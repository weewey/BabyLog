import XCTest
@testable import BabyLogCore

final class VisitSummaryBuilderTests: XCTestCase {

    // MARK: - Fixtures

    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 12) -> Date {
        cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h))!
    }

    private func feed(_ ml: Int, _ date: Date) -> FeedLog {
        try! FeedLog(volumeMl: ml, loggedAt: date, source: .bottle)
    }

    private func profile() -> ChildProfile {
        try! ChildProfile(name: "Ethan", dateOfBirth: date(2026, 4, 7), now: date(2026, 5, 1))
    }

    private func build(
        feeds: [FeedLog] = [],
        diapers: [DiaperLog] = [],
        growth: [GrowthMeasurement] = [],
        pumping: [PumpingSession] = [],
        milestones: [Milestone] = [],
        appointments: [MedicalAppointment] = [],
        now: Date
    ) -> VisitSummary {
        VisitSummaryBuilder().build(
            profile: profile(),
            feeds: feeds, diapers: diapers, growth: growth, pumping: pumping,
            milestones: milestones, appointments: appointments,
            now: now, calendar: cal
        )
    }

    // MARK: - Window

    func test_window_startsAtMostRecentPastAppointment() {
        let appts = [
            try! MedicalAppointment(title: "Old visit", scheduledAt: date(2026, 4, 1)),
            try! MedicalAppointment(title: "Last visit", scheduledAt: date(2026, 4, 20)),
            try! MedicalAppointment(title: "Future visit", scheduledAt: date(2026, 5, 3)),
        ]

        let summary = build(appointments: appts, now: date(2026, 5, 1))

        XCTAssertEqual(summary.since, date(2026, 4, 20))
        XCTAssertEqual(summary.until, date(2026, 5, 1))
        XCTAssertEqual(summary.nextAppointment?.title, "Future visit")
    }

    func test_window_fallsBackToDefaultDaysWhenNoPastAppointment() {
        let summary = VisitSummaryBuilder().build(
            profile: profile(), feeds: [], diapers: [], growth: [], pumping: [],
            milestones: [], appointments: [],
            now: date(2026, 5, 1), defaultWindowDays: 14, calendar: cal
        )

        XCTAssertEqual(summary.since, date(2026, 4, 17))
    }

    // MARK: - Feeds

    func test_feeds_aggregateOnlyWithinWindow() {
        let appts = [try! MedicalAppointment(title: "v", scheduledAt: date(2026, 4, 27, 0))]
        let feeds = [
            feed(60, date(2026, 4, 20)),               // before window — excluded
            feed(100, date(2026, 4, 28, 12)),           // day feed
            feed(120, date(2026, 4, 29, 2)),            // night feed (02:00)
            feed(80, date(2026, 4, 30, 23)),            // night feed (23:00)
        ]

        let s = build(feeds: feeds, appointments: appts, now: date(2026, 5, 1, 0)).feeds

        XCTAssertEqual(s.count, 3)
        XCTAssertEqual(s.totalMl, 300)
        XCTAssertEqual(s.nightFeeds, 2)
    }

    // MARK: - Diapers

    func test_diapers_countByType() {
        let appts = [try! MedicalAppointment(title: "v", scheduledAt: date(2026, 4, 28, 0))]
        let diapers = [
            DiaperLog(id: UUID(), type: .wet, loggedAt: date(2026, 4, 29)),
            DiaperLog(id: UUID(), type: .wet, loggedAt: date(2026, 4, 30)),
            DiaperLog(id: UUID(), type: .dirty, loggedAt: date(2026, 4, 30)),
            DiaperLog(id: UUID(), type: .wet, loggedAt: date(2026, 4, 1)), // before window
        ]

        let s = build(diapers: diapers, appointments: appts, now: date(2026, 5, 1)).diapers

        XCTAssertEqual(s.count, 3)
        XCTAssertEqual(s.byType.first { $0.label == "wet" }?.count, 2)
        XCTAssertEqual(s.byType.first { $0.label == "dirty" }?.count, 1)
        XCTAssertNil(s.byType.first { $0.label == "both" }) // zero counts omitted
    }

    // MARK: - Growth

    func test_growth_latestValuesAndWindowWeightDelta() {
        let appts = [try! MedicalAppointment(title: "v", scheduledAt: date(2026, 4, 20, 0))]
        let growth = [
            try! GrowthMeasurement(date: date(2026, 4, 22), weightGrams: 4800, heightCm: 56.0, headCircumferenceCm: 38.0),
            try! GrowthMeasurement(date: date(2026, 4, 30), weightGrams: 5200, heightCm: 58.0, headCircumferenceCm: nil),
        ]

        let s = build(growth: growth, appointments: appts, now: date(2026, 5, 1)).growth

        XCTAssertEqual(s.latestWeightGrams, 5200)
        XCTAssertEqual(s.latestHeightCm, 58.0)
        XCTAssertEqual(s.latestHeadCm, 38.0) // most recent non-nil head
        XCTAssertEqual(s.weightDeltaGrams, 400) // 5200 - 4800 within window
    }

    // MARK: - Milestones

    func test_milestones_filteredToWindowAndSorted() {
        let appts = [try! MedicalAppointment(title: "v", scheduledAt: date(2026, 4, 20, 0))]
        let ms = [
            try! Milestone(title: "Older", achievedAt: date(2026, 4, 1)), // excluded
            try! Milestone(title: "Tracks objects", achievedAt: date(2026, 4, 29)),
            try! Milestone(title: "Social smile", achievedAt: date(2026, 4, 24)),
        ]

        let s = build(milestones: ms, appointments: appts, now: date(2026, 5, 1)).milestones

        XCTAssertEqual(s.map(\.title), ["Social smile", "Tracks objects"])
    }

    // MARK: - plainText

    func test_plainText_includesHeaderSectionsAndDisclaimer() {
        let appts = [
            try! MedicalAppointment(title: "1-month", scheduledAt: date(2026, 4, 20, 0)),
            try! MedicalAppointment(title: "2-month", scheduledAt: date(2026, 5, 3)),
        ]
        let summary = build(
            feeds: [feed(120, date(2026, 4, 28))],
            milestones: [try! Milestone(title: "Social smile", achievedAt: date(2026, 4, 24))],
            appointments: appts,
            now: date(2026, 5, 1)
        )

        let text = summary.plainText(calendar: cal)

        XCTAssertTrue(text.contains("Ethan — visit summary"))
        XCTAssertTrue(text.contains("FEEDS"))
        XCTAssertTrue(text.contains("DIAPERS"))
        XCTAssertTrue(text.contains("Social smile"))
        XCTAssertTrue(text.contains("Next appointment: 2-month"))
        XCTAssertTrue(text.contains("not medical advice"))
    }

    func test_plainText_emptyData_rendersNoneLines() {
        let text = build(now: date(2026, 5, 1)).plainText(calendar: cal)

        XCTAssertTrue(text.contains("FEEDS"))
        XCTAssertTrue(text.contains("None logged this period"))
    }
}

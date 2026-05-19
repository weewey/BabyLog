import XCTest
@testable import BabyLogCore
import Foundation

final class PumpingAnalyticsTests: XCTestCase {

    private let template = PumpingScheduleTemplate.medelaEightSessionNewborn

    // Anchor "now" to a deterministic local moment: 2023-11-15 12:00 in the
    // current timezone. Using `DateComponents` + `Calendar.current` keeps
    // the "today" calculations aligned with whatever tz the test runner is in.
    private func now(hour: Int, minute: Int = 0) -> Date {
        var comps = DateComponents()
        comps.year = 2023
        comps.month = 11
        comps.day = 15
        comps.hour = hour
        comps.minute = minute
        return Calendar.current.date(from: comps) ?? Date(timeIntervalSince1970: 0)
    }

    private func session(hour: Int, minute: Int = 0, duration: Int = 20) throws -> PumpingSession {
        try PumpingSession(startedAt: now(hour: hour, minute: minute), durationMinutes: duration)
    }

    // MARK: - Empty

    func test_summarize_emptyReturnsZeros() {
        let a = PumpingAnalytics.summarize(
            sessions: [],
            template: template,
            now: now(hour: 12)
        )

        XCTAssertEqual(a.sessionsLoggedToday, 0)
        XCTAssertEqual(a.targetSessionsPerDay, 8)
        XCTAssertEqual(a.averageDurationMinutes, 0)
        XCTAssertEqual(a.totalMinutesToday, 0)
        XCTAssertEqual(a.totalVolumeMlToday, 0)
        XCTAssertEqual(a.completionRatio, 0)
    }

    // MARK: - Partial

    func test_summarize_partialDayAggregatesTodaysSessions() throws {
        let sessions = [
            try session(hour: 3,  duration: 22),
            try session(hour: 8,  minute: 30, duration: 20),
            try session(hour: 11, minute: 30, duration: 18),
        ]

        let a = PumpingAnalytics.summarize(
            sessions: sessions,
            template: template,
            now: now(hour: 12)
        )

        XCTAssertEqual(a.sessionsLoggedToday, 3)
        XCTAssertEqual(a.totalMinutesToday, 60)
        XCTAssertEqual(a.averageDurationMinutes, 20, accuracy: 0.001)
        XCTAssertEqual(a.completionRatio, 3.0 / 8.0, accuracy: 0.0001)
    }

    // MARK: - Daily volume total

    func test_summarize_totalVolumeMlTodaySumsAllSessions() throws {
        let sessions = [
            try session(year: 2023, month: 11, day: 15, hour: 3,  duration: 20, volumeMl: 80),
            try session(year: 2023, month: 11, day: 15, hour: 8,  duration: 20, volumeMl: 120),
            try session(year: 2023, month: 11, day: 15, hour: 11, duration: 18, volumeMl: 100),
        ]

        let a = PumpingAnalytics.summarize(
            sessions: sessions,
            template: template,
            now: now(hour: 12)
        )

        XCTAssertEqual(a.totalVolumeMlToday, 300)
    }

    func test_summarize_totalVolumeMlTodayTreatsNilAsZero() throws {
        let sessions = [
            try session(year: 2023, month: 11, day: 15, hour: 8, duration: 20, volumeMl: 100),
            try session(year: 2023, month: 11, day: 15, hour: 11, duration: 20, volumeMl: nil),
        ]

        let a = PumpingAnalytics.summarize(
            sessions: sessions,
            template: template,
            now: now(hour: 12)
        )

        XCTAssertEqual(a.totalVolumeMlToday, 100)
    }

    func test_summarize_totalVolumeMlTodayExcludesPreviousDays() throws {
        let sessions = [
            try session(year: 2023, month: 11, day: 14, hour: 10, duration: 20, volumeMl: 200),
            try session(year: 2023, month: 11, day: 15, hour: 8,  duration: 20, volumeMl: 50),
        ]

        let a = PumpingAnalytics.summarize(
            sessions: sessions,
            template: template,
            now: now(hour: 12)
        )

        XCTAssertEqual(a.totalVolumeMlToday, 50)
    }

    // MARK: - Completion clamp

    func test_summarize_completionRatioClampsAtOne() throws {
        let sessions = try (0..<10).map { _ in try session(hour: 8, minute: 30) }

        let a = PumpingAnalytics.summarize(
            sessions: sessions,
            template: template,
            now: now(hour: 23)
        )

        XCTAssertEqual(a.completionRatio, 1.0)
    }

    // MARK: - Next recommended slot

    func test_nextRecommendedSlot_skipsSlotsAlreadyCovered() throws {
        // Logged a session right near the morning-rise slot (08:30).
        // The next slot should be midday (11:30), not morning-rise.
        let sessions = [
            try session(hour: 8, minute: 35),
        ]

        let a = PumpingAnalytics.summarize(
            sessions: sessions,
            template: template,
            now: now(hour: 10)
        )

        XCTAssertEqual(a.nextRecommendedSlot?.id, "midday")
    }

    func test_nextRecommendedSlot_returnsFutureSlot() {
        let a = PumpingAnalytics.summarize(
            sessions: [],
            template: template,
            now: now(hour: 10)
        )

        // At 10:00 with no sessions, next slot is midday (11:30).
        XCTAssertEqual(a.nextRecommendedSlot?.id, "midday")
    }

    func test_nextRecommendedSlot_nilWhenAllSlotsPast() {
        // At 23:30, only "pre-sleep" (23:00) is left but it's already past.
        let a = PumpingAnalytics.summarize(
            sessions: [],
            template: template,
            now: now(hour: 23, minute: 30)
        )

        XCTAssertNil(a.nextRecommendedSlot)
    }

    // MARK: - Overnight gap

    func test_overnightGap_computedFromRealSessions() throws {
        // Session at 23:00 (pre-sleep) previous-day-shifted into "today"
        // is still "today" — but per our rule: anything before 06:00 counts
        // as "beforeSix". Log at 03:00, then at 08:30.
        let sessions = [
            try session(hour: 3,  duration: 20),
            try session(hour: 8,  minute: 30, duration: 20),
        ]

        let a = PumpingAnalytics.summarize(
            sessions: sessions,
            template: template,
            now: now(hour: 12)
        )

        // 03:00 → 08:30 = 5.5 hours
        XCTAssertEqual(a.overnightGapHours, 5.5, accuracy: 0.01)
    }

    func test_overnightGap_fallsBackToTemplateWhenNoSessions() {
        let a = PumpingAnalytics.summarize(
            sessions: [],
            template: template,
            now: now(hour: 12)
        )

        // pre-sleep=23:00, morning-rise=08:30. Gap = (24-23) + 8.5 = 9.5h
        XCTAssertEqual(a.overnightGapHours, 9.5, accuracy: 0.01)
    }

    // MARK: - Daily history grouping

    /// Build a session at a specific year/month/day/hour using a typed-throws
    /// constructor. Duration + volume default to something non-trivial so
    /// totals show up in assertions.
    private func session(
        year: Int, month: Int, day: Int, hour: Int, minute: Int = 0,
        duration: Int = 20, volumeMl: Int? = 120
    ) throws -> PumpingSession {
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        comps.hour = hour; comps.minute = minute
        let date = Calendar.current.date(from: comps)!
        return try PumpingSession(
            startedAt: date,
            durationMinutes: duration,
            milkVolumeMl: volumeMl
        )
    }

    func test_dailyHistory_emptyReturnsEmpty() {
        let result = PumpingAnalytics.dailyHistory(
            sessions: [],
            now: now(hour: 12)
        )
        XCTAssertTrue(result.isEmpty)
    }

    func test_dailyHistory_groupsSessionsByLocalDay_totalsVolumeAndMinutes() throws {
        let sessions = [
            try session(year: 2023, month: 11, day: 15, hour: 8,  duration: 20, volumeMl: 100),
            try session(year: 2023, month: 11, day: 15, hour: 14, duration: 25, volumeMl: 150),
            try session(year: 2023, month: 11, day: 14, hour: 10, duration: 30, volumeMl: 200),
        ]

        let history = PumpingAnalytics.dailyHistory(
            sessions: sessions,
            now: now(hour: 20)
        )

        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history[0].totalVolumeMl, 250)
        XCTAssertEqual(history[0].totalMinutes, 45)
        XCTAssertEqual(history[0].sessions.count, 2)
        XCTAssertEqual(history[1].totalVolumeMl, 200)
        XCTAssertEqual(history[1].totalMinutes, 30)
    }

    func test_dailyHistory_newestDayFirst_sessionsWithinDayNewestFirst() throws {
        let sessions = [
            try session(year: 2023, month: 11, day: 13, hour: 8),
            try session(year: 2023, month: 11, day: 15, hour: 8),
            try session(year: 2023, month: 11, day: 15, hour: 18),
            try session(year: 2023, month: 11, day: 14, hour: 12),
        ]

        let history = PumpingAnalytics.dailyHistory(
            sessions: sessions,
            now: now(hour: 20)
        )

        let days = history.map { Calendar.current.component(.day, from: $0.day) }
        XCTAssertEqual(days, [15, 14, 13])

        let firstDaySessionHours = history[0].sessions.map {
            Calendar.current.component(.hour, from: $0.startedAt)
        }
        XCTAssertEqual(firstDaySessionHours, [18, 8])
    }

    func test_dailyHistory_treatsNilVolumeAsZero() throws {
        let sessions = [
            try session(year: 2023, month: 11, day: 15, hour: 8, duration: 20, volumeMl: nil),
            try session(year: 2023, month: 11, day: 15, hour: 12, duration: 15, volumeMl: 80),
        ]

        let history = PumpingAnalytics.dailyHistory(
            sessions: sessions,
            now: now(hour: 20)
        )

        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history[0].totalVolumeMl, 80)
        XCTAssertEqual(history[0].totalMinutes, 35)
    }

    // MARK: - Daily volume series (30-day trend)

    func test_dailyVolumeSeries_returnsExactlyNDays_endingOnToday() throws {
        let series = PumpingAnalytics.dailyVolumeSeries(
            sessions: [],
            days: 30,
            now: now(hour: 12)
        )

        XCTAssertEqual(series.count, 30)
        let lastDay = Calendar.current.startOfDay(for: now(hour: 12))
        XCTAssertEqual(series.last?.day, lastDay)
    }

    func test_dailyVolumeSeries_zeroFillsMissingDays() throws {
        let sessions = [
            try session(year: 2023, month: 11, day: 15, hour: 8, volumeMl: 100),
            try session(year: 2023, month: 11, day: 13, hour: 8, volumeMl: 200),
        ]

        let series = PumpingAnalytics.dailyVolumeSeries(
            sessions: sessions,
            days: 5,
            now: now(hour: 20)
        )

        // 5 days ending on 2023-11-15 → [Nov 11, 12, 13, 14, 15]
        XCTAssertEqual(series.count, 5)
        XCTAssertEqual(series.map(\.totalVolumeMl), [0, 0, 200, 0, 100])
    }

    func test_dailyVolumeSeries_sumsMultipleSessionsOnSameDay() throws {
        let sessions = [
            try session(year: 2023, month: 11, day: 15, hour: 8,  volumeMl: 100),
            try session(year: 2023, month: 11, day: 15, hour: 14, volumeMl: 150),
            try session(year: 2023, month: 11, day: 15, hour: 18, volumeMl: 75),
        ]

        let series = PumpingAnalytics.dailyVolumeSeries(
            sessions: sessions,
            days: 1,
            now: now(hour: 20)
        )

        XCTAssertEqual(series.count, 1)
        XCTAssertEqual(series.first?.totalVolumeMl, 325)
    }

    func test_dailyVolumeSeries_ignoresSessionsOutsideWindow() throws {
        let sessions = [
            try session(year: 2023, month: 11, day: 15, hour: 8, volumeMl: 100),
            try session(year: 2023, month: 10, day: 1,  hour: 8, volumeMl: 400),
        ]

        let series = PumpingAnalytics.dailyVolumeSeries(
            sessions: sessions,
            days: 7,
            now: now(hour: 20)
        )

        XCTAssertEqual(series.count, 7)
        XCTAssertEqual(series.reduce(0) { $0 + $1.totalVolumeMl }, 100)
    }
}

import XCTest
@testable import BabyLogCore
import Foundation

final class ChatEmptyStateSummaryTests: XCTestCase {

    private static var utcCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private func feed(_ volume: Int, hoursBefore: Double, from ref: Date) throws -> FeedLog {
        let t = ref.addingTimeInterval(-hoursBefore * 3600)
        return try FeedLog(volumeMl: volume, loggedAt: t, source: .bottle)
    }

    private func diaper(hoursBefore: Double, from ref: Date) -> DiaperLog {
        let t = ref.addingTimeInterval(-hoursBefore * 3600)
        return DiaperLog(id: UUID(), type: .wet, loggedAt: t)
    }

    private func midday(_ dayOffset: Int) -> Date {
        // 12:00 UTC on `dayOffset` days since epoch.
        Date(timeIntervalSince1970: TimeInterval(dayOffset) * 86_400 + 12 * 3_600)
    }

    // MARK: - Aggregation

    func test_summarize_empty_producesZeroes() {
        let now = midday(10)
        let summary = ChatEmptyStateSummary.summarize(
            feeds: [], diapers: [], now: now, calendar: Self.utcCalendar
        )
        XCTAssertNil(summary.lastFeed)
        XCTAssertEqual(summary.todayFeedCount, 0)
        XCTAssertEqual(summary.todayFeedVolumeMl, 0)
        XCTAssertEqual(summary.todayDiaperCount, 0)
    }

    func test_summarize_collectsTodayTotalsAndIgnoresYesterday() throws {
        let now = midday(10)
        let feeds = [
            try feed(60, hoursBefore: 2, from: now),   // today
            try feed(90, hoursBefore: 4, from: now),   // today
            try feed(50, hoursBefore: 26, from: now),  // yesterday
        ]
        let diapers = [
            diaper(hoursBefore: 1, from: now),   // today
            diaper(hoursBefore: 30, from: now),  // yesterday
        ]
        let summary = ChatEmptyStateSummary.summarize(
            feeds: feeds, diapers: diapers, now: now, calendar: Self.utcCalendar
        )
        XCTAssertEqual(summary.todayFeedCount, 2)
        XCTAssertEqual(summary.todayFeedVolumeMl, 150)
        XCTAssertEqual(summary.todayDiaperCount, 1)
        XCTAssertEqual(summary.lastFeed?.volumeMl, 60)
    }

    // MARK: - Suggestions

    func test_suggestions_trailingChipIsAlwaysFeedTotal() {
        // 7am: early morning, no feeds yet — "Last night" recap removed
        // as not useful (user feedback 2026-04-15), trailing chip is
        // always the total query now.
        let now = Date(timeIntervalSince1970: 10 * 86_400 + 7 * 3_600)
        let summary = ChatEmptyStateSummary.summarize(
            feeds: [], diapers: [], now: now, calendar: Self.utcCalendar
        )
        XCTAssertEqual(summary.suggestions.last?.slug, "feedTotal")
        XCTAssertTrue(summary.suggestions.last?.autoSend == true)
    }

    func test_suggestions_withFeedsToday_offersTotalQuery() throws {
        let now = midday(10)
        let feeds = [try feed(60, hoursBefore: 2, from: now)]
        let summary = ChatEmptyStateSummary.summarize(
            feeds: feeds, diapers: [], now: now, calendar: Self.utcCalendar
        )
        XCTAssertEqual(summary.suggestions.last?.slug, "feedTotal")
    }

    func test_suggestions_noFeedsAfterMorning_stillOffersFeedTotal() {
        // 2pm, no feeds yet — the total query still works (it'll say zero).
        let now = Date(timeIntervalSince1970: 10 * 86_400 + 14 * 3_600)
        let summary = ChatEmptyStateSummary.summarize(
            feeds: [], diapers: [], now: now, calendar: Self.utcCalendar
        )
        XCTAssertEqual(summary.suggestions.last?.slug, "feedTotal")
    }

    // MARK: - Stale last feed

    func test_isLastFeedStale_false_whenRecent() throws {
        let now = midday(10)
        let feeds = [try feed(60, hoursBefore: 2, from: now)]
        let summary = ChatEmptyStateSummary.summarize(
            feeds: feeds, diapers: [], now: now, calendar: Self.utcCalendar
        )
        XCTAssertFalse(summary.isLastFeedStale)
    }

    func test_isLastFeedStale_true_afterFourHours() throws {
        let now = midday(10)
        let feeds = [try feed(60, hoursBefore: 4.5, from: now)]
        let summary = ChatEmptyStateSummary.summarize(
            feeds: feeds, diapers: [], now: now, calendar: Self.utcCalendar
        )
        XCTAssertTrue(summary.isLastFeedStale)
    }

    func test_isLastFeedStale_false_whenNoFeeds() {
        let now = midday(10)
        let summary = ChatEmptyStateSummary.summarize(
            feeds: [], diapers: [], now: now, calendar: Self.utcCalendar
        )
        XCTAssertFalse(summary.isLastFeedStale)
    }

    func test_suggestions_alwaysIncludeFourWriteChips() {
        let now = midday(10)
        let summary = ChatEmptyStateSummary.summarize(
            feeds: [], diapers: [], now: now, calendar: Self.utcCalendar
        )
        let slugs = summary.suggestions.map(\.slug)
        XCTAssertEqual(slugs.prefix(4), ["feed60", "pump20", "diaperDirty", "diaperWet"])
        XCTAssertEqual(summary.suggestions.count, 5)
    }

    func test_suggestions_pumpChipIsWriteIntent() {
        let now = midday(10)
        let suggestions = ChatEmptyStateSummary.defaultSuggestions(
            now: now, calendar: Self.utcCalendar, todayFeedCount: 0, lastFeed: nil
        )
        let pump = suggestions.first { $0.slug == "pump20" }
        XCTAssertNotNil(pump)
        XCTAssertTrue(pump?.text.hasPrefix("20 min pump at ") ?? false, "Pump chip should include time")
        XCTAssertFalse(pump?.autoSend ?? true, "Pump chip should fill composer, not auto-send")
    }
}

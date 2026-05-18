import XCTest
@testable import LittleECore
import Foundation

final class FeedLogAnalyticsTests: XCTestCase {

    private static var utcCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    func test_totalFor_emptyInput_returnsZero() {
        let total = FeedLogAnalytics.totalFor([], on: Date(), calendar: Self.utcCalendar)
        XCTAssertEqual(total, FeedLogAnalytics.DailyTotal(volumeMl: 0, count: 0))
    }

    func test_totalFor_sumsSameDayFeeds() throws {
        let cal = Self.utcCalendar
        let day = Date(timeIntervalSince1970: 86_400) // 1970-01-02 00:00 UTC
        let f1 = try FeedLog(volumeMl: 120, loggedAt: day, source: .bottle)
        let f2 = try FeedLog(volumeMl: 80, loggedAt: day + 3_600, source: .breast)

        let total = FeedLogAnalytics.totalFor([f1, f2], on: day, calendar: cal)

        XCTAssertEqual(total.volumeMl, 200)
        XCTAssertEqual(total.count, 2)
    }

    func test_totalFor_ignoresOtherDays() throws {
        let cal = Self.utcCalendar
        let today = Date(timeIntervalSince1970: 86_400)
        let yesterday = Date(timeIntervalSince1970: 0)
        let todayFeed = try FeedLog(volumeMl: 120, loggedAt: today, source: .bottle)
        let yesterdayFeed = try FeedLog(volumeMl: 500, loggedAt: yesterday, source: .bottle)

        let total = FeedLogAnalytics.totalFor([todayFeed, yesterdayFeed], on: today, calendar: cal)

        XCTAssertEqual(total.volumeMl, 120)
        XCTAssertEqual(total.count, 1)
    }

    // MARK: - dailyVolumes

    func test_dailyVolumes_emptyInput_returnsEmptyBucketsForRange() {
        let cal = Self.utcCalendar
        let endOfDay = Date(timeIntervalSince1970: 7 * 86_400) // day 7

        let result = FeedLogAnalytics.dailyVolumes(
            [],
            endingOn: endOfDay,
            days: 7,
            calendar: cal
        )

        XCTAssertEqual(result.count, 7)
        XCTAssertTrue(result.allSatisfy { $0.volumeMl == 0 && $0.count == 0 })
    }

    func test_dailyVolumes_singleDay_bucketsFeedUnderItsDate() throws {
        let cal = Self.utcCalendar
        let day = Date(timeIntervalSince1970: 7 * 86_400)
        let feed = try FeedLog(volumeMl: 150, loggedAt: day + 3_600, source: .bottle)

        let result = FeedLogAnalytics.dailyVolumes(
            [feed],
            endingOn: day,
            days: 3,
            calendar: cal
        )

        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result.last?.volumeMl, 150)
        XCTAssertEqual(result.last?.count, 1)
        XCTAssertEqual(result.dropLast().map(\.volumeMl), [0, 0])
    }

    func test_dailyVolumes_multiDay_sumsAndSortsAscending() throws {
        let cal = Self.utcCalendar
        let day3 = Date(timeIntervalSince1970: 3 * 86_400)
        let day2 = Date(timeIntervalSince1970: 2 * 86_400)
        let day1 = Date(timeIntervalSince1970: 1 * 86_400)

        let feeds = [
            try FeedLog(volumeMl: 100, loggedAt: day1 + 60, source: .bottle),
            try FeedLog(volumeMl: 120, loggedAt: day2 + 60, source: .bottle),
            try FeedLog(volumeMl: 80,  loggedAt: day2 + 7_200, source: .breast),
            try FeedLog(volumeMl: 90,  loggedAt: day3 + 60, source: .bottle),
        ]

        let result = FeedLogAnalytics.dailyVolumes(
            feeds,
            endingOn: day3,
            days: 3,
            calendar: cal
        )

        XCTAssertEqual(result.map(\.volumeMl), [100, 200, 90])
        XCTAssertEqual(result.map(\.count), [1, 2, 1])
        // ascending
        XCTAssertEqual(result.map(\.date), result.map(\.date).sorted())
    }

    func test_dailyVolumes_ignoresFeedsOutsideRange() throws {
        let cal = Self.utcCalendar
        let day5 = Date(timeIntervalSince1970: 5 * 86_400)
        let day1 = Date(timeIntervalSince1970: 1 * 86_400) // outside a 3-day window ending day5

        let inRange  = try FeedLog(volumeMl: 100, loggedAt: day5, source: .bottle)
        let outRange = try FeedLog(volumeMl: 500, loggedAt: day1, source: .bottle)

        let result = FeedLogAnalytics.dailyVolumes(
            [inRange, outRange],
            endingOn: day5,
            days: 3,
            calendar: cal
        )

        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result.map(\.volumeMl).reduce(0, +), 100)
    }

    // MARK: - pumpMilkPercentage

    func test_pumpMilkPercentage_bothZero_returnsZero() {
        XCTAssertEqual(FeedLogAnalytics.pumpMilkPercentage(feedVolumeMl: 0, pumpVolumeMl: 0), 0)
    }

    func test_pumpMilkPercentage_halfAndHalf_returnsHundred() {
        XCTAssertEqual(FeedLogAnalytics.pumpMilkPercentage(feedVolumeMl: 200, pumpVolumeMl: 200), 100)
    }

    func test_pumpMilkPercentage_noPump_returnsZero() {
        XCTAssertEqual(FeedLogAnalytics.pumpMilkPercentage(feedVolumeMl: 300, pumpVolumeMl: 0), 0)
    }

    func test_pumpMilkPercentage_noFeed_returnsZero() {
        XCTAssertEqual(FeedLogAnalytics.pumpMilkPercentage(feedVolumeMl: 0, pumpVolumeMl: 100), 0)
    }

    func test_pumpMilkPercentage_truncatesDown() {
        // 100 / 300 = 33.3% → 33
        XCTAssertEqual(FeedLogAnalytics.pumpMilkPercentage(feedVolumeMl: 300, pumpVolumeMl: 100), 33)
    }

    // MARK: - dailyPumpVolumes

    func test_dailyPumpVolumes_emptyReturnsEmpty() {
        let cal = Self.utcCalendar
        let result = FeedLogAnalytics.dailyPumpVolumes(
            [],
            endingOn: Date(timeIntervalSince1970: 86_400),
            days: 3,
            calendar: cal
        )
        XCTAssertTrue(result.isEmpty)
    }

    func test_dailyPumpVolumes_sumsByDay() throws {
        let cal = Self.utcCalendar
        let day = Date(timeIntervalSince1970: 86_400)
        let s1 = try PumpingSession(startedAt: day + 3600, durationMinutes: 20, milkVolumeMl: 80)
        let s2 = try PumpingSession(startedAt: day + 7200, durationMinutes: 20, milkVolumeMl: 120)

        let result = FeedLogAnalytics.dailyPumpVolumes(
            [s1, s2],
            endingOn: day,
            days: 1,
            calendar: cal
        )

        XCTAssertEqual(result[cal.startOfDay(for: day)], 200)
    }

    func test_dailyPumpVolumes_ignoresOutsideWindow() throws {
        let cal = Self.utcCalendar
        let day3 = Date(timeIntervalSince1970: 3 * 86_400)
        let day0 = Date(timeIntervalSince1970: 0)
        let inRange = try PumpingSession(startedAt: day3 + 60, durationMinutes: 20, milkVolumeMl: 100)
        let outRange = try PumpingSession(startedAt: day0 + 60, durationMinutes: 20, milkVolumeMl: 500)

        let result = FeedLogAnalytics.dailyPumpVolumes(
            [inRange, outRange],
            endingOn: day3,
            days: 2,
            calendar: cal
        )

        XCTAssertEqual(result.values.reduce(0, +), 100)
    }

    func test_dailyPumpVolumes_nilVolumeTreatedAsZero() throws {
        let cal = Self.utcCalendar
        let day = Date(timeIntervalSince1970: 86_400)
        let s = try PumpingSession(startedAt: day + 3600, durationMinutes: 20, milkVolumeMl: nil)

        let result = FeedLogAnalytics.dailyPumpVolumes(
            [s],
            endingOn: day,
            days: 1,
            calendar: cal
        )

        XCTAssertEqual(result[cal.startOfDay(for: day)], 0)
    }

    // MARK: - DST boundary

    func test_dailyVolumes_dstBoundary_producesOneBucketPerCalendarDay() throws {
        // US DST spring-forward: 2025-03-09 in America/Los_Angeles.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!

        // Pick a local noon on Mar 11, 2025 and request a 5-day window.
        var comps = DateComponents()
        comps.year = 2025; comps.month = 3; comps.day = 11; comps.hour = 12
        let endDay = cal.date(from: comps)!

        // One feed at local noon on Mar 9 (DST day) and one on Mar 10.
        var c1 = DateComponents(); c1.year = 2025; c1.month = 3; c1.day = 9; c1.hour = 12
        var c2 = DateComponents(); c2.year = 2025; c2.month = 3; c2.day = 10; c2.hour = 12
        let feed1 = try FeedLog(volumeMl: 100, loggedAt: cal.date(from: c1)!, source: .bottle)
        let feed2 = try FeedLog(volumeMl: 140, loggedAt: cal.date(from: c2)!, source: .bottle)

        let result = FeedLogAnalytics.dailyVolumes(
            [feed1, feed2],
            endingOn: endDay,
            days: 5,
            calendar: cal
        )

        XCTAssertEqual(result.count, 5)
        // Each calendar day appears exactly once, ascending, no duplicates across DST.
        let days = result.map { cal.startOfDay(for: $0.date) }
        XCTAssertEqual(Set(days).count, 5)
        XCTAssertEqual(days, days.sorted())
        // Feeds landed in their own buckets.
        var totals: [Date: Int] = [:]
        for bucket in result { totals[cal.startOfDay(for: bucket.date)] = bucket.volumeMl }
        XCTAssertEqual(totals[cal.startOfDay(for: cal.date(from: c1)!)], 100)
        XCTAssertEqual(totals[cal.startOfDay(for: cal.date(from: c2)!)], 140)
    }
}

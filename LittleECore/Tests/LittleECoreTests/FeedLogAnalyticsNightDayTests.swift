import XCTest
@testable import LittleECore
import Foundation

/// Night/day split, cluster detection, rolling hourly heatmap, peak hours,
/// longest stretch. Night window is 22:00–06:59, day 07:00–21:59.
final class FeedLogAnalyticsNightDayTests: XCTestCase {

    private static var utcCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private func feed(
        _ volume: Int,
        dayOffset: Int,
        hour: Int,
        minute: Int = 0
    ) throws -> FeedLog {
        let base = Date(timeIntervalSince1970: TimeInterval(dayOffset) * 86_400)
        let t = base.addingTimeInterval(TimeInterval(hour * 3_600 + minute * 60))
        return try FeedLog(volumeMl: volume, loggedAt: t, source: .bottle)
    }

    private var today: Date { Date(timeIntervalSince1970: 10 * 86_400) }

    // MARK: - nightDaySplit

    func test_nightDaySplit_empty_returnsZeros() {
        let split = FeedLogAnalytics.nightDaySplit(
            feeds: [], on: today, calendar: Self.utcCalendar
        )
        XCTAssertEqual(split.night, FeedLogAnalytics.DailyTotal(volumeMl: 0, count: 0))
        XCTAssertEqual(split.day, FeedLogAnalytics.DailyTotal(volumeMl: 0, count: 0))
    }

    func test_nightDaySplit_classifiesBoundaryHours() throws {
        // 22:00 night, 21:59 day, 06:59 night, 07:00 day.
        let feeds = [
            try feed(100, dayOffset: 10, hour: 22, minute: 0),
            try feed(110, dayOffset: 10, hour: 21, minute: 59),
            try feed(120, dayOffset: 10, hour: 6, minute: 59),
            try feed(130, dayOffset: 10, hour: 7, minute: 0),
        ]
        let split = FeedLogAnalytics.nightDaySplit(
            feeds: feeds, on: today, calendar: Self.utcCalendar
        )
        XCTAssertEqual(split.night.volumeMl, 220)
        XCTAssertEqual(split.night.count, 2)
        XCTAssertEqual(split.day.volumeMl, 240)
        XCTAssertEqual(split.day.count, 2)
    }

    func test_nightDaySplit_ignoresOtherDays() throws {
        let feeds = [
            try feed(100, dayOffset: 10, hour: 2),
            try feed(200, dayOffset: 9, hour: 23),
            try feed(150, dayOffset: 10, hour: 13),
        ]
        let split = FeedLogAnalytics.nightDaySplit(
            feeds: feeds, on: today, calendar: Self.utcCalendar
        )
        XCTAssertEqual(split.night.volumeMl, 100)
        XCTAssertEqual(split.day.volumeMl, 150)
    }

    // MARK: - detectNightCluster

    func test_detectNightCluster_belowThreshold_returnsFalse() throws {
        let feeds = [
            try feed(80, dayOffset: 10, hour: 22),
            try feed(80, dayOffset: 10, hour: 23),
        ]
        XCTAssertFalse(
            FeedLogAnalytics.detectNightCluster(
                feeds: feeds, on: today, calendar: Self.utcCalendar
            )
        )
    }

    func test_detectNightCluster_threeCloseFeeds_returnsTrue() throws {
        let feeds = [
            try feed(80, dayOffset: 10, hour: 1, minute: 0),
            try feed(80, dayOffset: 10, hour: 2, minute: 10),
            try feed(80, dayOffset: 10, hour: 3, minute: 5),
        ]
        XCTAssertTrue(
            FeedLogAnalytics.detectNightCluster(
                feeds: feeds, on: today, calendar: Self.utcCalendar
            )
        )
    }

    func test_detectNightCluster_widelySpacedNightFeeds_returnsFalse() throws {
        let feeds = [
            try feed(80, dayOffset: 10, hour: 0),
            try feed(80, dayOffset: 10, hour: 2),
            try feed(80, dayOffset: 10, hour: 4),
        ]
        XCTAssertFalse(
            FeedLogAnalytics.detectNightCluster(
                feeds: feeds, on: today, calendar: Self.utcCalendar
            )
        )
    }

    func test_detectNightCluster_ignoresDayFeeds() throws {
        let feeds = [
            try feed(80, dayOffset: 10, hour: 9),
            try feed(80, dayOffset: 10, hour: 10),
            try feed(80, dayOffset: 10, hour: 11),
        ]
        XCTAssertFalse(
            FeedLogAnalytics.detectNightCluster(
                feeds: feeds, on: today, calendar: Self.utcCalendar
            )
        )
    }

    // MARK: - hourlyHeatmap

    func test_hourlyHeatmap_empty_returns24Zeros() {
        let grid = FeedLogAnalytics.hourlyHeatmap(
            feeds: [], endingOn: today, days: 7, calendar: Self.utcCalendar
        )
        XCTAssertEqual(grid.count, 24)
        XCTAssertTrue(grid.allSatisfy { $0 == 0 })
    }

    func test_hourlyHeatmap_bucketsByHourOfDay() throws {
        let feeds = [
            try feed(80, dayOffset: 10, hour: 3),
            try feed(80, dayOffset: 9, hour: 3),
            try feed(80, dayOffset: 8, hour: 14),
        ]
        let grid = FeedLogAnalytics.hourlyHeatmap(
            feeds: feeds, endingOn: today, days: 7, calendar: Self.utcCalendar
        )
        XCTAssertEqual(grid[3], 2)
        XCTAssertEqual(grid[14], 1)
        XCTAssertEqual(grid.reduce(0, +), 3)
    }

    func test_hourlyHeatmap_ignoresOutsideWindow() throws {
        let feeds = [
            try feed(80, dayOffset: 10, hour: 9),
            try feed(80, dayOffset: 2, hour: 9),
        ]
        let grid = FeedLogAnalytics.hourlyHeatmap(
            feeds: feeds, endingOn: today, days: 7, calendar: Self.utcCalendar
        )
        XCTAssertEqual(grid[9], 1)
        XCTAssertEqual(grid.reduce(0, +), 1)
    }

    // MARK: - peakHours

    func test_peakHours_empty_returnsEmpty() {
        let peaks = FeedLogAnalytics.peakHours(
            feeds: [], endingOn: today, days: 7, limit: 4, calendar: Self.utcCalendar
        )
        XCTAssertTrue(peaks.isEmpty)
    }

    func test_peakHours_returnsTopByCountDescending() throws {
        let feeds = [
            try feed(80, dayOffset: 10, hour: 9),
            try feed(80, dayOffset: 9, hour: 9),
            try feed(80, dayOffset: 8, hour: 9),
            try feed(80, dayOffset: 10, hour: 14),
            try feed(80, dayOffset: 9, hour: 14),
            try feed(80, dayOffset: 10, hour: 21),
        ]
        let peaks = FeedLogAnalytics.peakHours(
            feeds: feeds, endingOn: today, days: 7, limit: 4, calendar: Self.utcCalendar
        )
        XCTAssertEqual(peaks.count, 3)
        XCTAssertEqual(peaks[0].hour, 9)
        XCTAssertEqual(peaks[0].count, 3)
        XCTAssertEqual(peaks[1].hour, 14)
        XCTAssertEqual(peaks[2].hour, 21)
    }

    func test_peakHours_honorsLimit() throws {
        let feeds = (0..<5).compactMap { try? feed(80, dayOffset: 10, hour: $0) }
        let peaks = FeedLogAnalytics.peakHours(
            feeds: feeds, endingOn: today, days: 7, limit: 3, calendar: Self.utcCalendar
        )
        XCTAssertEqual(peaks.count, 3)
    }

    // MARK: - longestStretch

    func test_longestStretch_fewerThanTwo_returnsNil() throws {
        XCTAssertNil(
            FeedLogAnalytics.longestStretch(
                feeds: [try feed(80, dayOffset: 10, hour: 3)],
                on: today, calendar: Self.utcCalendar
            )
        )
        XCTAssertNil(
            FeedLogAnalytics.longestStretch(
                feeds: [], on: today, calendar: Self.utcCalendar
            )
        )
    }

    func test_longestStretch_returnsLargestGapOnDay() throws {
        let feeds = [
            try feed(80, dayOffset: 10, hour: 1),
            try feed(80, dayOffset: 10, hour: 5),
            try feed(80, dayOffset: 10, hour: 6),
            try feed(80, dayOffset: 10, hour: 13),
            try feed(80, dayOffset: 10, hour: 15),
        ]
        let stretch = FeedLogAnalytics.longestStretch(
            feeds: feeds, on: today, calendar: Self.utcCalendar
        )
        XCTAssertEqual(stretch, 7 * 3_600)
    }

    func test_longestStretch_ignoresOtherDays() throws {
        let feeds = [
            try feed(80, dayOffset: 9, hour: 1),
            try feed(80, dayOffset: 10, hour: 5),
            try feed(80, dayOffset: 10, hour: 8),
        ]
        let stretch = FeedLogAnalytics.longestStretch(
            feeds: feeds, on: today, calendar: Self.utcCalendar
        )
        XCTAssertEqual(stretch, 3 * 3_600)
    }
}

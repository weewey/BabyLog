import XCTest
@testable import BabyLogCore
import Foundation

final class FeedLogClusterHeatmapTests: XCTestCase {

    // A deterministic calendar in a fixed timezone so tests don't depend on the host.
    private func utcCalendar(firstWeekday: Int = 1) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        // Force UTC to remove DST / host-TZ flakiness from the base case.
        if let tz = TimeZone(identifier: "UTC") {
            cal.timeZone = tz
        }
        cal.firstWeekday = firstWeekday
        return cal
    }

    private func date(_ iso: String) throws -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return try XCTUnwrap(f.date(from: iso))
    }

    // MARK: - Shape

    func test_clusterHeatmap_emptyInputReturns7x24GridOfZeros() throws {
        let start = try date("2026-04-05T00:00:00Z") // Sunday
        let end = try date("2026-04-12T00:00:00Z")   // Sunday
        let cal = utcCalendar()

        let grid = FeedLogAnalytics.clusterHeatmap(
            feeds: [],
            range: start..<end,
            calendar: cal
        )

        XCTAssertEqual(grid.count, 7)
        XCTAssertTrue(grid.allSatisfy { $0.count == 24 })
        XCTAssertTrue(grid.allSatisfy { $0.allSatisfy { $0 == 0 } })
    }

    // MARK: - Single feed

    func test_clusterHeatmap_singleFeedLandsInCorrectCell() throws {
        let cal = utcCalendar() // firstWeekday = Sunday
        let start = try date("2026-04-05T00:00:00Z")
        let end = try date("2026-04-12T00:00:00Z")
        // Tuesday 2026-04-07 at 14:00 UTC
        let feed = try FeedLog(
            volumeMl: 100,
            loggedAt: try date("2026-04-07T14:00:00Z"),
            source: .bottle
        )

        let grid = FeedLogAnalytics.clusterHeatmap(
            feeds: [feed],
            range: start..<end,
            calendar: cal
        )

        // firstWeekday=Sunday → row 0 = Sunday, row 2 = Tuesday.
        XCTAssertEqual(grid[2][14], 1)
        // Everything else zero.
        var total = 0
        for r in 0..<7 { for c in 0..<24 { total += grid[r][c] } }
        XCTAssertEqual(total, 1)
    }

    // MARK: - Midnight boundary

    func test_clusterHeatmap_midnightFeedLandsInHourZero() throws {
        let cal = utcCalendar()
        let start = try date("2026-04-05T00:00:00Z")
        let end = try date("2026-04-12T00:00:00Z")
        let feed = try FeedLog(
            volumeMl: 80,
            loggedAt: try date("2026-04-06T00:00:00Z"), // Monday 00:00
            source: .breast
        )

        let grid = FeedLogAnalytics.clusterHeatmap(
            feeds: [feed],
            range: start..<end,
            calendar: cal
        )

        XCTAssertEqual(grid[1][0], 1)
    }

    // MARK: - Out-of-range filtering

    func test_clusterHeatmap_ignoresFeedsOutsideRange() throws {
        let cal = utcCalendar()
        let start = try date("2026-04-05T00:00:00Z")
        let end = try date("2026-04-12T00:00:00Z")

        let before = try FeedLog(
            volumeMl: 100,
            loggedAt: try date("2026-04-04T12:00:00Z"),
            source: .bottle
        )
        let after = try FeedLog(
            volumeMl: 100,
            loggedAt: try date("2026-04-12T00:00:00Z"), // end is exclusive
            source: .bottle
        )
        let inside = try FeedLog(
            volumeMl: 100,
            loggedAt: try date("2026-04-08T09:30:00Z"),
            source: .bottle
        )

        let grid = FeedLogAnalytics.clusterHeatmap(
            feeds: [before, after, inside],
            range: start..<end,
            calendar: cal
        )

        var total = 0
        for r in 0..<7 { for c in 0..<24 { total += grid[r][c] } }
        XCTAssertEqual(total, 1)
        XCTAssertEqual(grid[3][9], 1) // Wednesday 09:xx
    }

    // MARK: - Accumulation

    func test_clusterHeatmap_multipleFeedsInSameCellAccumulate() throws {
        let cal = utcCalendar()
        let start = try date("2026-04-05T00:00:00Z")
        let end = try date("2026-04-12T00:00:00Z")
        let feeds = try [
            FeedLog(volumeMl: 60, loggedAt: try date("2026-04-08T03:05:00Z"), source: .bottle),
            FeedLog(volumeMl: 70, loggedAt: try date("2026-04-08T03:45:00Z"), source: .breast),
            FeedLog(volumeMl: 50, loggedAt: try date("2026-04-08T03:59:00Z"), source: .bottle),
        ]

        let grid = FeedLogAnalytics.clusterHeatmap(
            feeds: feeds,
            range: start..<end,
            calendar: cal
        )

        XCTAssertEqual(grid[3][3], 3)
    }

    // MARK: - First weekday configurable

    func test_clusterHeatmap_respectsCalendarFirstWeekday() throws {
        // Monday-first calendar: row 0 = Monday, row 1 = Tuesday.
        let cal = utcCalendar(firstWeekday: 2)
        let start = try date("2026-04-06T00:00:00Z") // Monday
        let end = try date("2026-04-13T00:00:00Z")
        let feed = try FeedLog(
            volumeMl: 100,
            loggedAt: try date("2026-04-07T10:00:00Z"), // Tuesday
            source: .bottle
        )

        let grid = FeedLogAnalytics.clusterHeatmap(
            feeds: [feed],
            range: start..<end,
            calendar: cal
        )

        XCTAssertEqual(grid[1][10], 1)
    }

    // MARK: - DST spring forward

    func test_clusterHeatmap_dstSpringForwardLosesNoFeed() throws {
        // US spring-forward 2026-03-08 02:00 → 03:00 local (America/New_York).
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        cal.firstWeekday = 1

        // Pick a feed at 04:30 local on the spring-forward day — unambiguous.
        let localFormatter = DateFormatter()
        localFormatter.calendar = cal
        localFormatter.timeZone = cal.timeZone
        localFormatter.dateFormat = "yyyy-MM-dd HH:mm"
        let loggedAt = try XCTUnwrap(localFormatter.date(from: "2026-03-08 04:30"))
        let start = try XCTUnwrap(localFormatter.date(from: "2026-03-08 00:00"))
        let end = try XCTUnwrap(localFormatter.date(from: "2026-03-15 00:00"))

        let feed = try FeedLog(volumeMl: 100, loggedAt: loggedAt, source: .bottle)

        let grid = FeedLogAnalytics.clusterHeatmap(
            feeds: [feed],
            range: start..<end,
            calendar: cal
        )

        // Sunday row (0 with firstWeekday=Sun), hour 4.
        XCTAssertEqual(grid[0][4], 1)
        var total = 0
        for r in 0..<7 { for c in 0..<24 { total += grid[r][c] } }
        XCTAssertEqual(total, 1)
    }

    // MARK: - DST fall back

    func test_clusterHeatmap_dstFallBackCountsBothInstancesInLocalHour() throws {
        // US fall-back 2026-11-01 02:00 → 01:00 local. The 01:xx hour happens twice.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        cal.firstWeekday = 1

        // Two UTC instants whose local wall-clock hour is 01:xx on 2026-11-01.
        // 05:30 UTC = 01:30 EDT (first 1am); 06:30 UTC = 01:30 EST (second 1am).
        let first = try FeedLog(
            volumeMl: 80,
            loggedAt: try date("2026-11-01T05:30:00Z"),
            source: .bottle
        )
        let second = try FeedLog(
            volumeMl: 80,
            loggedAt: try date("2026-11-01T06:30:00Z"),
            source: .bottle
        )

        let start = try date("2026-11-01T04:00:00Z") // Sunday 00:00 EDT
        let end = try date("2026-11-08T05:00:00Z")   // following Sunday 00:00 EST

        let grid = FeedLogAnalytics.clusterHeatmap(
            feeds: [first, second],
            range: start..<end,
            calendar: cal
        )

        XCTAssertEqual(grid[0][1], 2) // Sunday row, hour 1 local
    }

    // MARK: - feedsInBucket

    func test_feedsInBucket_returnsOnlyMatchingRowAndHour() throws {
        let cal = utcCalendar()
        let match1 = try FeedLog(volumeMl: 100, loggedAt: try date("2026-04-07T14:10:00Z"), source: .bottle)
        let match2 = try FeedLog(volumeMl: 100, loggedAt: try date("2026-04-14T14:50:00Z"), source: .breast)
        let wrongHour = try FeedLog(volumeMl: 100, loggedAt: try date("2026-04-07T15:00:00Z"), source: .bottle)
        let wrongDay = try FeedLog(volumeMl: 100, loggedAt: try date("2026-04-08T14:00:00Z"), source: .bottle)

        let filtered = FeedLogAnalytics.feedsInBucket(
            [match1, wrongHour, wrongDay, match2],
            row: 2, // Tuesday with firstWeekday=Sunday
            hour: 14,
            calendar: cal
        )

        XCTAssertEqual(Set(filtered.map(\.id)), Set([match1.id, match2.id]))
    }
}

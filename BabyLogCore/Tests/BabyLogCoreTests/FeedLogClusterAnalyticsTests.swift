import XCTest
@testable import BabyLogCore
import Foundation

final class FeedLogClusterAnalyticsTests: XCTestCase {

    func test_timeSinceLast_emptyReturnsNil() {
        XCTAssertNil(FeedLogAnalytics.timeSinceLast([], now: Date()))
    }

    func test_timeSinceLast_picksMostRecent() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let old = try FeedLog(volumeMl: 100, loggedAt: now.addingTimeInterval(-7_200), source: .bottle)
        let recent = try FeedLog(volumeMl: 120, loggedAt: now.addingTimeInterval(-1_800), source: .breast)

        let delta = FeedLogAnalytics.timeSinceLast([old, recent], now: now)

        XCTAssertEqual(delta, 1_800)
    }

    func test_intervalsBetween_returnsDeltasInChronologicalOrder() throws {
        let base = Date(timeIntervalSince1970: 0)
        let f1 = try FeedLog(volumeMl: 100, loggedAt: base, source: .bottle)
        let f2 = try FeedLog(volumeMl: 100, loggedAt: base.addingTimeInterval(3_600), source: .bottle)
        let f3 = try FeedLog(volumeMl: 100, loggedAt: base.addingTimeInterval(9_000), source: .bottle)

        let intervals = FeedLogAnalytics.intervalsBetween([f3, f1, f2])

        XCTAssertEqual(intervals, [3_600, 5_400])
    }

    func test_averageInterval_returnsMeanSeconds() throws {
        let base = Date(timeIntervalSince1970: 0)
        let feeds = try [
            FeedLog(volumeMl: 100, loggedAt: base, source: .bottle),
            FeedLog(volumeMl: 100, loggedAt: base.addingTimeInterval(3_600), source: .bottle),
            FeedLog(volumeMl: 100, loggedAt: base.addingTimeInterval(9_000), source: .bottle),
        ]

        XCTAssertEqual(FeedLogAnalytics.averageInterval(feeds), 4_500)
    }

    func test_averageInterval_singleOrEmptyReturnsNil() throws {
        XCTAssertNil(FeedLogAnalytics.averageInterval([]))
        let one = try FeedLog(volumeMl: 100, loggedAt: Date(), source: .bottle)
        XCTAssertNil(FeedLogAnalytics.averageInterval([one]))
    }
}

import XCTest
@testable import LittleECore

final class FeedReminderSchedulerTests: XCTestCase {

    func test_emptyFeeds_returnsNil() {
        XCTAssertNil(FeedReminderScheduler.nextFireDate(
            feeds: [],
            threshold: 3 * 3600,
            now: Date()
        ))
    }

    func test_singleFeed_schedulesAtLastFeedPlusThreshold() throws {
        let last = Date(timeIntervalSince1970: 1_800_000_000)
        let feed = try FeedLog(volumeMl: 100, loggedAt: last, source: .bottle)

        let fire = FeedReminderScheduler.nextFireDate(
            feeds: [feed],
            threshold: 3 * 3600,
            now: last.addingTimeInterval(60)
        )

        XCTAssertEqual(fire, last.addingTimeInterval(3 * 3600))
    }

    func test_overdue_stillReturnsLastPlusThreshold() throws {
        let last = Date(timeIntervalSince1970: 1_800_000_000)
        let feed = try FeedLog(volumeMl: 100, loggedAt: last, source: .bottle)

        let fire = FeedReminderScheduler.nextFireDate(
            feeds: [feed],
            threshold: 3 * 3600,
            now: last.addingTimeInterval(5 * 3600)
        )

        XCTAssertEqual(fire, last.addingTimeInterval(3 * 3600))
    }

    func test_multipleFeeds_usesMostRecent() throws {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let older = try FeedLog(volumeMl: 100, loggedAt: t0, source: .bottle)
        let newer = try FeedLog(volumeMl: 120, loggedAt: t0.addingTimeInterval(3600), source: .breast)

        let fire = FeedReminderScheduler.nextFireDate(
            feeds: [older, newer],
            threshold: 2 * 3600,
            now: t0.addingTimeInterval(3700)
        )

        XCTAssertEqual(fire, t0.addingTimeInterval(3600 + 2 * 3600))
    }

    func test_isOverdue_whenNowExceedsLastPlusThreshold() throws {
        let last = Date(timeIntervalSince1970: 1_800_000_000)
        let feed = try FeedLog(volumeMl: 100, loggedAt: last, source: .bottle)

        XCTAssertTrue(FeedReminderScheduler.isOverdue(
            feeds: [feed],
            threshold: 3 * 3600,
            now: last.addingTimeInterval(3 * 3600 + 1)
        ))
        XCTAssertFalse(FeedReminderScheduler.isOverdue(
            feeds: [feed],
            threshold: 3 * 3600,
            now: last.addingTimeInterval(3 * 3600 - 1)
        ))
    }

    func test_isOverdue_emptyFeeds_isFalse() {
        XCTAssertFalse(FeedReminderScheduler.isOverdue(
            feeds: [],
            threshold: 3 * 3600,
            now: Date()
        ))
    }
}

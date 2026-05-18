import XCTest
@testable import LittleE
import LittleECore

// MARK: - Test doubles

private actor SpyFeedReminderNotifier: FeedReminderNotifying {
    private(set) var calls: [(feeds: [FeedLog], threshold: TimeInterval)] = []

    func rescheduleFeedReminder(feeds: [FeedLog], threshold: TimeInterval) async {
        calls.append((feeds, threshold))
    }
}

private actor FailingFeedLogRepository: FeedLogRepository {
    func save(_ feed: FeedLog) async throws { }
    func all() async throws -> [FeedLog] { throw FeedLogError.volumeOutOfRange }
    func delete(id: UUID) async throws { }
}

private actor CallTracker: Sendable {
    private(set) var syncCallCount = 0

    func recordSync() {
        syncCallCount += 1
    }
}

// MARK: - Tests

final class BackgroundFeedRefreshActionTests: XCTestCase {

    private func makeFeed(at date: Date, volumeMl: Int = 120) throws -> FeedLog {
        try FeedLog(
            id: UUID(),
            volumeMl: volumeMl,
            loggedAt: date,
            source: .bottle,
            notes: nil
        )
    }

    // MARK: - Sync is called

    func test_execute_callsSyncExactlyOnce() async {
        let tracker = CallTracker()
        let repo = InMemoryFeedLogRepository()
        let reminder = SpyFeedReminderNotifier()

        let action = BackgroundFeedRefreshAction(
            syncAction: { await tracker.recordSync() },
            feedRepository: repo,
            reminder: reminder,
            reminderThreshold: 3 * 3600,
            clock: TestClock(now: Date())
        )

        _ = await action.execute()

        let count = await tracker.syncCallCount
        XCTAssertEqual(count, 1, "Sync should be called exactly once")
    }

    // MARK: - Reminder rescheduled with fresh feed data

    func test_execute_withFeeds_reschedulesReminderWithAllFeeds() async throws {
        let repo = InMemoryFeedLogRepository()
        let now = Date()
        let feed1 = try makeFeed(at: now.addingTimeInterval(-7200))
        let feed2 = try makeFeed(at: now.addingTimeInterval(-3600))
        try await repo.save(feed1)
        try await repo.save(feed2)

        let reminder = SpyFeedReminderNotifier()
        let threshold: TimeInterval = 3 * 3600

        let action = BackgroundFeedRefreshAction(
            syncAction: { },
            feedRepository: repo,
            reminder: reminder,
            reminderThreshold: threshold,
            clock: TestClock(now: now)
        )

        let result = await action.execute()

        XCTAssertTrue(result, "Should return true when feeds exist")

        let calls = await reminder.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].feeds.count, 2)
        XCTAssertEqual(calls[0].threshold, threshold)
    }

    func test_execute_withFeeds_passesCorrectThreshold() async throws {
        let repo = InMemoryFeedLogRepository()
        try await repo.save(try makeFeed(at: Date()))

        let reminder = SpyFeedReminderNotifier()
        let customThreshold: TimeInterval = 5 * 3600

        let action = BackgroundFeedRefreshAction(
            syncAction: { },
            feedRepository: repo,
            reminder: reminder,
            reminderThreshold: customThreshold,
            clock: TestClock(now: Date())
        )

        _ = await action.execute()

        let calls = await reminder.calls
        XCTAssertEqual(calls[0].threshold, customThreshold)
    }

    // MARK: - No feeds

    func test_execute_withNoFeeds_returnsFalse() async {
        let repo = InMemoryFeedLogRepository()
        let reminder = SpyFeedReminderNotifier()

        let action = BackgroundFeedRefreshAction(
            syncAction: { },
            feedRepository: repo,
            reminder: reminder,
            reminderThreshold: 3 * 3600,
            clock: TestClock(now: Date())
        )

        let result = await action.execute()

        XCTAssertFalse(result, "Should return false when no feeds exist")
    }

    func test_execute_withNoFeeds_stillCallsRescheduleWithEmptyArray() async {
        let repo = InMemoryFeedLogRepository()
        let reminder = SpyFeedReminderNotifier()

        let action = BackgroundFeedRefreshAction(
            syncAction: { },
            feedRepository: repo,
            reminder: reminder,
            reminderThreshold: 3 * 3600,
            clock: TestClock(now: Date())
        )

        _ = await action.execute()

        let calls = await reminder.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertTrue(calls[0].feeds.isEmpty)
    }

    // MARK: - Repository failure

    func test_execute_whenRepositoryThrows_returnsFalse() async {
        let repo = FailingFeedLogRepository()
        let reminder = SpyFeedReminderNotifier()

        let action = BackgroundFeedRefreshAction(
            syncAction: { },
            feedRepository: repo,
            reminder: reminder,
            reminderThreshold: 3 * 3600,
            clock: TestClock(now: Date())
        )

        let result = await action.execute()

        XCTAssertFalse(result, "Should return false when repository throws")
    }

    func test_execute_whenRepositoryThrows_doesNotCallReminder() async {
        let repo = FailingFeedLogRepository()
        let reminder = SpyFeedReminderNotifier()

        let action = BackgroundFeedRefreshAction(
            syncAction: { },
            feedRepository: repo,
            reminder: reminder,
            reminderThreshold: 3 * 3600,
            clock: TestClock(now: Date())
        )

        _ = await action.execute()

        let calls = await reminder.calls
        XCTAssertTrue(calls.isEmpty, "Reminder should not be called when repo fails")
    }

    func test_execute_whenRepositoryThrows_syncStillCalled() async {
        let tracker = CallTracker()
        let repo = FailingFeedLogRepository()
        let reminder = SpyFeedReminderNotifier()

        let action = BackgroundFeedRefreshAction(
            syncAction: { await tracker.recordSync() },
            feedRepository: repo,
            reminder: reminder,
            reminderThreshold: 3 * 3600,
            clock: TestClock(now: Date())
        )

        _ = await action.execute()

        let count = await tracker.syncCallCount
        XCTAssertEqual(count, 1, "Sync should still be called even if repo later fails")
    }

    // MARK: - Sync populates repo before read

    func test_execute_syncPopulatesRepoBeforeReminderReschedule() async throws {
        let repo = InMemoryFeedLogRepository()
        let reminder = SpyFeedReminderNotifier()
        let now = Date()
        let feed = try makeFeed(at: now)

        let action = BackgroundFeedRefreshAction(
            syncAction: {
                try? await repo.save(feed)
            },
            feedRepository: repo,
            reminder: reminder,
            reminderThreshold: 3 * 3600,
            clock: TestClock(now: now)
        )

        let result = await action.execute()

        XCTAssertTrue(result)
        let calls = await reminder.calls
        XCTAssertEqual(calls[0].feeds.count, 1, "Feed added during sync should be visible to reminder")
    }

    // MARK: - Multiple executions

    func test_execute_calledTwice_syncAndReminderCalledTwice() async throws {
        let tracker = CallTracker()
        let repo = InMemoryFeedLogRepository()
        try await repo.save(try makeFeed(at: Date()))
        let reminder = SpyFeedReminderNotifier()

        let action = BackgroundFeedRefreshAction(
            syncAction: { await tracker.recordSync() },
            feedRepository: repo,
            reminder: reminder,
            reminderThreshold: 3 * 3600,
            clock: TestClock(now: Date())
        )

        _ = await action.execute()
        _ = await action.execute()

        let syncCount = await tracker.syncCallCount
        let reminderCalls = await reminder.calls
        XCTAssertEqual(syncCount, 2)
        XCTAssertEqual(reminderCalls.count, 2)
    }

    // MARK: - Feed data integrity

    func test_execute_passesActualFeedDataToReminder() async throws {
        let repo = InMemoryFeedLogRepository()
        let now = Date()
        let recentFeed = try makeFeed(at: now.addingTimeInterval(-1800), volumeMl: 150)
        let olderFeed = try makeFeed(at: now.addingTimeInterval(-7200), volumeMl: 90)
        try await repo.save(recentFeed)
        try await repo.save(olderFeed)

        let reminder = SpyFeedReminderNotifier()

        let action = BackgroundFeedRefreshAction(
            syncAction: { },
            feedRepository: repo,
            reminder: reminder,
            reminderThreshold: 3 * 3600,
            clock: TestClock(now: now)
        )

        _ = await action.execute()

        let calls = await reminder.calls
        let feedIds = Set(calls[0].feeds.map(\.id))
        XCTAssertTrue(feedIds.contains(recentFeed.id))
        XCTAssertTrue(feedIds.contains(olderFeed.id))
    }

    // MARK: - Return value semantics

    func test_execute_withSingleFeed_returnsTrue() async throws {
        let repo = InMemoryFeedLogRepository()
        try await repo.save(try makeFeed(at: Date()))
        let reminder = SpyFeedReminderNotifier()

        let action = BackgroundFeedRefreshAction(
            syncAction: { },
            feedRepository: repo,
            reminder: reminder,
            reminderThreshold: 3 * 3600,
            clock: TestClock(now: Date())
        )

        let result = await action.execute()

        XCTAssertTrue(result)
    }

    func test_execute_withManyFeeds_returnsTrue() async throws {
        let repo = InMemoryFeedLogRepository()
        let now = Date()
        for i in 0..<10 {
            try await repo.save(try makeFeed(at: now.addingTimeInterval(Double(-i) * 3600)))
        }
        let reminder = SpyFeedReminderNotifier()

        let action = BackgroundFeedRefreshAction(
            syncAction: { },
            feedRepository: repo,
            reminder: reminder,
            reminderThreshold: 3 * 3600,
            clock: TestClock(now: now)
        )

        let result = await action.execute()

        XCTAssertTrue(result)
        let calls = await reminder.calls
        XCTAssertEqual(calls[0].feeds.count, 10)
    }
}

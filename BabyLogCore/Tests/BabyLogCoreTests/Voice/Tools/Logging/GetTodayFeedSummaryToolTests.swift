import XCTest
@testable import BabyLogCore

final class GetTodayFeedSummaryToolTests: XCTestCase {

    private var calendar: Calendar { .current }

    func test_noFeedsToday_reportsZero() async throws {
        let repo = InMemoryFeedLogRepository()
        let clock = TestClock(now: date("2026-04-15T14:00:00Z"))
        let tool = GetTodayFeedSummaryTool(repository: repo, clock: clock)

        let result = try await tool.execute(arguments: ToolArguments([:]))

        XCTAssertTrue(result.content.contains("0 feeds"))
        XCTAssertTrue(result.content.contains("0 ml"))
    }

    func test_multipleFeedsToday_sumsCorrectly() async throws {
        let repo = InMemoryFeedLogRepository()
        let now = date("2026-04-15T14:00:00Z")
        let clock = TestClock(now: now)
        let tool = GetTodayFeedSummaryTool(repository: repo, clock: clock)

        // Use times close to `now` so they're unambiguously "today" in any timezone.
        try await repo.save(FeedLog(volumeMl: 60, loggedAt: date("2026-04-15T11:00:00Z"), source: .bottle))
        try await repo.save(FeedLog(volumeMl: 120, loggedAt: date("2026-04-15T12:00:00Z"), source: .bottle))
        try await repo.save(FeedLog(volumeMl: 90, loggedAt: date("2026-04-15T13:00:00Z"), source: .bottle))

        let result = try await tool.execute(arguments: ToolArguments([:]))

        XCTAssertTrue(result.content.contains("3 feeds"), "Got: \(result.content)")
        XCTAssertTrue(result.content.contains("270 ml"), "Got: \(result.content)")
    }

    func test_excludesYesterdayFeeds() async throws {
        let repo = InMemoryFeedLogRepository()
        // Use a time well into the day so "start of today" is unambiguous.
        let now = date("2026-04-15T20:00:00Z")
        let clock = TestClock(now: now)
        let tool = GetTodayFeedSummaryTool(repository: repo, clock: clock)

        // A feed at 01:00 UTC on the 14th is clearly "yesterday" in any timezone.
        try await repo.save(FeedLog(volumeMl: 100, loggedAt: date("2026-04-14T01:00:00Z"), source: .bottle))
        // A feed 1h before now is clearly "today".
        try await repo.save(FeedLog(volumeMl: 80, loggedAt: date("2026-04-15T19:00:00Z"), source: .bottle))

        let result = try await tool.execute(arguments: ToolArguments([:]))

        XCTAssertTrue(result.content.contains("1 feed"), "Got: \(result.content)")
        XCTAssertTrue(result.content.contains("80 ml"), "Got: \(result.content)")
    }

    func test_includesLastFeedTime() async throws {
        let repo = InMemoryFeedLogRepository()
        let now = date("2026-04-15T20:00:00Z")
        let clock = TestClock(now: now)
        let tool = GetTodayFeedSummaryTool(repository: repo, clock: clock)

        try await repo.save(FeedLog(volumeMl: 120, loggedAt: date("2026-04-15T19:30:00Z"), source: .bottle))

        let result = try await tool.execute(arguments: ToolArguments([:]))

        XCTAssertTrue(result.content.contains("last feed at"))
    }

    func test_requiresNoArguments() {
        let tool = GetTodayFeedSummaryTool(
            repository: InMemoryFeedLogRepository(),
            clock: TestClock(now: Date())
        )
        XCTAssertTrue(tool.inputSchema.properties.isEmpty)
        XCTAssertTrue(tool.inputSchema.required.isEmpty)
        XCTAssertFalse(tool.requiresConfirmation)
    }

    // MARK: - Helpers

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }
}

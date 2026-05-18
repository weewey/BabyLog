import XCTest
@testable import LittleECore
import Foundation

final class ListRecentFeedLogsToolTests: XCTestCase {

    private func makeFeed(id: UUID = UUID(), ml: Int, at t: TimeInterval) throws -> FeedLog {
        try FeedLog(
            id: id,
            volumeMl: ml,
            loggedAt: Date(timeIntervalSince1970: t),
            source: .bottle
        )
    }

    func test_listRecentFeedLogs_emptyRepo_returnsEmptyMessage() async throws {
        let tool = ListRecentFeedLogsTool(repository: InMemoryFeedLogRepository())

        let result = try await tool.execute(arguments: ToolArguments())

        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.content, "No feed logs yet.")
    }

    func test_listRecentFeedLogs_returnsEntriesSortedNewestFirst() async throws {
        let repo = InMemoryFeedLogRepository()
        let older = try makeFeed(ml: 90, at: 1_700_000_000)
        let newest = try makeFeed(ml: 120, at: 1_700_010_000)
        let middle = try makeFeed(ml: 100, at: 1_700_005_000)
        try await repo.save(older)
        try await repo.save(newest)
        try await repo.save(middle)
        let tool = ListRecentFeedLogsTool(repository: repo)

        let result = try await tool.execute(arguments: ToolArguments())

        let lines = result.content.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].contains("120 ml"))
        XCTAssertTrue(lines[1].contains("100 ml"))
        XCTAssertTrue(lines[2].contains("90 ml"))
        XCTAssertTrue(lines[0].contains("id=\(newest.id.uuidString)"))
    }

    func test_listRecentFeedLogs_respectsLimit() async throws {
        let repo = InMemoryFeedLogRepository()
        for i in 0..<6 {
            try await repo.save(try makeFeed(ml: 80 + i, at: 1_700_000_000 + Double(i) * 1000))
        }
        let tool = ListRecentFeedLogsTool(repository: repo)

        let result = try await tool.execute(arguments: ToolArguments(["limit": .int(2)]))

        let lines = result.content.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
    }

    func test_listRecentFeedLogs_malformedLimit_fallsBackToDefault() async throws {
        let repo = InMemoryFeedLogRepository()
        for i in 0..<8 {
            try await repo.save(try makeFeed(ml: 80 + i, at: 1_700_000_000 + Double(i) * 1000))
        }
        let tool = ListRecentFeedLogsTool(repository: repo)

        // A string where an int is expected — ToolArguments would normally
        // throw; the list tool should swallow that and apply the default.
        let result = try await tool.execute(arguments: ToolArguments(["limit": .string("lots")]))

        let lines = result.content.split(separator: "\n")
        XCTAssertEqual(lines.count, 5)
    }

    func test_listRecentFeedLogs_zeroLimit_fallsBackToDefault() async throws {
        let repo = InMemoryFeedLogRepository()
        for i in 0..<7 {
            try await repo.save(try makeFeed(ml: 80 + i, at: 1_700_000_000 + Double(i) * 1000))
        }
        let tool = ListRecentFeedLogsTool(repository: repo)

        let result = try await tool.execute(arguments: ToolArguments(["limit": .int(0)]))

        let lines = result.content.split(separator: "\n")
        XCTAssertEqual(lines.count, 5)
    }

    func test_listRecentFeedLogs_doesNotRequireConfirmation() {
        let tool = ListRecentFeedLogsTool(repository: InMemoryFeedLogRepository())
        XCTAssertFalse(tool.requiresConfirmation)
    }
}

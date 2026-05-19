import XCTest
@testable import BabyLogCore
import Foundation

final class DeleteFeedLogToolTests: XCTestCase {

    func test_deleteFeedLog_removesEntryById() async throws {
        let repo = InMemoryFeedLogRepository()
        let id = UUID()
        let feed = try FeedLog(
            id: id,
            volumeMl: 120,
            loggedAt: Date(timeIntervalSince1970: 1_700_000_000),
            source: .bottle
        )
        try await repo.save(feed)
        let tool = DeleteFeedLogTool(repository: repo)
        let args = ToolArguments(["id": .string(id.uuidString)])

        let result = try await tool.execute(arguments: args)

        let remaining = try await repo.all()
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertFalse(result.isError)
    }

    func test_deleteFeedLog_unknownId_throwsExecutionFailed() async {
        let tool = DeleteFeedLogTool(repository: InMemoryFeedLogRepository())
        let args = ToolArguments(["id": .string(UUID().uuidString)])

        do {
            _ = try await tool.execute(arguments: args)
            XCTFail("expected throw")
        } catch let error as ChatToolError {
            if case .executionFailed = error { return }
            XCTFail("expected executionFailed, got \(error)")
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func test_deleteFeedLog_invalidUUID_throwsExecutionFailed() async {
        let tool = DeleteFeedLogTool(repository: InMemoryFeedLogRepository())
        let args = ToolArguments(["id": .string("not-a-uuid")])

        do {
            _ = try await tool.execute(arguments: args)
            XCTFail("expected throw")
        } catch let error as ChatToolError {
            if case .executionFailed = error { return }
            XCTFail("expected executionFailed, got \(error)")
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }
}

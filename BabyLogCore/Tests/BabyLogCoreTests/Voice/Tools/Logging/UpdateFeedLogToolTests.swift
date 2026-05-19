import XCTest
@testable import BabyLogCore
import Foundation

final class UpdateFeedLogToolTests: XCTestCase {

    func test_updateFeedLog_patchesVolumeAndKeepsSource() async throws {
        let repo = InMemoryFeedLogRepository()
        let id = UUID()
        let original = try FeedLog(
            id: id,
            volumeMl: 100,
            loggedAt: Date(timeIntervalSince1970: 1_700_000_000),
            source: .bottle
        )
        try await repo.save(original)
        let tool = UpdateFeedLogTool(repository: repo)
        let args = ToolArguments([
            "id": .string(id.uuidString),
            "volumeMl": .int(150),
        ])

        let result = try await tool.execute(arguments: args)

        let stored = try await repo.all()
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.id, id)
        XCTAssertEqual(stored.first?.volumeMl, 150)
        XCTAssertEqual(stored.first?.source, .bottle)
        XCTAssertFalse(result.isError)
    }

    func test_updateFeedLog_unknownId_throwsExecutionFailed() async {
        let repo = InMemoryFeedLogRepository()
        let tool = UpdateFeedLogTool(repository: repo)
        let args = ToolArguments(["id": .string(UUID().uuidString)])

        do {
            _ = try await tool.execute(arguments: args)
            XCTFail("expected throw")
        } catch let error as ChatToolError {
            if case .executionFailed = error {
                // ok
            } else {
                XCTFail("expected executionFailed, got \(error)")
            }
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func test_updateFeedLog_invalidUUID_throwsExecutionFailed() async {
        let tool = UpdateFeedLogTool(repository: InMemoryFeedLogRepository())
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

    func test_updateFeedLog_doesNotRequireConfirmation() {
        let tool = UpdateFeedLogTool(repository: InMemoryFeedLogRepository())

        XCTAssertFalse(tool.requiresConfirmation)
    }
}

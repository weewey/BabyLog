import XCTest
@testable import BabyLogCore
import Foundation

final class DeleteDiaperLogToolTests: XCTestCase {

    func test_deleteDiaperLog_removesEntryById() async throws {
        let repo = InMemoryDiaperLogRepository()
        let id = UUID()
        let log = try DiaperLog(
            id: id,
            typeRawValue: "wet",
            loggedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try await repo.save(log)
        let tool = DeleteDiaperLogTool(repository: repo)
        let args = ToolArguments(["id": .string(id.uuidString)])

        let result = try await tool.execute(arguments: args)

        let remaining = try await repo.all()
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertFalse(result.isError)
    }

    func test_deleteDiaperLog_unknownId_throwsExecutionFailed() async {
        let tool = DeleteDiaperLogTool(repository: InMemoryDiaperLogRepository())
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

    func test_deleteDiaperLog_invalidUUID_throwsExecutionFailed() async {
        let tool = DeleteDiaperLogTool(repository: InMemoryDiaperLogRepository())
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

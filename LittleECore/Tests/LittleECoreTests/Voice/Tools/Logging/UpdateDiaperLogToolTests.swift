import XCTest
@testable import LittleECore
import Foundation

final class UpdateDiaperLogToolTests: XCTestCase {

    func test_updateDiaperLog_patchesTypeAndKeepsLoggedAt() async throws {
        let repo = InMemoryDiaperLogRepository()
        let id = UUID()
        let loggedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let original = DiaperLog(id: id, type: .wet, loggedAt: loggedAt, notes: "initial")
        try await repo.save(original)
        let tool = UpdateDiaperLogTool(repository: repo)
        let args = ToolArguments([
            "id": .string(id.uuidString),
            "type": .string("dirty"),
        ])

        let result = try await tool.execute(arguments: args)

        let stored = try await repo.all()
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.id, id)
        XCTAssertEqual(stored.first?.type, .dirty)
        XCTAssertEqual(stored.first?.loggedAt, loggedAt)
        XCTAssertEqual(stored.first?.notes, "initial")
        XCTAssertFalse(result.isError)
    }

    func test_updateDiaperLog_patchesAllFields() async throws {
        let repo = InMemoryDiaperLogRepository()
        let id = UUID()
        try await repo.save(DiaperLog(
            id: id,
            type: .wet,
            loggedAt: Date(timeIntervalSince1970: 1_700_000_000),
            notes: nil
        ))
        let tool = UpdateDiaperLogTool(repository: repo)
        let newDate = "2026-04-13T10:30:00Z"
        let args = ToolArguments([
            "id": .string(id.uuidString),
            "type": .string("both"),
            "loggedAt": .string(newDate),
            "notes": .string("updated"),
        ])

        _ = try await tool.execute(arguments: args)

        let stored = try await repo.all()
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.type, .both)
        XCTAssertEqual(stored.first?.notes, "updated")
        XCTAssertEqual(
            stored.first?.loggedAt,
            ISO8601DateFormatter().date(from: newDate)
        )
    }

    func test_updateDiaperLog_unknownId_throwsExecutionFailed() async {
        let repo = InMemoryDiaperLogRepository()
        let tool = UpdateDiaperLogTool(repository: repo)
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

    func test_updateDiaperLog_invalidUUID_throwsExecutionFailed() async {
        let tool = UpdateDiaperLogTool(repository: InMemoryDiaperLogRepository())
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

import XCTest
@testable import BabyLogCore
import Foundation

final class UpdateMilestoneToolTests: XCTestCase {

    func test_updateMilestone_patchesTitleAndKeepsOthers() async throws {
        let repo = InMemoryMilestoneRepository()
        let id = UUID()
        let achievedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let original = try Milestone(id: id, title: "First smile", achievedAt: achievedAt, notes: "so cute")
        try await repo.save(original)
        let tool = UpdateMilestoneTool(repository: repo)
        let args = ToolArguments([
            "id": .string(id.uuidString),
            "title": .string("First giggle"),
        ])

        _ = try await tool.execute(arguments: args)

        let stored = try await repo.all()
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.id, id)
        XCTAssertEqual(stored.first?.title, "First giggle")
        XCTAssertEqual(stored.first?.achievedAt, achievedAt)
        XCTAssertEqual(stored.first?.notes, "so cute")
    }

    func test_updateMilestone_patchesAllFields() async throws {
        let repo = InMemoryMilestoneRepository()
        let id = UUID()
        let original = try Milestone(
            id: id,
            title: "First smile",
            achievedAt: Date(timeIntervalSince1970: 1_700_000_000),
            notes: nil
        )
        try await repo.save(original)
        let tool = UpdateMilestoneTool(repository: repo)
        let newDate = "2026-04-13T10:30:00Z"
        let args = ToolArguments([
            "id": .string(id.uuidString),
            "title": .string("First steps"),
            "achievedAt": .string(newDate),
            "notes": .string("walking!"),
        ])

        _ = try await tool.execute(arguments: args)

        let stored = try await repo.all()
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.title, "First steps")
        XCTAssertEqual(stored.first?.notes, "walking!")
        XCTAssertEqual(
            stored.first?.achievedAt,
            ISO8601DateFormatter().date(from: newDate)
        )
    }

    func test_updateMilestone_unknownId_throwsExecutionFailed() async {
        let tool = UpdateMilestoneTool(repository: InMemoryMilestoneRepository())
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

    func test_updateMilestone_invalidUUID_throwsExecutionFailed() async {
        let tool = UpdateMilestoneTool(repository: InMemoryMilestoneRepository())
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

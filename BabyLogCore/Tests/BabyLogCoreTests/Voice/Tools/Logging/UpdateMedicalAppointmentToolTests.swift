import XCTest
@testable import BabyLogCore
import Foundation

final class UpdateMedicalAppointmentToolTests: XCTestCase {

    func test_updateMedicalAppointment_patchesTitleAndKeepsOtherFields() async throws {
        let repo = InMemoryMedicalAppointmentRepository()
        let id = UUID()
        let original = try MedicalAppointment(
            id: id,
            title: "Old title",
            scheduledAt: Date(timeIntervalSince1970: 1_700_000_000),
            location: "Clinic A",
            notes: "Bring red book"
        )
        try await repo.save(original)
        let tool = UpdateMedicalAppointmentTool(repository: repo)
        let args = ToolArguments([
            "id": .string(id.uuidString),
            "title": .string("New title"),
        ])

        let result = try await tool.execute(arguments: args)

        let stored = try await repo.all()
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.id, id)
        XCTAssertEqual(stored.first?.title, "New title")
        XCTAssertEqual(stored.first?.location, "Clinic A")
        XCTAssertEqual(stored.first?.notes, "Bring red book")
        XCTAssertEqual(stored.first?.scheduledAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertFalse(result.isError)
    }

    func test_updateMedicalAppointment_unknownId_throwsExecutionFailed() async {
        let repo = InMemoryMedicalAppointmentRepository()
        let tool = UpdateMedicalAppointmentTool(repository: repo)
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

    func test_updateMedicalAppointment_invalidUUID_throwsExecutionFailed() async {
        let tool = UpdateMedicalAppointmentTool(repository: InMemoryMedicalAppointmentRepository())
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

    func test_updateMedicalAppointment_doesNotRequireConfirmation() {
        let tool = UpdateMedicalAppointmentTool(repository: InMemoryMedicalAppointmentRepository())

        XCTAssertFalse(tool.requiresConfirmation)
    }
}

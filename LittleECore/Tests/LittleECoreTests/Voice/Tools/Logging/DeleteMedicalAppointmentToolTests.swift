import XCTest
@testable import LittleECore
import Foundation

final class DeleteMedicalAppointmentToolTests: XCTestCase {

    func test_deleteMedicalAppointment_removesEntryById() async throws {
        let repo = InMemoryMedicalAppointmentRepository()
        let id = UUID()
        let appointment = try MedicalAppointment(
            id: id,
            title: "Check-up",
            scheduledAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try await repo.save(appointment)
        let tool = DeleteMedicalAppointmentTool(repository: repo)
        let args = ToolArguments(["id": .string(id.uuidString)])

        let result = try await tool.execute(arguments: args)

        let remaining = try await repo.all()
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertFalse(result.isError)
    }

    func test_deleteMedicalAppointment_unknownId_throwsExecutionFailed() async {
        let tool = DeleteMedicalAppointmentTool(repository: InMemoryMedicalAppointmentRepository())
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

    func test_deleteMedicalAppointment_invalidUUID_throwsExecutionFailed() async {
        let tool = DeleteMedicalAppointmentTool(repository: InMemoryMedicalAppointmentRepository())
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

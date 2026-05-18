import XCTest
@testable import LittleECore
import Foundation

final class CreateMedicalAppointmentToolTests: XCTestCase {

    func test_createMedicalAppointment_happyPath_savesEntryAndReturnsId() async throws {
        let repo = InMemoryMedicalAppointmentRepository()
        let tool = CreateMedicalAppointmentTool(repository: repo)
        let args = ToolArguments([
            "title": .string("6-month check-up"),
            "scheduledAt": .string("2026-05-01T10:00:00Z"),
            "location": .string("Dr Tan's clinic"),
        ])

        let result = try await tool.execute(arguments: args)

        let stored = try await repo.all()
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.title, "6-month check-up")
        XCTAssertEqual(stored.first?.location, "Dr Tan's clinic")
        XCTAssertFalse(result.isError)
        let savedId = try XCTUnwrap(stored.first?.id)
        XCTAssertTrue(
            result.content.contains("id=\(savedId.uuidString)"),
            "expected result content to embed saved id, got: \(result.content)"
        )
    }

    func test_createMedicalAppointment_missingTitle_throwsToolArgumentsError() async {
        let tool = CreateMedicalAppointmentTool(repository: InMemoryMedicalAppointmentRepository())
        let args = ToolArguments(["scheduledAt": .string("2026-05-01T10:00:00Z")])

        do {
            _ = try await tool.execute(arguments: args)
            XCTFail("expected throw")
        } catch let error as ToolArgumentsError {
            XCTAssertEqual(error, .missing(key: "title"))
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func test_createMedicalAppointment_missingScheduledAt_throwsToolArgumentsError() async {
        let tool = CreateMedicalAppointmentTool(repository: InMemoryMedicalAppointmentRepository())
        let args = ToolArguments(["title": .string("Check-up")])

        do {
            _ = try await tool.execute(arguments: args)
            XCTFail("expected throw")
        } catch let error as ToolArgumentsError {
            XCTAssertEqual(error, .missing(key: "scheduledAt"))
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func test_createMedicalAppointment_doesNotRequireConfirmation() {
        let tool = CreateMedicalAppointmentTool(repository: InMemoryMedicalAppointmentRepository())

        XCTAssertFalse(tool.requiresConfirmation)
    }
}

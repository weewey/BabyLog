import XCTest
@testable import BabyLogCore
import Foundation

final class ListRecentMedicalAppointmentsToolTests: XCTestCase {

    private func makeAppointment(
        id: UUID = UUID(),
        title: String,
        at t: TimeInterval,
        location: String? = nil
    ) throws -> MedicalAppointment {
        try MedicalAppointment(
            id: id,
            title: title,
            scheduledAt: Date(timeIntervalSince1970: t),
            location: location
        )
    }

    func test_listRecentMedicalAppointments_emptyRepo_returnsEmptyMessage() async throws {
        let tool = ListRecentMedicalAppointmentsTool(repository: InMemoryMedicalAppointmentRepository())

        let result = try await tool.execute(arguments: ToolArguments())

        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.content, "No medical appointments yet.")
    }

    func test_listRecentMedicalAppointments_returnsEntriesSortedNewestFirst() async throws {
        let repo = InMemoryMedicalAppointmentRepository()
        let older = try makeAppointment(title: "Past", at: 1_700_000_000)
        let newest = try makeAppointment(title: "Future", at: 1_700_010_000, location: "Clinic B")
        let middle = try makeAppointment(title: "Middle", at: 1_700_005_000)
        try await repo.save(older)
        try await repo.save(newest)
        try await repo.save(middle)
        let tool = ListRecentMedicalAppointmentsTool(repository: repo)

        let result = try await tool.execute(arguments: ToolArguments())

        let lines = result.content.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].contains("Future"))
        XCTAssertTrue(lines[0].contains("id=\(newest.id.uuidString)"))
        XCTAssertTrue(lines[0].contains("Clinic B"))
        XCTAssertTrue(lines[1].contains("Middle"))
        XCTAssertTrue(lines[2].contains("Past"))
    }

    func test_listRecentMedicalAppointments_respectsLimit() async throws {
        let repo = InMemoryMedicalAppointmentRepository()
        for i in 0..<6 {
            try await repo.save(
                try makeAppointment(
                    title: "Appt \(i)",
                    at: 1_700_000_000 + Double(i) * 1000
                )
            )
        }
        let tool = ListRecentMedicalAppointmentsTool(repository: repo)

        let result = try await tool.execute(arguments: ToolArguments(["limit": .int(2)]))

        let lines = result.content.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
    }

    func test_listRecentMedicalAppointments_doesNotRequireConfirmation() {
        let tool = ListRecentMedicalAppointmentsTool(repository: InMemoryMedicalAppointmentRepository())
        XCTAssertFalse(tool.requiresConfirmation)
    }
}

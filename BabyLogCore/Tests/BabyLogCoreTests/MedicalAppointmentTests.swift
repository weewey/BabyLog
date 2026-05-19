import XCTest
@testable import BabyLogCore
import Foundation

final class MedicalAppointmentTests: XCTestCase {

    func test_init_trimsTitleAndAccepts() throws {
        let appt = try MedicalAppointment(title: "  Pediatrician  ", scheduledAt: Date())
        XCTAssertEqual(appt.title, "Pediatrician")
    }

    func test_init_emptyTitleThrows() {
        XCTAssertThrowsError(try MedicalAppointment(title: "   ", scheduledAt: Date())) { error in
            XCTAssertEqual(error as? MedicalAppointmentError, .emptyTitle)
        }
    }

    func test_init_emptyLocationBecomesNil() throws {
        let appt = try MedicalAppointment(title: "Checkup", scheduledAt: Date(), location: "   ")
        XCTAssertNil(appt.location)
    }

    func test_repository_saveAllDeleteRoundTrip() async throws {
        let repo = InMemoryMedicalAppointmentRepository()
        let earlier = try MedicalAppointment(title: "A", scheduledAt: Date(timeIntervalSince1970: 100))
        let later = try MedicalAppointment(title: "B", scheduledAt: Date(timeIntervalSince1970: 200))

        try await repo.save(later)
        try await repo.save(earlier)

        let all = try await repo.all()
        XCTAssertEqual(all.map(\.title), ["A", "B"])

        try await repo.delete(id: earlier.id)
        let remaining = try await repo.all()
        XCTAssertEqual(remaining.map(\.title), ["B"])
    }
}

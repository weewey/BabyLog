import XCTest
@testable import BabyLogCore
import Foundation

final class MilestoneTests: XCTestCase {

    func test_init_emptyTitleThrows() {
        XCTAssertThrowsError(try Milestone(title: "  ", achievedAt: Date())) { err in
            XCTAssertEqual(err as? MilestoneError, .emptyTitle)
        }
    }

    func test_init_trimsNotes() throws {
        let m = try Milestone(title: "First smile", achievedAt: Date(), notes: "   ")
        XCTAssertNil(m.notes)
    }

    func test_repository_allReturnsNewestFirstAndDelete() async throws {
        let repo = InMemoryMilestoneRepository()
        let old = try Milestone(title: "A", achievedAt: Date(timeIntervalSince1970: 1_000))
        let recent = try Milestone(title: "B", achievedAt: Date(timeIntervalSince1970: 5_000))

        try await repo.save(old)
        try await repo.save(recent)

        let titles1 = try await repo.all().map(\.title)
        XCTAssertEqual(titles1, ["B", "A"])

        try await repo.delete(id: recent.id)
        let titles2 = try await repo.all().map(\.title)
        XCTAssertEqual(titles2, ["A"])
    }
}

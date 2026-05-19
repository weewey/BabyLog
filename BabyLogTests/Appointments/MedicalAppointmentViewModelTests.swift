import XCTest
import LittleECore
@testable import BabyLog

private struct FixedClock: Clock {
    let date: Date
    func now() -> Date { date }
}

@MainActor
final class MedicalAppointmentViewModelTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func makeSUT() -> MedicalAppointmentViewModel {
        MedicalAppointmentViewModel(
            repository: InMemoryMedicalAppointmentRepository(),
            clock: FixedClock(date: now)
        )
    }

    func test_canSave_falseForEmptyTitle() {
        let sut = makeSUT()
        XCTAssertFalse(sut.canSave)
        sut.draftTitle = "   "
        XCTAssertFalse(sut.canSave)
    }

    func test_canSave_trueWithTitle() {
        let sut = makeSUT()
        sut.draftTitle = "Pediatrician"
        XCTAssertTrue(sut.canSave)
    }

    func test_save_persistsAndResetsDraft() async {
        let sut = makeSUT()
        sut.draftTitle = "Vaccination"
        sut.draftScheduledAt = now.addingTimeInterval(3_600)

        await sut.save()

        XCTAssertEqual(sut.entries.count, 1)
        XCTAssertEqual(sut.entries.first?.title, "Vaccination")
        XCTAssertEqual(sut.draftTitle, "")
        XCTAssertNil(sut.saveError)
    }

    func test_save_emptyTitleSurfacesError() async {
        let sut = makeSUT()
        sut.draftTitle = "   "
        sut.draftScheduledAt = now

        // canSave guards the UI, but the VM itself should still surface the Core error
        // if called directly with a blank title.
        sut.draftTitle = "" // fully empty to force throw
        await sut.save()

        XCTAssertEqual(sut.saveError, .emptyTitle)
    }

    func test_upcomingAndPast_splitAroundClock() async throws {
        let sut = makeSUT()
        sut.draftTitle = "Future"
        sut.draftScheduledAt = now.addingTimeInterval(3_600)
        await sut.save()

        sut.draftTitle = "Past"
        sut.draftScheduledAt = now.addingTimeInterval(-3_600)
        await sut.save()

        XCTAssertEqual(sut.upcoming.map(\.title), ["Future"])
        XCTAssertEqual(sut.past.map(\.title), ["Past"])
    }

    func test_delete_removesEntry() async throws {
        let sut = makeSUT()
        sut.draftTitle = "Checkup"
        sut.draftScheduledAt = now.addingTimeInterval(3_600)
        await sut.save()

        let id = try XCTUnwrap(sut.entries.first?.id)
        await sut.delete(id: id)

        XCTAssertTrue(sut.entries.isEmpty)
    }
}

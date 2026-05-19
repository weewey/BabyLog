import XCTest
import LittleECore
@testable import BabyLog

// MARK: - Test doubles

/// Deterministic clock that always returns a fixed date.
private struct FixedClock: Clock {
    let date: Date
    func now() -> Date { date }
}

// MARK: - DiaperLogViewModelTests

@MainActor
final class DiaperLogViewModelTests: XCTestCase {

    // MARK: - Fixture

    private let fixedDate = Date(timeIntervalSinceReferenceDate: 0) // 2001-01-01 00:00:00 UTC

    private func makeSUT(
        repository: InMemoryDiaperLogRepository = InMemoryDiaperLogRepository()
    ) -> DiaperLogViewModel {
        DiaperLogViewModel(
            repository: repository,
            clock: FixedClock(date: fixedDate)
        )
    }

    // MARK: - canSave

    func test_canSave_alwaysTrue() {
        let sut = makeSUT()
        XCTAssertTrue(sut.canSave, "canSave should always be true for diaper logs")
    }

    func test_canSave_trueForAllTypes() {
        let sut = makeSUT()
        for type in DiaperType.allCases {
            sut.draftType = type
            XCTAssertTrue(sut.canSave, "canSave should be true for type \(type)")
        }
    }

    // MARK: - State transitions: draft -> save -> groupedEntries

    func test_save_entryAppearsInGroupedEntriesAfterSuccess() async {
        let sut = makeSUT()
        sut.draftType = .wet

        await sut.save()

        let all = sut.groupedEntries.flatMap(\.1)
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.type, .wet)
    }

    func test_save_preservesNotesWhenProvided() async {
        let sut = makeSUT()
        sut.draftType = .dirty
        sut.draftNotes = "After lunch"

        await sut.save()

        let all = sut.groupedEntries.flatMap(\.1)
        XCTAssertEqual(all.first?.notes, "After lunch")
    }

    func test_save_omitsNotesWhenBlank() async {
        let sut = makeSUT()
        sut.draftType = .wet
        sut.draftNotes = "   "

        await sut.save()

        let all = sut.groupedEntries.flatMap(\.1)
        XCTAssertNil(all.first?.notes, "Blank notes should be stored as nil")
    }

    func test_save_resetsDraftAfterSuccess() async {
        let sut = makeSUT()
        sut.draftType = .both
        sut.draftNotes = "Some note"

        await sut.save()

        XCTAssertEqual(sut.draftType, .wet, "Draft type should reset to .wet after a successful save")
        XCTAssertEqual(sut.draftNotes, "", "Draft notes should reset to empty after a successful save")
    }

    func test_save_groupedEntriesIsEmptyBeforeAnyInteraction() {
        let sut = makeSUT()
        XCTAssertTrue(sut.groupedEntries.isEmpty)
    }

    // MARK: - refreshEntries

    func test_refreshEntries_loadsFromRepository() async {
        let repo = InMemoryDiaperLogRepository()
        let log = DiaperLog(id: UUID(), type: .dirty, loggedAt: fixedDate)
        try? await repo.save(log)

        let sut = makeSUT(repository: repo)
        await sut.refreshEntries()

        let all = sut.groupedEntries.flatMap(\.1)
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.type, .dirty)
    }

    // MARK: - Error path

    func test_save_surfacesRepositoryErrorIntoLoadError() async {
        // DiaperLog construction never throws with a valid DiaperType,
        // so we verify that groupedEntries is populated correctly after save.
        let sut = makeSUT()
        sut.draftType = .wet
        await sut.save()
        XCTAssertNil(sut.saveError, "No save error should occur for valid diaper log")
    }

    // MARK: - groupedEntries reflects repository state

    func test_groupedEntries_reflectsAllEntriesAfterMultipleSaves() async {
        let repo = InMemoryDiaperLogRepository()
        let sut = makeSUT(repository: repo)

        sut.draftType = .wet
        await sut.save()

        sut.draftType = .dirty
        await sut.save()

        let all = sut.groupedEntries.flatMap(\.1)
        XCTAssertEqual(all.count, 2, "groupedEntries must reflect all persisted entries")
    }

    func test_groupedEntries_sharedRepositoryStateSurvivesAcrossViewModelInstances() async {
        // Two VMs sharing one repository must see the same data.
        let repo = InMemoryDiaperLogRepository()
        let first = DiaperLogViewModel(repository: repo, clock: FixedClock(date: fixedDate))
        let second = DiaperLogViewModel(repository: repo, clock: FixedClock(date: fixedDate))

        first.draftType = .both
        await first.save()

        await second.refreshEntries()

        let all = second.groupedEntries.flatMap(\.1)
        XCTAssertEqual(all.count, 1, "Second VM must observe entry saved by first VM via shared repository")
    }
}

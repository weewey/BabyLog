import XCTest
import BabyLogCore
@testable import BabyLog

private struct FixedClock: Clock {
    let date: Date
    func now() -> Date { date }
}

@MainActor
final class GrowthMeasurementViewModelTests: XCTestCase {

    private let fixedDate = Date(timeIntervalSinceReferenceDate: 0)

    private func makeSUT() -> (GrowthMeasurementViewModel, InMemoryGrowthMeasurementRepository) {
        let repo = InMemoryGrowthMeasurementRepository()
        let vm = GrowthMeasurementViewModel(repository: repo, clock: FixedClock(date: fixedDate))
        return (vm, repo)
    }

    func test_canSave_falseWhenAllFieldsNil() {
        let (sut, _) = makeSUT()
        XCTAssertFalse(sut.canSave)
    }

    func test_canSave_trueWhenWeightProvided() {
        let (sut, _) = makeSUT()
        sut.draftWeightGrams = 4_500
        XCTAssertTrue(sut.canSave)
    }

    func test_canSave_falseWhenWeightOutOfRange() {
        let (sut, _) = makeSUT()
        sut.draftWeightGrams = 100
        XCTAssertFalse(sut.canSave)
    }

    func test_save_persistsAndRefreshes() async throws {
        let (sut, _) = makeSUT()
        sut.draftWeightGrams = 4_500
        sut.draftHeightCm = 55.0

        await sut.save()

        XCTAssertEqual(sut.entries.count, 1)
        XCTAssertEqual(sut.entries.first?.weightGrams, 4_500)
        XCTAssertNil(sut.saveError)
    }

    func test_save_resetsDraftAfterSuccess() async throws {
        let (sut, _) = makeSUT()
        sut.draftWeightGrams = 4_500
        sut.draftNotes = "2-week checkup"

        await sut.save()

        XCTAssertNil(sut.draftWeightGrams)
        XCTAssertEqual(sut.draftNotes, "")
    }

    func test_save_surfacesCoreValidationError() async {
        let (sut, _) = makeSUT()
        sut.draftWeightGrams = 100_000 // out of range

        await sut.save()

        XCTAssertEqual(sut.saveError, .weightOutOfRange(100_000))
        XCTAssertTrue(sut.entries.isEmpty)
    }

    func test_summary_reflectsCoreAnalyticsForRepositoryEntries() async throws {
        let repo = InMemoryGrowthMeasurementRepository()
        let latestDate = fixedDate
        let priorDate = fixedDate.addingTimeInterval(-8 * 86_400)
        try await repo.save(GrowthMeasurement(date: priorDate, weightGrams: 8_080))
        try await repo.save(GrowthMeasurement(date: latestDate, weightGrams: 8_200))

        let sut = GrowthMeasurementViewModel(repository: repo, clock: FixedClock(date: fixedDate))
        await sut.refreshEntries()

        XCTAssertEqual(sut.summary.latestWeightGrams, 8_200)
        XCTAssertEqual(sut.summary.weightDeltaGramsLastWeek, 120)
    }

    func test_refreshEntries_loadsFromRepository() async throws {
        let repo = InMemoryGrowthMeasurementRepository()
        let seeded = try GrowthMeasurement(date: fixedDate, weightGrams: 4_000)
        try await repo.save(seeded)

        let sut = GrowthMeasurementViewModel(repository: repo, clock: FixedClock(date: fixedDate))
        await sut.refreshEntries()

        XCTAssertEqual(sut.entries.count, 1)
    }
}

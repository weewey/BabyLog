import XCTest
import BabyLogCore
@testable import BabyLog

private struct FixedClock: Clock {
    let date: Date
    func now() -> Date { date }
}

@MainActor
final class PumpingViewModelTests: XCTestCase {

    // MARK: - Fixture

    /// 2026-04-14 12:00:00 UTC — deterministic midday anchor.
    private let fixedDate = Date(timeIntervalSince1970: 1_776_513_600)

    private func makeSUT(
        repository: InMemoryPumpingSessionRepository = InMemoryPumpingSessionRepository()
    ) -> PumpingViewModel {
        PumpingViewModel(
            repository: repository,
            clock: FixedClock(date: fixedDate),
            template: .medelaEightSessionNewborn
        )
    }

    // MARK: - canSave

    func test_canSave_trueForDefaultDraft() {
        let sut = makeSUT()
        XCTAssertTrue(sut.canSave, "Default draft has valid 20-min duration")
    }

    func test_canSave_falseForZeroDuration() {
        let sut = makeSUT()
        sut.draftDurationMinutes = 0
        XCTAssertFalse(sut.canSave)
    }

    func test_canSave_falseForDurationAboveMax() {
        let sut = makeSUT()
        sut.draftDurationMinutes = 121
        XCTAssertFalse(sut.canSave)
    }

    // MARK: - save happy path

    func test_save_appendsEntryToSessions() async {
        let sut = makeSUT()
        sut.draftDurationMinutes = 25
        sut.draftMilkVolumeMl = 90

        await sut.save()

        XCTAssertEqual(sut.sessions.count, 1)
        XCTAssertEqual(sut.sessions.first?.durationMinutes, 25)
        XCTAssertEqual(sut.sessions.first?.milkVolumeMl, 90)
    }

    func test_save_recomputesSummaryAfterSuccess() async {
        let sut = makeSUT()
        XCTAssertEqual(sut.summary.sessionsLoggedToday, 0)

        sut.draftDurationMinutes = 20
        await sut.save()

        XCTAssertEqual(sut.summary.sessionsLoggedToday, 1)
        XCTAssertEqual(sut.summary.targetSessionsPerDay, 8)
    }

    func test_save_resetsDraftAfterSuccess() async {
        let sut = makeSUT()
        sut.draftDurationMinutes = 30
        sut.draftMilkVolumeMl = 120
        sut.draftNotes = "Hands-on"

        await sut.save()

        XCTAssertEqual(sut.draftDurationMinutes, 20, "Default duration restored")
        XCTAssertEqual(sut.draftMilkVolumeMl, 0)
        XCTAssertEqual(sut.draftNotes, "")
    }

    // MARK: - save error path

    func test_save_surfacesDurationOutOfRange() async {
        let sut = makeSUT()
        sut.draftDurationMinutes = 200

        await sut.save()

        XCTAssertEqual(sut.saveError, .durationOutOfRange)
        XCTAssertTrue(sut.sessions.isEmpty)
    }

    func test_save_clearsSaveErrorOnSubsequentSuccess() async {
        let sut = makeSUT()
        sut.draftDurationMinutes = 200
        await sut.save()
        XCTAssertNotNil(sut.saveError)

        sut.draftDurationMinutes = 20
        await sut.save()

        XCTAssertNil(sut.saveError)
    }

    // MARK: - update

    func test_update_replacesExistingSessionInRepository() async throws {
        let repo = InMemoryPumpingSessionRepository()
        let original = try PumpingSession(
            startedAt: fixedDate.addingTimeInterval(-3600),
            durationMinutes: 20,
            side: .left,
            milkVolumeMl: 80
        )
        try await repo.save(original)

        let sut = makeSUT(repository: repo)
        await sut.load()
        sut.beginEditing(original)
        sut.draftMilkVolumeMl = 150

        await sut.update()

        XCTAssertEqual(sut.sessions.count, 1, "Update must not duplicate")
        XCTAssertEqual(sut.sessions.first?.milkVolumeMl, 150)
        XCTAssertNil(sut.editingId, "Draft resets after successful update")
    }

    // MARK: - delete

    func test_delete_removesSessionAndRecomputesSummary() async {
        let sut = makeSUT()
        sut.draftDurationMinutes = 20
        await sut.save()
        let id = try? XCTUnwrap(sut.sessions.first?.id)

        if let id {
            await sut.delete(id: id)
        }

        XCTAssertTrue(sut.sessions.isEmpty)
        XCTAssertEqual(sut.summary.sessionsLoggedToday, 0)
    }

    // MARK: - load

    func test_load_fetchesAllEntriesFromRepository() async throws {
        let repo = InMemoryPumpingSessionRepository()
        let session = try PumpingSession(startedAt: fixedDate, durationMinutes: 15)
        try await repo.save(session)

        let sut = makeSUT(repository: repo)
        await sut.load()

        XCTAssertEqual(sut.sessions.count, 1)
    }

    // MARK: - tipOfDay

    func test_tipOfDay_returnsNonEmptyStringFromTemplateRotation() {
        let sut = makeSUT()
        XCTAssertFalse(sut.tipOfDay.isEmpty)
        XCTAssertTrue(PumpingScheduleTemplate.tipsRotation.contains(sut.tipOfDay))
    }

    // MARK: - History window + trend series

    /// Build a session N days before `fixedDate` at a given hour. Uses the
    /// ViewModel's own calendar (`.current`) so the grouping lines up with
    /// what `PumpingAnalytics.dailyHistory` will see.
    private func sessionDaysAgo(
        _ days: Int, hour: Int = 9, durationMinutes: Int = 20, volumeMl: Int? = 100
    ) throws -> PumpingSession {
        let cal = Calendar.current
        let startOfFixed = cal.startOfDay(for: fixedDate)
        let target = cal.date(byAdding: .day, value: -days, to: startOfFixed)!
        let withHour = cal.date(bySettingHour: hour, minute: 0, second: 0, of: target)!
        return try PumpingSession(
            startedAt: withHour,
            durationMinutes: durationMinutes,
            milkVolumeMl: volumeMl
        )
    }

    func test_history_defaultWindowIs30Days() async throws {
        let repo = InMemoryPumpingSessionRepository()
        // One session inside window (5 days ago) and one outside (45 days ago).
        try await repo.save(try sessionDaysAgo(5, volumeMl: 100))
        try await repo.save(try sessionDaysAgo(45, volumeMl: 200))

        let sut = makeSUT(repository: repo)
        await sut.load()

        XCTAssertEqual(sut.visibleHistoryDays, 30)
        XCTAssertEqual(sut.history.count, 1)
        XCTAssertEqual(sut.history.first?.totalVolumeMl, 100)
        XCTAssertTrue(sut.hasMoreHistory, "Older session exists → load-more available")
    }

    func test_loadMoreHistory_extendsWindowInThirtyDayStrides() async throws {
        let repo = InMemoryPumpingSessionRepository()
        try await repo.save(try sessionDaysAgo(5,  volumeMl: 100))
        try await repo.save(try sessionDaysAgo(45, volumeMl: 200))
        try await repo.save(try sessionDaysAgo(75, volumeMl: 300))

        let sut = makeSUT(repository: repo)
        await sut.load()
        XCTAssertEqual(sut.history.count, 1)

        sut.loadMoreHistory()
        XCTAssertEqual(sut.visibleHistoryDays, 60)
        XCTAssertEqual(sut.history.count, 2)
        XCTAssertTrue(sut.hasMoreHistory)

        sut.loadMoreHistory()
        XCTAssertEqual(sut.visibleHistoryDays, 90)
        XCTAssertEqual(sut.history.count, 3)
        XCTAssertFalse(sut.hasMoreHistory, "No sessions older than 90 days")
    }

    func test_history_groupsMultipleSessionsOnSameDay() async throws {
        let repo = InMemoryPumpingSessionRepository()
        try await repo.save(try sessionDaysAgo(2, hour: 8,  volumeMl: 60))
        try await repo.save(try sessionDaysAgo(2, hour: 14, volumeMl: 90))
        try await repo.save(try sessionDaysAgo(3, hour: 10, volumeMl: 120))

        let sut = makeSUT(repository: repo)
        await sut.load()

        XCTAssertEqual(sut.history.count, 2)
        XCTAssertEqual(sut.history[0].totalVolumeMl, 150)
        XCTAssertEqual(sut.history[0].sessions.count, 2)
        XCTAssertEqual(sut.history[1].totalVolumeMl, 120)
    }

    func test_trendSeries30d_returns30PointsEndingToday() async {
        let sut = makeSUT()
        await sut.load()

        XCTAssertEqual(sut.trendSeries30d.count, 30)
        let today = Calendar.current.startOfDay(for: fixedDate)
        XCTAssertEqual(sut.trendSeries30d.last?.day, today)
    }

    func test_trendSeries30d_zeroFillsWhenNoSessions() async {
        let sut = makeSUT()
        await sut.load()

        XCTAssertTrue(sut.trendSeries30d.allSatisfy { $0.totalVolumeMl == 0 })
    }

    func test_hasMoreHistory_falseWhenNoSessions() async {
        let sut = makeSUT()
        await sut.load()
        XCTAssertFalse(sut.hasMoreHistory)
    }
}

import XCTest
import BabyLogCore
@testable import BabyLog

// MARK: - Test doubles

/// Deterministic clock that always returns a fixed date.
private struct FixedClock: Clock {
    let date: Date
    func now() -> Date { date }
}

// MARK: - FeedLogViewModelTests

@MainActor
final class FeedLogViewModelTests: XCTestCase {

    // MARK: - Fixture

    private let fixedDate = Date(timeIntervalSinceReferenceDate: 0) // 2001-01-01 00:00:00 UTC

    private func makeSUT(
        repository: InMemoryFeedLogRepository = InMemoryFeedLogRepository()
    ) -> FeedLogViewModel {
        FeedLogViewModel(
            repository: repository,
            clock: FixedClock(date: fixedDate)
        )
    }

    // MARK: - canSave boundary

    func test_canSave_falseForDefaultDraftVolume() {
        // Default draftVolume is 0 — below valid range.
        let sut = makeSUT()
        XCTAssertFalse(sut.canSave, "Zero volume should fail Core validation")
    }

    func test_canSave_falseForNegativeVolume() {
        let sut = makeSUT()
        sut.draftVolume = -1
        XCTAssertFalse(sut.canSave, "Negative volume should fail Core validation")
    }

    func test_canSave_trueForValidVolume() {
        let sut = makeSUT()
        sut.draftVolume = 120
        XCTAssertTrue(sut.canSave, "120 ml is within the valid range")
    }

    func test_canSave_trueForLowerBound() {
        let sut = makeSUT()
        sut.draftVolume = 1
        XCTAssertTrue(sut.canSave, "1 ml is the valid lower bound")
    }

    func test_canSave_trueForUpperBound() {
        let sut = makeSUT()
        sut.draftVolume = 500
        XCTAssertTrue(sut.canSave, "500 ml is the valid upper bound")
    }

    func test_canSave_falseForAboveUpperBound() {
        let sut = makeSUT()
        sut.draftVolume = 501
        XCTAssertFalse(sut.canSave, "501 ml exceeds the valid upper bound")
    }

    // MARK: - State transitions: draft → save → groupedEntries

    func test_save_entryAppearsInGroupedEntriesAfterSuccess() async {
        let sut = makeSUT()
        sut.draftVolume = 120
        sut.draftSource = .bottle

        await sut.save()

        let all = sut.groupedEntries.flatMap(\.1)
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.volumeMl, 120)
        XCTAssertEqual(all.first?.source, .bottle)
    }

    func test_save_resetsDraftVolumeAndSourceAfterSuccess() async {
        let sut = makeSUT()
        sut.draftVolume = 150
        sut.draftSource = .breast

        await sut.save()

        XCTAssertEqual(sut.draftVolume, 0, "Draft volume should reset to 0 after a successful save")
        XCTAssertEqual(sut.draftSource, .bottle, "Draft source should reset to .bottle after a successful save")
    }

    func test_save_groupedEntriesIsEmptyBeforeAnyInteraction() {
        let sut = makeSUT()
        XCTAssertTrue(sut.groupedEntries.isEmpty)
    }

    // MARK: - Error path

    func test_save_surfacesVolumeOutOfRangeIntoSaveError() async {
        let sut = makeSUT()
        sut.draftVolume = -999 // invalid — FeedLog init throws .volumeOutOfRange

        await sut.save()

        XCTAssertEqual(sut.saveError, .volumeOutOfRange)
    }

    func test_save_clearsPreviousSaveErrorOnSubsequentSuccess() async {
        let sut = makeSUT()

        // 1. Trigger an error
        sut.draftVolume = -1
        await sut.save()
        XCTAssertNotNil(sut.saveError, "Precondition: saveError must be set by invalid volume")

        // 2. Perform a valid save — error should clear
        sut.draftVolume = 100
        await sut.save()

        XCTAssertNil(sut.saveError, "A successful save must clear any prior saveError")
    }

    func test_save_doesNotResetDraftOnError() async {
        let sut = makeSUT()
        sut.draftVolume = -1
        sut.draftSource = .breast

        await sut.save()

        // Draft is preserved so the user can correct and retry.
        XCTAssertEqual(sut.draftVolume, -1)
        XCTAssertEqual(sut.draftSource, .breast)
    }

    // MARK: - groupedEntries reflects repository state

    func test_groupedEntries_reflectsAllEntriesAfterMultipleSaves() async {
        let repo = InMemoryFeedLogRepository()
        let sut = makeSUT(repository: repo)

        sut.draftVolume = 80
        await sut.save()

        sut.draftVolume = 90
        await sut.save()

        let all = sut.groupedEntries.flatMap(\.1)
        XCTAssertEqual(all.count, 2, "groupedEntries must reflect all persisted entries")
    }

    func test_groupedEntries_sharedRepositoryStateSurvivesAcrossViewModelInstances() async {
        // Two VMs sharing one repository must see the same data.
        let repo = InMemoryFeedLogRepository()
        let first = FeedLogViewModel(repository: repo, clock: FixedClock(date: fixedDate))
        let second = FeedLogViewModel(repository: repo, clock: FixedClock(date: fixedDate))

        first.draftVolume = 60
        await first.save()

        await second.refreshEntries()

        let all = second.groupedEntries.flatMap(\.1)
        XCTAssertEqual(all.count, 1, "Second VM must observe entry saved by first VM via shared repository")
    }

    // MARK: - todayEntries

    func test_todayEntries_filtersToTodayOnly() async {
        let now = Date()
        let calendar = Calendar.current
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        let repo = InMemoryFeedLogRepository()
        let sut = FeedLogViewModel(repository: repo, clock: FixedClock(date: now))

        let todayFeed = try! FeedLog(volumeMl: 100, loggedAt: now, source: .bottle)
        let yesterdayFeed = try! FeedLog(volumeMl: 80, loggedAt: yesterday, source: .bottle)
        try! await repo.save(todayFeed)
        try! await repo.save(yesterdayFeed)
        await sut.refreshEntries()

        XCTAssertEqual(sut.todayEntries.count, 1)
        XCTAssertEqual(sut.todayEntries.first?.id, todayFeed.id)
    }

    func test_todayEntries_sortedNewestFirst() async {
        let calendar = Calendar.current
        let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        let morning = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: Date())!
        let repo = InMemoryFeedLogRepository()
        let sut = FeedLogViewModel(repository: repo, clock: FixedClock(date: noon))

        let earlyFeed = try! FeedLog(volumeMl: 60, loggedAt: morning, source: .bottle)
        let lateFeed = try! FeedLog(volumeMl: 90, loggedAt: noon, source: .bottle)
        try! await repo.save(earlyFeed)
        try! await repo.save(lateFeed)
        await sut.refreshEntries()

        XCTAssertEqual(sut.todayEntries.map(\.id), [lateFeed.id, earlyFeed.id])
    }

    func test_todayEntries_emptyWhenNoFeedsToday() async {
        let now = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        let repo = InMemoryFeedLogRepository()
        let sut = FeedLogViewModel(repository: repo, clock: FixedClock(date: now))

        let feed = try! FeedLog(volumeMl: 100, loggedAt: yesterday, source: .bottle)
        try! await repo.save(feed)
        await sut.refreshEntries()

        XCTAssertTrue(sut.todayEntries.isEmpty)
    }

    // MARK: - groupedEntriesExcludingToday

    func test_groupedEntriesExcludingToday_excludesCurrentDay() async {
        let now = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        let repo = InMemoryFeedLogRepository()
        let sut = FeedLogViewModel(repository: repo, clock: FixedClock(date: now))

        let todayFeed = try! FeedLog(volumeMl: 100, loggedAt: now, source: .bottle)
        let yesterdayFeed = try! FeedLog(volumeMl: 80, loggedAt: yesterday, source: .bottle)
        try! await repo.save(todayFeed)
        try! await repo.save(yesterdayFeed)
        await sut.refreshEntries()

        let historyFeeds = sut.groupedEntriesExcludingToday.flatMap(\.1)
        XCTAssertEqual(historyFeeds.count, 1)
        XCTAssertEqual(historyFeeds.first?.id, yesterdayFeed.id)
    }

    // MARK: - allPumpingSessions

    func test_allPumpingSessions_loadedFromPumpingRepository() async {
        let now = Date()
        let feedRepo = InMemoryFeedLogRepository()
        let pumpRepo = InMemoryPumpingSessionRepository()
        let session = try! PumpingSession(startedAt: now, durationMinutes: 20, milkVolumeMl: 100)
        try! await pumpRepo.save(session)

        let sut = FeedLogViewModel(
            repository: feedRepo,
            clock: FixedClock(date: now),
            pumpingRepository: pumpRepo
        )
        await sut.refreshEntries()

        XCTAssertEqual(sut.allPumpingSessions.count, 1)
        XCTAssertEqual(sut.allPumpingSessions.first?.milkVolumeMl, 100)
    }

    func test_allPumpingSessions_emptyWhenNoPumpingRepository() async {
        let sut = makeSUT()
        await sut.refreshEntries()

        XCTAssertTrue(sut.allPumpingSessions.isEmpty)
    }

    // MARK: - groupedEntriesExcludingToday (continued)

    func test_groupedEntriesExcludingToday_emptyWhenOnlyTodayExists() async {
        let now = Date()
        let repo = InMemoryFeedLogRepository()
        let sut = FeedLogViewModel(repository: repo, clock: FixedClock(date: now))

        let feed = try! FeedLog(volumeMl: 100, loggedAt: now, source: .bottle)
        try! await repo.save(feed)
        await sut.refreshEntries()

        XCTAssertTrue(sut.groupedEntriesExcludingToday.isEmpty)
    }

    // MARK: - timeSinceLastFeed tracks clock advancement

    func test_timeSinceLastFeed_updatesWhenClockAdvancesAfterRefresh() async {
        let now = Date()
        let clock = TestClock(now: now)
        let repo = InMemoryFeedLogRepository()
        let sut = FeedLogViewModel(repository: repo, clock: clock)

        let feed = try! FeedLog(volumeMl: 100, loggedAt: now, source: .bottle)
        try! await repo.save(feed)
        await sut.refreshEntries()

        let firstReading = sut.timeSinceLastFeed
        XCTAssertNotNil(firstReading)
        XCTAssertEqual(firstReading!, 0, accuracy: 1)

        // Advance clock by 30 minutes
        clock.advance(by: 30 * 60)

        // Re-read without refreshing entries — computed property uses clock.now()
        let secondReading = sut.timeSinceLastFeed
        XCTAssertNotNil(secondReading)
        XCTAssertEqual(secondReading!, 30 * 60, accuracy: 1,
                       "timeSinceLastFeed must reflect advanced clock time")
    }

    func test_lastRefreshed_updatedAfterRefreshEntries() async {
        let now = Date()
        let clock = TestClock(now: now)
        let repo = InMemoryFeedLogRepository()
        let sut = FeedLogViewModel(repository: repo, clock: clock)

        XCTAssertEqual(sut.lastRefreshed, .distantPast,
                       "lastRefreshed starts at distantPast before any refresh")

        await sut.refreshEntries()

        XCTAssertEqual(sut.lastRefreshed, now,
                       "lastRefreshed must match clock.now() after refresh")

        clock.advance(by: 60)
        await sut.refreshEntries()

        XCTAssertEqual(sut.lastRefreshed, now.addingTimeInterval(60),
                       "lastRefreshed must advance with the clock on subsequent refreshes")
    }

    func test_refreshEntries_updatesAllDerivedStateIncludingTimeSinceLast() async {
        let now = Date()
        let clock = TestClock(now: now)
        let repo = InMemoryFeedLogRepository()
        let sut = FeedLogViewModel(repository: repo, clock: clock)

        // Save a feed 10 minutes ago
        let tenMinAgo = now.addingTimeInterval(-10 * 60)
        let feed = try! FeedLog(volumeMl: 120, loggedAt: tenMinAgo, source: .bottle)
        try! await repo.save(feed)

        await sut.refreshEntries()

        XCTAssertEqual(sut.timeSinceLastFeed!, 10 * 60, accuracy: 1)
        XCTAssertEqual(sut.totalToday.volumeMl, 120)
        XCTAssertEqual(sut.totalToday.count, 1)

        // Add another feed at "now" and refresh
        let feed2 = try! FeedLog(volumeMl: 80, loggedAt: now, source: .bottle)
        try! await repo.save(feed2)
        await sut.refreshEntries()

        XCTAssertEqual(sut.timeSinceLastFeed!, 0, accuracy: 1,
                       "After refresh, timeSinceLastFeed must reflect the newest feed")
        XCTAssertEqual(sut.totalToday.volumeMl, 200)
        XCTAssertEqual(sut.totalToday.count, 2)
    }
}

// MARK: - FeedSectionTests

@MainActor
final class FeedSectionTests: XCTestCase {

    func test_allCases_containsThreeSections() {
        XCTAssertEqual(FeedSection.allCases.count, 3)
    }

    func test_allCases_orderedTodayTrendsHistory() {
        XCTAssertEqual(
            FeedSection.allCases.map(\.rawValue),
            ["Today", "Trends", "History"]
        )
    }

    func test_id_matchesRawValue() {
        for section in FeedSection.allCases {
            XCTAssertEqual(section.id, section.rawValue)
        }
    }

    func test_defaultSection_isToday() {
        let defaultSection: FeedSection = .today
        XCTAssertEqual(defaultSection, .today,
                       "Today should be the default section shown first")
    }
}

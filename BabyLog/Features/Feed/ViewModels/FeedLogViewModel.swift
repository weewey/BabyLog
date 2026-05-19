import Foundation
import Observation
import LittleECore

/// @Observable view model for the feed-log entry form and grouped feed list.
///
/// Core types consumed (all logic lives in Core):
///   - `FeedLog`           – struct (id: UUID, volumeMl: Int, loggedAt: Date, source: FeedSource)
///   - `FeedSource`        – enum  (.breast / .bottle)
///   - `FeedLogError`      – enum  (.volumeOutOfRange)
///   - `FeedLogRepository` – protocol (save(_:) async throws, all() async throws -> [FeedLog])
///   - `Clock`             – protocol (now() -> Date)
///
/// No business logic lives here. Validation delegates to Core's FeedLog init,
/// and grouping delegates to Core's groupFeedsByDay.
@Observable
final class FeedLogViewModel {

    // MARK: - Draft state (view-owned; mutated via bindings)

    var draftVolume: Int = 0
    var draftSource: FeedSource = .bottle
    var draftLoggedAt: Date
    var draftNotes: String = ""

    // MARK: - Derived from Core validation (computed — no logic in this file)

    var canSave: Bool {
        (try? FeedLog(volumeMl: draftVolume, loggedAt: draftLoggedAt, source: draftSource, notes: draftNotes)) != nil
    }

    // MARK: - Feed list state

    private(set) var groupedEntries: [(Date, [FeedLog])] = []
    private(set) var allEntries: [FeedLog] = []
    private(set) var allPumpingSessions: [PumpingSession] = []

    var todayEntries: [FeedLog] {
        let start = Calendar.current.startOfDay(for: clock.now())
        return allEntries
            .filter { $0.loggedAt >= start }
            .sorted { $0.loggedAt > $1.loggedAt }
    }

    var groupedEntriesExcludingToday: [(Date, [FeedLog])] {
        let start = Calendar.current.startOfDay(for: clock.now())
        return groupedEntries.filter { $0.0 < start }
    }

    var totalToday: FeedLogAnalytics.DailyTotal {
        FeedLogAnalytics.totalFor(allEntries, on: clock.now())
    }

    /// Current moment from the injected clock, exposed so views can pass it
    /// into pure-Core analytics helpers without reaching for `Date()`.
    var now: Date { clock.now() }

    /// Seconds since the most recent feed, nil if there are no feeds.
    var timeSinceLastFeed: TimeInterval? {
        FeedLogAnalytics.timeSinceLast(allEntries, now: clock.now())
    }

    /// Average gap between feeds in seconds, nil if <2 feeds.
    var averageFeedInterval: TimeInterval? {
        FeedLogAnalytics.averageInterval(allEntries)
    }

    // MARK: - Refresh tick

    /// Bumped after every `refreshEntries()` call. Views can depend on this to
    /// force SwiftUI to re-evaluate computed properties that read `clock.now()`.
    private(set) var lastRefreshed: Date = .distantPast

    // MARK: - Error surface

    private(set) var saveError: FeedLogError?
    private(set) var loadError: (any Error)?

    // MARK: - Dependencies (injected; no singletons, no .shared)

    private let repository: any FeedLogRepository
    private let pumpingRepository: (any PumpingSessionRepository)?
    private let clock: any Clock
    private let reminder: (any FeedReminderNotifying)?
    private let reminderThreshold: TimeInterval

    init(
        repository: any FeedLogRepository,
        clock: any Clock,
        reminder: (any FeedReminderNotifying)? = nil,
        reminderThreshold: TimeInterval = 3 * 3600,
        pumpingRepository: (any PumpingSessionRepository)? = nil
    ) {
        self.repository = repository
        self.pumpingRepository = pumpingRepository
        self.clock = clock
        self.reminder = reminder
        self.reminderThreshold = reminderThreshold
        self.draftLoggedAt = clock.now()
    }

    // MARK: - Actions
    // @MainActor because they write to @Observable properties that SwiftUI
    // reads on the main actor. The class itself is NOT @MainActor-wide.

    @MainActor
    func save() async {
        saveError = nil
        do {
            let entry = try FeedLog(
                volumeMl: draftVolume,
                loggedAt: draftLoggedAt,
                source: draftSource,
                notes: draftNotes
            )
            try await repository.save(entry)
            await refreshEntries()
            resetDraft()
        } catch let error as FeedLogError {
            saveError = error
        } catch {
            loadError = error
        }
    }

    @MainActor
    func delete(id: UUID) async {
        do {
            try await repository.delete(id: id)
            await refreshEntries()
        } catch {
            loadError = error
        }
    }

    @MainActor
    func refreshEntries() async {
        do {
            let all = try await repository.all()
            allEntries = all
            groupedEntries = groupFeedsByDay(all)
            allPumpingSessions = (try? await pumpingRepository?.all()) ?? []
            lastRefreshed = clock.now()
            loadError = nil
            await reminder?.rescheduleFeedReminder(feeds: all, threshold: reminderThreshold)
        } catch {
            loadError = error
        }
    }

    // MARK: - Private helpers

    @MainActor
    private func resetDraft() {
        draftVolume = 0
        draftSource = .bottle
        draftLoggedAt = clock.now()
        draftNotes = ""
    }

}

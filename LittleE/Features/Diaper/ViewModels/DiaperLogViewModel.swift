import Foundation
import Observation
import LittleECore

/// @Observable view model for the diaper-log entry form and grouped history.
///
/// Core types consumed (all logic lives in Core):
///   - `DiaperLog`           – struct (id: UUID, type: DiaperType, loggedAt: Date, notes: String?)
///   - `DiaperType`          – enum  (.wet / .dirty / .both)
///   - `DiaperLogError`      – enum  (.invalidType)
///   - `DiaperLogRepository` – protocol (save(_:) async throws, all() async throws -> [DiaperLog])
///   - `Clock`               – protocol (now() -> Date)
///
/// No business logic lives here. Grouping delegates to Core's
/// DiaperLogAnalytics.groupByDay.
@Observable
final class DiaperLogViewModel {

    // MARK: - Draft state (view-owned; mutated via bindings)

    var draftType: DiaperType = .wet
    var draftNotes: String = ""
    var draftLoggedAt: Date

    // MARK: - Derived from Core validation (computed — no logic in this file)

    var canSave: Bool { true }

    // MARK: - Entry list state

    private(set) var groupedEntries: [(Date, [DiaperLog])] = []
    private(set) var allEntries: [DiaperLog] = []

    var countsToday: DiaperLogAnalytics.DailyCounts {
        DiaperLogAnalytics.countsFor(allEntries, on: clock.now())
    }

    var now: Date { clock.now() }

    // MARK: - Error surface

    private(set) var saveError: DiaperLogError?
    private(set) var loadError: (any Error)?

    // MARK: - Dependencies (injected; no singletons, no .shared)

    private let repository: any DiaperLogRepository
    private let clock: any Clock

    init(repository: any DiaperLogRepository, clock: any Clock) {
        self.repository = repository
        self.clock = clock
        self.draftLoggedAt = clock.now()
    }

    // MARK: - Actions
    // @MainActor because they write to @Observable properties that SwiftUI
    // reads on the main actor. The class itself is NOT @MainActor-wide.

    @MainActor
    func save() async {
        saveError = nil
        do {
            let notes: String? = draftNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : draftNotes.trimmingCharacters(in: .whitespacesAndNewlines)
            let entry = DiaperLog(
                id: UUID(),
                type: draftType,
                loggedAt: draftLoggedAt,
                notes: notes
            )
            try await repository.save(entry)
            await refreshEntries()
            resetDraft()
        } catch let error as DiaperLogError {
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
            groupedEntries = DiaperLogAnalytics.groupByDay(all, calendar: .current)
            loadError = nil
        } catch {
            loadError = error
        }
    }

    // MARK: - Private helpers

    @MainActor
    private func resetDraft() {
        draftType = .wet
        draftNotes = ""
        draftLoggedAt = clock.now()
    }

}

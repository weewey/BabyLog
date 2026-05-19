import Foundation
import Observation
import BabyLogCore

/// @Observable view model for the pumping tab.
///
/// Core types consumed (all logic lives in Core):
///   - `PumpingSession`             – domain struct
///   - `PumpingSide`                – enum
///   - `PumpingSessionError`        – typed throws
///   - `PumpingSessionRepository`   – protocol
///   - `PumpingScheduleTemplate`    – schedule definition + tip rotation
///   - `PumpingAnalytics`           – summarize(sessions:template:now:)
///   - `Clock`                      – injected time primitive
///
/// Thin wrapper: no business logic, all validation + summary go through Core.
@Observable
final class PumpingViewModel {

    // MARK: - Draft state (view-owned; mutated via bindings)

    var draftStartedAt: Date
    var draftDurationMinutes: Int = 20
    var draftSide: PumpingSide = .both
    var draftMilkVolumeMl: Int = 0
    var draftNotes: String = ""

    /// Id of the session being edited, nil = create mode.
    var editingId: UUID?

    // MARK: - Derived from Core validation

    var canSave: Bool {
        (try? buildDraftSession()) != nil
    }

    // MARK: - Session list + summary state

    private(set) var sessions: [PumpingSession] = []
    private(set) var summary: PumpingAnalytics

    var todaysSessions: [PumpingSession] {
        let startOfToday = calendar.startOfDay(for: clock.now())
        return sessions
            .filter { $0.startedAt >= startOfToday }
            .sorted { $0.startedAt > $1.startedAt }
    }

    // MARK: - History window + trend series

    /// How many calendar days back the history view currently shows.
    /// Starts at 30, grows by 30 each time `loadMoreHistory()` is called.
    private(set) var visibleHistoryDays: Int = 30

    /// Grouped-by-day history within the visible window (newest day first).
    var history: [DailyPumpingSummary] {
        guard let cutoff = calendar.date(
            byAdding: .day,
            value: -(visibleHistoryDays - 1),
            to: calendar.startOfDay(for: clock.now())
        ) else { return [] }
        let windowed = sessions.filter { $0.startedAt >= cutoff }
        return PumpingAnalytics.dailyHistory(
            sessions: windowed,
            now: clock.now(),
            calendar: calendar
        )
    }

    /// True when at least one session lives strictly before the current
    /// visible window — i.e. "Load more" would reveal more data.
    var hasMoreHistory: Bool {
        guard let cutoff = calendar.date(
            byAdding: .day,
            value: -(visibleHistoryDays - 1),
            to: calendar.startOfDay(for: clock.now())
        ) else { return false }
        return sessions.contains { $0.startedAt < cutoff }
    }

    /// 30-day volume series (oldest → newest) used by the trend chart.
    var trendSeries30d: [DailyVolumePoint] {
        PumpingAnalytics.dailyVolumeSeries(
            sessions: sessions,
            days: 30,
            now: clock.now(),
            calendar: calendar
        )
    }

    func loadMoreHistory() {
        visibleHistoryDays += 30
    }

    var tipOfDay: String {
        PumpingScheduleTemplate.tipOfDay(for: clock.now(), calendar: calendar)
    }

    // MARK: - Error surface

    private(set) var saveError: PumpingSessionError?
    private(set) var loadError: (any Error)?

    // MARK: - Dependencies

    let template: PumpingScheduleTemplate
    private let repository: any PumpingSessionRepository
    private let clock: any Clock
    private let calendar: Calendar

    init(
        repository: any PumpingSessionRepository,
        clock: any Clock,
        template: PumpingScheduleTemplate = .medelaEightSessionNewborn,
        calendar: Calendar = .current
    ) {
        self.repository = repository
        self.clock = clock
        self.template = template
        self.calendar = calendar
        self.draftStartedAt = clock.now()
        self.summary = PumpingAnalytics.summarize(
            sessions: [],
            template: template,
            now: clock.now(),
            calendar: calendar
        )
    }

    // MARK: - Actions

    @MainActor
    func load() async {
        do {
            let all = try await repository.all()
            self.sessions = all
            recomputeSummary()
            loadError = nil
        } catch {
            loadError = error
        }
    }

    @MainActor
    func save() async {
        saveError = nil
        do {
            let session = try buildDraftSession()
            try await repository.save(session)
            await load()
            resetDraft()
        } catch let error as PumpingSessionError {
            saveError = error
        } catch {
            loadError = error
        }
    }

    @MainActor
    func update() async {
        guard let editingId else { return }
        saveError = nil
        do {
            let session = try buildDraftSession(forcingId: editingId)
            try await repository.update(session)
            await load()
            resetDraft()
        } catch let error as PumpingSessionError {
            saveError = error
        } catch {
            loadError = error
        }
    }

    @MainActor
    func delete(id: UUID) async {
        do {
            try await repository.delete(id: id)
            await load()
        } catch {
            loadError = error
        }
    }

    /// Preload the draft state from an existing session for editing.
    func beginEditing(_ session: PumpingSession) {
        editingId = session.id
        draftStartedAt = session.startedAt
        draftDurationMinutes = session.durationMinutes
        draftSide = session.side ?? .both
        draftMilkVolumeMl = session.milkVolumeMl ?? 0
        draftNotes = session.notes ?? ""
    }

    func resetDraft() {
        editingId = nil
        draftStartedAt = clock.now()
        draftDurationMinutes = 20
        draftSide = .both
        draftMilkVolumeMl = 0
        draftNotes = ""
    }

    // MARK: - Private helpers

    private func buildDraftSession(forcingId: UUID? = nil) throws -> PumpingSession {
        let id = forcingId ?? editingId ?? UUID()
        let milk: Int? = draftMilkVolumeMl > 0 ? draftMilkVolumeMl : nil
        let notes: String? = draftNotes.isEmpty ? nil : draftNotes
        return try PumpingSession(
            id: id,
            startedAt: draftStartedAt,
            durationMinutes: draftDurationMinutes,
            side: draftSide,
            milkVolumeMl: milk,
            pumpBrand: template.pumpBrand,
            notes: notes
        )
    }

    private func recomputeSummary() {
        summary = PumpingAnalytics.summarize(
            sessions: sessions,
            template: template,
            now: clock.now(),
            calendar: calendar
        )
    }
}

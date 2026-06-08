import Foundation
import BabyLogCore

/// Drives the "Prep for visit" screen. Fetches every domain's records, asks
/// `VisitSummaryBuilder` (Core) to assemble a deterministic `VisitSummary`,
/// and exposes it plus a share-ready text payload.
@MainActor
@Observable
final class VisitSummaryViewModel {

    enum State: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var summary: VisitSummary?

    /// On-device LLM narration of the summary. Best-effort: empty when the
    /// model is unavailable or fails — the structured card + share text stand
    /// on their own.
    private(set) var narration: String = ""
    private(set) var isNarrating: Bool = false

    private let profileRepository: any ChildProfileRepository
    private let feedRepository: any FeedLogRepository
    private let diaperRepository: any DiaperLogRepository
    private let growthRepository: any GrowthMeasurementRepository
    private let pumpingRepository: any PumpingSessionRepository
    private let milestoneRepository: any MilestoneRepository
    private let appointmentRepository: any MedicalAppointmentRepository
    private let clock: any Clock
    private let calendar: Calendar
    private let builder = VisitSummaryBuilder()

    /// Optional on-device LLM used to narrate the summary. `nil` disables
    /// narration (the structured card is shown alone).
    private let chatSessionFactory: (any ChatSessionFactory)?
    private let narrationBackend: ChatBackend
    private var narrationTask: Task<Void, Never>?

    init(
        profileRepository: any ChildProfileRepository,
        feedRepository: any FeedLogRepository,
        diaperRepository: any DiaperLogRepository,
        growthRepository: any GrowthMeasurementRepository,
        pumpingRepository: any PumpingSessionRepository,
        milestoneRepository: any MilestoneRepository,
        appointmentRepository: any MedicalAppointmentRepository,
        clock: any Clock = SystemClock(),
        calendar: Calendar = .current,
        chatSessionFactory: (any ChatSessionFactory)? = nil,
        narrationBackend: ChatBackend = .apple
    ) {
        self.profileRepository = profileRepository
        self.feedRepository = feedRepository
        self.diaperRepository = diaperRepository
        self.growthRepository = growthRepository
        self.pumpingRepository = pumpingRepository
        self.milestoneRepository = milestoneRepository
        self.appointmentRepository = appointmentRepository
        self.clock = clock
        self.calendar = calendar
        self.chatSessionFactory = chatSessionFactory
        self.narrationBackend = narrationBackend
    }

    /// Plain-text payload for the share sheet (empty until loaded).
    var shareText: String {
        summary?.plainText(calendar: calendar) ?? ""
    }

    func load() async {
        state = .loading
        do {
            let profile = try await profileRepository.load()
            let feeds = try await feedRepository.all()
            let diapers = try await diaperRepository.all()
            let growth = try await growthRepository.all()
            let pumping = try await pumpingRepository.all()
            let milestones = try await milestoneRepository.all()
            let appointments = try await appointmentRepository.all()

            summary = builder.build(
                profile: profile,
                feeds: feeds,
                diapers: diapers,
                growth: growth,
                pumping: pumping,
                milestones: milestones,
                appointments: appointments,
                now: clock.now(),
                calendar: calendar
            )
            state = .loaded
            if let summary { beginNarration(of: summary) }
        } catch {
            state = .failed(String(describing: error))
        }
    }

    /// Stop any in-flight narration (e.g. when the sheet is dismissed).
    func cancelNarration() {
        narrationTask?.cancel()
        narrationTask = nil
        isNarrating = false
    }

    private func beginNarration(of summary: VisitSummary) {
        guard let chatSessionFactory else { return }
        guard let session = try? chatSessionFactory.makeSession(for: narrationBackend) else {
            return // model unavailable on this device — structured card stands alone
        }
        narration = ""
        isNarrating = true
        let prompt = summary.narrationPrompt(calendar: calendar)
        narrationTask = Task { [weak self] in
            let messages = [ChatMessage(role: .user, text: prompt)]
            do {
                for try await delta in session.stream(messages: messages, tools: nil) {
                    if Task.isCancelled { break }
                    if case let .token(chunk) = delta { self?.narration += chunk }
                }
            } catch {
                // Best-effort: drop a partial/failed narration; the structured
                // summary and share text remain fully usable.
                self?.narration = ""
            }
            self?.isNarrating = false
            self?.narrationTask = nil
        }
    }
}

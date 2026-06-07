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

    init(
        profileRepository: any ChildProfileRepository,
        feedRepository: any FeedLogRepository,
        diaperRepository: any DiaperLogRepository,
        growthRepository: any GrowthMeasurementRepository,
        pumpingRepository: any PumpingSessionRepository,
        milestoneRepository: any MilestoneRepository,
        appointmentRepository: any MedicalAppointmentRepository,
        clock: any Clock = SystemClock(),
        calendar: Calendar = .current
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
        } catch {
            state = .failed(String(describing: error))
        }
    }
}

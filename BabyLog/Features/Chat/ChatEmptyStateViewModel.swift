import Foundation
import Observation
import BabyLogCore

/// Loads and holds the snapshot the chat empty-state shell renders.
/// Reads from feed + diaper repos and the child profile store; all
/// derivation lives in `ChatEmptyStateSummary.summarize` so this type is
/// pure plumbing.
@MainActor
@Observable
final class ChatEmptyStateViewModel {

    private(set) var summary: ChatEmptyStateSummary?
    private(set) var profile: ChildProfile?

    private let feedRepository: any FeedLogRepository
    private let diaperRepository: any DiaperLogRepository
    private let profileLoader: () -> ChildProfile?
    private let clock: any Clock
    let diapersEnabled: Bool

    init(
        feedRepository: any FeedLogRepository,
        diaperRepository: any DiaperLogRepository,
        profileLoader: @escaping () -> ChildProfile?,
        clock: any Clock = SystemClock(),
        diapersEnabled: Bool = true
    ) {
        self.feedRepository = feedRepository
        self.diaperRepository = diaperRepository
        self.profileLoader = profileLoader
        self.clock = clock
        self.diapersEnabled = diapersEnabled
    }

    func refresh() async {
        profile = profileLoader()
        do {
            async let feeds = feedRepository.all()
            async let diapers = diaperRepository.all()
            let now = clock.now()
            summary = ChatEmptyStateSummary.summarize(
                feeds: try await feeds,
                diapers: try await diapers,
                now: now,
                diapersEnabled: diapersEnabled
            )
        } catch {
            summary = ChatEmptyStateSummary.summarize(
                feeds: [], diapers: [], now: clock.now(),
                diapersEnabled: diapersEnabled
            )
        }
    }
}

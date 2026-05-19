import Foundation
import Observation
import BabyLogCore

/// Loads the compact "Today at a glance" snapshot shown at the top of the
/// More tab. Reuses `ChatEmptyStateSummary` so all derivation stays in
/// Core and this type is pure plumbing (mirrors `ChatEmptyStateViewModel`).
@MainActor
@Observable
final class MoreTabSummaryViewModel {

    private(set) var summary: ChatEmptyStateSummary?

    private let feedRepository: any FeedLogRepository
    private let diaperRepository: any DiaperLogRepository
    private let clock: any Clock
    let diapersEnabled: Bool

    init(
        feedRepository: any FeedLogRepository,
        diaperRepository: any DiaperLogRepository,
        clock: any Clock = SystemClock(),
        diapersEnabled: Bool = true
    ) {
        self.feedRepository = feedRepository
        self.diaperRepository = diaperRepository
        self.clock = clock
        self.diapersEnabled = diapersEnabled
    }

    func refresh() async {
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

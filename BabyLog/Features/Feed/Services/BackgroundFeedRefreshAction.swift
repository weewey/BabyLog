import Foundation
import BabyLogCore

/// Orchestrates a background sync → feed check → reminder reschedule cycle.
///
/// Designed to be called from a `BGAppRefreshTask` handler but is fully
/// testable with injected dependencies — no `BGTaskScheduler` dependency.
struct BackgroundFeedRefreshAction {

    let syncAction: () async -> Void
    let feedRepository: any FeedLogRepository
    let reminder: any FeedReminderNotifying
    let reminderThreshold: TimeInterval
    let clock: any Clock

    /// Performs the full cycle: sync remote data, read latest feeds,
    /// reschedule the local notification based on fresh data.
    /// Returns `true` if the reminder was rescheduled, `false` if
    /// no feeds exist (nothing to remind about).
    @discardableResult
    func execute() async -> Bool {
        await syncAction()
        do {
            let feeds = try await feedRepository.all()
            await reminder.rescheduleFeedReminder(
                feeds: feeds,
                threshold: reminderThreshold
            )
            return !feeds.isEmpty
        } catch {
            return false
        }
    }
}

import Foundation

/// Protocol the iOS layer implements with `UNUserNotificationCenter`. Core owns
/// the abstraction so view models stay testable without importing UserNotifications.
public protocol FeedReminderNotifying: Sendable {
    func rescheduleFeedReminder(feeds: [FeedLog], threshold: TimeInterval) async
}

/// Pure logic for deciding when the next "it's been a while since the last feed" reminder
/// should fire. The iOS layer wraps `UNUserNotificationCenter` around this.
public enum FeedReminderScheduler {

    /// The absolute date at which the next reminder should fire, or nil if there is
    /// nothing to remind about (no prior feeds). The returned date may be in the past
    /// if the threshold has already elapsed — callers can either fire immediately or
    /// clamp to `max(result, now)` when scheduling.
    public static func nextFireDate(
        feeds: [FeedLog],
        threshold: TimeInterval,
        now: Date
    ) -> Date? {
        guard let mostRecent = feeds.map(\.loggedAt).max() else { return nil }
        return mostRecent.addingTimeInterval(threshold)
    }

    /// True when the gap since the most recent feed exceeds the threshold.
    /// False when there are no prior feeds (nothing to be overdue against).
    public static func isOverdue(
        feeds: [FeedLog],
        threshold: TimeInterval,
        now: Date
    ) -> Bool {
        guard let fire = nextFireDate(feeds: feeds, threshold: threshold, now: now) else {
            return false
        }
        return now > fire
    }
}

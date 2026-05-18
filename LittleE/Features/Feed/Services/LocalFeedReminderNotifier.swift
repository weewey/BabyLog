import Foundation
@preconcurrency import UserNotifications
import LittleECore

/// iOS adapter that schedules a local notification when the gap since the
/// most recent feed exceeds the configured threshold.
///
/// Cancels any previously scheduled feed reminder on every reschedule so there
/// is at most one pending notification at a time.
final class LocalFeedReminderNotifier: FeedReminderNotifying {

    private static let requestIdentifier = "littlee.feed.reminder"

    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func requestAuthorization() async {
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    func rescheduleFeedReminder(feeds: [FeedLog], threshold: TimeInterval) async {
        center.removePendingNotificationRequests(withIdentifiers: [Self.requestIdentifier])

        guard UserDefaults.standard.object(forKey: "notifications.feedReminderEnabled") as? Bool ?? false else {
            return
        }

        guard let fire = FeedReminderScheduler.nextFireDate(
            feeds: feeds,
            threshold: threshold,
            now: Date()
        ) else { return }

        let delay = max(fire.timeIntervalSinceNow, 1)

        let content = UNMutableNotificationContent()
        content.title = "Time for a feed?"
        content.body = "It's been over \(Int(threshold / 3600))h since Ethan's last feed."
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
        let request = UNNotificationRequest(
            identifier: Self.requestIdentifier,
            content: content,
            trigger: trigger
        )
        _ = try? await center.add(request)
    }
}

import BackgroundTasks
import Foundation

/// Registers and schedules the `BGAppRefreshTask` that syncs feeds from
/// the remote store and reschedules the local "time for a feed?" reminder.
///
/// Call `register(action:)` once at app launch (before the end of
/// `application(_:didFinishLaunchingWithOptions:)` or the `@main` App
/// init). Call `scheduleRefresh()` whenever the app enters background.
enum BackgroundTaskRegistrar {

    static let taskIdentifier = "com.littlee.feedRefresh"

    /// Minimum interval between background refreshes. iOS may delay
    /// further based on system conditions; this is a lower bound.
    static let minimumInterval: TimeInterval = 15 * 60

    /// Register the handler with `BGTaskScheduler`. Must be called
    /// before the app finishes launching.
    static func register(action: @escaping @Sendable () async -> Void) {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskIdentifier,
            using: nil
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handleRefresh(refreshTask, action: action)
        }
    }

    /// Request the next background refresh. Call from the scene-phase
    /// `.background` transition so iOS knows we want a wakeup.
    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: minimumInterval)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Swallow — common on simulator or when quota exhausted.
        }
    }

    private static func handleRefresh(
        _ task: BGAppRefreshTask,
        action: @escaping @Sendable () async -> Void
    ) {
        let workTask = Task {
            await action()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = {
            workTask.cancel()
            task.setTaskCompleted(success: false)
        }
        scheduleRefresh()
    }
}

import SwiftUI
import SwiftData
import LittleECore

// MARK: - App entry point

@main
struct LittleEApp: App {

    /// Production ModelContainer configured with CloudKit automatic sync.
    /// Stored on the App struct so the container lifetime matches the process.
    private let container: ModelContainer

    init() {
        let schema = Schema([
            FeedLogModel.self,
            DiaperLogModel.self,
            GrowthMeasurementModel.self,
            MedicalAppointmentModel.self,
            MilestoneModel.self,
            ChildProfileModel.self,
            DomainEventModel.self,
            PumpingSessionModel.self,
        ])
        let isUITesting = ProcessInfo.processInfo.arguments.contains("--ui-testing")
        let config = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: isUITesting,
            cloudKitDatabase: .none
        )
        do {
            container = try ModelContainer(for: schema, configurations: config)
        } catch {
            fatalError("[LittleEApp] SwiftData container failed to initialise: \(error)")
        }
        #if DEBUG
        _ = ClaudeAPIKeyStore.load()
        #endif
    }

    /// Registers the background feed-refresh task. Called from
    /// `RootTabView` once `SyncComposition` is available.
    @MainActor
    static func registerBackgroundFeedRefresh(sync: SyncComposition) {
        let feedRepo = sync.makeFeedLogRepository()
        let reminder: any FeedReminderNotifying = LocalFeedReminderNotifier()
        let threshold: TimeInterval = 3 * 3600

        BackgroundTaskRegistrar.register { @Sendable in
            let action = BackgroundFeedRefreshAction(
                syncAction: { await sync.transport.syncNow() },
                feedRepository: feedRepo,
                reminder: reminder,
                reminderThreshold: threshold,
                clock: SystemClock()
            )
            await action.execute()
        }
    }

    var body: some Scene {
        WindowGroup {
            AppCompositionView()
        }
        .modelContainer(container)
    }
}

// MARK: - Composition root

/// Thin composition root that delegates to `RootTabView` for tab-based
/// navigation (Feeds, Diapers, Settings).
///
/// **Previews** do *not* go through this view — they inject
/// `InMemoryFeedLogRepository` directly in their own `#Preview` blocks.
struct AppCompositionView: View {

    var body: some View {
        RootTabView()
    }
}

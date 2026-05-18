import Foundation
import SwiftData
import LittleECore

/// App-wide sync wiring built once per `RootTabView` lifecycle.
///
/// Owns the single `SwiftDataEventStore` every event-sourced repository
/// projects off, the `SyncEngine` that drives the protocol, and the
/// `GitHubSyncService` transport. Also resolves (and on first launch,
/// generates and persists) this device's stable `DeviceID` so events
/// carry a consistent origin across app restarts.
@MainActor
final class SyncComposition {

    let store: SwiftDataEventStore
    let deviceID: DeviceID
    let clock: any Clock
    let engine: SyncEngine
    let transport: GitHubSyncService

    init(context: ModelContext, defaults: UserDefaults = .standard) {
        let store = SwiftDataEventStore(context: context)
        let deviceID = Self.resolveDeviceID(defaults: defaults)
        let engine = SyncEngine(store: store, deviceID: deviceID)
        let interval = defaults.object(forKey: Self.pollIntervalKey) as? Double ?? 30
        self.store = store
        self.deviceID = deviceID
        self.clock = SystemClock()
        self.engine = engine
        self.transport = GitHubSyncService(engine: engine, pollInterval: max(5, interval))
    }

    static let pollIntervalKey = "sync.pollIntervalSeconds"

    func makeFeedLogRepository() -> any FeedLogRepository {
        EventSourcedFeedLogRepository(
            store: store,
            deviceID: deviceID,
            clock: clock,
            localWriteNotifier: transport
        )
    }

    func makeDiaperLogRepository() -> any DiaperLogRepository {
        EventSourcedDiaperLogRepository(
            store: store,
            deviceID: deviceID,
            clock: clock,
            localWriteNotifier: transport
        )
    }

    func makeMedicalAppointmentRepository() -> any MedicalAppointmentRepository {
        EventSourcedMedicalAppointmentRepository(
            store: store,
            deviceID: deviceID,
            clock: clock,
            localWriteNotifier: transport
        )
    }

    func makeGrowthMeasurementRepository() -> any GrowthMeasurementRepository {
        EventSourcedGrowthMeasurementRepository(
            store: store,
            deviceID: deviceID,
            clock: clock,
            localWriteNotifier: transport
        )
    }

    func makeMilestoneRepository() -> any MilestoneRepository {
        EventSourcedMilestoneRepository(
            store: store,
            deviceID: deviceID,
            clock: clock,
            localWriteNotifier: transport
        )
    }

    func makePumpingSessionRepository() -> any PumpingSessionRepository {
        EventSourcedPumpingSessionRepository(
            store: store,
            deviceID: deviceID,
            clock: clock,
            localWriteNotifier: transport
        )
    }

    // MARK: - DeviceID persistence

    private static let deviceIDKey = "sync.deviceID"

    private static func resolveDeviceID(defaults: UserDefaults) -> DeviceID {
        if let existing = defaults.string(forKey: deviceIDKey), !existing.isEmpty {
            return DeviceID(existing)
        }
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: deviceIDKey)
        return DeviceID(fresh)
    }
}

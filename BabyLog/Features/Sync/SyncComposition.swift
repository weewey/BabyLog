import Foundation
import SwiftData
import LittleECore

/// App-wide sync wiring built once per `RootTabView` lifecycle.
///
/// Owns the single `SwiftDataEventStore` every event-sourced repository
/// projects off, and the `SyncEngine` that drives the protocol. Also
/// resolves (and on first launch, generates and persists) this device's
/// stable `DeviceID` so events carry a consistent origin across app restarts.
///
/// BabyLog is a single-device app — there is no remote sync transport.
/// The event-sourced store is kept for future iCloud sync extensibility.
@MainActor
final class SyncComposition {

    let store: SwiftDataEventStore
    let deviceID: DeviceID
    let clock: any Clock
    let engine: SyncEngine

    init(context: ModelContext, defaults: UserDefaults = .standard) {
        let store = SwiftDataEventStore(context: context)
        let deviceID = Self.resolveDeviceID(defaults: defaults)
        let engine = SyncEngine(store: store, deviceID: deviceID)
        self.store = store
        self.deviceID = deviceID
        self.clock = SystemClock()
        self.engine = engine
    }

    func makeFeedLogRepository() -> any FeedLogRepository {
        EventSourcedFeedLogRepository(
            store: store,
            deviceID: deviceID,
            clock: clock
        )
    }

    func makeDiaperLogRepository() -> any DiaperLogRepository {
        EventSourcedDiaperLogRepository(
            store: store,
            deviceID: deviceID,
            clock: clock
        )
    }

    func makeMedicalAppointmentRepository() -> any MedicalAppointmentRepository {
        EventSourcedMedicalAppointmentRepository(
            store: store,
            deviceID: deviceID,
            clock: clock
        )
    }

    func makeGrowthMeasurementRepository() -> any GrowthMeasurementRepository {
        EventSourcedGrowthMeasurementRepository(
            store: store,
            deviceID: deviceID,
            clock: clock
        )
    }

    func makeMilestoneRepository() -> any MilestoneRepository {
        EventSourcedMilestoneRepository(
            store: store,
            deviceID: deviceID,
            clock: clock
        )
    }

    func makePumpingSessionRepository() -> any PumpingSessionRepository {
        EventSourcedPumpingSessionRepository(
            store: store,
            deviceID: deviceID,
            clock: clock
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

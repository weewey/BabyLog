import Foundation

public actor EventSourcedGrowthMeasurementRepository: GrowthMeasurementRepository {

    private let inner: EventSourcedRepository<GrowthMeasurement>

    public init(
        store: any EventStore,
        deviceID: DeviceID,
        clock: any Clock,
        localWriteNotifier: (any LocalWriteNotifying)? = nil
    ) {
        self.inner = EventSourcedRepository(
            store: store,
            deviceID: deviceID,
            clock: clock,
            localWriteNotifier: localWriteNotifier
        )
    }

    public func save(_ measurement: GrowthMeasurement) async throws {
        try await inner.save(measurement)
    }

    public func delete(id: UUID) async throws {
        try await inner.delete(syncID: id.uuidString)
    }

    public func all() async throws -> [GrowthMeasurement] {
        let items = await inner.all()
        return items.sorted { $0.date < $1.date }
    }
}

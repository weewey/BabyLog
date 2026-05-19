import Foundation

public actor EventSourcedDiaperLogRepository: DiaperLogRepository {

    private let inner: EventSourcedRepository<DiaperLog>

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

    public func save(_ log: DiaperLog) async throws {
        try await inner.save(log)
    }

    public func all() async throws -> [DiaperLog] {
        let items = await inner.all()
        return items.sorted { $0.loggedAt > $1.loggedAt }
    }

    public func delete(id: UUID) async throws {
        try await inner.delete(syncID: id.uuidString)
    }
}

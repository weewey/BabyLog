import Foundation

public actor EventSourcedPumpingSessionRepository: PumpingSessionRepository {

    private let inner: EventSourcedRepository<PumpingSession>

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

    public func save(_ session: PumpingSession) async throws {
        try await inner.save(session)
    }

    public func update(_ session: PumpingSession) async throws {
        try await inner.save(session)
    }

    public func delete(id: UUID) async throws {
        try await inner.delete(syncID: id.uuidString)
    }

    public func all() async throws -> [PumpingSession] {
        let items = await inner.all()
        return items.sorted { $0.startedAt > $1.startedAt }
    }

    public func recent(limit: Int) async throws -> [PumpingSession] {
        guard limit > 0 else { return [] }
        let sorted = try await all()
        return Array(sorted.prefix(limit))
    }
}

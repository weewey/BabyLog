import Foundation

public actor EventSourcedMilestoneRepository: MilestoneRepository {

    private let inner: EventSourcedRepository<Milestone>

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

    public func save(_ milestone: Milestone) async throws {
        try await inner.save(milestone)
    }

    public func delete(id: UUID) async throws {
        try await inner.delete(syncID: id.uuidString)
    }

    public func all() async throws -> [Milestone] {
        let items = await inner.all()
        return items.sorted { $0.achievedAt > $1.achievedAt }
    }
}

import Foundation

/// `FeedLogRepository` backed by an `EventStore`.
///
/// Thin adapter over the generic `EventSourcedRepository<FeedLog>`. It
/// exists so call sites can keep using the domain-specific protocol
/// (`save(FeedLog)` / `delete(id: UUID)`) while the actual event plumbing
/// is shared across every synced domain.
public actor EventSourcedFeedLogRepository: FeedLogRepository {

    private let inner: EventSourcedRepository<FeedLog>

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

    public func save(_ feed: FeedLog) async throws {
        try await inner.save(feed)
    }

    public func all() async throws -> [FeedLog] {
        // FeedLog view models expect newest-first-by-loggedAt ordering.
        // The generic repo returns projection order (set iteration), so
        // we sort here in the adapter.
        let items = await inner.all()
        return items.sorted { $0.loggedAt > $1.loggedAt }
    }

    public func delete(id: UUID) async throws {
        try await inner.delete(syncID: id.uuidString)
    }
}

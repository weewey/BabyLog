import Foundation

// MARK: - Generic projection

/// Materialises the current state of all records for domain `D` from an
/// event log. Pure function over the log — re-running it on the same
/// input always produces the same output.
///
/// Rules:
/// - latest-wins per `recordID` via `DomainEvent.supersedes`
/// - tombstones remove records
/// - events whose `schemaVersion` is newer than this binary knows about
///   are dropped silently (forward compat)
/// - events whose wire payload fails to decode or fails domain validation
///   are dropped silently (never crash on peer data)
public enum EventProjection<D: SyncableDomain> {

    public static func materialise(_ events: [DomainEvent]) -> [D] {
        var latest: [String: DomainEvent] = [:]
        for event in events where event.kind == D.kind {
            // Future-version events are skipped — a peer running a newer
            // app version may be emitting payloads we can't read yet.
            if event.schemaVersion > D.schemaVersion { continue }
            if let existing = latest[event.recordID] {
                if DomainEvent.supersedes(event, existing) {
                    latest[event.recordID] = event
                }
            } else {
                latest[event.recordID] = event
            }
        }

        var out: [D] = []
        for event in latest.values {
            guard event.operation == .upsert else { continue }
            guard let decoded = SyncableDomainCodec.decode(
                D.self,
                from: event.payload,
                schemaVersion: event.schemaVersion
            ) else { continue }
            out.append(decoded)
        }
        return out
    }
}

// MARK: - Local write notification

/// Hook fired by `EventSourcedRepository` after a local save/delete so
/// the transport layer can push the fresh event to connected peers
/// without waiting for the next handshake. Framework-agnostic — the iOS
/// `MultipeerSyncService` conforms from outside Core.
public protocol LocalWriteNotifying: Sendable {
    func didAppendLocalEvent() async
}

// MARK: - Generic event-sourced repository

/// Generic event-sourced repository over an `EventStore`. Each domain
/// that conforms to `SyncableDomain` gets save/delete/all for free —
/// onboarding a new model is just conforming the type and instantiating
/// this actor with the right generic parameter.
///
/// Read ordering is insertion-order-ish (actually set order over the
/// latest-event map). Callers that need a specific sort wrap this actor
/// in a thin adapter and sort in their own `all()`.
public actor EventSourcedRepository<D: SyncableDomain> {

    private let store: any EventStore
    private let deviceID: DeviceID
    private let clock: any Clock
    private let localWriteNotifier: (any LocalWriteNotifying)?

    public init(
        store: any EventStore,
        deviceID: DeviceID,
        clock: any Clock,
        localWriteNotifier: (any LocalWriteNotifying)? = nil
    ) {
        self.store = store
        self.deviceID = deviceID
        self.clock = clock
        self.localWriteNotifier = localWriteNotifier
    }

    public func save(_ item: D) async throws {
        let payload = try SyncableDomainCodec.encode(item)
        let event = DomainEvent(
            deviceID: deviceID,
            timestamp: clock.now(),
            kind: D.kind,
            operation: .upsert,
            recordID: item.syncID,
            payload: payload,
            schemaVersion: D.schemaVersion
        )
        try await store.append(event)
        await localWriteNotifier?.didAppendLocalEvent()
    }

    public func delete(syncID: String) async throws {
        let tombstone = DomainEvent(
            deviceID: deviceID,
            timestamp: clock.now(),
            kind: D.kind,
            operation: .tombstone,
            recordID: syncID,
            payload: Data(),
            schemaVersion: D.schemaVersion
        )
        try await store.append(tombstone)
        await localWriteNotifier?.didAppendLocalEvent()
    }

    public func all() async -> [D] {
        let events = await store.all()
        return EventProjection<D>.materialise(events)
    }
}

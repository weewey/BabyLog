import Foundation

// MARK: - Seen vector

/// Per-device "high-water mark" of events we've already accepted.
///
/// Used during peer handshakes: each side sends its seen vector, the other
/// streams back the events it has that the first side lacks.
public struct SeenVector: Sendable, Hashable, Codable {

    /// For every origin device we've heard from, the set of event IDs we
    /// already hold. We keep the full set rather than a monotonic counter
    /// because clients append out-of-order and there's no per-device sequence.
    public var entries: [DeviceID: Set<EventID>]

    public init(entries: [DeviceID: Set<EventID>] = [:]) {
        self.entries = entries
    }

    public func contains(_ event: DomainEvent) -> Bool {
        entries[event.deviceID]?.contains(event.id) ?? false
    }
}

// MARK: - Protocol

/// Append-only event log. All repositories project off this.
///
/// Actor so concurrent writers don't race. Pure Swift — the in-memory
/// implementation is the one we TDD on Linux; a SwiftData-backed variant
/// lives in the iOS target and adapts the same contract.
public protocol EventStore: Sendable {

    /// Append an event. Idempotent: appending an event whose `id` is
    /// already present is a no-op.
    func append(_ event: DomainEvent) async throws

    /// Append many events at once. Preserves idempotency.
    func append(_ events: [DomainEvent]) async throws

    /// Every event in insertion order.
    func all() async -> [DomainEvent]

    /// Subset of events this store has that `peer` does not, per the
    /// peer's `seenVector`. Used to compute a delta to stream over
    /// Multipeer during a handshake.
    func eventsMissing(from peer: SeenVector) async -> [DomainEvent]

    /// Our local seen vector — what we've accepted so far.
    func seenVector() async -> SeenVector
}

// MARK: - In-memory implementation

/// Reference implementation used by tests and by the running app until a
/// SwiftData-backed variant is wired in. Thread-safe via actor isolation.
public actor InMemoryEventStore: EventStore {

    private var events: [DomainEvent] = []
    private var index: Set<EventID> = []

    public init() {}

    public func append(_ event: DomainEvent) async throws {
        guard !index.contains(event.id) else { return }
        index.insert(event.id)
        events.append(event)
    }

    public func append(_ events: [DomainEvent]) async throws {
        for event in events {
            try await append(event)
        }
    }

    public func all() async -> [DomainEvent] {
        events
    }

    public func eventsMissing(from peer: SeenVector) async -> [DomainEvent] {
        events.filter { !peer.contains($0) }
    }

    public func seenVector() async -> SeenVector {
        var entries: [DeviceID: Set<EventID>] = [:]
        for event in events {
            entries[event.deviceID, default: []].insert(event.id)
        }
        return SeenVector(entries: entries)
    }
}

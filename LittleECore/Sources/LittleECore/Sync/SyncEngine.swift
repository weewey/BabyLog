import Foundation

// MARK: - Handshake envelopes

/// First message of a sync handshake: "here is what I've already seen".
public struct SyncHandshake: Codable, Sendable, Hashable {
    public let from: DeviceID
    public let seen: SeenVector

    public init(from: DeviceID, seen: SeenVector) {
        self.from = from
        self.seen = seen
    }
}

/// Second message: "here are the events you don't have".
public struct SyncDelta: Codable, Sendable, Hashable {
    public let from: DeviceID
    public let events: [DomainEvent]

    public init(from: DeviceID, events: [DomainEvent]) {
        self.from = from
        self.events = events
    }
}

// MARK: - Sync engine

/// Pure sync protocol logic, framework-agnostic. The iOS-side
/// `MultipeerSyncService` reaches into this to compute envelopes and
/// apply received deltas — MC just moves bytes.
public actor SyncEngine {

    private let store: any EventStore
    private let deviceID: DeviceID

    public init(store: any EventStore, deviceID: DeviceID) {
        self.store = store
        self.deviceID = deviceID
    }

    /// This device's stable sync identity. Exposed so transports can
    /// stamp `SyncDelta.from` when they push events to peers without
    /// going through the handshake path.
    public var localDeviceID: DeviceID { deviceID }

    /// Every event currently in the local log, in store insertion order.
    /// Used by transports that need to broadcast the full log after a
    /// local write (push semantics); peers dedupe on their side.
    public func allEvents() async -> [DomainEvent] {
        await store.all()
    }

    /// Current seen vector from the local store. Exposed so transports
    /// can pre-filter incoming `SyncDelta`s against what they already
    /// hold before firing UI refresh hooks.
    public func currentSeenVector() async -> SeenVector {
        await store.seenVector()
    }

    /// Build the handshake we'd send to a fresh peer.
    public func makeHandshake() async -> SyncHandshake {
        let seen = await store.seenVector()
        return SyncHandshake(from: deviceID, seen: seen)
    }

    /// Compute the delta we'd send in response to a peer handshake.
    public func makeDelta(for peer: SyncHandshake) async -> SyncDelta {
        let events = await store.eventsMissing(from: peer.seen)
        return SyncDelta(from: deviceID, events: events)
    }

    /// Apply a delta received from a peer. Idempotent — safe to replay.
    /// Throws if the store fails to persist the events.
    public func apply(_ delta: SyncDelta) async throws {
        try await store.append(delta.events)
    }

    /// Convenience: run a full two-party merge between this engine and
    /// another. Both sides end up with the union of their event logs.
    /// Used by tests to verify the protocol converges.
    public func merge(with peer: SyncEngine) async throws {
        let ours = await makeHandshake()
        let theirs = await peer.makeHandshake()

        let toPeer = await makeDelta(for: theirs)
        let toUs = await peer.makeDelta(for: ours)

        try await peer.apply(toPeer)
        try await apply(toUs)
    }
}

// MARK: - Codec errors

/// Typed error surface for the sync codec. Every failure path that
/// crosses the transport boundary is one of these cases — callers can
/// exhaustively switch and decide whether to drop the message, request
/// a resync, or surface the problem in the UI.
public enum SyncCodecError: Error, Equatable, Sendable {
    /// The incoming bytes weren't valid JSON for the expected envelope.
    case decodeFailed(underlying: String)
    /// Envelope version tag didn't match what this build expects.
    /// Reserved for a future versioning handshake — unused today but
    /// carved out so callers don't need another round of API churn
    /// when we add it.
    case versionMismatch(expected: String, got: String)
    /// The JSON decoded but the shape didn't match (missing/extra keys).
    case schemaDrift(description: String)
    /// Encoding a Swift value into JSON unexpectedly failed.
    case encodeFailed(underlying: String)
}

// MARK: - Codec

/// JSON codec for on-wire sync envelopes. Kept centralised so the iOS
/// Multipeer transport and any future transport share one encoding.
public enum SyncCodec {

    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public static func encode<T: Encodable>(_ value: T) throws(SyncCodecError) -> Data {
        do {
            return try encoder.encode(value)
        } catch {
            throw .encodeFailed(underlying: String(describing: error))
        }
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws(SyncCodecError) -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch let decodingError as DecodingError {
            throw .schemaDrift(description: String(describing: decodingError))
        } catch {
            throw .decodeFailed(underlying: String(describing: error))
        }
    }
}

import Foundation

// MARK: - Device ID

/// Stable identifier for a single device (phone) participating in sync.
///
/// Devices generate one at first launch and persist it. Events carry the
/// origin device ID so merge tie-breaks are deterministic across devices.
public struct DeviceID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

// MARK: - Event ID

/// Globally-unique identifier for a single `DomainEvent`.
public struct EventID: Hashable, Sendable, Codable {
    public let value: UUID

    public init(_ value: UUID = UUID()) {
        self.value = value
    }
}

// MARK: - Domain event kinds

/// The kind of record an event targets. Keeps the event log generic over
/// the concrete domain types while still letting projections select their
/// slice of the log without decoding every payload.
public enum DomainEventKind: String, Sendable, Codable, Hashable {
    case feedLog
    case diaperLog
    case growthMeasurement
    case medicalAppointment
    case milestone
    case childProfile
    case pumpingSession
}

/// What this event says about the record.
public enum DomainEventOperation: String, Sendable, Codable, Hashable {
    /// Create-or-update. Latest wins.
    case upsert
    /// Tombstone. Record is logically deleted; later upserts for the same
    /// record ID win if their (timestamp, device) beats the tombstone.
    case tombstone
}

// MARK: - Domain event

/// Append-only record of a single domain mutation.
///
/// The event log is the source of truth; all repositories are projections
/// over a sequence of events. Events are immutable once appended.
///
/// `recordID` identifies the logical record (e.g. a `FeedLog.id`). Multiple
/// events may share a `recordID` — the materialisation path picks the
/// winner using `(timestamp, deviceID)` ordering.
public struct DomainEvent: Hashable, Sendable, Codable, Identifiable {

    public let id: EventID
    public let deviceID: DeviceID
    public let timestamp: Date
    public let kind: DomainEventKind
    public let operation: DomainEventOperation
    public let recordID: String
    public let payload: Data
    /// Schema version of the wire `payload`, set from
    /// `SyncableDomain.schemaVersion` at save time. The projection uses
    /// this to skip events from a future version (forward compat) and
    /// to route old payloads through `PayloadMigration` hooks when a
    /// domain evolves its shape (backward compat).
    public let schemaVersion: Int

    public init(
        id: EventID = EventID(),
        deviceID: DeviceID,
        timestamp: Date,
        kind: DomainEventKind,
        operation: DomainEventOperation,
        recordID: String,
        payload: Data,
        schemaVersion: Int = 1
    ) {
        self.id = id
        self.deviceID = deviceID
        self.timestamp = timestamp
        self.kind = kind
        self.operation = operation
        self.recordID = recordID
        self.payload = payload
        self.schemaVersion = schemaVersion
    }

    // Custom Codable so events written before `schemaVersion` existed
    // decode cleanly. Missing key → default 1.
    private enum CodingKeys: String, CodingKey {
        case id, deviceID, timestamp, kind, operation, recordID, payload, schemaVersion
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(EventID.self, forKey: .id)
        self.deviceID = try c.decode(DeviceID.self, forKey: .deviceID)
        self.timestamp = try c.decode(Date.self, forKey: .timestamp)
        self.kind = try c.decode(DomainEventKind.self, forKey: .kind)
        self.operation = try c.decode(DomainEventOperation.self, forKey: .operation)
        self.recordID = try c.decode(String.self, forKey: .recordID)
        self.payload = try c.decode(Data.self, forKey: .payload)
        self.schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(deviceID, forKey: .deviceID)
        try c.encode(timestamp, forKey: .timestamp)
        try c.encode(kind, forKey: .kind)
        try c.encode(operation, forKey: .operation)
        try c.encode(recordID, forKey: .recordID)
        try c.encode(payload, forKey: .payload)
        try c.encode(schemaVersion, forKey: .schemaVersion)
    }
}

// MARK: - Ordering

extension DomainEvent {
    /// Total order used by projections to pick the "latest" event for a
    /// given record. Newer timestamps win; ties break on `deviceID`
    /// (lexicographic) then on `id` (UUID string). Deterministic.
    public static func supersedes(_ lhs: DomainEvent, _ rhs: DomainEvent) -> Bool {
        if lhs.timestamp != rhs.timestamp {
            return lhs.timestamp > rhs.timestamp
        }
        if lhs.deviceID.rawValue != rhs.deviceID.rawValue {
            return lhs.deviceID.rawValue > rhs.deviceID.rawValue
        }
        return lhs.id.value.uuidString > rhs.id.value.uuidString
    }
}

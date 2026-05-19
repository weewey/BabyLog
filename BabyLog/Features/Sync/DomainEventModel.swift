import Foundation
import SwiftData
import LittleECore

/// SwiftData persistence model mirroring `LittleECore.DomainEvent`.
///
/// The event log is append-only, so this table grows monotonically. No
/// relationships — every row is self-contained so idempotent append +
/// seen-vector computation are single-table operations.
///
/// CloudKit-safe (all defaults) even though we currently run with
/// `cloudKitDatabase: .none`; leaves the door open to flip it on later.
@Model
final class DomainEventModel {

    /// Globally-unique event id; mirrors `DomainEvent.id.value`. Used for
    /// idempotent append (de-dupe on insert) and the seen vector.
    @Attribute(.unique) var eventID: UUID = UUID()

    var deviceIDRaw: String = ""
    var timestamp: Date = Date.distantPast
    var kindRaw: String = ""
    var operationRaw: String = ""
    var recordID: String = ""
    var payload: Data = Data()
    var schemaVersion: Int = 1

    init(
        eventID: UUID = UUID(),
        deviceIDRaw: String = "",
        timestamp: Date = .distantPast,
        kindRaw: String = "",
        operationRaw: String = "",
        recordID: String = "",
        payload: Data = Data(),
        schemaVersion: Int = 1
    ) {
        self.eventID = eventID
        self.deviceIDRaw = deviceIDRaw
        self.timestamp = timestamp
        self.kindRaw = kindRaw
        self.operationRaw = operationRaw
        self.recordID = recordID
        self.payload = payload
        self.schemaVersion = schemaVersion
    }
}

// MARK: - Mapping

extension DomainEventModel {

    /// Build a row from an in-memory `DomainEvent`.
    convenience init(event: DomainEvent) {
        self.init(
            eventID: event.id.value,
            deviceIDRaw: event.deviceID.rawValue,
            timestamp: event.timestamp,
            kindRaw: event.kind.rawValue,
            operationRaw: event.operation.rawValue,
            recordID: event.recordID,
            payload: event.payload,
            schemaVersion: event.schemaVersion
        )
    }

    /// Project back to the domain event. Returns `nil` if a raw enum value
    /// is unrecognised — treat those rows as "from a newer schema" and
    /// silently skip in projections, same policy as the in-memory store.
    func toDomain() -> DomainEvent? {
        guard
            let kind = DomainEventKind(rawValue: kindRaw),
            let op = DomainEventOperation(rawValue: operationRaw)
        else { return nil }
        return DomainEvent(
            id: EventID(eventID),
            deviceID: DeviceID(deviceIDRaw),
            timestamp: timestamp,
            kind: kind,
            operation: op,
            recordID: recordID,
            payload: payload,
            schemaVersion: schemaVersion
        )
    }
}

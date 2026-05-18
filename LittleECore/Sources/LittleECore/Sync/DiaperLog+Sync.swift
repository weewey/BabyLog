import Foundation

public struct DiaperLogWire: Codable, Hashable, Sendable {
    public let id: UUID
    public let type: DiaperType
    public let loggedAt: Date
    public let notes: String?
}

extension DiaperLog: SyncableDomain {

    public static var kind: DomainEventKind { .diaperLog }
    public static var schemaVersion: Int { 1 }

    public var syncID: String { id.uuidString }

    public func toWire() -> DiaperLogWire {
        DiaperLogWire(id: id, type: type, loggedAt: loggedAt, notes: notes)
    }

    public static func fromWire(_ wire: DiaperLogWire) -> DiaperLog? {
        DiaperLog(id: wire.id, type: wire.type, loggedAt: wire.loggedAt, notes: wire.notes)
    }
}

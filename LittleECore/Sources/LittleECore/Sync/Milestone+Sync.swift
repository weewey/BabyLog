import Foundation

public struct MilestoneWire: Codable, Hashable, Sendable {
    public let id: UUID
    public let title: String
    public let achievedAt: Date
    public let notes: String?
}

extension Milestone: SyncableDomain {

    public static var kind: DomainEventKind { .milestone }
    public static var schemaVersion: Int { 1 }

    public var syncID: String { id.uuidString }

    public func toWire() -> MilestoneWire {
        MilestoneWire(id: id, title: title, achievedAt: achievedAt, notes: notes)
    }

    public static func fromWire(_ wire: MilestoneWire) -> Milestone? {
        try? Milestone(id: wire.id, title: wire.title, achievedAt: wire.achievedAt, notes: wire.notes)
    }
}

import Foundation

public struct PumpingSessionWire: Codable, Hashable, Sendable {
    public let id: UUID
    public let startedAt: Date
    public let durationMinutes: Int
    public let side: PumpingSide?
    public let milkVolumeMl: Int?
    public let pumpBrand: String
    public let scheduleSlotId: String?
    public let notes: String?
}

extension PumpingSession: SyncableDomain {

    public static var kind: DomainEventKind { .pumpingSession }
    public static var schemaVersion: Int { 1 }

    public var syncID: String { id.uuidString }

    public func toWire() -> PumpingSessionWire {
        PumpingSessionWire(
            id: id,
            startedAt: startedAt,
            durationMinutes: durationMinutes,
            side: side,
            milkVolumeMl: milkVolumeMl,
            pumpBrand: pumpBrand,
            scheduleSlotId: scheduleSlotId,
            notes: notes
        )
    }

    public static func fromWire(_ wire: PumpingSessionWire) -> PumpingSession? {
        try? PumpingSession(
            id: wire.id,
            startedAt: wire.startedAt,
            durationMinutes: wire.durationMinutes,
            side: wire.side,
            milkVolumeMl: wire.milkVolumeMl,
            pumpBrand: wire.pumpBrand,
            scheduleSlotId: wire.scheduleSlotId,
            notes: wire.notes
        )
    }
}

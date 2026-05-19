import Foundation

public struct MedicalAppointmentWire: Codable, Hashable, Sendable {
    public let id: UUID
    public let title: String
    public let scheduledAt: Date
    public let location: String?
    public let notes: String?
}

extension MedicalAppointment: SyncableDomain {

    public static var kind: DomainEventKind { .medicalAppointment }
    public static var schemaVersion: Int { 1 }

    public var syncID: String { id.uuidString }

    public func toWire() -> MedicalAppointmentWire {
        MedicalAppointmentWire(
            id: id,
            title: title,
            scheduledAt: scheduledAt,
            location: location,
            notes: notes
        )
    }

    public static func fromWire(_ wire: MedicalAppointmentWire) -> MedicalAppointment? {
        try? MedicalAppointment(
            id: wire.id,
            title: wire.title,
            scheduledAt: wire.scheduledAt,
            location: wire.location,
            notes: wire.notes
        )
    }
}

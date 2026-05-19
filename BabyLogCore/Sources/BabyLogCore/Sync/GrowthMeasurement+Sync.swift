import Foundation

public struct GrowthMeasurementWire: Codable, Hashable, Sendable {
    public let id: UUID
    public let date: Date
    public let weightGrams: Int?
    public let heightCm: Double?
    public let headCircumferenceCm: Double?
    public let notes: String?
}

extension GrowthMeasurement: SyncableDomain {

    public static var kind: DomainEventKind { .growthMeasurement }
    public static var schemaVersion: Int { 1 }

    public var syncID: String { id.value.uuidString }

    public func toWire() -> GrowthMeasurementWire {
        GrowthMeasurementWire(
            id: id.value,
            date: date,
            weightGrams: weightGrams,
            heightCm: heightCm,
            headCircumferenceCm: headCircumferenceCm,
            notes: notes
        )
    }

    public static func fromWire(_ wire: GrowthMeasurementWire) -> GrowthMeasurement? {
        try? GrowthMeasurement(
            id: GrowthMeasurementID(wire.id),
            date: wire.date,
            weightGrams: wire.weightGrams,
            heightCm: wire.heightCm,
            headCircumferenceCm: wire.headCircumferenceCm,
            notes: wire.notes
        )
    }
}

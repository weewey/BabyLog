import Foundation
import SwiftData
import LittleECore

@MainActor
final class SwiftDataGrowthMeasurementRepository: GrowthMeasurementRepository {

    nonisolated init(context: ModelContext) {
        self.context = context
    }

    private let context: ModelContext

    func all() throws -> [GrowthMeasurement] {
        let descriptor = FetchDescriptor<GrowthMeasurementModel>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        return try context.fetch(descriptor).compactMap(toDomain)
    }

    func delete(id: UUID) throws {
        let descriptor = FetchDescriptor<GrowthMeasurementModel>(
            predicate: #Predicate { $0.id == id }
        )
        if let existing = try context.fetch(descriptor).first {
            context.delete(existing)
            try context.save()
        }
    }

    func save(_ measurement: GrowthMeasurement) throws {
        let mid = measurement.id.value
        let existing = FetchDescriptor<GrowthMeasurementModel>(
            predicate: #Predicate { $0.id == mid }
        )
        if let prior = try context.fetch(existing).first {
            context.delete(prior)
        }
        context.insert(toModel(measurement))
        try context.save()
    }

    private func toModel(_ m: GrowthMeasurement) -> GrowthMeasurementModel {
        GrowthMeasurementModel(
            id: m.id.value,
            date: m.date,
            weightGrams: m.weightGrams,
            heightCm: m.heightCm,
            headCircumferenceCm: m.headCircumferenceCm,
            notes: m.notes
        )
    }

    private func toDomain(_ model: GrowthMeasurementModel) -> GrowthMeasurement? {
        try? GrowthMeasurement(
            id: GrowthMeasurementID(model.id),
            date: model.date,
            weightGrams: model.weightGrams,
            heightCm: model.heightCm,
            headCircumferenceCm: model.headCircumferenceCm,
            notes: model.notes
        )
    }
}

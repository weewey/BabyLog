import Foundation
import SwiftData
import LittleECore

@MainActor
final class SwiftDataMedicalAppointmentRepository: MedicalAppointmentRepository {

    nonisolated init(context: ModelContext) {
        self.context = context
    }

    private let context: ModelContext

    func all() throws -> [MedicalAppointment] {
        let descriptor = FetchDescriptor<MedicalAppointmentModel>(
            sortBy: [SortDescriptor(\.scheduledAt, order: .forward)]
        )
        return try context.fetch(descriptor).compactMap(toDomain)
    }

    func save(_ appointment: MedicalAppointment) throws {
        let aid = appointment.id
        let existing = FetchDescriptor<MedicalAppointmentModel>(
            predicate: #Predicate { $0.id == aid }
        )
        if let prior = try context.fetch(existing).first {
            context.delete(prior)
        }
        context.insert(
            MedicalAppointmentModel(
                id: appointment.id,
                title: appointment.title,
                scheduledAt: appointment.scheduledAt,
                location: appointment.location,
                notes: appointment.notes
            )
        )
        try context.save()
    }

    func delete(id: UUID) throws {
        let existing = FetchDescriptor<MedicalAppointmentModel>(
            predicate: #Predicate { $0.id == id }
        )
        if let model = try context.fetch(existing).first {
            context.delete(model)
            try context.save()
        }
    }

    private func toDomain(_ m: MedicalAppointmentModel) -> MedicalAppointment? {
        try? MedicalAppointment(
            id: m.id,
            title: m.title,
            scheduledAt: m.scheduledAt,
            location: m.location,
            notes: m.notes
        )
    }
}

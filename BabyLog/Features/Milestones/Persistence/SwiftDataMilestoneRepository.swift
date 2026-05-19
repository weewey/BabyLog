import Foundation
import SwiftData
import LittleECore

@MainActor
final class SwiftDataMilestoneRepository: MilestoneRepository {

    nonisolated init(context: ModelContext) {
        self.context = context
    }

    private let context: ModelContext

    func all() throws -> [Milestone] {
        let descriptor = FetchDescriptor<MilestoneModel>(
            sortBy: [SortDescriptor(\.achievedAt, order: .reverse)]
        )
        return try context.fetch(descriptor).compactMap(toDomain)
    }

    func save(_ m: Milestone) throws {
        let mid = m.id
        let existing = FetchDescriptor<MilestoneModel>(
            predicate: #Predicate { $0.id == mid }
        )
        if let prior = try context.fetch(existing).first {
            context.delete(prior)
        }
        context.insert(MilestoneModel(
            id: m.id,
            title: m.title,
            achievedAt: m.achievedAt,
            notes: m.notes
        ))
        try context.save()
    }

    func delete(id: UUID) throws {
        let existing = FetchDescriptor<MilestoneModel>(
            predicate: #Predicate { $0.id == id }
        )
        if let model = try context.fetch(existing).first {
            context.delete(model)
            try context.save()
        }
    }

    private func toDomain(_ m: MilestoneModel) -> Milestone? {
        try? Milestone(id: m.id, title: m.title, achievedAt: m.achievedAt, notes: m.notes)
    }
}

import Foundation
import SwiftData
import BabyLogCore

@MainActor
final class SwiftDataChildProfileRepository: ChildProfileRepository {

    nonisolated init(context: ModelContext) {
        self.context = context
    }

    private let context: ModelContext

    func load() throws -> ChildProfile? {
        let descriptor = FetchDescriptor<ChildProfileModel>()
        guard let m = try context.fetch(descriptor).first else { return nil }
        return try? ChildProfile(name: m.name, dateOfBirth: m.dateOfBirth)
    }

    func save(_ profile: ChildProfile) throws {
        let descriptor = FetchDescriptor<ChildProfileModel>()
        let existing = try context.fetch(descriptor)
        for old in existing { context.delete(old) }
        context.insert(ChildProfileModel(name: profile.name, dateOfBirth: profile.dateOfBirth))
        try context.save()
    }
}

import Foundation
import SwiftData
import BabyLogCore

/// Concrete `DiaperLogRepository` backed by SwiftData + CloudKit.
///
/// Isolated to `@MainActor` because `ModelContext` is not `Sendable` and must
/// be accessed from a single concurrency domain.  All `DiaperLogRepository`
/// methods are synchronous here; a `throws`-only implementation satisfies both
/// a `throws` and an `async throws` protocol requirement.
@MainActor
final class SwiftDataDiaperLogRepository: DiaperLogRepository {

    nonisolated init(context: ModelContext) {
        self.context = context
    }

    // MARK: - Dependencies

    private let context: ModelContext

    // MARK: - DiaperLogRepository

    func all() throws -> [DiaperLog] {
        let descriptor = FetchDescriptor<DiaperLogModel>(
            sortBy: [SortDescriptor(\.loggedAt, order: .reverse)]
        )
        return try context.fetch(descriptor).compactMap(toDomain)
    }

    func save(_ log: DiaperLog) throws {
        let logID = log.id
        let existing = FetchDescriptor<DiaperLogModel>(
            predicate: #Predicate { $0.id == logID }
        )
        if let prior = try context.fetch(existing).first {
            context.delete(prior)
        }
        context.insert(toModel(log))
        try context.save()
    }

    func delete(id: UUID) throws {
        let existing = FetchDescriptor<DiaperLogModel>(
            predicate: #Predicate { $0.id == id }
        )
        if let model = try context.fetch(existing).first {
            context.delete(model)
            try context.save()
        }
    }

    // MARK: - Mapping helpers

    /// Domain -> persistence model.  No logic — pure field translation.
    private func toModel(_ log: DiaperLog) -> DiaperLogModel {
        DiaperLogModel(
            id: log.id,
            loggedAt: log.loggedAt,
            typeValue: log.type.rawValue,
            notes: log.notes
        )
    }

    /// Persistence model -> domain type.  Unrecognised `typeValue` falls
    /// back to `.wet` so a future schema extension never hard-crashes.
    /// Returns `nil` if the raw-value initialiser throws (e.g. corrupted
    /// record from a bad CloudKit sync).
    private func toDomain(_ model: DiaperLogModel) -> DiaperLog? {
        let type = DiaperType(rawValue: model.typeValue) ?? .wet
        return DiaperLog(
            id: model.id,
            type: type,
            loggedAt: model.loggedAt,
            notes: model.notes
        )
    }
}

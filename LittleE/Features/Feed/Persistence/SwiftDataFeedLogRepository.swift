import Foundation
import SwiftData
import LittleECore

/// Concrete `FeedLogRepository` backed by SwiftData + CloudKit.
///
/// Isolated to `@MainActor` because `ModelContext` is not `Sendable` and must
/// be accessed from a single concurrency domain.  All `FeedLogRepository`
/// methods are synchronous here; a `throws`-only implementation satisfies both
/// a `throws` and an `async throws` protocol requirement.
@MainActor
final class SwiftDataFeedLogRepository: FeedLogRepository {

    nonisolated init(context: ModelContext) {
        self.context = context
    }

    // MARK: - Dependencies

    private let context: ModelContext

    // MARK: - FeedLogRepository

    func all() throws -> [FeedLog] {
        let descriptor = FetchDescriptor<FeedLogModel>(
            sortBy: [SortDescriptor(\.loggedAt, order: .reverse)]
        )
        return try context.fetch(descriptor).compactMap(toDomain)
    }

    func save(_ feed: FeedLog) throws {
        let feedID = feed.id
        let existing = FetchDescriptor<FeedLogModel>(
            predicate: #Predicate { $0.id == feedID }
        )
        if let prior = try context.fetch(existing).first {
            context.delete(prior)
        }
        context.insert(toModel(feed))
        try context.save()
    }

    func delete(id: UUID) throws {
        let existing = FetchDescriptor<FeedLogModel>(
            predicate: #Predicate { $0.id == id }
        )
        if let model = try context.fetch(existing).first {
            context.delete(model)
            try context.save()
        }
    }

    // MARK: - Mapping helpers

    /// Domain -> persistence model.  No logic — pure field translation.
    private func toModel(_ log: FeedLog) -> FeedLogModel {
        FeedLogModel(
            id: log.id,
            loggedAt: log.loggedAt,
            volumeMl: log.volumeMl,
            sourceValue: sourceToString(log.source),
            notes: log.notes
        )
    }

    /// Persistence model -> domain type.  Unrecognised `sourceValue` falls
    /// back to `.bottle` so a future schema extension never hard-crashes.
    /// Returns `nil` if `FeedLog` initializer throws (e.g. volume out of range
    /// from a corrupted record).
    private func toDomain(_ model: FeedLogModel) -> FeedLog? {
        let source = sourceFromString(model.sourceValue)
        // try? is intentional: a corrupted record (e.g. negative volume from a
        // bad CloudKit sync) must not crash the app.  compactMap in `all()`
        // silently drops the unreadable row, which is acceptable because the
        // original data is still in the persistent store and will be readable
        // once the schema/validation is updated.
        return try? FeedLog(
            id: model.id,
            volumeMl: model.volumeMl,
            loggedAt: model.loggedAt,
            source: source,
            notes: model.notes
        )
    }

    // MARK: - FeedSource <-> String mapping

    /// Manual mapping because `FeedSource` is not `RawRepresentable`.
    private func sourceToString(_ source: FeedSource) -> String {
        switch source {
        case .bottle: return "bottle"
        case .breast: return "breast"
        }
    }

    private func sourceFromString(_ value: String) -> FeedSource {
        switch value {
        case "breast": return .breast
        default: return .bottle
        }
    }
}

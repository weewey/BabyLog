import Foundation
import SwiftData
import LittleECore

/// Concrete `PumpingSessionRepository` backed by SwiftData + CloudKit.
///
/// Isolated to `@MainActor` because `ModelContext` is not `Sendable`. All
/// methods are synchronous; Swift lets a `throws` function satisfy an
/// `async throws` protocol requirement.
@MainActor
final class SwiftDataPumpingSessionRepository: PumpingSessionRepository {

    nonisolated init(context: ModelContext) {
        self.context = context
    }

    // MARK: - Dependencies

    private let context: ModelContext

    // MARK: - PumpingSessionRepository

    func save(_ session: PumpingSession) throws {
        try upsert(session)
    }

    func update(_ session: PumpingSession) throws {
        try upsert(session)
    }

    func delete(id: UUID) throws {
        let existing = FetchDescriptor<PumpingSessionModel>(
            predicate: #Predicate { $0.id == id }
        )
        if let model = try context.fetch(existing).first {
            context.delete(model)
            try context.save()
        }
    }

    func all() throws -> [PumpingSession] {
        let descriptor = FetchDescriptor<PumpingSessionModel>(
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        return try context.fetch(descriptor).compactMap(toDomain)
    }

    func recent(limit: Int) throws -> [PumpingSession] {
        guard limit > 0 else { return [] }
        var descriptor = FetchDescriptor<PumpingSessionModel>(
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return try context.fetch(descriptor).compactMap(toDomain)
    }

    // MARK: - Upsert helper

    private func upsert(_ session: PumpingSession) throws {
        let sessionID = session.id
        let existing = FetchDescriptor<PumpingSessionModel>(
            predicate: #Predicate { $0.id == sessionID }
        )
        if let prior = try context.fetch(existing).first {
            context.delete(prior)
        }
        context.insert(toModel(session))
        try context.save()
    }

    // MARK: - Mapping helpers

    private func toModel(_ session: PumpingSession) -> PumpingSessionModel {
        PumpingSessionModel(
            id: session.id,
            startedAt: session.startedAt,
            durationMinutes: session.durationMinutes,
            sideValue: session.side?.rawValue,
            milkVolumeMl: session.milkVolumeMl,
            pumpBrand: session.pumpBrand,
            scheduleSlotId: session.scheduleSlotId,
            notes: session.notes
        )
    }

    /// Persistence model -> domain type. Returns `nil` on validation failure
    /// so a corrupted row never crashes the app.
    private func toDomain(_ model: PumpingSessionModel) -> PumpingSession? {
        let side = model.sideValue.flatMap { PumpingSide(rawValue: $0) }
        return try? PumpingSession(
            id: model.id,
            startedAt: model.startedAt,
            durationMinutes: model.durationMinutes,
            side: side,
            milkVolumeMl: model.milkVolumeMl,
            pumpBrand: model.pumpBrand,
            scheduleSlotId: model.scheduleSlotId,
            notes: model.notes
        )
    }
}

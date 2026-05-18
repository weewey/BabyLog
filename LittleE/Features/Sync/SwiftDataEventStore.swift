import Foundation
import OSLog
import SwiftData
import LittleECore

private let eventStoreLog = Logger(subsystem: "com.littlee.app", category: "SwiftDataEventStore")

/// `EventStore` backed by SwiftData. Persists every `DomainEvent` as a
/// `DomainEventModel` row so the event log survives app restarts.
///
/// Isolated to `@MainActor` for the same reason as the other SwiftData
/// repos: `ModelContext` is not `Sendable`, so we serialise all access on
/// the main actor. The `EventStore` protocol's `async` requirements are
/// satisfied via main-actor hops from arbitrary callers.
@MainActor
final class SwiftDataEventStore: EventStore {

    private let context: ModelContext

    nonisolated init(context: ModelContext) {
        self.context = context
    }

    // MARK: - EventStore

    func append(_ event: DomainEvent) async throws {
        let eid = event.id.value
        let existing = FetchDescriptor<DomainEventModel>(
            predicate: #Predicate { $0.eventID == eid }
        )
        if let count = try? context.fetchCount(existing), count > 0 {
            return
        }
        context.insert(DomainEventModel(event: event))
        do {
            try context.save()
        } catch {
            eventStoreLog.error("append(single) save failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    func append(_ events: [DomainEvent]) async throws {
        guard !events.isEmpty else { return }
        let ids = events.map(\.id.value)
        let existing = FetchDescriptor<DomainEventModel>(
            predicate: #Predicate { ids.contains($0.eventID) }
        )
        let seen: Set<UUID> = Set(
            ((try? context.fetch(existing)) ?? []).map(\.eventID)
        )
        for event in events where !seen.contains(event.id.value) {
            context.insert(DomainEventModel(event: event))
        }
        do {
            try context.save()
        } catch {
            eventStoreLog.error("append(batch) save failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    func all() async -> [DomainEvent] {
        let descriptor = FetchDescriptor<DomainEventModel>(
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )
        let rows = (try? context.fetch(descriptor)) ?? []
        return rows.compactMap { $0.toDomain() }
    }

    func eventsMissing(from peer: SeenVector) async -> [DomainEvent] {
        let events = await all()
        return events.filter { !peer.contains($0) }
    }

    func seenVector() async -> SeenVector {
        let events = await all()
        var entries: [DeviceID: Set<EventID>] = [:]
        for event in events {
            entries[event.deviceID, default: []].insert(event.id)
        }
        return SeenVector(entries: entries)
    }
}

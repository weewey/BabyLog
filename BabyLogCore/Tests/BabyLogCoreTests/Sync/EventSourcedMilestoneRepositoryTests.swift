import Foundation
import Testing
@testable import BabyLogCore

@Suite("EventSourcedMilestoneRepository")
struct EventSourcedMilestoneRepositoryTests {

    private final class TickingClock: Clock, @unchecked Sendable {
        private var current: Date
        init(start: Date = Date(timeIntervalSince1970: 1_000)) { self.current = start }
        func now() -> Date { defer { current = current.addingTimeInterval(1) }; return current }
    }

    private func makeMilestone(
        id: UUID = UUID(),
        title: String = "First smile",
        achievedAt: TimeInterval = 1_000
    ) throws -> Milestone {
        try Milestone(id: id, title: title, achievedAt: Date(timeIntervalSince1970: achievedAt))
    }

    @Test("saved milestone is retrievable via all()")
    func saveThenAll() async throws {
        let repo = EventSourcedMilestoneRepository(
            store: InMemoryEventStore(),
            deviceID: DeviceID("A"),
            clock: TickingClock()
        )
        let m = try makeMilestone()
        try await repo.save(m)

        let all = try await repo.all()
        #expect(all == [m])
    }

    @Test("all() returns milestones sorted newest-first by achievedAt")
    func allSortsNewestFirst() async throws {
        let repo = EventSourcedMilestoneRepository(
            store: InMemoryEventStore(),
            deviceID: DeviceID("A"),
            clock: TickingClock()
        )
        let older = try makeMilestone(title: "Head up", achievedAt: 100)
        let newer = try makeMilestone(title: "Rolled over", achievedAt: 5_000)

        try await repo.save(older)
        try await repo.save(newer)

        let all = try await repo.all()
        #expect(all.map(\.id) == [newer.id, older.id])
    }

    @Test("edit supersedes prior milestone")
    func editSupersedes() async throws {
        let repo = EventSourcedMilestoneRepository(
            store: InMemoryEventStore(),
            deviceID: DeviceID("A"),
            clock: TickingClock()
        )
        let id = UUID()
        try await repo.save(try makeMilestone(id: id, title: "Smile"))
        try await repo.save(try makeMilestone(id: id, title: "First real smile"))

        let all = try await repo.all()
        #expect(all.count == 1)
        #expect(all.first?.title == "First real smile")
    }

    @Test("delete tombstones the milestone")
    func deleteTombstones() async throws {
        let repo = EventSourcedMilestoneRepository(
            store: InMemoryEventStore(),
            deviceID: DeviceID("A"),
            clock: TickingClock()
        )
        let m = try makeMilestone()
        try await repo.save(m)
        try await repo.delete(id: m.id)

        #expect(try await repo.all().isEmpty)
    }

    @Test("remote edit wins on merge")
    func mergeAcrossDevices() async throws {
        let store = InMemoryEventStore()
        let local = EventSourcedMilestoneRepository(
            store: store,
            deviceID: DeviceID("A"),
            clock: TickingClock(start: Date(timeIntervalSince1970: 10))
        )
        let id = UUID()
        try await local.save(try makeMilestone(id: id, title: "Smile"))

        let remote = try makeMilestone(id: id, title: "Giggle")
        let event = DomainEvent(
            deviceID: DeviceID("B"),
            timestamp: Date(timeIntervalSince1970: 100),
            kind: .milestone,
            operation: .upsert,
            recordID: id.uuidString,
            payload: try SyncableDomainCodec.encode(remote)
        )
        try await store.append(event)

        let all = try await local.all()
        #expect(all.count == 1)
        #expect(all.first?.title == "Giggle")
    }

    @Test("empty-title payload from a corrupt peer is dropped")
    func corruptPeerDataDropped() async throws {
        let store = InMemoryEventStore()
        let repo = EventSourcedMilestoneRepository(
            store: store,
            deviceID: DeviceID("A"),
            clock: TickingClock()
        )
        let id = UUID()
        let bad = MilestoneWire(id: id, title: "   ", achievedAt: Date(), notes: nil)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let event = DomainEvent(
            deviceID: DeviceID("B"),
            timestamp: Date(timeIntervalSince1970: 1),
            kind: .milestone,
            operation: .upsert,
            recordID: id.uuidString,
            payload: try encoder.encode(bad)
        )
        try await store.append(event)

        #expect(try await repo.all().isEmpty)
    }
}

import Foundation
import Testing
@testable import BabyLogCore

@Suite("EventSourcedDiaperLogRepository")
struct EventSourcedDiaperLogRepositoryTests {

    private final class TickingClock: Clock, @unchecked Sendable {
        private var current: Date
        init(start: Date = Date(timeIntervalSince1970: 1_000)) { self.current = start }
        func now() -> Date { defer { current = current.addingTimeInterval(1) }; return current }
    }

    private func makeLog(
        id: UUID = UUID(),
        type: DiaperType = .wet,
        loggedAt: TimeInterval = 500
    ) -> DiaperLog {
        DiaperLog(id: id, type: type, loggedAt: Date(timeIntervalSince1970: loggedAt))
    }

    @Test("saved diaper is retrievable via all()")
    func saveThenAll() async throws {
        let repo = EventSourcedDiaperLogRepository(
            store: InMemoryEventStore(),
            deviceID: DeviceID("A"),
            clock: TickingClock()
        )
        let log = makeLog()

        try await repo.save(log)

        let all = try await repo.all()
        #expect(all == [log])
    }

    @Test("all() returns diapers sorted newest-first by loggedAt")
    func allSortsNewestFirst() async throws {
        let repo = EventSourcedDiaperLogRepository(
            store: InMemoryEventStore(),
            deviceID: DeviceID("A"),
            clock: TickingClock()
        )
        let older = makeLog(loggedAt: 100)
        let newer = makeLog(loggedAt: 500)

        try await repo.save(older)
        try await repo.save(newer)

        let all = try await repo.all()
        #expect(all.map(\.id) == [newer.id, older.id])
    }

    @Test("saving with the same id overwrites the previous event")
    func editSupersedes() async throws {
        let repo = EventSourcedDiaperLogRepository(
            store: InMemoryEventStore(),
            deviceID: DeviceID("A"),
            clock: TickingClock()
        )
        let id = UUID()
        try await repo.save(makeLog(id: id, type: .wet))
        try await repo.save(makeLog(id: id, type: .dirty))

        let all = try await repo.all()
        #expect(all.count == 1)
        #expect(all.first?.type == .dirty)
    }

    @Test("delete tombstones a diaper record")
    func deleteTombstones() async throws {
        let repo = EventSourcedDiaperLogRepository(
            store: InMemoryEventStore(),
            deviceID: DeviceID("A"),
            clock: TickingClock()
        )
        let log = makeLog()
        try await repo.save(log)
        try await repo.delete(id: log.id)

        let all = try await repo.all()
        #expect(all.isEmpty)
    }

    @Test("remote edit from another device wins on merge")
    func mergeAcrossDevices() async throws {
        let store = InMemoryEventStore()
        let local = EventSourcedDiaperLogRepository(
            store: store,
            deviceID: DeviceID("A"),
            clock: TickingClock(start: Date(timeIntervalSince1970: 10))
        )
        let id = UUID()
        try await local.save(makeLog(id: id, type: .wet))

        let remoteLog = makeLog(id: id, type: .dirty)
        let remoteEvent = DomainEvent(
            deviceID: DeviceID("B"),
            timestamp: Date(timeIntervalSince1970: 100),
            kind: .diaperLog,
            operation: .upsert,
            recordID: id.uuidString,
            payload: try SyncableDomainCodec.encode(remoteLog)
        )
        try await store.append(remoteEvent)

        let all = try await local.all()
        #expect(all.count == 1)
        #expect(all.first?.type == .dirty)
    }
}

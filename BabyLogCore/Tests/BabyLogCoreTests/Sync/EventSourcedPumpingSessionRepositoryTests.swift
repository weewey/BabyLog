import Foundation
import Testing
@testable import BabyLogCore

@Suite("EventSourcedPumpingSessionRepository")
struct EventSourcedPumpingSessionRepositoryTests {

    private final class TickingClock: Clock, @unchecked Sendable {
        private var current: Date
        init(start: Date = Date(timeIntervalSince1970: 1_000)) { self.current = start }
        func now() -> Date { defer { current = current.addingTimeInterval(1) }; return current }
    }

    private func makeSession(
        id: UUID = UUID(),
        startedAt: TimeInterval = 500,
        durationMinutes: Int = 20,
        milkVolumeMl: Int? = 120
    ) throws -> PumpingSession {
        try PumpingSession(
            id: id,
            startedAt: Date(timeIntervalSince1970: startedAt),
            durationMinutes: durationMinutes,
            side: .both,
            milkVolumeMl: milkVolumeMl,
            pumpBrand: "Medela"
        )
    }

    @Test("saved session is retrievable via all()")
    func saveThenAll() async throws {
        let repo = EventSourcedPumpingSessionRepository(
            store: InMemoryEventStore(),
            deviceID: DeviceID("A"),
            clock: TickingClock()
        )
        let session = try makeSession()
        try await repo.save(session)

        let all = try await repo.all()
        #expect(all == [session])
    }

    @Test("all() returns sessions sorted newest-first by startedAt")
    func allSortsNewestFirst() async throws {
        let repo = EventSourcedPumpingSessionRepository(
            store: InMemoryEventStore(),
            deviceID: DeviceID("A"),
            clock: TickingClock()
        )
        let older = try makeSession(startedAt: 100)
        let newer = try makeSession(startedAt: 500)

        try await repo.save(older)
        try await repo.save(newer)

        let all = try await repo.all()
        #expect(all.map(\.id) == [newer.id, older.id])
    }

    @Test("update() supersedes prior session with same id")
    func updateSupersedes() async throws {
        let repo = EventSourcedPumpingSessionRepository(
            store: InMemoryEventStore(),
            deviceID: DeviceID("A"),
            clock: TickingClock()
        )
        let id = UUID()
        try await repo.save(try makeSession(id: id, milkVolumeMl: 100))
        try await repo.update(try makeSession(id: id, milkVolumeMl: 180))

        let all = try await repo.all()
        #expect(all.count == 1)
        #expect(all.first?.milkVolumeMl == 180)
    }

    @Test("delete tombstones a session")
    func deleteTombstones() async throws {
        let repo = EventSourcedPumpingSessionRepository(
            store: InMemoryEventStore(),
            deviceID: DeviceID("A"),
            clock: TickingClock()
        )
        let session = try makeSession()
        try await repo.save(session)
        try await repo.delete(id: session.id)

        #expect(try await repo.all().isEmpty)
    }

    @Test("recent(limit:) returns newest N sessions")
    func recentLimits() async throws {
        let repo = EventSourcedPumpingSessionRepository(
            store: InMemoryEventStore(),
            deviceID: DeviceID("A"),
            clock: TickingClock()
        )
        for offset in 0..<5 {
            try await repo.save(try makeSession(startedAt: TimeInterval(100 * offset)))
        }

        let recent = try await repo.recent(limit: 2)
        #expect(recent.count == 2)
        #expect(recent[0].startedAt > recent[1].startedAt)
    }

    @Test("recent(limit:) with zero returns empty")
    func recentZero() async throws {
        let repo = EventSourcedPumpingSessionRepository(
            store: InMemoryEventStore(),
            deviceID: DeviceID("A"),
            clock: TickingClock()
        )
        try await repo.save(try makeSession())
        #expect(try await repo.recent(limit: 0).isEmpty)
    }

    @Test("remote edit wins on merge")
    func mergeAcrossDevices() async throws {
        let store = InMemoryEventStore()
        let local = EventSourcedPumpingSessionRepository(
            store: store,
            deviceID: DeviceID("A"),
            clock: TickingClock(start: Date(timeIntervalSince1970: 10))
        )
        let id = UUID()
        try await local.save(try makeSession(id: id, milkVolumeMl: 100))

        let remote = try makeSession(id: id, milkVolumeMl: 240)
        let event = DomainEvent(
            deviceID: DeviceID("B"),
            timestamp: Date(timeIntervalSince1970: 100),
            kind: .pumpingSession,
            operation: .upsert,
            recordID: id.uuidString,
            payload: try SyncableDomainCodec.encode(remote)
        )
        try await store.append(event)

        let all = try await local.all()
        #expect(all.count == 1)
        #expect(all.first?.milkVolumeMl == 240)
    }

    @Test("corrupt wire payload (bad duration) is dropped by fromWire")
    func corruptPeerDataDropped() async throws {
        let store = InMemoryEventStore()
        let repo = EventSourcedPumpingSessionRepository(
            store: store,
            deviceID: DeviceID("A"),
            clock: TickingClock()
        )
        let id = UUID()
        let bad = PumpingSessionWire(
            id: id,
            startedAt: Date(),
            durationMinutes: 0,
            side: .both,
            milkVolumeMl: 100,
            pumpBrand: "Medela",
            scheduleSlotId: nil,
            notes: nil
        )
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let event = DomainEvent(
            deviceID: DeviceID("B"),
            timestamp: Date(timeIntervalSince1970: 1),
            kind: .pumpingSession,
            operation: .upsert,
            recordID: id.uuidString,
            payload: try encoder.encode(bad)
        )
        try await store.append(event)

        #expect(try await repo.all().isEmpty)
    }
}

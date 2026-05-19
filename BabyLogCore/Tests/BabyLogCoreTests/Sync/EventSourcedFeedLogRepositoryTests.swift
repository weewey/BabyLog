import Foundation
import Testing
@testable import BabyLogCore

@Suite("EventSourcedFeedLogRepository")
struct EventSourcedFeedLogRepositoryTests {

    // MARK: - Helpers

    /// Monotonic test clock: each call to `now()` advances by one second.
    private final class TickingClock: Clock, @unchecked Sendable {
        private var current: Date
        init(start: Date = Date(timeIntervalSince1970: 1_000)) {
            self.current = start
        }
        func now() -> Date {
            let t = current
            current = current.addingTimeInterval(1)
            return t
        }
    }

    private func makeFeed(
        id: UUID = UUID(),
        volumeMl: Int = 120,
        loggedAt: TimeInterval = 500,
        notes: String? = nil
    ) throws -> FeedLog {
        try FeedLog(
            id: id,
            volumeMl: volumeMl,
            loggedAt: Date(timeIntervalSince1970: loggedAt),
            source: .bottle,
            notes: notes
        )
    }

    // MARK: - Save / all

    @Test("saving a feed is retrievable via all()")
    func saveThenAll() async throws {
        let repo = EventSourcedFeedLogRepository(
            store: InMemoryEventStore(),
            deviceID: DeviceID("A"),
            clock: TickingClock()
        )
        let feed = try makeFeed()

        try await repo.save(feed)

        let all = try await repo.all()
        #expect(all == [feed])
    }

    @Test("all() returns feeds sorted newest-first by loggedAt")
    func allSortsNewestFirst() async throws {
        let repo = EventSourcedFeedLogRepository(
            store: InMemoryEventStore(),
            deviceID: DeviceID("A"),
            clock: TickingClock()
        )
        let older = try makeFeed(loggedAt: 100)
        let newer = try makeFeed(loggedAt: 500)

        try await repo.save(older)
        try await repo.save(newer)

        let all = try await repo.all()
        #expect(all.map(\.id) == [newer.id, older.id])
    }

    // MARK: - Edits supersede

    @Test("saving a feed with the same id overwrites the previous event")
    func editSupersedes() async throws {
        let repo = EventSourcedFeedLogRepository(
            store: InMemoryEventStore(),
            deviceID: DeviceID("A"),
            clock: TickingClock()
        )
        let id = UUID()
        let original = try makeFeed(id: id, volumeMl: 100)
        let edited = try makeFeed(id: id, volumeMl: 200)

        try await repo.save(original)
        try await repo.save(edited)

        let all = try await repo.all()
        #expect(all.count == 1)
        #expect(all.first?.volumeMl == 200)
    }

    // MARK: - Delete

    @Test("delete tombstones a record and removes it from all()")
    func deleteTombstones() async throws {
        let repo = EventSourcedFeedLogRepository(
            store: InMemoryEventStore(),
            deviceID: DeviceID("A"),
            clock: TickingClock()
        )
        let feed = try makeFeed()
        try await repo.save(feed)

        try await repo.delete(id: feed.id)

        let all = try await repo.all()
        #expect(all.isEmpty)
    }

    // MARK: - Merge across devices

    @Test("merging remote events materialises latest-wins across devices")
    func mergeAcrossDevices() async throws {
        let store = InMemoryEventStore()
        let localRepo = EventSourcedFeedLogRepository(
            store: store,
            deviceID: DeviceID("A"),
            clock: TickingClock(start: Date(timeIntervalSince1970: 10))
        )
        let id = UUID()
        let localFeed = try makeFeed(id: id, volumeMl: 100)
        try await localRepo.save(localFeed)

        // Remote device B appends a later edit directly into the shared store.
        let remoteFeed = try makeFeed(id: id, volumeMl: 250)
        let remoteEvent = DomainEvent(
            deviceID: DeviceID("B"),
            timestamp: Date(timeIntervalSince1970: 100),
            kind: .feedLog,
            operation: .upsert,
            recordID: id.uuidString,
            payload: try FeedLogEventCodec.encode(remoteFeed)
        )
        try await store.append(remoteEvent)

        let all = try await localRepo.all()
        #expect(all.count == 1)
        #expect(all.first?.volumeMl == 250)
    }

    // MARK: - Re-apply idempotency

    @Test("replaying the same events twice produces the same state")
    func replayIsIdempotent() async throws {
        let storeA = InMemoryEventStore()
        let repoA = EventSourcedFeedLogRepository(
            store: storeA,
            deviceID: DeviceID("A"),
            clock: TickingClock()
        )
        let feed = try makeFeed()
        try await repoA.save(feed)

        let events = await storeA.all()
        let storeB = InMemoryEventStore()
        try await storeB.append(events)
        try await storeB.append(events) // second apply should be a no-op

        let repoB = EventSourcedFeedLogRepository(
            store: storeB,
            deviceID: DeviceID("B"),
            clock: TickingClock()
        )
        let all = try await repoB.all()
        #expect(all == [feed])
    }
}

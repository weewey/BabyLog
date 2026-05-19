import Foundation
import Testing
@testable import BabyLogCore

@Suite("InMemoryEventStore")
struct EventStoreTests {

    // MARK: - Helpers

    private func makeEvent(
        id: UUID = UUID(),
        device: String = "A",
        timestamp: TimeInterval = 0,
        kind: DomainEventKind = .feedLog,
        operation: DomainEventOperation = .upsert,
        recordID: String = "r-1",
        payload: String = "{}"
    ) -> DomainEvent {
        DomainEvent(
            id: EventID(id),
            deviceID: DeviceID(device),
            timestamp: Date(timeIntervalSince1970: timestamp),
            kind: kind,
            operation: operation,
            recordID: recordID,
            payload: Data(payload.utf8)
        )
    }

    // MARK: - append / all

    @Test("append then all returns the appended event")
    func appendThenAll() async throws {
        let store = InMemoryEventStore()
        let event = makeEvent()

        try await store.append(event)

        let events = await store.all()
        #expect(events == [event])
    }

    @Test("append is idempotent on event id")
    func appendIdempotent() async throws {
        let store = InMemoryEventStore()
        let event = makeEvent()

        try await store.append(event)
        try await store.append(event)

        let events = await store.all()
        #expect(events.count == 1)
    }

    @Test("batch append preserves order and idempotency")
    func batchAppend() async throws {
        let store = InMemoryEventStore()
        let e1 = makeEvent(timestamp: 1, recordID: "r-1")
        let e2 = makeEvent(timestamp: 2, recordID: "r-2")

        try await store.append([e1, e2, e1])

        let events = await store.all()
        #expect(events.map(\.recordID) == ["r-1", "r-2"])
    }

    // MARK: - seen vector + delta

    @Test("seenVector groups event ids by originating device")
    func seenVectorGroupsByDevice() async throws {
        let store = InMemoryEventStore()
        let a = makeEvent(device: "A")
        let b = makeEvent(device: "B")

        try await store.append([a, b])

        let vector = await store.seenVector()
        #expect(vector.entries[DeviceID("A")] == [a.id])
        #expect(vector.entries[DeviceID("B")] == [b.id])
    }

    @Test("eventsMissing returns only events the peer does not have")
    func eventsMissingComputesDelta() async throws {
        let local = InMemoryEventStore()
        let shared = makeEvent(device: "A", timestamp: 1)
        let localOnly = makeEvent(device: "A", timestamp: 2)

        try await local.append([shared, localOnly])
        let peerVector = SeenVector(entries: [DeviceID("A"): [shared.id]])

        let delta = await local.eventsMissing(from: peerVector)
        #expect(delta == [localOnly])
    }

    // MARK: - ordering

    @Test("supersedes prefers newer timestamp")
    func supersedesByTimestamp() {
        let old = makeEvent(timestamp: 1)
        let new = makeEvent(timestamp: 2)

        #expect(DomainEvent.supersedes(new, old))
        #expect(!DomainEvent.supersedes(old, new))
    }

    @Test("supersedes tie-breaks on device id when timestamps equal")
    func supersedesTieBreaksOnDevice() {
        let a = makeEvent(device: "A", timestamp: 5)
        let b = makeEvent(device: "B", timestamp: 5)

        #expect(DomainEvent.supersedes(b, a))
        #expect(!DomainEvent.supersedes(a, b))
    }
}

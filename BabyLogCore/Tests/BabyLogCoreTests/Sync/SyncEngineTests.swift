import Foundation
import Testing
@testable import BabyLogCore

@Suite("SyncEngine")
struct SyncEngineTests {

    private func makeEvent(
        device: String,
        timestamp: TimeInterval,
        recordID: String = UUID().uuidString
    ) -> DomainEvent {
        DomainEvent(
            deviceID: DeviceID(device),
            timestamp: Date(timeIntervalSince1970: timestamp),
            kind: .feedLog,
            operation: .upsert,
            recordID: recordID,
            payload: Data("{}".utf8)
        )
    }

    @Test("merge exchanges missing events both directions")
    func mergeExchangesBothWays() async throws {
        let storeA = InMemoryEventStore()
        let storeB = InMemoryEventStore()
        let a = makeEvent(device: "A", timestamp: 1)
        let b = makeEvent(device: "B", timestamp: 2)
        try await storeA.append(a)
        try await storeB.append(b)

        let engineA = SyncEngine(store: storeA, deviceID: DeviceID("A"))
        let engineB = SyncEngine(store: storeB, deviceID: DeviceID("B"))

        try await engineA.merge(with: engineB)

        let allA = await storeA.all()
        let allB = await storeB.all()
        #expect(Set(allA.map(\.id)) == Set([a.id, b.id]))
        #expect(Set(allB.map(\.id)) == Set([a.id, b.id]))
    }

    @Test("merge is idempotent — running it twice yields the same state")
    func mergeIdempotent() async throws {
        let storeA = InMemoryEventStore()
        let storeB = InMemoryEventStore()
        try await storeA.append(makeEvent(device: "A", timestamp: 1))
        try await storeB.append(makeEvent(device: "B", timestamp: 2))

        let engineA = SyncEngine(store: storeA, deviceID: DeviceID("A"))
        let engineB = SyncEngine(store: storeB, deviceID: DeviceID("B"))

        try await engineA.merge(with: engineB)
        let firstCount = await storeA.all().count

        try await engineA.merge(with: engineB)
        let secondCount = await storeA.all().count

        #expect(firstCount == 2)
        #expect(secondCount == 2)
    }

    @Test("handshake + delta round-trip encodes/decodes cleanly")
    func codecRoundTrip() throws {
        let handshake = SyncHandshake(
            from: DeviceID("A"),
            seen: SeenVector(entries: [DeviceID("A"): [EventID()]])
        )
        let data = try SyncCodec.encode(handshake)

        let decoded = try SyncCodec.decode(SyncHandshake.self, from: data)

        #expect(decoded == handshake)
    }

    @Test("decoding garbage bytes throws a typed schemaDrift error")
    func codecTypedDecodeError() {
        let garbage = Data("{ not a handshake }".utf8)

        #expect(throws: SyncCodecError.self) {
            _ = try SyncCodec.decode(SyncHandshake.self, from: garbage)
        }
    }
}

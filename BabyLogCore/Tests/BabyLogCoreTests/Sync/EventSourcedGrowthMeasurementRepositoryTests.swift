import Foundation
import Testing
@testable import BabyLogCore

@Suite("EventSourcedGrowthMeasurementRepository")
struct EventSourcedGrowthMeasurementRepositoryTests {

    private final class TickingClock: Clock, @unchecked Sendable {
        private var current: Date
        init(start: Date = Date(timeIntervalSince1970: 1_000)) { self.current = start }
        func now() -> Date { defer { current = current.addingTimeInterval(1) }; return current }
    }

    private func makeMeasurement(
        id: GrowthMeasurementID = GrowthMeasurementID(),
        date: TimeInterval = 1_000,
        weightGrams: Int? = 5_000
    ) throws -> GrowthMeasurement {
        try GrowthMeasurement(
            id: id,
            date: Date(timeIntervalSince1970: date),
            weightGrams: weightGrams,
            heightCm: 55,
            headCircumferenceCm: 38
        )
    }

    @Test("saved measurement is retrievable via all()")
    func saveThenAll() async throws {
        let repo = EventSourcedGrowthMeasurementRepository(
            store: InMemoryEventStore(),
            deviceID: DeviceID("A"),
            clock: TickingClock()
        )
        let m = try makeMeasurement()
        try await repo.save(m)

        let all = try await repo.all()
        #expect(all == [m])
    }

    @Test("all() returns measurements sorted earliest-first by date")
    func allSortsEarliestFirst() async throws {
        let repo = EventSourcedGrowthMeasurementRepository(
            store: InMemoryEventStore(),
            deviceID: DeviceID("A"),
            clock: TickingClock()
        )
        let later = try makeMeasurement(date: 5_000, weightGrams: 6_000)
        let earlier = try makeMeasurement(date: 1_000, weightGrams: 5_000)

        try await repo.save(later)
        try await repo.save(earlier)

        let all = try await repo.all()
        #expect(all.map(\.id) == [earlier.id, later.id])
    }

    @Test("resaving with same id supersedes")
    func resaveSupersedes() async throws {
        let repo = EventSourcedGrowthMeasurementRepository(
            store: InMemoryEventStore(),
            deviceID: DeviceID("A"),
            clock: TickingClock()
        )
        let id = GrowthMeasurementID()
        try await repo.save(try makeMeasurement(id: id, weightGrams: 5_000))
        try await repo.save(try makeMeasurement(id: id, weightGrams: 5_200))

        let all = try await repo.all()
        #expect(all.count == 1)
        #expect(all.first?.weightGrams == 5_200)
    }

    @Test("delete tombstones the measurement")
    func deleteTombstones() async throws {
        let repo = EventSourcedGrowthMeasurementRepository(
            store: InMemoryEventStore(),
            deviceID: DeviceID("A"),
            clock: TickingClock()
        )
        let m = try makeMeasurement()
        try await repo.save(m)
        try await repo.delete(id: m.id.value)

        #expect(try await repo.all().isEmpty)
    }

    @Test("remote edit wins on merge")
    func mergeAcrossDevices() async throws {
        let store = InMemoryEventStore()
        let local = EventSourcedGrowthMeasurementRepository(
            store: store,
            deviceID: DeviceID("A"),
            clock: TickingClock(start: Date(timeIntervalSince1970: 10))
        )
        let id = GrowthMeasurementID()
        try await local.save(try makeMeasurement(id: id, weightGrams: 5_000))

        let remote = try makeMeasurement(id: id, weightGrams: 5_500)
        let event = DomainEvent(
            deviceID: DeviceID("B"),
            timestamp: Date(timeIntervalSince1970: 100),
            kind: .growthMeasurement,
            operation: .upsert,
            recordID: id.value.uuidString,
            payload: try SyncableDomainCodec.encode(remote)
        )
        try await store.append(event)

        let all = try await local.all()
        #expect(all.count == 1)
        #expect(all.first?.weightGrams == 5_500)
    }

    @Test("corrupt wire payload (out-of-range weight) is dropped by fromWire")
    func corruptPeerDataDropped() async throws {
        let store = InMemoryEventStore()
        let repo = EventSourcedGrowthMeasurementRepository(
            store: store,
            deviceID: DeviceID("A"),
            clock: TickingClock()
        )
        let id = UUID()
        let bad = GrowthMeasurementWire(
            id: id,
            date: Date(),
            weightGrams: 50_000,
            heightCm: nil,
            headCircumferenceCm: nil,
            notes: nil
        )
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let event = DomainEvent(
            deviceID: DeviceID("B"),
            timestamp: Date(timeIntervalSince1970: 1),
            kind: .growthMeasurement,
            operation: .upsert,
            recordID: id.uuidString,
            payload: try encoder.encode(bad)
        )
        try await store.append(event)

        #expect(try await repo.all().isEmpty)
    }
}

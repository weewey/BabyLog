import Foundation
import Testing
@testable import BabyLogCore

@Suite("EventSourcedMedicalAppointmentRepository")
struct EventSourcedMedicalAppointmentRepositoryTests {

    private final class TickingClock: Clock, @unchecked Sendable {
        private var current: Date
        init(start: Date = Date(timeIntervalSince1970: 1_000)) { self.current = start }
        func now() -> Date { defer { current = current.addingTimeInterval(1) }; return current }
    }

    private func makeAppt(
        id: UUID = UUID(),
        title: String = "Pediatrician",
        scheduledAt: TimeInterval = 1_000
    ) throws -> MedicalAppointment {
        try MedicalAppointment(
            id: id,
            title: title,
            scheduledAt: Date(timeIntervalSince1970: scheduledAt)
        )
    }

    @Test("saved appointment is retrievable via all()")
    func saveThenAll() async throws {
        let repo = EventSourcedMedicalAppointmentRepository(
            store: InMemoryEventStore(),
            deviceID: DeviceID("A"),
            clock: TickingClock()
        )
        let appt = try makeAppt()
        try await repo.save(appt)

        let all = try await repo.all()
        #expect(all == [appt])
    }

    @Test("all() returns appointments sorted earliest-first by scheduledAt")
    func allSortsEarliestFirst() async throws {
        let repo = EventSourcedMedicalAppointmentRepository(
            store: InMemoryEventStore(),
            deviceID: DeviceID("A"),
            clock: TickingClock()
        )
        let later = try makeAppt(title: "Vaccines", scheduledAt: 5_000)
        let sooner = try makeAppt(title: "Checkup", scheduledAt: 1_000)

        try await repo.save(later)
        try await repo.save(sooner)

        let all = try await repo.all()
        #expect(all.map(\.id) == [sooner.id, later.id])
    }

    @Test("edit supersedes prior appointment")
    func editSupersedes() async throws {
        let repo = EventSourcedMedicalAppointmentRepository(
            store: InMemoryEventStore(),
            deviceID: DeviceID("A"),
            clock: TickingClock()
        )
        let id = UUID()
        try await repo.save(try makeAppt(id: id, title: "Checkup"))
        try await repo.save(try makeAppt(id: id, title: "Checkup rescheduled"))

        let all = try await repo.all()
        #expect(all.count == 1)
        #expect(all.first?.title == "Checkup rescheduled")
    }

    @Test("delete tombstones the appointment")
    func deleteTombstones() async throws {
        let repo = EventSourcedMedicalAppointmentRepository(
            store: InMemoryEventStore(),
            deviceID: DeviceID("A"),
            clock: TickingClock()
        )
        let appt = try makeAppt()
        try await repo.save(appt)
        try await repo.delete(id: appt.id)

        #expect(try await repo.all().isEmpty)
    }

    @Test("remote edit wins on merge")
    func mergeAcrossDevices() async throws {
        let store = InMemoryEventStore()
        let local = EventSourcedMedicalAppointmentRepository(
            store: store,
            deviceID: DeviceID("A"),
            clock: TickingClock(start: Date(timeIntervalSince1970: 10))
        )
        let id = UUID()
        try await local.save(try makeAppt(id: id, title: "Checkup"))

        let remote = try makeAppt(id: id, title: "Checkup moved")
        let event = DomainEvent(
            deviceID: DeviceID("B"),
            timestamp: Date(timeIntervalSince1970: 100),
            kind: .medicalAppointment,
            operation: .upsert,
            recordID: id.uuidString,
            payload: try SyncableDomainCodec.encode(remote)
        )
        try await store.append(event)

        let all = try await local.all()
        #expect(all.count == 1)
        #expect(all.first?.title == "Checkup moved")
    }

    @Test("empty-title payload from a corrupt peer is dropped")
    func corruptPeerDataDropped() async throws {
        let store = InMemoryEventStore()
        let repo = EventSourcedMedicalAppointmentRepository(
            store: store,
            deviceID: DeviceID("A"),
            clock: TickingClock()
        )
        let id = UUID()
        let badWire = MedicalAppointmentWire(
            id: id, title: "   ", scheduledAt: Date(), location: nil, notes: nil
        )
        let payload = try JSONEncoder.iso.encode(badWire)
        let event = DomainEvent(
            deviceID: DeviceID("B"),
            timestamp: Date(timeIntervalSince1970: 1),
            kind: .medicalAppointment,
            operation: .upsert,
            recordID: id.uuidString,
            payload: payload
        )
        try await store.append(event)

        #expect(try await repo.all().isEmpty)
    }
}

private extension JSONEncoder {
    static let iso: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

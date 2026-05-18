import Foundation

public actor EventSourcedMedicalAppointmentRepository: MedicalAppointmentRepository {

    private let inner: EventSourcedRepository<MedicalAppointment>

    public init(
        store: any EventStore,
        deviceID: DeviceID,
        clock: any Clock,
        localWriteNotifier: (any LocalWriteNotifying)? = nil
    ) {
        self.inner = EventSourcedRepository(
            store: store,
            deviceID: deviceID,
            clock: clock,
            localWriteNotifier: localWriteNotifier
        )
    }

    public func save(_ appointment: MedicalAppointment) async throws {
        try await inner.save(appointment)
    }

    public func all() async throws -> [MedicalAppointment] {
        let items = await inner.all()
        return items.sorted { $0.scheduledAt < $1.scheduledAt }
    }

    public func delete(id: UUID) async throws {
        try await inner.delete(syncID: id.uuidString)
    }
}

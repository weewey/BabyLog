import Foundation

public protocol MedicalAppointmentRepository: Sendable {
    func save(_ appointment: MedicalAppointment) async throws
    func all() async throws -> [MedicalAppointment]
    func delete(id: UUID) async throws
}

public actor InMemoryMedicalAppointmentRepository: MedicalAppointmentRepository {
    private var storage: [MedicalAppointment] = []
    public init() {}

    public func save(_ appointment: MedicalAppointment) async throws {
        if let idx = storage.firstIndex(where: { $0.id == appointment.id }) {
            storage[idx] = appointment
        } else {
            storage.append(appointment)
        }
    }

    public func all() async throws -> [MedicalAppointment] {
        storage.sorted { $0.scheduledAt < $1.scheduledAt }
    }

    public func delete(id: UUID) async throws {
        storage.removeAll { $0.id == id }
    }
}

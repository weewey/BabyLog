import Foundation

/// Abstraction over the iOS system calendar. The Core layer owns the
/// protocol so `MedicalAppointmentViewModel` stays testable without
/// importing EventKit. The iOS target provides the concrete adapter.
public protocol CalendarSyncing: Sendable {
    /// Creates or updates the calendar event corresponding to the given
    /// appointment. Implementations are expected to be idempotent —
    /// repeated calls with the same appointment id must not create
    /// duplicate events.
    func upsert(appointment: MedicalAppointment) async

    /// Removes any calendar event previously created for this appointment
    /// id. No-op if none exists.
    func remove(appointmentId: UUID) async
}

import Foundation
@preconcurrency import EventKit
import LittleECore

/// iOS adapter that mirrors `MedicalAppointment`s into the system calendar
/// via EventKit.
///
/// Events are tagged with `url = littlee://appointment/<uuid>` so we can
/// find them again without persisting EKEvent identifiers alongside the
/// appointment model (which would require a SwiftData + CloudKit schema
/// change).
///
/// All operations fail silently if calendar access has been denied — the
/// app still functions, the user just won't see events in Calendar.
final class EventKitCalendarSync: CalendarSyncing {

    private let store: EKEventStore
    private let defaultDurationSeconds: TimeInterval = 30 * 60
    private let isUITesting: Bool

    init(store: EKEventStore = EKEventStore()) {
        self.store = store
        self.isUITesting = ProcessInfo.processInfo.arguments.contains("--ui-testing")
    }

    func requestAccess() async {
        guard !isUITesting else { return }
        _ = try? await store.requestFullAccessToEvents()
    }

    func upsert(appointment: MedicalAppointment) async {
        guard !isUITesting else { return }
        guard await ensureAccess() else { return }
        guard let calendar = store.defaultCalendarForNewEvents else { return }

        await remove(appointmentId: appointment.id)

        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = appointment.title
        event.startDate = appointment.scheduledAt
        event.endDate = appointment.scheduledAt.addingTimeInterval(defaultDurationSeconds)
        event.location = appointment.location
        event.notes = appointment.notes
        event.url = Self.tagURL(for: appointment.id)
        event.addAlarm(EKAlarm(relativeOffset: -15 * 60))

        try? store.save(event, span: .thisEvent, commit: true)
    }

    func remove(appointmentId: UUID) async {
        guard !isUITesting else { return }
        guard await ensureAccess() else { return }
        let tag = Self.tagURL(for: appointmentId)

        let search = NSDate.distantPast
        let horizon = NSDate.distantFuture
        let predicate = store.predicateForEvents(
            withStart: search as Date,
            end: horizon as Date,
            calendars: nil
        )
        for event in store.events(matching: predicate) where event.url == tag {
            try? store.remove(event, span: .thisEvent, commit: true)
        }
    }

    private func ensureAccess() async -> Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            return true
        case .notDetermined:
            return (try? await store.requestFullAccessToEvents()) ?? false
        default:
            return false
        }
    }

    private static func tagURL(for id: UUID) -> URL? {
        URL(string: "littlee://appointment/\(id.uuidString)")
    }
}

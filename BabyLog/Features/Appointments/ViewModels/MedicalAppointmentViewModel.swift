import Foundation
import Observation
import LittleECore

@Observable
final class MedicalAppointmentViewModel {

    var draftTitle: String = ""
    var draftScheduledAt: Date
    var draftLocation: String = ""
    var draftNotes: String = ""

    var canSave: Bool {
        !draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private(set) var entries: [MedicalAppointment] = []
    private(set) var saveError: MedicalAppointmentError?
    private(set) var loadError: (any Error)?

    private let repository: any MedicalAppointmentRepository
    private let clock: any Clock
    private let calendar: (any CalendarSyncing)?

    var upcoming: [MedicalAppointment] {
        let now = clock.now()
        return entries.filter { $0.scheduledAt >= now }
    }

    var past: [MedicalAppointment] {
        let now = clock.now()
        return entries.filter { $0.scheduledAt < now }.reversed()
    }

    init(
        repository: any MedicalAppointmentRepository,
        clock: any Clock,
        calendar: (any CalendarSyncing)? = nil
    ) {
        self.repository = repository
        self.clock = clock
        self.calendar = calendar
        self.draftScheduledAt = clock.now().addingTimeInterval(86_400)
    }

    @MainActor
    func save() async {
        saveError = nil
        do {
            let entry = try MedicalAppointment(
                title: draftTitle,
                scheduledAt: draftScheduledAt,
                location: draftLocation,
                notes: draftNotes
            )
            try await repository.save(entry)
            await calendar?.upsert(appointment: entry)
            await refreshEntries()
            resetDraft()
        } catch let error as MedicalAppointmentError {
            saveError = error
        } catch {
            loadError = error
        }
    }

    @MainActor
    func delete(id: UUID) async {
        do {
            try await repository.delete(id: id)
            await calendar?.remove(appointmentId: id)
            await refreshEntries()
        } catch {
            loadError = error
        }
    }

    @MainActor
    func refreshEntries() async {
        do {
            entries = try await repository.all()
            loadError = nil
        } catch {
            loadError = error
        }
    }

    @MainActor
    private func resetDraft() {
        draftTitle = ""
        draftLocation = ""
        draftNotes = ""
        draftScheduledAt = clock.now().addingTimeInterval(86_400)
    }
}

import Foundation
import Observation
import BabyLogCore

@Observable
final class GrowthMeasurementViewModel {

    var draftDate: Date
    var draftWeightGrams: Int? = nil
    var draftHeightCm: Double? = nil
    var draftHeadCircumferenceCm: Double? = nil
    var draftNotes: String = ""

    var canSave: Bool {
        (try? makeDraft()) != nil
    }

    private(set) var entries: [GrowthMeasurement] = []

    var summary: GrowthAnalytics.Summary {
        GrowthAnalytics.summary(entries, now: clock.now())
    }

    private(set) var saveError: GrowthMeasurementError?
    private(set) var loadError: (any Error)?

    private let repository: any GrowthMeasurementRepository
    private let clock: any Clock

    init(repository: any GrowthMeasurementRepository, clock: any Clock) {
        self.repository = repository
        self.clock = clock
        self.draftDate = clock.now()
    }

    @MainActor
    func save() async {
        saveError = nil
        do {
            let entry = try makeDraft()
            try await repository.save(entry)
            await refreshEntries()
            resetDraft()
        } catch let error as GrowthMeasurementError {
            saveError = error
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

    private func makeDraft() throws(GrowthMeasurementError) -> GrowthMeasurement {
        let trimmedNotes = draftNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        return try GrowthMeasurement(
            date: draftDate,
            weightGrams: draftWeightGrams,
            heightCm: draftHeightCm,
            headCircumferenceCm: draftHeadCircumferenceCm,
            notes: trimmedNotes.isEmpty ? nil : trimmedNotes
        )
    }

    @MainActor
    private func resetDraft() {
        draftDate = clock.now()
        draftWeightGrams = nil
        draftHeightCm = nil
        draftHeadCircumferenceCm = nil
        draftNotes = ""
    }
}

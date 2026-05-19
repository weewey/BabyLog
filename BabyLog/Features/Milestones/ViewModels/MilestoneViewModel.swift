import Foundation
import Observation
import BabyLogCore

@Observable
final class MilestoneViewModel {

    var draftTitle: String = ""
    var draftAchievedAt: Date
    var draftNotes: String = ""

    var canSave: Bool {
        !draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private(set) var entries: [Milestone] = []
    private(set) var saveError: MilestoneError?
    private(set) var loadError: (any Error)?

    private let repository: any MilestoneRepository
    private let clock: any Clock

    init(repository: any MilestoneRepository, clock: any Clock) {
        self.repository = repository
        self.clock = clock
        self.draftAchievedAt = clock.now()
    }

    @MainActor
    func save() async {
        saveError = nil
        do {
            let entry = try Milestone(
                title: draftTitle,
                achievedAt: draftAchievedAt,
                notes: draftNotes
            )
            try await repository.save(entry)
            await refreshEntries()
            resetDraft()
        } catch let error as MilestoneError {
            saveError = error
        } catch {
            loadError = error
        }
    }

    @MainActor
    func delete(id: UUID) async {
        do {
            try await repository.delete(id: id)
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
        draftNotes = ""
        draftAchievedAt = clock.now()
    }
}

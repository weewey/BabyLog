import Foundation
import Observation
import BabyLogCore

@Observable
final class SettingsViewModel {

    var draftName: String = ""
    var draftDOB: Date

    private(set) var savedProfile: ChildProfile?
    private(set) var saveError: ChildProfileError?
    private(set) var loadError: (any Error)?

    private let repository: any ChildProfileRepository
    private let clock: any Clock

    var ageLabel: String? {
        guard let profile = savedProfile else { return nil }
        return ChildAge.shortLabel(dateOfBirth: profile.dateOfBirth, now: clock.now())
    }

    var canSave: Bool {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && draftDOB <= clock.now()
    }

    init(repository: any ChildProfileRepository, clock: any Clock) {
        self.repository = repository
        self.clock = clock
        self.draftDOB = clock.now()
    }

    private static let defaultName = ""
    private static let defaultDateOfBirth: Date = Calendar(identifier: .gregorian)
        .date(from: DateComponents(year: 2024, month: 1, day: 1)) ?? .distantPast

    @MainActor
    func load() async {
        do {
            let profile = try await repository.load()
            savedProfile = profile
            if let profile {
                draftName = profile.name
                draftDOB = profile.dateOfBirth
            } else {
                // No saved profile yet — leave the draft blank so the user
                // fills in their baby's name and date of birth in Settings.
                draftName = Self.defaultName
                draftDOB = Self.defaultDateOfBirth
            }
            loadError = nil
        } catch {
            loadError = error
        }
    }

    @MainActor
    func save() async {
        saveError = nil
        do {
            let profile = try ChildProfile(name: draftName, dateOfBirth: draftDOB, now: clock.now())
            try await repository.save(profile)
            savedProfile = profile
        } catch let error as ChildProfileError {
            saveError = error
        } catch {
            loadError = error
        }
    }
}

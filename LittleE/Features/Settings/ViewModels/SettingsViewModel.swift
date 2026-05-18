import Foundation
import Observation
import LittleECore

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

    /// Seed defaults for the first-run empty state. Private app — two users,
    /// one baby — so hardcoding Ethan Chua / 2026-04-07 beats a blank form.
    private static let defaultName = "Ethan Chua"
    private static let defaultDateOfBirth: Date = {
        var components = DateComponents()
        components.year = 2026
        components.month = 4
        components.day = 7
        return Calendar(identifier: .gregorian).date(from: components) ?? .distantPast
    }()

    @MainActor
    func load() async {
        do {
            let profile = try await repository.load()
            savedProfile = profile
            if let profile {
                draftName = profile.name
                draftDOB = profile.dateOfBirth
            } else {
                // No saved profile — seed the draft with sensible defaults
                // and persist so downstream consumers (age label, etc.)
                // see a real profile immediately.
                draftName = Self.defaultName
                draftDOB = Self.defaultDateOfBirth
                await save()
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

import Testing
import Foundation
@testable import BabyLogCore

@Suite("InMemoryGrowthMeasurementRepository")
struct InMemoryGrowthMeasurementRepositoryTests {

    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Empty state

    @Test("empty repository returns empty array")
    func emptyRepositoryReturnsEmpty() async throws {
        // Arrange
        let repo = InMemoryGrowthMeasurementRepository()

        // Act
        let result = try await repo.all()

        // Assert
        #expect(result.isEmpty)
    }

    // MARK: - Save and retrieve

    @Test("save then all returns the saved measurement")
    func saveAndRetrieveSingle() async throws {
        // Arrange
        let repo = InMemoryGrowthMeasurementRepository()
        let m    = try GrowthMeasurement(date: fixedDate, weightGrams: 3_500)

        // Act
        try await repo.save(m)
        let result = try await repo.all()

        // Assert
        #expect(result.count == 1)
        #expect(result.first?.id          == m.id)
        #expect(result.first?.weightGrams == 3_500)
    }

    @Test("save multiple measurements — all returned in insertion order")
    func saveMultiplePreservesOrder() async throws {
        // Arrange
        let repo = InMemoryGrowthMeasurementRepository()
        let m1   = try GrowthMeasurement(date: fixedDate, weightGrams: 3_000)
        let m2   = try GrowthMeasurement(date: fixedDate, heightCm: 50.0)
        let m3   = try GrowthMeasurement(date: fixedDate, headCircumferenceCm: 35.0)

        // Act
        try await repo.save(m1)
        try await repo.save(m2)
        try await repo.save(m3)
        let result = try await repo.all()

        // Assert
        #expect(result.count == 3)
        #expect(result[0].id == m1.id)
        #expect(result[1].id == m2.id)
        #expect(result[2].id == m3.id)
    }

    // MARK: - Overwrite semantics

    @Test("saving with same ID overwrites the previous entry and does not grow the store")
    func saveOverwritesSameID() async throws {
        // Arrange
        let repo     = InMemoryGrowthMeasurementRepository()
        let id       = GrowthMeasurementID()
        let original = try GrowthMeasurement(id: id, date: fixedDate, weightGrams: 3_000)
        let updated  = try GrowthMeasurement(id: id, date: fixedDate, weightGrams: 4_500)

        // Act
        try await repo.save(original)
        try await repo.save(updated)
        let result = try await repo.all()

        // Assert — store has exactly one entry with the updated weight
        #expect(result.count == 1)
        #expect(result.first?.id          == id)
        #expect(result.first?.weightGrams == 4_500)
    }

    @Test("overwriting one entry does not affect sibling entries")
    func overwriteDoesNotAffectSiblings() async throws {
        // Arrange
        let repo      = InMemoryGrowthMeasurementRepository()
        let idA       = GrowthMeasurementID()
        let idB       = GrowthMeasurementID()
        let a1        = try GrowthMeasurement(id: idA, date: fixedDate, weightGrams: 3_000)
        let b         = try GrowthMeasurement(id: idB, date: fixedDate, heightCm: 55.0)
        let a2        = try GrowthMeasurement(id: idA, date: fixedDate, weightGrams: 3_200)

        // Act
        try await repo.save(a1)
        try await repo.save(b)
        try await repo.save(a2)
        let result = try await repo.all()

        // Assert
        #expect(result.count == 2)
        let byID = Dictionary(uniqueKeysWithValues: result.map { ($0.id, $0) })
        #expect(byID[idA]?.weightGrams == 3_200)
        #expect(byID[idB]?.heightCm   == 55.0)
    }
}

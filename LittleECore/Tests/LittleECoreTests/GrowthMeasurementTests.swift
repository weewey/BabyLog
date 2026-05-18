import Testing
import Foundation
@testable import LittleECore

@Suite("GrowthMeasurement")
struct GrowthMeasurementTests {

    // A fixed date avoids any implicit reliance on the system clock inside tests.
    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Happy paths: single field each

    @Test("init with weight only succeeds and sets other fields nil")
    func initWithWeightOnly() throws {
        // Arrange / Act
        let m = try GrowthMeasurement(date: fixedDate, weightGrams: 3_500)

        // Assert
        #expect(m.weightGrams         == 3_500)
        #expect(m.heightCm            == nil)
        #expect(m.headCircumferenceCm == nil)
        #expect(m.notes               == nil)
    }

    @Test("init with height only succeeds")
    func initWithHeightOnly() throws {
        let m = try GrowthMeasurement(date: fixedDate, heightCm: 50.0)
        #expect(m.heightCm    == 50.0)
        #expect(m.weightGrams == nil)
    }

    @Test("init with head circumference only succeeds")
    func initWithHeadOnly() throws {
        let m = try GrowthMeasurement(date: fixedDate, headCircumferenceCm: 35.0)
        #expect(m.headCircumferenceCm == 35.0)
        #expect(m.weightGrams         == nil)
        #expect(m.heightCm            == nil)
    }

    @Test("init with all measurement fields and notes succeeds")
    func initWithAllFields() throws {
        let m = try GrowthMeasurement(
            date:                 fixedDate,
            weightGrams:          7_000,
            heightCm:             65.0,
            headCircumferenceCm:  42.0,
            notes:                "6-month check"
        )
        #expect(m.weightGrams         == 7_000)
        #expect(m.heightCm            == 65.0)
        #expect(m.headCircumferenceCm == 42.0)
        #expect(m.notes               == "6-month check")
        #expect(m.date                == fixedDate)
    }

    // MARK: - At-least-one-field guard

    @Test("all measurement fields nil throws noMeasurementFieldProvided")
    func allMeasurementFieldsNilThrows() {
        #expect(throws: GrowthMeasurementError.noMeasurementFieldProvided) {
            try GrowthMeasurement(date: fixedDate)
        }
    }

    @Test("notes-only init throws noMeasurementFieldProvided")
    func notesOnlyThrows() {
        #expect(throws: GrowthMeasurementError.noMeasurementFieldProvided) {
            try GrowthMeasurement(date: fixedDate, notes: "just a note")
        }
    }

    // MARK: - Weight bounds

    @Test("weight lower boundary 500g accepted")
    func weightLowerBoundary() throws {
        let m = try GrowthMeasurement(date: fixedDate, weightGrams: 500)
        #expect(m.weightGrams == 500)
    }

    @Test("weight upper boundary 15000g accepted")
    func weightUpperBoundary() throws {
        let m = try GrowthMeasurement(date: fixedDate, weightGrams: 15_000)
        #expect(m.weightGrams == 15_000)
    }

    @Test("weight 499g throws weightOutOfRange")
    func weightBelowMinThrows() {
        #expect(throws: GrowthMeasurementError.weightOutOfRange(499)) {
            try GrowthMeasurement(date: fixedDate, weightGrams: 499)
        }
    }

    @Test("weight 15001g throws weightOutOfRange")
    func weightAboveMaxThrows() {
        #expect(throws: GrowthMeasurementError.weightOutOfRange(15_001)) {
            try GrowthMeasurement(date: fixedDate, weightGrams: 15_001)
        }
    }

    // MARK: - Height bounds

    @Test("height lower boundary 20cm accepted")
    func heightLowerBoundary() throws {
        let m = try GrowthMeasurement(date: fixedDate, heightCm: 20.0)
        #expect(m.heightCm == 20.0)
    }

    @Test("height upper boundary 120cm accepted")
    func heightUpperBoundary() throws {
        let m = try GrowthMeasurement(date: fixedDate, heightCm: 120.0)
        #expect(m.heightCm == 120.0)
    }

    @Test("height 19.9cm throws heightOutOfRange")
    func heightBelowMinThrows() {
        #expect(throws: GrowthMeasurementError.heightOutOfRange(19.9)) {
            try GrowthMeasurement(date: fixedDate, heightCm: 19.9)
        }
    }

    @Test("height 120.1cm throws heightOutOfRange")
    func heightAboveMaxThrows() {
        #expect(throws: GrowthMeasurementError.heightOutOfRange(120.1)) {
            try GrowthMeasurement(date: fixedDate, heightCm: 120.1)
        }
    }

    // MARK: - Head circumference bounds

    @Test("head lower boundary 20cm accepted")
    func headLowerBoundary() throws {
        let m = try GrowthMeasurement(date: fixedDate, headCircumferenceCm: 20.0)
        #expect(m.headCircumferenceCm == 20.0)
    }

    @Test("head upper boundary 60cm accepted")
    func headUpperBoundary() throws {
        let m = try GrowthMeasurement(date: fixedDate, headCircumferenceCm: 60.0)
        #expect(m.headCircumferenceCm == 60.0)
    }

    @Test("head 19.9cm throws headCircumferenceOutOfRange")
    func headBelowMinThrows() {
        #expect(throws: GrowthMeasurementError.headCircumferenceOutOfRange(19.9)) {
            try GrowthMeasurement(date: fixedDate, headCircumferenceCm: 19.9)
        }
    }

    @Test("head 60.1cm throws headCircumferenceOutOfRange")
    func headAboveMaxThrows() {
        #expect(throws: GrowthMeasurementError.headCircumferenceOutOfRange(60.1)) {
            try GrowthMeasurement(date: fixedDate, headCircumferenceCm: 60.1)
        }
    }

    // MARK: - Identity

    @Test("two measurements constructed without explicit ID receive distinct IDs")
    func defaultIDsAreDistinct() throws {
        let a = try GrowthMeasurement(date: fixedDate, weightGrams: 3_000)
        let b = try GrowthMeasurement(date: fixedDate, weightGrams: 3_000)
        #expect(a.id != b.id)
    }

    @Test("custom ID is preserved verbatim")
    func customIDPreserved() throws {
        let id = GrowthMeasurementID(UUID())
        let m  = try GrowthMeasurement(id: id, date: fixedDate, weightGrams: 3_000)
        #expect(m.id == id)
    }
}

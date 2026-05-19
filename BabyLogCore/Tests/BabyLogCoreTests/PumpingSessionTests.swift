import XCTest
@testable import BabyLogCore
import Foundation

final class PumpingSessionTests: XCTestCase {

    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Duration bounds

    func test_pumpingSession_acceptsMinimumDuration() throws {
        let s = try PumpingSession(startedAt: fixedDate, durationMinutes: 1)

        XCTAssertEqual(s.durationMinutes, 1)
    }

    func test_pumpingSession_acceptsMaximumDuration() throws {
        let s = try PumpingSession(startedAt: fixedDate, durationMinutes: 120)

        XCTAssertEqual(s.durationMinutes, 120)
    }

    func test_pumpingSession_rejectsZeroDuration() {
        XCTAssertThrowsError(try PumpingSession(startedAt: fixedDate, durationMinutes: 0)) { err in
            XCTAssertEqual(err as? PumpingSessionError, .durationOutOfRange)
        }
    }

    func test_pumpingSession_rejectsDurationGreaterThan120() {
        XCTAssertThrowsError(try PumpingSession(startedAt: fixedDate, durationMinutes: 121)) { err in
            XCTAssertEqual(err as? PumpingSessionError, .durationOutOfRange)
        }
    }

    // MARK: - Volume bounds

    func test_pumpingSession_acceptsZeroVolume() throws {
        let s = try PumpingSession(startedAt: fixedDate, durationMinutes: 20, milkVolumeMl: 0)

        XCTAssertEqual(s.milkVolumeMl, 0)
    }

    func test_pumpingSession_acceptsMaximumVolume() throws {
        let s = try PumpingSession(startedAt: fixedDate, durationMinutes: 20, milkVolumeMl: 500)

        XCTAssertEqual(s.milkVolumeMl, 500)
    }

    func test_pumpingSession_rejectsNegativeVolume() {
        XCTAssertThrowsError(
            try PumpingSession(startedAt: fixedDate, durationMinutes: 20, milkVolumeMl: -1)
        ) { err in
            XCTAssertEqual(err as? PumpingSessionError, .volumeOutOfRange)
        }
    }

    func test_pumpingSession_rejectsVolumeGreaterThan500() {
        XCTAssertThrowsError(
            try PumpingSession(startedAt: fixedDate, durationMinutes: 20, milkVolumeMl: 501)
        ) { err in
            XCTAssertEqual(err as? PumpingSessionError, .volumeOutOfRange)
        }
    }

    func test_pumpingSession_allowsNilVolume() throws {
        let s = try PumpingSession(startedAt: fixedDate, durationMinutes: 20, milkVolumeMl: nil)

        XCTAssertNil(s.milkVolumeMl)
    }

    // MARK: - Notes

    func test_pumpingSession_rejectsNotesLongerThan500() {
        let notes = String(repeating: "a", count: 501)

        XCTAssertThrowsError(
            try PumpingSession(startedAt: fixedDate, durationMinutes: 20, notes: notes)
        ) { err in
            XCTAssertEqual(err as? PumpingSessionError, .notesTooLong)
        }
    }

    func test_pumpingSession_acceptsNotes500Chars() throws {
        let notes = String(repeating: "a", count: 500)

        let s = try PumpingSession(startedAt: fixedDate, durationMinutes: 20, notes: notes)

        XCTAssertEqual(s.notes?.count, 500)
    }

    // MARK: - Brand

    func test_pumpingSession_rejectsEmptyBrand() {
        XCTAssertThrowsError(
            try PumpingSession(startedAt: fixedDate, durationMinutes: 20, pumpBrand: "   ")
        ) { err in
            XCTAssertEqual(err as? PumpingSessionError, .brandEmpty)
        }
    }

    // MARK: - Happy path

    func test_pumpingSession_storesAllFields() throws {
        let knownID = UUID()

        let s = try PumpingSession(
            id: knownID,
            startedAt: fixedDate,
            durationMinutes: 20,
            side: .both,
            milkVolumeMl: 120,
            pumpBrand: "Medela",
            scheduleSlotId: "morning-rise",
            notes: "good let-down"
        )

        XCTAssertEqual(s.id, knownID)
        XCTAssertEqual(s.startedAt, fixedDate)
        XCTAssertEqual(s.durationMinutes, 20)
        XCTAssertEqual(s.side, .both)
        XCTAssertEqual(s.milkVolumeMl, 120)
        XCTAssertEqual(s.pumpBrand, "Medela")
        XCTAssertEqual(s.scheduleSlotId, "morning-rise")
        XCTAssertEqual(s.notes, "good let-down")
    }
}

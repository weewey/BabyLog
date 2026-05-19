import XCTest
import SwiftData
@testable import BabyLog
import LittleECore

/// Tests for `SwiftDataPumpingSessionRepository`.
///
/// All tests use an **in-memory** `ModelContainer` so they are fully isolated
/// and run sub-second without touching the host filesystem.
@MainActor
final class SwiftDataPumpingSessionRepositoryTests: XCTestCase {

    // MARK: - Fixture

    private var container: ModelContainer!
    private var sut: SwiftDataPumpingSessionRepository!

    override func setUpWithError() throws {
        container = try ModelContainer(
            for: PumpingSessionModel.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        sut = SwiftDataPumpingSessionRepository(context: container.mainContext)
    }

    override func tearDownWithError() throws {
        sut = nil
        container = nil
    }

    // MARK: - Empty store

    func testEmptyStoreReturnsEmptyArray() throws {
        let result = try sut.all()
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Round-trip

    func testSaveAndFetchPreservesAllFields() throws {
        let id = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_776_500_000)

        let session = try PumpingSession(
            id: id,
            startedAt: startedAt,
            durationMinutes: 25,
            side: .left,
            milkVolumeMl: 110,
            pumpBrand: "Medela",
            scheduleSlotId: "midday",
            notes: "Hands-on compressions"
        )

        try sut.save(session)
        let all = try sut.all()

        XCTAssertEqual(all.count, 1)
        let fetched = try XCTUnwrap(all.first)
        XCTAssertEqual(fetched.id, id)
        XCTAssertEqual(fetched.startedAt, startedAt)
        XCTAssertEqual(fetched.durationMinutes, 25)
        XCTAssertEqual(fetched.side, .left)
        XCTAssertEqual(fetched.milkVolumeMl, 110)
        XCTAssertEqual(fetched.pumpBrand, "Medela")
        XCTAssertEqual(fetched.scheduleSlotId, "midday")
        XCTAssertEqual(fetched.notes, "Hands-on compressions")
    }

    func testNilSideRoundTrips() throws {
        let session = try PumpingSession(
            startedAt: Date(timeIntervalSince1970: 1_776_500_100),
            durationMinutes: 20,
            side: nil,
            milkVolumeMl: nil
        )
        try sut.save(session)

        let fetched = try XCTUnwrap(try sut.all().first)
        XCTAssertNil(fetched.side)
        XCTAssertNil(fetched.milkVolumeMl)
    }

    // MARK: - Upsert idempotency

    func testUpdateReplacesExistingRecord() throws {
        let id = UUID()
        let original = try PumpingSession(
            id: id,
            startedAt: Date(timeIntervalSince1970: 1_776_500_000),
            durationMinutes: 20,
            side: .left,
            milkVolumeMl: 80
        )
        let patched = try PumpingSession(
            id: id,
            startedAt: Date(timeIntervalSince1970: 1_776_500_000),
            durationMinutes: 25,
            side: .both,
            milkVolumeMl: 150
        )

        try sut.save(original)
        try sut.update(patched)

        let all = try sut.all()
        XCTAssertEqual(all.count, 1, "Update must not duplicate record")
        XCTAssertEqual(all.first?.durationMinutes, 25)
        XCTAssertEqual(all.first?.side, .both)
        XCTAssertEqual(all.first?.milkVolumeMl, 150)
    }

    func testSaveSameIdTwiceYieldsSingleRecord() throws {
        let id = UUID()
        let a = try PumpingSession(id: id, startedAt: Date(timeIntervalSince1970: 1_776_500_000), durationMinutes: 20)
        let b = try PumpingSession(id: id, startedAt: Date(timeIntervalSince1970: 1_776_500_000), durationMinutes: 30)

        try sut.save(a)
        try sut.save(b)

        XCTAssertEqual(try sut.all().count, 1)
        XCTAssertEqual(try sut.all().first?.durationMinutes, 30)
    }

    // MARK: - Delete

    func testDeleteRemovesRecord() throws {
        let id = UUID()
        let session = try PumpingSession(id: id, startedAt: Date(timeIntervalSince1970: 1_776_500_000), durationMinutes: 20)
        try sut.save(session)
        XCTAssertEqual(try sut.all().count, 1)

        try sut.delete(id: id)

        XCTAssertTrue(try sut.all().isEmpty)
    }

    func testDeleteUnknownIdIsNoOp() throws {
        try sut.delete(id: UUID())
        XCTAssertTrue(try sut.all().isEmpty)
    }

    // MARK: - Ordering + recent

    func testAllReturnsNewestFirst() throws {
        let older = try PumpingSession(
            startedAt: Date(timeIntervalSince1970: 1_776_500_000),
            durationMinutes: 20
        )
        let newer = try PumpingSession(
            startedAt: Date(timeIntervalSince1970: 1_776_600_000),
            durationMinutes: 25
        )
        try sut.save(older)
        try sut.save(newer)

        let all = try sut.all()
        XCTAssertEqual(all.first?.durationMinutes, 25)
        XCTAssertEqual(all.last?.durationMinutes, 20)
    }

    func testRecentHonoursLimit() throws {
        for i in 0..<5 {
            let s = try PumpingSession(
                startedAt: Date(timeIntervalSince1970: 1_776_500_000 + Double(i * 3600)),
                durationMinutes: 20
            )
            try sut.save(s)
        }

        let recent = try sut.recent(limit: 3)
        XCTAssertEqual(recent.count, 3)
    }
}

import XCTest
import SwiftData
@testable import BabyLog
import BabyLogCore

/// Tests for `SwiftDataDiaperLogRepository`.
///
/// All tests use an **in-memory** `ModelContainer` so they are fully isolated,
/// require no simulator, and run sub-second.
@MainActor
final class SwiftDataDiaperLogRepositoryTests: XCTestCase {

    // MARK: - Fixture

    private var container: ModelContainer!
    private var sut: SwiftDataDiaperLogRepository!

    override func setUpWithError() throws {
        container = try ModelContainer(
            for: DiaperLogModel.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        sut = SwiftDataDiaperLogRepository(context: container.mainContext)
    }

    override func tearDownWithError() throws {
        sut = nil
        container = nil
    }

    // MARK: - Empty store

    func testEmptyStoreReturnsEmptyArray() throws {
        let result = try sut.all()
        XCTAssertTrue(result.isEmpty, "Fresh store should return an empty array")
    }

    // MARK: - Round-trip: all fields preserved

    func testSaveAndFetchPreservesAllFields() throws {
        let id = UUID()
        let loggedAt = Date(timeIntervalSince1970: 1_700_000_000)

        let log = DiaperLog(
            id: id,
            type: .dirty,
            loggedAt: loggedAt,
            notes: "After feeding"
        )

        try sut.save(log)
        let all = try sut.all()

        XCTAssertEqual(all.count, 1)
        let fetched = try XCTUnwrap(all.first)
        XCTAssertEqual(fetched.id, id)
        XCTAssertEqual(fetched.loggedAt, loggedAt)
        XCTAssertEqual(fetched.type, .dirty)
        XCTAssertEqual(fetched.notes, "After feeding")
    }

    // MARK: - DiaperType enum round-trip

    func testWetTypeRoundTrips() throws {
        let log = DiaperLog(
            id: UUID(),
            type: .wet,
            loggedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        try sut.save(log)

        let fetched = try XCTUnwrap(try sut.all().first)
        XCTAssertEqual(fetched.type, .wet)
    }

    func testDirtyTypeRoundTrips() throws {
        let log = DiaperLog(
            id: UUID(),
            type: .dirty,
            loggedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )
        try sut.save(log)

        let fetched = try XCTUnwrap(try sut.all().first)
        XCTAssertEqual(fetched.type, .dirty)
    }

    func testBothTypeRoundTrips() throws {
        let log = DiaperLog(
            id: UUID(),
            type: .both,
            loggedAt: Date(timeIntervalSince1970: 1_700_000_300)
        )
        try sut.save(log)

        let fetched = try XCTUnwrap(try sut.all().first)
        XCTAssertEqual(fetched.type, .both)
    }

    // MARK: - Notes optional handling

    func testNilNotesRoundTrips() throws {
        let log = DiaperLog(
            id: UUID(),
            type: .wet,
            loggedAt: Date(timeIntervalSince1970: 1_700_000_400)
        )
        try sut.save(log)

        let fetched = try XCTUnwrap(try sut.all().first)
        XCTAssertNil(fetched.notes)
    }

    // MARK: - Ordering

    func testAllReturnsMostRecentFirst() throws {
        let older = DiaperLog(
            id: UUID(),
            type: .wet,
            loggedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let newer = DiaperLog(
            id: UUID(),
            type: .dirty,
            loggedAt: Date(timeIntervalSince1970: 1_700_001_000)
        )

        try sut.save(older)
        try sut.save(newer)

        let all = try sut.all()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all.first?.type, .dirty, "Newest entry should be first")
        XCTAssertEqual(all.last?.type, .wet, "Oldest entry should be last")
    }

    // MARK: - Upsert idempotency

    func testSaveSameIdTwiceYieldsSingleRecord() throws {
        let id = UUID()
        let original = DiaperLog(
            id: id, type: .wet, loggedAt: Date(timeIntervalSince1970: 1_700_000_300)
        )
        let updated = DiaperLog(
            id: id, type: .both, loggedAt: Date(timeIntervalSince1970: 1_700_000_400),
            notes: "Updated"
        )

        try sut.save(original)
        try sut.save(updated)

        let all = try sut.all()
        XCTAssertEqual(all.count, 1, "Upsert must not duplicate a record")
        XCTAssertEqual(all.first?.type, .both, "Second save must win")
        XCTAssertEqual(all.first?.notes, "Updated")
    }
}

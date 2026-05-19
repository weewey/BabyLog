import XCTest
import SwiftData
@testable import BabyLog
import LittleECore

/// Tests for `SwiftDataFeedLogRepository`.
///
/// All tests use an **in-memory** `ModelContainer` so they are fully isolated,
/// require no simulator, and run sub-second.
@MainActor
final class SwiftDataFeedLogRepositoryTests: XCTestCase {

    // MARK: - Fixture

    private var container: ModelContainer!
    private var sut: SwiftDataFeedLogRepository!

    override func setUpWithError() throws {
        container = try ModelContainer(
            for: FeedLogModel.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        sut = SwiftDataFeedLogRepository(context: container.mainContext)
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

        let log = try FeedLog(
            id: id,
            volumeMl: 120,
            loggedAt: loggedAt,
            source: .bottle
        )

        try sut.save(log)
        let all = try sut.all()

        XCTAssertEqual(all.count, 1)
        let fetched = try XCTUnwrap(all.first)
        XCTAssertEqual(fetched.id, id)
        XCTAssertEqual(fetched.loggedAt, loggedAt)
        XCTAssertEqual(fetched.volumeMl, 120)
        XCTAssertEqual(fetched.source, .bottle)
    }

    // MARK: - FeedSource enum round-trip

    func testBottleSourceRoundTrips() throws {
        let log = try FeedLog(
            id: UUID(),
            volumeMl: 100,
            loggedAt: Date(timeIntervalSince1970: 1_700_000_100),
            source: .bottle
        )
        try sut.save(log)

        let fetched = try XCTUnwrap(try sut.all().first)
        XCTAssertEqual(fetched.source, .bottle)
    }

    func testBreastSourceRoundTrips() throws {
        let log = try FeedLog(
            id: UUID(),
            volumeMl: 80,
            loggedAt: Date(timeIntervalSince1970: 1_700_000_200),
            source: .breast
        )
        try sut.save(log)

        let fetched = try XCTUnwrap(try sut.all().first)
        XCTAssertEqual(fetched.source, .breast)
    }

    // MARK: - Upsert idempotency

    func testSaveSameIdTwiceYieldsSingleRecord() throws {
        let id = UUID()
        let original = try FeedLog(
            id: id, volumeMl: 90, loggedAt: Date(timeIntervalSince1970: 1_700_000_300), source: .bottle
        )
        let updated = try FeedLog(
            id: id, volumeMl: 120, loggedAt: Date(timeIntervalSince1970: 1_700_000_400), source: .bottle
        )

        try sut.save(original)
        try sut.save(updated)

        let all = try sut.all()
        XCTAssertEqual(all.count, 1, "Upsert must not duplicate a record")
        XCTAssertEqual(all.first?.volumeMl, 120, "Second save must win")
    }
}

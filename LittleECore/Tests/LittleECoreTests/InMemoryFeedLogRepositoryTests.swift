import XCTest
@testable import LittleECore
import Foundation

final class InMemoryFeedLogRepositoryTests: XCTestCase {

    private let olderDate = Date(timeIntervalSince1970: 1_699_910_000)
    private let newerDate = Date(timeIntervalSince1970: 1_699_920_000)

    // MARK: - Round-trip

    func test_repository_saveThenAllReturnsSavedEntry() async throws {
        let repo = InMemoryFeedLogRepository()
        let feed = try FeedLog(volumeMl: 120, loggedAt: newerDate, source: .bottle)

        try await repo.save(feed)
        let all = try await repo.all()

        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.id, feed.id)
    }

    // MARK: - Ordering

    func test_repository_allReturnsNewestFirst() async throws {
        let repo = InMemoryFeedLogRepository()
        let older = try FeedLog(volumeMl: 100, loggedAt: olderDate, source: .bottle)
        let newer = try FeedLog(volumeMl: 150, loggedAt: newerDate, source: .breast)

        try await repo.save(older)
        try await repo.save(newer)

        let all = try await repo.all()

        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all[0].id, newer.id)
        XCTAssertEqual(all[1].id, older.id)
    }

    // MARK: - Empty state

    func test_repository_emptyReturnsEmptyArray() async throws {
        let repo = InMemoryFeedLogRepository()

        let all = try await repo.all()

        XCTAssertTrue(all.isEmpty)
    }

    // MARK: - Delete

    func test_repository_deleteRemovesEntry() async throws {
        let repo = InMemoryFeedLogRepository()
        let feed = try FeedLog(volumeMl: 120, loggedAt: newerDate, source: .bottle)
        try await repo.save(feed)

        try await repo.delete(id: feed.id)

        let all = try await repo.all()
        XCTAssertTrue(all.isEmpty)
    }

    func test_repository_deleteOnlyRemovesMatchingEntry() async throws {
        let repo = InMemoryFeedLogRepository()
        let kept = try FeedLog(volumeMl: 100, loggedAt: olderDate, source: .bottle)
        let removed = try FeedLog(volumeMl: 150, loggedAt: newerDate, source: .breast)
        try await repo.save(kept)
        try await repo.save(removed)

        try await repo.delete(id: removed.id)

        let all = try await repo.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.id, kept.id)
    }

    func test_repository_deleteUnknownIdIsNoOp() async throws {
        let repo = InMemoryFeedLogRepository()
        let feed = try FeedLog(volumeMl: 120, loggedAt: newerDate, source: .bottle)
        try await repo.save(feed)

        try await repo.delete(id: UUID())

        let all = try await repo.all()
        XCTAssertEqual(all.count, 1)
    }
}

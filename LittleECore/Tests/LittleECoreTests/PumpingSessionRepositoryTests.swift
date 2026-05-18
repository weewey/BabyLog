import XCTest
@testable import LittleECore
import Foundation

final class PumpingSessionRepositoryTests: XCTestCase {

    private let older = Date(timeIntervalSince1970: 1_699_900_000)
    private let mid   = Date(timeIntervalSince1970: 1_699_950_000)
    private let newer = Date(timeIntervalSince1970: 1_699_999_000)

    // MARK: - Save + read

    func test_repository_saveThenAllReturnsSavedEntry() async throws {
        let repo = InMemoryPumpingSessionRepository()
        let s = try PumpingSession(startedAt: newer, durationMinutes: 20)

        try await repo.save(s)
        let all = try await repo.all()

        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.id, s.id)
    }

    func test_repository_allReturnsNewestFirst() async throws {
        let repo = InMemoryPumpingSessionRepository()
        let a = try PumpingSession(startedAt: older, durationMinutes: 18)
        let b = try PumpingSession(startedAt: newer, durationMinutes: 22)

        try await repo.save(a)
        try await repo.save(b)
        let all = try await repo.all()

        XCTAssertEqual(all.map(\.id), [b.id, a.id])
    }

    // MARK: - Update

    func test_repository_updatePreservesId() async throws {
        let repo = InMemoryPumpingSessionRepository()
        let original = try PumpingSession(startedAt: newer, durationMinutes: 20, milkVolumeMl: 80)
        try await repo.save(original)

        let patched = try PumpingSession(
            id: original.id,
            startedAt: newer,
            durationMinutes: 25,
            milkVolumeMl: 100
        )
        try await repo.update(patched)

        let all = try await repo.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.id, original.id)
        XCTAssertEqual(all.first?.durationMinutes, 25)
        XCTAssertEqual(all.first?.milkVolumeMl, 100)
    }

    // MARK: - Delete

    func test_repository_deleteRemovesEntry() async throws {
        let repo = InMemoryPumpingSessionRepository()
        let s = try PumpingSession(startedAt: newer, durationMinutes: 20)
        try await repo.save(s)

        try await repo.delete(id: s.id)

        let all = try await repo.all()
        XCTAssertTrue(all.isEmpty)
    }

    // MARK: - Recent

    func test_repository_recentReturnsNewestFirstWithLimit() async throws {
        let repo = InMemoryPumpingSessionRepository()
        let a = try PumpingSession(startedAt: older, durationMinutes: 15)
        let b = try PumpingSession(startedAt: mid,   durationMinutes: 18)
        let c = try PumpingSession(startedAt: newer, durationMinutes: 22)
        try await repo.save(a)
        try await repo.save(b)
        try await repo.save(c)

        let recent = try await repo.recent(limit: 2)

        XCTAssertEqual(recent.map(\.id), [c.id, b.id])
    }

    func test_repository_recentZeroLimitReturnsEmpty() async throws {
        let repo = InMemoryPumpingSessionRepository()
        let s = try PumpingSession(startedAt: newer, durationMinutes: 20)
        try await repo.save(s)

        let recent = try await repo.recent(limit: 0)

        XCTAssertTrue(recent.isEmpty)
    }
}

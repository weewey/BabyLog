import XCTest
@testable import BabyLogCore
import Foundation

final class UpdateFeedLogToolTests: XCTestCase {

    func test_updateFeedLog_patchesVolumeAndKeepsSource() async throws {
        let repo = InMemoryFeedLogRepository()
        let id = UUID()
        let original = try FeedLog(
            id: id,
            volumeMl: 100,
            loggedAt: Date(timeIntervalSince1970: 1_700_000_000),
            source: .bottle
        )
        try await repo.save(original)
        let tool = UpdateFeedLogTool(repository: repo)
        let args = ToolArguments([
            "id": .string(id.uuidString),
            "volumeMl": .int(150),
        ])

        let result = try await tool.execute(arguments: args)

        let stored = try await repo.all()
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.id, id)
        XCTAssertEqual(stored.first?.volumeMl, 150)
        XCTAssertEqual(stored.first?.source, .bottle)
        XCTAssertFalse(result.isError)
    }

    func test_updateFeedLog_unknownId_throwsExecutionFailed() async {
        let repo = InMemoryFeedLogRepository()
        let tool = UpdateFeedLogTool(repository: repo)
        let args = ToolArguments(["id": .string(UUID().uuidString)])

        do {
            _ = try await tool.execute(arguments: args)
            XCTFail("expected throw")
        } catch let error as ChatToolError {
            if case .executionFailed = error {
                // ok
            } else {
                XCTFail("expected executionFailed, got \(error)")
            }
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func test_updateFeedLog_invalidUUID_throwsExecutionFailed() async {
        let tool = UpdateFeedLogTool(repository: InMemoryFeedLogRepository())
        let args = ToolArguments(["id": .string("not-a-uuid")])

        do {
            _ = try await tool.execute(arguments: args)
            XCTFail("expected throw")
        } catch let error as ChatToolError {
            if case .executionFailed = error { return }
            XCTFail("expected executionFailed, got \(error)")
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func test_updateFeedLog_doesNotRequireConfirmation() {
        let tool = UpdateFeedLogTool(repository: InMemoryFeedLogRepository())

        XCTAssertFalse(tool.requiresConfirmation)
    }

    // MARK: - mostRecent selector

    func test_updateFeedLog_withMostRecent_updatesLatestEntry() async throws {
        let repo = InMemoryFeedLogRepository()
        let older = try FeedLog(id: UUID(), volumeMl: 80, loggedAt: Date(timeIntervalSince1970: 1_700_000_000), source: .bottle)
        let newer = try FeedLog(id: UUID(), volumeMl: 100, loggedAt: Date(timeIntervalSince1970: 1_700_010_000), source: .bottle)
        try await repo.save(older)
        try await repo.save(newer)
        let tool = UpdateFeedLogTool(repository: repo)
        let args = ToolArguments([
            "mostRecent": .bool(true),
            "volumeMl": .int(200),
        ])

        let result = try await tool.execute(arguments: args)

        let stored = try await repo.all()
        XCTAssertEqual(stored.count, 2)
        let updated = stored.first(where: { $0.id == newer.id })
        XCTAssertEqual(updated?.volumeMl, 200)
        let untouched = stored.first(where: { $0.id == older.id })
        XCTAssertEqual(untouched?.volumeMl, 80)
        XCTAssertFalse(result.isError)
    }

    func test_updateFeedLog_mostRecent_emptyRepo_throwsExecutionFailed() async {
        let tool = UpdateFeedLogTool(repository: InMemoryFeedLogRepository())
        let args = ToolArguments(["mostRecent": .bool(true), "volumeMl": .int(100)])

        do {
            _ = try await tool.execute(arguments: args)
            XCTFail("expected throw")
        } catch let error as ChatToolError {
            if case .executionFailed = error { return }
            XCTFail("expected executionFailed, got \(error)")
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    // MARK: - time selector

    func test_updateFeedLog_withTime_updatesClosestEntry() async throws {
        let repo = InMemoryFeedLogRepository()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let today = cal.startOfDay(for: Date())
        // 9:00 AM and 11:00 AM today (09:30 is 30 min from 9am, 90 min from 11am — unambiguous)
        let at9am  = try FeedLog(id: UUID(), volumeMl: 80,  loggedAt: cal.date(byAdding: .hour, value: 9,  to: today)!, source: .bottle)
        let at11am = try FeedLog(id: UUID(), volumeMl: 120, loggedAt: cal.date(byAdding: .hour, value: 11, to: today)!, source: .bottle)
        try await repo.save(at9am)
        try await repo.save(at11am)
        let tool = UpdateFeedLogTool(repository: repo)
        // "9:30" is 30 min from 9am and 90 min from 11am — clearly picks 9am
        let args = ToolArguments([
            "time": .string("09:30"),
            "volumeMl": .int(150),
        ])

        _ = try await tool.execute(arguments: args)

        let stored = try await repo.all()
        let updated = stored.first(where: { $0.id == at9am.id })
        XCTAssertEqual(updated?.volumeMl, 150)
        let untouched = stored.first(where: { $0.id == at11am.id })
        XCTAssertEqual(untouched?.volumeMl, 120)
    }

    // MARK: - no selector

    func test_updateFeedLog_noSelector_throwsExecutionFailed() async {
        let repo = InMemoryFeedLogRepository()
        let tool = UpdateFeedLogTool(repository: repo)
        let args = ToolArguments(["volumeMl": .int(100)])

        do {
            _ = try await tool.execute(arguments: args)
            XCTFail("expected throw")
        } catch let error as ChatToolError {
            if case .executionFailed = error { return }
            XCTFail("expected executionFailed, got \(error)")
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }
}

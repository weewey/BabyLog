import XCTest
@testable import BabyLogCore
import Foundation

final class UpdatePumpingSessionToolTests: XCTestCase {

    // MARK: - Existing id selector

    func test_updatePumpingSession_patchesVolumeById() async throws {
        let repo = InMemoryPumpingSessionRepository()
        let id = UUID()
        let original = try PumpingSession(
            id: id,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            durationMinutes: 20,
            milkVolumeMl: 100
        )
        try await repo.save(original)
        let tool = UpdatePumpingSessionTool(repository: repo)
        let args = ToolArguments([
            "id": .string(id.uuidString),
            "milkVolumeMl": .int(150),
        ])

        let result = try await tool.execute(arguments: args)

        let stored = try await repo.all()
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.milkVolumeMl, 150)
        XCTAssertEqual(stored.first?.durationMinutes, 20)
        XCTAssertFalse(result.isError)
    }

    // MARK: - mostRecent selector

    func test_updatePumpingSession_withMostRecent_updatesLatestSession() async throws {
        let repo = InMemoryPumpingSessionRepository()
        let older = try PumpingSession(
            id: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            durationMinutes: 15,
            milkVolumeMl: 80
        )
        let newer = try PumpingSession(
            id: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_700_010_000),
            durationMinutes: 20,
            milkVolumeMl: 100
        )
        try await repo.save(older)
        try await repo.save(newer)
        let tool = UpdatePumpingSessionTool(repository: repo)
        let args = ToolArguments([
            "mostRecent": .bool(true),
            "milkVolumeMl": .int(150),
        ])

        _ = try await tool.execute(arguments: args)

        let stored = try await repo.all()
        let updated = stored.first(where: { $0.id == newer.id })
        XCTAssertEqual(updated?.milkVolumeMl, 150)
        let untouched = stored.first(where: { $0.id == older.id })
        XCTAssertEqual(untouched?.milkVolumeMl, 80)
    }

    func test_updatePumpingSession_mostRecent_emptyRepo_throwsExecutionFailed() async {
        let tool = UpdatePumpingSessionTool(repository: InMemoryPumpingSessionRepository())
        let args = ToolArguments(["mostRecent": .bool(true), "milkVolumeMl": .int(100)])

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

    func test_updatePumpingSession_withTime_updatesClosestSession() async throws {
        let repo = InMemoryPumpingSessionRepository()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let today = cal.startOfDay(for: Date())
        // 9:00 AM and 11:00 AM today (09:30 is 30 min from 9am, 90 min from 11am — unambiguous)
        let at9am  = try PumpingSession(id: UUID(), startedAt: cal.date(byAdding: .hour, value: 9,  to: today)!, durationMinutes: 20, milkVolumeMl: 80)
        let at11am = try PumpingSession(id: UUID(), startedAt: cal.date(byAdding: .hour, value: 11, to: today)!, durationMinutes: 20, milkVolumeMl: 120)
        try await repo.save(at9am)
        try await repo.save(at11am)
        let tool = UpdatePumpingSessionTool(repository: repo)
        // "09:30" is 30 min from 9am and 90 min from 11am — clearly picks 9am
        let args = ToolArguments([
            "time": .string("09:30"),
            "milkVolumeMl": .int(150),
        ])

        _ = try await tool.execute(arguments: args)

        let stored = try await repo.all()
        let updated = stored.first(where: { $0.id == at9am.id })
        XCTAssertEqual(updated?.milkVolumeMl, 150)
        let untouched = stored.first(where: { $0.id == at11am.id })
        XCTAssertEqual(untouched?.milkVolumeMl, 120)
    }

    // MARK: - no selector

    func test_updatePumpingSession_noSelector_throwsExecutionFailed() async {
        let tool = UpdatePumpingSessionTool(repository: InMemoryPumpingSessionRepository())
        let args = ToolArguments(["milkVolumeMl": .int(100)])

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

    func test_updatePumpingSession_unknownId_throwsExecutionFailed() async {
        let tool = UpdatePumpingSessionTool(repository: InMemoryPumpingSessionRepository())
        let args = ToolArguments(["id": .string(UUID().uuidString)])

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

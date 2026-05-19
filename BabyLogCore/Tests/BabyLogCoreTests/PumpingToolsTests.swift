import XCTest
@testable import BabyLogCore
import Foundation

final class PumpingToolsTests: XCTestCase {

    // MARK: - CreatePumpingSessionTool

    func test_createPumpingSession_happyPath_savesAndEmbedsId() async throws {
        let repo = InMemoryPumpingSessionRepository()
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_700_000_000))
        let tool = CreatePumpingSessionTool(repository: repo, clock: clock)
        let args = ToolArguments([
            "durationMinutes": .int(20),
            "side": .string("both"),
            "milkVolumeMl": .int(110),
        ])

        let result = try await tool.execute(arguments: args)

        let stored = try await repo.all()
        XCTAssertEqual(stored.count, 1)
        let saved = try XCTUnwrap(stored.first)
        XCTAssertEqual(saved.durationMinutes, 20)
        XCTAssertEqual(saved.side, .both)
        XCTAssertEqual(saved.milkVolumeMl, 110)
        XCTAssertEqual(saved.startedAt, clock.now())
        XCTAssertFalse(result.isError)
        XCTAssertTrue(
            result.content.contains("id=\(saved.id.uuidString)"),
            "expected result to embed id, got: \(result.content)"
        )
        XCTAssertTrue(result.content.contains("20 min"))
    }

    func test_createPumpingSession_missingDuration_throws() async {
        let tool = CreatePumpingSessionTool(
            repository: InMemoryPumpingSessionRepository(),
            clock: TestClock()
        )

        do {
            _ = try await tool.execute(arguments: ToolArguments([:]))
            XCTFail("expected throw")
        } catch let err as ToolArgumentsError {
            XCTAssertEqual(err, .missing(key: "durationMinutes"))
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }

    func test_createPumpingSession_outOfRangeDuration_throwsDomainError() async {
        let tool = CreatePumpingSessionTool(
            repository: InMemoryPumpingSessionRepository(),
            clock: TestClock()
        )
        let args = ToolArguments(["durationMinutes": .int(121)])

        do {
            _ = try await tool.execute(arguments: args)
            XCTFail("expected throw")
        } catch let err as PumpingSessionError {
            XCTAssertEqual(err, .durationOutOfRange)
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }

    func test_createPumpingSession_doesNotRequireConfirmation() {
        let tool = CreatePumpingSessionTool(
            repository: InMemoryPumpingSessionRepository(),
            clock: TestClock()
        )
        XCTAssertFalse(tool.requiresConfirmation)
    }

    // MARK: - UpdatePumpingSessionTool

    func test_updatePumpingSession_patchesFieldAndPreservesId() async throws {
        let repo = InMemoryPumpingSessionRepository()
        let original = try PumpingSession(
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            durationMinutes: 20,
            milkVolumeMl: 80
        )
        try await repo.save(original)

        let tool = UpdatePumpingSessionTool(repository: repo)
        let args = ToolArguments([
            "id": .string(original.id.uuidString),
            "durationMinutes": .int(25),
        ])

        _ = try await tool.execute(arguments: args)

        let all = try await repo.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.id, original.id)
        XCTAssertEqual(all.first?.durationMinutes, 25)
        XCTAssertEqual(all.first?.milkVolumeMl, 80)
    }

    func test_updatePumpingSession_unknownId_throws() async throws {
        let repo = InMemoryPumpingSessionRepository()
        let tool = UpdatePumpingSessionTool(repository: repo)
        let args = ToolArguments([
            "id": .string(UUID().uuidString),
            "durationMinutes": .int(25),
        ])

        do {
            _ = try await tool.execute(arguments: args)
            XCTFail("expected throw")
        } catch let err as ChatToolError {
            if case .executionFailed = err {
                // ok
            } else {
                XCTFail("wrong error: \(err)")
            }
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }

    // MARK: - DeletePumpingSessionTool

    func test_deletePumpingSession_removesEntry() async throws {
        let repo = InMemoryPumpingSessionRepository()
        let s = try PumpingSession(
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            durationMinutes: 20
        )
        try await repo.save(s)
        let tool = DeletePumpingSessionTool(repository: repo)

        _ = try await tool.execute(arguments: ToolArguments([
            "id": .string(s.id.uuidString),
        ]))

        let all = try await repo.all()
        XCTAssertTrue(all.isEmpty)
    }

    func test_deletePumpingSession_invalidUUID_throws() async {
        let tool = DeletePumpingSessionTool(repository: InMemoryPumpingSessionRepository())

        do {
            _ = try await tool.execute(arguments: ToolArguments([
                "id": .string("not-a-uuid"),
            ]))
            XCTFail("expected throw")
        } catch let err as ChatToolError {
            if case .executionFailed = err { /* ok */ } else { XCTFail("wrong error: \(err)") }
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }

    // MARK: - ListRecentPumpingSessionsTool

    func test_listRecentPumpingSessions_emptyReturnsPlaceholder() async throws {
        let repo = InMemoryPumpingSessionRepository()
        let tool = ListRecentPumpingSessionsTool(repository: repo)

        let result = try await tool.execute(arguments: ToolArguments([:]))

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("No pumping sessions"))
    }

    func test_listRecentPumpingSessions_returnsFormattedLines() async throws {
        let repo = InMemoryPumpingSessionRepository()
        let s = try PumpingSession(
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            durationMinutes: 22,
            side: .both,
            milkVolumeMl: 120
        )
        try await repo.save(s)
        let tool = ListRecentPumpingSessionsTool(repository: repo)

        let result = try await tool.execute(arguments: ToolArguments(["limit": .int(5)]))

        XCTAssertTrue(result.content.contains("id=\(s.id.uuidString)"))
        XCTAssertTrue(result.content.contains("22 min"))
        XCTAssertTrue(result.content.contains("120 ml"))
        XCTAssertTrue(result.content.contains("both"))
    }

    func test_listRecentPumpingSessions_defaultLimitWhenOmitted() async throws {
        let repo = InMemoryPumpingSessionRepository()
        // 12 sessions. Default limit is 10.
        for i in 0..<12 {
            let s = try PumpingSession(
                startedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(i) * 100),
                durationMinutes: 20
            )
            try await repo.save(s)
        }
        let tool = ListRecentPumpingSessionsTool(repository: repo)

        let result = try await tool.execute(arguments: ToolArguments([:]))

        let lines = result.content.split(separator: "\n")
        XCTAssertEqual(lines.count, 10)
    }
}

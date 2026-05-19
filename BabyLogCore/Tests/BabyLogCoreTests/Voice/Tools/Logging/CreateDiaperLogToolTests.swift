import XCTest
@testable import BabyLogCore
import Foundation

final class CreateDiaperLogToolTests: XCTestCase {

    func test_createDiaperLog_happyPath_savesEntry() async throws {
        let repo = InMemoryDiaperLogRepository()
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_700_000_000))
        let tool = CreateDiaperLogTool(repository: repo, clock: clock)
        let args = ToolArguments(["type": .string("wet")])

        let result = try await tool.execute(arguments: args)

        let stored = try await repo.all()
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.type, .wet)
        XCTAssertEqual(stored.first?.loggedAt, clock.now())
        XCTAssertFalse(result.isError)
        let savedId = try XCTUnwrap(stored.first?.id)
        XCTAssertTrue(
            result.content.contains("id=\(savedId.uuidString)"),
            "expected result content to embed saved id, got: \(result.content)"
        )
    }

    func test_createDiaperLog_missingType_throwsToolArgumentsError() async {
        let tool = CreateDiaperLogTool(repository: InMemoryDiaperLogRepository(), clock: TestClock())
        let args = ToolArguments([:])

        do {
            _ = try await tool.execute(arguments: args)
            XCTFail("expected throw")
        } catch let error as ToolArgumentsError {
            XCTAssertEqual(error, .missing(key: "type"))
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func test_createDiaperLog_invalidType_throwsDiaperLogError() async {
        let tool = CreateDiaperLogTool(repository: InMemoryDiaperLogRepository(), clock: TestClock())
        let args = ToolArguments(["type": .string("sparkly")])

        do {
            _ = try await tool.execute(arguments: args)
            XCTFail("expected throw")
        } catch let error as DiaperLogError {
            XCTAssertEqual(error, .invalidType("sparkly"))
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func test_createDiaperLog_resultEmbedsDailyBreakdownAndGap() async throws {
        let repo = InMemoryDiaperLogRepository()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try await repo.save(DiaperLog(id: UUID(), type: .wet, loggedAt: base.addingTimeInterval(-2 * 3600)))
        try await repo.save(DiaperLog(id: UUID(), type: .dirty, loggedAt: base.addingTimeInterval(-1 * 3600)))
        let tool = CreateDiaperLogTool(repository: repo, clock: TestClock(now: base))

        let result = try await tool.execute(arguments: ToolArguments(["type": .string("wet")]))

        XCTAssertTrue(result.content.contains("Logged wet diaper"), result.content)
        XCTAssertTrue(result.content.contains("3 diapers"), result.content)
        XCTAssertTrue(result.content.contains("2 wet"), result.content)
        XCTAssertTrue(result.content.contains("1 dirty"), result.content)
        XCTAssertTrue(result.content.contains("Gap from previous: 1 h"), result.content)
    }

    func test_createDiaperLog_doesNotRequireConfirmation() {
        let tool = CreateDiaperLogTool(repository: InMemoryDiaperLogRepository(), clock: TestClock())

        XCTAssertFalse(tool.requiresConfirmation)
    }
}

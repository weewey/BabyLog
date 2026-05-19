import XCTest
@testable import BabyLogCore
import Foundation

final class CreateFeedLogToolTests: XCTestCase {

    func test_createFeedLog_happyPath_savesEntryAndReturnsSummary() async throws {
        let repo = InMemoryFeedLogRepository()
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_700_000_000))
        let tool = CreateFeedLogTool(repository: repo, clock: clock)
        let args = ToolArguments([
            "volumeMl": .int(120),
            "source": .string("bottle"),
        ])

        let result = try await tool.execute(arguments: args)

        let stored = try await repo.all()
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.volumeMl, 120)
        XCTAssertEqual(stored.first?.source, .bottle)
        XCTAssertEqual(stored.first?.loggedAt, clock.now())
        XCTAssertFalse(result.isError)
        XCTAssertFalse(result.content.isEmpty)
        let savedId = try XCTUnwrap(stored.first?.id)
        XCTAssertTrue(
            result.content.contains("id=\(savedId.uuidString)"),
            "expected result content to embed saved id, got: \(result.content)"
        )
    }

    func test_createFeedLog_missingVolume_throwsToolArgumentsError() async {
        let tool = CreateFeedLogTool(repository: InMemoryFeedLogRepository(), clock: TestClock())
        let args = ToolArguments(["source": .string("bottle")])

        do {
            _ = try await tool.execute(arguments: args)
            XCTFail("expected throw")
        } catch let error as ToolArgumentsError {
            XCTAssertEqual(error, .missing(key: "volumeMl"))
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func test_createFeedLog_negativeVolume_throwsFeedLogError() async {
        let tool = CreateFeedLogTool(repository: InMemoryFeedLogRepository(), clock: TestClock())
        let args = ToolArguments([
            "volumeMl": .int(-5),
            "source": .string("bottle"),
        ])

        do {
            _ = try await tool.execute(arguments: args)
            XCTFail("expected throw")
        } catch let error as FeedLogError {
            XCTAssertEqual(error, .volumeOutOfRange)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func test_createFeedLog_resultEmbedsTodaysCountTotalAndGap() async throws {
        // Two earlier feeds today, then save a third. Result text
        // should carry the running totals + gap for the model to quote.
        let repo = InMemoryFeedLogRepository()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let base = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14 22:13:20 UTC
        // Seed at t-4h and t-2h.
        try await repo.save(FeedLog(volumeMl: 60, loggedAt: base.addingTimeInterval(-4 * 3600), source: .bottle))
        try await repo.save(FeedLog(volumeMl: 90, loggedAt: base.addingTimeInterval(-2 * 3600), source: .bottle))
        let clock = TestClock(now: base)
        let tool = CreateFeedLogTool(repository: repo, clock: clock)

        let result = try await tool.execute(arguments: ToolArguments(["volumeMl": .int(100)]))

        XCTAssertTrue(result.content.contains("Logged 100 ml feed"), result.content)
        XCTAssertTrue(result.content.contains("3 feeds"), result.content)
        XCTAssertTrue(result.content.contains("250 ml total"), result.content)
        XCTAssertTrue(result.content.contains("Gap from previous: 2 h"), result.content)
    }

    func test_createFeedLog_firstFeedOfDay_omitsGap() async throws {
        let repo = InMemoryFeedLogRepository()
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_700_000_000))
        let tool = CreateFeedLogTool(repository: repo, clock: clock)

        let result = try await tool.execute(arguments: ToolArguments(["volumeMl": .int(60)]))

        XCTAssertTrue(result.content.contains("1 feed,"), result.content)
        XCTAssertTrue(result.content.contains("60 ml total"), result.content)
        XCTAssertFalse(result.content.contains("Gap from previous"), result.content)
    }

    func test_createFeedLog_doesNotRequireConfirmation() {
        let tool = CreateFeedLogTool(repository: InMemoryFeedLogRepository(), clock: TestClock())

        XCTAssertFalse(tool.requiresConfirmation)
    }
}

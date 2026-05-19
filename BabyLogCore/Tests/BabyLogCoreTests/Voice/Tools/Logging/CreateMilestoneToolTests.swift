import XCTest
@testable import BabyLogCore
import Foundation

final class CreateMilestoneToolTests: XCTestCase {

    func test_createMilestone_happyPath_savesEntry() async throws {
        let repo = InMemoryMilestoneRepository()
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_700_000_000))
        let tool = CreateMilestoneTool(repository: repo, clock: clock)
        let args = ToolArguments([
            "title": .string("First smile"),
            "notes": .string("Big grin after a feed"),
        ])

        let result = try await tool.execute(arguments: args)

        let stored = try await repo.all()
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.title, "First smile")
        XCTAssertEqual(stored.first?.notes, "Big grin after a feed")
        XCTAssertEqual(stored.first?.achievedAt, clock.now())
        XCTAssertFalse(result.isError)
        let savedId = try XCTUnwrap(stored.first?.id)
        XCTAssertTrue(
            result.content.contains("id=\(savedId.uuidString)"),
            "expected result content to embed saved id, got: \(result.content)"
        )
    }

    func test_createMilestone_resultIncludesTotalDaysSinceLastAndAge() async throws {
        let repo = InMemoryMilestoneRepository()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let birth = now.addingTimeInterval(-30 * 86400)
        try await repo.save(Milestone(title: "First smile", achievedAt: now.addingTimeInterval(-5 * 86400), notes: nil))
        let tool = CreateMilestoneTool(
            repository: repo,
            clock: TestClock(now: now),
            birthDate: birth
        )

        let result = try await tool.execute(arguments: ToolArguments(["title": .string("Rolled over")]))

        XCTAssertTrue(result.content.contains("Logged milestone: Rolled over"), result.content)
        XCTAssertTrue(result.content.contains("2 milestones total"), result.content)
        XCTAssertTrue(result.content.contains("5 days since the last one (First smile)"), result.content)
        XCTAssertTrue(result.content.contains("30 days old"), result.content)
    }

    func test_createMilestone_missingTitle_throwsToolArgumentsError() async {
        let tool = CreateMilestoneTool(repository: InMemoryMilestoneRepository(), clock: TestClock())
        let args = ToolArguments([:])

        do {
            _ = try await tool.execute(arguments: args)
            XCTFail("expected throw")
        } catch let error as ToolArgumentsError {
            XCTAssertEqual(error, .missing(key: "title"))
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func test_createMilestone_emptyTitle_throwsMilestoneError() async {
        let tool = CreateMilestoneTool(repository: InMemoryMilestoneRepository(), clock: TestClock())
        let args = ToolArguments(["title": .string("   ")])

        do {
            _ = try await tool.execute(arguments: args)
            XCTFail("expected throw")
        } catch let error as MilestoneError {
            XCTAssertEqual(error, .emptyTitle)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func test_createMilestone_doesNotRequireConfirmation() {
        let tool = CreateMilestoneTool(repository: InMemoryMilestoneRepository(), clock: TestClock())

        XCTAssertFalse(tool.requiresConfirmation)
    }
}

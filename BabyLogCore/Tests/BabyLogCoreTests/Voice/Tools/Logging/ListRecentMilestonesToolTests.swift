import XCTest
@testable import BabyLogCore
import Foundation

final class ListRecentMilestonesToolTests: XCTestCase {

    private func makeMilestone(title: String, at t: TimeInterval) throws -> Milestone {
        try Milestone(title: title, achievedAt: Date(timeIntervalSince1970: t))
    }

    func test_listRecentMilestones_emptyRepo_returnsEmptyMessage() async throws {
        let tool = ListRecentMilestonesTool(repository: InMemoryMilestoneRepository())

        let result = try await tool.execute(arguments: ToolArguments())

        XCTAssertEqual(result.content, "No milestones yet.")
    }

    func test_listRecentMilestones_returnsEntriesSortedNewestFirst() async throws {
        let repo = InMemoryMilestoneRepository()
        let a = try makeMilestone(title: "first smile", at: 1_700_000_000)
        let b = try makeMilestone(title: "rolled over",  at: 1_700_010_000)
        let c = try makeMilestone(title: "held head up", at: 1_700_005_000)
        try await repo.save(a)
        try await repo.save(b)
        try await repo.save(c)
        let tool = ListRecentMilestonesTool(repository: repo)

        let result = try await tool.execute(arguments: ToolArguments())

        let lines = result.content.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].contains("rolled over"))
        XCTAssertTrue(lines[1].contains("held head up"))
        XCTAssertTrue(lines[2].contains("first smile"))
    }

    func test_listRecentMilestones_respectsLimit() async throws {
        let repo = InMemoryMilestoneRepository()
        for i in 0..<6 {
            try await repo.save(try makeMilestone(title: "m\(i)", at: 1_700_000_000 + Double(i) * 1000))
        }
        let tool = ListRecentMilestonesTool(repository: repo)

        let result = try await tool.execute(arguments: ToolArguments(["limit": .int(1)]))

        XCTAssertEqual(result.content.split(separator: "\n").count, 1)
    }

    func test_listRecentMilestones_malformedLimit_fallsBackToDefault() async throws {
        let repo = InMemoryMilestoneRepository()
        for i in 0..<8 {
            try await repo.save(try makeMilestone(title: "m\(i)", at: 1_700_000_000 + Double(i) * 1000))
        }
        let tool = ListRecentMilestonesTool(repository: repo)

        let result = try await tool.execute(arguments: ToolArguments(["limit": .string("many")]))

        XCTAssertEqual(result.content.split(separator: "\n").count, 5)
    }
}

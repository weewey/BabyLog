import XCTest
@testable import LittleECore
import Foundation

final class ListRecentDiaperLogsToolTests: XCTestCase {

    private func makeDiaper(id: UUID = UUID(), type: DiaperType, at t: TimeInterval) -> DiaperLog {
        DiaperLog(id: id, type: type, loggedAt: Date(timeIntervalSince1970: t))
    }

    func test_listRecentDiaperLogs_emptyRepo_returnsEmptyMessage() async throws {
        let tool = ListRecentDiaperLogsTool(repository: InMemoryDiaperLogRepository())

        let result = try await tool.execute(arguments: ToolArguments())

        XCTAssertEqual(result.content, "No diaper logs yet.")
    }

    func test_listRecentDiaperLogs_returnsEntriesSortedNewestFirst() async throws {
        let repo = InMemoryDiaperLogRepository()
        let a = makeDiaper(type: .wet,  at: 1_700_000_000)
        let b = makeDiaper(type: .dirty, at: 1_700_010_000)
        let c = makeDiaper(type: .both,  at: 1_700_005_000)
        try await repo.save(a)
        try await repo.save(b)
        try await repo.save(c)
        let tool = ListRecentDiaperLogsTool(repository: repo)

        let result = try await tool.execute(arguments: ToolArguments())

        let lines = result.content.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].contains("dirty"))
        XCTAssertTrue(lines[1].contains("both"))
        XCTAssertTrue(lines[2].contains("wet"))
        XCTAssertTrue(lines[0].contains("id=\(b.id.uuidString)"))
    }

    func test_listRecentDiaperLogs_respectsLimit() async throws {
        let repo = InMemoryDiaperLogRepository()
        for i in 0..<6 {
            try await repo.save(makeDiaper(type: .wet, at: 1_700_000_000 + Double(i) * 1000))
        }
        let tool = ListRecentDiaperLogsTool(repository: repo)

        let result = try await tool.execute(arguments: ToolArguments(["limit": .int(3)]))

        XCTAssertEqual(result.content.split(separator: "\n").count, 3)
    }

    func test_listRecentDiaperLogs_malformedLimit_fallsBackToDefault() async throws {
        let repo = InMemoryDiaperLogRepository()
        for i in 0..<8 {
            try await repo.save(makeDiaper(type: .wet, at: 1_700_000_000 + Double(i) * 1000))
        }
        let tool = ListRecentDiaperLogsTool(repository: repo)

        let result = try await tool.execute(arguments: ToolArguments(["limit": .string("nope")]))

        XCTAssertEqual(result.content.split(separator: "\n").count, 5)
    }
}

import XCTest
@testable import BabyLogCore
import Foundation

final class ListRecentGrowthMeasurementsToolTests: XCTestCase {

    private func makeMeasurement(weight: Int, at t: TimeInterval) throws -> GrowthMeasurement {
        try GrowthMeasurement(
            date: Date(timeIntervalSince1970: t),
            weightGrams: weight
        )
    }

    func test_listRecentGrowthMeasurements_emptyRepo_returnsEmptyMessage() async throws {
        let tool = ListRecentGrowthMeasurementsTool(repository: InMemoryGrowthMeasurementRepository())

        let result = try await tool.execute(arguments: ToolArguments())

        XCTAssertEqual(result.content, "No growth measurements yet.")
    }

    func test_listRecentGrowthMeasurements_returnsEntriesSortedNewestFirst() async throws {
        let repo = InMemoryGrowthMeasurementRepository()
        let a = try makeMeasurement(weight: 4000, at: 1_700_000_000)
        let b = try makeMeasurement(weight: 4500, at: 1_700_010_000)
        let c = try makeMeasurement(weight: 4200, at: 1_700_005_000)
        try await repo.save(a)
        try await repo.save(b)
        try await repo.save(c)
        let tool = ListRecentGrowthMeasurementsTool(repository: repo)

        let result = try await tool.execute(arguments: ToolArguments())

        let lines = result.content.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].contains("4500 g"))
        XCTAssertTrue(lines[1].contains("4200 g"))
        XCTAssertTrue(lines[2].contains("4000 g"))
    }

    func test_listRecentGrowthMeasurements_respectsLimit() async throws {
        let repo = InMemoryGrowthMeasurementRepository()
        for i in 0..<6 {
            try await repo.save(try makeMeasurement(weight: 4000 + i * 10, at: 1_700_000_000 + Double(i) * 1000))
        }
        let tool = ListRecentGrowthMeasurementsTool(repository: repo)

        let result = try await tool.execute(arguments: ToolArguments(["limit": .int(2)]))

        XCTAssertEqual(result.content.split(separator: "\n").count, 2)
    }

    func test_listRecentGrowthMeasurements_malformedLimit_fallsBackToDefault() async throws {
        let repo = InMemoryGrowthMeasurementRepository()
        for i in 0..<8 {
            try await repo.save(try makeMeasurement(weight: 4000 + i * 10, at: 1_700_000_000 + Double(i) * 1000))
        }
        let tool = ListRecentGrowthMeasurementsTool(repository: repo)

        let result = try await tool.execute(arguments: ToolArguments(["limit": .bool(true)]))

        XCTAssertEqual(result.content.split(separator: "\n").count, 5)
    }
}

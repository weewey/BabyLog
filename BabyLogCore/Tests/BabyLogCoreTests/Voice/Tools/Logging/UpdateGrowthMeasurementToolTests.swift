import XCTest
@testable import BabyLogCore
import Foundation

final class UpdateGrowthMeasurementToolTests: XCTestCase {

    private func makeOriginal(id: GrowthMeasurementID) throws -> GrowthMeasurement {
        try GrowthMeasurement(
            id: id,
            date: Date(timeIntervalSince1970: 1_700_000_000),
            weightGrams: 4000,
            heightCm: 55.0,
            headCircumferenceCm: 38.0,
            notes: "initial"
        )
    }

    func test_updateGrowthMeasurement_patchesWeightAndKeepsOthers() async throws {
        let repo = InMemoryGrowthMeasurementRepository()
        let id = GrowthMeasurementID(UUID())
        try await repo.save(try makeOriginal(id: id))
        let tool = UpdateGrowthMeasurementTool(repository: repo)
        let args = ToolArguments([
            "id": .string(id.value.uuidString),
            "weightGrams": .int(4500),
        ])

        _ = try await tool.execute(arguments: args)

        let stored = try await repo.all()
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.id, id)
        XCTAssertEqual(stored.first?.weightGrams, 4500)
        XCTAssertEqual(stored.first?.heightCm, 55.0)
        XCTAssertEqual(stored.first?.headCircumferenceCm, 38.0)
        XCTAssertEqual(stored.first?.notes, "initial")
    }

    func test_updateGrowthMeasurement_patchesAllFields() async throws {
        let repo = InMemoryGrowthMeasurementRepository()
        let id = GrowthMeasurementID(UUID())
        try await repo.save(try makeOriginal(id: id))
        let tool = UpdateGrowthMeasurementTool(repository: repo)
        let newDate = "2026-04-13T10:30:00Z"
        let args = ToolArguments([
            "id": .string(id.value.uuidString),
            "weightGrams": .int(5000),
            "heightCm": .double(60.0),
            "headCircumferenceCm": .double(40.0),
            "date": .string(newDate),
            "notes": .string("updated"),
        ])

        _ = try await tool.execute(arguments: args)

        let stored = try await repo.all()
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.weightGrams, 5000)
        XCTAssertEqual(stored.first?.heightCm, 60.0)
        XCTAssertEqual(stored.first?.headCircumferenceCm, 40.0)
        XCTAssertEqual(stored.first?.notes, "updated")
        // "Z"-suffixed strings from the AI are treated as local time (not UTC).
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let components = cal.dateComponents([.year, .month, .day, .hour, .minute], from: try XCTUnwrap(stored.first?.date))
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 4)
        XCTAssertEqual(components.day, 13)
        XCTAssertEqual(components.hour, 10)
        XCTAssertEqual(components.minute, 30)
    }

    func test_updateGrowthMeasurement_unknownId_throwsExecutionFailed() async {
        let tool = UpdateGrowthMeasurementTool(repository: InMemoryGrowthMeasurementRepository())
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

    func test_updateGrowthMeasurement_invalidUUID_throwsExecutionFailed() async {
        let tool = UpdateGrowthMeasurementTool(repository: InMemoryGrowthMeasurementRepository())
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
}

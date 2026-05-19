import XCTest
@testable import BabyLogCore
import Foundation

final class DeleteGrowthMeasurementToolTests: XCTestCase {

    func test_deleteGrowthMeasurement_removesEntryById() async throws {
        let repo = InMemoryGrowthMeasurementRepository()
        let uuid = UUID()
        let measurement = try GrowthMeasurement(
            id: GrowthMeasurementID(uuid),
            date: Date(timeIntervalSince1970: 1_700_000_000),
            weightGrams: 4200,
            heightCm: nil,
            headCircumferenceCm: nil
        )
        try await repo.save(measurement)
        let tool = DeleteGrowthMeasurementTool(repository: repo)
        let args = ToolArguments(["id": .string(uuid.uuidString)])

        let result = try await tool.execute(arguments: args)

        let remaining = try await repo.all()
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertFalse(result.isError)
    }

    func test_deleteGrowthMeasurement_unknownId_throwsExecutionFailed() async {
        let tool = DeleteGrowthMeasurementTool(repository: InMemoryGrowthMeasurementRepository())
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

    func test_deleteGrowthMeasurement_invalidUUID_throwsExecutionFailed() async {
        let tool = DeleteGrowthMeasurementTool(repository: InMemoryGrowthMeasurementRepository())
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

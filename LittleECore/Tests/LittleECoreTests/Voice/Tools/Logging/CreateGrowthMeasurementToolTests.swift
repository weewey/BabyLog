import XCTest
@testable import LittleECore
import Foundation

final class CreateGrowthMeasurementToolTests: XCTestCase {

    func test_createGrowthMeasurement_happyPath_savesEntry() async throws {
        let repo = InMemoryGrowthMeasurementRepository()
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_700_000_000))
        let tool = CreateGrowthMeasurementTool(repository: repo, clock: clock)
        let args = ToolArguments([
            "weightGrams": .int(4200),
            "heightCm": .double(54.5),
        ])

        let result = try await tool.execute(arguments: args)

        let stored = try await repo.all()
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.weightGrams, 4200)
        XCTAssertEqual(stored.first?.heightCm, 54.5)
        XCTAssertEqual(stored.first?.date, clock.now())
        XCTAssertFalse(result.isError)
        let savedId = try XCTUnwrap(stored.first?.id)
        XCTAssertTrue(
            result.content.contains("id=\(savedId.value.uuidString)"),
            "expected result content to embed saved id, got: \(result.content)"
        )
    }

    func test_createGrowthMeasurement_resultIncludesWeightDeltaSinceLast() async throws {
        let repo = InMemoryGrowthMeasurementRepository()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        // Prior weight a week ago: 4000 g.
        try await repo.save(GrowthMeasurement(date: now.addingTimeInterval(-7 * 86400), weightGrams: 4000, heightCm: nil, headCircumferenceCm: nil))
        let tool = CreateGrowthMeasurementTool(repository: repo, clock: TestClock(now: now))

        let result = try await tool.execute(arguments: ToolArguments(["weightGrams": .int(4200)]))

        XCTAssertTrue(result.content.contains("4.20 kg"), result.content)
        XCTAssertTrue(result.content.contains("+200 g since last"), result.content)
        XCTAssertTrue(result.content.contains("7 days since last measurement"), result.content)
    }

    func test_createGrowthMeasurement_firstOnRecord_saysFirst() async throws {
        let tool = CreateGrowthMeasurementTool(
            repository: InMemoryGrowthMeasurementRepository(),
            clock: TestClock(now: Date(timeIntervalSince1970: 1_700_000_000))
        )

        let result = try await tool.execute(arguments: ToolArguments(["weightGrams": .int(3500)]))

        XCTAssertTrue(result.content.contains("First growth measurement"), result.content)
        XCTAssertFalse(result.content.contains("since last"), result.content)
    }

    func test_createGrowthMeasurement_noFieldsSupplied_throwsExecutionFailed() async {
        let tool = CreateGrowthMeasurementTool(
            repository: InMemoryGrowthMeasurementRepository(),
            clock: TestClock()
        )
        let args = ToolArguments([:])

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

    func test_createGrowthMeasurement_outOfRangeWeight_throwsDomainError() async {
        let tool = CreateGrowthMeasurementTool(
            repository: InMemoryGrowthMeasurementRepository(),
            clock: TestClock()
        )
        let args = ToolArguments(["weightGrams": .int(20)])

        do {
            _ = try await tool.execute(arguments: args)
            XCTFail("expected throw")
        } catch let error as GrowthMeasurementError {
            XCTAssertEqual(error, .weightOutOfRange(20))
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func test_createGrowthMeasurement_doesNotRequireConfirmation() {
        let tool = CreateGrowthMeasurementTool(
            repository: InMemoryGrowthMeasurementRepository(),
            clock: TestClock()
        )

        XCTAssertFalse(tool.requiresConfirmation)
    }
}

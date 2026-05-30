import XCTest
@testable import BabyLog

final class MLXMemoryTuningTests: XCTestCase {

    func test_memoryLimit_isBelowRecommendedWorkingSet() {
        // The MLX default memoryLimit is 1.5x the device's recommended GPU
        // working set, which overshoots the GPU ceiling on iOS and gets a
        // Metal command buffer denied mid-generation (uncatchable SIGABRT).
        // Our cap must sit *below* the recommended working set, not above it.
        let workingSet: UInt64 = 6 * 1024 * 1024 * 1024  // 6 GB

        let limit = MLXMemoryTuning.memoryLimitBytes(recommendedWorkingSet: workingSet)

        XCTAssertLessThan(limit, Int(workingSet))
        XCTAssertGreaterThan(limit, 0)
    }

    func test_memoryLimit_leavesHeadroomForA2BModel() {
        // A ~1.5 GB model plus KV cache must still fit under the cap on a
        // typical 6 GB-working-set phone.
        let workingSet: UInt64 = 6 * 1024 * 1024 * 1024

        let limit = MLXMemoryTuning.memoryLimitBytes(recommendedWorkingSet: workingSet)

        XCTAssertGreaterThan(limit, 3 * 1024 * 1024 * 1024)
    }

    func test_memoryLimit_handlesZeroWorkingSet_returnsNonNegative() {
        // Some virtualized/unknown devices report 0; never produce a negative
        // or absurd limit.
        XCTAssertGreaterThanOrEqual(
            MLXMemoryTuning.memoryLimitBytes(recommendedWorkingSet: 0),
            0
        )
    }
}

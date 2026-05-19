import XCTest
@testable import BabyLog

final class BackgroundTaskRegistrarTests: XCTestCase {

    func test_taskIdentifier_matchesInfoPlistValue() {
        XCTAssertEqual(
            BackgroundTaskRegistrar.taskIdentifier,
            "com.babylog.feedRefresh"
        )
    }

    func test_minimumInterval_isFifteenMinutes() {
        XCTAssertEqual(
            BackgroundTaskRegistrar.minimumInterval,
            15 * 60
        )
    }
}

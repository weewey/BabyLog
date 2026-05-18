import XCTest
@testable import LittleE

final class BackgroundTaskRegistrarTests: XCTestCase {

    func test_taskIdentifier_matchesInfoPlistValue() {
        XCTAssertEqual(
            BackgroundTaskRegistrar.taskIdentifier,
            "com.littlee.feedRefresh"
        )
    }

    func test_minimumInterval_isFifteenMinutes() {
        XCTAssertEqual(
            BackgroundTaskRegistrar.minimumInterval,
            15 * 60
        )
    }
}

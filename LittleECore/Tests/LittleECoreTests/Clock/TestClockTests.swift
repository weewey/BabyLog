import XCTest
@testable import LittleECore

final class TestClockTests: XCTestCase {

    func test_testClock_returnsInjectedInitialDate() {
        // arrange
        let initial = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = TestClock(now: initial)

        // act
        let result = clock.now()

        // assert
        XCTAssertEqual(result, initial)
    }

    func test_testClock_advanceBy_movesCurrentTimeForward() {
        // arrange
        let initial = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = TestClock(now: initial)

        // act
        clock.advance(by: 60)

        // assert
        XCTAssertEqual(clock.now(), initial.addingTimeInterval(60))
    }

    func test_testClock_setTo_overridesCurrentTime() {
        // arrange
        let clock = TestClock(now: Date(timeIntervalSince1970: 0))
        let target = Date(timeIntervalSince1970: 500)

        // act
        clock.set(to: target)

        // assert
        XCTAssertEqual(clock.now(), target)
    }

    func test_systemClock_returnsDateCloseToNow() {
        // arrange
        let clock = SystemClock()

        // act
        let result = clock.now()

        // assert
        XCTAssertLessThan(abs(result.timeIntervalSinceNow), 1.0)
    }
}

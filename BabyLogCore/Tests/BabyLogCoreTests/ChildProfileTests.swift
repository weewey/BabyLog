import XCTest
@testable import BabyLogCore
import Foundation

final class ChildProfileTests: XCTestCase {

    private static var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    func test_init_emptyNameThrows() {
        XCTAssertThrowsError(try ChildProfile(name: "   ", dateOfBirth: Date(timeIntervalSince1970: 0))) { err in
            XCTAssertEqual(err as? ChildProfileError, .emptyName)
        }
    }

    func test_init_futureDOBThrows() {
        let now = Date(timeIntervalSince1970: 1_000)
        let future = Date(timeIntervalSince1970: 2_000)
        XCTAssertThrowsError(try ChildProfile(name: "Ethan", dateOfBirth: future, now: now)) { err in
            XCTAssertEqual(err as? ChildProfileError, .futureDateOfBirth)
        }
    }

    func test_shortLabel_daysWeeksMonthsYears() {
        let dob = Date(timeIntervalSince1970: 0)
        let plus3d = dob.addingTimeInterval(3 * 86_400)
        XCTAssertEqual(ChildAge.shortLabel(dateOfBirth: dob, now: plus3d, calendar: Self.cal), "3d")

        let plus10d = dob.addingTimeInterval(10 * 86_400)
        XCTAssertEqual(ChildAge.shortLabel(dateOfBirth: dob, now: plus10d, calendar: Self.cal), "1w 3d")
    }
}

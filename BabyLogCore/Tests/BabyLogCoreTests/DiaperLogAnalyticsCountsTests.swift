import XCTest
@testable import BabyLogCore
import Foundation

final class DiaperLogAnalyticsCountsTests: XCTestCase {

    private static var utcCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    func test_countsFor_emptyInput_returnsZero() {
        let counts = DiaperLogAnalytics.countsFor([], on: Date(), calendar: Self.utcCalendar)
        XCTAssertEqual(counts, DiaperLogAnalytics.DailyCounts(wet: 0, dirty: 0, both: 0))
    }

    func test_countsFor_sumsSameDayByType() {
        let cal = Self.utcCalendar
        let day = Date(timeIntervalSince1970: 86_400)
        let l1 = DiaperLog(id: UUID(), type: .wet, loggedAt: day)
        let l2 = DiaperLog(id: UUID(), type: .wet, loggedAt: day + 3_600)
        let l3 = DiaperLog(id: UUID(), type: .dirty, loggedAt: day + 7_200)
        let l4 = DiaperLog(id: UUID(), type: .both, loggedAt: day + 10_800)

        let counts = DiaperLogAnalytics.countsFor([l1, l2, l3, l4], on: day, calendar: cal)

        XCTAssertEqual(counts.wet, 2)
        XCTAssertEqual(counts.dirty, 1)
        XCTAssertEqual(counts.both, 1)
        XCTAssertEqual(counts.total, 4)
    }

    func test_countsFor_ignoresOtherDays() {
        let cal = Self.utcCalendar
        let today = Date(timeIntervalSince1970: 86_400)
        let yesterday = Date(timeIntervalSince1970: 0)
        let t = DiaperLog(id: UUID(), type: .wet, loggedAt: today)
        let y = DiaperLog(id: UUID(), type: .dirty, loggedAt: yesterday)

        let counts = DiaperLogAnalytics.countsFor([t, y], on: today, calendar: cal)

        XCTAssertEqual(counts.wet, 1)
        XCTAssertEqual(counts.dirty, 0)
        XCTAssertEqual(counts.both, 0)
    }
}

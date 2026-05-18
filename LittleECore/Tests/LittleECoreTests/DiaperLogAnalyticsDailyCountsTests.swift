import XCTest
@testable import LittleECore
import Foundation

final class DiaperLogAnalyticsDailyCountsTests: XCTestCase {

    private static var utcCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private static func day(_ offsetFromEpochDays: Int) -> Date {
        Date(timeIntervalSince1970: TimeInterval(offsetFromEpochDays * 86_400))
    }

    func test_dailyCounts_emptyInput_returnsZeroFilledWindow() {
        let cal = Self.utcCalendar
        let endingOn = Self.day(10)

        let points = DiaperLogAnalytics.dailyCounts(
            [],
            endingOn: endingOn,
            days: 7,
            calendar: cal
        )

        XCTAssertEqual(points.count, 7)
        for p in points {
            XCTAssertEqual(p.wet, 0)
            XCTAssertEqual(p.dirty, 0)
            XCTAssertEqual(p.both, 0)
        }
        XCTAssertEqual(
            points.map(\.date),
            (4...10).map { Self.day($0) }
        )
    }

    func test_dailyCounts_singleWetToday_bucketsIntoTodayOnly() {
        let cal = Self.utcCalendar
        let today = Self.day(20)
        let log = DiaperLog(id: UUID(), type: .wet, loggedAt: today + 3_600)

        let points = DiaperLogAnalytics.dailyCounts(
            [log],
            endingOn: today,
            days: 3,
            calendar: cal
        )

        XCTAssertEqual(points.count, 3)
        XCTAssertEqual(points[0], .init(date: Self.day(18), wet: 0, dirty: 0, both: 0))
        XCTAssertEqual(points[1], .init(date: Self.day(19), wet: 0, dirty: 0, both: 0))
        XCTAssertEqual(points[2], .init(date: Self.day(20), wet: 1, dirty: 0, both: 0))
    }

    func test_dailyCounts_mixedTypesAcrossDays_bucketsCorrectly() {
        let cal = Self.utcCalendar
        let today = Self.day(30)
        let yesterday = Self.day(29)
        let twoDaysAgo = Self.day(28)

        let logs: [DiaperLog] = [
            DiaperLog(id: UUID(), type: .wet,   loggedAt: today + 1_000),
            DiaperLog(id: UUID(), type: .dirty, loggedAt: yesterday + 2_000),
            DiaperLog(id: UUID(), type: .both,  loggedAt: twoDaysAgo + 3_000),
        ]

        let points = DiaperLogAnalytics.dailyCounts(
            logs,
            endingOn: today,
            days: 3,
            calendar: cal
        )

        XCTAssertEqual(points[0], .init(date: twoDaysAgo, wet: 0, dirty: 0, both: 1))
        XCTAssertEqual(points[1], .init(date: yesterday,  wet: 0, dirty: 1, both: 0))
        XCTAssertEqual(points[2], .init(date: today,      wet: 1, dirty: 0, both: 0))
    }

    func test_dailyCounts_excludesEntriesOutsideWindow() {
        let cal = Self.utcCalendar
        let today = Self.day(100)
        let wayBack = Self.day(90)
        let log = DiaperLog(id: UUID(), type: .wet, loggedAt: wayBack)

        let points = DiaperLogAnalytics.dailyCounts(
            [log],
            endingOn: today,
            days: 7,
            calendar: cal
        )

        XCTAssertEqual(points.count, 7)
        for p in points {
            XCTAssertEqual(p.wet, 0)
            XCTAssertEqual(p.dirty, 0)
            XCTAssertEqual(p.both, 0)
        }
    }

    func test_dailyCounts_ordersByDateAscending() {
        let cal = Self.utcCalendar
        let endingOn = Self.day(50)

        let points = DiaperLogAnalytics.dailyCounts(
            [],
            endingOn: endingOn,
            days: 5,
            calendar: cal
        )

        let dates = points.map(\.date)
        XCTAssertEqual(dates.count, 5)
        for i in 1..<dates.count {
            XCTAssertLessThan(dates[i - 1], dates[i])
        }
    }

    func test_dailyCounts_zeroDays_returnsEmpty() {
        let points = DiaperLogAnalytics.dailyCounts(
            [],
            endingOn: Date(),
            days: 0,
            calendar: Self.utcCalendar
        )

        XCTAssertEqual(points, [])
    }

    func test_dailyCounts_respectsCalendarTimezoneForDayBoundaries() {
        var sgt = Calendar(identifier: .gregorian)
        sgt.timeZone = TimeZone(identifier: "Asia/Singapore")!
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!

        // 2026-04-13 23:30 Asia/Singapore == 2026-04-13 15:30 UTC.
        var comps = DateComponents()
        comps.year = 2026; comps.month = 4; comps.day = 13
        comps.hour = 23; comps.minute = 30
        comps.timeZone = TimeZone(identifier: "Asia/Singapore")
        guard let loggedAt = Calendar(identifier: .gregorian).date(from: comps) else {
            return XCTFail("could not build Asia/Singapore date")
        }
        let log = DiaperLog(id: UUID(), type: .wet, loggedAt: loggedAt)

        // Window ending on 2026-04-14 in each calendar.
        var endSGT = DateComponents()
        endSGT.year = 2026; endSGT.month = 4; endSGT.day = 14
        endSGT.hour = 12; endSGT.timeZone = TimeZone(identifier: "Asia/Singapore")
        let endingSGT = Calendar(identifier: .gregorian).date(from: endSGT) ?? Date()

        let sgtPoints = DiaperLogAnalytics.dailyCounts(
            [log],
            endingOn: endingSGT,
            days: 2,
            calendar: sgt
        )
        // SGT: log bucketed into April 13, not April 14.
        XCTAssertEqual(sgtPoints.count, 2)
        XCTAssertEqual(sgtPoints[0].wet, 1, "log should land in April 13 SGT")
        XCTAssertEqual(sgtPoints[1].wet, 0, "April 14 SGT should be empty")

        var endUTC = DateComponents()
        endUTC.year = 2026; endUTC.month = 4; endUTC.day = 14
        endUTC.hour = 12; endUTC.timeZone = TimeZone(identifier: "UTC")
        let endingUTC = Calendar(identifier: .gregorian).date(from: endUTC) ?? Date()

        let utcPoints = DiaperLogAnalytics.dailyCounts(
            [log],
            endingOn: endingUTC,
            days: 2,
            calendar: utc
        )
        // UTC: 15:30 UTC on April 13 — bucketed into April 13 UTC.
        XCTAssertEqual(utcPoints.count, 2)
        XCTAssertEqual(utcPoints[0].wet, 1, "log should land in April 13 UTC")
        XCTAssertEqual(utcPoints[1].wet, 0, "April 14 UTC should be empty")
    }
}

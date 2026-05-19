import XCTest
@testable import BabyLogCore
import Foundation

final class FeedLogGroupingTests: XCTestCase {

    private var calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    private let day1Start = Date(timeIntervalSince1970: 1_699_920_000)
    private let day2Start = Date(timeIntervalSince1970: 1_700_006_400)

    // MARK: - Helpers

    private func makeLog(
        volumeMl: Int = 100,
        at date: Date,
        source: FeedSource = .bottle
    ) throws -> FeedLog {
        try FeedLog(volumeMl: volumeMl, loggedAt: date, source: source)
    }

    // MARK: - Same-day grouping

    func test_grouping_twoEntriesOnSameDayProduceOneGroup() throws {
        let t1 = day1Start.addingTimeInterval(3_600)
        let t2 = day1Start.addingTimeInterval(7_200)
        let feed1 = try makeLog(at: t1)
        let feed2 = try makeLog(at: t2)

        let groups = groupFeedsByDay([feed1, feed2], calendar: calendar)

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].1.count, 2)
    }

    // MARK: - Multi-day ordering

    func test_grouping_newestDayAppearsFirst() throws {
        let t1 = day1Start.addingTimeInterval(3_600)
        let t2 = day2Start.addingTimeInterval(3_600)
        let feed1 = try makeLog(at: t1)
        let feed2 = try makeLog(at: t2)

        let groups = groupFeedsByDay([feed1, feed2], calendar: calendar)

        XCTAssertEqual(groups.count, 2)
        XCTAssertGreaterThan(groups[0].0, groups[1].0)
        XCTAssertEqual(groups[0].1.first?.id, feed2.id)
        XCTAssertEqual(groups[1].1.first?.id, feed1.id)
    }

    // MARK: - Within-day ordering

    func test_grouping_entriesWithinDayAreNewestFirst() throws {
        let t1 = day1Start.addingTimeInterval(1_800)
        let t2 = day1Start.addingTimeInterval(3_600)
        let t3 = day1Start.addingTimeInterval(7_200)
        let feed1 = try makeLog(volumeMl: 80, at: t1)
        let feed2 = try makeLog(volumeMl: 100, at: t2)
        let feed3 = try makeLog(volumeMl: 120, at: t3)

        let groups = groupFeedsByDay([feed1, feed2, feed3], calendar: calendar)

        XCTAssertEqual(groups.count, 1)
        let entries = groups[0].1
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries[0].id, feed3.id)
        XCTAssertEqual(entries[1].id, feed2.id)
        XCTAssertEqual(entries[2].id, feed1.id)
    }

    // MARK: - Edge cases

    func test_grouping_emptyInputReturnsEmptyGroups() {
        let groups = groupFeedsByDay([], calendar: calendar)

        XCTAssertTrue(groups.isEmpty)
    }
}

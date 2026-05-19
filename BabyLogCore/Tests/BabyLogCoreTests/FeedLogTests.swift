import XCTest
@testable import BabyLogCore
import Foundation

final class FeedLogTests: XCTestCase {

    private let fixedDate = Date(timeIntervalSince1970: 1_699_920_000)

    // MARK: - Valid boundary values

    func test_feedLog_acceptsMinimumVolume() throws {
        let log = try FeedLog(volumeMl: 1, loggedAt: fixedDate, source: .bottle)

        XCTAssertEqual(log.volumeMl, 1)
    }

    func test_feedLog_acceptsTypicalVolume() throws {
        let log = try FeedLog(volumeMl: 120, loggedAt: fixedDate, source: .breast)

        XCTAssertEqual(log.volumeMl, 120)
    }

    func test_feedLog_acceptsMaximumVolume() throws {
        let log = try FeedLog(volumeMl: 500, loggedAt: fixedDate, source: .bottle)

        XCTAssertEqual(log.volumeMl, 500)
    }

    // MARK: - Invalid boundary values

    func test_feedLog_rejectsZeroVolume() {
        XCTAssertThrowsError(
            try FeedLog(volumeMl: 0, loggedAt: fixedDate, source: .bottle)
        ) { error in
            XCTAssertEqual(error as? FeedLogError, .volumeOutOfRange)
        }
    }

    func test_feedLog_rejectsVolumeGreaterThan500() {
        XCTAssertThrowsError(
            try FeedLog(volumeMl: 501, loggedAt: fixedDate, source: .bottle)
        ) { error in
            XCTAssertEqual(error as? FeedLogError, .volumeOutOfRange)
        }
    }

    // MARK: - Field integrity

    func test_feedLog_storesSuppliedFields() throws {
        let knownID = UUID()

        let log = try FeedLog(
            id: knownID,
            volumeMl: 200,
            loggedAt: fixedDate,
            source: .breast
        )

        XCTAssertEqual(log.id, knownID)
        XCTAssertEqual(log.volumeMl, 200)
        XCTAssertEqual(log.loggedAt, fixedDate)
        XCTAssertEqual(log.source, .breast)
    }
}

import XCTest
@testable import BabyLogCore
import Foundation

final class ToolArgumentsTests: XCTestCase {

    func test_string_returnsValueWhenPresent() throws {
        let args = ToolArguments(["k": .string("v")])

        XCTAssertEqual(try args.string("k"), "v")
    }

    func test_string_throwsMissingWhenAbsent() {
        let args = ToolArguments([:])

        XCTAssertThrowsError(try args.string("k")) { error in
            XCTAssertEqual(error as? ToolArgumentsError, .missing(key: "k"))
        }
    }

    func test_string_throwsTypeMismatchWhenWrongType() {
        let args = ToolArguments(["k": .int(1)])

        XCTAssertThrowsError(try args.string("k")) { error in
            XCTAssertEqual(error as? ToolArgumentsError, .typeMismatch(key: "k", expected: "string"))
        }
    }

    func test_int_returnsValueAndAcceptsIntegralDouble() throws {
        let args = ToolArguments(["a": .int(3), "b": .double(4.0)])

        XCTAssertEqual(try args.int("a"), 3)
        XCTAssertEqual(try args.int("b"), 4)
    }

    func test_int_throwsTypeMismatchOnNonIntegral() {
        let args = ToolArguments(["k": .double(1.5)])

        XCTAssertThrowsError(try args.int("k"))
    }

    func test_double_acceptsIntAndDouble() throws {
        let args = ToolArguments(["a": .double(1.5), "b": .int(2)])

        XCTAssertEqual(try args.double("a"), 1.5)
        XCTAssertEqual(try args.double("b"), 2.0)
    }

    func test_bool_returnsValue() throws {
        let args = ToolArguments(["k": .bool(true)])

        XCTAssertTrue(try args.bool("k"))
    }

    func test_date_parsesISO8601String() throws {
        let args = ToolArguments(["t": .string("2026-04-13T14:32:00Z")])

        let date = try args.date("t")

        XCTAssertEqual(
            date.timeIntervalSince1970,
            ISO8601DateFormatter().date(from: "2026-04-13T14:32:00Z")?.timeIntervalSince1970
        )
    }

    func test_date_parsesNaiveISO8601AsLocalTime() throws {
        let args = ToolArguments(["t": .string("2026-04-13T08:00:00")])

        let date = try args.date("t")

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let components = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 4)
        XCTAssertEqual(components.day, 13)
        XCTAssertEqual(components.hour, 8)
        XCTAssertEqual(components.minute, 0)
        XCTAssertEqual(components.second, 0)
    }

    func test_optionalDate_parsesNaiveISO8601AsLocalTime() throws {
        let args = ToolArguments(["t": .string("2026-04-13T08:00:00")])

        let date = try XCTUnwrap(args.optionalDate("t"))

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        XCTAssertEqual(cal.component(.hour, from: date), 8)
    }

    func test_date_parsesPlainDateAsLocalMidnight() throws {
        let args = ToolArguments(["t": .string("2026-04-13")])

        let date = try args.date("t")

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let components = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 4)
        XCTAssertEqual(components.day, 13)
        XCTAssertEqual(components.hour, 0)
        XCTAssertEqual(components.minute, 0)
    }

    func test_parseISO8601_resolvesJavaScriptNowExpression() {
        // Gemma sometimes emits JS syntax for "current time". We should get a Date
        // close to now rather than nil/failure.
        let before = Date()
        let result = ToolArguments.parseISO8601("new Date().toISOString()")
        let after = Date()

        XCTAssertNotNil(result)
        if let d = result {
            XCTAssertTrue(d >= before && d <= after)
        }
    }

    func test_parseISO8601_resolvesNowKeyword() {
        let before = Date()
        let result = ToolArguments.parseISO8601("now")
        let after = Date()

        XCTAssertNotNil(result)
        if let d = result { XCTAssertTrue(d >= before && d <= after) }
    }

    func test_optionalString_returnsNilWhenMissing() throws {
        let args = ToolArguments([:])

        XCTAssertNil(try args.optionalString("k"))
    }

    func test_optionalString_returnsNilWhenExplicitNull() throws {
        let args = ToolArguments(["k": .null])

        XCTAssertNil(try args.optionalString("k"))
    }
}

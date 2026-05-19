import XCTest
@testable import BabyLogCore
import Foundation

final class JSONValueTests: XCTestCase {

    func test_jsonValue_roundTripsScalars() throws {
        let values: [JSONValue] = [
            .string("hi"),
            .int(42),
            .double(3.14),
            .bool(true),
            .null,
        ]

        for value in values {
            let encoded = try JSONEncoder().encode(value)
            let decoded = try JSONDecoder().decode(JSONValue.self, from: encoded)

            XCTAssertEqual(decoded, value)
        }
    }

    func test_jsonValue_roundTripsArrayAndObject() throws {
        let value: JSONValue = .object([
            "name": .string("ethan"),
            "ages": .array([.int(0), .int(1)]),
            "asleep": .bool(false),
        ])

        let encoded = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: encoded)

        XCTAssertEqual(decoded, value)
    }

    func test_jsonValue_decodesFromRawJSON() throws {
        let raw = Data(#"{"k":"v","n":2}"#.utf8)

        let decoded = try JSONDecoder().decode(JSONValue.self, from: raw)

        XCTAssertEqual(decoded, .object(["k": .string("v"), "n": .int(2)]))
    }
}

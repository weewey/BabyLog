import XCTest
@testable import BabyLogCore
import Foundation

final class ToolInputSchemaTests: XCTestCase {

    private func encode(_ schema: ToolInputSchema) throws -> [String: Any] {
        let data = try JSONEncoder().encode(schema)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dict = object as? [String: Any] else {
            XCTFail("Schema did not encode to an object")
            return [:]
        }
        return dict
    }

    func test_schema_encodesObjectShape() throws {
        let schema = ToolInputSchema(
            properties: [
                ("volumeMl", .init(type: .integer, description: "ml")),
            ],
            required: ["volumeMl"]
        )

        let dict = try encode(schema)

        XCTAssertEqual(dict["type"] as? String, "object")
        XCTAssertEqual(dict["required"] as? [String], ["volumeMl"])
        let props = dict["properties"] as? [String: Any]
        let volume = props?["volumeMl"] as? [String: Any]
        XCTAssertEqual(volume?["type"] as? String, "integer")
        XCTAssertEqual(volume?["description"] as? String, "ml")
    }

    func test_schema_encodesOptionalNumberWithoutEnum() throws {
        let schema = ToolInputSchema(
            properties: [
                ("heightCm", .init(type: .number)),
            ],
            required: []
        )

        let dict = try encode(schema)

        let props = dict["properties"] as? [String: Any]
        let height = props?["heightCm"] as? [String: Any]
        XCTAssertEqual(height?["type"] as? String, "number")
        XCTAssertNil(height?["enum"])
        XCTAssertEqual(dict["required"] as? [String], [])
    }

    func test_schema_encodesEnumOfStrings() throws {
        let schema = ToolInputSchema(
            properties: [
                ("source", .init(type: .string, enumValues: ["bottle", "breast"])),
            ],
            required: ["source"]
        )

        let dict = try encode(schema)

        let props = dict["properties"] as? [String: Any]
        let source = props?["source"] as? [String: Any]
        XCTAssertEqual(source?["type"] as? String, "string")
        XCTAssertEqual(source?["enum"] as? [String], ["bottle", "breast"])
    }
}

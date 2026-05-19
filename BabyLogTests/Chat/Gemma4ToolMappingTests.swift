import XCTest
import LittleECore
import MLXLMCommon
@testable import BabyLog

/// Golden tests for the `ChatTool ↔ MLXLMCommon.ToolSpec` projection and
/// the inbound MLX `JSONValue` → `LittleECore.JSONValue` coercion. These
/// are the two pieces Gemma 4 tool calls flow through, so they need
/// exact-shape coverage — the upstream `GemmaFunctionParser` is sensitive
/// to the nested `function.parameters` schema shape.
final class Gemma4ToolMappingTests: XCTestCase {

    // MARK: - Outbound: ChatTool -> ToolSpec

    func test_toolSpec_topLevelShape_isFunctionWrapped() {
        let spec = Gemma4ToolMapping.toolSpec(for: FakeFeedTool())
        XCTAssertEqual(spec["type"] as? String, "function")
        let function = spec["function"] as? [String: any Sendable]
        XCTAssertNotNil(function)
        XCTAssertEqual(function?["name"] as? String, "createFeedLog")
        XCTAssertEqual(function?["description"] as? String, "Create a feed log entry.")
    }

    func test_toolSpec_parametersAreJSONSchemaObject() {
        let spec = Gemma4ToolMapping.toolSpec(for: FakeFeedTool())
        let function = spec["function"] as? [String: any Sendable]
        let params = function?["parameters"] as? [String: any Sendable]
        XCTAssertEqual(params?["type"] as? String, "object")
        XCTAssertEqual(params?["required"] as? [String], ["volumeMl"])
        let props = params?["properties"] as? [String: any Sendable]
        XCTAssertNotNil(props)
        XCTAssertEqual(props?.count, 2)
    }

    func test_toolSpec_stringProperty_withEnum_serializesEnumValues() {
        let spec = Gemma4ToolMapping.toolSpec(for: FakeDiaperTool())
        let function = spec["function"] as? [String: any Sendable]
        let params = function?["parameters"] as? [String: any Sendable]
        let props = params?["properties"] as? [String: any Sendable]
        let typeProp = props?["type"] as? [String: any Sendable]
        XCTAssertEqual(typeProp?["type"] as? String, "string")
        XCTAssertEqual(typeProp?["enum"] as? [String], ["wet", "dirty", "both"])
    }

    func test_toolSpec_nonStringProperty_omitsEnumEvenIfProvided() {
        let spec = Gemma4ToolMapping.toolSpec(for: FakeFeedTool())
        let function = spec["function"] as? [String: any Sendable]
        let params = function?["parameters"] as? [String: any Sendable]
        let props = params?["properties"] as? [String: any Sendable]
        let volume = props?["volumeMl"] as? [String: any Sendable]
        XCTAssertEqual(volume?["type"] as? String, "integer")
        XCTAssertNil(volume?["enum"])
    }

    func test_toolSpec_propertyWithoutDescription_omitsDescriptionKey() {
        let spec = Gemma4ToolMapping.toolSpec(for: FakeNoDescTool())
        let function = spec["function"] as? [String: any Sendable]
        let params = function?["parameters"] as? [String: any Sendable]
        let props = params?["properties"] as? [String: any Sendable]
        let bare = props?["bare"] as? [String: any Sendable]
        XCTAssertEqual(bare?["type"] as? String, "boolean")
        XCTAssertNil(bare?["description"])
    }

    // MARK: - Inbound: MLX JSONValue -> ToolArguments

    func test_toolArguments_coercesScalarTypes() {
        let mlx: [String: MLXLMCommon.JSONValue] = [
            "volumeMl": .int(60),
            "ml": .double(60.5),
            "label": .string("hi"),
            "done": .bool(true),
            "none": .null,
        ]
        let args = Gemma4ToolMapping.toolArguments(from: mlx)
        XCTAssertEqual(args.values["volumeMl"], .int(60))
        XCTAssertEqual(args.values["ml"], .double(60.5))
        XCTAssertEqual(args.values["label"], .string("hi"))
        XCTAssertEqual(args.values["done"], .bool(true))
        XCTAssertEqual(args.values["none"], .null)
    }

    func test_toolArguments_coercesNestedArray() {
        let mlx: [String: MLXLMCommon.JSONValue] = [
            "tags": .array([.string("a"), .string("b"), .int(3)])
        ]
        let args = Gemma4ToolMapping.toolArguments(from: mlx)
        XCTAssertEqual(
            args.values["tags"],
            .array([.string("a"), .string("b"), .int(3)])
        )
    }

    func test_toolArguments_coercesNestedObject() {
        let mlx: [String: MLXLMCommon.JSONValue] = [
            "payload": .object([
                "id": .string("abc"),
                "count": .int(7),
            ])
        ]
        let args = Gemma4ToolMapping.toolArguments(from: mlx)
        XCTAssertEqual(
            args.values["payload"],
            .object(["id": .string("abc"), "count": .int(7)])
        )
    }

    func test_toolArguments_deeplyNested_roundTripsStructure() {
        let mlx: [String: MLXLMCommon.JSONValue] = [
            "root": .object([
                "list": .array([
                    .object(["k": .bool(true)]),
                    .object(["k": .bool(false)]),
                ])
            ])
        ]
        let args = Gemma4ToolMapping.toolArguments(from: mlx)
        let expected: LittleECore.JSONValue = .object([
            "list": .array([
                .object(["k": .bool(true)]),
                .object(["k": .bool(false)]),
            ])
        ])
        XCTAssertEqual(args.values["root"], expected)
    }

    func test_toolArguments_emptyInput_returnsEmptyArguments() {
        let args = Gemma4ToolMapping.toolArguments(from: [:])
        XCTAssertTrue(args.values.isEmpty)
    }
}

// MARK: - Fake tools (minimal, zero-dep)

private struct FakeFeedTool: ChatTool {
    let name = "createFeedLog"
    let description = "Create a feed log entry."
    let requiresConfirmation = false
    var inputSchema: ToolInputSchema {
        ToolInputSchema(
            properties: [
                ("volumeMl", .init(
                    type: .integer,
                    description: "Volume in millilitres.",
                    enumValues: ["ignored"]  // non-string, should NOT surface
                )),
                ("note", .init(type: .string, description: "Optional note.")),
            ],
            required: ["volumeMl"]
        )
    }
    func execute(arguments: ToolArguments) async throws -> ToolResult {
        ToolResult(content: "ok", isError: false)
    }
}

private struct FakeDiaperTool: ChatTool {
    let name = "createDiaperLog"
    let description = "Log a diaper change."
    let requiresConfirmation = false
    var inputSchema: ToolInputSchema {
        ToolInputSchema(
            properties: [
                ("type", .init(
                    type: .string,
                    description: "Contents.",
                    enumValues: ["wet", "dirty", "both"]
                )),
            ],
            required: ["type"]
        )
    }
    func execute(arguments: ToolArguments) async throws -> ToolResult {
        ToolResult(content: "ok", isError: false)
    }
}

private struct FakeNoDescTool: ChatTool {
    let name = "flag"
    let description = "Set a flag."
    let requiresConfirmation = false
    var inputSchema: ToolInputSchema {
        ToolInputSchema(
            properties: [("bare", .init(type: .boolean))],
            required: []
        )
    }
    func execute(arguments: ToolArguments) async throws -> ToolResult {
        ToolResult(content: "ok", isError: false)
    }
}

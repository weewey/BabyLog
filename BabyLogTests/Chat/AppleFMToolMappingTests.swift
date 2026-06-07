import XCTest
import BabyLogCore
@testable import BabyLog
#if canImport(FoundationModels)
import FoundationModels

/// Exercises the Apple FM tool bridge against the real `FoundationModels`
/// runtime (available in the iOS 26 simulator). Only the mapping + adapter
/// execution is tested here — no model inference is involved.
@available(iOS 26.0, macOS 26.0, *)
final class AppleFMToolMappingTests: XCTestCase {

    private final class SpyTool: ChatTool, @unchecked Sendable {
        let name = "createFeedLog"
        let description = "Create a feed log"
        let inputSchema = ToolInputSchema(
            properties: [
                ("volumeMl", ToolInputSchema.Property(type: .integer, description: "ml")),
                ("note", ToolInputSchema.Property(type: .string, description: "note")),
                ("source", ToolInputSchema.Property(type: .string, description: "src", enumValues: ["bottle", "breast"])),
            ],
            required: ["volumeMl"]
        )
        let requiresConfirmation = false
        private(set) var received: ToolArguments?
        func execute(arguments: ToolArguments) async throws -> ToolResult {
            received = arguments
            return ToolResult(content: "logged id=42")
        }
    }

    private final class EventBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [AppleFMEvent] = []
        var events: [AppleFMEvent] { lock.lock(); defer { lock.unlock() }; return _events }
        func append(_ event: AppleFMEvent) { lock.lock(); _events.append(event); lock.unlock() }
    }

    func test_generationSchema_buildsForMixedPropertyTypes() throws {
        XCTAssertNoThrow(try AppleFMToolMapping.generationSchema(for: SpyTool()))
    }

    func test_toolArguments_decodesGeneratedContentJSON() throws {
        let content = try GeneratedContent(json: #"{"volumeMl": 120, "note": "morning"}"#)

        let args = try AppleFMToolMapping.toolArguments(from: content)

        XCTAssertEqual(try args.int("volumeMl"), 120)
        XCTAssertEqual(try args.string("note"), "morning")
    }

    func test_adapter_call_executesToolAndEmitsCallThenResult() async throws {
        let spy = SpyTool()
        let box = EventBox()
        let adapter = try AppleFMToolAdapter(chatTool: spy, emit: { box.append($0) })

        let output = try await adapter.call(
            arguments: GeneratedContent(json: #"{"volumeMl": 90}"#)
        )

        XCTAssertEqual(output, "logged id=42")
        XCTAssertEqual(try spy.received?.int("volumeMl"), 90)

        let events = box.events
        XCTAssertEqual(events.count, 2)
        guard case let .toolCall(_, name, _) = events.first else {
            return XCTFail("expected first event to be .toolCall")
        }
        XCTAssertEqual(name, "createFeedLog")
        guard case let .toolResult(_, result) = events.last else {
            return XCTFail("expected last event to be .toolResult")
        }
        XCTAssertEqual(result.content, "logged id=42")
    }
}
#endif

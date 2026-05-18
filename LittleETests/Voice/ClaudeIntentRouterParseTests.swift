import XCTest
import LittleECore
@testable import LittleE

/// Pure parse tests for `ClaudeAssistant.parse(_:)`. No network.
final class ClaudeAssistantParseTests: XCTestCase {

    func test_parse_feedToolUse_returnsFeedDraft() throws {
        let json = """
        {
          "content": [
            {
              "type": "tool_use",
              "name": "log_feed",
              "input": { "volume_ml": 120, "source": "bottle" }
            }
          ]
        }
        """.data(using: .utf8)!

        let response = try ClaudeAssistant.parse(json)

        XCTAssertEqual(response, .toolUse(.feed(FeedDraft(volumeMl: 120, source: .bottle))))
    }

    func test_parse_diaperToolUse_returnsDiaperDraft() throws {
        let json = """
        { "content": [ { "type": "tool_use", "name": "log_diaper", "input": { "type": "wet" } } ] }
        """.data(using: .utf8)!

        let response = try ClaudeAssistant.parse(json)

        XCTAssertEqual(response, .toolUse(.diaper(DiaperDraft(type: .wet))))
    }

    func test_parse_unknownToolUse_returnsUnknownWithReason() throws {
        let json = """
        { "content": [ { "type": "tool_use", "name": "unknown", "input": { "reason": "no clue" } } ] }
        """.data(using: .utf8)!

        let response = try ClaudeAssistant.parse(json)

        XCTAssertEqual(response, .toolUse(.unknown(reason: "no clue")))
    }

    func test_parse_textOnlyResponse_returnsAnswerWithNoToolUses() throws {
        let json = """
        { "content": [ { "type": "text", "text": "hi there" } ] }
        """.data(using: .utf8)!

        let response = try ClaudeAssistant.parse(json)

        XCTAssertEqual(response.answer, "hi there")
        XCTAssertTrue(response.toolUses.isEmpty)
    }

    func test_parse_textAndToolUse_returnsBoth() throws {
        let json = """
        { "content": [
            { "type": "text", "text": "logged it" },
            { "type": "tool_use", "name": "log_feed", "input": { "volume_ml": 60, "source": "bottle" } }
        ] }
        """.data(using: .utf8)!

        let response = try ClaudeAssistant.parse(json)

        XCTAssertEqual(response.answer, "logged it")
        XCTAssertEqual(response.toolUses, [.feed(FeedDraft(volumeMl: 60, source: .bottle))])
    }

    func test_parse_emptyContent_throwsInvalidResponse() {
        let json = #"{ "content": [] }"#.data(using: .utf8)!

        XCTAssertThrowsError(try ClaudeAssistant.parse(json)) { error in
            XCTAssertEqual(error as? AssistantError, .invalidResponse)
        }
    }

    func test_requestBody_marksSystemPromptForCaching() {
        let body = ClaudeAssistant.requestBody(transcript: "fed 60ml")

        let system = body["system"] as? [[String: Any]]
        let firstBlock = system?.first
        let cacheControl = firstBlock?["cache_control"] as? [String: String]
        XCTAssertEqual(cacheControl?["type"], "ephemeral")
    }

    func test_requestBody_marksLastToolForCaching() {
        let body = ClaudeAssistant.requestBody(transcript: "fed 60ml")

        let tools = body["tools"] as? [[String: Any]]
        let lastTool = tools?.last
        let cacheControl = lastTool?["cache_control"] as? [String: String]
        XCTAssertEqual(cacheControl?["type"], "ephemeral")
    }

    func test_requestBody_omitsToolChoice_lettingModelDecide() {
        let body = ClaudeAssistant.requestBody(transcript: "fed 60ml")

        XCTAssertNil(body["tool_choice"])
    }

func test_requestBody_pinsHaiku45Model() {
        let body = ClaudeAssistant.requestBody(transcript: "fed 60ml")

        XCTAssertEqual(body["model"] as? String, "claude-haiku-4-5-20251001")
    }
}

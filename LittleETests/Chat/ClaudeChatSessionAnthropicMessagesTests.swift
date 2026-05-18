import XCTest
import LittleECore
@testable import LittleE

/// Tests for `ClaudeChatSession.anthropicMessages(from:)` — the projection
/// that re-bundles `ChatViewModel`'s interleaved tool-call messages into
/// the shape Anthropic's Messages API requires (one assistant turn with
/// every tool_use block, one user turn with every matching tool_result).
/// Regression guard for the HTTP 400 "unexpected tool_use_id" bundler bug.
final class ClaudeChatSessionAnthropicMessagesTests: XCTestCase {

    // MARK: - Single-call baseline

    func test_singleToolCall_bundlesIntoOneAssistantOneUserTurn() {
        let history: [ChatMessage] = [
            .init(role: .user, text: "log 60ml"),
            .init(role: .assistant, text: ""),
            toolCall(id: "a", name: "createFeedLog"),
            toolResult(id: "a", name: "createFeedLog", content: "id=1"),
        ]
        let out = ClaudeChatSession.anthropicMessages(from: history)

        XCTAssertEqual(out.count, 3)  // user, assistant(tool_use), user(tool_result)
        XCTAssertEqual(out[0]["role"] as? String, "user")
        XCTAssertEqual(out[1]["role"] as? String, "assistant")
        XCTAssertEqual(out[2]["role"] as? String, "user")

        let assistantBlocks = out[1]["content"] as? [[String: Any]]
        XCTAssertEqual(assistantBlocks?.count, 1)
        XCTAssertEqual(assistantBlocks?.first?["type"] as? String, "tool_use")
        XCTAssertEqual(assistantBlocks?.first?["id"] as? String, "a")

        let resultBlocks = out[2]["content"] as? [[String: Any]]
        XCTAssertEqual(resultBlocks?.count, 1)
        XCTAssertEqual(resultBlocks?.first?["tool_use_id"] as? String, "a")
    }

    // MARK: - Parallel calls (the regression bug)

    func test_parallelToolCalls_bundleAllUseBlocksIntoOneAssistantTurn() {
        // ChatViewModel writes interleaved call/result pairs; the bundler
        // must regroup them.
        let history: [ChatMessage] = [
            .init(role: .user, text: "log everything"),
            .init(role: .assistant, text: ""),
            toolCall(id: "a", name: "createFeedLog"),
            toolResult(id: "a", name: "createFeedLog", content: "ok"),
            toolCall(id: "b", name: "createDiaperLog"),
            toolResult(id: "b", name: "createDiaperLog", content: "ok"),
            toolCall(id: "c", name: "createPumpingSession"),
            toolResult(id: "c", name: "createPumpingSession", content: "ok"),
        ]
        let out = ClaudeChatSession.anthropicMessages(from: history)

        XCTAssertEqual(out.count, 3)
        let asstBlocks = out[1]["content"] as? [[String: Any]]
        XCTAssertEqual(asstBlocks?.count, 3)
        XCTAssertEqual(asstBlocks?.map { $0["id"] as? String }, ["a", "b", "c"])
        XCTAssertTrue(asstBlocks?.allSatisfy { ($0["type"] as? String) == "tool_use" } ?? false)

        let resultBlocks = out[2]["content"] as? [[String: Any]]
        XCTAssertEqual(resultBlocks?.count, 3)
        XCTAssertEqual(
            resultBlocks?.map { $0["tool_use_id"] as? String },
            ["a", "b", "c"]
        )
    }

    func test_parallelToolCalls_assistantTextPrefix_isPreserved() {
        let history: [ChatMessage] = [
            .init(role: .user, text: "do it"),
            .init(role: .assistant, text: "On it."),
            toolCall(id: "a", name: "createFeedLog"),
            toolResult(id: "a", name: "createFeedLog", content: "ok"),
            toolCall(id: "b", name: "createDiaperLog"),
            toolResult(id: "b", name: "createDiaperLog", content: "ok"),
        ]
        let out = ClaudeChatSession.anthropicMessages(from: history)
        let asstBlocks = out[1]["content"] as? [[String: Any]]
        XCTAssertEqual(asstBlocks?.count, 3)  // text + 2 tool_use
        XCTAssertEqual(asstBlocks?.first?["type"] as? String, "text")
        XCTAssertEqual(asstBlocks?.first?["text"] as? String, "On it.")
    }

    // MARK: - Edge cases

    func test_emptyTrailingAssistantBubble_isStripped() {
        let history: [ChatMessage] = [
            .init(role: .user, text: "hi"),
            .init(role: .assistant, text: ""),  // streaming shell, must drop
        ]
        let out = ClaudeChatSession.anthropicMessages(from: history)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0]["role"] as? String, "user")
    }

    func test_systemMessages_areStripped() {
        let history: [ChatMessage] = [
            .init(role: .system, text: "you are helpful"),
            .init(role: .user, text: "hi"),
        ]
        let out = ClaudeChatSession.anthropicMessages(from: history)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0]["role"] as? String, "user")
    }

    func test_textOnlyAssistantTurn_serializesAsString() {
        let history: [ChatMessage] = [
            .init(role: .user, text: "hi"),
            .init(role: .assistant, text: "hello"),
        ]
        let out = ClaudeChatSession.anthropicMessages(from: history)
        XCTAssertEqual(out.count, 2)
        // Plain text turns use the string-content form.
        XCTAssertEqual(out[1]["content"] as? String, "hello")
    }

    func test_orphanToolMessages_synthesizeAssistantTurn() {
        // Tool-loop iteration 2+: ChatViewModel drops the empty assistant
        // shell, leaving the call/result pair without an assistant anchor.
        let history: [ChatMessage] = [
            .init(role: .user, text: "log it"),
            toolCall(id: "x", name: "createFeedLog"),
            toolResult(id: "x", name: "createFeedLog", content: "ok"),
        ]
        let out = ClaudeChatSession.anthropicMessages(from: history)
        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(out[1]["role"] as? String, "assistant")
        let asstBlocks = out[1]["content"] as? [[String: Any]]
        XCTAssertEqual(asstBlocks?.first?["type"] as? String, "tool_use")
    }

    // MARK: - Extended thinking round-trip

    func test_reasoningBlock_prependedToAssistantTurn_whenToolUseFollows() {
        let assistant = ChatMessage(
            role: .assistant,
            text: "",
            reasoning: ChatMessage.Reasoning(
                text: "The user wants a feed log. I'll use createFeedLog.",
                signature: "abc123signature"
            )
        )
        let history: [ChatMessage] = [
            .init(role: .user, text: "log 60ml"),
            assistant,
            toolCall(id: "a", name: "createFeedLog"),
            toolResult(id: "a", name: "createFeedLog", content: "ok"),
        ]
        let out = ClaudeChatSession.anthropicMessages(from: history)

        XCTAssertEqual(out.count, 3)
        let asst = out[1]["content"] as? [[String: Any]]
        XCTAssertEqual(asst?.count, 2)  // thinking + tool_use
        XCTAssertEqual(asst?.first?["type"] as? String, "thinking")
        XCTAssertEqual(
            asst?.first?["thinking"] as? String,
            "The user wants a feed log. I'll use createFeedLog."
        )
        XCTAssertEqual(asst?.first?["signature"] as? String, "abc123signature")
        XCTAssertEqual(asst?.last?["type"] as? String, "tool_use")
    }

    func test_reasoningBlock_withoutSignature_isDropped() {
        // A thinking block without a signature is useless for round-trip
        // — Anthropic rejects it. Serializer must drop it silently.
        let assistant = ChatMessage(
            role: .assistant,
            text: "Here.",
            reasoning: ChatMessage.Reasoning(text: "hmm", signature: "")
        )
        let history: [ChatMessage] = [
            .init(role: .user, text: "hi"),
            assistant,
        ]
        let out = ClaudeChatSession.anthropicMessages(from: history)

        XCTAssertEqual(out.count, 2)
        // Text-only assistant turn collapses to a plain string.
        XCTAssertEqual(out[1]["content"] as? String, "Here.")
    }

    func test_emptyShell_withReasoning_isKept_forSignatureRoundTrip() {
        // The streaming assistant shell is normally stripped when empty.
        // With a reasoning block it must survive so its signature can be
        // echoed back on the tool_result turn.
        let shell = ChatMessage(
            role: .assistant,
            text: "",
            reasoning: ChatMessage.Reasoning(text: "plan", signature: "sig")
        )
        let history: [ChatMessage] = [
            .init(role: .user, text: "hi"),
            shell,
        ]
        let out = ClaudeChatSession.anthropicMessages(from: history)
        XCTAssertEqual(out.count, 2)
        let asst = out[1]["content"] as? [[String: Any]]
        XCTAssertEqual(asst?.first?["type"] as? String, "thinking")
    }

    // MARK: - Helpers

    private func toolCall(id: String, name: String) -> ChatMessage {
        ChatMessage(
            role: .tool,
            text: "",
            toolEntry: .call(id: id, name: name, arguments: ToolArguments([:]))
        )
    }

    private func toolResult(
        id: String,
        name: String,
        content: String
    ) -> ChatMessage {
        ChatMessage(
            role: .tool,
            text: "",
            toolEntry: .result(
                id: id,
                name: name,
                result: ToolResult(content: content, isError: false)
            )
        )
    }
}

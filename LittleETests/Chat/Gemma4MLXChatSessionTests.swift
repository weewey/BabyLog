import XCTest
import LittleECore
@testable import LittleE

/// Pure-logic tests for the Gemma 4 backend. Covers the two bug-prone
/// pieces that don't need a `ModelContainer`: the streaming tool-call
/// parser (base Gemma 3/4 `tool_code` markdown-block format) and the
/// `splitHistory` projection into MLX chat shape.
final class Gemma4MLXChatSessionTests: XCTestCase {

    // MARK: - GemmaToolCallStreamParser (tool_code markdown format)

    func test_parser_emitsPlainProseUntouched() {
        var parser = GemmaToolCallStreamParser()
        let deltas = parser.consume("Logged — nice one.")
        let flushed = parser.flush()
        XCTAssertEqual(tokens(deltas + flushed).joined(), "Logged — nice one.")
    }

    func test_parser_parsesSingleCall_withIntArgument() {
        var parser = GemmaToolCallStreamParser()
        let deltas = parser.consume(
            "```tool_code\ncreateFeedLog(volumeMl=60)\n```"
        )
        let flushed = parser.flush()
        let calls = toolCalls(deltas + flushed)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, "createFeedLog")
        XCTAssertEqual(calls.first?.arguments.values["volumeMl"], .int(60))
    }

    func test_parser_parsesStringArgument_doubleQuoted() {
        var parser = GemmaToolCallStreamParser()
        let body = "```tool_code\ncreateDiaperLog(kind=\"dirty\")\n```"
        let calls = toolCalls(parser.consume(body) + parser.flush())
        XCTAssertEqual(calls.first?.arguments.values["kind"], .string("dirty"))
    }

    func test_parser_parsesStringArgument_withEscapedQuote() {
        var parser = GemmaToolCallStreamParser()
        let body = "```tool_code\ncreateMilestone(title=\"said \\\"mama\\\"\")\n```"
        let calls = toolCalls(parser.consume(body) + parser.flush())
        XCTAssertEqual(
            calls.first?.arguments.values["title"],
            .string("said \"mama\"")
        )
    }

    func test_parser_parsesStringArgument_containingParens() {
        var parser = GemmaToolCallStreamParser()
        let body = "```tool_code\ncreateMilestone(title=\"rolled over (left to right)\")\n```"
        let calls = toolCalls(parser.consume(body) + parser.flush())
        XCTAssertEqual(
            calls.first?.arguments.values["title"],
            .string("rolled over (left to right)")
        )
    }

    func test_parser_parsesMultipleArgs_mixedTypes() {
        var parser = GemmaToolCallStreamParser()
        let body = "```tool_code\ncreateFeedLog(volumeMl=120, loggedAt=\"2026-04-15T10:00:00Z\")\n```"
        let calls = toolCalls(parser.consume(body) + parser.flush())
        XCTAssertEqual(calls.first?.arguments.values["volumeMl"], .int(120))
        XCTAssertEqual(
            calls.first?.arguments.values["loggedAt"],
            .string("2026-04-15T10:00:00Z")
        )
    }

    func test_parser_parsesBoolAndDouble() {
        var parser = GemmaToolCallStreamParser()
        let body = "```tool_code\ncreateGrowthMeasurement(weightKg=8.2, isEstimate=true)\n```"
        let calls = toolCalls(parser.consume(body) + parser.flush())
        XCTAssertEqual(calls.first?.arguments.values["weightKg"], .double(8.2))
        XCTAssertEqual(calls.first?.arguments.values["isEstimate"], .bool(true))
    }

    func test_parser_handlesChunkBoundary_midFence() {
        var parser = GemmaToolCallStreamParser()
        var out: [ChatDelta] = []
        out += parser.consume("Got it. ```too")
        out += parser.consume("l_code\ncreateFeedLog(volumeMl=90)\n```")
        out += parser.flush()
        XCTAssertEqual(tokens(out).joined(), "Got it. ")
        XCTAssertEqual(toolCalls(out).first?.arguments.values["volumeMl"], .int(90))
    }

    func test_parser_handlesChunkBoundary_midCallBody() {
        var parser = GemmaToolCallStreamParser()
        var out: [ChatDelta] = []
        out += parser.consume("```tool_code\ncreateFeedLog(volum")
        out += parser.consume("eMl=120)\n```")
        out += parser.flush()
        XCTAssertEqual(toolCalls(out).first?.arguments.values["volumeMl"], .int(120))
    }

    func test_parser_handlesOneCharAtATime() {
        var parser = GemmaToolCallStreamParser()
        let full = "Hi! ```tool_code\ncreateFeedLog(volumeMl=60)\n``` done."
        var out: [ChatDelta] = []
        for ch in full {
            out += parser.consume(String(ch))
        }
        out += parser.flush()
        XCTAssertEqual(tokens(out).joined(), "Hi!  done.")
        XCTAssertEqual(toolCalls(out).count, 1)
        XCTAssertEqual(toolCalls(out).first?.name, "createFeedLog")
    }

    func test_parser_emitsProseAroundCall() {
        var parser = GemmaToolCallStreamParser()
        let out = parser.consume(
            "Sure. ```tool_code\ncreateFeedLog(volumeMl=60)\n``` done!"
        )
        let flushed = parser.flush()
        XCTAssertEqual(tokens(out + flushed).joined(), "Sure.  done!")
        XCTAssertEqual(toolCalls(out + flushed).count, 1)
    }

    func test_parser_multipleParallelCalls() {
        var parser = GemmaToolCallStreamParser()
        let out = parser.consume(
            "```tool_code\ncreateFeedLog(volumeMl=60)\n```" +
            "```tool_code\ncreateDiaperLog(kind=\"wet\")\n```"
        )
        let calls = toolCalls(out + parser.flush())
        XCTAssertEqual(calls.map(\.name), ["createFeedLog", "createDiaperLog"])
        XCTAssertEqual(calls[1].arguments.values["kind"], .string("wet"))
    }

    // MARK: - Native `<|tool_call>...<tool_call|>` envelope

    func test_parser_nativeEnvelope_parsesSingleCall() {
        var parser = GemmaToolCallStreamParser()
        let out = parser.consume(
            "<|tool_call>call:listRecentFeedLogs{limit:10}<tool_call|>"
        )
        let calls = toolCalls(out + parser.flush())
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, "listRecentFeedLogs")
        XCTAssertEqual(calls.first?.arguments.values["limit"], .int(10))
        XCTAssertEqual(tokens(out + parser.flush()).joined(), "")
    }

    func test_parser_nativeEnvelope_parsesParallelCalls() {
        var parser = GemmaToolCallStreamParser()
        let out = parser.consume(
            "<|tool_call>call:listRecentFeedLogs{limit:10}<tool_call|>" +
            "<|tool_call>call:listRecentDiaperLogs{limit:10}<tool_call|>"
        )
        let calls = toolCalls(out + parser.flush())
        XCTAssertEqual(
            calls.map(\.name),
            ["listRecentFeedLogs", "listRecentDiaperLogs"]
        )
        XCTAssertEqual(calls[0].arguments.values["limit"], .int(10))
        XCTAssertEqual(calls[1].arguments.values["limit"], .int(10))
    }

    func test_parser_nativeEnvelope_parsesStringArg() {
        var parser = GemmaToolCallStreamParser()
        let out = parser.consume(
            "<|tool_call>call:createDiaperLog{kind:\"wet\"}<tool_call|>"
        )
        let calls = toolCalls(out + parser.flush())
        XCTAssertEqual(calls.first?.arguments.values["kind"], .string("wet"))
    }

    func test_parser_nativeEnvelope_handlesChunkBoundary_midOpen() {
        var parser = GemmaToolCallStreamParser()
        var out: [ChatDelta] = []
        out += parser.consume("hello <|tool_")
        out += parser.consume("call>call:createFeedLog{volumeMl:60}<tool_call|>")
        out += parser.flush()
        XCTAssertEqual(tokens(out).joined(), "hello ")
        XCTAssertEqual(toolCalls(out).first?.name, "createFeedLog")
        XCTAssertEqual(toolCalls(out).first?.arguments.values["volumeMl"], .int(60))
    }

    func test_parser_nativeEnvelope_handlesChunkBoundary_midClose() {
        var parser = GemmaToolCallStreamParser()
        var out: [ChatDelta] = []
        out += parser.consume("<|tool_call>call:createFeedLog{volumeMl:60}<tool")
        out += parser.consume("_call|> done")
        out += parser.flush()
        XCTAssertEqual(toolCalls(out).first?.name, "createFeedLog")
        XCTAssertEqual(tokens(out).joined(), " done")
    }

    func test_parser_multipleParallelCalls_separatedByNewline() {
        var parser = GemmaToolCallStreamParser()
        let out = parser.consume(
            "```tool_code\ncreateFeedLog(volumeMl=60)\n```\n" +
            "```tool_code\ncreateDiaperLog(kind=\"wet\")\n```"
        )
        let calls = toolCalls(out + parser.flush())
        XCTAssertEqual(calls.count, 2)
    }

    func test_parser_stripsToolOutputEcho() {
        // Model sometimes echoes a tool_output fence back. We must swallow
        // it rather than re-emit as prose.
        var parser = GemmaToolCallStreamParser()
        let out = parser.consume(
            "```tool_output\nid=abc\n```Logged 60 ml."
        )
        let flushed = parser.flush()
        XCTAssertEqual(tokens(out + flushed).joined(), "Logged 60 ml.")
    }

    func test_parser_flushesIncompleteCallAsProse() {
        var parser = GemmaToolCallStreamParser()
        _ = parser.consume("```tool_code\ncreateFeedLog(volumeMl=60")
        let flushed = parser.flush()
        // Incomplete — surfaced as a raw token so the user sees something.
        XCTAssertFalse(tokens(flushed).isEmpty)
    }

    // MARK: - Thinking block stripping (preserved from pre-rewrite)

    func test_parser_stripsCompleteThinkingBlock_emitsReasoningDelta() {
        var parser = GemmaToolCallStreamParser()
        let out = parser.consume("<think>user wants a 60 ml feed</think>Logged!")
        let flushed = parser.flush()
        let all = out + flushed
        XCTAssertEqual(tokens(all).joined(), "Logged!")
        let reasoning = reasoningDeltas(all)
        XCTAssertEqual(reasoning.count, 1)
        XCTAssertEqual(reasoning.first?.text, "user wants a 60 ml feed")
    }

    func test_parser_thinkingBlock_precedesToolCall() {
        var parser = GemmaToolCallStreamParser()
        let out = parser.consume(
            "<think>need to log a feed</think>" +
            "```tool_code\ncreateFeedLog(volumeMl=60)\n```"
        )
        let flushed = parser.flush()
        XCTAssertEqual(reasoningDeltas(out + flushed).first?.text, "need to log a feed")
        XCTAssertEqual(toolCalls(out + flushed).first?.name, "createFeedLog")
        XCTAssertEqual(tokens(out + flushed).joined(), "")
    }

    func test_parser_thinkingBlock_splitAcrossChunks_neverLeaksProse() {
        var parser = GemmaToolCallStreamParser()
        var out: [ChatDelta] = []
        out += parser.consume("<think>reason")
        XCTAssertEqual(tokens(out).joined(), "")
        out += parser.consume("ing half</think>Done.")
        out += parser.flush()
        XCTAssertEqual(tokens(out).joined(), "Done.")
        XCTAssertEqual(reasoningDeltas(out).first?.text, "reasoning half")
    }

    func test_parser_harmony_analysisChannel_thenFinalChannel() {
        var parser = GemmaToolCallStreamParser()
        let body = "<|channel|>analysis<|message|>User wants a 60ml feed<|end|>" +
            "<|channel|>final<|message|>Logged 60 ml."
        let out = parser.consume(body) + parser.flush()
        XCTAssertEqual(tokens(out).joined(), "Logged 60 ml.")
        XCTAssertEqual(reasoningDeltas(out).first?.text, "User wants a 60ml feed")
    }

    func test_parser_harmony_analysisChannel_beforeToolCall() {
        var parser = GemmaToolCallStreamParser()
        let body = "<|channel|>analysis<|message|>need to log feed<|end|>" +
            "<|channel|>final<|message|>" +
            "```tool_code\ncreateFeedLog(volumeMl=60)\n```"
        let out = parser.consume(body) + parser.flush()
        XCTAssertEqual(reasoningDeltas(out).first?.text, "need to log feed")
        XCTAssertEqual(toolCalls(out).first?.name, "createFeedLog")
        XCTAssertEqual(tokens(out).joined(), "")
    }

    func test_parser_harmony_unclosedAnalysis_flushDrainsAsReasoning() {
        var parser = GemmaToolCallStreamParser()
        var out = parser.consume("<|channel|>analysis<|message|>incomplete thought")
        out += parser.flush()
        XCTAssertEqual(tokens(out).joined(), "")
        let combined = reasoningDeltas(out).map(\.text).joined()
        XCTAssertEqual(combined, "incomplete thought")
    }

    func test_parser_unclosedThinking_flushAsReasoning_notProse() {
        var parser = GemmaToolCallStreamParser()
        _ = parser.consume("<think>incomplete reasoning")
        let flushed = parser.flush()
        XCTAssertEqual(tokens(flushed).joined(), "")
        XCTAssertEqual(reasoningDeltas(flushed).first?.text, "incomplete reasoning")
    }

    // MARK: - splitHistory

    private let today = Date(timeIntervalSince1970: 1_775_000_000) // ~2026-04-07

    func test_splitHistory_userOnly_promotesLastUserToPrompt() {
        let msgs = [
            ChatMessage(role: .user, text: "Log a 60 ml feed")
        ]
        let (history, lastUser) = Gemma4MLXChatSession.splitHistory(msgs, today: today)
        XCTAssertEqual(lastUser, "Log a 60 ml feed")
        // History is [system] only — no prior user turn.
        XCTAssertEqual(history.count, 1)
    }

    func test_splitHistory_priorTurns_goIntoHistory() {
        let msgs = [
            ChatMessage(role: .user, text: "hi"),
            ChatMessage(role: .assistant, text: "hello"),
            ChatMessage(role: .user, text: "log 60")
        ]
        let (history, lastUser) = Gemma4MLXChatSession.splitHistory(msgs, today: today)
        XCTAssertEqual(lastUser, "log 60")
        // system + user("hi") + assistant("hello")
        XCTAssertEqual(history.count, 3)
    }

    func test_splitHistory_toolResultTail_becomesToolOutputFencePrompt() {
        let call = ChatMessage(
            role: .tool,
            text: "",
            toolEntry: .call(
                id: "t1",
                name: "createFeedLog",
                arguments: ToolArguments(["volumeMl": .int(60)])
            )
        )
        let result = ChatMessage(
            role: .tool,
            text: "",
            toolEntry: .result(
                id: "t1",
                name: "createFeedLog",
                result: ToolResult(content: "id=abc", isError: false)
            )
        )
        let msgs = [
            ChatMessage(role: .user, text: "log 60"),
            call,
            result
        ]
        let (_, lastUser) = Gemma4MLXChatSession.splitHistory(msgs, today: today)
        XCTAssertEqual(
            lastUser,
            "```tool_output\nid=abc\n```"
        )
    }

    func test_splitHistory_emptyMessages_returnsEmpty() {
        let (history, lastUser) = Gemma4MLXChatSession.splitHistory([], today: today)
        XCTAssertTrue(history.isEmpty)
        XCTAssertNil(lastUser)
    }

    // MARK: - System prompt

    func test_gemmaSystemPrompt_containsToolCodeInstructions() {
        let prompt = Gemma4MLXChatSession.gemmaSystemPrompt(today: today, tools: [])
        XCTAssertTrue(prompt.contains("tool_code"))
        XCTAssertTrue(prompt.contains("Ethan"))
    }

    func test_gemmaSystemPrompt_rendersToolList() {
        let tool = StubChatTool(
            name: "createFeedLog",
            description: "Log a feed.",
            schema: ToolInputSchema(
                properties: [
                    ("volumeMl", .init(type: .integer, description: "volume in ml")),
                    ("loggedAt", .init(type: .string, description: "ISO8601"))
                ],
                required: ["volumeMl"]
            )
        )
        let prompt = Gemma4MLXChatSession.gemmaSystemPrompt(today: today, tools: [tool])
        XCTAssertTrue(prompt.contains("createFeedLog"))
        XCTAssertTrue(prompt.contains("volumeMl"))
        XCTAssertTrue(prompt.contains("loggedAt"))
    }

    func test_gemmaSystemPrompt_dropsLegacyToolCallTagSyntax() {
        let prompt = Gemma4MLXChatSession.gemmaSystemPrompt(today: today, tools: [])
        XCTAssertFalse(prompt.contains("<|tool_call>"))
        XCTAssertFalse(prompt.contains("<tool_call|>"))
    }

    // MARK: - Helpers

    private func tokens(_ deltas: [ChatDelta]) -> [String] {
        deltas.compactMap {
            if case .token(let s) = $0 { return s } else { return nil }
        }
    }

    private func reasoningDeltas(
        _ deltas: [ChatDelta]
    ) -> [(text: String, signature: String)] {
        deltas.compactMap {
            if case .reasoning(let text, let sig) = $0 {
                return (text, sig)
            }
            return nil
        }
    }

    private func toolCalls(
        _ deltas: [ChatDelta]
    ) -> [(name: String, arguments: ToolArguments)] {
        deltas.compactMap {
            if case .toolCall(_, let name, let args) = $0 {
                return (name, args)
            }
            return nil
        }
    }
}

// MARK: - Stub ChatTool for system-prompt rendering tests

private struct StubChatTool: ChatTool {
    let name: String
    let description: String
    let schema: ToolInputSchema
    var inputSchema: ToolInputSchema { schema }
    var requiresConfirmation: Bool { false }
    func execute(arguments: ToolArguments) async throws -> ToolResult {
        ToolResult(content: "", isError: false)
    }
}

import XCTest
@testable import LittleE
@testable import LittleECore

/// Pure-Swift coverage for `QwenLlamaCppChatSession`'s history/template
/// projection and the simulator guard. These are the knobs the agent
/// will most often touch — the llama.cpp C call path itself is only
/// exercised end-to-end on a real device via TestFlight.
final class QwenLlamaCppChatSessionTests: XCTestCase {

    // MARK: - Simulator gate

    func test_init_onSimulator_throwsUnsupportedDevice() {
        // The session is gated to device-only because `llama.cpp`'s Metal
        // residency-set init hangs on the iOS 26 simulator. Any attempt to
        // construct on sim must surface a typed error rather than
        // proceeding into the llama path and crashing.
        XCTAssertThrowsError(try QwenLlamaCppChatSession()) { error in
            XCTAssertEqual(
                error as? QwenLlamaCppChatSessionError,
                .unsupportedDevice
            )
        }
    }

    // MARK: - History projection

    func test_splitHistory_withNoTools_producesBareSystemPromptAndTurns() throws {
        let messages: [ChatMessage] = [
            ChatMessage(role: .user, text: "Hi"),
            ChatMessage(role: .assistant, text: "Hello!")
        ]

        let projected = QwenLlamaCppChatSession.splitHistory(messages: messages, tools: nil)

        XCTAssertFalse(projected.system.isEmpty)
        XCTAssertFalse(projected.system.contains("Available tools"))
        XCTAssertEqual(projected.turns.count, 2)
        XCTAssertEqual(projected.turns[0].role, .user)
        XCTAssertEqual(projected.turns[0].text, "Hi")
        XCTAssertEqual(projected.turns[1].role, .assistant)
        XCTAssertEqual(projected.turns[1].text, "Hello!")
    }

    func test_splitHistory_withTools_listsEachToolInSystemPrompt() throws {
        let feedRepo = InMemoryFeedLogRepository()
        let registry = ToolRegistry([
            CreateFeedLogTool(repository: feedRepo, clock: SystemClock(), reminder: nil),
            ListRecentFeedLogsTool(repository: feedRepo),
        ])

        let projected = QwenLlamaCppChatSession.splitHistory(
            messages: [ChatMessage(role: .user, text: "log a feed")],
            tools: registry
        )

        XCTAssertTrue(projected.system.contains("Available tools:"))
        XCTAssertTrue(projected.system.contains("- createFeedLog:"))
        XCTAssertTrue(projected.system.contains("- listRecentFeedLogs:"))
        XCTAssertTrue(projected.system.contains("<tool_call>"))
    }

    func test_splitHistory_toolResultMergesIntoPrecedingUserTurn() throws {
        let result = ToolResult(content: "Logged 120 ml at 10:00")
        let messages: [ChatMessage] = [
            ChatMessage(role: .user, text: "log 120 ml"),
            ChatMessage(
                role: .tool,
                text: "",
                toolEntry: .result(id: "t1", name: "createFeedLog", result: result)
            )
        ]

        let projected = QwenLlamaCppChatSession.splitHistory(messages: messages, tools: nil)

        XCTAssertEqual(projected.turns.count, 1)
        XCTAssertEqual(projected.turns[0].role, .user)
        XCTAssertTrue(projected.turns[0].text.contains("log 120 ml"))
        XCTAssertTrue(projected.turns[0].text.contains("<tool_response>"))
        XCTAssertTrue(projected.turns[0].text.contains("\"name\": \"createFeedLog\""))
        XCTAssertTrue(projected.turns[0].text.contains("Logged 120 ml at 10:00"))
    }

    func test_splitHistory_toolResultWithQuotesIsEscaped() throws {
        let result = ToolResult(content: "contains \"quotes\" inside")
        let messages: [ChatMessage] = [
            ChatMessage(role: .user, text: "x"),
            ChatMessage(
                role: .tool,
                text: "",
                toolEntry: .result(id: "t1", name: "echo", result: result)
            )
        ]

        let projected = QwenLlamaCppChatSession.splitHistory(messages: messages, tools: nil)

        XCTAssertTrue(projected.turns[0].text.contains("\\\"quotes\\\""))
    }

    func test_splitHistory_systemMessagesInInputAreDroppedInFavorOfCanonicalPrompt() throws {
        let messages: [ChatMessage] = [
            ChatMessage(role: .system, text: "ignore this"),
            ChatMessage(role: .user, text: "hi")
        ]

        let projected = QwenLlamaCppChatSession.splitHistory(messages: messages, tools: nil)

        XCTAssertFalse(projected.system.contains("ignore this"))
        XCTAssertEqual(projected.turns.count, 1)
        XCTAssertEqual(projected.turns[0].text, "hi")
    }

    // MARK: - ChatML rendering

    func test_renderChatMLPrompt_wrapsSystemAndTurnsInImStartImEndMarkers() {
        let history = QwenLlamaCppChatSession.ProjectedHistory(
            system: "SYS",
            turns: [
                .init(role: .user, text: "U1"),
                .init(role: .assistant, text: "A1"),
                .init(role: .user, text: "U2"),
            ]
        )

        let rendered = QwenLlamaCppChatSession.renderChatMLPrompt(history: history)

        XCTAssertEqual(
            rendered,
            """
            <|im_start|>system
            SYS<|im_end|>
            <|im_start|>user
            U1<|im_end|>
            <|im_start|>assistant
            A1<|im_end|>
            <|im_start|>user
            U2<|im_end|>
            <|im_start|>assistant

            """
        )
    }

    func test_renderChatMLPrompt_endsWithOpenAssistantTurn() {
        let history = QwenLlamaCppChatSession.ProjectedHistory(
            system: "s",
            turns: [.init(role: .user, text: "hi")]
        )

        let rendered = QwenLlamaCppChatSession.renderChatMLPrompt(history: history)

        XCTAssertTrue(rendered.hasSuffix("<|im_start|>assistant\n"))
    }
}

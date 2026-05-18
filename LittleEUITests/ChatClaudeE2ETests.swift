import XCTest

/// End-to-end smoke test for the Claude streaming chat backend.
///
/// This test is **gated** on a real Anthropic API key being provided via
/// the `LITTLEE_CLAUDE_TEST_KEY` environment variable. CI does not set
/// that variable, so the test is `XCTSkip`-ped by default and never makes
/// a real network call in the normal test run. To exercise it locally:
///
///     LITTLEE_CLAUDE_TEST_KEY=sk-ant-... xcodebuild test \
///       -only-testing:LittleEUITests/ChatClaudeE2ETests
///
/// The Chat tab UI itself lands in a sibling card (X.5 / X.6). Until that
/// ships the test also guards on the tab being present, so it remains
/// green (skipped) on both pre- and post-UI checkouts.
@MainActor
final class ChatClaudeE2ETests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["LITTLEE_CLAUDE_TEST_KEY"] != nil else {
            throw XCTSkip("LITTLEE_CLAUDE_TEST_KEY not set — skipping live Claude E2E.")
        }
        app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing",
            "--chat-backend", "claude",
        ]
        if let key = ProcessInfo.processInfo.environment["LITTLEE_CLAUDE_TEST_KEY"] {
            app.launchEnvironment["LITTLEE_CLAUDE_TEST_KEY"] = key
        }
        app.launch()
    }

    func test_sendMessage_streamsAssistantReply() throws {
        // Navigate to the Chat tab. If it isn't in the build yet, skip —
        // the backend tests still cover the parsing logic hermetically.
        let chatTab = app.tabBars.buttons["Chat"]
        guard chatTab.waitForExistence(timeout: 2) else {
            throw XCTSkip("Chat tab not present in this build — skipping E2E.")
        }
        chatTab.tap()

        let input = app.textFields["chatInputField"]
        XCTAssertTrue(input.waitForExistence(timeout: 2))
        input.tap()
        input.typeText("Say hi to Ethan in three words.")

        app.buttons["chatSendButton"].tap()

        // Wait for the assistant bubble to start streaming — identified by
        // its accessibility identifier `chatAssistantMessage`.
        let reply = app.staticTexts["chatAssistantMessage"]
        XCTAssertTrue(reply.waitForExistence(timeout: 30))
        XCTAssertFalse(reply.label.isEmpty, "assistant reply should contain streamed text")
    }
}

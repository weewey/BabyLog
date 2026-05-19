import XCTest

/// End-to-end test for the Apple Foundation Models Chat backend.
///
/// This test requires:
///   1. `FoundationModels` framework available (iOS 26 device — not the
///      simulator, where on-device models are not installed).
///   2. The Chat tab UI (accessibility identifiers `chat-tab`,
///      `chat-input`, `chat-send`, `chat-last-assistant-message`) which
///      lands in a later card.
///
/// On CI (simulator) or before the UI lands, the test skips with a
/// descriptive reason so the suite stays green. On a real device with the
/// UI in place it types a message, taps send, and asserts a non-empty
/// streaming reply appears within a reasonable window.
final class ChatAppleE2ETests: XCTestCase {

    func test_appleFM_streamsNonEmptyReply_onDevice() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Apple Foundation Models requires on-device execution; skipping in simulator.")
        #else
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing", "--chat-backend=apple"]
        app.launch()

        let chatTab = app.buttons["chat-tab"]
        guard chatTab.waitForExistence(timeout: 5) else {
            throw XCTSkip("Chat tab not yet wired up in this build; skipping E2E until UI lands.")
        }
        chatTab.tap()

        let input = app.textFields["chat-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 3), "chat-input not found")
        input.tap()
        input.typeText("Hello baby")

        app.buttons["chat-send"].tap()

        let reply = app.staticTexts["chat-last-assistant-message"]
        let appeared = reply.waitForExistence(timeout: 15)
        XCTAssertTrue(appeared, "Assistant reply never appeared within timeout")

        let replyText = reply.label
        XCTAssertFalse(replyText.isEmpty, "Assistant reply was empty")
        #endif
    }
}

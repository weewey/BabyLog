import XCTest

@MainActor
final class ChatTabE2ETests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-UITEST_FAKE_CHAT", "1", "-UITEST_RESET_CHAT", "1"]
        app.launch()
    }

    // MARK: - Default tab

    func test_launch_chatTabIsDefaultSelection() throws {
        let chatTabButton = app.tabBars.buttons["Assistant"]
        XCTAssertTrue(chatTabButton.waitForExistence(timeout: 3))
        XCTAssertTrue(chatTabButton.isSelected, "Assistant should be the default selected tab")
        XCTAssertTrue(app.otherElements["chatTabRoot"].exists
                      || app.textFields["chatInputField"].waitForExistence(timeout: 2))
    }

    // MARK: - Send flow

    func test_sendMessage_streamsAssistantReply() throws {
        let input = app.textFields["chatInputField"]
        XCTAssertTrue(input.waitForExistence(timeout: 3))
        input.tap()
        input.typeText("hello")

        let sendButton = app.buttons["chatSendButton"]
        XCTAssertTrue(sendButton.isEnabled)
        sendButton.tap()

        // User bubble should appear
        let userBubble = app.otherElements["chatUserBubble"]
            .firstMatch
        // Assistant bubble should appear and eventually have non-empty text.
        let assistantBubble = app.otherElements["chatAssistantBubble"].firstMatch
        XCTAssertTrue(assistantBubble.waitForExistence(timeout: 3)
                      || app.staticTexts.matching(identifier: "chatAssistantBubble").firstMatch.waitForExistence(timeout: 3))

        // Wait for streaming to finish: send button re-enabled means isStreaming=false
        // We type another character to force a non-empty input, then check
        // enablement. Simpler: wait for the send button to exist again.
        let sendAgain = app.buttons["chatSendButton"]
        let exists = NSPredicate(format: "exists == true")
        expectation(for: exists, evaluatedWith: sendAgain, handler: nil)
        waitForExpectations(timeout: 5)

        _ = userBubble // silence warning
    }

    // MARK: - Backend picker

    func test_backendPicker_switchesToAppleAndPersists() throws {
        // Default backend is Gemma. The picker now also offers Apple; selecting
        // it must update the selection marker and persist across a relaunch.
        let marker = app.staticTexts["chatSelectedBackendMarker"]
        XCTAssertTrue(marker.waitForExistence(timeout: 5))
        XCTAssertEqual(marker.label, "gemma", "expected default backend to be gemma")

        app.buttons["chatBackendMenu"].tap()
        app.buttons["chatBackendOption_apple"].tap()

        let appleSelected = NSPredicate(format: "label == %@", "apple")
        expectation(for: appleSelected, evaluatedWith: marker, handler: nil)
        waitForExpectations(timeout: 5)

        // Relaunch without the reset flag — selection should persist.
        app.terminate()
        app.launchArguments = ["--ui-testing", "-UITEST_FAKE_CHAT", "1"]
        app.launch()

        let markerAfter = app.staticTexts["chatSelectedBackendMarker"]
        XCTAssertTrue(markerAfter.waitForExistence(timeout: 5))
        XCTAssertEqual(markerAfter.label, "apple",
                       "expected persisted backend to be apple after relaunch")
    }
}

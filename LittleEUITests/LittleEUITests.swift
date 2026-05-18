import XCTest

@MainActor
final class LittleEUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-tabs.diapersEnabled", "1", "-tabs.appointmentsEnabled", "1"]
        app.launch()
        let feeds = app.tabBars.buttons["Feeds"]
        if feeds.waitForExistence(timeout: 3) { feeds.tap() }
    }

    // MARK: - Launch & empty state

    func testLaunch_showsFeedTab() throws {
        XCTAssertTrue(app.navigationBars["Feeds"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["feedAddButton"].exists)
    }

    func testEmptyState_showsNoFeedsYet() throws {
        let picker = app.segmentedControls["feedSectionPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 3))
        picker.buttons["History"].tap()
        XCTAssertTrue(app.staticTexts["No Feeds Yet"].waitForExistence(timeout: 3))
    }

    func testSaveButton_disabledWhenVolumeIsZero() throws {
        openFeedForm()
        XCTAssertFalse(app.buttons["saveButton"].isEnabled)
        closeFeedForm()
    }

    // MARK: - Feed logging flow

    func testLogFeed_bottleFeed_appearsInList() throws {
        logFeed(volume: "120")
        XCTAssertTrue(waitForFeedRow(containing: "120 ml"))
    }

    func testLogFeed_breastFeed_appearsInList() throws {
        openFeedForm()
        typeVolume("80")
        let breast = app.buttons["Breast"]
        if breast.waitForExistence(timeout: 1) { breast.tap() }
        app.buttons["saveButton"].tap()
        closeFeedForm()
        XCTAssertTrue(waitForFeedRow(containing: "80 ml"))
    }

    func testLogFeed_resetsDraftAfterSave() throws {
        openFeedForm()
        typeVolume("150")
        app.buttons["saveButton"].tap()

        let value = app.textFields["volumeField"].value as? String ?? ""
        XCTAssertTrue(value.isEmpty || value == "0",
                      "Expected empty/'0' but got '\(value)'")
        closeFeedForm()
        XCTAssertTrue(waitForFeedRow(containing: "150 ml"))
    }

    func testLogMultipleFeeds_allAppearInList() throws {
        logFeed(volume: "100")
        logFeed(volume: "200")

        XCTAssertTrue(waitForFeedRow(containing: "100 ml"))
        XCTAssertTrue(waitForFeedRow(containing: "200 ml"))
    }

    func testInvalidVolume_saveStaysDisabled() throws {
        openFeedForm()
        typeVolume("501")
        let saveButton = app.buttons["saveButton"]
        let disabled = NSPredicate(format: "isEnabled == false")
        expectation(for: disabled, evaluatedWith: saveButton, handler: nil)
        waitForExpectations(timeout: 2)
        closeFeedForm()
    }

    // MARK: - Tab navigation

    func testTabBar_visibleTabsExist() throws {
        XCTAssertTrue(app.tabBars.buttons["Feeds"].exists)
        XCTAssertTrue(app.tabBars.buttons["Diapers"].exists)
        XCTAssertTrue(app.tabBars.buttons["Pumping"].exists)
    }

    func testTabBar_switchToDiapers_showsDiaperUI() throws {
        app.tabBars.buttons["Diapers"].tap()
        XCTAssertTrue(app.navigationBars["Diapers"].waitForExistence(timeout: 3))
    }

    func testTabBar_switchBackToFeeds_showsFeedTab() throws {
        app.tabBars.buttons["Diapers"].tap()
        app.tabBars.buttons["Feeds"].tap()
        XCTAssertTrue(app.navigationBars["Feeds"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["feedAddButton"].exists)
    }

    // MARK: - Helpers

    private func openFeedForm() {
        let add = app.buttons["feedAddButton"]
        XCTAssertTrue(add.waitForExistence(timeout: 3))
        add.tap()
        XCTAssertTrue(app.textFields["volumeField"].waitForExistence(timeout: 3))
    }

    private func closeFeedForm() {
        let done = app.buttons["feedFormDoneButton"]
        if done.waitForExistence(timeout: 1) { done.tap() }
    }

    private func typeVolume(_ volume: String) {
        let field = app.textFields["volumeField"]
        field.tap()
        field.typeText(volume)
        dismissKeyboard()
    }

    private func dismissKeyboard() {
        let done = app.buttons["keyboardDoneButton"]
        if done.waitForExistence(timeout: 1) { done.tap() }
    }

    private func logFeed(volume: String) {
        openFeedForm()
        typeVolume(volume)
        app.buttons["saveButton"].tap()
        closeFeedForm()
        _ = waitForFeedRow(containing: "\(volume) ml")
    }

    private func waitForFeedRow(containing text: String, timeout: TimeInterval = 5) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS[c] %@", text)
        return app.descendants(matching: .any).matching(predicate).firstMatch.waitForExistence(timeout: timeout)
    }
}

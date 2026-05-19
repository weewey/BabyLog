import XCTest

@MainActor
final class MilestonesUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        navigateToMilestones()
    }

    @MainActor
    func testLaunch_showsMilestoneTab() throws {
        XCTAssertTrue(app.navigationBars["Milestones"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["milestoneAddButton"].exists)
    }

    @MainActor
    func testSaveButton_disabledWhenTitleEmpty() throws {
        openMilestoneForm()
        XCTAssertFalse(app.buttons["milestoneSaveButton"].isEnabled)
        closeMilestoneForm()
    }

    @MainActor
    func testLogMilestone_appearsInList() throws {
        openMilestoneForm()
        let titleField = app.textFields["milestoneTitleField"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 3))
        titleField.tap()
        titleField.typeText("First smile")

        let done = app.buttons["keyboardDoneButton"]
        if done.waitForExistence(timeout: 1) { done.tap() }

        waitEnabled(app.buttons["milestoneSaveButton"]).tap()
        closeMilestoneForm()

        XCTAssertTrue(app.staticTexts["First smile"].waitForExistence(timeout: 3))
    }

    @MainActor
    private func openMilestoneForm() {
        let add = app.buttons["milestoneAddButton"]
        XCTAssertTrue(add.waitForExistence(timeout: 3))
        add.tap()
        XCTAssertTrue(app.textFields["milestoneTitleField"].waitForExistence(timeout: 3))
    }

    @MainActor
    private func closeMilestoneForm() {
        let done = app.buttons["milestoneFormDoneButton"]
        if done.waitForExistence(timeout: 1) { done.tap() }
    }

    @MainActor
    private func navigateToMilestones() {
        _ = app.navigationBars["Feeds"].waitForExistence(timeout: 5)
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5))
        let direct = app.tabBars.buttons["Milestones"]
        if direct.waitForExistence(timeout: 2) {
            direct.tap()
            return
        }
        let more = app.tabBars.buttons["More"]
        if more.waitForExistence(timeout: 2) {
            more.tap()
            tapMoreRow("Milestones")
        }
    }

    @MainActor
    private func tapMoreRow(_ label: String) {
        let candidates: [XCUIElement] = [
            app.cells[label],
            app.cells.staticTexts[label],
            app.tables.staticTexts[label],
            app.collectionViews.cells[label],
            app.collectionViews.staticTexts[label],
            app.staticTexts[label],
        ]
        for c in candidates where c.waitForExistence(timeout: 1) {
            c.tap()
            return
        }
    }

    @MainActor
    @discardableResult
    private func waitEnabled(_ element: XCUIElement, timeout: TimeInterval = 2) -> XCUIElement {
        let enabled = NSPredicate(format: "isEnabled == true")
        expectation(for: enabled, evaluatedWith: element, handler: nil)
        waitForExpectations(timeout: timeout)
        return element
    }
}

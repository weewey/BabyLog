import XCTest

@MainActor
final class GrowthUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        navigateToGrowth()
    }

    @MainActor
    func testLaunch_showsGrowthTab() throws {
        XCTAssertTrue(app.navigationBars["Growth"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["growthAddButton"].exists)
    }

    @MainActor
    func testSaveButton_disabledWhenEmpty() throws {
        openGrowthForm()
        XCTAssertFalse(app.buttons["growthSaveButton"].isEnabled)
        closeGrowthForm()
    }

    @MainActor
    func testLogMeasurement_weightOnly_appearsInList() throws {
        openGrowthForm()
        let weightField = app.textFields["weightField"]
        XCTAssertTrue(weightField.waitForExistence(timeout: 5))
        weightField.tap()
        weightField.typeText("4500")

        let keyboardDone = app.buttons["keyboardDoneButton"]
        if keyboardDone.waitForExistence(timeout: 1) { keyboardDone.tap() }

        waitEnabled(app.buttons["growthSaveButton"]).tap()
        closeGrowthForm()

        let predicate = NSPredicate(format: "label CONTAINS[c] %@", "4.50 kg")
        let row = app.descendants(matching: .any).matching(predicate).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
    }

    @MainActor
    private func navigateToGrowth() {
        _ = app.tabBars.firstMatch.waitForExistence(timeout: 5)
        let more = app.tabBars.buttons["More"]
        XCTAssertTrue(more.waitForExistence(timeout: 3))
        more.tap()
        tapMoreRow("Growth")
        _ = app.navigationBars["Growth"].waitForExistence(timeout: 3)
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
    private func openGrowthForm() {
        let add = app.buttons["growthAddButton"]
        XCTAssertTrue(add.waitForExistence(timeout: 3))
        add.tap()
        XCTAssertTrue(app.textFields["weightField"].waitForExistence(timeout: 3))
    }

    @MainActor
    private func closeGrowthForm() {
        let done = app.buttons["growthFormDoneButton"]
        if done.waitForExistence(timeout: 1) { done.tap() }
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

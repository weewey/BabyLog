import XCTest

@MainActor
final class SettingsUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        navigateToSettings()
    }

    @MainActor
    func testLaunch_showsSettingsForm() throws {
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.textFields["childNameField"].waitForExistence(timeout: 3))
        let save = app.buttons["settingsSaveButton"]
        if !save.exists {
            app.swipeUp()
        }
        XCTAssertTrue(save.waitForExistence(timeout: 3))
    }

    @MainActor
    func testSaveChildProfile_showsAgeBadge() throws {
        let nameField = app.textFields["childNameField"]
        nameField.tap()
        nameField.typeText("Ethan")

        let done = app.buttons["keyboardDoneButton"]
        if done.waitForExistence(timeout: 1) { done.tap() }

        let save = app.buttons["settingsSaveButton"]
        if !save.isHittable { app.swipeUp() }
        waitEnabled(save).tap()

        // After save, ageLabel is computed and the age row appears.
        // Query as a descendant (any element type) because SwiftUI may expose
        // a Form HStack with an accessibility identifier as a cell, other, or
        // static text depending on the iOS version.
        let row = app.descendants(matching: .any).matching(identifier: "childAgeRow").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
    }

    @MainActor
    private func navigateToSettings() {
        _ = app.navigationBars["Feeds"].waitForExistence(timeout: 5)
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5))
        let direct = app.tabBars.buttons["Settings"]
        if direct.waitForExistence(timeout: 2) {
            direct.tap()
            return
        }
        let more = app.tabBars.buttons["More"]
        if more.waitForExistence(timeout: 2) {
            more.tap()
            tapMoreRow("Settings")
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

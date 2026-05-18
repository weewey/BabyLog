import XCTest

final class DiaperUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launchArguments += ["-tabs.diapersEnabled", "1"]
        app.launch()
    }

    // MARK: - Launch & empty state

    @MainActor
    func testLaunch_showsDiaperTab() throws {
        navigateToDiapers()
        XCTAssertTrue(app.navigationBars["Diapers"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["diaperAddButton"].exists)
    }

    @MainActor
    func testEmptyState_showsNoDiaperChangesYet() throws {
        navigateToDiapers()

        let emptyState = app.staticTexts["No Diaper Changes Yet"]
        XCTAssertTrue(emptyState.waitForExistence(timeout: 3))
    }

    // MARK: - Diaper logging flow

    @MainActor
    func testLogDiaper_wetChange_appearsInList() throws {
        navigateToDiapers()
        logDiaper(type: "Wet")

        let row = app.staticTexts["Wet"]
        XCTAssertTrue(row.waitForExistence(timeout: 3))
    }

    @MainActor
    func testLogDiaper_dirtyChange_appearsInList() throws {
        navigateToDiapers()
        logDiaper(type: "Dirty")

        let row = app.staticTexts["Dirty"]
        XCTAssertTrue(row.waitForExistence(timeout: 3))
    }

    @MainActor
    func testLogDiaper_bothChange_appearsInList() throws {
        navigateToDiapers()
        logDiaper(type: "Both")

        let row = app.staticTexts["Both"]
        XCTAssertTrue(row.waitForExistence(timeout: 3))
    }

    @MainActor
    func testLogDiaper_withNotes_appearsInList() throws {
        navigateToDiapers()
        openDiaperForm()

        let notesField = app.textFields["notesField"]
        XCTAssertTrue(notesField.waitForExistence(timeout: 2))
        notesField.tap()
        notesField.typeText("After lunch")

        let done = app.buttons["keyboardDoneButton"]
        if done.waitForExistence(timeout: 1) { done.tap() }

        app.buttons["saveButton"].tap()
        closeDiaperForm()

        let predicate = NSPredicate(format: "label CONTAINS[c] %@", "After lunch")
        let row = app.descendants(matching: .any).matching(predicate).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
    }

    @MainActor
    func testLogDiaper_resetsDraftAfterSave() throws {
        navigateToDiapers()
        openDiaperForm()

        let notesField = app.textFields["notesField"]
        XCTAssertTrue(notesField.waitForExistence(timeout: 2))
        notesField.tap()
        notesField.typeText("Test note")

        let done = app.buttons["keyboardDoneButton"]
        if done.waitForExistence(timeout: 1) { done.tap() }

        app.buttons["saveButton"].tap()

        let clearedField = app.textFields["notesField"]
        let fieldValue = clearedField.value as? String ?? ""
        XCTAssertTrue(fieldValue.isEmpty || fieldValue == "Notes (optional)",
                      "Expected empty or placeholder but got '\(fieldValue)'")

        closeDiaperForm()

        let predicate = NSPredicate(format: "label CONTAINS[c] %@", "Test note")
        XCTAssertTrue(app.descendants(matching: .any).matching(predicate).firstMatch.waitForExistence(timeout: 5))
    }

    // MARK: - Helpers

    @MainActor
    private func navigateToDiapers() {
        let diaperTab = app.tabBars.buttons["Diapers"]
        if diaperTab.waitForExistence(timeout: 2) {
            diaperTab.tap()
        }
    }

    @MainActor
    private func openDiaperForm() {
        let add = app.buttons["diaperAddButton"]
        XCTAssertTrue(add.waitForExistence(timeout: 3))
        add.tap()
        XCTAssertTrue(app.buttons["saveButton"].waitForExistence(timeout: 3))
    }

    @MainActor
    private func closeDiaperForm() {
        let done = app.buttons["diaperFormDoneButton"]
        if done.waitForExistence(timeout: 1) { done.tap() }
    }

    @MainActor
    private func logDiaper(type: String) {
        openDiaperForm()
        let picker = app.buttons["typePicker"]
        if picker.exists && type != "Wet" {
            picker.tap()
            let option = app.buttons[type]
            if option.waitForExistence(timeout: 2) {
                option.tap()
            }
        }

        app.buttons["saveButton"].tap()
        closeDiaperForm()
    }
}

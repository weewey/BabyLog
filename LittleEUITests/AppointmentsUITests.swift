import XCTest

@MainActor
final class AppointmentsUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launchArguments += ["-tabs.appointmentsEnabled", "1"]
        app.launch()
        navigateToAppts()
    }

    @MainActor
    func testLaunch_showsAppointmentTab() throws {
        XCTAssertTrue(app.navigationBars["Appointments"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["appointmentAddButton"].exists)
    }

    @MainActor
    func testEmptyState_showsPlaceholder() throws {
        XCTAssertTrue(app.staticTexts["No Appointments"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testSaveButton_disabledWhenTitleEmpty() throws {
        openAppointmentForm()
        XCTAssertFalse(app.buttons["apptSaveButton"].isEnabled)
        closeAppointmentForm()
    }

    @MainActor
    func testLogAppointment_appearsInList() throws {
        openAppointmentForm()
        let titleField = app.textFields["apptTitleField"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 3))
        titleField.tap()
        titleField.typeText("Pediatrician")

        let done = app.buttons["keyboardDoneButton"]
        if done.waitForExistence(timeout: 1) { done.tap() }

        waitEnabled(app.buttons["apptSaveButton"]).tap()
        closeAppointmentForm()

        XCTAssertTrue(app.staticTexts["Pediatrician"].waitForExistence(timeout: 3))
    }

    @MainActor
    private func openAppointmentForm() {
        let add = app.buttons["appointmentAddButton"]
        XCTAssertTrue(add.waitForExistence(timeout: 3))
        add.tap()
        XCTAssertTrue(app.textFields["apptTitleField"].waitForExistence(timeout: 3))
    }

    @MainActor
    private func closeAppointmentForm() {
        let done = app.buttons["appointmentFormDoneButton"]
        if done.waitForExistence(timeout: 1) { done.tap() }
    }

    @MainActor
    private func navigateToAppts() {
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5))
        let direct = app.tabBars.buttons["Appts"]
        if direct.waitForExistence(timeout: 2) {
            direct.tap()
            return
        }
        // Appointments now lives under the custom More tab.
        let more = app.tabBars.buttons["More"]
        if more.waitForExistence(timeout: 2) {
            more.tap()
            tapMoreRow("Appointments")
        }
    }

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

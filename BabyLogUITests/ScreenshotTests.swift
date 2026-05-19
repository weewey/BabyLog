import XCTest

@MainActor
final class ScreenshotTests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        // Chat is the default tab; jump to Feeds for the existing screenshot flow.
        let feeds = app.tabBars.buttons["Feeds"]
        if feeds.waitForExistence(timeout: 3) { feeds.tap() }
        _ = app.navigationBars["Feeds"].waitForExistence(timeout: 5)
    }

    func testCaptureAllTabs() throws {
        attach(name: "01_feeds")

        tapTab("Diapers")
        _ = app.navigationBars["Diapers"].waitForExistence(timeout: 3)
        attach(name: "02_diapers")

        tapTab("Pumping")
        _ = app.navigationBars["Pumping"].waitForExistence(timeout: 3)
        attach(name: "03_pumping")

        tapTab("Appts")
        _ = app.navigationBars["Appointments"].waitForExistence(timeout: 3)
        attach(name: "04_appointments")

        // More → Milestones / Settings
        let more = app.tabBars.buttons["More"]
        if more.waitForExistence(timeout: 2) {
            more.tap()
            attach(name: "05_more_menu")

            tapMoreRow("Milestones")
            _ = app.navigationBars["Milestones"].waitForExistence(timeout: 3)
            attach(name: "06_milestones")

            if more.waitForExistence(timeout: 2) { more.tap() }
            tapMoreRow("Settings")
            _ = app.navigationBars["Settings"].waitForExistence(timeout: 3)
            attach(name: "07_settings")
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

    private func tapTab(_ name: String) {
        let tab = app.tabBars.buttons[name]
        if tab.waitForExistence(timeout: 2) { tab.tap() }
    }

    private func attach(name: String) {
        let shot = app.screenshot()
        let att = XCTAttachment(screenshot: shot)
        att.name = name
        att.lifetime = .keepAlways
        add(att)
    }
}

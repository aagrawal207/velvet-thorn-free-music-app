import XCTest

@MainActor
final class GanaBajanaUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testLaunchAndNavigation() throws {
        let ui = AppUITestDriver(testCase: self, prefix: "launch-navigation")
        addTeardownBlock { await ui.finish() }
        try ui.launch()
        let app = ui.app
        try ui.selectTab("search")
        XCTAssertTrue(app.textFields["search.field"].waitForExistence(timeout: 5))
        try ui.selectTab("library")
        XCTAssertTrue(app.staticTexts["Your Library"].waitForExistence(timeout: 5))
        try ui.selectTab("recap")
        let listening = try ui.tabButton("recap")
        XCTAssertEqual(listening.identifier, "tab.recap")
        XCTAssertEqual(listening.label, "Stats")
        XCTAssertTrue(app.staticTexts["Stats"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Time with your music, made from saved listening."].exists)
    }
}

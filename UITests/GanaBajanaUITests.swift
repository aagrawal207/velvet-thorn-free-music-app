import XCTest

@MainActor
final class GanaBajanaUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testLaunchAndNavigation() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--seed-ui", "--skip-welcome", "--reset-ui"]
        app.launchEnvironment["GANABAJANA_TEST_STORE"] = UUID().uuidString
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Search"].waitForExistence(timeout: 15))
        app.tabBars.buttons["Search"].tap()
        XCTAssertTrue(app.textFields["search.field"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(app.staticTexts["Your library"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Recap"].tap()
        XCTAssertTrue(app.staticTexts["Your listening, lately"].waitForExistence(timeout: 5))
    }
}

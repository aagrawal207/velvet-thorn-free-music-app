import XCTest

@MainActor
final class GanaBajanaMainStatsUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testStatsKeepsRecapSelectorsAndTitleCasedSections() throws {
        let ui = AppUITestDriver(testCase: self, prefix: "main-stats")
        addTeardownBlock { await ui.finish() }
        ui.app.launchArguments = ["--uitesting", "--seed-ui", "--reset-ui", "--skip-welcome",
                                  "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        ui.app.launchEnvironment = ["GANABAJANA_TEST_STORE": ui.storeName]
        ui.app.launch()
        let tab = ui.app.buttons["tab.recap"].firstMatch
        try ui.requireHittable(tab, timeout: 25)
        XCTAssertEqual(tab.label, "Stats")
        try ui.tap(tab)
        XCTAssertTrue(tab.isSelected)
        XCTAssertTrue(ui.element("recap.screen").exists)
        XCTAssertTrue(ui.app.staticTexts["Stats"].exists)
        XCTAssertFalse(ui.app.staticTexts["Listening"].exists)
        ui.capture("stats-title-and-periods")
        try ui.reveal(ui.app.staticTexts["On Repeat"])
        XCTAssertTrue(ui.app.staticTexts["On Repeat"].exists)
        try ui.reveal(ui.app.staticTexts["Day by Day"])
        XCTAssertTrue(ui.app.staticTexts["Day by Day"].exists)
        let allTime = ui.app.buttons["recap.window.allTime"]
        try ui.reveal(allTime, direction: .down)
        try ui.tap(allTime)
        XCTAssertTrue(allTime.isSelected)
        try ui.reveal(ui.app.staticTexts["Over Time"])
        XCTAssertTrue(ui.app.staticTexts["Over Time"].exists)
        let recents = ui.app.buttons["recap.recent.toggle"]
        try ui.reveal(recents)
        XCTAssertEqual(recents.label, "Recently Played")
        XCTAssertEqual(recents.value as? String, "Collapsed")
        ui.capture("stats-collapsed-recent-history")
    }
}

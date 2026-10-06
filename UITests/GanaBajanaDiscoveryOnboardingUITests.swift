import XCTest

@MainActor
final class GanaBajanaDiscoveryOnboardingUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testNotNowOpensHomeAndRelaunchDoesNotOfferConnectionAgain() throws {
        let ui = makeDriver()
        try ui.launch(skipWelcome: false)
        try ui.tap(ui.app.buttons["welcome.continue"])

        let connect = ui.app.buttons["welcome.youtube.connect"]
        let notNow = ui.app.buttons["welcome.youtube.notNow"]
        try ui.reveal(connect)
        try ui.requireHittable(connect)
        XCTAssertGreaterThanOrEqual(connect.frame.height + 1e-6, 44)
        try ui.reveal(notNow)
        try ui.requireHittable(notNow)
        XCTAssertGreaterThanOrEqual(notNow.frame.height + 1e-6, 44)
        XCTAssertEqual(notNow.label, "Not Now")
        XCTAssertFalse(ui.element("signin.screen").exists)
        XCTAssertFalse(ui.element("import.content").exists)

        try ui.tap(notNow)
        try ui.requireHittable(ui.tabButton("home"))
        try ui.relaunch()
        assertOnboardingAbsent(ui)

        try ui.openSettings()
        try ui.openSettingsPage(.account)
        let signIn = ui.app.buttons["settings.youtubeSignIn"]
        try ui.reveal(signIn)
        try ui.requireHittable(signIn)
        XCTAssertFalse(ui.app.buttons["settings.youtubeSignOut"].exists)
        XCTAssertFalse(ui.app.buttons["settings.youtubeImport"].exists)
    }

    func testRelaunchDuringOptionalStepDoesNotRepeatIt() throws {
        let ui = makeDriver()
        try ui.launch(skipWelcome: false)
        try ui.tap(ui.app.buttons["welcome.continue"])
        try ui.reveal(ui.app.buttons["welcome.youtube.notNow"])
        try ui.requireHittable(ui.app.buttons["welcome.youtube.notNow"])

        try ui.relaunch()
        assertOnboardingAbsent(ui)
        XCTAssertFalse(ui.element("signin.screen").exists)
    }

    func testPreviouslyCompletedWelcomeNeverOffersConnection() throws {
        let ui = makeDriver()
        try ui.launch()
        ui.app.terminate()
        try ui.launch(skipWelcome: false, reset: false)
        assertOnboardingAbsent(ui)
        XCTAssertFalse(ui.element("signin.screen").exists)
    }

    private func makeDriver() -> AppUITestDriver {
        let ui = AppUITestDriver(testCase: self, prefix: "discovery-onboarding")
        addTeardownBlock { await ui.finish() }
        return ui
    }

    private func assertOnboardingAbsent(_ ui: AppUITestDriver, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(ui.app.buttons["welcome.continue"].exists, file: file, line: line)
        XCTAssertFalse(ui.app.buttons["welcome.youtube.connect"].exists, file: file, line: line)
        XCTAssertFalse(ui.app.buttons["welcome.youtube.notNow"].exists, file: file, line: line)
    }
}

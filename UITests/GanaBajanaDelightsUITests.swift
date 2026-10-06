import XCTest

/// Settings > About: seven quick taps on Version answer with the secret-menu line, and a second round with its sequel.
/// The flourish is a system sound and the haptic is a no-op in the simulator; only the toast is asserted.
@MainActor
final class GanaBajanaDelightsUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testSevenVersionTapsShowTheSecretMenuLineThenItsSequel() throws {
        let ui = AppUITestDriver(testCase: self, prefix: "delights")
        addTeardownBlock { await ui.finish() }
        try ui.launch()
        try ui.openSettings()
        try ui.openSettingsPage(.about)
        let version = ui.element("settings.version")
        try ui.reveal(version)
        let message = ui.element("message.text")

        // Plain element taps keep each gap well inside the 1.5-second limit; the driver's tap adds settling waits.
        for _ in 0..<7 { version.tap() }
        try ui.wait("Seven quick taps answer with the secret-menu line") {
            message.exists && message.label == "There’s no secret menu. Nice try, though."
        }
        for _ in 0..<7 { version.tap() }
        try ui.wait("A second round notes the persistence") {
            message.exists && message.label == "Still no secret menu. Persistence noted."
        }
        XCTAssertTrue(ui.app.buttons["settings.done"].exists, "The taps never leave the About page")
        ui.capture("delights-about-second-round")
    }
}

import XCTest

/// Captures the player with each background style so the motion can be judged on screen.
@MainActor
final class GanaBajanaPlayerBackgroundUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testEachPlayerBackgroundStyleCanBeChosenAndShowsThePlayer() throws {
        for (style, light) in [("Drift", false), ("Pulse", false), ("React to Music", false), ("Drift", true)] {
            let ui = AppUITestDriver(testCase: self, prefix: "player-background")
            try ui.launch(additionalArguments: light ? ["--light"] : [])
            try ui.openSettings()
            try ui.openSettingsPage(.appearance)
            let row = ui.app.buttons["settings.playerBackground"]
            try ui.reveal(row)
            XCTAssertTrue(ui.accessibleText(row).contains("Off"), ui.accessibleText(row))
            try ui.tap(row)
            let choice = ui.app.buttons[style].firstMatch
            try ui.wait("The menu offers \(style)") { choice.exists }
            choice.tap()
            try ui.wait("The row shows \(style)") { ui.accessibleText(row).contains(style) }
            try ui.tap(ui.app.buttons["settings.done"])
            try ui.playSeededPlaylist()
            try ui.openPlayer()
            let name = style.lowercased().replacingOccurrences(of: " ", with: "-") + (light ? "-light" : "")
            Thread.sleep(forTimeInterval: 2)
            ui.capture("player-background-\(name)-a")
            Thread.sleep(forTimeInterval: 4)
            ui.capture("player-background-\(name)-b")
            ui.finish()
        }
    }
}

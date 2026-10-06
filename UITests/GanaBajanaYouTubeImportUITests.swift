import Foundation
import XCTest

/// Settings > Account & connection > Import from YouTube Music against the network-free `--youtube-import-fixture`:
/// a fixture sign-in plus canned account pages (3 liked songs, 2 playlists, 2 artists, 5 history rows).
@MainActor
final class GanaBajanaYouTubeImportUITests: XCTestCase {
    private static let summary = "Liked 3 songs, added 1 playlist, followed 2 artists, added 4 songs to YouTube Music history."

    override func setUpWithError() throws { continueAfterFailure = false }

    func testImportCopiesTheAccountLibraryOnceAndASecondRunAddsNothing() throws {
        let ui = makeDriver()
        try ui.launch(additionalArguments: ["--youtube-import-fixture"])
        try ui.selectTab("library")
        let likes = ui.app.buttons["library.likes"]
        try ui.wait("Library must list the seeded likes") { likes.exists && ui.accessibleText(likes).contains("5 songs") }
        XCTAssertFalse(ui.playlist(named: "Road trip").exists, "The remote-only playlist does not exist before the import")

        try ui.openSettings()
        try ui.openSettingsPage(.account)
        let row = ui.app.buttons["settings.youtubeImport"]
        try ui.reveal(row, maxSwipes: 24)
        XCTAssertGreaterThanOrEqual(row.frame.height, 44 - 1e-6)
        XCTAssertEqual(row.label, "Import from YouTube Music")
        try ui.expectValue(row, "Not imported")
        XCTAssertTrue(ui.element("settings.youtubeStatus").exists, "The row sits under the signed-in status")
        try ui.tap(row)
        try ui.wait("Settings must open the import page") { ui.app.navigationBars["Import from YouTube Music"].exists }
        XCTAssertTrue(ui.element("import.intro").label.contains("Nothing is changed on the account"))
        XCTAssertTrue(ui.element("import.warning").label.contains("Google can see these requests"))
        XCTAssertTrue(ui.accessibleText(ui.element("import.lastImport")).contains("Not imported"))
        for kind in ["likes", "playlists", "subscriptions"] { try ui.expectSwitch("import.kind.\(kind)", isOn: true) }
        try ui.expectSwitch("import.kind.history", isOn: false)
        try ui.setSwitch("import.kind.history", to: true)

        let lateNight = ui.app.buttons["import.playlist.0"]
        let roadTrip = ui.app.buttons["import.playlist.1"]
        // List rows below the fold do not exist until scrolled into view.
        try ui.reveal(roadTrip, maxSwipes: 12)
        try ui.wait("The picker lists both remote playlists") { lateNight.exists && roadTrip.exists }
        XCTAssertEqual(lateNight.label, "Late night favorites")
        XCTAssertEqual(roadTrip.label, "Road trip")
        XCTAssertTrue(lateNight.isSelected && roadTrip.isSelected, "Every playlist starts selected")
        XCTAssertGreaterThanOrEqual(roadTrip.frame.height, 44 - 1e-6)
        try ui.tap(roadTrip)
        try ui.wait("Tapping a playlist deselects it") { !roadTrip.isSelected }
        XCTAssertTrue(ui.element("import.playlists.selection").label.hasPrefix("1 of 2 selected"))
        try ui.tap(roadTrip)
        try ui.wait("Tapping again reselects it") { roadTrip.isSelected }
        ui.capture("youtube-import-ready")

        let start = ui.app.buttons["import.start"]
        try ui.reveal(start, maxSwipes: 12)
        XCTAssertGreaterThanOrEqual(start.frame.height, 44 - 1e-6)
        XCTAssertTrue(start.isEnabled)
        try ui.tap(start)
        let summary = ui.element("import.summary")
        try revealSummary(summary, reading: Self.summary, ui: ui)
        XCTAssertTrue(ui.accessibleText(ui.element("import.progress.likes")).contains("3 read, 3 liked"))
        XCTAssertTrue(ui.accessibleText(ui.element("import.progress.playlists")).contains("2 read, 1 added"))
        XCTAssertTrue(ui.accessibleText(ui.element("import.progress.subscriptions")).contains("2 read, 2 followed"))
        XCTAssertTrue(ui.accessibleText(ui.element("import.progress.history")).contains("5 read, 4 added"))
        XCTAssertFalse(ui.app.buttons["import.cancel"].exists)
        ui.capture("youtube-import-summary")
        let lastImport = ui.element("import.lastImport")
        try ui.reveal(lastImport, direction: .down, maxSwipes: 12)
        XCTAssertFalse(ui.accessibleText(lastImport).contains("Not imported"), ui.accessibleText(lastImport))

        try ui.reveal(start, maxSwipes: 12)
        try ui.tap(start)
        try revealSummary(summary, reading: "Nothing new to import.", ui: ui)
        XCTAssertTrue(ui.accessibleText(ui.element("import.progress.likes")).contains("3 read, 0 liked"))

        try ui.tap(ui.app.navigationBars["Import from YouTube Music"].buttons.firstMatch)
        try ui.wait("Back returns to the Account page") { ui.app.navigationBars[SettingsPageID.account.title].exists }
        try ui.reveal(row, maxSwipes: 24)
        try ui.wait("The Settings row shows the import date") { (row.value as? String).map { $0 != "Not imported" && !$0.isEmpty } == true }
        try ui.tap(ui.app.buttons["settings.done"])

        try ui.selectTab("library")
        try ui.wait("Liked songs must count the three imported likes") { ui.accessibleText(likes).contains("8 songs") }
        let imported = ui.playlist(named: "Road trip")
        try ui.reveal(imported, maxSwipes: 12)
        XCTAssertEqual(ui.playlists(named: "Road trip").count, 1, "The second run did not duplicate the playlist")
        XCTAssertEqual(ui.playlists(named: "YouTube Music history").count, 1)
        XCTAssertEqual(ui.playlists(named: AppUIFixture.seededPlaylist).count, 1, "The mapped playlist was updated in place, not copied")
        ui.capture("youtube-import-library")
        try ui.openPlaylist(named: "Road trip")
        try ui.wait("The imported playlist lists its two songs") {
            ui.app.buttons["track.play.ImportRoad1"].exists && ui.app.buttons["track.play.ImportRoad2"].exists
        }

        try ui.relaunch(adding: ["--light"])
        try ui.selectTab("library")
        try ui.wait("Imported content survives a relaunch") { ui.accessibleText(likes).contains("8 songs") }
        try ui.openSettings()
        try ui.openSettingsPage(.account)
        try ui.reveal(row, maxSwipes: 24)
        try ui.wait("The ledger date is read back after relaunch") { (row.value as? String).map { $0 != "Not imported" } == true }
        try ui.tap(row)
        try ui.wait("The import page opens again") { ui.app.navigationBars["Import from YouTube Music"].exists }
        try ui.wait("The last import date is shown") { !ui.accessibleText(ui.element("import.lastImport")).contains("Not imported") }
        XCTAssertTrue(ui.element("import.summary").exists == false, "A fresh page shows no stale summary")
        ui.capture("youtube-import-light")
    }

    func testTheRowIsHiddenWithoutASignIn() throws {
        let ui = makeDriver()
        try ui.launch()
        try ui.openSettings()
        try ui.openSettingsPage(.account)
        let signIn = ui.app.buttons["settings.youtubeSignIn"]
        try ui.reveal(signIn, maxSwipes: 24)
        XCTAssertFalse(ui.app.buttons["settings.youtubeImport"].exists, "Import is offered only to a signed-in account")
        XCTAssertFalse(ui.element("settings.youtubeImport").exists)
    }

    /// The summary row lives below the fold of a lazy list: scroll for it until the run has written the expected text.
    private func revealSummary(_ summary: XCUIElement, reading expected: String, ui: AppUITestDriver, timeout: TimeInterval = 45) throws {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if summary.exists {
                try ui.reveal(summary, maxSwipes: 6)
                if summary.label == expected { return }
            } else {
                // Cheap scroll toward the progress section; `reveal` would spend the deadline on slow swipes.
                ui.app.swipeUp()
            }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date() < deadline
        XCTFail("The import summary must read \(expected); it reads \(summary.exists ? summary.label : "nothing")")
        throw AppUIWorkflowFailure(message: "The import did not finish with the expected summary (store: \(ui.storeName))")
    }

    private func makeDriver() -> AppUITestDriver {
        let ui = AppUITestDriver(testCase: self, prefix: "youtube-import")
        addTeardownBlock { await ui.finish() }
        return ui
    }
}

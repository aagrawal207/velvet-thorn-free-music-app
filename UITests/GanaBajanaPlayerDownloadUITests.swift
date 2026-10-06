import UIKit
import XCTest

/// The Download button beside AirPlay in the player's bottom row: it downloads the current song through the
/// download center, shows the transfer, ends filled in the accent, and asks before removing the download.
@MainActor
final class GanaBajanaPlayerDownloadUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testDownloadButtonDownloadsTheSongAndRemoveReturnsItToTheCache() throws {
        // The slow hook holds the fixture transfer for 3 s so the ring and the cancel path can be observed.
        let ui = try launchPlayer(arguments: ["--cache-fixture", "--cache-fixture-slow-download"])
        let button = ui.app.buttons["player.download"]
        let airPlay = ui.app.buttons["player.airplay"]
        try ui.requireHittable(button)
        try ui.expectLabel(button, "Download")
        XCTAssertTrue(button.isEnabled)
        XCTAssertEqual(ui.app.buttons.matching(identifier: "player.download").count, 1)
        XCTAssertGreaterThanOrEqual(button.frame.width + 1e-6, 44)
        XCTAssertGreaterThanOrEqual(button.frame.height + 1e-6, 44)
        XCTAssertEqual(button.frame.minX, airPlay.frame.maxX + 8, accuracy: 1, "Download sits 8 points beside AirPlay")
        XCTAssertEqual(button.frame.midY, airPlay.frame.midY, accuracy: 1)

        // The fixture caches Tum Hi Ho already; Blinding Lights has no copy, so its download shows a real transfer.
        for _ in 0..<3 { try ui.tap(ui.app.buttons["player.next"]) }
        try ui.expectCurrentTrack(AppUIFixture.blindingLights)
        try ui.expectLabel(button, "Download")
        try ui.expectLabel(ui.app.buttons["player.playPause"], "Play")
        ui.capture("player-download-idle")

        // A tap during the transfer cancels it without asking; the second download lets the More sheet's row follow.
        try ui.tap(button)
        try ui.wait("The button shows the transfer") { button.label.hasPrefix("Downloading, ") }
        XCTAssertTrue(button.label.hasSuffix(" percent"), button.label)
        XCTAssertTrue((button.value as? String)?.hasSuffix(" percent") == true, "The value carries the percentage: \(String(describing: button.value))")
        XCTAssertEqual(button.frame.minX, airPlay.frame.maxX + 8, accuracy: 1, "The ring keeps the row's geometry")
        XCTAssertEqual(button.frame.width, 44, accuracy: 1)
        ui.capture("player-download-downloading")
        try ui.tap(button)
        try ui.expectLabel(button, "Download")
        XCTAssertFalse(ui.app.buttons["Remove Download"].exists, "Cancelling asks nothing")
        try ui.tap(button)
        try ui.wait("The second transfer starts") { button.label.hasPrefix("Downloading, ") }
        let row = ui.app.buttons["player.options.download"]
        try openOptions(revealing: row, ui: ui)
        XCTAssertTrue(row.label.hasPrefix("Downloading") || row.label == "Downloaded", row.label)
        try ui.closeSheet("Song Options")
        var transitions: [String] = []
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            let label = button.label
            if transitions.last != label { transitions.append(label) }
            if label == "Downloaded" { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        ui.note("player-download-transitions", transitions.joined(separator: " -> "))
        XCTAssertEqual(button.label, "Downloaded", "The fixture file is published and promoted within 15 s: \(transitions)")
        XCTAssertFalse(transitions.contains("Download"), "The idle label never returns during the transfer: \(transitions)")
        XCTAssertTrue(button.isEnabled)
        XCTAssertEqual(button.frame.minX, airPlay.frame.maxX + 8, accuracy: 1, "The state change keeps the row's geometry")
        let downloadedShot = ui.app.screenshot()
        ui.capture("player-download-downloaded")
        let glyph = try HeartGlyph(downloadedShot, frame: ui.app.frame, heart: button.frame)
        let pixels = try HeartGlyph.pixels(downloadedShot, frame: ui.app.frame)
        // The filled disc either side of the arrow shaft is the accent; the shaft itself is a cutout.
        let disc = [0.25, 0.75].map { pixels.color(at: CGPoint(x: glyph.box.minX + glyph.box.width * $0, y: glyph.box.midY)) }
        XCTAssertTrue(disc.contains(where: \.isCoral), "A downloaded song shows the filled accent circle \(disc)")
        XCTAssertGreaterThanOrEqual(glyph.box.width, 14, "The glyph is about 20 points wide \(glyph.box)")
        XCTAssertLessThanOrEqual(glyph.box.width, 26)

        // The More sheet's own row agrees with the button.
        try openOptions(revealing: row, ui: ui)
        try ui.expectLabel(row, "Downloaded")
        try ui.expectValue(row, "Remove Download")
        try ui.closeSheet("Song Options")

        // Removing asks first; the confirmation returns the song to the cache tier and the button to its idle state.
        // iOS 26 anchors the dialog to the button and dismisses it on an outside tap, so no Cancel button is asserted.
        try ui.tap(button)
        let remove = ui.app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@",
                                                         "player.download.remove", "Remove Download")).firstMatch
        try ui.wait("Tapping a downloaded song asks before removing") { remove.exists }
        XCTAssertEqual(button.label, "Downloaded", "Asking changes nothing yet")
        ui.capture("player-download-remove-confirmation")
        try ui.tap(remove)
        try ui.expectLabel(button, "Download")
        try ui.wait("The confirmation must close") { !remove.exists }
        try openOptions(revealing: row, ui: ui)
        try ui.expectLabel(row, "Download")
        try ui.closeSheet("Song Options")
        ui.capture("player-download-removed")

        // The Downloads screen no longer lists the song.
        try ui.closePlayer()
        try ui.tap(ui.app.buttons["tab.library"].firstMatch)
        let card = ui.app.buttons["library.downloads"]
        try ui.reveal(card)
        try ui.wait("The Library card counts no downloads") { card.value as? String == "Keep music on this device." }
        try ui.tap(card)
        try ui.wait("The Library card opens Downloads") { ui.app.navigationBars["Downloads"].exists }
        let summary = ui.app.staticTexts["downloads.summary"]
        try ui.wait("Downloads lists no songs") { summary.exists && summary.label.hasPrefix("0 songs on this device") }
        XCTAssertFalse(ui.app.buttons["downloads.play.\(AppUIFixture.blindingLights)"].exists)
        XCTAssertTrue(ui.element("downloads.empty").exists)

        // Remove demotes rather than deletes: the song is back in Cached songs.
        try ui.tap(ui.app.navigationBars["Downloads"].buttons.firstMatch)
        try ui.wait("Back must return to the Library root") {
            !ui.app.navigationBars["Downloads"].exists && ui.app.buttons["library.likes"].exists
        }
        XCTAssertFalse(ui.app.buttons["library.cachedSongs"].exists)
        try ui.openSettings()
        try ui.openSettingsPage(.library)
        let storage = ui.app.buttons["settings.storage"]
        try ui.reveal(storage, maxSwipes: 16)
        try ui.tap(storage)
        try ui.wait("Settings must open Storage") { ui.app.navigationBars["Storage"].exists }
        let cached = ui.app.buttons["storage.cachedSongs"]
        try ui.reveal(cached, maxSwipes: 16)
        try ui.tap(cached)
        try ui.wait("Storage must open Cached songs") { ui.app.navigationBars["Cached Songs"].exists }
        let cachedRow = ui.app.buttons["cachedSongs.play.\(AppUIFixture.blindingLights)"]
        try ui.wait("Cached songs has read the inventory") { ui.app.staticTexts["cachedSongs.count"].exists }
        try ui.reveal(cachedRow)
        XCTAssertTrue(cachedRow.label.contains("Blinding Lights"), cachedRow.label)
        XCTAssertTrue(cachedRow.isEnabled, "The demoted download remains playable from its cached file")
        for (title, parent) in [("Cached Songs", "Storage"), ("Storage", SettingsPageID.library.title)] {
            let bar = ui.app.navigationBars[title]
            let back = bar.buttons[parent].exists ? bar.buttons[parent] : bar.buttons["Back"]
            try ui.tap(back)
            try ui.wait("Back must return to \(parent)") { ui.app.navigationBars[parent].exists }
        }
        try ui.tap(ui.app.buttons["settings.done"])
        try ui.wait("Closing Settings must return to the app") { !ui.app.buttons["settings.done"].exists }
    }

    func testWithoutADownloadCenterTheButtonStaysInPlaceDisabled() throws {
        let ui = try launchPlayer()
        let button = ui.app.buttons["player.download"]
        let airPlay = ui.app.buttons["player.airplay"]
        try ui.requireHittable(button)
        XCTAssertFalse(button.isEnabled, "The plain fixture has no local audio store, so downloads are unavailable")
        XCTAssertEqual(button.label, "Download Unavailable")
        XCTAssertGreaterThanOrEqual(button.frame.width + 1e-6, 44)
        XCTAssertGreaterThanOrEqual(button.frame.height + 1e-6, 44)
        XCTAssertEqual(button.frame.minX, airPlay.frame.maxX + 8, accuracy: 1)
        XCTAssertEqual(button.frame.midY, airPlay.frame.midY, accuracy: 1)
        XCTAssertLessThan(button.frame.maxX + 44, ui.app.buttons["player.lyrics"].frame.minX, "The spacer keeps the pairs apart")
        ui.capture("player-download-unavailable")
    }

    /// Medium-detent hit testing can expose a row below the viewport; expand before scrolling to it.
    private func openOptions(revealing row: XCUIElement, ui: AppUITestDriver) throws {
        try ui.openPlayerMenu()
        let list = ui.app.scrollViews["player.options.list"]
        let sheet = ui.app.otherElements["player.options.sheet"]
        let top = sheet.frame.minY
        if list.exists { list.swipeUp(velocity: .slow) }
        try ui.wait("More expands before revealing its Download row") {
            sheet.frame.minY < top - 60 || sheet.frame.minY < 120
        }
        try ui.reveal(row)
    }

    private func launchPlayer(arguments: [String] = []) throws -> AppUITestDriver {
        let ui = AppUITestDriver(testCase: self, prefix: "player-download")
        addTeardownBlock { await ui.finish() }
        XCUIDevice.shared.orientation = .portrait
        ui.app.launchArguments = ["--uitesting", "--seed-ui", "--skip-welcome", "--reset-ui", "--player"] + arguments
            + ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        ui.app.launchEnvironment = ["GANABAJANA_TEST_STORE": ui.storeName]
        ui.app.launch()
        // The cache fixture publishes its files before the player is presented.
        try ui.requireHittable(ui.app.buttons["player.close"], timeout: 25)
        return ui
    }
}

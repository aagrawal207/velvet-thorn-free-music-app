import UIKit
import XCTest

/// The player's More sheet after R14: row order, the share rows and card preview, the downloaded row, and the
/// equalizer sheet with a per-song override that survives skipping away and back.
@MainActor
final class GanaBajanaPlayerMoreUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testMoreSheetLeadsWithDislikeAndSharingAndKeepsEveryRowInOrder() throws {
        let ui = try launchPlayer()
        try openMore(ui)
        // The fixture song is liked, so Dislike is hidden and Share song leads.
        XCTAssertFalse(ui.app.buttons["player.options.dislike"].exists)
        let order = ["player.options.share", "player.options.details", "player.options.album",
                     "player.options.artist", "player.options.playlist", "player.options.equalizer", "player.sleepTimer",
                     "player.options.audioQuality", "player.options.reloadAudioQuality"]
        // The options list is a plain stack, so every row has a frame at once and their order is their minY order.
        let frames = order.map { id -> CGFloat in
            let row = ui.element(id)
            XCTAssertTrue(row.exists, id)
            return row.frame.minY
        }
        for index in 1..<order.count {
            XCTAssertGreaterThan(frames[index], frames[index - 1], "\(order[index]) follows \(order[index - 1])")
        }
        let share = ui.app.buttons["player.options.share"]
        try ui.reveal(share, direction: .down)
        XCTAssertEqual(share.label, "Share Song")
        XCTAssertFalse(ui.app.buttons["player.options.shareCard"].exists)
        XCTAssertGreaterThanOrEqual(share.frame.height + 1e-6, 44)
        let equalizer = ui.app.buttons["player.options.equalizer"]
        try ui.reveal(equalizer)
        XCTAssertEqual(equalizer.label, "Equalizer")
        XCTAssertEqual(equalizer.value as? String, "Off")
        try ui.reveal(share, direction: .down)
        capture(ui, "more-sheet-top")

        try ui.tap(share)
        try ui.wait("Sharing opens the preview before the system sheet") { ui.app.navigationBars["Share Song"].exists }
        let preview = ui.element("songShare.preview")
        try ui.wait("The card must finish rendering", timeout: 15) { preview.exists && preview.label.hasPrefix("Song card for") }
        XCTAssertGreaterThan(preview.frame.width, 200)
        XCTAssertEqual(preview.frame.height / preview.frame.width, 1350.0 / 1080.0, accuracy: 0.02, "The preview keeps the 4:5 card")
        try ui.requireHittable(ui.app.buttons["songShare.share"])
        XCTAssertTrue(ui.app.buttons["songShare.linkOnly"].exists)
        capture(ui, "share-card-preview")
        try ui.tap(ui.app.buttons["player.options.back"])
        try ui.wait("Back returns to Song options") { ui.app.navigationBars["Song Options"].exists }
        try ui.closeSheet("Song Options")

        // Unliking offers Dislike above the share rows, with its plain explanation.
        let like = ui.app.buttons["player.like"]
        try ui.tap(like)
        try ui.wait("The heading must unlike the song") { like.label == "Like this song" }
        try openMore(ui)
        let dislike = ui.app.buttons["player.options.dislike"]
        try ui.reveal(dislike, direction: .down)
        XCTAssertEqual(dislike.label, "Don't Recommend This Song")
        XCTAssertEqual(dislike.value as? String, "Keeps this song out of mixes and radio.")
        XCTAssertLessThan(dislike.frame.minY, ui.app.buttons["player.options.share"].frame.minY)
        capture(ui, "more-sheet-dislike")
        try ui.closeSheet("Song Options")
    }

    func testDownloadedRowKeepsItsFilledGlyphAndAsksBeforeRemoving() throws {
        let ui = try launchPlayer(arguments: ["--cache-fixture"])
        try openMore(ui)
        let row = ui.app.buttons["player.options.download"]
        try ui.reveal(row)
        XCTAssertEqual(row.label, "Download")
        try ui.tap(row)
        try ui.wait("The complete cached copy is promoted", timeout: 15) { row.label == "Downloaded" }
        XCTAssertEqual(row.value as? String, "Remove Download")
        try ui.reveal(row)
        let shot = ui.app.screenshot()
        let pixels = try ScreenPixels(shot, frame: ui.app.frame)
        // The glyph column is 28 points wide after the row's 16-point inset.
        var coral = 0
        var x = row.frame.minX + 16
        while x < row.frame.minX + 44 {
            var y = row.frame.midY - 12
            while y < row.frame.midY + 12 {
                if pixels.color(at: CGPoint(x: x, y: y)).isCoral { coral += 1 }
                y += 1
            }
            x += 1
        }
        XCTAssertGreaterThan(coral, 40, "The downloaded row shows the filled accent arrow")
        capture(ui, "more-sheet-downloaded")

        try ui.tap(row)
        let remove = ui.app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@",
                                                         "player.options.download.remove", "Remove Download")).firstMatch
        try ui.wait("Removing asks first") { remove.exists }
        XCTAssertEqual(row.label, "Downloaded", "Asking changes nothing yet")
        try ui.tap(remove)
        try ui.wait("Remove download returns the idle row") { row.label == "Download" }
        try ui.closeSheet("Song Options")
    }

    func testEqualizerFromMoreKeepsAPerSongOverrideAcrossASkip() throws {
        let ui = try launchPlayer()
        let first = try currentTrackID(ui)
        try openEqualizer(ui)
        try ui.setSwitch("equalizer.enabled", to: true)
        let preset = ui.app.buttons["equalizer.preset"]
        try ui.reveal(preset, direction: .down)
        try ui.tap(preset)
        try ui.tap(ui.app.buttons["Bass Boost"])
        try ui.expectValue(preset, "Bass Boost")
        let description = ui.element("equalizer.preset.description")
        XCTAssertEqual(description.label, "Bass boost: more thump for hip hop and EDM")

        try ui.setSwitch("equalizer.song.toggle", to: true)
        let treble = ui.app.sliders["equalizer.simple.treble"]
        try ui.reveal(treble)
        treble.adjust(toNormalizedSliderPosition: 0.85)
        try ui.wait("Treble must boost this song") { (treble.value as? String)?.hasPrefix("+") == true }
        let songTreble = try XCTUnwrap(treble.value as? String)
        try ui.expectValue(preset, "Custom")
        capture(ui, "equalizer-sheet-song")

        // More controls opens the full page on the same song settings; Advanced lists named bands.
        let more = ui.app.buttons["equalizer.moreControls"]
        try ui.reveal(more)
        try ui.tap(more)
        try ui.wait("More controls pushes the full equalizer") { ui.element("settings.equalizer.content").exists }
        try selectMode("Advanced", ui: ui)
        let band = ui.element("equalizer.band.8")
        try ui.reveal(band)
        XCTAssertEqual(band.label, "Treble, 8 kHz")
        XCTAssertTrue((band.value as? String)?.hasPrefix("+") == true, "The song's treble boost reaches the 8 kHz band")
        capture(ui, "equalizer-advanced-song")
        try selectMode("Simple", ui: ui)
        try ui.tap(ui.app.buttons["player.options.back"])
        try ui.tap(ui.app.buttons["player.options.back"])
        try ui.wait("Back returns to Song options") { ui.app.navigationBars["Song Options"].exists }
        let row = ui.app.buttons["player.options.equalizer"]
        try ui.reveal(row)
        try ui.expectValue(row, "This Song")
        try ui.closeSheet("Song Options")

        // The next song follows the global Bass boost; coming back restores the song's own curve.
        try ui.tap(ui.app.buttons["player.next"])
        try ui.wait("The player must move to another song") { (try? self.currentTrackID(ui)) != first }
        try openMore(ui)
        try ui.reveal(row)
        try ui.expectValue(row, "Bass Boost")
        try ui.closeSheet("Song Options")
        for _ in 0..<3 where (try? currentTrackID(ui)) != first { try ui.tap(ui.app.buttons["player.previous"]) }
        try ui.wait("Previous must return to the first song") { (try? self.currentTrackID(ui)) == first }
        try openEqualizer(ui)
        try ui.expectSwitch("equalizer.song.toggle", isOn: true)
        try ui.reveal(treble)
        try ui.expectValue(treble, songTreble)

        // Turning the toggle off returns the song to the global setting.
        try ui.setSwitch("equalizer.song.toggle", to: false)
        try ui.reveal(preset, direction: .down)
        try ui.expectValue(preset, "Bass Boost")
        try ui.tap(ui.app.buttons["player.options.back"])
        try ui.reveal(row)
        try ui.expectValue(row, "Bass Boost")
    }

    func testRecommendationExclusionPersistsAndCanBeUndoneWithoutBlockingExplicitPlayback() throws {
        let ui = try launchPlayer()
        try ui.expectCurrentTrack(AppUIFixture.tumHiHo)
        try ui.tap(ui.app.buttons["player.like"])
        try ui.wait("The liked song is unliked before exclusion") {
            ui.app.buttons["player.like"].label == "Like this song"
        }
        try openMore(ui)
        let exclusion = ui.app.buttons["player.options.dislike"]
        try ui.reveal(exclusion, direction: .down)
        XCTAssertEqual(exclusion.label, "Don't Recommend This Song")
        XCTAssertEqual(exclusion.value as? String, "Keeps this song out of mixes and radio.")
        try ui.tap(exclusion)
        try ui.wait("Excluding closes More") { !ui.app.otherElements["player.options.sheet"].exists }
        try ui.expectCurrentTrack(AppUIFixture.tumHiHo)

        ui.app.terminate()
        ui.app.launchArguments.removeAll { $0 == "--reset-ui" }
        ui.app.launch()
        try ui.requireHittable(ui.app.buttons["player.close"], timeout: 25)
        try openMore(ui)
        try ui.reveal(exclusion, direction: .down)
        XCTAssertEqual(exclusion.label, "Allow Recommendations")
        XCTAssertEqual(exclusion.value as? String, "Lets this song back into mixes and radio.")
        try ui.closeSheet("Song Options")
        try ui.tap(ui.app.buttons["player.playPause"])
        try ui.wait("Explicit playback of an excluded song is still allowed") {
            ui.app.buttons["player.playPause"].label == "Pause"
        }
        try ui.expectCurrentTrack(AppUIFixture.tumHiHo)
        try ui.tap(ui.app.buttons["player.playPause"])
        try ui.closePlayer()
        try ui.selectTab("recap")
        let recents = ui.app.buttons["recap.recent.toggle"]
        try ui.reveal(recents)
        try ui.tap(recents)
        let menu = ui.element("recap.recent").buttons["track.options.\(AppUIFixture.tumHiHo)"].firstMatch
        try ui.reveal(menu)
        try ui.tap(menu)
        let allow = ui.app.buttons["Allow Recommendations"]
        try ui.requireHittable(allow)
        XCTAssertFalse(ui.app.buttons["Don't Recommend This Song"].exists)
        try ui.tap(allow)
        try ui.tap(menu)
        try ui.requireHittable(ui.app.buttons["Don't Recommend This Song"])
        XCTAssertFalse(ui.app.buttons["Allow Recommendations"].exists)
    }

    // MARK: - Helpers

    /// Opens More and expands it to the large detent, as the other More-sheet suites do, so reveal can scroll.
    private func openMore(_ ui: AppUITestDriver) throws {
        try ui.openExpandedPlayerMenu()
    }

    private func openEqualizer(_ ui: AppUITestDriver) throws {
        try openMore(ui)
        let row = ui.app.buttons["player.options.equalizer"]
        try ui.reveal(row)
        try ui.tap(row)
        try ui.wait("More must push the equalizer sheet") { ui.element("player.equalizer.content").exists }
        try ui.requireHittable(ui.app.switches["equalizer.enabled"])
    }

    private func selectMode(_ title: String, ui: AppUITestDriver) throws {
        let id = "equalizer.mode.\(title.lowercased())"
        let segment = ui.app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", id, title)).firstMatch
        try ui.reveal(segment, direction: .down)
        try ui.tap(segment)
        try ui.wait("\(title) must be selected") { segment.isSelected }
    }

    private func currentTrackID(_ ui: AppUITestDriver) throws -> String {
        let title = ui.app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "player.track.")).firstMatch
        guard title.exists else { throw AppUIWorkflowFailure(message: "No current track title") }
        return title.identifier
    }

    private func capture(_ ui: AppUITestDriver, _ name: String) {
        ui.capture("player-more-\(name)")
    }

    private func launchPlayer(arguments: [String] = []) throws -> AppUITestDriver {
        let ui = AppUITestDriver(testCase: self, prefix: "player-more")
        addTeardownBlock { await ui.finish() }
        XCUIDevice.shared.orientation = .portrait
        ui.app.launchArguments = ["--uitesting", "--seed-ui", "--skip-welcome", "--reset-ui", "--player"] + arguments
            + ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        ui.app.launchEnvironment = ["GANABAJANA_TEST_STORE": ui.storeName]
        ui.app.launch()
        try ui.requireHittable(ui.app.buttons["player.close"], timeout: 25)
        return ui
    }
}

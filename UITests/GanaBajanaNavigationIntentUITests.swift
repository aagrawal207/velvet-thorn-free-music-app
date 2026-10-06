import Foundation
import XCTest

@MainActor
final class GanaBajanaNavigationIntentUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testSettingsAndSearchLibraryLinksReopenAfterBackAndKeepPlaybackIntact() throws {
        let ui = makeDriver()
        try ui.launch(additionalArguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"])
        try ui.searchAndPlayTumHiHo()
        try ui.openPlayer()
        try ui.waitForAdvance(from: 0, by: 1)
        try ui.pause()
        try ui.closePlayer()
        try ui.selectTab("home")
        try ui.openSettings()
        try ui.openSettingsPage(.discovery)
        for _ in 0..<2 {
            let customize = ui.app.buttons["settings.customizeHome"]
            try ui.reveal(customize, maxSwipes: 24)
            try ui.tap(customize)
            try ui.reveal(ui.app.switches["home.customization.show.charts"])
            try ui.setSwitch("home.customization.show.charts", to: false)
            try ui.setSwitch("home.customization.show.charts", to: true)
            try ui.tap(ui.app.navigationBars["Customize Home"].buttons.firstMatch)
            try ui.requireHittable(customize)
        }
        try ui.tap(ui.app.buttons["settings.done"])
        try ui.expectLabel(ui.app.buttons["miniPlayer.playPause"], "Play")
        XCTAssertTrue(ui.app.buttons["miniPlayer.open"].label.contains("Tum Hi Ho"))
        try ui.assertMiniPlayerAboveTabs()

        try ui.selectTab("search")
        try ui.clearSearch()
        try ui.dismissSearchKeyboard()
        // The playlist shortcut is Search's remaining local library link; liked songs open from the Library tab.
        let playlistShortcut = ui.app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search.library.playlist.")).firstMatch
        for _ in 0..<2 {
            try ui.reveal(playlistShortcut, direction: .down)
            try ui.tap(playlistShortcut)
            try ui.reveal(ui.app.buttons["track.play.\(AppUIFixture.tumHiHo)"])
            try ui.assertMiniPlayerAboveTabs()
            XCTAssertEqual(ui.element("miniPlayer.container").frame.height, 64, accuracy: 1)
            try ui.tap(ui.app.navigationBars[AppUIFixture.seededPlaylist].buttons.firstMatch)
            try ui.requireHittable(playlistShortcut)
            XCTAssertFalse(ui.app.buttons["search.filter.songs"].exists)
        }

        try ui.selectTab("library")
        for _ in 0..<2 {
            try ui.reveal(ui.app.buttons["library.likes"], direction: .down)
            try ui.tap(ui.app.buttons["library.likes"])
            try ui.reveal(ui.app.buttons["track.play.\(AppUIFixture.tumHiHo)"])
            try ui.assertMiniPlayerAboveTabs()
            try ui.tap(ui.app.navigationBars["Liked Songs"].buttons["Back"])
            try ui.requireHittable(ui.app.buttons["library.createPlaylist"])
        }
        ui.capture("native-local-links-back-and-reopen")
    }

    func testSearchReselectionPopsLocalSpotlightAndKeepsItsNewFocusRequest() throws {
        let ui = makeDriver()
        try ui.launch(additionalArguments: ["--artist-spotlight-fixture", "--search-results", "A. R. Rahman"])
        for _ in 0..<2 {
            try ui.waitForSearchResults()
            try ui.tap(ui.app.buttons["search.featuredArtist"])
            try ui.reveal(ui.app.buttons["artist.spotlight.open"])
            try ui.tap(ui.app.buttons["artist.spotlight.open"])
            try ui.reveal(ui.app.staticTexts["artist.spotlight.countProvenance"])
            try ui.selectTab("search")
            try ui.wait("Reselect must pop both artist destinations and focus the existing Search draft") {
                ui.app.textFields["search.field"].exists && ui.app.keyboards.firstMatch.exists
                    && !ui.app.staticTexts["artist.spotlight.countProvenance"].exists
            }
            try ui.expectValue(ui.app.textFields["search.field"], "A. R. Rahman")
            try ui.requireHittable(ui.app.buttons["search.filter.songs"])
            try ui.dismissSearchKeyboard()
        }
        ui.capture("local-spotlight-search-reselection")
    }

    func testNameOnlyPlayerArtistOpensAfterEmptySearchDiscoveryReappears() throws {
        let ui = makeDriver()
        try ui.launch(additionalArguments: ["--artist-navigation-fixture"])
        try ui.selectTab("search")
        try ui.requireHittable(ui.app.buttons["search.radio.open"])
        XCTAssertFalse(ui.app.buttons["search.filter.songs"].exists)
        XCTAssertFalse(ui.app.keyboards.firstMatch.exists)
        try ui.openPlayer()
        try chooseNameOnlyArtist(ui)
        try ui.wait("Search discovery must reappear while the name-only artist lookup is still loading") {
            ui.app.textFields["search.field"].exists && ui.app.buttons["search.radio.open"].exists
                && !ui.app.buttons["player.close"].exists
        }
        try ui.expectArtistPage(named: "Norah Jones")
        try ui.reveal(ui.app.buttons["track.play.fixture.setup.norah.2002"])
        XCTAssertEqual(ui.app.staticTexts["collection.title"].label, "Norah Jones")
        XCTAssertFalse(ui.element("player.browse.sheet").exists)
        XCTAssertFalse(ui.app.keyboards.firstMatch.exists)
        XCTAssertFalse(ui.app.buttons["player.close"].exists)
        ui.capture("name-only-artist-survives-search-reappearance")
    }

    func testSearchReselectionPopsRadioBrowseAndFocusesTheBlankRadioLedRoot() throws {
        let ui = makeDriver()
        try ui.launch()
        try ui.selectTab("search")
        for _ in 0..<2 {
            let radio = ui.app.buttons["search.radio.open"]
            try ui.reveal(radio)
            try ui.tap(radio)
            try ui.wait("Radio must be a pushed Search destination") { ui.app.navigationBars["Radio"].exists }
            try ui.requireHittable(ui.app.searchFields["Songs or artists"])
            try ui.requireHittable(ui.app.buttons["radio.search.type"])
            try ui.expectValue(ui.app.buttons["radio.search.type"], "Songs")
            XCTAssertFalse(ui.app.buttons["player.close"].exists)
            try ui.selectTab("search")
            try ui.wait("Reselection must retire the local radio path and keep the new focus request") {
                ui.app.textFields["search.field"].exists && ui.app.keyboards.firstMatch.exists
                    && !ui.app.navigationBars["Radio"].exists
            }
            let field = ui.app.textFields["search.field"]
            XCTAssertTrue((field.value as? String ?? "").isEmpty || field.value as? String == field.placeholderValue)
            try ui.requireHittable(field)
            try ui.requireHittable(ui.app.buttons["search.radio.open"])
            XCTAssertFalse(ui.app.buttons["search.filter.songs"].exists)
            XCTAssertFalse(ui.app.searchFields["Songs or artists"].exists)
            XCTAssertFalse(ui.element("search.radio.content").exists)
            try ui.dismissSearchKeyboard()
        }
        ui.capture("radio-search-reselection-keeps-blank-root-focus")
    }

    func testReopeningATypedRecentAlbumSupersedesAnOlderArtistLookup() throws {
        let ui = makeDriver()
        try ui.launch(additionalArguments: ["--artist-navigation-fixture", "--slow-search"])
        try ui.search("Arijit")
        try ui.waitForSearchResults()
        try ui.selectSearchFilter("albums")
        let album = ui.app.buttons["collection.\(AppUIFixture.album)"]
        try ui.requireHittable(album)
        try ui.tap(album)
        try ui.wait("Opening the album result must establish its typed recent entry") {
            ui.app.staticTexts["ALBUM"].exists && ui.app.buttons["collection.play"].exists
        }
        try ui.tap(ui.app.navigationBars.buttons.firstMatch)
        try ui.requireHittable(ui.app.textFields["search.field"])
        try ui.clearSearch()
        try ui.dismissSearchKeyboard()
        let recent = ui.app.buttons["search.recent.collection:album:\(AppUIFixture.album)"]
        try ui.reveal(recent)
        XCTAssertTrue(recent.label.contains("Evening favorites, Album"))
        XCTAssertFalse(ui.app.buttons["search.recent.arijit"].exists)

        try ui.openPlayer()
        try chooseNameOnlyArtist(ui)
        try ui.wait("The recent result must remain actionable while the name-only artist lookup is pending") {
            recent.exists && recent.isHittable && !ui.app.buttons["player.close"].exists
        }
        recent.tap()
        try ui.wait("The newer recent-result tap must open its album immediately") {
            ui.app.staticTexts["ALBUM"].exists && ui.app.staticTexts["collection.title"].label == "Evening favorites"
        }
        let unexpectedArtist = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated {
                ui.app.buttons["collection.follow"].exists && ui.app.staticTexts["collection.title"].label == "Norah Jones"
            }
        }, object: nil)
        unexpectedArtist.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [unexpectedArtist], timeout: 6), .completed,
                       "The delayed artist response must not replace the newer album navigation")
        XCTAssertEqual(ui.app.staticTexts["collection.title"].label, "Evening favorites")
        XCTAssertTrue(ui.app.staticTexts["ALBUM"].exists)
        XCTAssertFalse(ui.app.keyboards.firstMatch.exists)
        try ui.tap(ui.app.navigationBars.buttons.firstMatch)
        try ui.requireHittable(ui.app.textFields["search.field"])
        let field = ui.app.textFields["search.field"]
        XCTAssertTrue((field.value as? String ?? "").isEmpty || field.value as? String == field.placeholderValue)
        XCTAssertFalse(ui.app.buttons["search.filter.songs"].exists)
        ui.capture("typed-recent-album-wins-over-stale-artist")
    }

    private func chooseNameOnlyArtist(_ ui: AppUITestDriver) throws {
        let artist = ui.app.buttons["player.artistName"]
        try ui.expectLabel(artist, "Album and artists, Norah Jones")
        try ui.tap(artist)
        try ui.wait("A recording with an album must offer the combined chooser") {
            ui.app.navigationBars["Album and Artists"].exists && ui.element("player.browse.sheet").exists
        }
        let album = ui.app.buttons["player.browse.album"]
        try ui.requireHittable(album)
        try ui.expectLabel(album, "Go to Album")
        try ui.expectValue(album, "Come Away With Me")
        let credit = ui.app.buttons["player.artist.0"]
        try ui.requireHittable(credit)
        try ui.expectLabel(credit, "Norah Jones")
        try ui.tap(credit)
    }

    private func makeDriver() -> AppUITestDriver {
        let ui = AppUITestDriver(testCase: self, prefix: "navigation-intent")
        addTeardownBlock { await ui.finish() }
        return ui
    }
}

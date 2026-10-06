import Foundation
import XCTest

@MainActor
final class GanaBajanaSearchDiscoveryUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testSearchTapDoneToolbarAndReselectNavigationKeepTheQuery() throws {
        let ui = makeDriver()
        try ui.launch()
        try tapSearch(ui)
        let field = ui.app.textFields["search.field"]
        try ui.requireHittable(ui.app.buttons["search.dismissKeyboard"])
        let toolbarDone = ui.app.buttons["search.dismissKeyboard.toolbar"]
        try ui.requireHittable(toolbarDone)
        XCTAssertGreaterThanOrEqual(toolbarDone.frame.height, 44 - 1e-6)
        field.typeText("Arijit")
        try ui.waitForSearchResults()
        XCTAssertLessThanOrEqual(toolbarDone.frame.maxY, ui.app.keyboards.firstMatch.frame.minY + 1)
        ui.capture("search-keyboard-bottom-dismiss-iphone17pro")
        try ui.tap(toolbarDone)
        try expectKeyboardDismissed(ui)
        XCTAssertEqual(field.value as? String, "Arijit")

        try ui.selectSearchFilter("albums")
        let album = ui.app.buttons["collection.\(AppUIFixture.album)"]
        try ui.reveal(album)
        try ui.tap(field)
        try ui.wait("Editing must show the keyboard") { ui.app.keyboards.firstMatch.exists }
        try ui.tap(album)
        try ui.wait("Opening a result must dismiss the keyboard") {
            ui.app.staticTexts["ALBUM"].exists && !ui.app.keyboards.firstMatch.exists
        }
        let back = ui.app.navigationBars.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "Back", "Search")).firstMatch
        try ui.tap(back)
        try ui.requireHittable(field)
        XCTAssertEqual(field.value as? String, "Arijit")
        XCTAssertFalse(ui.app.keyboards.firstMatch.exists, "Back is not a new Search tap")
        try ui.tap(album)
        try ui.wait("The album detail must reopen") { ui.app.staticTexts["ALBUM"].exists }
        try tapSearch(ui)
        XCTAssertFalse(ui.app.staticTexts["ALBUM"].exists, "Search reselect must pop the search stack")
        try expectSearchAtTop(ui)
        XCTAssertEqual(field.value as? String, "Arijit")
        try ui.tap(ui.app.buttons["search.dismissKeyboard"])
        try expectKeyboardDismissed(ui)
        XCTAssertEqual(field.value as? String, "Arijit")
        ui.capture("search-discovery-keyboard-dismissed-query-preserved")
    }

    func testSearchReselectPopsScrolledRadioAndFocusesTheField() throws {
        let ui = makeDriver()
        try ui.launch(additionalArguments: ["--seed-radio-fixture", "-UIPreferredContentSizeCategoryName",
                                           "UICTContentSizeCategoryAccessibilityXXXL"])
        try openRadioDiscovery(ui)
        let searchType = ui.app.buttons["radio.search.type"]
        try ui.requireHittable(searchType)
        let content = ui.element("search.radio.content")
        let navigation = ui.app.navigationBars["Radio"]
        for _ in 0..<8 {
            if !searchType.exists || searchType.frame.maxY < max(content.frame.minY, navigation.frame.maxY) { break }
            content.swipeUp()
        }
        XCTAssertTrue(!searchType.exists || searchType.frame.maxY < max(content.frame.minY, navigation.frame.maxY),
                      "The test must begin scrolled away from the Radio search controls")
        XCTAssertFalse(ui.app.buttons["miniPlayer.open"].exists, "Browsing and scrolling must not start radio")
        try tapSearch(ui)
        try expectSearchAtTop(ui)
        XCTAssertFalse(ui.app.navigationBars["Radio"].exists)
        XCTAssertFalse(ui.app.searchFields["Songs or artists"].exists)
        XCTAssertFalse(ui.app.buttons["search.filter.songs"].exists)
        XCTAssertTrue(ui.app.keyboards.firstMatch.exists)
        let field = ui.app.textFields["search.field"]
        XCTAssertTrue((field.value as? String) == "" || (field.value as? String) == field.placeholderValue)
        field.typeText("Arijit")
        try ui.waitForSearchResults()
        try ui.tap(ui.app.buttons["search.dismissKeyboard"])
        try expectKeyboardDismissed(ui)
        try tapSearch(ui)
        try expectSearchAtTop(ui)
        XCTAssertEqual(field.value as? String, "Arijit")
        XCTAssertTrue(ui.app.keyboards.firstMatch.exists)
        ui.capture("search-reselect-scrolls-to-top-and-keeps-query")
    }

    /// R13 item 9: a playlist chosen from the Playlists filter must open with its songs, not the empty state.
    func testPlaylistSearchResultOpensWithItsSongs() throws {
        let ui = makeDriver()
        try ui.launch()
        try ui.search("Arijit")
        try ui.waitForSearchResults()
        try ui.selectSearchFilter("playlists")
        let playlist = ui.app.buttons["collection.\(AppUIFixture.album)"]
        try ui.reveal(playlist)
        XCTAssertTrue(playlist.label.contains("Evening favorites"), playlist.label)
        try ui.tap(playlist)
        let rows = ui.app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "track.play."))
        try ui.wait("The playlist page must list its songs") {
            ui.app.staticTexts["PLAYLIST"].exists && ui.app.staticTexts["collection.title"].label == "Evening favorites"
                && rows.count >= 1
        }
        XCTAssertFalse(ui.app.staticTexts["No Music in This Collection"].exists)
        XCTAssertFalse(ui.app.staticTexts["Loading"].exists)
        try ui.reveal(ui.app.buttons["track.play.\(AppUIFixture.tumHiHo)"])
        XCTAssertEqual(rows.count, 5, "Every provided song is a row")
        let summary = ui.app.staticTexts["collection.summary"]
        try ui.reveal(summary, maxSwipes: 12)
        XCTAssertTrue(summary.label.hasPrefix("5 songs"), summary.label)
        XCTAssertTrue(ui.app.buttons["collection.play"].isEnabled)
        ui.capture("search-discovery-playlist-result-opens-with-songs")
        try ui.tap(ui.app.buttons["track.play.\(AppUIFixture.tumHiHo)"])
        try ui.wait("Playing from the playlist must update the mini-player") {
            ui.app.buttons["miniPlayer.open"].label.contains("Tum Hi Ho")
        }
    }

    func testProgrammaticSearchShowsResultsWithoutRequestingKeyboard() throws {
        let ui = makeDriver()
        try ui.launch(additionalArguments: ["--search-results", "Tum Hi Ho"])
        try ui.waitForSearchResults()
        XCTAssertEqual(ui.app.textFields["search.field"].value as? String, "Tum Hi Ho")
        XCTAssertTrue(ui.app.tabBars.buttons["Search"].isSelected)
        XCTAssertFalse(ui.app.keyboards.firstMatch.exists)
        XCTAssertFalse(ui.app.buttons["search.dismissKeyboard"].exists)
        try tapSearch(ui)
        XCTAssertEqual(ui.app.textFields["search.field"].value as? String, "Tum Hi Ho")
        try ui.tap(ui.app.buttons["track.play.\(AppUIFixture.tumHiHo)"])
        try expectKeyboardDismissed(ui)
        try ui.wait("Playing a result must update the mini-player") {
            ui.app.buttons["miniPlayer.open"].label.contains("Tum Hi Ho")
        }
    }

    func testLikedSongResultMenuRequiresRemovingTheLikeBeforeOfferingDislike() throws {
        let ui = makeDriver()
        try ui.launch()
        try ui.search("Tum Hi Ho")
        try ui.waitForSearchResults()
        let menu = ui.app.buttons["track.options.\(AppUIFixture.tumHiHo)"]
        try ui.tap(menu)
        try ui.requireHittable(ui.app.buttons["Remove from Liked Songs"])
        XCTAssertFalse(ui.app.buttons["Don't Recommend This Song"].exists)
        try ui.tap(ui.app.buttons["Remove from Liked Songs"])
        try ui.tap(menu)
        try ui.requireHittable(ui.app.buttons["Don't Recommend This Song"])
        XCTAssertTrue(ui.app.buttons["Like Song"].exists)
    }

    func testOnlyOpenedSongsBecomeRecentsAndSurviveRelaunchAndRemoval() throws {
        let ui = makeDriver()
        try ui.launch()
        try ui.search("Arijit")
        try ui.waitForSearchResults()
        try ui.clearSearch()
        try ui.tap(ui.app.buttons["search.dismissKeyboard"])
        try expectKeyboardDismissed(ui)
        try ui.reveal(ui.app.staticTexts["search.recents.empty"])
        XCTAssertFalse(ui.app.buttons["search.recents.clear"].exists, "Submitting a query does not open a result")
        try ui.search("Tum Hi")
        try ui.waitForSearchResults()
        try ui.tap(ui.app.buttons["track.play.\(AppUIFixture.tumHiHo)"])
        try expectKeyboardDismissed(ui)
        try ui.search("Blinding Lights")
        try ui.waitForSearchResults()

        try ui.relaunch()
        try ui.selectTab("search")
        let recent = ui.app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@", "search.recent.", "Tum Hi Ho, Song")).firstMatch
        try ui.reveal(recent)
        XCTAssertFalse(ui.app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "search.recent.", "Blinding Lights")).firstMatch.exists)
        let removalID = "search.recent.remove." + String(recent.identifier.dropFirst("search.recent.".count))
        try ui.tap(recent)
        try ui.wait("Reopening a recent song must play it without filling the query") {
            ui.app.buttons["miniPlayer.open"].label.contains("Tum Hi Ho")
        }
        let field = ui.app.textFields["search.field"]
        XCTAssertTrue((field.value as? String) == "" || (field.value as? String) == field.placeholderValue)
        XCTAssertFalse(ui.app.buttons["search.filter.songs"].exists)
        try ui.reveal(ui.app.buttons[removalID])
        try ui.tap(ui.app.buttons[removalID])
        try ui.reveal(ui.app.staticTexts["search.recents.empty"])
        try ui.relaunch()
        try ui.selectTab("search")
        try ui.reveal(ui.app.staticTexts["search.recents.empty"])
        XCTAssertFalse(recent.exists)
        try ui.selectTab("library")
        try ui.tap(ui.app.buttons["library.likes"])
        try ui.reveal(ui.app.staticTexts["5 songs"])
    }

    func testSongRadioContinuesWithGeneralAutoplayOffWithoutOpeningPlayerOrSearchRecents() throws {
        let ui = makeDriver()
        try ui.launch(additionalArguments: ["--seed-radio-fixture", "--cache-fixture"])
        try ui.openSettings()
        try ui.setSwitch("settings.autoplay", to: false)
        try ui.tap(ui.app.buttons["settings.done"])
        try openRadioDiscovery(ui)
        let song = ui.app.buttons["radio.suggestion.\(AppUIFixture.tumHiHo)"]
        try ui.reveal(song)
        XCTAssertEqual(song.label, "Start Tum Hi Ho Radio, Arijit Singh")
        try ui.tap(song)
        try ui.wait("The selected song must start radio while leaving its browse page visible") {
            ui.element("radio.session").exists && ui.app.buttons["miniPlayer.open"].label.contains("Tum Hi Ho")
        }
        try ui.expectLabel(ui.element("radio.session"), "Tum Hi Ho Radio")
        XCTAssertTrue(ui.app.navigationBars["Radio"].exists)
        XCTAssertFalse(ui.app.buttons["player.close"].exists)
        try ui.openPlayer()
        try ui.expectCurrentTrack(AppUIFixture.tumHiHo)
        try ui.waitForAdvance(from: 0, by: 1)
        try ui.openPlayerSheet("queue", title: "Queue")
        try ui.reveal(ui.element("queue.radio"), direction: .down)
        try ui.expectLabel(ui.element("queue.radio"), "Tum Hi Ho Radio")
        for id in [AppUIFixture.tumHiHo, AppUIFixture.kesariya, AppUIFixture.agarTumSaathHo,
                   AppUIFixture.blindingLights, AppUIFixture.shapeOfYou] {
            try ui.reveal(ui.queueSong(id: id))
        }
        let last = ui.app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "queue.play.4.")).firstMatch
        try ui.reveal(last)
        let lastID = String(last.identifier.dropFirst("queue.play.4.".count))
        try ui.tap(last)
        try ui.expectCurrentTrack(lastID)
        try ui.waitForAdvance(from: 0, by: 1)
        try ui.openPlayerSheet("queue", title: "Queue")
        let followup = ui.queueSong(id: "seedMore001")
        try ui.reveal(followup, maxSwipes: 24)
        XCTAssertEqual(followup.label, "Play Radio Follow Up 1, Radio Artist 1, Autoplay")
        try ui.reveal(ui.element("queue.radio"), direction: .down)
        try ui.expectLabel(ui.element("queue.radio"), "Tum Hi Ho Radio")
        ui.capture("search-discovery-song-radio-continued-with-autoplay-off")
        try ui.closeSheet("Queue")
        try ui.pause()
        try ui.closePlayer()
        try ui.tap(ui.app.navigationBars["Radio"].buttons["Back"])
        try ui.reveal(ui.app.staticTexts["search.recents.empty"])
        XCTAssertFalse(ui.app.buttons["search.recents.clear"].exists, "Radio has its own Listen Again history")
        try ui.openSettings()
        try ui.expectSwitch("settings.autoplay", isOn: false)
    }

    private func openRadioDiscovery(_ ui: AppUITestDriver) throws {
        try tapSearch(ui)
        if ui.app.buttons["search.clear"].exists { try ui.clearSearch() }
        try ui.tap(ui.app.buttons["search.dismissKeyboard"])
        try expectKeyboardDismissed(ui)
        let radio = ui.app.buttons["search.radio.open"]
        try ui.reveal(radio)
        try ui.tap(radio)
        try ui.wait("The Radio row must open the song and artist search page") {
            ui.app.navigationBars["Radio"].exists && ui.element("search.radio.content").exists
                && ui.app.searchFields["Songs or artists"].exists && !ui.app.textFields["search.field"].exists
        }
        XCTAssertFalse(ui.app.keyboards.firstMatch.exists)
    }

    private func tapSearch(_ ui: AppUITestDriver) throws {
        let button = ui.app.tabBars.buttons["Search"]
        let wasSelected = button.isSelected
        try ui.tap(button)
        if !wasSelected {
            XCTAssertFalse(ui.app.keyboards.firstMatch.exists, "The first tab tap opens discovery without a keyboard")
            try ui.tap(button)
        }
        try ui.wait("A Search tab reselect must focus the field and show the keyboard") {
            ui.app.textFields["search.field"].exists && ui.app.keyboards.firstMatch.exists
        }
        try ui.dismissKeyboardIntroduction()
    }

    private func expectKeyboardDismissed(_ ui: AppUITestDriver) throws {
        try ui.wait("Dismissing search editing must restore bottom navigation") {
            !ui.app.keyboards.firstMatch.exists && !ui.app.buttons["search.dismissKeyboard"].exists
                && ui.app.tabBars.buttons["Search"].exists && ui.app.tabBars.buttons["Search"].isHittable
        }
    }

    private func expectSearchAtTop(_ ui: AppUITestDriver) throws {
        let content = ui.app.scrollViews["search.content"]
        let field = ui.app.textFields["search.field"]
        let queryIsEmpty = (field.value as? String) == "" || (field.value as? String) == field.placeholderValue
        // The Radio row leads the empty start screen; the library shortcuts live in the Library tab.
        let first = ui.app.buttons[queryIsEmpty ? "search.radio.open" : "search.filter.songs"]
        try ui.wait("Search reselect must reveal the top anchor without a test scroll") {
            guard content.exists, first.exists else { return false }
            let viewport = content.frame
            let frame = first.frame
            return frame.minY >= viewport.minY - 1 && frame.minY <= viewport.minY + 24
                && frame.maxY <= viewport.maxY + 1
                && frame.intersection(viewport).height >= 43
        }
    }

    private func makeDriver() -> AppUITestDriver {
        let ui = AppUITestDriver(testCase: self, prefix: "search-discovery")
        addTeardownBlock { await ui.finish() }
        return ui
    }
}

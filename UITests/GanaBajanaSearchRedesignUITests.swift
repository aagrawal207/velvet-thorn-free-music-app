import Foundation
import XCTest

@MainActor
final class GanaBajanaSearchRedesignUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testBlankSearchStartsWithRadioPlaylistsAndRecentsWithoutLibraryCardsFiltersOrStaticSuggestions() throws {
        let ui = makeDriver()
        try launch(ui)
        try selectTab("search", ui: ui)
        try ui.requireHittable(ui.app.textFields["search.field"])
        XCTAssertFalse(ui.app.keyboards.firstMatch.exists, "The first Search tap should leave the keyboard closed")
        let radio = ui.app.buttons["search.radio.open"]
        try assertTarget(radio, ui: ui)
        // R13 item 3: liked, cached and library shortcuts belong to the Library tab now.
        for id in ["search.library.likes", "search.library.cached", "search.library.open"] {
            XCTAssertFalse(ui.app.buttons[id].exists, "\(id) must not return to the Search start screen")
        }
        let playlist = searchPlaylist(ui)
        try ui.reveal(playlist)
        XCTAssertTrue(playlist.label.contains(AppUIFixture.seededPlaylist))
        XCTAssertTrue(playlist.label.contains("Playlist"))
        XCTAssertGreaterThan(playlist.frame.minY, radio.frame.maxY - 1, "Radio leads, then the playlists")
        try ui.reveal(ui.app.staticTexts["search.recents.empty"])
        XCTAssertGreaterThan(ui.app.staticTexts["search.recents.empty"].frame.minY, playlist.frame.minY)
        assertNoFilters(ui)
        XCTAssertFalse(ui.app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search.suggestion.")).firstMatch.exists)
        XCTAssertFalse(ui.element("search.radio.content").exists)
        XCTAssertFalse(ui.app.searchFields["Songs or artists"].exists)
        XCTAssertFalse(ui.app.staticTexts["Start somewhere good"].exists)
        XCTAssertFalse(ui.app.staticTexts["Find somewhere good"].exists)
        XCTAssertFalse(ui.app.staticTexts["Recent searches"].exists)
        ui.capture("radio-led-blank-search")
    }

    func testAllResultKindsPersistIndependentlyAndRemovalAndClearSurviveRelaunch() throws {
        let ui = makeDriver()
        try launch(ui, arguments: ["--artist-spotlight-fixture"])
        try search("Tum Hi", ui: ui)
        try ui.waitForSearchResults()
        let song = ui.app.buttons["track.play.\(AppUIFixture.tumHiHo)"]
        XCTAssertTrue((song.value as? String)?.contains("Song") == true)
        try ui.tap(song)
        try ui.wait("The selected song must play") { ui.app.buttons["miniPlayer.open"].label.contains("Tum Hi Ho") }

        try replaceQuery("A. R. Rahman", ui: ui)
        try ui.requireHittable(ui.app.buttons["search.featuredArtist"])
        try ui.tap(ui.app.buttons["search.featuredArtist"])
        try ui.expectArtistPage(named: "A. R. Rahman")
        try backToSearch(ui)

        try replaceQuery("Arijit", ui: ui)
        try ui.waitForSearchResults()
        for filter in ["albums", "playlists"] {
            try ui.selectSearchFilter(filter)
            let result = ui.app.buttons["collection.\(AppUIFixture.album)"]
            try ui.requireHittable(result)
            XCTAssertTrue(result.label.contains(filter == "albums" ? "Album" : "Playlist"))
            try ui.tap(result)
            try ui.wait("The selected collection kind must open") {
                ui.app.staticTexts[filter == "albums" ? "ALBUM" : "PLAYLIST"].exists
            }
            try backToSearch(ui)
        }

        try launch(ui, reset: false, arguments: ["--artist-spotlight-fixture"])
        try selectTab("search", ui: ui)
        let expected = [
            (id: "collection:playlist:\(AppUIFixture.album)", title: "Evening favorites", kind: "Playlist"),
            (id: "collection:album:\(AppUIFixture.album)", title: "Evening favorites", kind: "Album"),
            (id: "collection:artist:UCfixtureARRahman0000001", title: "A. R. Rahman", kind: "Artist"),
            (id: "track:\(AppUIFixture.tumHiHo)", title: "Tum Hi Ho", kind: "Song")
        ]
        for item in expected {
            let recent = ui.app.buttons["search.recent.\(item.id)"]
            try ui.reveal(recent)
            XCTAssertTrue(recent.label.contains("\(item.title), \(item.kind)"))
            try assertTarget(recent, ui: ui)
        }
        XCTAssertEqual(recentButtons(ui).count, 4, "An album and playlist with the same provider ID must stay distinct")
        XCTAssertFalse(ui.app.buttons["search.recent.tum hi"].exists, "The opened song, not the query fragment, is saved")
        ui.capture("typed-recent-results-after-relaunch")

        let albumRemoval = ui.app.buttons["search.recent.remove.collection:album:\(AppUIFixture.album)"]
        try ui.reveal(albumRemoval)
        try assertTarget(albumRemoval, ui: ui)
        try ui.tap(albumRemoval)
        try ui.wait("Removing one kind must preserve the other collection with the same ID") {
            !ui.app.buttons["search.recent.collection:album:\(AppUIFixture.album)"].exists
                && ui.app.buttons["search.recent.collection:playlist:\(AppUIFixture.album)"].exists
        }
        try launch(ui, reset: false, arguments: ["--artist-spotlight-fixture"])
        try selectTab("search", ui: ui)
        try ui.reveal(ui.app.buttons["search.recents.clear"])
        XCTAssertEqual(recentButtons(ui).count, 3)
        try assertTarget(ui.app.buttons["search.recents.clear"], ui: ui)
        try ui.tap(ui.app.buttons["search.recents.clear"])
        try ui.reveal(ui.app.staticTexts["search.recents.empty"])
        XCTAssertFalse(ui.app.buttons["search.recents.clear"].exists)
        try launch(ui, reset: false, arguments: ["--artist-spotlight-fixture"])
        try selectTab("search", ui: ui)
        try ui.reveal(ui.app.staticTexts["search.recents.empty"])
        XCTAssertEqual(recentButtons(ui).count, 0)
        XCTAssertTrue(ui.app.buttons["search.radio.open"].exists)
        XCTAssertTrue(searchPlaylist(ui).exists)
    }

    func testRecentArtistDirectlyReopensAfterRelaunchAndBackKeepsTheQueryEmpty() throws {
        let ui = makeDriver()
        let arguments = ["--artist-spotlight-fixture"]
        try launch(ui, arguments: arguments)
        try search("A. R. Rahman", ui: ui)
        try ui.requireHittable(ui.app.buttons["search.featuredArtist"])
        try ui.selectSearchFilter("artists")
        let artist = ui.app.buttons["collection.UCfixtureARRahman0000001"]
        try ui.requireHittable(artist)
        XCTAssertTrue(artist.label.contains("Artist"))
        try ui.tap(artist)
        try ui.expectArtistPage(named: "A. R. Rahman")

        try launch(ui, reset: false, arguments: arguments)
        try selectTab("search", ui: ui)
        let recent = ui.app.buttons["search.recent.collection:artist:UCfixtureARRahman0000001"]
        try ui.reveal(recent)
        XCTAssertTrue(recent.label.contains("A. R. Rahman, Artist"))
        try ui.tap(recent)
        try ui.expectArtistPage(named: "A. R. Rahman")
        XCTAssertFalse(ui.app.keyboards.firstMatch.exists)
        try backToSearch(ui)
        assertEmptyQuery(ui)
        assertNoFilters(ui)
        XCTAssertFalse(ui.element("search.progress").exists, "Reopening a saved result does not run the catalog query again")
        try ui.reveal(recent)
        XCTAssertEqual(recentButtons(ui).count, 1, "Reopening updates recency without creating a duplicate")
    }

    func testSubmittingQueriesAndChangingFiltersDoesNotCreateRecentlyOpenedItems() throws {
        let ui = makeDriver()
        try launch(ui)
        try search("Arijit", ui: ui)
        try ui.waitForSearchResults()
        try ui.selectSearchFilter("albums")
        try ui.requireHittable(ui.app.buttons["collection.\(AppUIFixture.album)"])
        try clearQuery(ui)
        try ui.reveal(ui.app.staticTexts["search.recents.empty"])
        XCTAssertEqual(recentButtons(ui).count, 0)
        XCTAssertFalse(ui.app.buttons["search.recents.clear"].exists)
        try launch(ui, reset: false)
        try selectTab("search", ui: ui)
        try ui.reveal(ui.app.staticTexts["search.recents.empty"])
        XCTAssertEqual(recentButtons(ui).count, 0)
    }

    func testFiltersFollowExecutedQueriesAndRemainAvailableDuringFilterLoading() throws {
        let ui = makeDriver()
        try launch(ui, arguments: ["--slow-search"])
        try selectTab("search", ui: ui)
        assertNoFilters(ui)
        try replaceQuery("Tum Hi Ho", ui: ui)
        try ui.waitForSearchResults(timeout: 20)
        try assertTarget(ui.app.buttons["search.filter.songs"], ui: ui)
        try ui.selectSearchFilter("albums")
        try ui.wait("Changing filters must keep the filter row while the new response loads") {
            ui.element("search.progress").exists && ui.app.buttons["search.filter.albums"].isSelected
                && ui.app.buttons["search.filter.songs"].exists
        }
        try ui.requireHittable(ui.app.buttons["collection.\(AppUIFixture.album)"], timeout: 20)
        try ui.selectSearchFilter("songs")
        try ui.waitForSearchResults(timeout: 20)
        try ui.tap(ui.app.buttons["search.clear"])
        assertNoFilters(ui)
        ui.app.textFields["search.field"].typeText("Blinding Lights")
        try dismissKeyboard(ui)
        try ui.wait("A new query must replace the old song while it is loading") {
            ui.element("search.progress").exists && !ui.app.buttons["track.play.\(AppUIFixture.tumHiHo)"].exists
        }
        try ui.requireHittable(ui.app.buttons["track.play.\(AppUIFixture.blindingLights)"], timeout: 20)
        try assertTarget(ui.app.buttons["search.filter.songs"], ui: ui)
        try clearQuery(ui)
        assertNoFilters(ui)
    }

    func testSearchFailureKeepsFiltersAndRetryUsesTheCurrentQuery() throws {
        let ui = makeDriver()
        try launch(ui, arguments: ["--fail-search-once"])
        try search("Tum Hi Ho", ui: ui)
        try ui.requireHittable(ui.app.buttons["search.retry"])
        XCTAssertTrue(ui.app.staticTexts["Search couldn't finish"].exists)
        try assertTarget(ui.app.buttons["search.filter.songs"], ui: ui)
        try assertTarget(ui.app.buttons["search.retry"], ui: ui)
        try ui.tap(ui.app.buttons["search.retry"])
        try ui.requireHittable(ui.app.buttons["track.play.\(AppUIFixture.tumHiHo)"])
        XCTAssertFalse(ui.app.buttons["search.retry"].exists)
        XCTAssertEqual(ui.app.textFields["search.field"].value as? String, "Tum Hi Ho")
    }

    func testSearchReselectFromScrolledResultsAndNestedArtistFocusesOnce() throws {
        try verifyReselection()
    }

    func testSearchReselectWithReduceMotionFromScrolledResultsAndNestedArtistFocusesOnce() throws {
        try verifyReselection(arguments: ["--reduce-motion"])
    }

    func testSearchRootReselectKeepsLoadedResultsWithoutLoadingAgain() throws {
        let ui = makeDriver()
        try launch(ui, arguments: ["--slow-search"])
        try search("Arijit", ui: ui)
        try ui.waitForSearchResults(timeout: 20)
        let results = ui.app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "track.play."))
        let expectedIDs = [AppUIFixture.tumHiHo, AppUIFixture.kesariya, AppUIFixture.agarTumSaathHo]
            .map { "track.play.\($0)" }
        XCTAssertEqual(results.allElementsBoundByIndex.map(\.identifier), expectedIDs)
        XCTAssertFalse(ui.element("search.progress").exists)
        ui.capture("search-root-reselection-loaded-results")

        // The delayed fixture exposes a replacement request before identical result IDs can return.
        let reloadOrBlank = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated {
                ui.element("search.progress").exists || !ui.app.buttons[expectedIDs[0]].exists
            }
        }, object: nil)
        reloadOrBlank.isInverted = true
        try selectTab("search", ui: ui)
        XCTAssertEqual(XCTWaiter.wait(for: [reloadOrBlank], timeout: 2.5), .completed,
                       "Reselecting Search must retain its results throughout focus, without loading or blanking them")
        try expectFocusedSearchAtTop(ui, firstID: "search.filter.songs")
        XCTAssertEqual(ui.app.textFields["search.field"].value as? String, "Arijit")
        XCTAssertTrue(ui.app.buttons["search.filter.songs"].isSelected)
        XCTAssertFalse(ui.app.buttons["search.retry"].exists)
        ui.capture("search-root-reselection-retained-with-keyboard")
        try dismissKeyboard(ui)
        XCTAssertEqual(results.allElementsBoundByIndex.map(\.identifier), expectedIDs)
    }

    func testFindMusicFromEmptyLikedSongsReturnsToBlankSearch() throws {
        let ui = makeDriver()
        try launch(ui)
        try selectTab("library", ui: ui)
        try ui.tap(ui.app.buttons["library.likes"])
        try ui.wait("The Library card must open liked songs") { ui.app.navigationBars["Liked Songs"].exists }
        for id in [AppUIFixture.shapeOfYou, AppUIFixture.blindingLights, AppUIFixture.agarTumSaathHo,
                   AppUIFixture.kesariya, AppUIFixture.tumHiHo] {
            let options = ui.app.buttons["track.options.\(id)"]
            try ui.reveal(options)
            try ui.tap(options)
            try ui.tap(ui.app.buttons["Remove from Liked Songs"])
            try ui.wait("Removing a like must remove that recording from this page") {
                !ui.app.buttons["track.play.\(id)"].exists
            }
        }
        let findMusic = ui.app.buttons["library.likes.findMusic"]
        try ui.reveal(findMusic)
        XCTAssertEqual(ui.app.staticTexts["library.likes.count"].label, "0 songs")
        ui.capture("library-empty-liked-songs-find-music")
        try ui.tap(findMusic)
        try ui.requireHittable(ui.app.textFields["search.field"])
        XCTAssertFalse(ui.app.navigationBars["Liked Songs"].exists)
        assertEmptyQuery(ui)
        assertNoFilters(ui)
        XCTAssertFalse(ui.app.keyboards.firstMatch.exists)
        XCTAssertTrue(ui.app.buttons["search.radio.open"].exists)
        XCTAssertFalse(ui.app.buttons["search.library.likes"].exists)
        XCTAssertEqual(recentButtons(ui).count, 0)
        ui.capture("search-root-after-empty-likes-find-music")
    }

    func testSearchAllMusicFromPlaylistShortcutReturnsToBlankSearch() throws {
        let ui = makeDriver()
        try launch(ui)
        try selectTab("search", ui: ui)
        let shortcut = searchPlaylist(ui)
        try ui.reveal(shortcut)
        try ui.tap(shortcut)
        try ui.reveal(ui.app.buttons["library.playlist.addSongs"])
        try ui.tap(ui.app.buttons["library.playlist.addSongs"])
        try ui.wait("Add songs must open from the Search playlist shortcut") {
            ui.app.navigationBars["Add Songs"].exists && ui.app.buttons["library.playlist.addDone"].exists
        }
        try ui.tap(ui.app.buttons["library.playlist.searchMusic"])
        try ui.requireHittable(ui.app.textFields["search.field"])
        XCTAssertFalse(ui.app.navigationBars["Add Songs"].exists)
        XCTAssertFalse(ui.app.navigationBars[AppUIFixture.seededPlaylist].exists)
        XCTAssertFalse(ui.app.buttons["library.playlist.addDone"].exists)
        assertEmptyQuery(ui)
        assertNoFilters(ui)
        XCTAssertFalse(ui.app.keyboards.firstMatch.exists)
        try ui.reveal(shortcut)
        XCTAssertTrue(shortcut.label.contains("5 songs"))
        XCTAssertEqual(recentButtons(ui).count, 0)
        ui.capture("search-root-after-playlist-search-all-music")
    }

    func testLocalSearchAutofocusesFromLikedAndPlaylistSearchShortcuts() throws {
        let ui = makeDriver()
        try launch(ui)
        try selectTab("search", ui: ui)
        // Liked songs opens from its Library card; the playlist keeps its Search shortcut.
        let shortcuts = [
            (id: "library.likes", tab: "library", scope: "library.likes", title: "Liked Songs"),
            (id: searchPlaylist(ui).identifier, tab: "search", scope: "library.playlist", title: AppUIFixture.seededPlaylist)
        ]
        for shortcut in shortcuts {
            try selectTab(shortcut.tab, ui: ui)
            try ui.reveal(ui.app.buttons[shortcut.id])
            try ui.tap(ui.app.buttons[shortcut.id])
            try ui.wait("The library shortcut must open its own page") { ui.app.navigationBars[shortcut.title].exists }
            let field = ui.app.textFields["\(shortcut.scope).search.field"]
            XCTAssertFalse(field.exists)
            XCTAssertFalse(ui.app.keyboards.firstMatch.exists)
            try ui.tap(ui.app.buttons["\(shortcut.scope).search"])
            try ui.wait("The magnifier must open and focus local search without another field tap") {
                field.exists && (ui.app.keyboards.firstMatch.exists
                    || ui.app.otherElements["UIContinuousPathIntroductionView"].exists)
            }
            try ui.dismissKeyboardIntroduction()
            try ui.wait("Local search must have an open keyboard before typing") { ui.app.keyboards.firstMatch.exists }
            ui.app.typeText("Tamasha")
            try ui.expectValue(field, "Tamasha")
            try ui.expectLabel(ui.app.staticTexts["\(shortcut.scope).count"], "1 of 5 songs")
            XCTAssertTrue(ui.app.buttons["track.play.\(AppUIFixture.agarTumSaathHo)"].exists)
            ui.capture("\(shortcut.scope)-autofocus-from-search")
            try ui.tap(ui.app.buttons["\(shortcut.scope).search.cancel"])
            try ui.wait("Cancel must dismiss local search and its keyboard") {
                !field.exists && !ui.app.keyboards.firstMatch.exists
            }
            if shortcut.tab == "search" {
                try backToSearch(ui)
            } else {
                try ui.tap(ui.app.navigationBars[shortcut.title].buttons.firstMatch)
                try ui.wait("Back must return to the Library root") { !ui.app.navigationBars[shortcut.title].exists }
                try selectTab("search", ui: ui)
            }
            assertEmptyQuery(ui)
            assertNoFilters(ui)
        }
        XCTAssertEqual(recentButtons(ui).count, 0)
    }

    func testPlaylistShortcutsShowLiveEditsAndSurviveRelaunch() throws {
        let ui = makeDriver()
        try launch(ui)
        try selectTab("search", ui: ui)
        let playlist = searchPlaylist(ui)
        try ui.reveal(playlist)
        let shortcutID = playlist.identifier
        XCTAssertNotNil(UUID(uuidString: String(shortcutID.dropFirst("search.library.playlist.".count))))
        try ui.tap(playlist)
        try ui.wait("The playlist shortcut must open the UUID-backed library page") {
            ui.app.navigationBars[AppUIFixture.seededPlaylist].exists && ui.app.buttons["library.playlist.menu"].exists
        }
        try ui.tap(ui.app.buttons["library.playlist.menu"])
        try ui.tap(ui.app.buttons["library.playlist.rename"])
        let name = ui.app.textFields["library.playlist.name"]
        try ui.replaceSelectedText(in: name, with: "Renamed from Search")
        try ui.tap(ui.app.buttons["library.playlist.save"])
        try ui.wait("Renaming must update the live destination") { ui.app.navigationBars["Renamed from Search"].exists }
        try backToSearch(ui)
        try ui.reveal(ui.app.buttons[shortcutID])
        XCTAssertTrue(ui.app.buttons[shortcutID].label.contains("Renamed from Search"))
        XCTAssertFalse(ui.app.keyboards.firstMatch.exists)

        try launch(ui, reset: false)
        try selectTab("search", ui: ui)
        try ui.reveal(ui.app.buttons[shortcutID])
        XCTAssertTrue(ui.app.buttons[shortcutID].label.contains("Renamed from Search"))
        XCTAssertEqual(recentButtons(ui).count, 0, "Library navigation is separate from opened catalog results")
    }

    func testSearchReselectPopsLocalPlaylistAndRadioPages() throws {
        let ui = makeDriver()
        try launch(ui)
        try selectTab("search", ui: ui)
        let playlistID = searchPlaylist(ui).identifier
        for id in [playlistID, "search.radio.open"] {
            let shortcut = ui.app.buttons[id]
            try ui.reveal(shortcut)
            try ui.tap(shortcut)
            try ui.wait("A shortcut must leave the Search root") {
                !ui.app.textFields["search.field"].exists && ui.app.navigationBars.firstMatch.exists
            }
            if id == "search.radio.open" {
                try ui.requireHittable(ui.app.searchFields["Songs or artists"])
                try assertTarget(ui.app.buttons["radio.search.type"], ui: ui)
                XCTAssertTrue(ui.app.navigationBars["Radio"].exists)
                XCTAssertFalse(ui.app.buttons["player.close"].exists)
            }
            try selectTab("search", ui: ui)
            try expectFocusedSearchAtTop(ui, firstID: "search.radio.open")
            XCTAssertFalse(ui.app.searchFields["Songs or artists"].exists)
            assertEmptyQuery(ui)
            try dismissKeyboard(ui)
            XCTAssertFalse(ui.app.buttons["search.dismissKeyboard"].exists, "The consumed request must not refocus after Done")
        }
    }

    func testOfflineSearchRoutesCachedSongsThroughTheBannerAndDeduplicatesLocalMatches() throws {
        let ui = makeDriver()
        try launch(ui, arguments: ["--offline-fixture", "--cached-songs-fixture"])
        try selectTab("search", ui: ui)
        try ui.requireHittable(ui.element("search.offline"))
        XCTAssertTrue(ui.element("search.offline").label.contains("You’re offline"))
        XCTAssertFalse(ui.app.buttons["search.library.cached"].exists, "Cached songs is a Library entry now")
        let banner = ui.app.buttons["offline.onThisDevice"]
        try ui.requireHittable(banner)
        try ui.tap(banner)
        try ui.wait("The banner must open the Library's On this device page") {
            ui.app.navigationBars["On This Device"].exists && ui.app.buttons["tab.library"].firstMatch.isSelected
        }
        XCTAssertTrue(ui.element("offline.status").exists)
        XCTAssertFalse(banner.exists, "No banner action while that page is open")
        let cachedSong = ui.app.buttons["onThisDevice.row.\(AppUIFixture.tumHiHo)"]
        try ui.reveal(cachedSong)
        try ui.tap(cachedSong)
        try ui.wait("The real cached fixture must play without a connection", timeout: 20) {
            let mini = ui.app.buttons["miniPlayer.open"]
            return mini.exists && mini.label.contains("Tum Hi Ho") && (mini.value as? String)?.hasPrefix("Playing") == true
        }
        try selectTab("search", ui: ui)
        try ui.requireHittable(ui.app.textFields["search.field"])
        let cases = [(query: "TÚM", count: 2), (query: "aRIJÍT", count: 3), (query: "tÁMÁSHA", count: 1)]
        for item in cases {
            try replaceQuery(item.query, ui: ui)
            let matches = ui.element("search.offline.results").buttons.matching(NSPredicate(
                format: "identifier BEGINSWITH %@", "track.play."))
            try ui.wait("Local search must match saved metadata without duplicate liked/playlist/cache rows") { matches.count == item.count }
            assertNoFilters(ui)
            XCTAssertFalse(ui.element("search.progress").exists)
            XCTAssertFalse(ui.app.buttons["search.retry"].exists)
            XCTAssertFalse(ui.app.staticTexts["Search couldn't finish"].exists)
            XCTAssertFalse(ui.app.buttons["search.library.cached"].exists)
            XCTAssertFalse(ui.app.buttons["search.library.open"].exists)
            XCTAssertTrue(banner.exists, "Offline results rely on the banner for the Cached songs route")
        }
        try replaceQuery("No saved recording matches this", ui: ui)
        try ui.reveal(ui.element("search.offline.empty"))
        XCTAssertFalse(ui.app.buttons["search.retry"].exists)
        try clearQuery(ui)
        try ui.reveal(ui.app.buttons["search.radio.open"])
        ui.capture("offline-local-search-with-banner-route")
    }

    func testLargeDynamicTypeKeepsSearchLibraryAndRecentControlsReachableOnPhoneAndIPad() throws {
        let ui = makeDriver()
        try launch(ui, arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        try selectTab("search", ui: ui)
        for id in ["search.radio.open", searchPlaylist(ui).identifier] {
            try ui.reveal(ui.app.buttons[id], maxSwipes: 20)
            try assertTarget(ui.app.buttons[id], ui: ui)
        }
        try replaceQuery("Tum Hi Ho", ui: ui, dismiss: false)
        try assertTarget(ui.app.buttons["search.clear"], ui: ui)
        try assertTarget(ui.app.buttons["search.dismissKeyboard"], ui: ui)
        try assertTarget(ui.app.buttons["search.dismissKeyboard.toolbar"], ui: ui)
        try dismissKeyboard(ui)
        try ui.waitForSearchResults()
        try ui.selectSearchFilter("songs")
        try assertTarget(ui.app.buttons["search.filter.songs"], ui: ui)
        let song = ui.app.buttons["track.play.\(AppUIFixture.tumHiHo)"]
        try ui.reveal(song, maxSwipes: 20)
        try assertTarget(song, ui: ui)
        try ui.tap(song)
        try clearQuery(ui)
        for id in ["search.recent.track:\(AppUIFixture.tumHiHo)", "search.recent.remove.track:\(AppUIFixture.tumHiHo)", "search.recents.clear"] {
            try ui.reveal(ui.app.buttons[id], maxSwipes: 20)
            try assertTarget(ui.app.buttons[id], ui: ui)
        }
        ui.capture("search-redesign-accessibility-xxxl")
    }

    private func verifyReselection(arguments: [String] = []) throws {
        let ui = makeDriver()
        try launch(ui, arguments: arguments + ["--artist-spotlight-fixture", "--search-results", "A. R. Rahman"])
        try ui.waitForSearchResults()
        XCTAssertFalse(ui.app.keyboards.firstMatch.exists)
        let last = ui.app.buttons["track.play.fixture.spotlight.extra.13"]
        try ui.reveal(last, maxSwipes: 30)
        let filter = ui.app.buttons["search.filter.songs"]
        XCTAssertTrue(!filter.exists || filter.frame.maxY < ui.app.scrollViews["search.content"].frame.minY)
        try selectTab("search", ui: ui)
        try expectFocusedSearchAtTop(ui, firstID: "search.filter.songs")
        XCTAssertEqual(ui.app.textFields["search.field"].value as? String, "A. R. Rahman")
        try dismissKeyboard(ui)
        try ui.requireHittable(ui.app.buttons["search.featuredArtist"])
        try ui.tap(ui.app.buttons["search.featuredArtist"])
        try ui.expectArtistPage(named: "A. R. Rahman")
        try ui.reveal(ui.app.buttons["artist.spotlight.open"])
        try ui.tap(ui.app.buttons["artist.spotlight.open"])
        try ui.reveal(ui.app.staticTexts["artist.spotlight.countProvenance"])
        try selectTab("search", ui: ui)
        try expectFocusedSearchAtTop(ui, firstID: "search.filter.songs")
        XCTAssertFalse(ui.app.staticTexts["artist.spotlight.countProvenance"].exists)
        XCTAssertEqual(ui.app.textFields["search.field"].value as? String, "A. R. Rahman")
        try dismissKeyboard(ui)
        try ui.tap(ui.app.buttons["search.featuredArtist"])
        try ui.expectArtistPage(named: "A. R. Rahman")
        try backToSearch(ui)
        XCTAssertFalse(ui.app.keyboards.firstMatch.exists, "Native Back must not replay the consumed Search focus request")
        XCTAssertEqual(ui.app.textFields["search.field"].value as? String, "A. R. Rahman")
        ui.capture(arguments.isEmpty ? "search-reselection-root-and-nested-detail" : "search-reselection-reduce-motion")
    }

    private func makeDriver() -> AppUITestDriver {
        let ui = AppUITestDriver(testCase: self, prefix: "search-redesign")
        addTeardownBlock { await ui.finish() }
        return ui
    }

    private func launch(_ ui: AppUITestDriver, reset: Bool = true, arguments: [String] = []) throws {
        ui.app.terminate()
        XCUIDevice.shared.orientation = .portrait
        ui.app.launchArguments = ["--uitesting", "--seed-ui", "--skip-welcome"]
            + (reset ? ["--reset-ui"] : []) + arguments
            + ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        ui.app.launchEnvironment = ["GANABAJANA_TEST_STORE": ui.storeName]
        ui.app.launch()
        // Native iPad top tabs expose tab.* buttons outside the bottom tab-bar query used by the phone driver.
        try ui.requireHittable(ui.app.buttons["tab.home"].firstMatch, timeout: 25)
    }

    private func selectTab(_ tab: String, ui: AppUITestDriver) throws {
        if ui.app.buttons["search.dismissKeyboard"].exists { try dismissKeyboard(ui) }
        try ui.tap(ui.app.buttons["tab.\(tab)"].firstMatch)
    }

    private func search(_ query: String, ui: AppUITestDriver) throws {
        try selectTab("search", ui: ui)
        try replaceQuery(query, ui: ui)
    }

    private func replaceQuery(_ query: String, ui: AppUITestDriver, dismiss: Bool = true) throws {
        let field = ui.app.textFields["search.field"]
        try ui.requireHittable(field)
        if ui.app.buttons["search.clear"].exists { try ui.clearSearch() }
        else { try ui.tap(field) }
        try ui.dismissKeyboardIntroduction()
        field.typeText(query)
        if dismiss { try dismissKeyboard(ui) }
    }

    private func clearQuery(_ ui: AppUITestDriver) throws {
        try ui.clearSearch()
        try dismissKeyboard(ui)
        assertEmptyQuery(ui)
        assertNoFilters(ui)
    }

    private func dismissKeyboard(_ ui: AppUITestDriver) throws {
        try ui.tap(ui.app.buttons["search.dismissKeyboard"])
        try ui.wait("Done must dismiss editing without clearing the query") {
            !ui.app.keyboards.firstMatch.exists && !ui.app.buttons["search.dismissKeyboard"].exists
        }
    }

    private func backToSearch(_ ui: AppUITestDriver) throws {
        let back = ui.app.navigationBars.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "Back", "Search")).firstMatch
        try ui.tap(back)
        try ui.requireHittable(ui.app.textFields["search.field"])
        XCTAssertFalse(ui.app.keyboards.firstMatch.exists)
    }

    private func searchPlaylist(_ ui: AppUITestDriver) -> XCUIElement {
        ui.app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search.library.playlist.")).firstMatch
    }

    private func recentButtons(_ ui: AppUITestDriver) -> XCUIElementQuery {
        ui.app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND NOT (identifier BEGINSWITH %@)",
                                           "search.recent.", "search.recent.remove."))
    }

    private func assertNoFilters(_ ui: AppUITestDriver, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(ui.app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search.filter.")).count,
                       0, file: file, line: line)
    }

    private func assertEmptyQuery(_ ui: AppUITestDriver, file: StaticString = #filePath, line: UInt = #line) {
        let field = ui.app.textFields["search.field"]
        XCTAssertTrue((field.value as? String) == "" || (field.value as? String) == field.placeholderValue, file: file, line: line)
    }

    private func assertTarget(_ element: XCUIElement, ui: AppUITestDriver,
                              file: StaticString = #filePath, line: UInt = #line) throws {
        try ui.requireHittable(element)
        XCTAssertGreaterThanOrEqual(element.frame.width, 44 - 1e-6, file: file, line: line)
        XCTAssertGreaterThanOrEqual(element.frame.height, 44 - 1e-6, file: file, line: line)
        XCTAssertLessThanOrEqual(element.frame.width, 1000 + 1e-6, file: file, line: line)
        XCTAssertGreaterThanOrEqual(element.frame.minX, ui.app.windows.firstMatch.frame.minX - 1e-6, file: file, line: line)
        XCTAssertLessThanOrEqual(element.frame.maxX, ui.app.windows.firstMatch.frame.maxX + 1e-6, file: file, line: line)
    }

    private func expectFocusedSearchAtTop(_ ui: AppUITestDriver, firstID: String) throws {
        try ui.wait("Reselect must pop to the root, scroll to the top, and focus the field without another tap") {
            let viewport = ui.app.scrollViews["search.content"]
            let first = ui.app.buttons[firstID]
            guard viewport.exists, first.exists, ui.app.keyboards.firstMatch.exists else { return false }
            return first.frame.minY >= viewport.frame.minY - 1 && first.frame.minY <= viewport.frame.minY + 24
                && first.frame.intersection(viewport.frame).height >= 44 - 1e-6
        }
        try ui.dismissKeyboardIntroduction()
        try ui.requireHittable(ui.app.textFields["search.field"])
    }
}

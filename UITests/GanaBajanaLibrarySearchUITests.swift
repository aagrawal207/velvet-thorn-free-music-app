import XCTest

@MainActor
final class GanaBajanaLibrarySearchUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testLikedSongsSearchesTitleArtistAndAlbumThenClearsWithoutReplacingPlayback() throws {
        let ui = makeDriver()
        try launch(ui)
        try disableAutoplay(ui)
        try openLikes(ui)
        try beginSearch(ui, scope: "library.likes")

        try query("TÚM", in: "library.likes", ui: ui)
        try expectCount("2 of 5 songs", scope: "library.likes", ui: ui)
        XCTAssertFalse(ui.app.buttons["track.play.\(AppUIFixture.kesariya)"].exists)
        try query("aRIJÍT", in: "library.likes", ui: ui)
        try expectCount("3 of 5 songs", scope: "library.likes", ui: ui)
        try ui.reveal(ui.app.buttons["track.play.\(AppUIFixture.agarTumSaathHo)"])
        XCTAssertFalse(ui.app.buttons["track.play.\(AppUIFixture.shapeOfYou)"].exists)

        try query("tÁMÁSHA", in: "library.likes", ui: ui)
        try expectCount("1 of 5 songs", scope: "library.likes", ui: ui)
        let song = ui.app.buttons["track.play.\(AppUIFixture.agarTumSaathHo)"]
        try ui.reveal(song)
        try assertMinimumTarget(song, ui: ui)
        try ui.tap(song)
        try ui.wait("A filtered liked song must become the current recording") {
            let mini = ui.app.buttons["miniPlayer.open"]
            return mini.exists && mini.label.contains("Agar Tum Saath Ho")
        }
        try ui.openPlayer()
        try ui.expectCurrentTrack(AppUIFixture.agarTumSaathHo)
        try ui.waitForAdvance(from: 0, by: 1)
        try ui.pause()
        try ui.closePlayer()
        try assertQueue([AppUIFixture.agarTumSaathHo], current: AppUIFixture.agarTumSaathHo, ui: ui)

        try query("no-such-saved-recording", in: "library.likes", ui: ui)
        try expectNoMatches(scope: "library.likes", ui: ui)
        try clearQuery(scope: "library.likes", ui: ui)
        try expectCount("5 songs", scope: "library.likes", ui: ui)
        try cancelSearch(scope: "library.likes", ui: ui)
        try assertQueue([AppUIFixture.agarTumSaathHo], current: AppUIFixture.agarTumSaathHo, ui: ui)

        try selectTab("search", ui: ui)
        let globalField = ui.app.textFields["search.field"]
        try ui.requireHittable(globalField)
        XCTAssertTrue(isEmpty(globalField), "Local library queries must not replace the catalog query")
        XCTAssertFalse(ui.app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search.recent.")).firstMatch.exists,
                       "Library filtering must not add catalog search history")
    }

    func testPlaylistPlayAndShuffleCaptureOnlyMatchesEvenAfterSearchIsCleared() throws {
        let ui = makeDriver()
        try launch(ui)
        try disableAutoplay(ui)
        try selectTab("library", ui: ui)
        try ui.openPlaylist(named: AppUIFixture.seededPlaylist)
        try beginSearch(ui, scope: "library.playlist")
        try query("ARIJIT", in: "library.playlist", ui: ui)
        try assertSearchFieldPaddingFocuses(scope: "library.playlist", ui: ui)
        try expectCount("3 of 5 songs", scope: "library.playlist", ui: ui)
        XCTAssertFalse(ui.app.buttons["library.playlist.edit"].isEnabled)
        try ui.reveal(ui.app.buttons["library.playlist.play"], direction: .down)
        try assertMinimumTarget(ui.app.buttons["library.playlist.play"], ui: ui)
        try ui.tap(ui.app.buttons["library.playlist.play"])
        try assertQueue([AppUIFixture.tumHiHo, AppUIFixture.kesariya, AppUIFixture.agarTumSaathHo],
                        current: AppUIFixture.tumHiHo, playing: true, ui: ui)

        try query("TUM", in: "library.playlist", ui: ui)
        try expectCount("2 of 5 songs", scope: "library.playlist", ui: ui)
        try ui.reveal(ui.app.buttons["library.playlist.shuffle"], direction: .down)
        try assertMinimumTarget(ui.app.buttons["library.playlist.shuffle"], ui: ui)
        try ui.tap(ui.app.buttons["library.playlist.shuffle"])
        try ui.openPlayer()
        try ui.pause()
        let current = try XCTUnwrap([AppUIFixture.tumHiHo, AppUIFixture.agarTumSaathHo].first {
            ui.app.staticTexts["player.track.\($0)"].exists
        })
        try ui.closePlayer()
        try assertQueue([AppUIFixture.tumHiHo, AppUIFixture.agarTumSaathHo], current: current, shuffled: true, ui: ui)

        try clearQuery(scope: "library.playlist", ui: ui)
        try expectCount("5 songs · Made by you", scope: "library.playlist", ui: ui)
        try query("missing-album-927", in: "library.playlist", ui: ui)
        try expectNoMatches(scope: "library.playlist", ui: ui)
        try cancelSearch(scope: "library.playlist", ui: ui)
        try assertQueue([AppUIFixture.tumHiHo, AppUIFixture.agarTumSaathHo], current: current, shuffled: true, ui: ui)
        try expectCount("5 songs · Made by you", scope: "library.playlist", ui: ui)
    }

    func testFilteredPlaylistRemovalUsesRecordingIdentityAndCancelRestoresNativeReordering() throws {
        let ui = makeDriver()
        try launch(ui)
        try selectTab("library", ui: ui)
        try ui.openPlaylist(named: AppUIFixture.seededPlaylist)
        let edit = ui.app.buttons["library.playlist.edit"]
        try ui.tap(edit)
        try ui.expectLabel(edit, "Done")
        try beginSearch(ui, scope: "library.playlist")
        try query("BRAHMÁSTRA", in: "library.playlist", ui: ui)
        try expectCount("1 of 5 songs", scope: "library.playlist", ui: ui)
        XCTAssertFalse(edit.isEnabled)
        XCTAssertEqual(edit.label, "Edit", "Starting search must end an in-progress editing session")
        try submitQuery(scope: "library.playlist", ui: ui)
        let kesariya = ui.app.buttons["track.play.\(AppUIFixture.kesariya)"]
        try ui.reveal(kesariya)
        try ui.removeQueueSong(kesariya)
        try expectCount("0 of 4 songs", scope: "library.playlist", ui: ui)
        try expectNoMatches(scope: "library.playlist", ui: ui)

        try clearQuery(scope: "library.playlist", ui: ui)
        try expectCount("4 songs · Made by you", scope: "library.playlist", ui: ui)
        try cancelSearch(scope: "library.playlist", ui: ui)
        XCTAssertTrue(edit.isEnabled)
        let tum = ui.app.buttons["track.play.\(AppUIFixture.tumHiHo)"]
        let agar = ui.app.buttons["track.play.\(AppUIFixture.agarTumSaathHo)"]
        try ui.reveal(tum)
        try ui.reveal(agar)
        XCTAssertLessThan(tum.frame.minY, agar.frame.minY)
        XCTAssertFalse(kesariya.exists, "Deleting filtered row zero must remove Kesariya, not full-playlist row zero")
        try ui.tap(edit)
        try ui.moveQueueSong(agar, before: tum)
        try ui.wait("Native reordering must work again after cancelling search") { agar.frame.minY < tum.frame.minY }
        try ui.tap(edit)
        try ui.expectLabel(edit, "Edit")

        try ui.reveal(ui.app.buttons["library.playlist.addSongs"], direction: .down)
        try ui.tap(ui.app.buttons["library.playlist.addSongs"])
        let alreadyAdded = ui.app.buttons["library.playlist.add.\(AppUIFixture.tumHiHo)"]
        try ui.reveal(alreadyAdded)
        XCTAssertFalse(alreadyAdded.isEnabled, "Search and reordering must not allow duplicate recording IDs")
        try ui.tap(ui.app.buttons["library.playlist.addDone"])

        try launch(ui, reset: false)
        try selectTab("library", ui: ui)
        try ui.openPlaylist(named: AppUIFixture.seededPlaylist)
        try expectCount("4 songs · Made by you", scope: "library.playlist", ui: ui)
        try ui.reveal(agar)
        try ui.reveal(tum)
        XCTAssertLessThan(agar.frame.minY, tum.frame.minY, "The new full-playlist order must survive relaunch")
        XCTAssertFalse(kesariya.exists)
    }

    func testEmptyPlaylistKeepsItsEmptyLibraryMessageWhileSearching() throws {
        let ui = makeDriver()
        try launch(ui)
        try selectTab("library", ui: ui)
        try ui.tap(ui.app.buttons["library.createPlaylist"])
        let name = ui.app.textFields["library.playlist.name"]
        try ui.tap(name)
        name.typeText("An empty search playlist")
        try ui.tap(ui.app.buttons["library.playlist.save"])
        try ui.wait("Saving the empty playlist must close its editor") { !name.exists }
        try ui.openPlaylist(named: "An empty search playlist")
        try beginSearch(ui, scope: "library.playlist")
        try query("Tamasha", in: "library.playlist", ui: ui)
        try submitQuery(scope: "library.playlist", ui: ui)
        try expectCount("0 songs · Made by you", scope: "library.playlist", ui: ui)
        try ui.reveal(ui.app.staticTexts["The first song sets the mood"])
        XCTAssertFalse(ui.app.staticTexts["No matching songs"].exists)
        XCTAssertFalse(ui.app.buttons["library.playlist.play"].isEnabled)
        XCTAssertFalse(ui.app.buttons["library.playlist.shuffle"].isEnabled)
        try clearQuery(scope: "library.playlist", ui: ui)
        try cancelSearch(scope: "library.playlist", ui: ui)
        try expectCount("0 songs · Made by you", scope: "library.playlist", ui: ui)
        XCTAssertFalse(ui.app.buttons["library.playlist.edit"].isEnabled)
    }

    func testSearchControlsAndResultsRemainReachableAtLargestDynamicTypeOnPhoneAndIPad() throws {
        let ui = makeDriver()
        try launch(ui, arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        try openLikes(ui)
        try beginSearch(ui, scope: "library.likes")
        try query("Tamasha", in: "library.likes", ui: ui)
        try assertSearchFieldPaddingFocuses(scope: "library.likes", ui: ui)
        try expectCount("1 of 5 songs", scope: "library.likes", ui: ui)
        try assertMinimumTarget(ui.app.buttons["library.likes.search.clear"], ui: ui)
        try assertMinimumTarget(ui.app.buttons["library.likes.search.cancel"], ui: ui)
        try submitQuery(scope: "library.likes", ui: ui)
        let song = ui.app.buttons["track.play.\(AppUIFixture.agarTumSaathHo)"]
        try ui.reveal(song)
        try assertMinimumTarget(song, ui: ui)
        try clearQuery(scope: "library.likes", ui: ui)
        try cancelSearch(scope: "library.likes", ui: ui)
        try ui.tap(ui.app.navigationBars["Liked songs"].buttons["Back"])

        try ui.openPlaylist(named: AppUIFixture.seededPlaylist)
        try beginSearch(ui, scope: "library.playlist")
        try query("After Hours", in: "library.playlist", ui: ui)
        try assertSearchFieldPaddingFocuses(scope: "library.playlist", ui: ui)
        try assertMinimumTarget(ui.app.buttons["library.playlist.search.clear"], ui: ui)
        try assertMinimumTarget(ui.app.buttons["library.playlist.search.cancel"], ui: ui)
        try submitQuery(scope: "library.playlist", ui: ui)
        try expectCount("1 of 5 songs", scope: "library.playlist", ui: ui)
        let blindingLights = ui.app.buttons["track.play.\(AppUIFixture.blindingLights)"]
        try ui.reveal(blindingLights)
        try assertMinimumTarget(blindingLights, ui: ui)
        XCTAssertLessThanOrEqual(blindingLights.frame.width, 1000 + 1e-6, "Regular-width results use the shared content column")
        try cancelSearch(scope: "library.playlist", ui: ui)
    }

    func testLikedSongsHistoryNoticeEnablesThePreferenceAndPersistsIt() throws {
        let ui = makeDriver()
        try launch(ui)
        try openSettings(ui)
        try ui.setSwitch("settings.history", to: false)
        try ui.tap(ui.app.buttons["settings.done"])
        try openLikes(ui)
        let enable = ui.app.buttons["library.history.enable"]
        try ui.reveal(enable)
        try assertMinimumTarget(enable, ui: ui)
        try ui.tap(enable)
        try ui.wait("The library notice must disappear only after history has been enabled") { !enable.exists }
        try launch(ui, reset: false)
        try openSettings(ui)
        try ui.expectSwitch("settings.history", isOn: true)
        try ui.tap(ui.app.buttons["settings.done"])
        try openLikes(ui)
        try expectCount("5 songs", scope: "library.likes", ui: ui)
        XCTAssertFalse(enable.exists)
    }

    private func makeDriver() -> AppUITestDriver {
        let ui = AppUITestDriver(testCase: self, prefix: "library-search")
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
        // iPad's native top tabs are plain buttons rather than children of a bottom tab bar.
        try ui.requireHittable(ui.app.buttons["tab.home"].firstMatch, timeout: 25)
    }

    private func selectTab(_ tab: String, ui: AppUITestDriver) throws {
        try ui.tap(ui.app.buttons["tab.\(tab)"].firstMatch)
    }

    private func openLikes(_ ui: AppUITestDriver) throws {
        try selectTab("library", ui: ui)
        try ui.reveal(ui.app.buttons["library.likes"], direction: .down)
        try ui.tap(ui.app.buttons["library.likes"])
        try ui.wait("Liked songs must open") { ui.app.navigationBars["Liked songs"].exists }
    }

    private func openSettings(_ ui: AppUITestDriver) throws {
        try selectTab("home", ui: ui)
        try ui.reveal(ui.app.buttons["home.settings"], direction: .down)
        try ui.tap(ui.app.buttons["home.settings"])
        try ui.requireHittable(ui.app.buttons["settings.done"])
    }

    private func disableAutoplay(_ ui: AppUITestDriver) throws {
        try openSettings(ui)
        try ui.setSwitch("settings.autoplay", to: false)
        try ui.tap(ui.app.buttons["settings.done"])
    }

    private func beginSearch(_ ui: AppUITestDriver, scope: String) throws {
        let field = ui.app.textFields["\(scope).search.field"]
        XCTAssertFalse(field.exists, "The search field must be on demand")
        let button = ui.app.buttons["\(scope).search"]
        try assertMinimumTarget(button, ui: ui)
        try ui.tap(button)
        try ui.wait("The native library search field must appear") { field.exists }
        try ui.dismissKeyboardIntroduction()
        try assertMinimumTarget(field, ui: ui)
        try assertMinimumTarget(ui.app.buttons["\(scope).search.cancel"], ui: ui)
    }

    private func query(_ query: String, in scope: String, ui: AppUITestDriver) throws {
        let field = ui.app.textFields["\(scope).search.field"]
        if ui.app.buttons["\(scope).search.clear"].exists { try clearQuery(scope: scope, ui: ui) }
        try ui.tap(field)
        field.typeText(query)
        try ui.expectValue(field, query)
    }

    private func assertSearchFieldPaddingFocuses(scope: String, ui: AppUITestDriver) throws {
        let field = ui.app.textFields["\(scope).search.field"]
        let query = try XCTUnwrap(field.value as? String)
        for edge in ["top", "bottom"] {
            try submitQuery(scope: scope, ui: ui)
            try assertMinimumTarget(field, ui: ui)
            let frame = field.frame
            let window = ui.app.windows.firstMatch
            let bounds = window.frame
            let y = edge == "top" ? frame.minY + 4 : frame.maxY - 4
            // Window coordinates exercise the claimed padding instead of XCTest's native text-line activation point.
            window.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: frame.midX - bounds.minX, dy: y - bounds.minY)).tap()
            try ui.wait("Tapping \(edge) padding of \(scope).search.field must focus its native editor and preserve the query") {
                field.exists && ui.app.keyboards.firstMatch.exists && (field.value as? String) == query
            }
            try assertMinimumTarget(field, ui: ui)
        }
    }

    private func clearQuery(scope: String, ui: AppUITestDriver) throws {
        let clear = ui.app.buttons["\(scope).search.clear"]
        try assertMinimumTarget(clear, ui: ui)
        try ui.tap(clear)
        let field = ui.app.textFields["\(scope).search.field"]
        try ui.wait("Clearing a local query must keep its native field open and empty") {
            field.exists && ((field.value as? String) == "" || (field.value as? String) == field.placeholderValue)
        }
    }

    private func cancelSearch(scope: String, ui: AppUITestDriver) throws {
        let cancel = ui.app.buttons["\(scope).search.cancel"]
        try assertMinimumTarget(cancel, ui: ui)
        try ui.tap(cancel)
        try ui.wait("Cancel must remove the search field and restore its compact affordance") {
            !ui.app.textFields["\(scope).search.field"].exists && ui.app.buttons["\(scope).search"].exists
        }
    }

    private func submitQuery(scope: String, ui: AppUITestDriver) throws {
        let field = ui.app.textFields["\(scope).search.field"]
        let before = field.value as? String
        try ui.tap(field)
        field.typeText("\n")
        try ui.wait("Submitting must dismiss the keyboard without clearing the filter") {
            !ui.app.keyboards.firstMatch.exists && (field.value as? String) == before
        }
    }

    private func expectCount(_ text: String, scope: String, ui: AppUITestDriver) throws {
        let count = ui.app.staticTexts["\(scope).count"]
        try ui.reveal(count, direction: .down)
        try ui.expectLabel(count, text)
    }

    private func expectNoMatches(scope: String, ui: AppUITestDriver) throws {
        try ui.reveal(ui.app.staticTexts["No matching songs"])
        XCTAssertFalse(ui.app.staticTexts["The first song sets the mood"].exists)
        XCTAssertFalse(ui.app.staticTexts["Save a song you love"].exists)
        try ui.reveal(ui.app.buttons["\(scope).play"], direction: .down)
        XCTAssertFalse(ui.app.buttons["\(scope).play"].isEnabled)
        XCTAssertFalse(ui.app.buttons["\(scope).shuffle"].isEnabled)
    }

    private func assertQueue(_ ids: [String], current: String, shuffled: Bool = false,
                             playing: Bool = false, ui: AppUITestDriver) throws {
        try ui.openPlayer()
        try ui.expectCurrentTrack(current)
        if playing {
            try ui.waitForAdvance(from: ui.position(), by: 0.5)
            try ui.pause()
        } else {
            try ui.expectLabel(ui.app.buttons["player.playPause"], "Play")
        }
        try ui.openPlayerSheet("queue", title: "Queue")
        let rows = ui.app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "queue.play."))
        try ui.wait("The queue must contain exactly the captured library search results") { rows.count == ids.count }
        XCTAssertEqual(ui.app.buttons["player.shuffle"].isSelected, shuffled)
        for id in ids {
            let row = ui.queueSong(id: id)
            try ui.reveal(row)
            XCTAssertFalse(row.label.hasSuffix(", Autoplay"))
            if id == current { XCTAssertTrue(row.label.hasPrefix("Current song")) }
        }
        if !shuffled {
            for (first, second) in zip(ids, ids.dropFirst()) {
                XCTAssertLessThan(ui.queueSong(id: first).frame.minY, ui.queueSong(id: second).frame.minY)
            }
        }
        try ui.closeSheet("Queue")
        try ui.closePlayer()
    }

    private func assertMinimumTarget(_ element: XCUIElement, ui: AppUITestDriver,
                                     file: StaticString = #filePath, line: UInt = #line) throws {
        try ui.requireHittable(element)
        let frame = element.frame
        let context = "\(element.identifier) (\(element.elementType)), frame: \(frame)"
        XCTAssertGreaterThanOrEqual(frame.width + 1e-6, 44, context, file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.height + 1e-6, 44, context, file: file, line: line)
        let window = ui.app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(frame.minX, window.minX - 1e-6, context, file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxX, window.maxX + 1e-6, context, file: file, line: line)
    }

    private func isEmpty(_ field: XCUIElement) -> Bool {
        guard let value = field.value as? String else { return false }
        return value.isEmpty || value == field.placeholderValue
    }
}

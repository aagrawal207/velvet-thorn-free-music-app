import XCTest

@MainActor
final class GanaBajanaCachedSongsUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testInventorySearchesLocalTitleArtistAndAlbumAndExcludesPartialAudio() throws {
        let ui = makeDriver()
        try launch(ui)
        try openStorage(ui)
        try ui.wait("Storage must count compatible complete recordings, not every stored song") {
            ui.app.buttons["storage.cachedSongs"].value as? String == "4 available locally"
                && ui.accessibleText(ui.element("storage.audio.usage")).contains("4 songs verified for local playback")
        }
        try openCachedSongs(ui)
        try expectCount("5 songs · 4 available locally", ui: ui)
        XCTAssertTrue(ui.element("cachedSongs.offline").exists)

        try search("TÚM", ui: ui)
        try expectCount("2 of 5 songs · 2 available locally", ui: ui)
        try search("aRIJÍT", ui: ui)
        try expectCount("3 of 5 songs · 3 available locally", ui: ui)
        try search("tÁMÁSHA", ui: ui)
        try expectCount("1 of 5 songs · 1 available locally", ui: ui)
        let legacy = playButton(AppUIFixture.agarTumSaathHo, ui: ui)
        try ui.reveal(legacy)
        XCTAssertTrue(legacy.label.contains("Agar Tum Saath Ho"), "Legacy IDs must join saved library metadata without a catalog lookup")

        try search("Blinding Lights", ui: ui)
        try expectCount("0 of 5 songs · 0 available locally", ui: ui)
        XCTAssertTrue(ui.element("cachedSongs.search.empty").exists)
        XCTAssertFalse(playButton(AppUIFixture.blindingLights, ui: ui).exists, "An unfinished .part file is not a cached song")
        XCTAssertFalse(ui.app.buttons["cachedSongs.play"].isEnabled)
        XCTAssertFalse(ui.app.buttons["cachedSongs.shuffle"].isEnabled)
        try closeSettings(ui)
        try assertNoNetwork(ui)
        try ui.tap(ui.app.buttons["tab.search"].firstMatch)
        let globalQuery = ui.app.textFields["search.field"]
        try ui.requireHittable(globalQuery)
        XCTAssertTrue((globalQuery.value as? String) == "" || (globalQuery.value as? String) == globalQuery.placeholderValue)
        XCTAssertFalse(ui.app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search.recent.")).firstMatch.exists)
    }

    func testIncompatibleCopyExplainsConnectionRequirementAndCanStillBeRemoved() throws {
        let ui = makeDriver()
        try launch(ui)
        try openCachedSongs(ui)
        try search("Shape of You", ui: ui)
        try expectCount("1 of 5 songs · 0 available locally", ui: ui)
        let song = playButton(AppUIFixture.shapeOfYou, ui: ui)
        try ui.reveal(song)
        XCTAssertFalse(song.isEnabled)
        XCTAssertTrue(ui.accessibleText(song).contains("Needs a connection"))
        XCTAssertFalse(ui.app.buttons["cachedSongs.play"].isEnabled)
        XCTAssertFalse(ui.app.buttons["cachedSongs.shuffle"].isEnabled)
        let remove = removeButton(AppUIFixture.shapeOfYou, ui: ui)
        try ui.reveal(remove)
        try assertMinimumTarget(remove, ui: ui)
        try ui.tap(remove)
        try expectCount("0 of 4 songs · 0 available locally", ui: ui)
        XCTAssertFalse(song.exists)
        try cancelSearch(ui)
        try expectCount("4 songs · 4 available locally", ui: ui)
    }

    func testPlayAndShuffleQueueOnlyCompleteCompatibleLocalSongs() throws {
        let ui = makeDriver()
        try launch(ui)
        for action in ["play", "shuffle"] {
            try openCachedSongs(ui)
            try expectCount("5 songs · 4 available locally", ui: ui)
            let button = ui.app.buttons["cachedSongs.\(action)"]
            try ui.reveal(button, direction: .down)
            try assertMinimumTarget(button, ui: ui)
            try ui.tap(button)
            try closeSettings(ui)
            try assertPlaybackQueue(Fixture.playableIDs, shuffled: action == "shuffle", ui: ui)
        }
    }

    func testFilteredLegacySongPlaysFromItsFileWithoutNetworkAccess() throws {
        let ui = makeDriver()
        try launch(ui)
        for usesContextMenu in [false, true] {
            try openCachedSongs(ui)
            try search("Tamasha", ui: ui)
            try expectCount("1 of 5 songs · 1 available locally", ui: ui)
            let song = playButton(AppUIFixture.agarTumSaathHo, ui: ui)
            try ui.reveal(song)
            if usesContextMenu {
                song.press(forDuration: 1)
                try ui.tap(ui.app.buttons["cachedSongs.contextPlay.\(AppUIFixture.agarTumSaathHo)"])
            } else {
                try ui.tap(song)
            }
            try assertCachedSearchDismissed(ui)
            try closeSettings(ui)
            try assertPlaybackQueue([AppUIFixture.agarTumSaathHo], current: AppUIFixture.agarTumSaathHo,
                                    shuffled: false, ui: ui)
        }
    }

    func testFilteredPlayAndShuffleDismissSearchWithoutExpandingTheQueue() throws {
        let ui = makeDriver()
        try launch(ui)
        let expected = [AppUIFixture.tumHiHo, AppUIFixture.kesariya, AppUIFixture.agarTumSaathHo]
        for action in ["play", "shuffle"] {
            try openCachedSongs(ui)
            try search("Arijit", ui: ui)
            try expectCount("3 of 5 songs · 3 available locally", ui: ui)
            let button = ui.app.buttons["cachedSongs.\(action)"]
            try ui.reveal(button)
            try ui.tap(button)
            try assertCachedSearchDismissed(ui)
            try closeSettings(ui)
            try assertPlaybackQueue(expected, shuffled: action == "shuffle", ui: ui)
        }
    }

    func testUnknownRecordingUsesTruthfulFallbackAndBrowsingDoesNotAddItToRecents() throws {
        let ui = makeDriver()
        try launch(ui)
        try openCachedSongs(ui)
        try expectCount("5 songs · 4 available locally", ui: ui)
        let unknown = playButton(Fixture.unknownID, ui: ui)
        try ui.reveal(unknown)
        XCTAssertEqual(unknown.label, "Cached song, Recording ID: \(Fixture.unknownID)")
        XCTAssertTrue(unknown.isEnabled, "The coordinator supplies a safe, ID-only track for this valid local recording")
        XCTAssertTrue(removeButton(Fixture.unknownID, ui: ui).isEnabled)
        try closeSettings(ui)
        try assertNoNetwork(ui)

        try ui.tap(ui.app.buttons["tab.library"].firstMatch)
        try ui.reveal(ui.app.buttons["library.recents.all"])
        try ui.tap(ui.app.buttons["library.recents.all"])
        try ui.expectLabel(ui.app.staticTexts["library.recents.count"], "5 songs")
        XCTAssertFalse(ui.element("library.recent.\(Fixture.unknownID)").exists)

        try openCachedSongs(ui)
        try ui.reveal(unknown)
        try ui.tap(unknown)
        try closeSettings(ui)
        try assertPlaybackQueue(Fixture.playableIDs, current: Fixture.unknownID, shuffled: false, ui: ui)
        try ui.tap(ui.app.buttons["tab.library"].firstMatch)
        try ui.reveal(ui.element("library.recent.\(Fixture.unknownID)"), direction: .down)
        XCTAssertTrue(ui.app.buttons["track.play.\(Fixture.unknownID)"].label.contains("Cached song"))
        try ui.expectLabel(ui.app.staticTexts["library.recents.count"], "6 songs")
    }

    func testAccessibleRemovalDeletesAllVersionsAndPersistsWithoutChangingTheLibrary() throws {
        let ui = makeDriver()
        try launch(ui)
        try openCachedSongs(ui)
        try search("Brahmastra", ui: ui)
        try expectCount("1 of 5 songs · 1 available locally", ui: ui)
        let song = playButton(AppUIFixture.kesariya, ui: ui)
        try ui.reveal(song)
        XCTAssertTrue(ui.accessibleText(song).contains("2 versions"))
        let remove = removeButton(AppUIFixture.kesariya, ui: ui)
        try assertMinimumTarget(remove, ui: ui)
        try ui.tap(remove)
        try expectCount("0 of 4 songs · 0 available locally", ui: ui)
        XCTAssertFalse(song.exists)
        XCTAssertFalse(ui.app.alerts.firstMatch.exists)
        try cancelSearch(ui)
        try expectCount("4 songs · 3 available locally", ui: ui)
        try back(from: "Cached songs", to: "Storage", ui: ui)
        try ui.reveal(ui.element("storage.library.likes"), maxSwipes: 16)
        XCTAssertTrue(ui.accessibleText(ui.element("storage.library.likes")).contains("5"))
        XCTAssertTrue(ui.accessibleText(ui.element("storage.library.playlists")).contains("1"))

        try launch(ui, reset: false)
        try openCachedSongs(ui)
        try expectCount("4 songs · 3 available locally", ui: ui)
        try search("Brahmastra", ui: ui)
        try expectCount("0 of 4 songs · 0 available locally", ui: ui)
        XCTAssertFalse(song.exists, "No alternate encoding may reappear as a second logical recording after relaunch")
    }

    func testNativeSwipeAndContextMenuRemoveTheirRecordingIDs() throws {
        let ui = makeDriver()
        try launch(ui)
        try openCachedSongs(ui)
        try expectCount("5 songs · 4 available locally", ui: ui)
        let id = AppUIFixture.agarTumSaathHo
        let row = ui.element("cachedSongs.row.\(id)")
        try ui.reveal(row)
        let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
        let end = row.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: end)
        try ui.tap(ui.app.buttons["cachedSongs.swipeRemove.\(id)"])
        try expectCount("4 songs · 3 available locally", ui: ui)
        XCTAssertFalse(playButton(id, ui: ui).exists)

        let unknown = playButton(Fixture.unknownID, ui: ui)
        try ui.reveal(unknown)
        unknown.press(forDuration: 1)
        try ui.tap(ui.app.buttons["cachedSongs.contextRemove.\(Fixture.unknownID)"])
        try expectCount("3 songs · 2 available locally", ui: ui)
        XCTAssertFalse(unknown.exists)
    }

    func testPausedSelectionAndUpcomingSongStayInUse() throws {
        let ui = makeDriver()
        try launch(ui, scenario: .inUse)
        let mini = ui.app.buttons["miniPlayer.open"]
        try ui.requireHittable(mini)
        let selection = mini.label
        let playbackState = mini.value as? String
        XCTAssertTrue(selection.contains("Tum Hi Ho"))
        XCTAssertTrue(playbackState?.contains("Paused") == true)
        try openCachedSongs(ui)
        try expectCount("5 songs · 4 available locally", ui: ui)
        for id in [AppUIFixture.tumHiHo, AppUIFixture.kesariya] {
            let song = playButton(id, ui: ui)
            try ui.reveal(song)
            XCTAssertTrue(ui.accessibleText(song).contains("In use"))
            let remove = removeButton(id, ui: ui)
            XCTAssertTrue(remove.exists)
            XCTAssertFalse(remove.isEnabled)
            XCTAssertTrue(remove.label.contains("In use"))
            try assertMinimumTarget(remove, ui: ui)
        }
        try closeSettings(ui)
        XCTAssertEqual(mini.label, selection)
        XCTAssertEqual(mini.value as? String, playbackState)
        try ui.openPlayer()
        try ui.expectCurrentTrack(AppUIFixture.tumHiHo)
        try ui.assertPausedPositionStaysPut()
        try ui.closePlayer()
        try assertNoNetwork(ui)
    }

    func testRemovalThatBecomesInUseKeepsItsRowAndDoesNotClaimSuccess() throws {
        let ui = makeDriver()
        try launch(ui, scenario: .retainOnRemove)
        try openCachedSongs(ui)
        try search("Brahmastra", ui: ui)
        try expectCount("1 of 5 songs · 1 available locally", ui: ui)
        let song = playButton(AppUIFixture.kesariya, ui: ui)
        let remove = removeButton(AppUIFixture.kesariya, ui: ui)
        try ui.reveal(remove)
        try ui.tap(remove)
        try ui.wait("A live retention decision must keep the row and disable its remove action") {
            song.exists && !remove.isEnabled && ui.accessibleText(song).contains("In use")
        }
        XCTAssertTrue(ui.accessibleText(song).contains("2 versions"))
        XCTAssertFalse(ui.accessibleText(ui.element("message.text")).localizedCaseInsensitiveContains("removed"))
        XCTAssertFalse(ui.element("cachedSongs.search.empty").exists)
    }

    func testOfflineEmptyCacheHasClearHelpAndAReachableLibraryAction() throws {
        let ui = makeDriver()
        try launch(ui, scenario: .empty)
        try openCachedSongs(ui)
        try expectCount("0 songs · 0 available locally", ui: ui)
        try ui.reveal(ui.element("cachedSongs.empty"))
        XCTAssertTrue(ui.element("cachedSongs.offline").exists)
        XCTAssertTrue(ui.app.staticTexts["No cached songs yet"].exists)
        XCTAssertFalse(ui.element("cachedSongs.unsupported").exists)
        XCTAssertFalse(ui.app.buttons["cachedSongs.play"].isEnabled)
        XCTAssertFalse(ui.app.buttons["cachedSongs.shuffle"].isEnabled)
        let library = ui.app.buttons["cachedSongs.library"]
        try ui.reveal(library)
        try assertMinimumTarget(library, ui: ui)
        try ui.tap(library)
        try ui.wait("The empty-cache action must open the saved library") { ui.app.buttons["library.likes"].isHittable }
        XCTAssertFalse(ui.app.navigationBars["Storage"].exists)
        try assertNoNetwork(ui)
    }

    func testNilCapabilityIsUnavailableRatherThanAVerifiedEmptyCache() throws {
        let ui = makeDriver()
        try launch(ui, scenario: .unsupported)
        try openStorage(ui)
        try ui.wait("A nil cache capability must remain explicitly unavailable") {
            ui.app.buttons["storage.cachedSongs"].value as? String == "Unavailable"
                && ui.accessibleText(ui.element("storage.audio.usage")).contains("Unavailable")
        }
        let audio = ui.accessibleText(ui.element("storage.audio.usage"))
        XCTAssertTrue(audio.contains("Unavailable"))
        XCTAssertFalse(audio.contains("0 bytes"))
        XCTAssertFalse(audio.contains("0 songs"))
        XCTAssertFalse(ui.app.buttons["storage.clear.audio"].isEnabled)
        try openCachedSongs(ui)
        try ui.reveal(ui.element("cachedSongs.unsupported"))
        XCTAssertFalse(ui.element("cachedSongs.empty").exists)
        XCTAssertFalse(ui.element("cachedSongs.count").exists)
        XCTAssertFalse(ui.app.buttons["cachedSongs.play"].exists)
        XCTAssertFalse(ui.element("cachedSongs.error").exists)
    }

    func testReadFailureOffersInlineRetryWithoutClaimingTheCacheIsEmpty() throws {
        let ui = makeDriver()
        try launch(ui, scenario: .readError)
        try openCachedSongs(ui)
        let error = ui.element("cachedSongs.error")
        try ui.reveal(error)
        XCTAssertFalse(error.label.isEmpty)
        XCTAssertFalse(ui.element("cachedSongs.empty").exists)
        XCTAssertFalse(ui.element("cachedSongs.unsupported").exists)
        XCTAssertFalse(ui.element("cachedSongs.count").exists)
        let retry = ui.app.buttons["cachedSongs.retry"]
        try ui.reveal(retry)
        try assertMinimumTarget(retry, ui: ui)
        try ui.tap(retry)
        try expectCount("5 songs · 4 available locally", ui: ui)
        XCTAssertFalse(error.exists)
    }

    func testRemovalFailureKeepsTheRecordingUntilASuccessfulRetry() throws {
        let ui = makeDriver()
        try launch(ui, scenario: .removeError)
        try openCachedSongs(ui)
        try search("Brahmastra", ui: ui)
        try expectCount("1 of 5 songs · 1 available locally", ui: ui)
        let song = playButton(AppUIFixture.kesariya, ui: ui)
        let remove = removeButton(AppUIFixture.kesariya, ui: ui)
        try ui.reveal(remove)
        try ui.tap(remove)
        try ui.wait("A failed removal must report its error and keep the recording") {
            ui.element("cachedSongs.error").exists && song.exists && remove.isEnabled
        }
        XCTAssertTrue(ui.accessibleText(song).contains("2 versions"))
        let retry = ui.app.buttons["cachedSongs.retry"]
        try ui.reveal(retry, direction: .down)
        try ui.tap(retry)
        try expectCount("1 of 5 songs · 1 available locally", ui: ui)
        XCTAssertFalse(ui.element("cachedSongs.error").exists)
        try ui.reveal(remove)
        try ui.tap(remove)
        try expectCount("0 of 4 songs · 0 available locally", ui: ui)
        XCTAssertFalse(song.exists)
    }

    func testInitialSnapshotShowsLoadingWithoutZeroCountsOrAnUnsupportedState() throws {
        let ui = makeDriver()
        try launch(ui, scenario: .slow)
        try openCachedSongs(ui)
        try ui.requireHittable(ui.element("cachedSongs.loading"))
        XCTAssertFalse(ui.element("cachedSongs.count").exists)
        XCTAssertFalse(ui.element("cachedSongs.empty").exists)
        XCTAssertFalse(ui.element("cachedSongs.unsupported").exists)
        try ui.wait("The delayed real inventory must replace the loading state", timeout: 40) {
            let count = ui.app.staticTexts["cachedSongs.count"]
            return count.exists && count.label == "5 songs · 4 available locally"
        }
        XCTAssertFalse(ui.element("cachedSongs.loading").exists)
    }

    func testControlsRemainReachableAtLargestDynamicTypeOnPhoneAndIPad() throws {
        let ui = makeDriver()
        try launch(ui, additionalArguments: ["--light", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        try openStorage(ui)
        let link = ui.app.buttons["storage.cachedSongs"]
        try ui.reveal(link)
        try assertMinimumTarget(link, ui: ui)
        try openCachedSongs(ui)
        try expectCount("5 songs · 4 available locally", ui: ui)
        for id in ["cachedSongs.play", "cachedSongs.shuffle"] {
            let button = ui.app.buttons[id]
            try ui.reveal(button)
            try assertMinimumTarget(button, ui: ui)
        }
        try search("Tamasha", ui: ui)
        try expectCount("1 of 5 songs · 1 available locally", ui: ui)
        let song = playButton(AppUIFixture.agarTumSaathHo, ui: ui)
        try ui.reveal(song, maxSwipes: 16)
        try assertMinimumTarget(song, ui: ui)
        XCTAssertLessThanOrEqual(song.frame.width, 1000 + 1e-6)
        let remove = removeButton(AppUIFixture.agarTumSaathHo, ui: ui)
        try ui.reveal(remove)
        try assertMinimumTarget(remove, ui: ui)
        ui.capture("cached-songs-accessibility-text")
    }

    func testStorageClearsRecentlyOpenedWithoutLegacyTermsAndPersistsTheClear() throws {
        let ui = makeDriver()
        try launch(ui)
        try ui.tap(ui.app.buttons["tab.search"].firstMatch)
        let field = ui.app.textFields["search.field"]
        try ui.tap(field)
        try ui.dismissKeyboardIntroduction()
        field.typeText("Tamasha")
        try ui.tap(ui.app.buttons["search.dismissKeyboard"])
        let result = ui.app.buttons["track.play.\(AppUIFixture.agarTumSaathHo)"]
        try ui.reveal(result)
        try ui.tap(result)

        try openStorage(ui)
        try ui.expectMetric("storage.searches.count", number: 1, description: "Recently opened")
        XCTAssertFalse(ui.element("storage.searches.legacyCount").exists)
        let clear = ui.app.buttons["storage.clear.searches"]
        try ui.reveal(clear)
        try assertMinimumTarget(clear, ui: ui)
        XCTAssertTrue(clear.isEnabled, "Typed destinations alone must enable search-history clearing")
        try ui.tap(clear)
        XCTAssertTrue(ui.app.alerts.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Recently opened")).firstMatch.exists)
        try ui.tap(ui.app.alerts.buttons["Cancel"])
        try ui.expectMetric("storage.searches.count", number: 1, description: "Recently opened")
        try ui.reveal(clear)
        try ui.tap(clear)
        try ui.tap(ui.app.alerts.buttons["Clear"])
        try ui.expectMetric("storage.searches.count", number: 0, description: "Recently opened")
        try ui.reveal(clear)
        try ui.wait("A successful typed-history clear must show its result and disable Clear") {
            ui.element("storage.result.searches").exists && !clear.isEnabled
        }
        XCTAssertFalse(ui.element("storage.error.searches").exists)
        try closeSettings(ui)
        try ui.tap(ui.app.buttons["tab.search"].firstMatch)
        if ui.app.buttons["search.clear"].exists {
            try ui.clearSearch()
            try ui.tap(ui.app.buttons["search.dismissKeyboard"])
        } else if ui.app.buttons["search.dismissKeyboard"].exists {
            try ui.tap(ui.app.buttons["search.dismissKeyboard"])
        }
        try ui.reveal(ui.app.staticTexts["search.recents.empty"])
        XCTAssertFalse(ui.app.buttons["search.recent.track:\(AppUIFixture.agarTumSaathHo)"].exists)

        try launch(ui, reset: false)
        try openStorage(ui)
        try ui.expectMetric("storage.searches.count", number: 0, description: "Recently opened")
        try ui.reveal(clear)
        XCTAssertFalse(clear.isEnabled)
        XCTAssertFalse(ui.element("storage.searches.legacyCount").exists)
    }

    private func makeDriver() -> AppUITestDriver {
        let ui = AppUITestDriver(testCase: self, prefix: "cached-songs")
        addTeardownBlock { await ui.finish() }
        return ui
    }

    private func launch(_ ui: AppUITestDriver, scenario: Scenario? = nil, reset: Bool = true,
                        additionalArguments: [String] = []) throws {
        ui.app.terminate()
        XCUIDevice.shared.orientation = .portrait
        ui.app.launchArguments = ["--uitesting", "--seed-ui", "--skip-welcome", "--cache-fixture", "--offline-fixture"]
            + (reset ? ["--reset-ui"] : []) + (scenario.map { [$0.rawValue] } ?? []) + additionalArguments
            + ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        ui.app.launchEnvironment = ["GANABAJANA_TEST_STORE": ui.storeName]
        ui.app.launch()
        // Native iPad top tabs are plain buttons; the shared driver's launch waits for a phone tab bar.
        try ui.requireHittable(ui.app.buttons["tab.home"].firstMatch, timeout: 25)
    }

    private func openStorage(_ ui: AppUITestDriver) throws {
        if ui.app.navigationBars["Storage"].exists { return }
        try ui.tap(ui.app.buttons["tab.home"].firstMatch)
        try ui.reveal(ui.app.buttons["home.settings"], direction: .down, maxSwipes: 16)
        try ui.tap(ui.app.buttons["home.settings"])
        try ui.requireHittable(ui.app.buttons["settings.done"])
        let storage = ui.app.buttons["settings.storage"]
        try ui.reveal(storage, maxSwipes: 16)
        try ui.tap(storage)
        try ui.wait("Settings must open Storage") { ui.app.navigationBars["Storage"].exists }
    }

    private func openCachedSongs(_ ui: AppUITestDriver) throws {
        try openStorage(ui)
        let link = ui.app.buttons["storage.cachedSongs"]
        try ui.reveal(link, maxSwipes: 16)
        try ui.tap(link)
        try ui.wait("Storage must open the cached-song browser") { ui.app.navigationBars["Cached songs"].exists }
    }

    private func closeSettings(_ ui: AppUITestDriver) throws {
        if ui.app.navigationBars["Cached songs"].exists {
            try cancelSearch(ui)
            try back(from: "Cached songs", to: "Storage", ui: ui)
        }
        try back(from: "Storage", to: "Settings", ui: ui)
        try ui.tap(ui.app.buttons["settings.done"])
        try ui.wait("Closing Storage must return to the app") { !ui.app.navigationBars["Settings"].exists }
    }

    private func back(from title: String, to parent: String, ui: AppUITestDriver) throws {
        let bar = ui.app.navigationBars[title]
        let back = bar.buttons[parent].exists ? bar.buttons[parent] : bar.buttons["Back"]
        try ui.tap(back)
        try ui.wait("Back must return to \(parent)") { ui.app.navigationBars[parent].exists }
    }

    private func search(_ query: String, ui: AppUITestDriver) throws {
        let field = ui.app.searchFields.firstMatch
        try ui.reveal(field, direction: .down, maxSwipes: 16)
        try ui.tap(field)
        try ui.dismissKeyboardIntroduction()
        let existing = field.value as? String ?? ""
        if !existing.isEmpty, existing != field.placeholderValue {
            let clear = field.buttons["Clear text"]
            if clear.exists { try ui.tap(clear) }
            else {
                try ui.replaceSelectedText(in: field, with: query)
                field.typeText("\n")
                return
            }
        }
        field.typeText(query + "\n")
        try ui.expectValue(field, query)
    }

    private func cancelSearch(_ ui: AppUITestDriver) throws {
        let field = ui.app.searchFields.firstMatch
        guard field.exists else { return }
        let cancel = ui.app.navigationBars["Cached songs"].buttons.matching(NSPredicate(
            format: "label IN %@", ["Cancel", "Close", "Close Search", "Close search"]
        )).firstMatch
        let query = field.value as? String ?? ""
        guard cancel.exists || (!query.isEmpty && query != field.placeholderValue) else { return }
        if !cancel.exists || !cancel.isHittable {
            try ui.reveal(field, direction: .down, maxSwipes: 16)
            try ui.tap(field)
        }
        try ui.tap(cancel)
        try ui.wait("Cancelling local search must clear the filter") {
            !field.exists || (field.value as? String) == "" || (field.value as? String) == field.placeholderValue
        }
        try assertCachedSearchDismissed(ui)
    }

    private func assertCachedSearchDismissed(_ ui: AppUITestDriver) throws {
        try ui.wait("Playback or native search dismissal must hide the keyboard and restore navigation") {
            let bar = ui.app.navigationBars["Cached songs"]
            let back = bar.buttons["Storage"].exists ? bar.buttons["Storage"] : bar.buttons["Back"]
            return !ui.app.keyboards.firstMatch.exists && back.exists && back.isHittable
        }
    }

    private func expectCount(_ text: String, ui: AppUITestDriver) throws {
        let count = ui.app.staticTexts["cachedSongs.count"]
        try ui.wait("The inventory must report its actual rows and local availability") { count.exists && count.label == text }
        try ui.reveal(count, direction: .down, maxSwipes: 16)
    }

    private func playButton(_ id: String, ui: AppUITestDriver) -> XCUIElement { ui.app.buttons["cachedSongs.play.\(id)"] }
    private func removeButton(_ id: String, ui: AppUITestDriver) -> XCUIElement { ui.app.buttons["cachedSongs.remove.\(id)"] }

    private func assertPlaybackQueue(_ ids: [String], current: String? = nil, shuffled: Bool, ui: AppUITestDriver) throws {
        try ui.openPlayer()
        let selected = try XCTUnwrap(current ?? ids.first(where: { ui.app.staticTexts["player.track.\($0)"].exists }))
        try ui.expectCurrentTrack(selected)
        try ui.waitForAdvance(from: 0, by: 1)
        try ui.pause()
        try ui.openPlayerSheet("queue", title: "Queue")
        let rows = ui.app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "queue.play."))
        try ui.wait("The queue must contain only the chosen playable cached recordings") { rows.count == ids.count }
        XCTAssertEqual(ui.app.buttons["player.shuffle"].isSelected, shuffled)
        for id in ids { try ui.reveal(ui.queueSong(id: id)) }
        XCTAssertFalse(ui.queueSong(id: AppUIFixture.shapeOfYou).exists)
        XCTAssertFalse(ui.queueSong(id: AppUIFixture.blindingLights).exists)
        try ui.closeSheet("Queue")
        try ui.closePlayer()
        try assertNoNetwork(ui)
        try ui.expectValue(ui.element("cacheFixture.playbackSource"), "local")
    }

    private func assertNoNetwork(_ ui: AppUITestDriver) throws {
        let requests = ui.element("cacheFixture.networkRequests")
        try ui.wait("The offline fixture must expose its network-attempt counter") { requests.exists }
        XCTAssertEqual(requests.value as? String, "0", "Browsing and cached playback must not attempt remote extraction or media requests")
    }

    private func assertMinimumTarget(_ element: XCUIElement, ui: AppUITestDriver,
                                     file: StaticString = #filePath, line: UInt = #line) throws {
        try ui.requireHittable(element)
        XCTAssertGreaterThanOrEqual(element.frame.width + 1e-6, 44, file: file, line: line)
        XCTAssertGreaterThanOrEqual(element.frame.height + 1e-6, 44, file: file, line: line)
        let window = ui.app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(element.frame.minX, window.minX - 1e-6, file: file, line: line)
        XCTAssertLessThanOrEqual(element.frame.maxX, window.maxX + 1e-6, file: file, line: line)
    }

    private enum Scenario: String {
        case empty = "--cache-fixture-empty"
        case unsupported = "--cache-fixture-unsupported"
        case readError = "--cache-fixture-read-error"
        case removeError = "--cache-fixture-remove-error"
        case inUse = "--cache-fixture-in-use"
        case retainOnRemove = "--cache-fixture-retain-on-remove"
        case slow = "--cache-fixture-slow"
    }

    private enum Fixture {
        // The cache fixture has these four playable IDs, incompatible Shape of You, and an unfinished Blinding Lights.
        // Kesariya has two encodings; Agar Tum Saath Ho has legacy metadata; the unknown ID has no library metadata.
        static let unknownID = "CacheOnly01"
        static let playableIDs = [AppUIFixture.tumHiHo, AppUIFixture.kesariya, AppUIFixture.agarTumSaathHo, unknownID]
    }
}

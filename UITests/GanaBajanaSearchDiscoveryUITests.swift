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
        XCTAssertGreaterThanOrEqual(toolbarDone.frame.height, 44)
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
        try expectSearchAtTop(ui)
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

    func testSearchReselectScrollsDiscoveryToTheTopAndFocusesTheField() throws {
        let ui = makeDriver()
        try ui.launch()
        try openRadioDiscovery(ui)
        let firstFilter = ui.app.buttons["search.filter.songs"]
        let content = ui.app.scrollViews["search.content"]
        try ui.reveal(ui.app.buttons["search.station.left-field-rap"], maxSwipes: 16)
        XCTAssertTrue(!firstFilter.exists || firstFilter.frame.maxY < content.frame.minY,
                      "The test must begin scrolled away from the top")
        try tapSearch(ui)
        try expectSearchAtTop(ui)
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
        try ui.requireHittable(ui.app.buttons["Remove from liked songs"])
        XCTAssertFalse(ui.app.buttons["Dislike song"].exists)
        try ui.tap(ui.app.buttons["Remove from liked songs"])
        try ui.tap(menu)
        try ui.requireHittable(ui.app.buttons["Dislike song"])
        XCTAssertTrue(ui.app.buttons["Like song"].exists)
    }

    func testStarterOrderAndDeliberateRecentSearchesSurviveRelaunchAndRemoval() throws {
        let ui = makeDriver()
        try ui.launch()
        try tapSearch(ui)
        try ui.tap(ui.app.buttons["search.dismissKeyboard"])
        try expectKeyboardDismissed(ui)
        let artists = ["Kanye West", "A. R. Rahman", "Char Diwaari", "Shreya Ghoshal", "Radiohead"]
        var previousY = -CGFloat.infinity
        for artist in artists {
            let suggestion = ui.app.buttons["search.suggestion.\(artist)"]
            try ui.reveal(suggestion)
            XCTAssertGreaterThan(suggestion.frame.minY, previousY)
            XCTAssertGreaterThanOrEqual(suggestion.frame.height, 44)
            previousY = suggestion.frame.minY
        }

        let field = ui.app.textFields["search.field"]
        try ui.tap(field)
        field.typeText("Arijit")
        try ui.waitForSearchResults()
        try ui.clearSearch()
        try ui.tap(ui.app.buttons["search.dismissKeyboard"])
        try expectKeyboardDismissed(ui)
        XCTAssertFalse(ui.app.staticTexts["Recent searches"].exists, "Typing and background lookup are not committed searches")
        try ui.tap(ui.app.buttons["search.suggestion.Kanye West"])
        try ui.clearSearch()
        field.typeText("Tum Hi Ho")
        try ui.waitForSearchResults()
        try ui.tap(ui.app.buttons["track.play.\(AppUIFixture.tumHiHo)"])
        try expectKeyboardDismissed(ui)
        try ui.clearSearch()
        field.typeText("Blinding Lights")
        try ui.tap(ui.app.buttons["search.dismissKeyboard"])
        try expectKeyboardDismissed(ui)

        try ui.relaunch()
        try tapSearch(ui)
        try ui.tap(ui.app.buttons["search.dismissKeyboard"])
        try expectKeyboardDismissed(ui)
        let first = ui.app.buttons["search.recent.blinding lights"]
        let second = ui.app.buttons["search.recent.tum hi ho"]
        let third = ui.app.buttons["search.recent.kanye west"]
        for recent in [first, second, third] { try ui.reveal(recent) }
        XCTAssertLessThan(first.frame.minY, second.frame.minY)
        XCTAssertLessThan(second.frame.minY, third.frame.minY)
        XCTAssertFalse(ui.app.buttons["search.recent.arijit"].exists)
        try ui.tap(second)
        try ui.clearSearch()
        try ui.tap(ui.app.buttons["search.dismissKeyboard"])
        try expectKeyboardDismissed(ui)
        XCTAssertLessThan(second.frame.minY, first.frame.minY)
        try ui.tap(ui.app.buttons["search.recent.remove.blinding lights"])
        XCTAssertFalse(first.exists)
        ui.capture("search-discovery-recent-searches-after-relaunch")
        try ui.tap(ui.app.buttons["search.recents.clear"])
        XCTAssertFalse(ui.app.staticTexts["Recent searches"].exists)
        try ui.relaunch()
        try tapSearch(ui)
        try ui.tap(ui.app.buttons["search.dismissKeyboard"])
        try expectKeyboardDismissed(ui)
        XCTAssertFalse(ui.app.staticTexts["Recent searches"].exists)
        try ui.selectTab("library")
        try ui.tap(ui.app.buttons["library.likes"])
        try ui.reveal(ui.app.staticTexts["5 songs"])
    }

    func testStationPlaysRealQueueAndContinuesWhenGeneralAutoplayIsOff() throws {
        let ui = makeDriver()
        try ui.launch()
        try ui.openSettings()
        try ui.setSwitch("settings.autoplay", to: false)
        try ui.tap(ui.app.buttons["settings.done"])
        try tapSearch(ui)
        try ui.tap(ui.app.buttons["search.dismissKeyboard"])
        try expectKeyboardDismissed(ui)
        let station = ui.app.buttons["search.station.melancholy"]
        try ui.reveal(station)
        XCTAssertTrue(station.label.contains("Radio"))
        try openRadioSetup(ui, station: station)
        XCTAssertEqual(ui.app.staticTexts["radio.setup.selectionCount"].label, "0 of 4 hints")
        XCTAssertEqual(ui.app.buttons["radio.setup.start"].value as? String, "Style defaults")
        try startConfiguredRadio(ui)
        try expectStation(ui, title: "Melancholy", song: "Apocalypse")
        XCTAssertFalse(ui.app.staticTexts["Recent searches"].exists)
        try ui.openPlayer()
        try ui.expectCurrentTrack("fixture.experience.seed.0")
        try ui.waitForAdvance(from: 0, by: 1)
        try ui.pause()
        try ui.openPlayerSheet("queue", title: "Queue")
        try expectQueueRadioLabel(ui, station: "Melancholy")
        for index in 0..<4 {
            try ui.reveal(ui.element("queue.play.\(index).fixture.experience.seed.\(index)"))
        }
        let lastInitialSong = ui.element("queue.play.15.fixture.experience.radio.3.2")
        try ui.reveal(lastInitialSong, maxSwipes: 20)
        try ui.tap(lastInitialSong)
        try ui.expectCurrentTrack("fixture.experience.radio.3.2")
        try ui.waitForAdvance(from: 0, by: 1)
        try ui.pause()
        try ui.openPlayerSheet("queue", title: "Queue")
        try expectQueueRadioLabel(ui, station: "Melancholy")
        let continuation = ui.app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@", "queue.play.", "fixture.experience.radio.0.3")).firstMatch
        try ui.reveal(continuation, maxSwipes: 24)
        ui.capture("search-discovery-station-continued-with-autoplay-off")
        try ui.closeSheet("Queue")
        try ui.closePlayer()
        try ui.openSettings()
        try ui.expectSwitch("settings.autoplay", isOn: false)
    }

    func testFastStationReselectKeepsTheNewStationAndExistingPlaybackDuringLoading() throws {
        let ui = makeDriver()
        try ui.launch(additionalArguments: ["--slow-experience-radio"])
        try tapSearch(ui)
        ui.app.textFields["search.field"].typeText("Tum Hi Ho")
        try ui.waitForSearchResults()
        try ui.tap(ui.app.buttons["track.play.\(AppUIFixture.tumHiHo)"])
        try expectKeyboardDismissed(ui)
        try ui.clearSearch()
        try ui.tap(ui.app.buttons["search.dismissKeyboard"])
        try expectKeyboardDismissed(ui)
        let melancholy = ui.app.buttons["search.station.melancholy"]
        let gym = ui.app.buttons["search.station.hindi-gym"]
        try ui.reveal(melancholy)
        try startRadio(ui, station: melancholy)
        try ui.wait("The selected radio tile must acknowledge loading") { melancholy.value as? String == "Loading" }
        XCTAssertTrue(ui.app.buttons["miniPlayer.open"].label.contains("Tum Hi Ho"))
        try ui.reveal(gym)
        try startRadio(ui, station: gym)
        try ui.wait("Reselecting must move the loading indication to the new station") { gym.value as? String == "Loading" }
        XCTAssertEqual(radioLoadingIndicators(ui).count, 1)
        XCTAssertEqual(radioLoadingIndicators(ui).firstMatch.identifier, "search.station.progress.hindi-gym")
        try expectStation(ui, title: "Hindi gym", song: "Zinda", timeout: 20)
        XCTAssertEqual(gym.value as? String, "Current station")
        XCTAssertNotEqual(melancholy.value as? String, "Current station")
        try ui.openPlayer()
        try ui.expectCurrentTrack("fixture.experience.seed.4")
        try ui.waitForAdvance(from: 0, by: 1)
        try ui.pause()
        try ui.openPlayerSheet("queue", title: "Queue")
        try expectQueueRadioLabel(ui, station: "Hindi gym")
        try ui.reveal(ui.element("queue.play.1.fixture.experience.seed.5"))
        XCTAssertFalse(ui.element("queue.play.0.fixture.experience.seed.0").exists)
        ui.capture("search-discovery-fast-station-reselection")
    }

    func testRadioLoadingUsesOneSpinnerAndKeepsTilesAndHeaderFixedThroughReadiness() throws {
        let ui = makeDriver()
        try ui.launch(additionalArguments: ["--slow-experience-radio"])
        try tapSearch(ui)
        ui.app.textFields["search.field"].typeText("Tum Hi Ho")
        try ui.waitForSearchResults()
        try ui.tap(ui.app.buttons["track.play.\(AppUIFixture.tumHiHo)"])
        try expectKeyboardDismissed(ui)
        try ui.requireHittable(ui.app.buttons["miniPlayer.open"])
        try ui.clearSearch()
        try ui.tap(ui.app.buttons["search.dismissKeyboard"])
        try expectKeyboardDismissed(ui)

        let station = ui.app.buttons["search.station.melancholy"]
        let other = ui.app.buttons["search.station.hindi-gym"]
        try ui.reveal(station)
        try ui.requireHittable(other)
        XCTAssertTrue(ui.element("search.radio.header").exists)
        let frames = radioLayoutFrames(ui)
        let labels = [station.label, other.label]
        let progress = radioLoadingIndicators(ui)
        XCTAssertEqual(progress.count, 0)
        XCTAssertFalse(ui.app.buttons["search.station.active"].exists)

        try startRadio(ui, station: station)
        try ui.wait("Only the tapped station must report loading") { station.value as? String == "Loading" }
        assertRadioLayout(ui, matches: frames)
        XCTAssertEqual(progress.count, 1, "Count radio indicators only, not Home or the mini-player")
        XCTAssertEqual(progress.firstMatch.identifier, "search.station.progress.melancholy")
        XCTAssertEqual([station.label, other.label], labels)
        assertNoRadioLoadingCopy(ui)

        try expectStation(ui, title: "Melancholy", song: "Apocalypse", timeout: 20)
        assertRadioLayout(ui, matches: frames)
        XCTAssertEqual(progress.count, 0)
        XCTAssertEqual([station.label, other.label], labels)
        assertNoRadioLoadingCopy(ui)
        let active = ui.app.buttons["search.station.active"]
        XCTAssertEqual(active.frame.width, 44, accuracy: 1)
        XCTAssertEqual(active.frame.height, 44, accuracy: 1)
        XCTAssertTrue(active.label.contains("Melancholy Radio"))
        try ui.tap(active)
        try ui.expectCurrentTrack("fixture.experience.seed.0")
    }

    func testTappingALoadingRadioAgainCancelsWithoutMovingTheGrid() throws {
        let ui = makeDriver()
        try ui.launch(additionalArguments: ["--slow-experience-radio"])
        try openRadioDiscovery(ui)
        let station = ui.app.buttons["search.station.melancholy"]
        try ui.reveal(station)
        try ui.requireHittable(ui.app.buttons["search.station.hindi-gym"])
        XCTAssertTrue(ui.element("search.radio.header").exists)
        let frames = radioLayoutFrames(ui)
        try startRadio(ui, station: station)
        try ui.wait("The station must be loading before cancellation") { station.value as? String == "Loading" }
        try ui.tap(station)
        try ui.wait("Tapping the pending station again must cancel it") { station.value as? String == "Play radio" }
        assertRadioLayout(ui, matches: frames)
        XCTAssertEqual(radioLoadingIndicators(ui).count, 0)
        assertNoRadioLoadingCopy(ui)
        let unwantedPlayback = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated {
                ui.app.buttons["search.station.active"].exists || ui.app.buttons["miniPlayer.open"].exists
            }
        }, object: nil)
        unwantedPlayback.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [unwantedPlayback], timeout: 7), .completed,
                       "A cancelled radio must not become active when its slow request would have finished")
    }

    func testTransientRadioFailureRecoversWithProviderSongs() throws {
        let ui = makeDriver()
        try ui.launch(additionalArguments: ["--fail-experience-radio-once"])
        try tapSearch(ui)
        try ui.tap(ui.app.buttons["search.dismissKeyboard"])
        try expectKeyboardDismissed(ui)
        let station = ui.app.buttons["search.station.melancholy"]
        try ui.reveal(station)
        try startRadio(ui, station: station)
        try expectStation(ui, title: "Melancholy", song: "Apocalypse", timeout: 20)
        XCTAssertFalse(ui.app.staticTexts["search.station.error"].exists)
        try ui.openPlayer()
        try ui.waitForAdvance(from: 0, by: 1)
        try ui.pause()
        try ui.openPlayerSheet("queue", title: "Queue")
        try ui.reveal(ui.element("queue.play.4.fixture.experience.radio.0.0"))
        try expectQueueRadioLabel(ui, station: "Melancholy")
    }

    func testRadioDiscoveryFollowsSavedLanguagesAndUsesMatchingVariantCopy() throws {
        let ui = makeDriver()
        try ui.launch()
        try selectDiscoveryLanguages(ui, hindi: false, english: true)
        try openRadioDiscovery(ui)
        try ui.reveal(ui.app.buttons["search.station.melancholy"])
        XCTAssertFalse(ui.app.buttons["search.station.hindi-gym"].exists)
        let rap = ui.app.buttons["search.station.left-field-rap"]
        try ui.reveal(rap)
        XCTAssertTrue(rap.label.contains("Kanye West") && rap.label.contains("Tyler, The Creator"))
        XCTAssertFalse(rap.label.contains("Char Diwaari"))
        try ui.relaunch()
        try openRadioDiscovery(ui)
        try ui.reveal(ui.app.buttons["search.station.melancholy"])
        XCTAssertFalse(ui.app.buttons["search.station.hindi-gym"].exists)

        try selectDiscoveryLanguages(ui, hindi: true, english: false)
        try openRadioDiscovery(ui)
        let gym = ui.app.buttons["search.station.hindi-gym"]
        try ui.reveal(gym)
        XCTAssertTrue(gym.label.contains("Hindi + Punjabi"))
        XCTAssertFalse(ui.app.buttons["search.station.melancholy"].exists)
        try ui.reveal(rap)
        XCTAssertTrue(rap.label.contains("Char Diwaari") && rap.label.contains("Seedhe Maut"))
        XCTAssertFalse(rap.label.contains("Kanye West"))

        try selectDiscoveryLanguages(ui, hindi: true, english: true)
        try openRadioDiscovery(ui)
        try ui.reveal(gym)
        try ui.reveal(ui.app.buttons["search.station.melancholy"], direction: .down)
        try ui.reveal(rap)
        XCTAssertTrue(rap.label.contains("Kanye West") && rap.label.contains("Char Diwaari"))
    }

    func testMixedRadioStartsOnlyTheSelectedLanguageSeedGroup() throws {
        let ui = makeDriver()
        try ui.launch()
        let cases = [(hindi: false, english: true, song: "Flashing Lights", first: 28, second: 30),
                     (hindi: true, english: false, song: "Jhaag", first: 29, second: 31)]
        for selection in cases {
            try selectDiscoveryLanguages(ui, hindi: selection.hindi, english: selection.english)
            try openRadioDiscovery(ui)
            let station = ui.app.buttons["search.station.left-field-rap"]
            try ui.reveal(station)
            try startRadio(ui, station: station)
            try expectStation(ui, title: "Left-field rap", song: selection.song)
            try ui.openPlayer()
            try ui.expectCurrentTrack("fixture.experience.seed.\(selection.first)")
            try ui.waitForAdvance(from: 0, by: 1)
            try ui.pause()
            try ui.openPlayerSheet("queue", title: "Queue")
            try ui.reveal(ui.element("queue.play.0.fixture.experience.seed.\(selection.first)"))
            try ui.reveal(ui.element("queue.play.1.fixture.experience.seed.\(selection.second)"))
            try expectQueueRadioLabel(ui, station: "Left-field rap")
            try ui.closeSheet("Queue")
            try ui.closePlayer()
        }
    }

    func testClassicRadiosPlayFromTheirLanguageScopedDiscoveryTiles() throws {
        let ui = makeDriver()
        try ui.launch()
        let cases = [(id: "hindi-classics", title: "Hindi classics", song: "Lag Ja Gale Se Phir", hindi: true, seed: 32),
                     (id: "english-golden-oldies", title: "English golden oldies", song: "Here Comes The Sun", hindi: false, seed: 36)]
        for selection in cases {
            try selectDiscoveryLanguages(ui, hindi: selection.hindi, english: !selection.hindi)
            try openRadioDiscovery(ui)
            let station = ui.app.buttons["search.station.\(selection.id)"]
            try ui.reveal(station)
            XCTAssertTrue(station.label.contains("Radio"))
            try openRadioSetup(ui, station: station)
            XCTAssertTrue(ui.app.buttons["radio.setup.era.older"].isSelected)
            try startConfiguredRadio(ui)
            try expectStation(ui, title: selection.title, song: selection.song)
            try ui.openPlayer()
            try ui.expectCurrentTrack("fixture.experience.seed.\(selection.seed)")
            try ui.waitForAdvance(from: 0, by: 1)
            try ui.pause()
            try ui.openPlayerSheet("queue", title: "Queue")
            try expectQueueRadioLabel(ui, station: selection.title)
            try ui.reveal(ui.element("queue.play.0.fixture.experience.seed.\(selection.seed)"))
            try ui.reveal(ui.element("queue.play.1.fixture.experience.seed.\(selection.seed + 1)"))
            ui.capture("search-\(selection.id)-radio-queue")
            try ui.closeSheet("Queue")
            try ui.closePlayer()
        }
    }

    func testOptionalArtistAndEraEditsCanBeCancelledWithoutChangingPlayback() throws {
        let ui = makeDriver()
        try ui.launch()
        try ui.search("Tum Hi Ho")
        try ui.waitForSearchResults()
        try ui.tap(ui.app.buttons["track.play.\(AppUIFixture.tumHiHo)"])
        try ui.openPlayer()
        try ui.waitForAdvance(from: 0, by: 1)
        try ui.pause()
        let position = try ui.position()
        try ui.closePlayer()
        try ui.clearSearch()
        try ui.tap(ui.app.buttons["search.dismissKeyboard"])
        try expectKeyboardDismissed(ui)
        let station = ui.app.buttons["search.station.melancholy"]
        try ui.reveal(station)
        try openRadioSetup(ui, station: station)
        XCTAssertTrue(ui.app.buttons["radio.setup.era.anytime"].isSelected)
        try ui.expectSwitch("radio.setup.language.english", isOn: true)
        try ui.expectSwitch("radio.setup.language.hindi", isOn: false)
        let start = ui.app.buttons["radio.setup.start"]
        XCTAssertTrue(start.isEnabled)
        XCTAssertEqual(start.value as? String, "Style defaults")
        XCTAssertEqual(ui.app.staticTexts["radio.setup.selectionCount"].label, "0 of 4 hints")
        let height = start.frame.height
        let layout = Dictionary(uniqueKeysWithValues: ["radio.setup.options", "radio.setup.start",
            "radio.setup.artist.cigarettes after sex", "radio.setup.artist.pixies"].map { ($0, ui.element($0).frame) })
        try ui.tap(ui.app.buttons["radio.setup.era.older"])
        XCTAssertTrue(start.isEnabled)
        XCTAssertEqual(start.frame.height, height, accuracy: 1)
        try ui.tap(ui.app.buttons["radio.setup.era.newer"])
        XCTAssertTrue(start.isEnabled, "Era eligibility is resolved after Start, without an artist-count gate")
        XCTAssertEqual(start.frame.height, height, accuracy: 1)
        for (id, original) in layout {
            let frame = ui.element(id).frame
            XCTAssertFalse(original.isEmpty || frame.isEmpty, id)
            XCTAssertEqual(frame.minY, original.minY, accuracy: 1, "Preference edits must not move \(id)")
            XCTAssertEqual(frame.height, original.height, accuracy: 1, "Preference edits must not resize \(id)")
        }
        try ui.tap(ui.app.buttons["radio.setup.era.anytime"])
        try ui.setSwitch("radio.setup.language.english", to: false)
        XCTAssertFalse(start.isEnabled, "A language is required even though artist hints are optional")
        XCTAssertEqual(ui.app.staticTexts["radio.setup.summary"].label, "Choose at least one language.")
        try ui.setSwitch("radio.setup.language.english", to: true)
        XCTAssertTrue(start.isEnabled)
        try setSetupArtist(ui, "cigarettes after sex", selected: true)
        XCTAssertTrue(start.isEnabled)
        XCTAssertEqual(ui.app.staticTexts["radio.setup.selectionCount"].label, "1 of 4 hints")
        try ui.reveal(ui.app.buttons["radio.setup.clearArtists"], direction: .down)
        try ui.tap(ui.app.buttons["radio.setup.clearArtists"])
        XCTAssertTrue(start.isEnabled)
        XCTAssertEqual(start.value as? String, "Style defaults")
        ui.capture("radio-setup-optional-hints-and-cancel-iphone17pro")
        try cancelRadioSetup(ui)
        XCTAssertFalse(ui.app.buttons["search.station.active"].exists)
        XCTAssertEqual(radioLoadingIndicators(ui).count, 0)
        try ui.openPlayer()
        try ui.expectCurrentTrack(AppUIFixture.tumHiHo)
        try ui.expectPosition(position)
        try ui.expectLabel(ui.app.buttons["player.playPause"], "Play")
        try ui.openPlayerSheet("queue", title: "Queue")
        try ui.reveal(ui.element("queue.play.0.\(AppUIFixture.tumHiHo)"))
        XCTAssertFalse(ui.element("queue.play.0.fixture.experience.seed.0").exists)
    }

    func testArtistSearchAndNewerEraUseTheAddedArtistsActualDatedRecording() throws {
        let ui = makeDriver()
        try ui.launch()
        try openRadioDiscovery(ui)
        let station = ui.app.buttons["search.station.melancholy"]
        try ui.reveal(station)
        try openRadioSetup(ui, station: station)
        try ui.tap(ui.app.buttons["radio.setup.era.newer"])
        XCTAssertTrue(ui.app.buttons["radio.setup.start"].isEnabled)
        let field = ui.app.textFields["radio.setup.artistSearch"]
        try ui.reveal(field)
        try ui.tap(field)
        try ui.dismissKeyboardIntroduction()
        field.typeText("Norah")
        let result = ui.app.buttons["radio.setup.addArtist.UCfixtureRadioNorah00001"]
        try ui.wait("Artist search must return an addable provider artist") { result.exists }
        let keyboardDone = ui.app.buttons["radio.setup.dismissKeyboard"]
        try ui.requireHittable(keyboardDone)
        XCTAssertGreaterThanOrEqual(keyboardDone.frame.height, 44)
        try ui.tap(keyboardDone)
        try ui.wait("The setup keyboard must dismiss without closing the draft") { !ui.app.keyboards.firstMatch.exists }
        try ui.reveal(result)
        try ui.tap(result)
        XCTAssertTrue(ui.app.buttons["radio.setup.start"].isEnabled, "A single artist hint can start a mood-led station")
        XCTAssertEqual(ui.app.staticTexts["radio.setup.selectionCount"].label, "1 of 4 hints")
        ui.capture("radio-setup-newer-with-added-artist-iphone17pro")
        try startConfiguredRadio(ui)
        try expectStation(ui, title: "Melancholy", song: "Apocalypse")
        XCTAssertTrue(ui.app.buttons["search.station.active"].label.contains("Newer"))
        try ui.openPlayer()
        try ui.expectCurrentTrack("fixture.experience.seed.0")
        try ui.waitForAdvance(from: 0, by: 1)
        try ui.pause()
        try ui.openPlayerSheet("queue", title: "Queue")
        try ui.reveal(ui.element("queue.play.1.fixture.setup.norah.2016"))
        XCTAssertFalse(ui.element("queue.play.1.fixture.setup.norah.2002").exists)
        try ui.reveal(ui.element("queue.play.3.fixture.setup.radio.norah.0"))
        try expectQueueRadioLabel(ui, station: "Melancholy")
    }

    func testRevealScrollsOptionalArtistsWithoutStartingRadio() throws {
        let ui = makeDriver()
        try ui.launch()
        try openRadioDiscovery(ui)
        let station = ui.app.buttons["search.station.melancholy"]
        for era in ["newer", "anytime"] {
            try ui.reveal(station)
            try openRadioSetup(ui, station: station)
            try ui.tap(ui.app.buttons["radio.setup.era.\(era)"])
            let start = ui.app.buttons["radio.setup.start"]
            XCTAssertTrue(start.isEnabled)
            XCTAssertEqual(start.value as? String, "Style defaults")
            let options = ui.app.scrollViews["radio.setup.options"]
            let artist = ui.app.buttons["radio.setup.artist.radiohead"]
            let before = artist.frame
            let background = ui.app.buttons["search.suggestion.Radiohead"]
            let backgroundFrame = background.frame
            let startFrame = start.frame
            XCTAssertGreaterThan(before.midY, options.frame.maxY, "The regression needs a row whose center is clipped")
            XCTAssertLessThan(before.intersection(options.frame).height, 44)
            ui.capture("radio-reveal-\(era)-clipped-before")

            try ui.reveal(artist)

            let visible = artist.frame.intersection(options.frame)
            XCTAssertLessThan(artist.frame.minY, before.minY, "Reveal must scroll the owning sheet before returning")
            XCTAssertLessThan(artist.frame.midY, options.frame.maxY)
            XCTAssertGreaterThanOrEqual(artist.frame.minY, ui.app.navigationBars["Set up radio"].frame.maxY)
            XCTAssertGreaterThanOrEqual(visible.height, 44)
            XCTAssertFalse(artist.isSelected, "Scrolling must not select an optional artist")
            XCTAssertTrue(start.isEnabled)
            XCTAssertEqual(start.frame.minY, startFrame.minY, accuracy: 1)
            XCTAssertEqual(background.frame.minY, backgroundFrame.minY, accuracy: 1, "The Search page beneath the sheet must not scroll")
            XCTAssertTrue(ui.app.navigationBars["Set up radio"].exists)
            ui.capture("radio-reveal-\(era)-visible-after")
            try setSetupArtist(ui, "radiohead", selected: true)
            try setSetupArtist(ui, "mazzy star", selected: true)
            XCTAssertTrue(start.isEnabled)
            try cancelRadioSetup(ui)
            XCTAssertFalse(ui.app.buttons["search.station.active"].exists)
            XCTAssertFalse(ui.app.buttons["miniPlayer.open"].exists)
        }
    }

    func testSetupLanguageChangesUseTheChosenVariantWithoutSavingDiscoveryPreferences() throws {
        let ui = makeDriver()
        try ui.launch()
        try selectDiscoveryLanguages(ui, hindi: true, english: true)
        try openRadioDiscovery(ui)
        let station = ui.app.buttons["search.station.left-field-rap"]
        try ui.reveal(station)
        try openRadioSetup(ui, station: station)
        try ui.setSwitch("radio.setup.language.hindi", to: false)
        XCTAssertFalse(ui.app.buttons["radio.setup.artist.char diwaari"].exists)
        XCTAssertFalse(ui.app.buttons["radio.setup.artist.seedhe maut"].exists)
        try startConfiguredRadio(ui)
        try expectStation(ui, title: "Left-field rap", song: "Flashing Lights")
        XCTAssertTrue(ui.app.buttons["search.station.active"].label.contains("English · Anytime"))
        try ui.openPlayer()
        try ui.expectCurrentTrack("fixture.experience.seed.28")
        try ui.waitForAdvance(from: 0, by: 1)
        try ui.pause()
        try ui.openPlayerSheet("queue", title: "Queue")
        try ui.reveal(ui.element("queue.play.1.fixture.experience.seed.30"))
        XCTAssertFalse(ui.element("queue.play.1.fixture.experience.seed.29").exists)
        try ui.closeSheet("Queue")
        try ui.closePlayer()
        try openRadioSetup(ui, station: station)
        try ui.expectSwitch("radio.setup.language.hindi", isOn: true)
        try ui.expectSwitch("radio.setup.language.english", isOn: true)
        XCTAssertEqual(ui.app.staticTexts["radio.setup.selectionCount"].label, "0 of 4 hints")
        try cancelRadioSetup(ui)
        try expectStation(ui, title: "Left-field rap", song: "Flashing Lights")
    }

    func testCancellingAnotherSetupKeepsTheAlreadyPendingRadio() throws {
        let ui = makeDriver()
        try ui.launch(additionalArguments: ["--slow-experience-radio"])
        try openRadioDiscovery(ui)
        let melancholy = ui.app.buttons["search.station.melancholy"]
        let gym = ui.app.buttons["search.station.hindi-gym"]
        try ui.reveal(melancholy)
        try startRadio(ui, station: melancholy)
        try ui.wait("The first station must be loading") { melancholy.value as? String == "Loading" }
        try ui.reveal(gym)
        try openRadioSetup(ui, station: gym)
        try cancelRadioSetup(ui)
        try expectStation(ui, title: "Melancholy", song: "Apocalypse", timeout: 20)
        XCTAssertNotEqual(gym.value as? String, "Current station")
        XCTAssertEqual(radioLoadingIndicators(ui).count, 0)
        XCTAssertFalse(ui.app.staticTexts["search.station.error"].exists)
        try ui.openPlayer()
        try ui.expectCurrentTrack("fixture.experience.seed.0")
    }

    private func openRadioSetup(_ ui: AppUITestDriver, station: XCUIElement) throws {
        try ui.tap(station)
        try ui.wait("Tapping a station must open its setup sheet") {
            ui.app.navigationBars["Set up radio"].exists && ui.app.buttons["radio.setup.start"].exists
        }
        try ui.requireHittable(ui.app.buttons["radio.setup.cancel"])
        XCTAssertFalse(ui.app.keyboards.firstMatch.exists)
        let options = ui.app.scrollViews["radio.setup.options"]
        try ui.requireHittable(options)
        XCTAssertGreaterThan(options.frame.height, 0)
        XCTAssertLessThanOrEqual(options.frame.maxY, ui.app.staticTexts["radio.setup.summary"].frame.minY,
                                "The scroll viewport must end above the fixed radio footer")
    }

    private func startConfiguredRadio(_ ui: AppUITestDriver) throws {
        let start = ui.app.buttons["radio.setup.start"]
        try ui.wait("Start must be available with optional artist hints") { start.exists && start.isEnabled }
        XCTAssertGreaterThanOrEqual(start.frame.height, 52)
        try ui.tap(start)
        try ui.wait("Starting a radio must close the setup sheet") { !ui.app.navigationBars["Set up radio"].exists }
    }

    private func startRadio(_ ui: AppUITestDriver, station: XCUIElement) throws {
        try openRadioSetup(ui, station: station)
        try startConfiguredRadio(ui)
    }

    private func cancelRadioSetup(_ ui: AppUITestDriver) throws {
        try ui.tap(ui.app.buttons["radio.setup.cancel"])
        try ui.wait("Cancel must close the setup sheet") { !ui.app.navigationBars["Set up radio"].exists }
    }

    private func setSetupArtist(_ ui: AppUITestDriver, _ key: String, selected: Bool) throws {
        let artist = ui.app.buttons["radio.setup.artist.\(key)"]
        try ui.reveal(artist)
        let frame = artist.frame
        let viewport = ui.app.scrollViews["radio.setup.options"].frame.intersection(ui.app.windows.firstMatch.frame)
        let center = CGPoint(x: frame.midX, y: frame.midY)
        guard viewport.contains(center), center.y >= ui.app.navigationBars["Set up radio"].frame.maxY,
              frame.intersection(viewport).height >= min(frame.height, 44) else {
            throw AppUIWorkflowFailure(message: "Artist \(key) must be revealed inside the options viewport before tapping: \(frame), viewport: \(viewport)")
        }
        if artist.isSelected != selected {
            try ui.tap(artist)
            XCTAssertTrue(ui.app.navigationBars["Set up radio"].exists, "Toggling an artist must not activate Start radio")
        }
        try ui.wait("The artist choice must update while its setup sheet stays open") {
            ui.app.navigationBars["Set up radio"].exists && artist.exists && artist.isSelected == selected
        }
    }

    private func radioLoadingIndicators(_ ui: AppUITestDriver) -> XCUIElementQuery {
        ui.element("search.radio").descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "search.station.progress."))
    }

    private func radioLayoutFrames(_ ui: AppUITestDriver) -> [String: CGRect] {
        var frames = Dictionary(uniqueKeysWithValues: ["search.station.melancholy", "search.station.hindi-gym"].map {
            ($0, ui.element($0).frame)
        })
        // The accessibility container grows to include its new action; the visible title must not move.
        frames["search.radio.title"] = ui.app.staticTexts["Find your radio"].frame
        return frames
    }

    private func assertRadioLayout(_ ui: AppUITestDriver, matches expected: [String: CGRect],
                                   file: StaticString = #filePath, line: UInt = #line) {
        for (id, frame) in radioLayoutFrames(ui) {
            guard let original = expected[id] else { XCTFail("Missing baseline for \(id)", file: file, line: line); continue }
            XCTAssertFalse(original.isEmpty || frame.isEmpty, id, file: file, line: line)
            XCTAssertEqual(frame.minX, original.minX, accuracy: 1, id, file: file, line: line)
            XCTAssertEqual(frame.minY, original.minY, accuracy: 1, id, file: file, line: line)
            XCTAssertEqual(frame.width, original.width, accuracy: 1, id, file: file, line: line)
            XCTAssertEqual(frame.height, original.height, accuracy: 1, id, file: file, line: line)
        }
    }

    private func assertNoRadioLoadingCopy(_ ui: AppUITestDriver, file: StaticString = #filePath, line: UInt = #line) {
        let radio = ui.element("search.radio")
        XCTAssertFalse(ui.app.staticTexts["search.station.loading"].exists, file: file, line: line)
        XCTAssertFalse(radio.staticTexts.matching(NSPredicate(
            format: "label CONTAINS[c] %@ OR label BEGINSWITH %@", "Finding songs", "Starting "
        )).firstMatch.exists, file: file, line: line)
    }

    private func selectDiscoveryLanguages(_ ui: AppUITestDriver, hindi: Bool, english: Bool) throws {
        try ui.openSettings()
        let languages = ui.app.buttons["settings.languages"]
        try ui.reveal(languages, maxSwipes: 24)
        try ui.tap(languages)
        if hindi { try ui.setSwitch("settings.language.hindi", to: true) }
        if english { try ui.setSwitch("settings.language.english", to: true) }
        if !hindi { try ui.setSwitch("settings.language.hindi", to: false) }
        if !english { try ui.setSwitch("settings.language.english", to: false) }
        try ui.tap(ui.app.navigationBars["Discovery languages"].buttons.firstMatch)
        try ui.tap(ui.app.buttons["settings.done"])
    }

    private func openRadioDiscovery(_ ui: AppUITestDriver) throws {
        try tapSearch(ui)
        try ui.tap(ui.app.buttons["search.dismissKeyboard"])
        try expectKeyboardDismissed(ui)
    }

    private func tapSearch(_ ui: AppUITestDriver) throws {
        let button = ui.app.tabBars.buttons["Search"]
        let wasSelected = button.isSelected
        try ui.tap(button)
        if !wasSelected {
            try ui.requireHittable(ui.app.textFields["search.field"])
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
        let first = ui.app.buttons["search.filter.songs"]
        try ui.wait("Search reselect or navigation reset must reveal the top anchor without a test scroll") {
            guard content.exists, first.exists else { return false }
            let viewport = content.frame
            let frame = first.frame
            return frame.minY >= viewport.minY - 1 && frame.maxY <= viewport.minY + 90
                && frame.intersection(viewport).height >= 43
        }
    }

    private func expectStation(_ ui: AppUITestDriver, title: String, song: String, timeout: TimeInterval = 12) throws {
        try ui.wait("The requested station must become the active radio", timeout: timeout) {
            let active = ui.app.buttons["search.station.active"]
            let mini = ui.app.buttons["miniPlayer.open"]
            return active.exists && active.label.contains("\(title) Radio") && mini.exists && mini.label.contains(song)
        }
    }

    private func expectQueueRadioLabel(_ ui: AppUITestDriver, station: String) throws {
        let label = ui.app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS[c] %@ AND label CONTAINS[c] %@", station, "radio")).firstMatch
        try ui.wait("The queue must identify the active station as radio") { label.exists }
    }

    private func makeDriver() -> AppUITestDriver {
        let ui = AppUITestDriver(testCase: self, prefix: "search-discovery")
        addTeardownBlock { await ui.finish() }
        return ui
    }
}

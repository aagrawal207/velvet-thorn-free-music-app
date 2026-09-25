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
        try ui.launch()
        try openRadioDiscovery(ui)
        let firstStation = ui.app.buttons["search.station.melancholy"]
        let content = ui.app.scrollViews["search.radio.content"]
        try ui.reveal(ui.app.buttons["search.station.left-field-rap"], maxSwipes: 24)
        XCTAssertTrue(!firstStation.exists || firstStation.frame.maxY < content.frame.minY,
                      "The test must begin scrolled away from the top")
        try tapSearch(ui)
        try expectSearchAtTop(ui)
        XCTAssertFalse(ui.app.navigationBars["Radio"].exists)
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

    func testStationPlaysRealQueueAndContinuesWhenGeneralAutoplayIsOff() throws {
        let ui = makeDriver()
        try ui.launch()
        try ui.openSettings()
        try ui.setSwitch("settings.autoplay", to: false)
        try ui.tap(ui.app.buttons["settings.done"])
        try tuneRadioProfile(ui, dominant: "en")
        try openRadioDiscovery(ui)
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
        try ui.expectCurrentTrack(Seed.apocalypse.track)
        try ui.waitForAdvance(from: 0, by: 1)
        try ui.pause()
        try ui.openPlayerSheet("queue", title: "Queue")
        try expectQueueRadioLabel(ui, station: "Melancholy")
        for (index, seed) in Seed.melancholy.enumerated() {
            try ui.reveal(ui.element("queue.play.\(index).\(seed.track)"))
        }
        let lastInitialSong = ui.element("queue.play.15.\(Seed.fadeIntoYou.radio(2))")
        try ui.reveal(lastInitialSong, maxSwipes: 20)
        try ui.tap(lastInitialSong)
        try ui.expectCurrentTrack(Seed.fadeIntoYou.radio(2))
        try ui.waitForAdvance(from: 0, by: 1)
        try ui.pause()
        try ui.openPlayerSheet("queue", title: "Queue")
        try expectQueueRadioLabel(ui, station: "Melancholy")
        let continuation = ui.app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@", "queue.play.", Seed.apocalypse.radio(3))).firstMatch
        try ui.reveal(continuation, maxSwipes: 24)
        ui.capture("search-discovery-station-continued-with-autoplay-off")
        try ui.closeSheet("Queue")
        try ui.closePlayer()
        try ui.tap(ui.app.navigationBars["Radio"].buttons["Back"])
        try ui.reveal(ui.app.staticTexts["search.recents.empty"])
        XCTAssertFalse(ui.app.buttons["search.recents.clear"].exists, "Starting radio must not create an opened search result")
        try ui.openSettings()
        try ui.expectSwitch("settings.autoplay", isOn: false)
    }

    func testFastStationReselectKeepsTheNewStationAndExistingPlaybackDuringLoading() throws {
        let ui = makeDriver()
        try ui.launch(additionalArguments: ["--slow-experience-radio"])
        try tuneRadioProfile(ui, dominant: "en")
        try tapSearch(ui)
        ui.app.textFields["search.field"].typeText("Tum Hi Ho")
        try ui.waitForSearchResults()
        try ui.tap(ui.app.buttons["track.play.\(AppUIFixture.tumHiHo)"])
        try expectKeyboardDismissed(ui)
        try ui.clearSearch()
        try ui.tap(ui.app.buttons["search.dismissKeyboard"])
        try expectKeyboardDismissed(ui)
        try openRadioPage(ui)
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
        let workoutSong = "fixture.style.workout-motivation-songs.0"
        try expectStation(ui, title: "Workout", song: "workout motivation songs fixture", timeout: 20)
        XCTAssertEqual(gym.value as? String, "Current station")
        XCTAssertNotEqual(melancholy.value as? String, "Current station")
        try ui.openPlayer()
        try ui.expectCurrentTrack(workoutSong)
        try ui.waitForAdvance(from: 0, by: 1)
        try ui.pause()
        try ui.openPlayerSheet("queue", title: "Queue")
        try expectQueueRadioLabel(ui, station: "Workout")
        try ui.reveal(ui.element("queue.play.0.\(workoutSong)"))
        let next = ui.app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "queue.play.1.fixture.style.")).firstMatch
        try ui.reveal(next)
        XCTAssertFalse(ui.element("queue.play.0.\(Seed.apocalypse.track)").exists)
        ui.capture("search-discovery-fast-station-reselection")
    }

    func testRadioLoadingUsesOneSpinnerAndKeepsTilesAndHeaderFixedThroughReadiness() throws {
        let ui = makeDriver()
        try ui.launch(additionalArguments: ["--slow-experience-radio"])
        try tuneRadioProfile(ui, dominant: "en")
        try tapSearch(ui)
        ui.app.textFields["search.field"].typeText("Tum Hi Ho")
        try ui.waitForSearchResults()
        try ui.tap(ui.app.buttons["track.play.\(AppUIFixture.tumHiHo)"])
        try expectKeyboardDismissed(ui)
        try ui.requireHittable(ui.app.buttons["miniPlayer.open"])
        try ui.clearSearch()
        try ui.tap(ui.app.buttons["search.dismissKeyboard"])
        try expectKeyboardDismissed(ui)
        try openRadioPage(ui)

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
        try ui.expectCurrentTrack(Seed.apocalypse.track)
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
        try tuneRadioProfile(ui, dominant: "en")
        try openRadioDiscovery(ui)
        let station = ui.app.buttons["search.station.melancholy"]
        try ui.reveal(station)
        try startRadio(ui, station: station)
        try expectStation(ui, title: "Melancholy", song: "Apocalypse", timeout: 20)
        XCTAssertFalse(ui.app.staticTexts["search.station.error"].exists)
        try ui.openPlayer()
        try ui.waitForAdvance(from: 0, by: 1)
        try ui.pause()
        try ui.openPlayerSheet("queue", title: "Queue")
        // Every cue radio failed once, so the station's own wording searches fill the queue behind the four cues.
        for (index, seed) in Seed.melancholy.enumerated() {
            try ui.reveal(ui.element("queue.play.\(index).\(seed.track)"))
        }
        let styleSong = ui.app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "queue.play.4.fixture.style.")).firstMatch
        try ui.reveal(styleSong)
        try expectQueueRadioLabel(ui, station: "Melancholy")
    }

    func testRadioBrowseKeepsStationsAndTruthfulAutomaticCopyAcrossLanguageNudges() throws {
        let ui = makeDriver()
        try ui.launch()
        for dominant in ["en", "hi"] {
            try tuneRadioProfile(ui, dominant: dominant)
            try openRadioDiscovery(ui)
            try ui.reveal(ui.app.buttons["search.station.melancholy"])
            XCTAssertTrue(ui.element("search.radio.group.moods").exists)
            let gym = ui.app.buttons["search.station.hindi-gym"]
            try ui.reveal(gym)
            XCTAssertTrue(gym.label.contains("Workout Radio. Follows your listening."))
            let rap = ui.app.buttons["search.station.left-field-rap"]
            try ui.reveal(rap, maxSwipes: 24)
            XCTAssertTrue(ui.element("search.radio.group.genres").exists)
            XCTAssertTrue(rap.label.contains("Rap and hip hop Radio. Follows your listening."))
            XCTAssertFalse(rap.label.contains("Kanye West") || rap.label.contains("Char Diwaari"),
                           "A station description must not promise artist cues for an inferred profile")
            try ui.reveal(ui.app.buttons["search.station.qawwali"], maxSwipes: 24)
            try ui.reveal(ui.app.buttons["search.station.nineties"], maxSwipes: 24)
        }
        try ui.relaunch()
        try openRadioDiscovery(ui)
        try ui.reveal(ui.app.buttons["search.station.melancholy"])
        XCTAssertTrue(ui.app.buttons["search.station.melancholy"].label.contains("Follows your listening"))
        ui.capture("search-discovery-grouped-stations")
    }

    func testMixedRadioStartsTheDominantLearnedLanguageSeedGroup() throws {
        let ui = makeDriver()
        try ui.launch()
        let cases = [(dominant: "en", song: "Flashing Lights", first: Seed.flashingLights, second: Seed.earfquake),
                     (dominant: "hi", song: "Jhaag", first: Seed.jhaag, second: Seed.nanchaku)]
        for selection in cases {
            try tuneRadioProfile(ui, dominant: selection.dominant)
            try openRadioDiscovery(ui)
            let station = ui.app.buttons["search.station.left-field-rap"]
            try ui.reveal(station, maxSwipes: 24)
            try startRadio(ui, station: station)
            try expectStation(ui, title: "Rap and hip hop", song: selection.song)
            try ui.openPlayer()
            try ui.expectCurrentTrack(selection.first.track)
            try ui.waitForAdvance(from: 0, by: 1)
            try ui.pause()
            try ui.openPlayerSheet("queue", title: "Queue")
            try ui.reveal(ui.element("queue.play.0.\(selection.first.track)"))
            try ui.reveal(ui.element("queue.play.1.\(selection.second.track)"))
            try expectQueueRadioLabel(ui, station: "Rap and hip hop")
            try ui.closeSheet("Queue")
            try ui.closePlayer()
        }
    }

    func testClassicRadiosPlayFromTheirDiscoveryTilesInEitherLanguage() throws {
        let ui = makeDriver()
        try ui.launch()
        let cases = [(id: "hindi-classics", title: "Bollywood classics", song: "Lag Ja Gale Se Phir", hindi: true,
                      first: Seed.lagJaGale, second: Seed.yehShamMastani),
                     (id: "english-golden-oldies", title: "Golden oldies", song: "Here Comes The Sun", hindi: false,
                      first: Seed.hereComesTheSun, second: Seed.cantHelpFalling)]
        for selection in cases {
            try tuneRadioProfile(ui, dominant: selection.hindi ? "hi" : "en")
            try openRadioDiscovery(ui)
            let station = ui.app.buttons["search.station.\(selection.id)"]
            try ui.reveal(station, maxSwipes: 24)
            XCTAssertTrue(station.label.contains("Radio"))
            try openRadioSetup(ui, station: station)
            XCTAssertTrue(ui.app.buttons["radio.setup.era.older"].isSelected)
            try startConfiguredRadio(ui)
            try expectStation(ui, title: selection.title, song: selection.song)
            try ui.openPlayer()
            try ui.expectCurrentTrack(selection.first.track)
            try ui.waitForAdvance(from: 0, by: 1)
            try ui.pause()
            try ui.openPlayerSheet("queue", title: "Queue")
            try expectQueueRadioLabel(ui, station: selection.title)
            try ui.reveal(ui.element("queue.play.0.\(selection.first.track)"))
            try ui.reveal(ui.element("queue.play.1.\(selection.second.track)"))
            ui.capture("search-\(selection.id)-radio-queue")
            try ui.closeSheet("Queue")
            try ui.closePlayer()
        }
    }

    func testHindiLedMelancholyStartsFromStyleSearchesWithoutArtistHintsOrLanguageSwitches() throws {
        let ui = makeDriver()
        try ui.launch()
        try tuneRadioProfile(ui, dominant: "hi")
        try openRadioDiscovery(ui)
        let station = ui.app.buttons["search.station.melancholy"]
        try ui.reveal(station)
        try openRadioSetup(ui, station: station)
        try expectAutomaticRadioLanguages(ui)
        let start = ui.app.buttons["radio.setup.start"]
        XCTAssertTrue(start.isEnabled, "A station starts in any language, without a matching cue variant")
        XCTAssertEqual(ui.app.staticTexts["radio.setup.summary"].label, "Start from the station’s mood. No artist hints needed.")
        XCTAssertEqual(ui.app.staticTexts["radio.setup.selectionCount"].label, "0 of 4 hints")
        ui.capture("radio-setup-melancholy-hindi-led")
        try startConfiguredRadio(ui)
        try expectStation(ui, title: "Melancholy", song: "fixture")
        XCTAssertTrue(ui.app.buttons["search.station.active"].label.contains("Follows your listening · Anytime"))
        XCTAssertFalse(ui.app.staticTexts["search.station.error"].exists)
        try ui.openPlayer()
        let current = ui.app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "player.track.fixture.style.")).firstMatch
        try ui.wait("Hindi Melancholy must play a song found through its wording, not an English cue") { current.exists }
        XCTAssertFalse(ui.app.staticTexts["player.track.\(Seed.apocalypse.track)"].exists)
        try ui.waitForAdvance(from: 0, by: 1)
        try ui.pause()
        try ui.openPlayerSheet("queue", title: "Queue")
        try expectQueueRadioLabel(ui, station: "Melancholy")
        let first = ui.app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "queue.play.0.fixture.style.")).firstMatch
        try ui.reveal(first)
        XCTAssertFalse(ui.element("queue.play.0.\(Seed.apocalypse.track)").exists)
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
        try openRadioPage(ui)
        let station = ui.app.buttons["search.station.melancholy"]
        try ui.reveal(station)
        try openRadioSetup(ui, station: station)
        XCTAssertTrue(ui.app.buttons["radio.setup.era.anytime"].isSelected)
        try expectAutomaticRadioLanguages(ui)
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
        XCTAssertTrue(start.isEnabled, "The inferred language profile needs no setup form")
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
        XCTAssertFalse(ui.element("queue.play.0.\(Seed.apocalypse.track)").exists)
    }

    func testArtistSearchAndNewerEraUseTheAddedArtistsActualDatedRecording() throws {
        let ui = makeDriver()
        try ui.launch()
        try tuneRadioProfile(ui, dominant: "en")
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
        try ui.expectCurrentTrack(Seed.apocalypse.track)
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
            let backgroundFrame = station.frame
            try openRadioSetup(ui, station: station)
            try ui.tap(ui.app.buttons["radio.setup.era.\(era)"])
            let start = ui.app.buttons["radio.setup.start"]
            XCTAssertTrue(start.isEnabled)
            XCTAssertEqual(start.value as? String, "Style defaults")
            let options = ui.app.scrollViews["radio.setup.options"]
            let artist = ui.app.buttons["radio.setup.artist.radiohead"]
            let before = artist.frame
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
            XCTAssertTrue(ui.app.navigationBars["Set up radio"].exists)
            ui.capture("radio-reveal-\(era)-visible-after")
            try setSetupArtist(ui, "radiohead", selected: true)
            try setSetupArtist(ui, "mazzy star", selected: true)
            XCTAssertTrue(start.isEnabled)
            try cancelRadioSetup(ui)
            XCTAssertEqual(station.frame.minY, backgroundFrame.minY, accuracy: 1, "The Radio page beneath the sheet must not scroll")
            XCTAssertFalse(ui.app.buttons["search.station.active"].exists)
            XCTAssertFalse(ui.app.buttons["miniPlayer.open"].exists)
        }
    }

    func testRadioSetupKeepsAutomaticLanguagesAndDoesNotPersistOptionalArtistDrafts() throws {
        let ui = makeDriver()
        try ui.launch()
        try tuneRadioProfile(ui, dominant: "en")
        try openRadioDiscovery(ui)
        let station = ui.app.buttons["search.station.left-field-rap"]
        try ui.reveal(station, maxSwipes: 24)
        try openRadioSetup(ui, station: station)
        try expectAutomaticRadioLanguages(ui)
        try setSetupArtist(ui, "kanye west", selected: true)
        XCTAssertEqual(ui.app.staticTexts["radio.setup.selectionCount"].label, "1 of 4 hints")
        try ui.reveal(ui.app.buttons["radio.setup.clearArtists"], direction: .down)
        try ui.tap(ui.app.buttons["radio.setup.clearArtists"])
        try startConfiguredRadio(ui)
        try expectStation(ui, title: "Rap and hip hop", song: "Flashing Lights")
        XCTAssertTrue(ui.app.buttons["search.station.active"].label.contains("Follows your listening · Anytime"))
        try ui.openPlayer()
        try ui.expectCurrentTrack(Seed.flashingLights.track)
        try ui.waitForAdvance(from: 0, by: 1)
        try ui.pause()
        try ui.openPlayerSheet("queue", title: "Queue")
        try ui.reveal(ui.element("queue.play.1.\(Seed.earfquake.track)"))
        XCTAssertFalse(ui.element("queue.play.1.\(Seed.jhaag.track)").exists)
        try ui.closeSheet("Queue")
        try ui.closePlayer()
        try openRadioSetup(ui, station: station)
        try expectAutomaticRadioLanguages(ui)
        XCTAssertEqual(ui.app.staticTexts["radio.setup.selectionCount"].label, "0 of 4 hints")
        try cancelRadioSetup(ui)
        try expectStation(ui, title: "Rap and hip hop", song: "Flashing Lights")
    }

    func testCancellingAnotherSetupKeepsTheAlreadyPendingRadio() throws {
        let ui = makeDriver()
        try ui.launch(additionalArguments: ["--slow-experience-radio"])
        try tuneRadioProfile(ui, dominant: "en")
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
        try ui.expectCurrentTrack(Seed.apocalypse.track)
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

    private func tuneRadioProfile(_ ui: AppUITestDriver, dominant: String) throws {
        try ui.openSettings()
        let languages = ui.app.buttons["settings.languages"]
        try ui.reveal(languages, maxSwipes: 24)
        try ui.tap(languages)
        let tuning = ui.app.buttons["listeningLanguages.tune"]
        try ui.reveal(tuning, maxSwipes: 24)
        try ui.tap(tuning)
        for code in ["en", "hi"] {
            let menu = ui.app.buttons["listeningLanguages.nudge.\(code)"]
            try ui.reveal(menu, maxSwipes: 24)
            try ui.tap(menu)
            let title = code == dominant ? "More" : "Less"
            let identified = ui.app.buttons["listeningLanguages.choice.\(code).\(title.lowercased())"]
            let native = ui.app.buttons[title]
            try ui.wait("The native language adjustment menu must open") { identified.exists || native.exists }
            try ui.tap(identified.exists ? identified : native)
            try ui.expectValue(menu, title)
        }
        try ui.tap(ui.app.navigationBars["Listening languages"].buttons.firstMatch)
        try ui.tap(ui.app.buttons["settings.done"])
    }

    private func expectAutomaticRadioLanguages(_ ui: AppUITestDriver) throws {
        let label = ui.element("radio.setup.listeningLanguages")
        try ui.reveal(label, direction: .down)
        XCTAssertEqual(label.label, "Languages follow your listening")
        XCTAssertFalse(ui.app.switches.matching(NSPredicate(format: "identifier BEGINSWITH %@", "radio.setup.language.")).firstMatch.exists)
    }

    private func openRadioDiscovery(_ ui: AppUITestDriver) throws {
        try tapSearch(ui)
        if ui.app.buttons["search.clear"].exists { try ui.clearSearch() }
        try ui.tap(ui.app.buttons["search.dismissKeyboard"])
        try expectKeyboardDismissed(ui)
        try openRadioPage(ui)
    }

    private func openRadioPage(_ ui: AppUITestDriver) throws {
        let radio = ui.app.buttons["search.radio.open"]
        try ui.reveal(radio)
        try ui.tap(radio)
        try ui.wait("The compact Radio row must open its own browse page") {
            ui.app.navigationBars["Radio"].exists && ui.app.scrollViews["search.radio.content"].exists
                && !ui.app.textFields["search.field"].exists
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
        let first = ui.app.buttons[queryIsEmpty ? "search.library.likes" : "search.filter.songs"]
        try ui.wait("Search reselect must reveal the top anchor without a test scroll") {
            guard content.exists, first.exists else { return false }
            let viewport = content.frame
            let frame = first.frame
            return frame.minY >= viewport.minY - 1 && frame.minY <= viewport.minY + 24
                && frame.maxY <= viewport.maxY + 1
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

    /// Debug fixture ids derive from each cue's search query, so they survive station reordering.
    private struct Seed {
        let slug: String
        var track: String { "fixture.experience.seed.\(slug)" }
        func radio(_ index: Int) -> String { "fixture.experience.radio.\(slug).\(index)" }

        static let apocalypse = Seed(slug: "apocalypse-cigarettes-after-sex")
        static let whereIsMyMind = Seed(slug: "where-is-my-mind-pixies")
        static let noSurprises = Seed(slug: "no-surprises-radiohead")
        static let fadeIntoYou = Seed(slug: "fade-into-you-mazzy-star")
        static let melancholy = [apocalypse, whereIsMyMind, noSurprises, fadeIntoYou]
        static let zinda = Seed(slug: "zinda-siddharth-mahadevan-bhaag-milkha-bhaag")
        static let goat = Seed(slug: "g-o-a-t-diljit-dosanjh")
        static let flashingLights = Seed(slug: "flashing-lights-kanye-west")
        static let earfquake = Seed(slug: "earfquake-tyler-the-creator")
        static let jhaag = Seed(slug: "jhaag-char-diwaari")
        static let nanchaku = Seed(slug: "nanchaku-seedhe-maut")
        static let lagJaGale = Seed(slug: "lag-ja-gale-se-phir-lata-mangeshkar")
        static let yehShamMastani = Seed(slug: "yeh-sham-mastani-kishore-kumar")
        static let hereComesTheSun = Seed(slug: "here-comes-the-sun-the-beatles")
        static let cantHelpFalling = Seed(slug: "can-t-help-falling-in-love-elvis-presley")
    }
}

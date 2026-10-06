import XCTest

/// R13 WP17: genre evidence from the fixture store flows into Settings, Recap and Song details.
@MainActor
final class GanaBajanaGenreProfileUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testListeningGenresListsFamiliesWithBarsAndAHipHopNudgePersistsAcrossRelaunch() throws {
        let ui = makeDriver()
        try ui.launch(additionalArguments: ["--genre-fixture"])
        try openListeningGenres(ui, expectedTopFamily: "Bollywood")
        try expectFixtureStats(ui)
        let content = ui.app.scrollViews["genres.content"]
        let hipHopMenu = content.buttons["genres.nudge.hipHop"]
        try ui.reveal(hipHopMenu, maxSwipes: 16)
        try ui.expectValue(hipHopMenu, "Automatic")
        XCTAssertGreaterThanOrEqual(hipHopMenu.frame.height + 1e-6, 44)
        let reset = content.buttons["genres.reset"]
        try ui.reveal(reset, maxSwipes: 16)
        XCTAssertFalse(reset.isEnabled, "Reset stays disabled while every family is Automatic")
        try setNudge("hipHop", to: "More", in: ui)
        try expectFixtureStats(ui)
        ui.capture("listening-genres-fixture-dark")

        try ui.relaunch(adding: ["--light"])
        try openListeningGenres(ui, expectedTopFamily: "Hip hop")
        try expectFixtureStats(ui)
        try ui.reveal(hipHopMenu, maxSwipes: 16)
        try ui.expectValue(hipHopMenu, "More")
        try ui.expectValue(content.buttons["genres.nudge.bollywood"], "Automatic")
        try ui.reveal(reset, maxSwipes: 16)
        XCTAssertTrue(reset.isEnabled)
        ui.capture("listening-genres-nudge-persisted-light")
        try ui.tap(reset)
        try ui.expectValue(hipHopMenu, "Automatic")
        try ui.wait("Reset returns every adjustment to Automatic") { !reset.isEnabled }
    }

    func testRecapShowsTopGenresDirectlyAboveListeningLanguagesAndHidesWithoutEvidence() throws {
        let ui = makeDriver()
        try ui.launch(additionalArguments: ["--genre-fixture"])
        try ui.selectTab("recap")
        let card = ui.element("recap.genres")
        try ui.reveal(card, maxSwipes: 20)
        XCTAssertTrue(card.exists)
        let bollywood = ui.element("recap.genres.bollywood")
        let hipHop = ui.element("recap.genres.hipHop")
        try ui.expectValue(bollywood, "67% of classified plays")
        try ui.expectValue(hipHop, "33% of classified plays")
        XCTAssertLessThan(bollywood.frame.minY, hipHop.frame.minY, "Families sort by share")
        XCTAssertFalse(ui.element("recap.genres.pop").exists)
        let languages = ui.app.buttons["recap.listeningLanguages"]
        try ui.reveal(languages, maxSwipes: 20)
        XCTAssertLessThan(card.frame.maxY, languages.frame.minY + 1, "Top genres sits directly above Listening languages")
        let share = ui.app.buttons["recap.share"]
        XCTAssertTrue(share.exists)
        XCTAssertLessThan(share.frame.maxY, card.frame.minY + 1, "Sharing stays above the genre card")
        let open = ui.app.buttons["recap.genres.open"]
        try ui.reveal(open, maxSwipes: 20)
        XCTAssertGreaterThanOrEqual(open.frame.height + 1e-6, 44)
        ui.capture("recap-top-genres-week")

        let year = ui.app.buttons["recap.window.year"]
        try ui.reveal(year, direction: .down, maxSwipes: 20)
        try ui.tap(year)
        try ui.wait("The year window keeps the same fixture shares") {
            (bollywood.value as? String) == "67% of classified plays"
        }
        try ui.reveal(open, maxSwipes: 20)
        try ui.tap(open)
        try ui.wait("The card opens the genres page") { ui.app.navigationBars["Listening Genres"].exists }
        try ui.tap(ui.app.navigationBars["Listening Genres"].buttons.firstMatch)
        try ui.wait("Back returns to the recap") { ui.element("recap.screen").exists }

        // Without evidence the card disappears and the recap keeps its R13 order.
        try ui.launch()
        try ui.selectTab("recap")
        try ui.reveal(ui.app.buttons["recap.listeningLanguages"], maxSwipes: 20)
        XCTAssertFalse(ui.element("recap.genres").exists)
    }

    func testSongDetailsShowTheGenresRowWithItsMusicBrainzSource() throws {
        let ui = makeDriver()
        try ui.launch(additionalArguments: ["--genre-fixture"])
        try ui.searchAndPlayTumHiHo()
        try ui.openPlayer()
        try ui.openPlayerMenu()
        let details = ui.app.buttons["player.options.details"]
        try ui.requireHittable(details)
        try ui.tap(details)
        try ui.wait("The Song details page must open inside the options sheet") {
            ui.app.navigationBars["Song Details"].exists && ui.element("player.details.list").exists
        }
        let genres = ui.element("player.details.genres")
        try ui.reveal(genres)
        XCTAssertEqual(genres.label, "Genres")
        XCTAssertEqual(genres.value as? String, "Bollywood")
        XCTAssertGreaterThanOrEqual(genres.frame.height + 1e-6, 44)
        let source = ui.app.staticTexts["player.details.genres.source"]
        try ui.reveal(source)
        XCTAssertEqual(source.label, "Genres from MusicBrainz")
        let language = ui.element("player.details.language")
        XCTAssertLessThan(language.frame.minY, genres.frame.minY, "Genres follows Language in the Playback group")
        ui.capture("song-details-genres-row")
    }

    private func makeDriver() -> AppUITestDriver {
        let ui = AppUITestDriver(testCase: self, prefix: "genre-profile")
        addTeardownBlock { await ui.finish() }
        return ui
    }

    private func openListeningGenres(_ ui: AppUITestDriver, expectedTopFamily: String) throws {
        try ui.openSettings()
        try ui.openSettingsPage(.discovery)
        let row = ui.app.buttons["settings.genres"]
        try ui.reveal(row, maxSwipes: 24)
        XCTAssertTrue(row.label.contains("Listening Genres"))
        XCTAssertTrue(ui.accessibleText(row).contains(expectedTopFamily), "The row shows the strongest family: \(ui.accessibleText(row))")
        XCTAssertGreaterThanOrEqual(row.frame.height + 1e-6, 44)
        try ui.tap(row)
        let content = ui.app.scrollViews["genres.content"]
        try ui.wait("Listening genres must open as a native navigation destination") {
            ui.app.navigationBars["Listening Genres"].exists && content.exists && content.staticTexts["genres.window"].exists
        }
    }

    private func expectFixtureStats(_ ui: AppUITestDriver) throws {
        let content = ui.app.scrollViews["genres.content"]
        let coverage = content.staticTexts["genres.coverage"]
        try ui.reveal(coverage, maxSwipes: 16)
        try ui.expectLabel(coverage, "45% of your plays are classified.")
        try ui.expectValue(genreElement("genres.total.plays", in: ui), "20")
        try ui.expectValue(genreElement("genres.total.songs", in: ui), "2")
        let bollywood = genreElement("genres.family.bollywood", in: ui)
        let hipHop = genreElement("genres.family.hipHop", in: ui)
        try ui.reveal(bollywood, maxSwipes: 16)
        try ui.expectValue(bollywood, "6 plays · 1 song, 66.7% of classified plays")
        try ui.expectValue(hipHop, "3 plays · 1 song, 33.3% of classified plays")
        XCTAssertLessThan(bollywood.frame.minY, hipHop.frame.minY, "Families sort by share")
        XCTAssertFalse(genreElement("genres.family.pop", in: ui).exists, "Unplayed families have no bar")
        XCTAssertFalse(genreElement("genres.empty", in: ui).exists)
    }

    private func setNudge(_ family: String, to title: String, in ui: AppUITestDriver) throws {
        let content = ui.app.scrollViews["genres.content"]
        let menu = content.buttons["genres.nudge.\(family)"]
        try ui.reveal(menu, maxSwipes: 16)
        try ui.tap(menu)
        let identified = ui.app.buttons["genres.choice.\(family).\(title.lowercased())"]
        let native = ui.app.buttons[title]
        try ui.wait("The native adjustment picker must offer \(title)") { identified.exists || native.exists }
        try ui.tap(identified.exists ? identified : native)
        try ui.expectValue(menu, title)
    }

    private func genreElement(_ id: String, in ui: AppUITestDriver) -> XCUIElement {
        ui.app.scrollViews["genres.content"].descendants(matching: .any).matching(identifier: id).firstMatch
    }
}

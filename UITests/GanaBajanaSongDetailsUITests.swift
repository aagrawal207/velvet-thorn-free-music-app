import XCTest

@MainActor
final class GanaBajanaSongDetailsUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testSongDetailsShowPerformersCreditsReleaseFactsCopyAndDescription() throws {
        let ui = makeDriver()
        try ui.launch()
        try ui.searchAndPlayTumHiHo()
        try openSongDetails(ui)

        let title = ui.app.staticTexts["player.details.title"]
        try ui.requireHittable(title)
        XCTAssertEqual(title.label, "Tum Hi Ho")
        XCTAssertEqual(ui.app.staticTexts["player.details.artists"].label, "Arijit Singh")

        let composer = ui.element("player.details.credit.composer")
        try ui.wait("The fixture credits must load into the Credits section", timeout: 15) { composer.exists }
        XCTAssertFalse(ui.element("player.details.loading").exists)
        XCTAssertEqual(composer.value as? String, "Mithoon")
        XCTAssertEqual(ui.element("player.details.credit.lyricist").value as? String, "Mithoon")
        XCTAssertEqual(ui.element("player.details.credit.producer").value as? String, "Mithoon")

        let performer = ui.app.buttons["player.details.performer.0"]
        try ui.requireHittable(performer)
        XCTAssertEqual(performer.label, "Arijit Singh")
        XCTAssertGreaterThanOrEqual(performer.frame.height, 44 - 1e-6)
        XCTAssertGreaterThanOrEqual(performer.frame.width, 44 - 1e-6)

        let album = ui.element("player.details.album")
        try ui.reveal(album)
        XCTAssertEqual(album.value as? String, "Aashiqui 2")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        let expectedDate = formatter.string(from: try XCTUnwrap(ISO8601DateFormatter().date(from: "2013-04-01T00:00:00Z")))
        let released = ui.element("player.details.released")
        try ui.reveal(released)
        XCTAssertEqual(released.value as? String, expectedDate)
        let label = ui.element("player.details.label")
        try ui.reveal(label)
        XCTAssertEqual(label.value as? String, "\u{2117} 2013 T-Series")
        let source = ui.app.staticTexts["player.details.credits.source"]
        try ui.reveal(source)
        XCTAssertEqual(source.label, "Credits from YouTube's release notes")

        let plays = ui.element("player.details.yourPlays")
        try ui.reveal(plays)
        let playCount = Int((plays.value as? String) ?? "") ?? 0
        XCTAssertGreaterThanOrEqual(playCount, 6, "The seeded library holds six qualified plays of the first fixture song")
        let views = ui.element("player.details.views")
        try ui.reveal(views)
        XCTAssertEqual(views.value as? String, "1,234,567,890")
        let duration = ui.element("player.details.duration")
        try ui.reveal(duration)
        XCTAssertEqual(duration.value as? String, "4:22")
        let language = ui.element("player.details.language")
        try ui.reveal(language)
        XCTAssertEqual(language.value as? String, "Hindi")
        ui.capture("song-details-playback")

        let copy = ui.app.buttons["player.details.copyID"]
        try ui.reveal(copy)
        XCTAssertGreaterThanOrEqual(copy.frame.height, 44 - 1e-6)
        XCTAssertGreaterThanOrEqual(copy.frame.width, 44 - 1e-6)
        XCTAssertEqual(copy.label, "Copy recording ID")
        XCTAssertEqual(ui.app.staticTexts["player.details.recordingID"].label, AppUIFixture.tumHiHo)
        try ui.tap(copy)
        try ui.wait("Copying must confirm on the button") { copy.label == "Recording ID copied" }
        let openYouTube = ui.element("player.details.openYouTube")
        try ui.reveal(openYouTube)
        XCTAssertTrue(openYouTube.exists)

        let more = ui.app.buttons["player.details.description.more"]
        try ui.reveal(more)
        XCTAssertEqual(more.label, "Show More")
        XCTAssertGreaterThanOrEqual(more.frame.height, 44 - 1e-6)
        let collapsedHeight = ui.app.staticTexts["player.details.description"].frame.height
        try ui.tap(more)
        try ui.wait("Show more must expand the description") {
            more.label == "Show Less" && ui.app.staticTexts["player.details.description"].frame.height > collapsedHeight
        }
        ui.capture("song-details-description")

        // The system glass toolbar sizes its own buttons (36 points reported) and extends their hit areas itself.
        let refresh = ui.app.buttons["player.details.refresh"]
        try ui.requireHittable(refresh)
        XCTAssertEqual(refresh.label, "Refresh details")
        try ui.tap(refresh)
        try ui.wait("A refresh must finish without showing the loading row") {
            refresh.isEnabled && !ui.element("player.details.loading").exists && !ui.element("player.details.unavailable").exists
        }
        try ui.reveal(composer, direction: .down)
        XCTAssertEqual(composer.value as? String, "Mithoon", "A refresh keeps the loaded credits")

        try ui.tap(ui.app.buttons["player.options.back"])
        try ui.wait("Back must return to Song options") {
            ui.app.navigationBars["Song Options"].exists && ui.app.buttons["player.options.details"].exists
        }
        XCTAssertEqual(ui.app.otherElements.matching(identifier: "player.options.sheet").count, 1)
        try ui.tap(ui.app.buttons["player.options.toolbarDone"])
        try ui.wait("Done must close the options sheet") { !ui.element("player.options.sheet").exists }
    }

    func testSongWithoutDetailsShowsTheUnavailableStateWithRetry() throws {
        let ui = makeDriver()
        try ui.launch()
        try ui.search("Kesariya")
        try ui.playSearchResult(id: AppUIFixture.kesariya, title: "Kesariya")
        try openSongDetails(ui)
        XCTAssertEqual(ui.app.staticTexts["player.details.title"].label, "Kesariya")
        let message = ui.app.staticTexts["player.details.unavailable"]
        try ui.wait("The second fixture song has no details", timeout: 15) { message.exists }
        XCTAssertEqual(message.label, "Details are not available for this song right now.")
        XCTAssertFalse(ui.element("player.details.credit.composer").exists)
        XCTAssertFalse(ui.element("player.details.credits.source").exists)
        let retry = ui.app.buttons["player.details.retry"]
        try ui.reveal(retry)
        XCTAssertGreaterThanOrEqual(retry.frame.height, 44 - 1e-6)
        XCTAssertGreaterThanOrEqual(retry.frame.width, 44 - 1e-6)
        ui.capture("song-details-unavailable")
        try ui.tap(retry)
        try ui.wait("Retry must finish back in the unavailable state for a song without details", timeout: 15) {
            message.exists && !ui.element("player.details.loading").exists
        }
        XCTAssertTrue(ui.app.buttons["player.details.performer.0"].exists, "Performers come from the track itself")
    }

    func testPerformerRowClosesTheSheetAndPlayerAndOpensTheArtist() throws {
        let ui = makeDriver()
        try ui.launch()
        try ui.searchAndPlayTumHiHo()
        try openSongDetails(ui)
        let performer = ui.app.buttons["player.details.performer.0"]
        try ui.requireHittable(performer)
        XCTAssertEqual(performer.label, "Arijit Singh")
        try ui.tap(performer)
        try ui.expectArtistPage(named: "Arijit Singh")
        XCTAssertFalse(ui.element("player.options.sheet").exists)
        XCTAssertFalse(ui.app.buttons["player.close"].exists)
        try ui.requireHittable(ui.app.buttons["miniPlayer.open"])
        ui.capture("song-details-artist-page")
    }

    /// Mini-player to the full player to More; the details row leads the browse group, before Go to album (R14).
    private func openSongDetails(_ ui: AppUITestDriver) throws {
        try ui.openPlayer()
        try ui.openPlayerMenu()
        let details = ui.app.buttons["player.options.details"]
        try ui.requireHittable(details)
        XCTAssertEqual(details.label, "Song Details")
        let album = ui.app.buttons["player.options.album"]
        let artist = ui.app.buttons["player.options.artist"]
        let share = ui.app.buttons["player.options.share"]
        XCTAssertGreaterThan(details.frame.minY, share.frame.minY, "Song details follows the share rows")
        XCTAssertLessThan(details.frame.minY, album.frame.minY, "Song details precedes Go to album")
        XCTAssertLessThan(album.frame.minY, artist.frame.minY, "Go to album precedes Go to artist")
        try ui.tap(details)
        try ui.wait("The Song details page must open inside the options sheet") {
            ui.app.navigationBars["Song Details"].exists && ui.element("player.details.list").exists
        }
        XCTAssertEqual(ui.app.otherElements.matching(identifier: "player.options.sheet").count, 1)
    }

    private func makeDriver() -> AppUITestDriver {
        let ui = AppUITestDriver(testCase: self, prefix: "song-details")
        addTeardownBlock { await ui.finish() }
        return ui
    }
}

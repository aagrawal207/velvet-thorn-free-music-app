import Foundation
import XCTest

@MainActor
final class GanaBajanaArtistSpotlightUITests: XCTestCase {
    // Fixture shape: 20 listed songs plus 2 search-only collaborations; 5 listed recordings carry matched lyrics.
    private let listedSongs = 20
    private let searchOnlyCollaborations = 2
    private let identifiedLanguages = 5

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testArtistPageListsSearchOnlyCollaborationsUnderFeaturingAndPlaysThemAsTheirOwnQueue() throws {
        let ui = AppUITestDriver(testCase: self, prefix: "artist-featuring")
        addTeardownBlock { await ui.finish() }
        try ui.launch(additionalArguments: ["--artist-spotlight-fixture", "--search-results", "A. R. Rahman"])
        try ui.waitForSearchResults()
        try ui.tap(ui.app.buttons["search.featuredArtist"])
        try ui.reveal(ui.app.staticTexts["collection.monthlyAudience"])
        let featured = ui.app.buttons["track.play.fixture.spotlight.featured"]
        let titleFeature = ui.app.buttons["track.play.fixture.spotlight.featured.clause"]
        try ui.reveal(featured, maxSwipes: 14)
        let header = ui.element("artist.featuring.header")
        XCTAssertTrue(header.exists)
        XCTAssertTrue(ui.app.staticTexts["Featuring A. R. Rahman"].exists)
        XCTAssertTrue(ui.app.staticTexts["Sorted by available play counts"].exists)
        XCTAssertLessThan(header.frame.minY, featured.frame.minY)
        XCTAssertEqual(featured.label, "Harbour Duet, Spotlight Fixture Guest, A. R. Rahman")
        try ui.reveal(titleFeature)
        XCTAssertLessThan(featured.frame.minY, titleFeature.frame.minY, "950 provider plays precede 300")
        XCTAssertFalse(ui.app.buttons["artist.featuring.more"].exists, "Two collaborations fit under the 15-row cap")
        XCTAssertGreaterThanOrEqual(featured.frame.height + 1e-6, 44)
        ui.capture("artist-page-featuring-section")

        try ui.tap(featured)
        try ui.openPlayer()
        try ui.expectCurrentTrack("fixture.spotlight.featured")
        try ui.waitForAdvance(from: 0, by: 1)
        try ui.pause()
        try ui.openPlayerSheet("queue", title: "Queue")
        try ui.reveal(ui.element("queue.play.0.fixture.spotlight.featured"))
        try ui.reveal(ui.element("queue.play.1.fixture.spotlight.featured.clause"))
        XCTAssertFalse(ui.element("queue.play.2.fixture.spotlight.tamil").exists, "The section plays only its own collaborations")
        try ui.closeSheet("Queue")
        try ui.closePlayer()

        let card = ui.app.buttons["artist.spotlight.open"]
        try ui.reveal(card, direction: .down, maxSwipes: 14)
        try ui.tap(card)
        try ui.reveal(ui.app.staticTexts["artist.spotlight.countProvenance"])
        let spotlightTop = ui.app.buttons["track.play.fixture.spotlight.tamil"]
        let spotlightFeatured = ui.app.buttons["track.play.fixture.spotlight.featured"]
        try ui.reveal(spotlightTop)
        try ui.reveal(spotlightFeatured)
        XCTAssertLessThan(spotlightTop.frame.minY, spotlightFeatured.frame.minY, "1,200 plays precede 950 inside This is")
    }

    func testArtistCardOpensCountSortedCollectionWithPerSongLanguagesAndFilteredPlayback() throws {
        let ui = AppUITestDriver(testCase: self, prefix: "artist-spotlight")
        addTeardownBlock { await ui.finish() }
        try ui.launch(additionalArguments: ["--artist-spotlight-fixture", "--search-results", "A. R. Rahman"])
        try ui.waitForSearchResults()
        try ui.tap(ui.app.buttons["search.featuredArtist"])
        let monthlyAudience = ui.app.staticTexts["collection.monthlyAudience"]
        try ui.reveal(monthlyAudience)
        XCTAssertEqual(monthlyAudience.label, "12.3M monthly audience")
        let card = ui.app.buttons["artist.spotlight.open"]
        try ui.reveal(card)
        XCTAssertEqual(card.label, "This is A. R. Rahman")
        XCTAssertGreaterThanOrEqual(card.frame.height, 44)
        try ui.tap(card)
        try ui.reveal(ui.app.staticTexts["artist.spotlight.countProvenance"])
        XCTAssertEqual(ui.app.staticTexts["artist.spotlight.countProvenance"].label, "Sorted by available play counts")
        let browseLanguages = ui.app.buttons["artist.spotlight.browseLanguages"]
        try ui.reveal(browseLanguages)
        XCTAssertGreaterThanOrEqual(browseLanguages.frame.height + 1e-6, 44)
        XCTAssertFalse(ui.element("artist.spotlight.languages").exists)
        XCTAssertFalse(ui.app.buttons["artist.spotlight.correctLanguage.fixture.spotlight.tamil"].exists)
        XCTAssertFalse(ui.app.staticTexts["artist.spotlight.unclassified"].exists)
        ui.capture("artist-spotlight-song-list-default")
        try ui.tap(browseLanguages)
        let allSongs = listedSongs + searchOnlyCollaborations
        let unclassifiedSongs = allSongs - identifiedLanguages
        try ui.wait("Matched lyrics must produce recording-specific language counts", timeout: 25) {
            ui.app.buttons["artist.spotlight.language.hi"].label == "Hindi, 2 songs"
                && ui.app.buttons["artist.spotlight.language.ta"].label == "Tamil, 1 song"
                && ui.app.buttons["artist.spotlight.language.te"].label == "Telugu, 1 song"
                && ui.app.buttons["artist.spotlight.language.en"].label == "English, 1 song"
                && ui.app.buttons["artist.spotlight.language.unclassified"].label == "Unclassified, \(unclassifiedSongs) songs"
        }
        XCTAssertEqual(ui.app.buttons["artist.spotlight.language.all"].label, "All, \(allSongs) songs")
        XCTAssertTrue(ui.app.staticTexts["artist.spotlight.languageProvenance"].exists)
        let top = ui.app.buttons["track.play.fixture.spotlight.tamil"]
        let next = ui.app.buttons["track.play.fixture.spotlight.hindi"]
        try ui.reveal(top)
        try ui.reveal(next)
        XCTAssertLessThan(top.frame.minY, next.frame.minY, "1,200 provider plays must precede 800, despite the original listing order")
        ui.capture("artist-spotlight-language-browser-expanded")

        try selectLanguage("hi", ui: ui)
        try ui.reveal(browseLanguages, direction: .down)
        try ui.tap(browseLanguages)
        XCTAssertTrue((browseLanguages.value as? String)?.contains("Collapsed, Hindi") == true)
        XCTAssertFalse(ui.element("artist.spotlight.languages").exists)
        try ui.tap(browseLanguages)
        XCTAssertEqual(ui.app.buttons["artist.spotlight.language.hi"].value as? String, "Selected")
        try ui.reveal(next)
        let secondHindi = ui.app.buttons["track.play.fixture.spotlight.hindi.second"]
        try ui.reveal(secondHindi)
        XCTAssertLessThan(next.frame.minY, secondHindi.frame.minY)
        XCTAssertFalse(top.exists)
        let play = ui.app.buttons["collection.play"]
        try ui.reveal(play, direction: .down)
        try ui.tap(play)
        try ui.openPlayer()
        try ui.expectCurrentTrack("fixture.spotlight.hindi")
        try ui.waitForAdvance(from: 0, by: 1)
        try ui.pause()
        try ui.openPlayerSheet("queue", title: "Queue")
        try ui.reveal(ui.element("queue.play.0.fixture.spotlight.hindi"))
        try ui.reveal(ui.element("queue.play.1.fixture.spotlight.hindi.second"))
        XCTAssertFalse(ui.element("queue.play.2.fixture.spotlight.tamil").exists)
        try ui.closeSheet("Queue")
        try ui.closePlayer()

        try selectLanguage("ta", ui: ui)
        let shuffle = ui.app.buttons["collection.shuffle"]
        try ui.reveal(shuffle, direction: .down)
        try ui.tap(shuffle)
        try ui.openPlayer()
        try ui.expectCurrentTrack("fixture.spotlight.tamil")
        try ui.waitForAdvance(from: 0, by: 1)
        try ui.pause()
        try ui.closePlayer()
        try ui.tap(ui.app.buttons["collection.actions"])
        try ui.tap(ui.app.buttons["Add to a playlist"])
        try ui.requireHittable(ui.app.textFields["collection.playlistName"])
        XCTAssertEqual(ui.app.textFields["collection.playlistName"].value as? String, "This is A. R. Rahman")
        XCTAssertTrue(ui.app.buttons["Create and Add 1 Song"].exists)
        ui.capture("artist-spotlight-filtered-collection-playlist")
    }

    func testOptInLanguagesReachManualCorrectionAndClearingRestoresTheSource() throws {
        let ui = AppUITestDriver(testCase: self, prefix: "artist-language-correction")
        addTeardownBlock { await ui.finish() }
        try ui.launch(additionalArguments: ["--artist-spotlight-fixture", "--search-results", "A. R. Rahman"])
        try ui.waitForSearchResults()
        try ui.tap(ui.app.buttons["search.featuredArtist"])
        let card = ui.app.buttons["artist.spotlight.open"]
        try ui.reveal(card)
        try ui.tap(card)
        let browser = ui.app.buttons["artist.spotlight.browseLanguages"]
        try ui.reveal(browser)
        try ui.tap(browser)
        let correction = ui.app.buttons["artist.spotlight.correctLanguage.fixture.spotlight.tamil"]
        try ui.reveal(correction)
        try ui.wait("The reference song must finish its own language check", timeout: 25) {
            correction.label.contains(", Tamil")
        }
        try ui.tap(correction)
        let english = ui.app.buttons["artist.spotlight.setLanguage.en"]
        try ui.reveal(english)
        try ui.tap(english)
        try ui.wait("A saved correction must be visible on the song") {
            correction.label.contains(", English") && correction.value as? String == "Your correction"
        }
        try ui.tap(correction)
        let clear = ui.app.buttons["artist.spotlight.clearLanguage"]
        try ui.reveal(clear)
        try ui.tap(clear)
        try ui.wait("Clearing the correction must reveal the recording's inferred language") {
            correction.label.contains(", Tamil") && (correction.value as? String)?.contains("LRCLIB") == true
        }
    }

    private func selectLanguage(_ code: String, ui: AppUITestDriver) throws {
        let strip = ui.element("artist.spotlight.languages")
        try ui.reveal(strip, direction: .down)
        let button = ui.app.buttons["artist.spotlight.language.\(code)"]
        for _ in 0..<5 {
            if button.exists && button.isHittable { break }
            if ["all", "en", "hi"].contains(code) { strip.swipeRight() }
            else { strip.swipeLeft() }
        }
        try ui.tap(button)
        XCTAssertEqual(button.value as? String, "Selected")
    }
}

import Foundation
import XCTest

@MainActor
final class GanaBajanaArtistSpotlightUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
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
        try ui.wait("Matched lyrics must produce recording-specific language counts", timeout: 25) {
            ui.app.buttons["artist.spotlight.language.hi"].label == "Hindi, 2 songs"
                && ui.app.buttons["artist.spotlight.language.ta"].label == "Tamil, 1 song"
                && ui.app.buttons["artist.spotlight.language.te"].label == "Telugu, 1 song"
                && ui.app.buttons["artist.spotlight.language.en"].label == "English, 1 song"
                && ui.app.buttons["artist.spotlight.language.unclassified"].label == "Unclassified, 15 songs"
        }
        XCTAssertEqual(ui.app.buttons["artist.spotlight.language.all"].label, "All, 20 songs")
        XCTAssertTrue(ui.app.staticTexts["artist.spotlight.languageProvenance"].exists)
        let top = ui.app.buttons["track.play.fixture.spotlight.tamil"]
        let next = ui.app.buttons["track.play.fixture.spotlight.hindi"]
        try ui.reveal(top)
        try ui.reveal(next)
        XCTAssertLessThan(top.frame.minY, next.frame.minY, "1,200 provider plays must precede 800, despite the original listing order")

        try selectLanguage("hi", ui: ui)
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
        XCTAssertTrue(ui.app.buttons["Create and add 1 song"].exists)
        ui.capture("artist-spotlight-filtered-collection-playlist")
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

import Foundation
import XCTest

@MainActor
final class GanaBajanaLanguageCorrectionUITests: XCTestCase {
    func testSongLanguageCorrectionPersistsAndCanBeClearedOnItsOwn() throws {
        continueAfterFailure = false
        let ui = AppUITestDriver(testCase: self, prefix: "language-correction")
        addTeardownBlock { await ui.finish() }
        try ui.launch(additionalArguments: ["--artist-spotlight-fixture", "--search-results", "A. R. Rahman"])
        try openSpotlight(ui)
        let row = ui.app.buttons["artist.spotlight.correctLanguage.fixture.spotlight.tamil"]
        try ui.reveal(row)
        try ui.tap(row)
        try ui.tap(ui.app.buttons["artist.spotlight.setLanguage.en"])
        try ui.wait("A correction must update the row immediately") { row.label.contains("English") }

        try ui.relaunch()
        try openSpotlight(ui)
        try ui.reveal(row)
        XCTAssertTrue(row.label.contains("English"))
        try ui.tap(row)
        try ui.requireHittable(ui.app.buttons["artist.spotlight.clearLanguage"])
        try ui.tap(ui.app.buttons["artist.spotlight.clearLanguage"])
        try ui.tap(row)
        XCTAssertFalse(ui.app.buttons["artist.spotlight.clearLanguage"].exists)
        ui.capture("song-language-correction-cleared")
    }

    private func openSpotlight(_ ui: AppUITestDriver) throws {
        try ui.waitForSearchResults()
        try ui.tap(ui.app.buttons["search.featuredArtist"])
        try waitForPageReady("collection.monthlyAudience", label: "12.3M monthly audience", in: ui)
        let card = ui.app.buttons["artist.spotlight.open"]
        try ui.reveal(card)
        try ui.tap(card)
        try waitForPageReady("artist.spotlight.countProvenance", label: "Sorted by available play counts", in: ui)
    }

    private func waitForPageReady(_ identifier: String, label: String, in ui: AppUITestDriver) throws {
        let marker = ui.app.staticTexts[identifier]
        let scroll = ui.app.scrollViews.containing(.staticText, identifier: identifier).firstMatch
        try ui.expectLabel(marker, label)
        // A destination marker can appear before its navigation transition has valid scroll geometry.
        try ui.wait("The \(identifier) destination must have a visible scroll viewport") {
            guard scroll.exists else { return false }
            let frame = scroll.frame
            return [frame.minX, frame.minY, frame.maxX, frame.maxY].allSatisfy(\.isFinite)
                && !frame.isEmpty && frame.intersection(ui.app.windows.firstMatch.frame).height > 50
        }
        try ui.requireHittable(marker)
    }
}

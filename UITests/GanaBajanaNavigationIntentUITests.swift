import Foundation
import XCTest

@MainActor
final class GanaBajanaNavigationIntentUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testLocalNativeLinksReopenAfterBackAndKeepTheMiniPlayerViewport() throws {
        let ui = makeDriver()
        try ui.launch(additionalArguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"])
        try ui.searchAndPlayTumHiHo()
        try ui.openPlayer()
        try ui.waitForAdvance(from: 0, by: 1)
        try ui.pause()
        try ui.closePlayer()
        try ui.selectTab("home")

        for _ in 0..<2 {
            let customize = ui.app.buttons["home.customize"]
            try ui.reveal(customize, direction: .down)
            try ui.tap(customize)
            try ui.reveal(ui.app.switches["home.customization.show.charts"])
            try ui.setSwitch("home.customization.show.charts", to: false)
            try ui.setSwitch("home.customization.show.charts", to: true)
            try ui.assertMiniPlayerAboveTabs()
            XCTAssertEqual(ui.element("miniPlayer.container").frame.height, 64, accuracy: 1)
            try ui.tap(ui.app.navigationBars["Customize Home"].buttons.firstMatch)
            try ui.requireHittable(customize)
        }

        try ui.selectTab("library")
        for _ in 0..<2 {
            try ui.reveal(ui.app.buttons["library.likes"], direction: .down)
            try ui.tap(ui.app.buttons["library.likes"])
            try ui.reveal(ui.app.buttons["track.play.\(AppUIFixture.tumHiHo)"])
            try ui.assertMiniPlayerAboveTabs()
            try ui.tap(ui.app.navigationBars["Liked songs"].buttons["Back"])
            try ui.requireHittable(ui.app.buttons["library.createPlaylist"])
        }
        ui.capture("native-local-links-back-and-reopen")
    }

    func testSearchReselectionPopsLocalSpotlightAndKeepsItsNewFocusRequest() throws {
        let ui = makeDriver()
        try ui.launch(additionalArguments: ["--artist-spotlight-fixture", "--search-results", "A. R. Rahman"])
        for _ in 0..<2 {
            try ui.waitForSearchResults()
            try ui.tap(ui.app.buttons["search.featuredArtist"])
            try ui.reveal(ui.app.buttons["artist.spotlight.open"])
            try ui.tap(ui.app.buttons["artist.spotlight.open"])
            try ui.reveal(ui.app.staticTexts["artist.spotlight.countProvenance"])
            try ui.tap(ui.app.tabBars.buttons["Search"])
            try ui.wait("Reselect must pop both artist destinations and focus the existing Search draft") {
                ui.app.textFields["search.field"].exists && ui.app.keyboards.firstMatch.exists
                    && !ui.app.staticTexts["artist.spotlight.countProvenance"].exists
            }
            try ui.expectValue(ui.app.textFields["search.field"], "A. R. Rahman")
            try ui.requireHittable(ui.app.buttons["search.filter.songs"])
            try ui.dismissSearchKeyboard()
        }
        ui.capture("local-spotlight-search-reselection")
    }

    func testNameOnlyPlayerArtistOpensAfterEmptySearchDiscoveryReappears() throws {
        let ui = makeDriver()
        try ui.launch(additionalArguments: ["--artist-navigation-fixture"])
        try ui.selectTab("search")
        try ui.requireHittable(ui.app.staticTexts["Start somewhere good"])
        XCTAssertFalse(ui.app.keyboards.firstMatch.exists)
        try ui.openPlayer()
        let artist = ui.app.buttons["player.artistName"]
        try ui.expectLabel(artist, "Go to artist, Norah Jones")
        try ui.tap(artist)
        try ui.wait("Search discovery must reappear while the name-only artist lookup is still loading") {
            ui.app.textFields["search.field"].exists && ui.app.staticTexts["Start somewhere good"].exists
                && !ui.app.buttons["player.close"].exists
        }
        try ui.expectArtistPage(named: "Norah Jones")
        XCTAssertFalse(ui.app.keyboards.firstMatch.exists)
        XCTAssertFalse(ui.app.buttons["player.close"].exists)
        ui.capture("name-only-artist-survives-search-reappearance")
    }

    private func makeDriver() -> AppUITestDriver {
        let ui = AppUITestDriver(testCase: self, prefix: "navigation-intent")
        addTeardownBlock { await ui.finish() }
        return ui
    }
}

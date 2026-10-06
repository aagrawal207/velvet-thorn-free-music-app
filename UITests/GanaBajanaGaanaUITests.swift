import Foundation
import XCTest

/// Gaana catalog behind the `MusicSource` abstraction: a "Gaana" search section with a source badge on its rows,
/// playback of a `gaana:` song and the Settings > Discovery > Catalog sources switch. Runs against the network-free
/// `--gaana-fixture` provider; the stream is the shared fixture waveform.
@MainActor
final class GanaBajanaGaanaUITests: XCTestCase {
    private static let gaanaSongID = "gaana:944286"
    private static let gaanaAlbumID = "gaana:album:92317"

    override func setUpWithError() throws { continueAfterFailure = false }

    func testSearchShowsAGaanaSectionWithBadgedRowsAndPlaysTheSong() throws {
        let ui = makeDriver()
        try ui.launch(additionalArguments: ["--gaana-fixture"])
        try ui.search("tum")
        try ui.waitForSearchResults()
        let youTubeHeader = ui.element("search.section.youtube")
        let gaanaHeader = ui.element("search.section.gaana")
        try ui.wait("Both catalogs must contribute a section") { youTubeHeader.exists && gaanaHeader.exists }
        XCTAssertTrue(ui.app.staticTexts["YouTube Music"].exists)
        XCTAssertLessThan(youTubeHeader.frame.minY, gaanaHeader.frame.minY, "YouTube Music results lead")
        XCTAssertTrue(ui.app.buttons["track.play.\(AppUIFixture.tumHiHo)"].exists)
        let gaanaRow = ui.app.buttons["track.play.\(Self.gaanaSongID)"]
        try ui.reveal(gaanaRow)
        XCTAssertGreaterThanOrEqual(gaanaRow.frame.height, 44 - 1e-6)
        XCTAssertTrue(gaanaRow.value.map { String(describing: $0) }?.contains("Gaana") == true,
                      "The row tells VoiceOver where the song comes from")
        let badge = ui.element("track.source.\(Self.gaanaSongID)")
        try ui.wait("The row carries a Gaana badge") { badge.exists }
        XCTAssertEqual(badge.label, "Gaana")
        XCTAssertFalse(ui.element("track.source.\(AppUIFixture.tumHiHo)").exists, "YouTube Music rows stay unmarked")
        ui.capture("search-gaana-section")

        try ui.selectSearchFilter("albums")
        try ui.waitForSearchResults()
        let gaanaAlbum = ui.app.buttons["collection.\(Self.gaanaAlbumID)"]
        try ui.reveal(gaanaAlbum)
        XCTAssertTrue(ui.app.buttons["collection.\(AppUIFixture.album)"].exists, "Filters apply per source")
        try ui.wait("Album results keep the source headings") { ui.element("search.section.gaana").exists }
        try ui.tap(gaanaAlbum)
        try ui.wait("The Gaana album must open through the shared collection page") {
            ui.app.staticTexts["ALBUM"].exists && ui.app.buttons["track.play.\(Self.gaanaSongID)"].exists
        }
        let back = ui.app.navigationBars.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "Back", "Search")).firstMatch
        try ui.tap(back)
        try ui.selectSearchFilter("songs")
        try ui.playSearchResult(id: Self.gaanaSongID, title: "Tum Hi Ho")
        try ui.openPlayer()
        try ui.expectCurrentTrack(Self.gaanaSongID)
        XCTAssertTrue(ui.app.staticTexts["player.track.\(Self.gaanaSongID)"].label.contains("Tum Hi Ho"))
        ui.capture("player-gaana-song")
        try ui.closePlayer()
    }

    func testCatalogSourcesSettingHidesTheGaanaSection() throws {
        let ui = makeDriver()
        try ui.launch(additionalArguments: ["--gaana-fixture"])
        try ui.openSettings()
        try ui.openSettingsPage(.discovery)
        let row = ui.app.buttons["settings.sources"]
        try ui.reveal(row, maxSwipes: 24)
        try ui.tap(row)
        try ui.wait("Settings must open the Catalog sources page") { ui.app.navigationBars["Catalog Sources"].exists }
        let gaana = ui.app.switches["settings.sources.gaana"]
        try ui.wait("Gaana is listed and switchable") { gaana.exists && gaana.isEnabled }
        XCTAssertEqual(gaana.label, "Gaana")
        try ui.expectSwitch("settings.sources.gaana", isOn: true)
        try ui.expectSwitch("settings.sources.saavn", isOn: true)
        try ui.setSwitch("settings.sources.gaana", to: false)
        // Switching Gaana off leaves JioSaavn alone.
        try ui.expectSwitch("settings.sources.saavn", isOn: true)
        ui.capture("settings-catalog-sources-gaana-off")
        try ui.tap(ui.app.navigationBars["Catalog Sources"].buttons.firstMatch)
        try ui.wait("Back returns to the Discovery page") { ui.app.navigationBars[SettingsPageID.discovery.title].exists }
        try ui.tap(ui.app.buttons["settings.done"])

        try ui.search("tum")
        try ui.waitForSearchResults()
        XCTAssertTrue(ui.app.buttons["track.play.\(AppUIFixture.tumHiHo)"].exists)
        XCTAssertFalse(ui.element("search.section.gaana").exists, "A switched-off source contributes no section")
        XCTAssertFalse(ui.app.buttons["track.play.\(Self.gaanaSongID)"].exists)
        XCTAssertTrue(ui.app.staticTexts["Songs"].exists, "A single source keeps the plain heading")

        try ui.openSettings()
        try ui.openSettingsPage(.discovery)
        try ui.reveal(ui.app.buttons["settings.sources"], maxSwipes: 24)
        try ui.tap(ui.app.buttons["settings.sources"])
        try ui.setSwitch("settings.sources.gaana", to: true)
        try ui.tap(ui.app.navigationBars["Catalog Sources"].buttons.firstMatch)
        try ui.tap(ui.app.buttons["settings.done"])
        try ui.search("tum")
        try ui.waitForSearchResults()
        try ui.wait("Re-enabling the source brings its section back") { ui.element("search.section.gaana").exists }
    }

    private func makeDriver() -> AppUITestDriver {
        let ui = AppUITestDriver(testCase: self, prefix: "gaana")
        addTeardownBlock { await ui.finish() }
        return ui
    }
}

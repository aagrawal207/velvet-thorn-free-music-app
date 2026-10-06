import Foundation
import XCTest

/// JioSaavn catalog behind the `MusicSource` abstraction: grouped search sections, playback of a `saavn:` song and the
/// Settings > Discovery > Catalog sources switch. Runs against the network-free `--saavn-fixture` provider.
@MainActor
final class GanaBajanaCatalogSourcesUITests: XCTestCase {
    private static let saavnSongID = "saavn:fixtureTum01"
    private static let saavnAlbumID = "saavn:album:fixtureJabWeMet"

    override func setUpWithError() throws { continueAfterFailure = false }

    func testSearchGroupsResultsBySourceAndPlaysAJioSaavnSong() throws {
        let ui = makeDriver()
        try ui.launch(additionalArguments: ["--saavn-fixture"])
        try ui.search("tum")
        try ui.waitForSearchResults()
        let youTubeHeader = ui.element("search.section.youtube")
        let saavnHeader = ui.element("search.section.saavn")
        try ui.wait("Both catalogs must contribute a section") { youTubeHeader.exists && saavnHeader.exists }
        XCTAssertTrue(ui.app.staticTexts["YouTube Music"].exists)
        XCTAssertTrue(ui.app.staticTexts["JioSaavn"].exists)
        XCTAssertLessThan(youTubeHeader.frame.minY, saavnHeader.frame.minY, "YouTube Music results lead")
        let youTubeRow = ui.app.buttons["track.play.\(AppUIFixture.tumHiHo)"]
        XCTAssertTrue(youTubeRow.exists)
        let saavnRow = ui.app.buttons["track.play.\(Self.saavnSongID)"]
        try ui.reveal(saavnRow)
        XCTAssertGreaterThanOrEqual(saavnRow.frame.height, 44 - 1e-6)
        XCTAssertTrue(saavnRow.value.map { String(describing: $0) }?.contains("JioSaavn") == true,
                      "The row tells VoiceOver where the song comes from")
        ui.capture("search-grouped-by-source")

        try ui.selectSearchFilter("albums")
        try ui.waitForSearchResults()
        let saavnAlbum = ui.app.buttons["collection.\(Self.saavnAlbumID)"]
        try ui.reveal(saavnAlbum)
        XCTAssertTrue(ui.app.buttons["collection.\(AppUIFixture.album)"].exists, "Filters apply per source")
        try ui.wait("Album results keep the source headings") { ui.element("search.section.saavn").exists }
        try ui.tap(saavnAlbum)
        try ui.wait("The JioSaavn album must open through the shared collection page") {
            ui.app.staticTexts["ALBUM"].exists && ui.app.buttons["track.play.\(Self.saavnSongID)"].exists
        }
        let back = ui.app.navigationBars.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "Back", "Search")).firstMatch
        try ui.tap(back)
        try ui.selectSearchFilter("songs")
        try ui.playSearchResult(id: Self.saavnSongID, title: "Tum Se Hi")
        try ui.openPlayer()
        try ui.expectCurrentTrack(Self.saavnSongID)
        XCTAssertTrue(ui.app.staticTexts["player.track.\(Self.saavnSongID)"].label.contains("Tum Se Hi"))
        ui.capture("player-jiosaavn-song")
        try ui.closePlayer()
    }

    func testCatalogSourcesSettingHidesTheJioSaavnSection() throws {
        let ui = makeDriver()
        try ui.launch(additionalArguments: ["--saavn-fixture"])
        try ui.openSettings()
        try ui.openSettingsPage(.discovery)
        let row = ui.app.buttons["settings.sources"]
        try ui.reveal(row, maxSwipes: 24)
        XCTAssertGreaterThanOrEqual(row.frame.height, 44 - 1e-6)
        XCTAssertTrue(ui.accessibleText(ui.element("settings.sources.description")).contains("JioSaavn"))
        try ui.tap(row)
        try ui.wait("Settings must open the Catalog sources page") { ui.app.navigationBars["Catalog Sources"].exists }
        let gaana = ui.app.switches["settings.sources.gaana"]
        try ui.wait("Gaana is listed as a switchable source") { gaana.exists && gaana.isEnabled }
        XCTAssertEqual(gaana.label, "Gaana")
        XCTAssertTrue(ui.element("settings.sources.footer").exists)
        try ui.expectSwitch("settings.sources.saavn", isOn: true)
        try ui.setSwitch("settings.sources.saavn", to: false)
        ui.capture("settings-catalog-sources-saavn-off")
        try ui.tap(ui.app.navigationBars["Catalog Sources"].buttons.firstMatch)
        try ui.wait("Back returns to the Discovery page") { ui.app.navigationBars[SettingsPageID.discovery.title].exists }
        let sources = ui.accessibleText(ui.element("settings.sources.description"))
        XCTAssertFalse(sources.contains("JioSaavn"), sources)
        XCTAssertTrue(sources.contains("Gaana"), "The note keeps naming the sources that stay on: \(sources)")
        try ui.tap(ui.app.buttons["settings.done"])

        try ui.search("tum")
        try ui.waitForSearchResults()
        XCTAssertTrue(ui.app.buttons["track.play.\(AppUIFixture.tumHiHo)"].exists)
        XCTAssertFalse(ui.element("search.section.saavn").exists, "A switched-off source contributes no section")
        XCTAssertFalse(ui.app.buttons["track.play.\(Self.saavnSongID)"].exists)
        XCTAssertTrue(ui.app.staticTexts["Songs"].exists, "A single source keeps the plain heading")

        try ui.openSettings()
        try ui.openSettingsPage(.discovery)
        try ui.reveal(ui.app.buttons["settings.sources"], maxSwipes: 24)
        try ui.tap(ui.app.buttons["settings.sources"])
        try ui.setSwitch("settings.sources.saavn", to: true)
        try ui.tap(ui.app.navigationBars["Catalog Sources"].buttons.firstMatch)
        try ui.tap(ui.app.buttons["settings.done"])
        try ui.search("tum")
        try ui.waitForSearchResults()
        try ui.wait("Re-enabling the source brings its section back") { ui.element("search.section.saavn").exists }
    }

    private func makeDriver() -> AppUITestDriver {
        let ui = AppUITestDriver(testCase: self, prefix: "catalog-sources")
        addTeardownBlock { await ui.finish() }
        return ui
    }
}

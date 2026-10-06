import UIKit
import XCTest

@MainActor
final class GanaBajanaCollectionPresentationUITests: XCTestCase {
    private let fixtureSongs: [(id: String, title: String, artist: String, duration: String)] = [
        (AppUIFixture.tumHiHo, "Tum Hi Ho", "Arijit Singh", "4:22"),
        (AppUIFixture.kesariya, "Kesariya", "Arijit Singh", "4:29"),
        (AppUIFixture.agarTumSaathHo, "Agar Tum Saath Ho", "Alka Yagnik, Arijit Singh", "5:42"),
        (AppUIFixture.blindingLights, "Blinding Lights", "The Weeknd", "3:22"),
        (AppUIFixture.shapeOfYou, "Shape of You", "Ed Sheeran", "3:54"),
    ]

    override func setUpWithError() throws { continueAfterFailure = false }

    func testAlbumShowsSongLengthsAndKeepsItsSummaryBelowTheContentAndAboveTheMiniPlayer() throws {
        let ui = makeDriver()
        try ui.launch(additionalArguments: ["--album-description-fixture", "--artwork-fixture"])
        try openCatalogCollection(ui, filter: "albums", kind: "ALBUM")
        assertSummaryIsOutsideHeader(ui)
        try ui.wait("Album description metadata must arrive") { ui.app.staticTexts["album.description.text"].exists }
        ui.capture("collection-album-header-dark")

        for song in fixtureSongs { try assertDurationRow(ui, song: song) }
        try ui.tap(ui.app.buttons["track.play.\(AppUIFixture.shapeOfYou)"])
        try ui.wait("A duration row must still play its song") {
            ui.app.buttons["miniPlayer.open"].label.contains("Shape of You")
        }
        try assertFooter(ui, lastTrackID: AppUIFixture.shapeOfYou)
        let summary = ui.app.staticTexts["collection.summary"]
        XCTAssertGreaterThan(summary.frame.minY, ui.app.staticTexts["album.description.text"].frame.maxY)
        let mini = ui.app.otherElements["miniPlayer.container"]
        XCTAssertTrue(mini.exists)
        XCTAssertLessThanOrEqual(summary.frame.maxY, mini.frame.minY + 1)
        ui.capture("collection-album-durations-footer-mini-player")
    }

    func testMixShowsEachLengthAndOneFooterSummary() throws {
        let ui = makeDriver()
        try ui.launch(additionalArguments: ["--light", "--artwork-fixture"])
        let recentMix = ui.app.buttons["Recently Played, see all"]
        try ui.reveal(recentMix)
        try ui.tap(recentMix)
        try ui.wait("Recently played must open its mix collection") {
            ui.app.staticTexts["MIX"].exists && ui.app.buttons["collection.play"].exists
        }
        assertSummaryIsOutsideHeader(ui)
        ui.capture("collection-mix-header-light")
        for song in fixtureSongs.reversed() { try assertDurationRow(ui, song: song) }
        try assertFooter(ui, lastTrackID: AppUIFixture.tumHiHo)
        ui.capture("collection-mix-durations-footer-light")
    }

    func testCatalogPlaylistAlsoShowsSongLengths() throws {
        let ui = makeDriver()
        try ui.launch()
        try openCatalogCollection(ui, filter: "playlists", kind: "PLAYLIST")
        assertSummaryIsOutsideHeader(ui)
        try assertDurationRow(ui, song: fixtureSongs[0])
        try assertDurationRow(ui, song: fixtureSongs[4])
        try assertFooter(ui, lastTrackID: AppUIFixture.shapeOfYou)
    }

    func testLargestTextKeepsLongSongTitlesDurationsAndMenusReachable() throws {
        let ui = makeDriver()
        try ui.launch(additionalArguments: ["--light", "--artwork-fixture", "-UIPreferredContentSizeCategoryName",
                                            UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue])
        try openCatalogCollection(ui, filter: "albums", kind: "ALBUM")
        assertSummaryIsOutsideHeader(ui)
        try assertDurationRow(ui, song: fixtureSongs[2])
        ui.capture("collection-album-long-title-accessibility-xxxl")
        try assertDurationRow(ui, song: fixtureSongs[4])
        try assertFooter(ui, lastTrackID: AppUIFixture.shapeOfYou)
        ui.capture("collection-album-footer-accessibility-xxxl")
    }

    private func openCatalogCollection(_ ui: AppUITestDriver, filter: String, kind: String) throws {
        try ui.search("Arijit")
        try ui.waitForSearchResults()
        try ui.selectSearchFilter(filter)
        let collection = ui.app.buttons["collection.\(AppUIFixture.album)"]
        try ui.reveal(collection)
        try ui.tap(collection)
        try ui.wait("The catalog must supply the collection's songs") {
            ui.app.staticTexts[kind].exists && ui.app.buttons["collection.play"].exists
        }
    }

    private func assertSummaryIsOutsideHeader(_ ui: AppUITestDriver, file: StaticString = #filePath, line: UInt = #line) {
        let header = ui.app.otherElements["collection.header"]
        XCTAssertTrue(header.exists, file: file, line: line)
        XCTAssertFalse(header.staticTexts["collection.summary"].exists, file: file, line: line)
        XCTAssertFalse(header.staticTexts["5 songs · 21:49"].exists, file: file, line: line)
    }

    private func assertDurationRow(_ ui: AppUITestDriver, song: (id: String, title: String, artist: String, duration: String),
                                   file: StaticString = #filePath, line: UInt = #line) throws {
        let row = ui.app.buttons["track.play.\(song.id)"]
        try ui.reveal(row, maxSwipes: 24)
        XCTAssertEqual(row.label, "\(song.title), \(song.artist)", file: file, line: line)
        XCTAssertEqual(row.value as? String, "Duration \(song.duration)", file: file, line: line)
        let duration = ui.app.staticTexts["track.duration.\(song.id)"]
        XCTAssertTrue(duration.exists, file: file, line: line)
        XCTAssertEqual(duration.label, song.duration, file: file, line: line)
        XCTAssertGreaterThan(duration.frame.width, 0, file: file, line: line)
        XCTAssertGreaterThan(duration.frame.height, 0, file: file, line: line)
        XCTAssertTrue(row.frame.insetBy(dx: -1, dy: -1).contains(duration.frame), file: file, line: line)

        let menu = ui.app.buttons["track.options.\(song.id)"]
        try ui.reveal(menu, maxSwipes: 24)
        XCTAssertGreaterThanOrEqual(menu.frame.width + 1e-6, 44, file: file, line: line)
        XCTAssertGreaterThanOrEqual(menu.frame.height + 1e-6, 44, file: file, line: line)
        XCTAssertLessThanOrEqual(duration.frame.maxX, menu.frame.minX + 1, file: file, line: line)
    }

    private func assertFooter(_ ui: AppUITestDriver, lastTrackID: String,
                              file: StaticString = #filePath, line: UInt = #line) throws {
        let summary = ui.app.staticTexts["collection.summary"]
        try ui.reveal(summary, maxSwipes: 24)
        XCTAssertEqual(summary.label, "5 songs · 21:49", file: file, line: line)
        XCTAssertEqual(ui.app.staticTexts.matching(identifier: "collection.summary").count, 1, file: file, line: line)
        let lastRow = ui.app.buttons["track.play.\(lastTrackID)"]
        XCTAssertTrue(lastRow.exists, file: file, line: line)
        XCTAssertGreaterThan(lastRow.frame.height, 0, file: file, line: line)
        XCTAssertGreaterThan(summary.frame.minY, lastRow.frame.maxY, file: file, line: line)
        XCTAssertTrue(ui.app.windows.firstMatch.frame.insetBy(dx: -1, dy: -1).contains(summary.frame), file: file, line: line)
    }

    private func makeDriver() -> AppUITestDriver {
        let ui = AppUITestDriver(testCase: self, prefix: "collection-presentation")
        addTeardownBlock { await ui.finish() }
        return ui
    }
}

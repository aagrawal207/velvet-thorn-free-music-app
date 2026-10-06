import XCTest

/// R14 items 3 to 6 and the Library half of 16: compact Library entries, liked/downloaded/on-device filters,
/// the offline On this device list, Recap's Recently played section, the share card and the Following scroll.
@MainActor
final class GanaBajanaLibraryOrganisationUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testCompactEntriesAreOneGroupOfShortRowsOnTheFirstScreenWithoutRecentListens() throws {
        let ui = makeDriver()
        try launch(ui, arguments: ["--cache-fixture"])
        try ui.tap(ui.app.buttons["tab.library"].firstMatch)
        let rows = ["library.likes", "library.downloads"].map { ui.app.buttons[$0] }
        try ui.wait("Listening entries must be on the Library root") { rows.allSatisfy(\.exists) }
        XCTAssertFalse(ui.app.buttons["library.cachedSongs"].exists, "Cache management is in Settings > Storage")
        let bottom = visibleBottom(ui)
        var measurements: [String] = []
        for row in rows {
            try ui.requireHittable(row)
            XCTAssertGreaterThanOrEqual(row.frame.height + 1e-6, 44, "\(row.identifier) keeps a 44-point target")
            XCTAssertLessThanOrEqual(row.frame.height, 60 + 1e-6, "\(row.identifier) is a compact row, not a card")
            XCTAssertLessThanOrEqual(row.frame.maxY, bottom + 1e-6, "\(row.identifier) is visible without scrolling")
            measurements.append("\(row.identifier) \(row.frame)")
        }
        // One inset card: rows touch across a hairline and share a width.
        for (upper, lower) in zip(rows, rows.dropFirst()) {
            XCTAssertLessThan(lower.frame.minY - upper.frame.maxY, 2.5, "\(lower.identifier) continues the group")
            XCTAssertEqual(lower.frame.width, upper.frame.width, accuracy: 1)
        }
        XCTAssertEqual(rows[0].label, "Liked Songs")
        XCTAssertEqual(rows[0].value as? String, "5 songs")
        XCTAssertEqual(rows[1].value as? String, "Keep music on this device.")
        let playlists = ui.app.staticTexts["Playlists"]
        XCTAssertTrue(playlists.exists && playlists.frame.maxY <= bottom, "Playlists now start on the first screen")
        for gone in ["library.recents.all", "library.findMusic"] { XCTAssertFalse(ui.app.buttons[gone].exists, gone) }
        XCTAssertFalse(ui.app.staticTexts["Recent listens"].exists, "Recent listens moved to Recap")
        ui.note("library-entry-frames", measurements.joined(separator: "\n"))
        ui.capture("library-top")
    }

    func testLikedSongsChipsFilterDownloadedAndOnThisDeviceAndDownloadsFiltersLiked() throws {
        let ui = makeDriver()
        try launch(ui, arguments: ["--cache-fixture", "--cache-fixture-downloaded"])
        try ui.tap(ui.app.buttons["tab.library"].firstMatch)
        try ui.tap(ui.app.buttons["library.likes"])
        try ui.wait("Liked songs must open") { ui.app.navigationBars["Liked Songs"].exists }
        let all = ui.app.buttons["library.likes.filter.all"]
        let superLiked = ui.app.buttons["library.likes.filter.superLiked"]
        let downloaded = ui.app.buttons["library.likes.filter.downloaded"]
        let onDevice = ui.app.buttons["library.likes.filter.onDevice"]
        let count = ui.app.staticTexts["library.likes.count"]
        for chip in [all, superLiked, downloaded, onDevice] { try assertTarget(chip, ui: ui) }
        XCTAssertFalse(ui.app.buttons["library.likes.downloadedOnly"].exists, "The toolbar toggle became the chips")
        XCTAssertTrue(all.isSelected)
        XCTAssertEqual([all.label, superLiked.label, downloaded.label, onDevice.label], ["All", "Super Liked", "Downloaded", "On This Device"])
        XCTAssertLessThan(all.frame.maxY, ui.app.buttons["library.likes.play"].frame.minY, "Chips sit above Play")
        try ui.expectLabel(count, "5 songs")

        try ui.tap(downloaded)
        try ui.wait("Downloaded keeps only the downloaded like") { downloaded.isSelected && count.label == "1 of 5 songs" }
        XCTAssertTrue(ui.app.buttons["track.play.\(AppUIFixture.tumHiHo)"].exists)
        XCTAssertFalse(ui.app.buttons["track.play.\(AppUIFixture.kesariya)"].exists)

        try ui.tap(onDevice)
        try ui.wait("On this device adds complete cached copies") { onDevice.isSelected && count.label == "3 of 5 songs" }
        for id in [AppUIFixture.tumHiHo, AppUIFixture.kesariya, AppUIFixture.agarTumSaathHo] {
            // Rows are lazy; the taller chip block can leave the third one just below the fold.
            try ui.reveal(ui.app.buttons["track.play.\(id)"])
            XCTAssertTrue(ui.app.buttons["track.play.\(id)"].exists, id)
        }
        for id in [AppUIFixture.blindingLights, AppUIFixture.shapeOfYou] {
            XCTAssertFalse(ui.app.buttons["track.play.\(id)"].exists, "\(id) has no complete local copy")
        }
        ui.capture("liked-songs-chips-on-this-device")
        try ui.tap(ui.app.buttons["library.likes.play"])
        try ui.wait("Play queues only the filtered songs") {
            let mini = ui.app.buttons["miniPlayer.open"]
            return mini.exists && ["Tum Hi Ho", "Kesariya", "Agar Tum Saath Ho"].contains { mini.label.contains($0) }
        }
        try ui.tap(all)
        try ui.wait("All restores every like") { all.isSelected && count.label == "5 songs" }

        // Downloads: the Liked chip hides a download once its song is no longer liked.
        try ui.tap(ui.app.navigationBars["Liked Songs"].buttons.firstMatch)
        try ui.tap(ui.app.buttons["library.downloads"])
        try ui.wait("Downloads must open") { ui.app.navigationBars["Downloads"].exists }
        let liked = ui.app.buttons["downloads.filter.liked"]
        let row = ui.app.buttons["downloads.play.\(AppUIFixture.tumHiHo)"]
        try assertTarget(liked, ui: ui)
        XCTAssertTrue(ui.app.buttons["downloads.filter.all"].isSelected)
        try ui.tap(liked)
        try ui.wait("A liked download stays under Liked") { liked.isSelected && row.exists }
        try ui.tap(ui.app.navigationBars["Downloads"].buttons.firstMatch)
        try ui.tap(ui.app.buttons["library.likes"])
        let likedRow = ui.app.buttons["track.play.\(AppUIFixture.tumHiHo)"]
        try ui.reveal(likedRow)
        likedRow.swipeLeft()
        try ui.tap(ui.app.buttons["library.unlike.\(AppUIFixture.tumHiHo)"])
        try ui.wait("Unliking removes the row") { count.label == "4 songs" }
        try ui.tap(ui.app.navigationBars["Liked Songs"].buttons.firstMatch)
        try ui.tap(ui.app.buttons["library.downloads"])
        try ui.wait("Downloads must open again") { ui.app.navigationBars["Downloads"].exists }
        try ui.tap(liked)
        try ui.wait("An unliked download leaves the Liked filter, and the file stays") {
            ui.element("downloads.filter.empty").exists && !row.exists
                && ui.app.staticTexts["downloads.summary"].label.hasPrefix("1 song on this device")
        }
        try ui.tap(ui.app.buttons["downloads.filter.all"])
        try ui.wait("All shows the download again") { row.exists }
    }

    func testOfflineBannerOpensOnThisDeviceWithDownloadsFirstAndPlaysWithoutNetwork() throws {
        let ui = makeDriver()
        try launch(ui, arguments: ["--cache-fixture", "--cache-fixture-downloaded", "--offline-fixture"])
        let action = ui.app.buttons["offline.onThisDevice"]
        try ui.requireHittable(action)
        try ui.tap(action)
        try ui.wait("The banner opens On this device") { ui.app.navigationBars["On This Device"].exists }
        let count = ui.app.staticTexts["onThisDevice.count"]
        try ui.wait("Downloads and complete cached copies are both listed") {
            count.label == "4 songs play without a connection · 1 downloaded · 3 cached"
        }
        let downloadedRow = ui.app.buttons["onThisDevice.row.\(AppUIFixture.tumHiHo)"]
        let cachedRow = ui.app.buttons["onThisDevice.row.\(AppUIFixture.kesariya)"]
        XCTAssertTrue(downloadedRow.exists && cachedRow.exists)
        XCTAssertEqual(downloadedRow.value as? String, "Downloaded")
        XCTAssertEqual(cachedRow.value as? String, "Cached")
        XCTAssertLessThan(downloadedRow.frame.minY, cachedRow.frame.minY, "Downloads come first")
        XCTAssertLessThan(ui.element("onThisDevice.section.downloaded").frame.minY, ui.element("onThisDevice.section.cached").frame.minY)
        XCTAssertFalse(ui.app.buttons["onThisDevice.row.\(AppUIFixture.shapeOfYou)"].exists, "Incompatible copies are not playable")
        XCTAssertTrue(ui.element("offline.status").exists && !action.exists, "The status shows once")
        ui.capture("on-this-device-offline")
        try ui.reveal(cachedRow)
        try ui.tap(cachedRow)
        try ui.wait("A cached song plays offline", timeout: 20) {
            let mini = ui.app.buttons["miniPlayer.open"]
            return mini.exists && mini.label.contains("Kesariya") && (mini.value as? String)?.hasPrefix("Playing") == true
        }
        XCTAssertEqual(ui.element("cacheFixture.networkRequests").value as? String, "0")
    }

    func testRecentlyPlayedIsCollapsedLastAndExpandsWithPlayResumeAndHistory() throws {
        let ui = makeDriver()
        try launch(ui)
        try ui.tap(ui.app.buttons["tab.recap"].firstMatch)
        let toggle = ui.app.buttons["recap.recent.toggle"]
        try ui.reveal(toggle, maxSwipes: 20)
        XCTAssertEqual(toggle.value as? String, "Collapsed")
        XCTAssertFalse(ui.app.buttons["recap.recent.all"].exists)
        XCTAssertFalse(ui.element("recap.recent.\(AppUIFixture.shapeOfYou)").exists)
        let onRepeat = ui.element("recap.onRepeat.play")
        let dayChart = ui.element("recap.dayChart")
        XCTAssertLessThan(onRepeat.frame.minY, dayChart.frame.minY)
        // Accessibility containers enclose rendered children rather than the stack's layout padding.
        let sectionGap = ui.element("recap.timeline").frame.minY - ui.element("recap.onRepeat").frame.maxY
        XCTAssertGreaterThanOrEqual(sectionGap, 0, "On repeat does not overlap Day by day")
        XCTAssertLessThan(sectionGap, 44, "No other section fits between On repeat and Day by day")
        for id in ["recap.dayChart", "recap.listeningLanguages", "recap.howCounted", "recap.share"] {
            XCTAssertLessThan(ui.element(id).frame.maxY, toggle.frame.minY + 1, "\(id) precedes the last subsection")
        }
        try ui.tap(toggle)
        try ui.wait("Recently played expands") { (toggle.value as? String) == "Expanded" }
        // The seed records recents in fixture order, so the last song is the newest.
        let newestFirst = [AppUIFixture.shapeOfYou, AppUIFixture.blindingLights, AppUIFixture.agarTumSaathHo,
                           AppUIFixture.kesariya, AppUIFixture.tumHiHo]
        let rows = newestFirst.map { ui.element("recap.recent.\($0)") }
        XCTAssertTrue(rows.allSatisfy(\.exists))
        for (newer, older) in zip(rows, rows.dropFirst()) { XCTAssertLessThan(newer.frame.minY, older.frame.minY) }
        let resume = ui.app.buttons["recap.resume.\(AppUIFixture.shapeOfYou)"]
        XCTAssertTrue(resume.exists && resume.label.contains("0:48"), "Resume positions moved with the list")
        try ui.reveal(ui.app.buttons["recap.recent.all"], direction: .down)
        ui.capture("recap-recent")

        let play = rows[1].buttons["track.play.\(AppUIFixture.blindingLights)"]
        try ui.reveal(play)
        try ui.tap(play)
        try ui.wait("A recent row plays its song") {
            let mini = ui.app.buttons["miniPlayer.open"]
            return mini.exists && mini.label.contains("Blinding Lights")
        }
        let seeAll = ui.app.buttons["recap.recent.all"]
        try ui.reveal(seeAll, direction: .down)
        try assertTarget(seeAll, ui: ui)
        try ui.tap(seeAll)
        try ui.wait("See all pushes the full history") { ui.app.navigationBars["Recently Played"].exists }
        try ui.expectLabel(ui.app.staticTexts["library.recents.count"], "5 songs")
        try ui.tap(ui.app.navigationBars["Recently Played"].buttons.firstMatch)
        try ui.wait("Back returns to Recap") { ui.element("recap.screen").exists }
        try ui.reveal(toggle, direction: .down)
        try ui.tap(toggle)
        try ui.wait("Collapsing hides the history actions again") { !ui.app.buttons["recap.recent.all"].exists }
    }

    func testShareCardPreviewShowsTheRenderedPictureInDarkAndLight() throws {
        for appearance in ["dark", "light"] {
            let ui = makeDriver()
            try launch(ui, arguments: ["--recap-long-names-fixture"] + (appearance == "light" ? ["--light"] : []))
            try ui.tap(ui.app.buttons["tab.recap"].firstMatch)
            let preview = ui.app.buttons["recap.share"]
            try ui.reveal(preview, maxSwipes: 16)
            XCTAssertEqual(preview.label, "Share")
            XCTAssertEqual(ui.app.buttons.matching(identifier: "recap.share").count, 1)
            XCTAssertFalse(ui.app.buttons["recap.share.preview"].exists, "There is one page action")
            XCTAssertFalse(ui.app.buttons["recap.share.previewShare"].exists, "System sharing belongs to the preview")
            XCTAssertLessThan(preview.frame.minY, ui.element("recap.onRepeat.play").frame.minY)
            try ui.tap(preview)
            try ui.wait("Share opens the app's preview before any system share sheet") {
                ui.app.navigationBars["Stats Card"].exists && ui.app.buttons["recap.share.done"].exists
            }
            let image = ui.element("recap.share.previewImage")
            try ui.wait("The preview sheet shows the card") { image.exists }
            XCTAssertEqual(image.value as? String, "\(1080.formatted()) by \(1350.formatted()) pixels")
            XCTAssertEqual(image.frame.width / image.frame.height, 1080.0 / 1350.0, accuracy: 0.01)
            XCTAssertTrue(ui.app.buttons["recap.share.previewShare"].exists)
            ui.capture("recap-share-card-\(appearance)")
            try ui.tap(ui.app.buttons["recap.share.done"])
            try ui.wait("Done closes the preview") { !image.exists }
            ui.finish()
        }
    }

    func testOpenFollowingInLibraryLandsOnTheFollowedArtistsOnceFromAnotherTab() throws {
        let ui = makeDriver()
        try launch(ui, arguments: ["--library-organisation-fixture", "--open-following-fixture"])
        let following = ui.element("library.following")
        try ui.wait("The request selects Library and scrolls to Following", timeout: 15) {
            ui.app.buttons["tab.library"].firstMatch.isSelected && following.exists
                && following.frame.minY >= 0 && following.frame.maxY <= self.visibleBottom(ui) + 1e-6
        }
        XCTAssertTrue(ui.app.buttons["library.following.UCfixtureArijitSingh0001"].isHittable)
        XCTAssertFalse(ui.app.buttons["library.createPlaylist"].isHittable, "The root scrolled past its header")
        ui.capture("library-following-scroll")

        // The request is consumed: scrolling back up stays put, and Following starts below the first screen.
        let header = ui.app.buttons["library.createPlaylist"]
        try ui.reveal(header, direction: .down, maxSwipes: 12)
        try ui.reveal(ui.app.buttons["library.likes"], direction: .down)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(header.isHittable, "No second scroll pulls the page back")
        XCTAssertFalse(following.exists && following.frame.maxY <= visibleBottom(ui),
                       "The fixture places Following below the first screen, so the landing was a real scroll")
    }

    // MARK: - Helpers

    /// Top of the tab bar, or of the mini-player when one sits above it.
    private func visibleBottom(_ ui: AppUITestDriver) -> CGFloat {
        var bottom = ui.app.tabBars.firstMatch.frame.minY
        let mini = ui.app.otherElements["miniPlayer.container"]
        if mini.exists { bottom = min(bottom, mini.frame.minY) }
        return bottom
    }

    private func makeDriver() -> AppUITestDriver {
        let ui = AppUITestDriver(testCase: self, prefix: "library-organisation")
        addTeardownBlock { await ui.finish() }
        return ui
    }

    private func launch(_ ui: AppUITestDriver, arguments: [String] = []) throws {
        ui.app.terminate()
        XCUIDevice.shared.orientation = .portrait
        ui.app.launchArguments = ["--uitesting", "--seed-ui", "--skip-welcome", "--reset-ui"] + arguments
            + ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        ui.app.launchEnvironment = ["GANABAJANA_TEST_STORE": ui.storeName]
        ui.app.launch()
        try ui.requireHittable(ui.app.buttons["tab.home"].firstMatch, timeout: 25)
    }

    private func assertTarget(_ element: XCUIElement, ui: AppUITestDriver,
                              file: StaticString = #filePath, line: UInt = #line) throws {
        try ui.requireHittable(element)
        XCTAssertGreaterThanOrEqual(element.frame.width + 1e-6, 44, file: file, line: line)
        XCTAssertGreaterThanOrEqual(element.frame.height + 1e-6, 44, file: file, line: line)
    }
}

import XCTest

/// One home per song: a downloaded song appears only under Downloads, the Cached songs screen and the temporary
/// cache totals exclude it, and a stale cache variant left beside a download is removed at inventory load.
@MainActor
final class GanaBajanaDownloadTierUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testDownloadedSongLeavesTheCachedInventoryAndStorageSplitsTheTiers() throws {
        let ui = makeDriver()
        try launch(ui, arguments: ["--offline-fixture", "--cache-fixture-downloaded"])
        try openStorage(ui)
        let downloadsRow = ui.app.buttons["storage.downloads"]
        try ui.reveal(downloadsRow, maxSwipes: 16)
        try ui.wait("Storage must count the seeded download in its own row") {
            (downloadsRow.value as? String)?.hasPrefix("1 song") == true
        }
        let cachedRow = ui.app.buttons["storage.cachedSongs"]
        try ui.reveal(cachedRow, maxSwipes: 16)
        try ui.wait("The Cached songs row counts the cache tier only") { cachedRow.value as? String == "3 available locally" }
        let usage = ui.element("storage.audio.usage")
        try ui.reveal(usage, direction: .down, maxSwipes: 16)
        try ui.wait("The temporary cache total excludes the downloaded song and its removed stale variant") {
            let text = ui.accessibleText(usage)
            return text.contains("4 songs cached") && text.contains("3 songs verified for local playback")
        }

        try ui.tap(cachedRow)
        try ui.wait("Storage must open the cached-song browser") { ui.app.navigationBars["Cached Songs"].exists }
        let count = ui.app.staticTexts["cachedSongs.count"]
        try ui.wait("Cached songs lists the cache tier only") { count.exists && count.label == "4 songs · 3 available locally" }
        XCTAssertFalse(ui.app.buttons["cachedSongs.play.\(AppUIFixture.tumHiHo)"].exists, "A downloaded song has its home under Downloads")
        try ui.reveal(ui.app.buttons["cachedSongs.play.\(AppUIFixture.kesariya)"])
        try back(from: "Cached Songs", to: "Storage", ui: ui)

        try ui.reveal(downloadsRow, maxSwipes: 16)
        try ui.tap(downloadsRow)
        try ui.wait("Storage must open Downloads") { ui.app.navigationBars["Downloads"].exists }
        let summary = ui.app.staticTexts["downloads.summary"]
        try ui.wait("Downloads lists the song") { summary.exists && summary.label.hasPrefix("1 song on this device") }
        let row = ui.app.buttons["downloads.play.\(AppUIFixture.tumHiHo)"]
        try ui.reveal(row)
        XCTAssertTrue(row.label.contains("Tum Hi Ho"))
        let text = ui.accessibleText(row)
        XCTAssertTrue(text.contains("Downloaded"))
        XCTAssertFalse(text.contains("versions"), "The stale cache variant was removed at inventory load; one file remains")
        XCTAssertTrue(row.isEnabled)
        XCTAssertFalse(ui.app.buttons["downloads.play.\(AppUIFixture.kesariya)"].exists, "Cache-tier songs stay out of Downloads")
        try closeSettings(from: "Downloads", ui: ui)
        try assertNoNetwork(ui)
    }

    func testPlayerCaptionReadsDownloadedAndCachedSongsStillExcludesTheCurrentDownload() throws {
        let ui = makeDriver()
        try launch(ui, arguments: ["--offline-fixture", "--cache-fixture-in-use", "--cache-fixture-downloaded"])
        try ui.openPlayer()
        try ui.expectCurrentTrack(AppUIFixture.tumHiHo)
        try ui.openPlayerMenu()
        let caption = ui.app.staticTexts["player.options.cache.current"]
        try ui.wait("The player caption must state the permanent tier") { caption.exists && caption.label == "Current: Downloaded" }
        let next = ui.app.staticTexts["player.options.cache.next"]
        XCTAssertEqual(next.label, "Next: Cached on this device")
        XCTAssertTrue(ui.app.staticTexts["player.options.cache.notice"].label.contains("Downloads stay on this device"))
        try ui.closeSheet("Song Options")
        try ui.closePlayer()

        try openStorage(ui)
        let cachedRow = ui.app.buttons["storage.cachedSongs"]
        try ui.reveal(cachedRow, maxSwipes: 16)
        try ui.tap(cachedRow)
        try ui.wait("Storage must open the cached-song browser") { ui.app.navigationBars["Cached Songs"].exists }
        let count = ui.app.staticTexts["cachedSongs.count"]
        try ui.wait("The current downloaded song is not a cached-songs row even while in use") {
            count.exists && count.label == "4 songs · 3 available locally"
        }
        XCTAssertFalse(ui.app.buttons["cachedSongs.play.\(AppUIFixture.tumHiHo)"].exists)
        let upcoming = ui.app.buttons["cachedSongs.play.\(AppUIFixture.kesariya)"]
        try ui.reveal(upcoming)
        XCTAssertTrue(ui.accessibleText(upcoming).contains("In use"), "The upcoming cache-tier song keeps its protection")
        try back(from: "Cached Songs", to: "Storage", ui: ui)
        let downloadsRow = ui.app.buttons["storage.downloads"]
        try ui.reveal(downloadsRow, maxSwipes: 16)
        try ui.wait("Storage counts the download") { (downloadsRow.value as? String)?.hasPrefix("1 song") == true }
        try ui.tap(downloadsRow)
        try ui.wait("Storage must open Downloads") { ui.app.navigationBars["Downloads"].exists }
        try ui.reveal(ui.app.buttons["downloads.play.\(AppUIFixture.tumHiHo)"])
        try closeSettings(from: "Downloads", ui: ui)
        try assertNoNetwork(ui)
    }

    func testDownloadingACachedSongMovesItToDownloadsAndRemoveDownloadReturnsIt() throws {
        let ui = makeDriver()
        try launch(ui, arguments: ["--offline-fixture"])
        let count = ui.app.staticTexts["cachedSongs.count"]
        try openStorageCachedSongs(ui)
        try ui.wait("Before the download every fixture song is a cached song") {
            count.exists && count.label == "5 songs · 4 available locally"
        }
        try ui.reveal(ui.app.buttons["cachedSongs.play.\(AppUIFixture.tumHiHo)"])
        try closeSettings(from: "Cached Songs", ui: ui)

        try setDownloaded(true, ui: ui)
        try openStorageCachedSongs(ui)
        try ui.wait("The downloaded song leaves Cached songs") { count.exists && count.label == "4 songs · 3 available locally" }
        XCTAssertFalse(ui.app.buttons["cachedSongs.play.\(AppUIFixture.tumHiHo)"].exists, "Downloads is its only home")
        try closeSettings(from: "Cached Songs", ui: ui)

        try openStorage(ui)
        let downloadsRow = ui.app.buttons["storage.downloads"]
        try ui.reveal(downloadsRow, maxSwipes: 16)
        try ui.wait("The Downloads line carries the downloaded song") { (downloadsRow.value as? String)?.hasPrefix("1 song") == true }
        let cachedRow = ui.app.buttons["storage.cachedSongs"]
        try ui.reveal(cachedRow, maxSwipes: 16)
        try ui.wait("The Cached songs line counts the cache tier only") { cachedRow.value as? String == "3 available locally" }
        let usage = ui.element("storage.audio.usage")
        try ui.reveal(usage, direction: .down, maxSwipes: 16)
        try ui.wait("The temporary cache total excludes the download") {
            let text = ui.accessibleText(usage)
            return text.contains("4 songs cached") && text.contains("3 songs verified for local playback")
        }
        try ui.reveal(downloadsRow, maxSwipes: 16)
        try ui.tap(downloadsRow)
        try ui.wait("Storage must open Downloads") { ui.app.navigationBars["Downloads"].exists }
        try ui.reveal(ui.app.buttons["downloads.play.\(AppUIFixture.tumHiHo)"])
        try closeSettings(from: "Downloads", ui: ui)

        try setDownloaded(false, ui: ui)
        try openStorageCachedSongs(ui)
        try ui.wait("Remove download makes it a cached song again") { count.exists && count.label == "5 songs · 4 available locally" }
        let returned = ui.app.buttons["cachedSongs.play.\(AppUIFixture.tumHiHo)"]
        try ui.reveal(returned)
        XCTAssertTrue(returned.isEnabled, "The demoted file still plays locally")
        try closeSettings(from: "Cached Songs", ui: ui)
        try assertNoNetwork(ui)
    }

    // MARK: - Helpers

    private func openStorageCachedSongs(_ ui: AppUITestDriver) throws {
        try openStorage(ui)
        let link = ui.app.buttons["storage.cachedSongs"]
        try ui.reveal(link, maxSwipes: 16)
        try ui.tap(link)
        try ui.wait("Storage must open the cached-song browser") { ui.app.navigationBars["Cached Songs"].exists }
    }

    private func leaveLibraryPage(_ title: String, ui: AppUITestDriver) throws {
        try ui.tap(ui.app.navigationBars[title].buttons.firstMatch)
        try ui.wait("Back must return to the Library root") { !ui.app.navigationBars[title].exists }
    }

    /// Uses the Liked songs row menu: Download promotes the complete cached copy offline, Remove download demotes it.
    private func setDownloaded(_ downloaded: Bool, ui: AppUITestDriver) throws {
        try ui.tap(ui.app.buttons["tab.library"].firstMatch)
        let likes = ui.app.buttons["library.likes"]
        try ui.reveal(likes)
        try ui.tap(likes)
        try ui.wait("Liked songs must open") { ui.app.navigationBars["Liked Songs"].exists }
        let options = ui.app.buttons["track.options.\(AppUIFixture.tumHiHo)"]
        try ui.reveal(options)
        try ui.tap(options)
        let action = ui.app.buttons[downloaded ? "track.download.\(AppUIFixture.tumHiHo)" : "track.removeDownload.\(AppUIFixture.tumHiHo)"]
        try ui.wait("The song menu offers the tier change") { action.exists }
        try ui.tap(action)
        let glyph = ui.element("track.downloaded.\(AppUIFixture.tumHiHo)")
        try ui.wait("The row glyph follows the tier", timeout: 20) { glyph.exists == downloaded }
        try leaveLibraryPage("Liked Songs", ui: ui)
    }

    private func makeDriver() -> AppUITestDriver {
        let ui = AppUITestDriver(testCase: self, prefix: "download-tier")
        addTeardownBlock { await ui.finish() }
        return ui
    }

    private func launch(_ ui: AppUITestDriver, arguments: [String]) throws {
        ui.app.terminate()
        XCUIDevice.shared.orientation = .portrait
        ui.app.launchArguments = ["--uitesting", "--seed-ui", "--skip-welcome", "--cache-fixture", "--reset-ui"]
            + arguments + ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        ui.app.launchEnvironment = ["GANABAJANA_TEST_STORE": ui.storeName]
        ui.app.launch()
        try ui.requireHittable(ui.app.buttons["tab.home"].firstMatch, timeout: 25)
    }

    private func openStorage(_ ui: AppUITestDriver) throws {
        if ui.app.navigationBars["Storage"].exists { return }
        try ui.tap(ui.app.buttons["tab.home"].firstMatch)
        try ui.reveal(ui.app.buttons["home.settings"], direction: .down, maxSwipes: 16)
        try ui.tap(ui.app.buttons["home.settings"])
        try ui.requireHittable(ui.app.buttons["settings.done"])
        try ui.openSettingsPage(.library)
        let storage = ui.app.buttons["settings.storage"]
        try ui.reveal(storage, maxSwipes: 16)
        try ui.tap(storage)
        try ui.wait("Settings must open Storage") { ui.app.navigationBars["Storage"].exists }
    }

    private func closeSettings(from title: String, ui: AppUITestDriver) throws {
        try back(from: title, to: "Storage", ui: ui)
        try back(from: "Storage", to: SettingsPageID.library.title, ui: ui)
        try ui.tap(ui.app.buttons["settings.done"])
        try ui.wait("Closing Storage must return to the app") { !ui.app.navigationBars[SettingsPageID.library.title].exists }
    }

    private func back(from title: String, to parent: String, ui: AppUITestDriver) throws {
        let bar = ui.app.navigationBars[title]
        let back = bar.buttons[parent].exists ? bar.buttons[parent] : bar.buttons["Back"]
        try ui.tap(back)
        try ui.wait("Back must return to \(parent)") { ui.app.navigationBars[parent].exists }
    }

    private func assertNoNetwork(_ ui: AppUITestDriver) throws {
        let requests = ui.element("cacheFixture.networkRequests")
        try ui.wait("The fixture must expose its network-attempt counter") { requests.exists }
        XCTAssertEqual(requests.value as? String, "0", "Inventory and tier separation must not attempt any network request")
    }
}

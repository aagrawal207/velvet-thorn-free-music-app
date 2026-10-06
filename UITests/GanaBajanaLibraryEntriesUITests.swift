import XCTest

/// Storage owns cache management; Library and the offline banner keep playable music easy to reach.
@MainActor
final class GanaBajanaLibraryEntriesUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testLibraryOmitsCacheManagementAndSettingsStorageOpensTheBrowser() throws {
        let ui = makeDriver()
        try launch(ui, arguments: ["--cache-fixture"])
        try ui.tap(ui.app.buttons["tab.library"].firstMatch)
        let downloads = ui.app.buttons["library.downloads"]
        XCTAssertTrue(downloads.exists)
        XCTAssertTrue(ui.app.buttons["library.likes"].exists)
        XCTAssertFalse(ui.app.buttons["library.cachedSongs"].exists)
        try ui.tap(ui.app.buttons["tab.home"].firstMatch)
        try ui.reveal(ui.app.buttons["home.settings"], direction: .down, maxSwipes: 16)
        try ui.tap(ui.app.buttons["home.settings"])
        try ui.openSettingsPage(.library)
        try ui.reveal(ui.app.buttons["settings.storage"])
        try ui.tap(ui.app.buttons["settings.storage"])
        let cached = ui.app.buttons["storage.cachedSongs"]
        try ui.reveal(cached)
        try assertTarget(cached, ui: ui)
        try ui.tap(cached)
        try ui.wait("Storage must push the cached-song browser") { ui.app.navigationBars["Cached Songs"].exists }
        try ui.wait("The browser lists the fixture inventory") {
            ui.app.staticTexts["cachedSongs.count"].label == "5 songs · 4 available locally"
        }
        XCTAssertTrue(ui.app.buttons["cachedSongs.play"].exists)
        XCTAssertTrue(ui.app.searchFields.firstMatch.exists)
        XCTAssertFalse(ui.element("cachedSongs.offline").exists, "Online, and inside a tab the banner owns the status anyway")
        try ui.tap(ui.app.navigationBars["Cached Songs"].buttons.firstMatch)
        try ui.wait("Back must return to Storage") { cached.exists && !ui.app.navigationBars["Cached Songs"].exists }
    }

    func testSearchStartKeepsRadioPlaylistsAndRecentsWithoutLibraryShortcutCards() throws {
        let ui = makeDriver()
        try launch(ui)
        try ui.selectTab("search")
        let radio = ui.app.buttons["search.radio.open"]
        try ui.requireHittable(radio)
        for id in ["search.library.likes", "search.library.cached", "search.library.open"] {
            XCTAssertFalse(ui.app.buttons[id].exists, "\(id) moved to the Library tab")
        }
        XCTAssertFalse(ui.app.staticTexts["Liked Songs"].exists)
        XCTAssertFalse(ui.app.staticTexts["Cached Songs"].exists)
        XCTAssertFalse(ui.app.staticTexts["Your Library"].exists)
        let playlist = ui.app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "search.library.playlist.")).firstMatch
        XCTAssertTrue(playlist.exists, "Playlists stay as quick openers")
        XCTAssertTrue(playlist.label.contains(AppUIFixture.seededPlaylist))
        XCTAssertLessThan(radio.frame.minY, ui.element("search.library.playlists").frame.minY, "Radio leads the start screen")
        XCTAssertLessThan(playlist.frame.maxY, ui.app.staticTexts["search.recents.empty"].frame.minY)
        let viewport = ui.app.scrollViews["search.content"].frame
        XCTAssertLessThanOrEqual(radio.frame.minY, viewport.minY + 24, "Radio is the first control under the field")
        ui.capture("search-start-without-library-cards")

        try ui.tap(playlist)
        try ui.wait("The playlist shortcut still opens the library playlist") {
            ui.app.navigationBars[AppUIFixture.seededPlaylist].exists
        }
        try ui.tap(ui.app.navigationBars.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "Back", "Search")).firstMatch)
        try ui.requireHittable(ui.app.textFields["search.field"])
    }

    func testOfflineBannerOpensOnThisDeviceAndShowsTheStatusOnce() throws {
        let ui = makeDriver()
        try launch(ui, arguments: ["--cache-fixture", "--offline-fixture"])
        let action = ui.app.buttons["offline.onThisDevice"]
        let status = ui.element("offline.status")
        try ui.requireHittable(action)
        try assertTarget(action, ui: ui)
        XCTAssertEqual(action.label, "You’re offline. Open songs on this device")
        XCTAssertFalse(ui.app.buttons["offline.cachedSongs"].exists, "The banner opens On this device, not Cached songs")
        XCTAssertFalse(status.exists)
        try ui.tap(action)
        try ui.wait("The banner action must open On this device inside the Library tab") {
            ui.app.navigationBars["On This Device"].exists && ui.app.buttons["tab.library"].firstMatch.isSelected
        }
        try ui.wait("The status stays while the redundant action is gone") { status.exists && !action.exists }
        XCTAssertEqual(status.label, "You’re offline")
        XCTAssertEqual(offlineMentionsOutside(status, ui: ui).count, 0,
                       "Exactly one offline status on screen: \(describe(offlineMentions(ui)))")
        try ui.wait("The page lists every playable local song") {
            ui.app.staticTexts["onThisDevice.count"].label.hasPrefix("4 songs play without a connection")
        }
        XCTAssertTrue(ui.app.buttons["onThisDevice.play"].isEnabled)
        XCTAssertTrue(ui.app.buttons["onThisDevice.shuffle"].isEnabled)
        XCTAssertTrue(ui.app.buttons["onThisDevice.row.\(AppUIFixture.tumHiHo)"].exists)
        ui.capture("on-this-device-offline-single-status")

        // Another tab does not show the page, so its banner offers the action again.
        try ui.tap(ui.app.buttons["tab.home"].firstMatch)
        try ui.requireHittable(action)
        XCTAssertFalse(status.exists)
        try ui.tap(ui.app.buttons["tab.library"].firstMatch)
        try ui.wait("Returning to Library shows the still-open page with the plain status") {
            ui.app.navigationBars["On This Device"].exists && status.exists && !action.exists
        }

        try ui.tap(ui.app.navigationBars["On This Device"].buttons.firstMatch)
        try ui.wait("Back restores the banner action on the Library root") {
            action.exists && !status.exists && ui.app.buttons["library.likes"].exists
        }
        XCTAssertFalse(ui.app.buttons["library.cachedSongs"].exists)

        // The banner action from another tab replaces whatever the Library stack showed.
        try ui.tap(ui.app.buttons["library.likes"])
        try ui.wait("Liked songs must be pushed first") { ui.app.navigationBars["Liked Songs"].exists }
        try ui.tap(ui.app.buttons["tab.search"].firstMatch)
        try ui.requireHittable(action)
        try ui.tap(action)
        try ui.wait("The action must land on On this device, not on the earlier Liked songs page") {
            ui.app.navigationBars["On This Device"].exists && !ui.app.navigationBars["Liked Songs"].exists && status.exists
        }
        XCTAssertEqual(ui.element("cacheFixture.networkRequests").value as? String, "0")
    }

    func testSettingsCachedSongsCarriesItsOwnOfflineLineBecauseTheSheetCoversTheBanner() throws {
        let ui = makeDriver()
        try launch(ui, arguments: ["--cache-fixture", "--offline-fixture"])
        try ui.reveal(ui.app.buttons["home.settings"], direction: .down, maxSwipes: 16)
        try ui.tap(ui.app.buttons["home.settings"])
        try ui.requireHittable(ui.app.buttons["settings.done"])
        try ui.openSettingsPage(.library)
        let storage = ui.app.buttons["settings.storage"]
        try ui.reveal(storage, maxSwipes: 16)
        try ui.tap(storage)
        let link = ui.app.buttons["storage.cachedSongs"]
        try ui.reveal(link, maxSwipes: 16)
        try ui.tap(link)
        try ui.wait("Storage must open the cached-song browser") { ui.app.navigationBars["Cached Songs"].exists }
        let line = ui.element("cachedSongs.offline")
        try ui.wait("The sheet's page carries its own offline line") { line.exists }
        XCTAssertEqual(line.label, "You're offline")
        let action = ui.app.buttons["offline.onThisDevice"]
        XCTAssertFalse(action.exists && action.isHittable, "The tab banner sits behind the sheet, not on this screen")
    }

    /// Every element whose label mentions being offline; the banner status is a combined element, not a plain text.
    private func offlineMentions(_ ui: AppUITestDriver) -> XCUIElementQuery {
        ui.app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", "offline"))
    }

    /// XCUITest still lists the children of a combined element, so mentions inside the banner's frame are the banner.
    private func offlineMentionsOutside(_ banner: XCUIElement, ui: AppUITestDriver) -> [XCUIElement] {
        let frame = banner.frame.insetBy(dx: -1, dy: -1)
        return offlineMentions(ui).allElementsBoundByIndex.filter { !frame.contains($0.frame) }
    }

    private func describe(_ query: XCUIElementQuery) -> String {
        query.allElementsBoundByIndex.map { "\($0.elementType.rawValue) '\($0.identifier)' \($0.label) \($0.frame)" }.joined(separator: "; ")
    }

    private func makeDriver() -> AppUITestDriver {
        let ui = AppUITestDriver(testCase: self, prefix: "library-entries")
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
        // Native iPad top tabs are plain buttons; the shared driver's launch waits for a phone tab bar.
        try ui.requireHittable(ui.app.buttons["tab.home"].firstMatch, timeout: 25)
    }

    private func assertTarget(_ element: XCUIElement, ui: AppUITestDriver,
                              file: StaticString = #filePath, line: UInt = #line) throws {
        try ui.requireHittable(element)
        XCTAssertGreaterThanOrEqual(element.frame.width + 1e-6, 44, file: file, line: line)
        XCTAssertGreaterThanOrEqual(element.frame.height + 1e-6, 44, file: file, line: line)
        let window = ui.app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(element.frame.minX, window.minX - 1e-6, file: file, line: line)
        XCTAssertLessThanOrEqual(element.frame.maxX, window.maxX + 1e-6, file: file, line: line)
    }
}

import XCTest

/// Managed downloads over the offline cache fixture: promotion from the player, the Downloads screen,
/// the Library entry, Settings toggles and the queue path that copies a local fixture file.
@MainActor
final class GanaBajanaDownloadsUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testPlayerDownloadPromotesTheCachedSongAndDownloadsScreenListsAndDeletesIt() throws {
        let ui = makeDriver()
        try launch(ui, arguments: ["--offline-fixture", "--cache-fixture-in-use"])
        try ui.openPlayer()
        try ui.expectCurrentTrack(AppUIFixture.tumHiHo)
        try ui.openExpandedPlayerMenu()
        let download = ui.app.buttons["player.options.download"]
        try ui.reveal(download)
        XCTAssertEqual(download.label, "Download")
        let playlist = ui.app.buttons["player.options.playlist"]
        XCTAssertGreaterThan(download.frame.minY, playlist.frame.minY, "Download follows Add to playlist")
        let export = ui.app.buttons["player.options.export"]
        XCTAssertTrue(export.exists)
        XCTAssertEqual(export.label, "Export Audio", "A complete cached copy already allows export")
        try assertMinimumTarget(download, ui: ui)
        try ui.tap(download)
        try ui.wait("A complete cached copy is promoted without any transfer") { download.label == "Downloaded" }
        XCTAssertEqual(download.value as? String, "Remove Download", "The downloaded row offers removal as its secondary line")
        let caption = ui.app.staticTexts["player.options.cache.current"]
        try ui.wait("The player caption must state the permanent tier") { caption.exists && caption.label == "Current: Downloaded" }
        XCTAssertTrue(ui.app.staticTexts["player.options.cache.notice"].label.contains("Downloads stay on this device"))
        try ui.closeSheet("Song Options")
        try ui.closePlayer()
        try assertNoNetwork(ui)

        try openDownloads(ui)
        let summary = ui.app.staticTexts["downloads.summary"]
        try ui.wait("Downloads must list the promoted song") { summary.exists && summary.label.hasPrefix("1 song on this device") }
        let row = ui.app.buttons["downloads.play.\(AppUIFixture.tumHiHo)"]
        try ui.reveal(row)
        XCTAssertTrue(row.label.contains("Tum Hi Ho"))
        XCTAssertTrue(ui.accessibleText(row).contains("Downloaded"))
        try assertMinimumTarget(ui.app.buttons["downloads.play"], ui: ui)
        try assertMinimumTarget(ui.app.buttons["downloads.shuffle"], ui: ui)
        let delete = ui.app.buttons["downloads.delete.\(AppUIFixture.tumHiHo)"]
        try assertMinimumTarget(delete, ui: ui)
        XCTAssertTrue(delete.isEnabled)
        try back(from: "Downloads", to: "Storage", ui: ui)
        let storageRow = ui.app.buttons["storage.downloads"]
        try ui.reveal(storageRow)
        try ui.wait("Storage must count the download outside the cache") {
            (storageRow.value as? String)?.hasPrefix("1 song") == true
        }
        let cachedRow = ui.app.buttons["storage.cachedSongs"]
        try ui.reveal(cachedRow)
        try ui.wait("The downloaded song leaves the cache-tier count; Downloads is its only home") {
            cachedRow.value as? String == "3 available locally"
        }
        try openDownloadsFromStorage(ui)

        // Playing song: deletion keeps the file for the player by demoting it instead of removing bytes.
        try ui.reveal(delete)
        try ui.tap(delete)
        try ui.wait("A song in use is demoted rather than deleted") {
            ui.accessibleText(ui.element("message.text")).contains("stays cached")
        }
        try ui.wait("The Downloads list drops the demoted song") { summary.label.hasPrefix("0 songs on this device") }
        try ui.reveal(ui.element("downloads.empty"))
        XCTAssertTrue(ui.app.staticTexts["Download songs, albums or playlists to keep them on this device."].exists)
        try closeSettings(from: "Downloads", ui: ui)
        try assertNoNetwork(ui)
    }

    func testLibraryRowMenuDownloadCopiesTheFixtureFileAndFilterShowsDownloadedLikes() throws {
        let ui = makeDriver()
        try launch(ui, arguments: [])
        try ui.tap(ui.app.buttons["tab.library"].firstMatch)
        let card = ui.app.buttons["library.downloads"]
        try ui.reveal(card)
        try assertMinimumTarget(card, ui: ui)
        XCTAssertEqual(card.value as? String, "Keep music on this device.")

        try ui.tap(ui.app.buttons["library.likes"])
        try ui.wait("Liked songs must open") { ui.app.navigationBars["Liked Songs"].exists }
        let options = ui.app.buttons["track.options.\(AppUIFixture.blindingLights)"]
        try ui.reveal(options)
        try ui.tap(options)
        let download = ui.app.buttons["track.download.\(AppUIFixture.blindingLights)"]
        try ui.wait("The song menu offers Download") { download.exists }
        let exportHint = ui.app.buttons["track.export.\(AppUIFixture.blindingLights)"]
        XCTAssertTrue(exportHint.exists)
        XCTAssertEqual(exportHint.label, "Download to Export")
        XCTAssertFalse(exportHint.isEnabled)
        try ui.tap(download)
        let glyph = ui.element("track.downloaded.\(AppUIFixture.blindingLights)")
        try ui.wait("The fixture file is published locally and promoted within seconds", timeout: 40) { glyph.exists }
        XCTAssertFalse(ui.element("track.downloaded.\(AppUIFixture.tumHiHo)").exists)

        let filter = ui.app.buttons["library.likes.filter.downloaded"]
        try ui.reveal(filter, direction: .down)
        try assertMinimumTarget(filter, ui: ui)
        XCTAssertFalse(filter.isSelected)
        XCTAssertTrue(ui.app.buttons["library.likes.filter.all"].isSelected)
        try ui.tap(filter)
        try ui.wait("The chip reports its state") { filter.isSelected && !ui.app.buttons["library.likes.filter.all"].isSelected }
        try ui.expectLabel(ui.app.staticTexts["library.likes.count"], "1 of 5 songs")
        XCTAssertTrue(ui.app.buttons["track.play.\(AppUIFixture.blindingLights)"].exists)
        XCTAssertFalse(ui.app.buttons["track.play.\(AppUIFixture.tumHiHo)"].exists)

        try ui.reveal(options)
        try ui.tap(options)
        let export = ui.app.buttons["track.export.\(AppUIFixture.blindingLights)"]
        try ui.wait("The menu offers export once a complete copy exists") { export.exists && export.isEnabled }
        XCTAssertEqual(export.label, "Export Audio")
        try ui.tap(export)
        try ui.wait("The export sheet must prepare a shareable file", timeout: 40) { ui.app.buttons["export.share"].exists }
        let fileName = ui.app.staticTexts["export.fileName"]
        XCTAssertEqual(fileName.label, "The Weeknd - Blinding Lights.m4a")
        XCTAssertTrue(ui.app.staticTexts["export.detail"].label.contains("Song details included"))
        try assertMinimumTarget(ui.app.buttons["export.share"], ui: ui)
        try ui.tap(ui.app.buttons["export.done"])
        try ui.wait("Done closes the export sheet") { !ui.app.buttons["export.share"].exists }
        try ui.tap(ui.app.navigationBars["Liked Songs"].buttons.firstMatch)
        try ui.wait("Back returns to the library") { card.exists }
        try ui.wait("The Library card counts the new download") { (card.value as? String)?.hasPrefix("1 song on this device") == true }
        try ui.tap(card)
        try ui.wait("The Library card opens Downloads") { ui.app.navigationBars["Downloads"].exists }
        try ui.reveal(ui.app.buttons["downloads.play.\(AppUIFixture.blindingLights)"])
    }

    func testDownloadSettingsPersistAndTheLikedSongsToggleConfirmsItsBacklog() throws {
        let ui = makeDriver()
        try launch(ui, arguments: ["--offline-fixture"])
        try ui.openSettings()
        try ui.openSettingsPage(.library)
        try ui.reveal(ui.app.staticTexts["settings.section.library"], maxSwipes: 16)
        try ui.expectSwitch("settings.downloadsCellular", isOn: false)
        try expectLikedDownloads("settings.autoDownloadLiked", value: "Off", ui: ui)
        XCTAssertTrue(ui.app.staticTexts["settings.downloadsCellular.description"].label.contains("Wi-Fi"))
        XCTAssertTrue(ui.app.staticTexts["settings.autoDownloadLiked.description"].label.contains("this device"))
        let cellular = ui.app.switches["settings.downloadsCellular"]
        try ui.reveal(cellular)
        XCTAssertGreaterThanOrEqual(cellular.frame.height + 1e-6, 44)
        try ui.setSwitch("settings.downloadsCellular", to: true)

        try chooseLikedDownloads("settings.autoDownloadLiked", choice: "All Liked", ui: ui)
        let alert = ui.app.alerts["Download Liked Songs?"]
        try ui.wait("Choosing All Liked must confirm the backlog with its count") {
            alert.exists && alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "5 liked songs")).firstMatch.exists
        }
        try tapLikedDownloadsAction("cancel", label: "Cancel", preferenceID: "settings.autoDownloadLiked", ui: ui)
        try expectLikedDownloads("settings.autoDownloadLiked", value: "Off", ui: ui)
        try chooseLikedDownloads("settings.autoDownloadLiked", choice: "All Liked", ui: ui)
        try ui.wait("The confirmation returns") { alert.exists }
        try tapLikedDownloadsAction("confirm", label: "Download", preferenceID: "settings.autoDownloadLiked", ui: ui)
        try expectLikedDownloads("settings.autoDownloadLiked", value: "All Liked", ui: ui)

        try ui.tap(ui.app.buttons["settings.done"])
        try ui.wait("Settings closes") { !ui.app.navigationBars[SettingsPageID.library.title].exists }
        try launch(ui, arguments: ["--offline-fixture"], reset: false)
        try ui.openSettings()
        try ui.expectSwitch("settings.downloadsCellular", isOn: true)
        try expectLikedDownloads("settings.autoDownloadLiked", value: "All Liked", ui: ui)
        // Cached liked songs promote offline; the uncached ones wait for a connection instead of failing.
        let storage = ui.app.buttons["settings.storage"]
        try ui.reveal(storage, maxSwipes: 16)
        try ui.tap(storage)
        try ui.wait("Settings must open Storage") { ui.app.navigationBars["Storage"].exists }
        let downloads = ui.app.buttons["storage.downloads"]
        try ui.reveal(downloads)
        try ui.wait("The backlog promotes every complete cached like", timeout: 30) {
            (downloads.value as? String)?.hasPrefix("3 songs") == true
        }
        try ui.tap(downloads)
        try ui.wait("Storage opens Downloads") { ui.app.navigationBars["Downloads"].exists }
        let waiting = ui.app.staticTexts["downloads.state.\(AppUIFixture.blindingLights)"]
        try ui.reveal(waiting)
        XCTAssertEqual(waiting.label, "Waiting for a connection")
        let cancelAll = ui.app.buttons["downloads.cancelAll"]
        try ui.reveal(cancelAll)
        try assertMinimumTarget(cancelAll, ui: ui)
        try ui.tap(cancelAll)
        try ui.tap(ui.app.alerts.buttons["Cancel Downloads"])
        try ui.wait("Cancel all clears the queue") { !waiting.exists }
        try closeSettings(from: "Downloads", ui: ui)
        try assertNoNetwork(ui)
    }

    func testLikedSongsDownloadConfirmationResetsFiltersAndKeepsPendingLikesVisible() throws {
        let ui = makeDriver()
        try launch(ui, arguments: ["--offline-fixture", "--cache-fixture-downloaded"])
        try ui.tap(ui.app.buttons["tab.library"].firstMatch)
        try ui.tap(ui.app.buttons["library.likes"])
        let downloaded = ui.app.buttons["library.likes.filter.downloaded"]
        try ui.reveal(downloaded)
        try ui.tap(downloaded)
        XCTAssertTrue(downloaded.isSelected)
        try ui.expectLabel(ui.app.staticTexts["library.likes.count"], "1 of 5 songs")

        let toggleID = "library.likes.autoDownload"
        let toggle = ui.app.buttons[toggleID]
        try ui.reveal(toggle, direction: .down)
        XCTAssertTrue(toggle.label.hasPrefix("Download Liked Songs"))
        try chooseLikedDownloads(toggleID, choice: "All Liked", ui: ui)
        let alert = ui.app.alerts["Download Liked Songs?"]
        try ui.wait("Choosing All Liked confirms the remaining backlog") { alert.exists }
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "4 liked songs will be queued")).firstMatch.exists)
        try tapLikedDownloadsAction("cancel", label: "Cancel", preferenceID: toggleID, ui: ui)
        try expectLikedDownloads(toggleID, value: "Off", ui: ui)
        XCTAssertTrue(downloaded.isSelected, "Cancel keeps the existing filter")
        try ui.expectLabel(ui.app.staticTexts["library.likes.count"], "1 of 5 songs")

        try chooseLikedDownloads(toggleID, choice: "All Liked", ui: ui)
        try ui.wait("Confirmation returns") { alert.exists }
        try tapLikedDownloadsAction("confirm", label: "Download", preferenceID: toggleID, ui: ui)
        try expectLikedDownloads(toggleID, value: "All Liked", ui: ui)
        let all = ui.app.buttons["library.likes.filter.all"]
        try ui.reveal(all)
        XCTAssertTrue(all.isSelected, "All Liked keeps only the All and Super Liked chips and resets to All")
        XCTAssertTrue(ui.app.buttons["library.likes.filter.superLiked"].exists)
        XCTAssertFalse(downloaded.exists)
        XCTAssertFalse(ui.app.buttons["library.likes.filter.onDevice"].exists)
        try ui.expectLabel(ui.app.staticTexts["library.likes.count"], "5 songs")
        let status = ui.app.staticTexts["library.likes.downloadStatus"]
        try ui.wait("Cached likes promote while uncached likes stay pending", timeout: 30) {
            status.label == "3 of 5 downloaded · 2 pending · Waiting for a connection"
        }
        ui.capture("liked-songs-auto-download-pending")
        for id in [AppUIFixture.tumHiHo, AppUIFixture.blindingLights] {
            try ui.reveal(ui.app.buttons["track.play.\(id)"])
            XCTAssertTrue(ui.app.buttons["track.play.\(id)"].exists, "Pending likes remain in the list")
        }

        try ui.reveal(toggle, direction: .down)
        try chooseLikedDownloads(toggleID, choice: "Off", ui: ui)
        try ui.reveal(downloaded)
        XCTAssertTrue(downloaded.exists)
        XCTAssertTrue(ui.app.buttons["library.likes.filter.onDevice"].exists)
        XCTAssertFalse(downloaded.isSelected)
        XCTAssertTrue(all.isSelected, "Disabling must not restore a hidden stale filter")
        try ui.expectLabel(ui.app.staticTexts["library.likes.count"], "5 songs")
        try assertNoNetwork(ui)
    }

    func testLikedSongsDownloadPreferencePersistsAndStaysSynchronizedWithSettings() throws {
        let ui = makeDriver()
        try launch(ui, arguments: ["--offline-fixture"])
        try ui.tap(ui.app.buttons["tab.library"].firstMatch)
        try ui.tap(ui.app.buttons["library.likes"])
        try chooseLikedDownloads("library.likes.autoDownload", choice: "All Liked", ui: ui)
        let alert = ui.app.alerts["Download Liked Songs?"]
        try ui.wait("The backlog needs confirmation") { alert.exists }
        try tapLikedDownloadsAction("confirm", label: "Download", preferenceID: "library.likes.autoDownload", ui: ui)
        try expectLikedDownloads("library.likes.autoDownload", value: "All Liked", ui: ui)
        try launch(ui, arguments: ["--offline-fixture"], reset: false)
        try ui.tap(ui.app.buttons["tab.library"].firstMatch)
        try ui.tap(ui.app.buttons["library.likes"])
        try expectLikedDownloads("library.likes.autoDownload", value: "All Liked", ui: ui)
        XCTAssertFalse(ui.app.buttons["library.likes.filter.downloaded"].exists)
        try ui.expectLabel(ui.app.staticTexts["library.likes.count"], "5 songs")

        try ui.openSettings()
        try ui.openSettingsPage(containing: "settings.autoDownloadLiked")
        try expectLikedDownloads("settings.autoDownloadLiked", value: "All Liked", ui: ui)
        try chooseLikedDownloads("settings.autoDownloadLiked", choice: "Off", ui: ui)
        try ui.tap(ui.app.buttons["settings.done"])
        try ui.selectTab("library")
        if !ui.app.navigationBars["Liked Songs"].exists { try ui.tap(ui.app.buttons["library.likes"]) }
        try expectLikedDownloads("library.likes.autoDownload", value: "Off", ui: ui)
        try ui.reveal(ui.app.buttons["library.likes.filter.downloaded"])
        XCTAssertTrue(ui.app.buttons["library.likes.filter.downloaded"].exists)
        XCTAssertTrue(ui.app.buttons["library.likes.filter.onDevice"].exists)
        XCTAssertTrue(ui.app.buttons["library.likes.filter.all"].isSelected)
    }

    // MARK: - Helpers

    private func makeDriver() -> AppUITestDriver {
        let ui = AppUITestDriver(testCase: self, prefix: "downloads")
        addTeardownBlock { await ui.finish() }
        return ui
    }

    private func launch(_ ui: AppUITestDriver, arguments: [String], reset: Bool = true) throws {
        ui.app.terminate()
        XCUIDevice.shared.orientation = .portrait
        ui.app.launchArguments = ["--uitesting", "--seed-ui", "--skip-welcome", "--cache-fixture"] + (reset ? ["--reset-ui"] : [])
            + arguments + ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        ui.app.launchEnvironment = ["GANABAJANA_TEST_STORE": ui.storeName]
        ui.app.launch()
        try ui.requireHittable(ui.app.buttons["tab.home"].firstMatch, timeout: 25)
    }

    /// Taps a Settings switch without asserting its new value; the liked-songs toggle answers with an alert first.
    /// Download Liked Songs is a native menu row: the row button carries the current choice as its value.
    private func expectLikedDownloads(_ id: String, value: String, ui: AppUITestDriver) throws {
        let row = ui.app.buttons[id]
        try ui.reveal(row, maxSwipes: 24)
        try ui.expectValue(row, value)
    }

    private func chooseLikedDownloads(_ id: String, choice: String, ui: AppUITestDriver) throws {
        let row = ui.app.buttons[id]
        try ui.reveal(row, maxSwipes: 24)
        try assertMinimumTarget(row, ui: ui)
        try ui.tap(row)
        let identified = ui.app.buttons["\(id).choice.\(AutoDownloadChoice.key(for: choice))"]
        let native = ui.app.buttons[choice]
        try ui.wait("The Download Liked Songs menu must offer \(choice)") { identified.exists || native.exists }
        let option = identified.exists ? identified : native
        try ui.requireHittable(option)
        try ui.tap(option)
        try ui.wait("Choosing \(choice) must dismiss the native menu") { !option.exists || option.isSelected }
    }

    private enum AutoDownloadChoice {
        static func key(for title: String) -> String {
            switch title {
            case "Super Liked Only": "superLiked"
            case "All Liked": "liked"
            default: "off"
            }
        }
    }

    private func tapLikedDownloadsAction(_ action: String, label: String, preferenceID: String,
                                         ui: AppUITestDriver) throws {
        let alert = ui.app.alerts["Download Liked Songs?"]
        let id = "\(preferenceID).\(action)"
        let predicate = NSPredicate(format: "identifier == %@ AND label == %@", id, label)
        try ui.wait("The exact liked-download action must appear") {
            alert.exists && alert.buttons.matching(predicate).count > 0
        }
        let matches = alert.buttons.matching(predicate).allElementsBoundByIndex
        // The alert exposes a parent button and a virtual child with the same ID and label.
        // Resolve the owning parent explicitly; unrelated duplicate actions must still fail.
        let parents = matches.filter { $0.descendants(matching: .button).matching(predicate).count > 0 }
        let candidates = matches.count == 1 ? matches : parents
        guard candidates.count == 1, let parent = candidates.first,
              matches.count == 1 + parent.descendants(matching: .button).matching(predicate).count else {
            throw AppUIWorkflowFailure(message: "Expected one owning alert button for \(id); found \(matches.count) matches and \(parents.count) parents.")
        }
        try assertMinimumTarget(parent, ui: ui)
        XCTAssertEqual(parent.identifier, id)
        XCTAssertEqual(parent.label, label)
        try ui.tap(parent)
        try ui.wait("The liked-download confirmation must dismiss after \(label)") { !alert.exists }
    }

    private func openDownloads(_ ui: AppUITestDriver) throws {
        try ui.tap(ui.app.buttons["tab.home"].firstMatch)
        try ui.reveal(ui.app.buttons["home.settings"], direction: .down, maxSwipes: 16)
        try ui.tap(ui.app.buttons["home.settings"])
        try ui.requireHittable(ui.app.buttons["settings.done"])
        try ui.openSettingsPage(.library)
        let storage = ui.app.buttons["settings.storage"]
        try ui.reveal(storage, maxSwipes: 16)
        try ui.tap(storage)
        try ui.wait("Settings must open Storage") { ui.app.navigationBars["Storage"].exists }
        try openDownloadsFromStorage(ui)
    }

    private func openDownloadsFromStorage(_ ui: AppUITestDriver) throws {
        let link = ui.app.buttons["storage.downloads"]
        try ui.reveal(link, maxSwipes: 16)
        try assertMinimumTarget(link, ui: ui)
        try ui.tap(link)
        try ui.wait("Storage must open Downloads") { ui.app.navigationBars["Downloads"].exists }
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
        XCTAssertEqual(requests.value as? String, "0", "Downloads of local copies must not attempt remote extraction or media requests")
    }

    private func assertMinimumTarget(_ element: XCUIElement, ui: AppUITestDriver,
                                     file: StaticString = #filePath, line: UInt = #line) throws {
        try ui.requireHittable(element)
        XCTAssertGreaterThanOrEqual(element.frame.width + 1e-6, 44, file: file, line: line)
        XCTAssertGreaterThanOrEqual(element.frame.height + 1e-6, 44, file: file, line: line)
    }
}

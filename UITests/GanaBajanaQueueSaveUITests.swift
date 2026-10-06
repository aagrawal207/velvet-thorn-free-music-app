import UIKit
import XCTest

@MainActor
final class GanaBajanaQueueSaveUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testSaveCapturesRemainingSongsOnceAndPreservesQueueThroughRelaunch() throws {
        let ui = makeDriver()
        try launch(ui)
        try playFixturePlaylist(ui)
        try openPlayer(ui)
        try ui.waitForAdvance(from: 0, by: 1)
        try ui.tap(playerScreen(ui).buttons["player.next"])
        try ui.expectCurrentTrack(AppUIFixture.kesariya)
        try ui.waitForAdvance(from: 0, by: 1)
        try pausePlayback(ui)
        let position = try ui.position()
        let original = fixtureIDs + [AppUIFixture.kesariya]
        try XCTContext.runActivity(named: "Save the captured remaining queue without changing playback") { _ in
            try openQueue(ui)
            let list = queueList(ui)
            try ui.tap(list.buttons["player.repeat"])
            try ui.expectLabel(list.buttons["player.repeat"], "Repeating queue. Repeat song next.")
            // The presenting playlist remains in the accessibility tree behind Queue.
            let songMenu = list.otherElements["queue.row.1.\(AppUIFixture.kesariya)"]
                .buttons["track.options.\(AppUIFixture.kesariya)"]
            try ui.tap(songMenu)
            let addToQueue = ui.app.buttons["Add to Queue"]
            try ui.tap(addToQueue)
            try ui.wait("Adding the duplicate must dismiss its menu") { !addToQueue.exists }
            try assertQueue(original, currentIndex: 1, ui: ui)

            try openSaveSheet(ui, count: 4, firstTitle: "Kesariya")
            try namePlaylist("From Kesariya", ui: ui)
            try savePlaylist(ui)
            try assertQueue(original, currentIndex: 1, ui: ui)
            try assertPlaybackModes(shuffled: false, repeatLabel: "Repeating queue. Repeat song next.", ui: ui)
            try closeQueue(ui)
            try ui.expectCurrentTrack(AppUIFixture.kesariya)
            try ui.expectLabel(playerScreen(ui).buttons["player.playPause"], "Play")
            try ui.expectPosition(position)
        }

        try XCTContext.runActivity(named: "Relaunch and verify the complete queue, modes and paused position") { _ in
            try launch(ui, reset: false)
            try openPlayer(ui)
            try ui.expectCurrentTrack(AppUIFixture.kesariya)
            try ui.expectPosition(position)
            try ui.expectLabel(playerScreen(ui).buttons["player.playPause"], "Play")
            try openQueue(ui)
            try assertQueue(original, currentIndex: 1, ui: ui)
            try assertPlaybackModes(shuffled: false, repeatLabel: "Repeating queue. Repeat song next.", ui: ui)
            try closeQueue(ui)
            try closePlayer(ui)
        }

        try XCTContext.runActivity(named: "Verify one durable playlist with the captured order and deduplicated recordings") { _ in
            try selectTab("library", ui: ui)
            try openPlaylist(named: "From Kesariya", expectedPlaylistCount: 2, ui: ui)
            // Exact ordered equality also excludes the earlier song and a second copy of Kesariya.
            try assertPlaylist(Array(fixtureIDs.dropFirst()), named: "From Kesariya", ui: ui)
        }
    }

    func testBlankNameAndDoneLeaveLibraryAndPlaybackUnchanged() throws {
        let ui = makeDriver()
        try launch(ui)
        try playFixturePlaylist(ui)
        try openPlayer(ui)
        try ui.waitForAdvance(from: 0, by: 1)
        try pausePlayback(ui)
        let position = try ui.position()
        try openQueue(ui)
        try openSaveSheet(ui, count: 5, firstTitle: "Tum Hi Ho")
        try namePlaylist("   ", ui: ui)
        XCTAssertFalse(ui.app.buttons["queue.saveRemaining.save"].isEnabled)
        try assertMinimumTarget(ui.app.buttons["queue.saveRemaining.done"], ui: ui)
        try ui.tap(ui.app.buttons["queue.saveRemaining.done"])
        try waitForQueue(ui)
        try assertQueue(fixtureIDs, currentIndex: 0, ui: ui)
        try closeQueue(ui)
        try ui.expectCurrentTrack(AppUIFixture.tumHiHo)
        try ui.expectPosition(position)
        try ui.expectLabel(ui.app.buttons["player.playPause"], "Play")
        XCTAssertFalse(ui.app.buttons["queue.saveRemaining"].exists, "Saving belongs to Queue, not the main player")
        XCTAssertFalse(ui.app.buttons["player.browse"].exists, "Album browsing belongs to the artist line, not the bottom row")
        for id in ["player.lyrics", "player.airplay", "player.download", "player.queue", "player.trailingTime"] {
            try assertMinimumTarget(ui.app.buttons[id], ui: ui)
        }
        try closePlayer(ui)
        try selectTab("library", ui: ui)
        XCTAssertFalse(ui.playlist(named: "Remaining songs").exists)
        XCTAssertEqual(ui.app.buttons.matching(NSPredicate(format: "identifier MATCHES %@", #"library\.playlist\.[0-9A-Fa-f-]{36}"#)).count, 1)
    }

    func testEmptyQueueDisablesSave() throws {
        let ui = makeDriver()
        try launch(ui)
        try playFixturePlaylist(ui)
        try openPlayer(ui)
        try ui.waitForAdvance(from: 0, by: 1)
        try pausePlayback(ui)
        try openQueue(ui)
        for id in fixtureIDs {
            let song = ui.queueSong(id: id)
            try ui.reveal(song)
            try ui.removeQueueSong(song)
            try ui.wait("The removed recording must leave the queue") { !song.exists }
        }
        try ui.wait("An empty queue must keep a disabled save action") {
            ui.app.staticTexts["An Open Queue"].exists
                && ui.app.buttons["queue.saveRemaining"].exists && !ui.app.buttons["queue.saveRemaining"].isEnabled
        }
        try assertMinimumTarget(ui.app.buttons["queue.saveRemaining"], ui: ui)
    }

    func testFailedSaveCanReloadLibraryAndRetryTheSameDraft() throws {
        let ui = makeDriver()
        try launch(ui, additionalArguments: ["--library-recovery-fixture"])
        try openPlayer(ui)
        try ui.expectCurrentTrack(AppUIFixture.kesariya)
        try ui.expectPosition(32)
        try openQueue(ui)
        try openSaveSheet(ui, count: 2, firstTitle: "Kesariya")
        try namePlaylist("Recovered queue selection", ui: ui)
        let draft = draftContent(ui)
        let save = draft.buttons["queue.saveRemaining.save"]
        try reveal(save, in: draft, navigationTitle: "Save Remaining Songs", ui: ui)
        try ui.tap(save)
        let error = draft.staticTexts["queue.saveRemaining.error"]
        try ui.wait("A rejected library write must leave a visible, retryable draft") {
            error.exists && !error.label.isEmpty && ui.app.textFields["queue.saveRemaining.name"].exists
                && ui.app.buttons["queue.saveRemaining.save"].isEnabled
        }
        XCTAssertTrue(error.label.localizedCaseInsensitiveContains("reload"))
        try ui.expectValue(ui.app.textFields["queue.saveRemaining.name"], "Recovered queue selection")
        let reload = draft.buttons["queue.saveRemaining.reloadLibrary"]
        try reveal(reload, in: draft, navigationTitle: "Save Remaining Songs", ui: ui)
        try assertMinimumTarget(reload, ui: ui)
        try ui.tap(reload)
        try ui.wait("Reloading the repaired library must clear the draft error") { !error.exists }
        try expectPreview(count: 2, firstTitle: "Kesariya", ui: ui)
        try ui.expectValue(ui.app.textFields["queue.saveRemaining.name"], "Recovered queue selection")
        try savePlaylist(ui)
        try assertQueue(Array(fixtureIDs.prefix(3)), currentIndex: 1, ui: ui)
        try closeQueue(ui)
        try ui.expectCurrentTrack(AppUIFixture.kesariya)
        try ui.expectPosition(32)
        try ui.expectLabel(ui.app.buttons["player.playPause"], "Play")
        try closePlayer(ui)
        try selectTab("library", ui: ui)
        try openPlaylist(named: "Recovered queue selection", ui: ui)
        try assertPlaylist([AppUIFixture.kesariya, AppUIFixture.agarTumSaathHo], named: "Recovered queue selection", ui: ui)
    }

    func testOfflineMoreAndQueueShowCompleteCacheAvailability() throws {
        let ui = makeDriver()
        try launch(ui, additionalArguments: cacheArguments)
        try openPlayer(ui)
        try ui.wait("Offline context must be visible inside the full-screen player") {
            ui.app.staticTexts["player.offline"].exists && ui.app.staticTexts["player.offline"].label.hasPrefix("Offline")
        }
        try ui.tap(ui.app.buttons["player.menu"])
        try expectCache("Current: Cached on this device", id: "player.options.cache.current", ui: ui)
        try expectCache("Next: Cached on this device", id: "player.options.cache.next", ui: ui)
        let reload = ui.app.buttons["player.options.reloadAudioQuality"]
        try ui.reveal(reload)
        XCTAssertFalse(reload.isEnabled)
        XCTAssertTrue(ui.accessibleText(reload).contains("Connect to check audio quality"))
        try ui.tap(ui.app.buttons["player.options.toolbarDone"])
        try ui.wait("More must close without reloading audio") { !ui.element("player.options.sheet").exists }
        try openQueue(ui)
        try expectCache("Current: Cached on this device", id: "queue.cache.current", ui: ui)
        try expectCache("Next: Cached on this device", id: "queue.cache.next", ui: ui)
        XCTAssertTrue(ui.app.staticTexts["queue.cache.notice"].label.contains("iOS can remove"))

        try ui.reveal(ui.app.buttons["player.repeat"], direction: .down)
        try ui.tap(ui.app.buttons["player.repeat"])
        try ui.tap(ui.app.buttons["player.repeat"])
        try ui.expectLabel(ui.app.buttons["player.repeat"], "Repeating song. Turn repeat off next.")
        XCTAssertFalse(ui.app.staticTexts["queue.cache.next"].exists, "Repeat one has no different automatic next entry")
        try ui.tap(ui.app.buttons["player.repeat"])
        try expectCache("Next: Cached on this device", id: "queue.cache.next", ui: ui)
        try closeQueue(ui)
        try ui.expectPosition(32)
        try ui.expectLabel(ui.app.buttons["player.playPause"], "Play")
        try closePlayer(ui)
        try ui.expectValue(ui.element("cacheFixture.networkRequests"), "0")
    }

    func testPartialAndIncompatibleAudioNeedAConnection() throws {
        let ui = makeDriver()
        try launch(ui, additionalArguments: cacheArguments)
        try selectTab("library", ui: ui)
        try ui.tap(ui.app.buttons["library.likes"])
        for id in [AppUIFixture.blindingLights, AppUIFixture.shapeOfYou] {
            let menu = ui.app.cells.containing(.button, identifier: "track.play.\(id)")
                .buttons["track.options.\(id)"]
            try ui.reveal(menu)
            try ui.tap(menu)
            try ui.tap(ui.app.buttons["Play Next"])
            try openPlayer(ui)
            try ui.expectCurrentTrack(AppUIFixture.tumHiHo)
            try openQueue(ui)
            try expectCache("Current: Cached on this device", id: "queue.cache.current", ui: ui)
            // Next describes the automatic cached successor, not the unavailable adjacent occurrence.
            try expectCache("Next: Cached on this device", id: "queue.cache.next", ui: ui)
            XCTAssertTrue(queueList(ui).buttons["queue.play.1.\(id)"].exists)
            try closeQueue(ui)
            try ui.expectPosition(32)
            try closePlayer(ui)
            try ui.expectValue(ui.element("cacheFixture.networkRequests"), "0")
        }
    }

    func testSaveControlsRemainReachableAtAccessibilityTextSize() throws {
        let ui = makeDriver()
        try launch(ui, additionalArguments: ["-UIPreferredContentSizeCategoryName",
                                             UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue])
        try playFixturePlaylist(ui)
        try openPlayer(ui)
        try ui.waitForAdvance(from: 0, by: 1)
        try pausePlayback(ui)
        try openQueue(ui)
        try openSaveSheet(ui, count: 5, firstTitle: "Tum Hi Ho")
        let draft = draftContent(ui)
        for control in [draft.textFields["queue.saveRemaining.name"], draft.buttons["queue.saveRemaining.save"]] {
            try reveal(control, in: draft, navigationTitle: "Save Remaining Songs", ui: ui, maxDrags: 16)
            try assertMinimumTarget(control, ui: ui)
        }
        try assertMinimumTarget(ui.app.navigationBars["Save Remaining Songs"].buttons["queue.saveRemaining.done"], ui: ui)
        ui.capture("queue-save-accessibility-text")
        try savePlaylist(ui)
        try assertQueue(fixtureIDs, currentIndex: 0, ui: ui)
    }

    private var fixtureIDs: [String] {
        [AppUIFixture.tumHiHo, AppUIFixture.kesariya, AppUIFixture.agarTumSaathHo,
         AppUIFixture.blindingLights, AppUIFixture.shapeOfYou]
    }

    private var cacheArguments: [String] { ["--cache-fixture", "--offline-fixture", "--cache-fixture-in-use"] }

    private func makeDriver() -> AppUITestDriver {
        let ui = AppUITestDriver(testCase: self, prefix: "queue-save")
        addTeardownBlock { await ui.finish() }
        return ui
    }

    private func launch(_ ui: AppUITestDriver, reset: Bool = true, additionalArguments: [String] = []) throws {
        ui.app.terminate()
        XCUIDevice.shared.orientation = .portrait
        ui.app.launchArguments = ["--uitesting", "--seed-ui", "--skip-welcome"]
            + (reset ? ["--reset-ui"] : []) + additionalArguments
            + ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        ui.app.launchEnvironment = ["GANABAJANA_TEST_STORE": ui.storeName]
        ui.app.launch()
        // iPad's native top tabs are plain buttons rather than a phone tab bar.
        try ui.requireHittable(ui.app.buttons["tab.home"].firstMatch, timeout: 25)
    }

    private func selectTab(_ tab: String, ui: AppUITestDriver) throws {
        try ui.tap(ui.app.buttons["tab.\(tab)"].firstMatch)
    }

    private func playFixturePlaylist(_ ui: AppUITestDriver) throws {
        try selectTab("library", ui: ui)
        try openPlaylist(named: AppUIFixture.seededPlaylist, ui: ui)
        let list = playlistList(ui)
        let play = list.buttons["library.playlist.play"]
        try reveal(play, in: list, navigationTitle: AppUIFixture.seededPlaylist, libraryChrome: true, ui: ui)
        try ui.tap(play)
        try ui.requireHittable(ui.app.buttons["miniPlayer.open"])
    }

    private func playerScreen(_ ui: AppUITestDriver) -> XCUIElement {
        ui.app.otherElements["player.screen"]
    }

    private func openPlayer(_ ui: AppUITestDriver) throws {
        try ui.tap(ui.app.buttons["miniPlayer.open"])
        try ui.requireHittable(playerScreen(ui).buttons["player.close"])
    }

    private func pausePlayback(_ ui: AppUITestDriver) throws {
        let button = playerScreen(ui).buttons["player.playPause"]
        try ui.expectLabel(button, "Pause")
        try ui.tap(button)
        try ui.expectLabel(button, "Play")
    }

    private func playlistList(_ ui: AppUITestDriver) -> XCUIElement {
        let query = ui.app.collectionViews.containing(.staticText, identifier: "library.playlist.count")
        let matches = query.allElementsBoundByAccessibilityElement
        // Bind the list itself so recycling its header during a drag cannot invalidate the locator.
        return matches.count == 1 ? matches[0] : query.element
    }

    private func openPlaylist(named name: String, expectedPlaylistCount: Int? = nil, ui: AppUITestDriver) throws {
        let library = ui.app.scrollViews["library.screen"]
        let playlists = library.buttons.matching(NSPredicate(format: "identifier MATCHES %@",
                                                             #"library\.playlist\.[0-9A-Fa-f-]{36}"#))
        let selected = playlists.matching(NSPredicate(format: "label CONTAINS %@", name))
        try reveal(selected.element, in: library, libraryChrome: true, ui: ui)
        XCTAssertEqual(selected.count, 1, "The library must contain exactly one playlist with the saved name")
        if let expectedPlaylistCount {
            XCTAssertEqual(playlists.count, expectedPlaylistCount, "Saving must retain the original playlist without extra placeholders")
        }
        try ui.tap(selected.element)
        try ui.requireHittable(ui.app.navigationBars[name].buttons["library.playlist.menu"])
        try ui.wait("The named playlist must expose its own song list") { self.playlistList(ui).exists }
    }

    private func queueList(_ ui: AppUITestDriver) -> XCUIElement {
        ui.app.collectionViews["queue.list"]
    }

    private func openQueue(_ ui: AppUITestDriver) throws {
        try ui.tap(playerScreen(ui).buttons["player.queue"])
        try waitForQueue(ui)
    }

    private func waitForQueue(_ ui: AppUITestDriver) throws {
        let done = ui.app.navigationBars["Queue"].buttons["queue.done"]
        try ui.wait("The draft must be dismissed and Queue must be the interactive sheet") {
            !ui.app.textFields["queue.saveRemaining.name"].exists
                && !ui.app.navigationBars["Save Remaining Songs"].exists
                && self.queueList(ui).exists && done.exists && done.isHittable
        }
    }

    private func closeQueue(_ ui: AppUITestDriver) throws {
        try ui.tap(ui.app.navigationBars["Queue"].buttons["queue.done"])
        let close = playerScreen(ui).buttons["player.close"]
        try ui.wait("Queue must dismiss to the full player") {
            !self.queueList(ui).exists && !ui.app.navigationBars["Queue"].exists
                && close.exists && close.isHittable
        }
    }

    private func closePlayer(_ ui: AppUITestDriver) throws {
        try ui.tap(playerScreen(ui).buttons["player.close"])
        // The mini-player can exist behind an outgoing player before dismissal finishes.
        try ui.wait("The full player must dismiss before interacting with the library") {
            !ui.app.buttons["player.close"].exists && !ui.app.otherElements["player.presentation"].exists
        }
    }

    private func openSaveSheet(_ ui: AppUITestDriver, count: Int, firstTitle: String) throws {
        let action = ui.app.navigationBars["Queue"].buttons["queue.saveRemaining"]
        try assertMinimumTarget(action, ui: ui)
        try ui.tap(action)
        let done = ui.app.navigationBars["Save Remaining Songs"].buttons["queue.saveRemaining.done"]
        try ui.wait("Queue must open its interactive naming sheet") {
            ui.app.textFields["queue.saveRemaining.name"].exists && done.exists && done.isHittable
        }
        try expectPreview(count: count, firstTitle: firstTitle, ui: ui)
    }

    private func draftContent(_ ui: AppUITestDriver) -> XCUIElement {
        ui.app.scrollViews.containing(.textField, identifier: "queue.saveRemaining.name").element
    }

    private func expectPreview(count: Int, firstTitle: String, ui: AppUITestDriver) throws {
        let content = draftContent(ui)
        let summary = content.staticTexts["queue.saveRemaining.count"]
        try ui.expectLabel(summary, "\(count) \(count == 1 ? "song" : "songs") selected")
        try ui.expectLabel(content.staticTexts["queue.saveRemaining.firstSong"], "Starts with \(firstTitle)")
    }

    private func namePlaylist(_ name: String, ui: AppUITestDriver) throws {
        let content = draftContent(ui)
        let field = content.textFields["queue.saveRemaining.name"]
        try reveal(field, in: content, navigationTitle: "Save Remaining Songs", ui: ui)
        try ui.tap(field)
        try ui.dismissKeyboardIntroduction()
        try ui.replaceSelectedText(in: field, with: name)
        field.typeText("\n")
        try ui.wait("Submitting the name must dismiss the keyboard") { !ui.app.keyboards.firstMatch.exists }
    }

    private func savePlaylist(_ ui: AppUITestDriver) throws {
        let content = draftContent(ui)
        let save = content.buttons["queue.saveRemaining.save"]
        try reveal(save, in: content, navigationTitle: "Save Remaining Songs", ui: ui)
        try assertMinimumTarget(save, ui: ui)
        try ui.tap(save)
        try waitForQueue(ui)
    }

    private func assertQueue(_ ids: [String], currentIndex: Int, ui: AppUITestDriver) throws {
        try waitForQueue(ui)
        let list = queueList(ui)
        let expected = ids.enumerated().map { "queue.play.\($0.offset).\($0.element)" }
        let query = list.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "queue.play."))
        var rows = try query.allElementsBoundByIndex.map { try $0.snapshot() }
        // State reads do not require hittability; only unmaterialized lazy rows need a bounded list scroll.
        if rows.count < expected.count, let last = expected.last {
            try reveal(query[last], in: list, navigationTitle: "Queue", ui: ui)
            rows = try query.allElementsBoundByIndex.map { try $0.snapshot() }
        }
        XCTAssertEqual(rows.map(\.identifier), expected, "Queue order, occurrence identities and duplicates must be preserved")
        XCTAssertEqual(rows.indices.filter { rows[$0].label.hasPrefix("Current song, ") }, [currentIndex])
    }

    private func assertPlaybackModes(shuffled: Bool, repeatLabel: String, ui: AppUITestDriver) throws {
        let buttons = queueList(ui).buttons
        XCTAssertEqual(buttons["player.shuffle"].isSelected, shuffled)
        try ui.expectLabel(buttons["player.repeat"], repeatLabel)
    }

    private func assertPlaylist(_ ids: [String], named name: String, ui: AppUITestDriver) throws {
        XCTAssertFalse(ui.app.buttons["player.close"].exists)
        XCTAssertFalse(ui.app.navigationBars["Queue"].exists)
        try ui.requireHittable(ui.app.navigationBars[name].buttons["library.playlist.menu"])
        let expected = ids.map { "track.play.\($0)" }
        let list = playlistList(ui)
        let query = list.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "track.play."))
        var rows = try query.allElementsBoundByIndex.map { try $0.snapshot() }
        if rows.count < expected.count, let last = expected.last {
            try reveal(query[last], in: list, navigationTitle: name, libraryChrome: true, ui: ui)
            rows = try query.allElementsBoundByIndex.map { try $0.snapshot() }
        }
        XCTAssertEqual(rows.map(\.identifier), expected, "The saved playlist must contain exactly the captured, deduplicated order")
    }

    private func expectCache(_ text: String, id: String, ui: AppUITestDriver) throws {
        let status = ui.app.staticTexts[id]
        try ui.expectLabel(status, text)
    }

    private func reveal(_ element: XCUIElement, in content: XCUIElement, navigationTitle: String? = nil,
                        libraryChrome: Bool = false, ui: AppUITestDriver, maxDrags: Int = 8) throws {
        let window = ui.app.windows.firstMatch
        var lastContext = ""
        for attempt in 0...maxDrags {
            let bounds = window.frame
            let contentBounds = content.frame.intersection(bounds)
            var top = contentBounds.minY
            var bottom = contentBounds.maxY
            if let navigationTitle {
                top = max(top, ui.app.navigationBars[navigationTitle].frame.maxY)
            }
            if libraryChrome {
                let tabs = ui.app.tabBars.firstMatch
                if tabs.exists, tabs.isHittable {
                    let frame = tabs.frame
                    if frame.intersects(contentBounds) {
                        if frame.midY < contentBounds.midY { top = max(top, frame.maxY) }
                        else { bottom = min(bottom, frame.minY) }
                    }
                }
                // Rows pass beneath the glass, so the capsule's top, not its inset open button's, ends the visible area.
                let mini = ui.app.otherElements["miniPlayer.container"]
                if mini.exists, mini.frame.intersects(contentBounds) { bottom = min(bottom, mini.frame.minY) }
            }
            let keyboard = ui.app.keyboards.firstMatch
            if keyboard.exists, keyboard.frame.intersects(contentBounds) { bottom = min(bottom, keyboard.frame.minY) }
            let viewport = CGRect(x: contentBounds.minX, y: top, width: contentBounds.width, height: max(0, bottom - top))
            guard usableFrame(viewport) else {
                throw AppUIWorkflowFailure(message: "The intended scroll container has no usable viewport: \(viewport)")
            }
            let frame = element.exists ? element.frame : CGRect.null
            lastContext = "frame: \(frame), viewport: \(viewport)"
            if usableFrame(frame), viewport.insetBy(dx: -1e-6, dy: -1e-6).contains(frame), element.isHittable { return }
            guard attempt < maxDrags else { break }

            var movement = -viewport.height * 0.4
            if usableFrame(frame) {
                if frame.minY < viewport.minY { movement = viewport.minY - frame.minY + 8 }
                else if frame.maxY > viewport.maxY { movement = viewport.maxY - frame.maxY - 8 }
            }
            let distance = min(max(abs(movement), 14), viewport.height * 0.4)
            let startY = movement > 0 ? viewport.minY + viewport.height * 0.2 : viewport.maxY - viewport.height * 0.2
            let origin = window.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: viewport.minX + min(12, viewport.width * 0.05) - bounds.minX,
                                                  dy: startY - bounds.minY))
            let end = start.withOffset(CGVector(dx: 0, dy: movement > 0 ? distance : -distance))
            // Edge drags stay inside the supplied container without activating song rows or menus.
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        throw AppUIWorkflowFailure(message: "The intended container could not reveal \(element) after \(maxDrags) drags; \(lastContext)")
    }

    private func usableFrame(_ frame: CGRect) -> Bool {
        !frame.isEmpty && !frame.isNull && [frame.minX, frame.minY, frame.maxX, frame.maxY].allSatisfy(\.isFinite)
    }

    private func assertMinimumTarget(_ element: XCUIElement, ui: AppUITestDriver,
                                     file: StaticString = #filePath, line: UInt = #line) throws {
        try ui.requireHittable(element)
        let frame = element.frame
        XCTAssertGreaterThanOrEqual(frame.width + 1e-6, 44, file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.height + 1e-6, 44, file: file, line: line)
        XCTAssertTrue(ui.app.windows.firstMatch.frame.insetBy(dx: -1e-6, dy: -1e-6).contains(frame), file: file, line: line)
    }
}

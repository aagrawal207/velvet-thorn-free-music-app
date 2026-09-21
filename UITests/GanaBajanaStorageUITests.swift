import Foundation
import XCTest

@MainActor
final class GanaBajanaStorageUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testSettingsDisclosesStorageAndArtworkClearKeepsTheLibrary() throws {
        let ui = makeDriver()
        try ui.launch()
        try openStorage(ui)
        try ui.wait("A fixture resolver must report that audio caching is unavailable") {
            ui.accessibleText(ui.element("storage.audio.usage")).contains("Unavailable")
        }
        let audioClear = ui.app.buttons["storage.clear.audio"]
        XCTAssertTrue(audioClear.exists)
        XCTAssertFalse(audioClear.isEnabled)
        XCTAssertGreaterThanOrEqual(audioClear.frame.height, 44)
        ui.capture("storage-temporary-cache-iphone17pro")

        let artworkClear = ui.app.buttons["storage.clear.artwork"]
        try ui.reveal(artworkClear)
        XCTAssertGreaterThanOrEqual(artworkClear.frame.height, 44)
        try ui.tap(artworkClear)
        try ui.tap(ui.app.alerts.buttons["Cancel"])
        XCTAssertFalse(ui.element("storage.result.artwork").exists)
        try ui.tap(artworkClear)
        try ui.tap(ui.app.alerts.buttons["Clear"])
        try ui.wait("Clearing artwork must show its result") { ui.element("storage.result.artwork").exists }
        XCTAssertFalse(ui.element("storage.error.artwork").exists)

        try ui.reveal(ui.element("storage.library.likes"))
        XCTAssertTrue(ui.accessibleText(ui.element("storage.library.likes")).contains("5"))
        XCTAssertTrue(ui.accessibleText(ui.element("storage.library.playlists")).contains("1"))
        ui.capture("storage-saved-library-iphone17pro")
        try ui.reveal(ui.element("storage.memoryOnly"), maxSwipes: 16)
        XCTAssertTrue(ui.accessibleText(ui.element("storage.memoryOnly")).contains("Memory only"))
        try ui.reveal(ui.element("storage.account"))
        XCTAssertTrue(ui.accessibleText(ui.element("storage.account")).contains("Keychain"))
        XCTAssertTrue(ui.accessibleText(ui.element("storage.account")).contains("Not signed in"))
    }

    func testClearingRecentSearchesPersistsAndKeepsLikesAndPlaylists() throws {
        let ui = makeDriver()
        try ui.launch(additionalArguments: ["--light"])
        try ui.search("Kesariya")
        try ui.waitForSearchResults()
        try openStorage(ui)
        let count = ui.element("storage.searches.count")
        try ui.reveal(count, maxSwipes: 20)
        XCTAssertTrue(ui.accessibleText(count).contains("1"))
        let clear = ui.app.buttons["storage.clear.searches"]
        try ui.reveal(clear)
        try ui.tap(clear)
        try ui.tap(ui.app.alerts.buttons["Cancel"])
        XCTAssertTrue(ui.accessibleText(count).contains("1"))
        try ui.tap(clear)
        try ui.tap(ui.app.alerts.buttons["Clear"])
        try ui.wait("Only the saved search terms should be cleared") {
            ui.element("storage.result.searches").exists && !clear.isEnabled
        }
        ui.capture("storage-recent-searches-cleared-light-iphone17pro")

        try ui.relaunch()
        try openStorage(ui)
        try ui.reveal(ui.element("storage.library.likes"), maxSwipes: 20)
        XCTAssertTrue(ui.accessibleText(ui.element("storage.library.likes")).contains("5"))
        XCTAssertTrue(ui.accessibleText(ui.element("storage.library.playlists")).contains("1"))
        try ui.reveal(count, maxSwipes: 20)
        XCTAssertTrue(ui.accessibleText(count).contains("0"))
        try ui.reveal(clear)
        XCTAssertFalse(clear.isEnabled)
    }

    func testLibraryConflictBannerStaysActionableAndPreservesTheLivePlayer() throws {
        let ui = makeDriver()
        try ui.launch(additionalArguments: ["--library-recovery-fixture"])
        let reload = ui.app.buttons["message.libraryReload"]
        try ui.requireHittable(reload)
        XCTAssertEqual(reload.label, "Reload saved library")
        assertMinimumControlSize(reload)
        let mini = ui.app.buttons["miniPlayer.open"]
        let selection = mini.label
        let state = mini.value as? String
        XCTAssertTrue(selection.contains("Kesariya"))
        XCTAssertTrue(state?.contains("Paused") == true)
        let disappears = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated { !ui.app.buttons["message.libraryReload"].exists }
        }, object: nil)
        disappears.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [disappears], timeout: 4.5), .completed)
        ui.capture("library-conflict-reload-banner-iphone17pro")

        try ui.tap(reload)
        try ui.wait("A recovered library must retire its conflict action") { !reload.exists }
        XCTAssertEqual(mini.label, selection)
        XCTAssertEqual(mini.value as? String, state)
        try ui.assertMiniPlayerAboveTabs()
        try ui.openPlayer()
        try ui.expectCurrentTrack(AppUIFixture.kesariya)
        try ui.expectPosition(32)
        try ui.expectLabel(ui.app.buttons["player.playPause"], "Play")
        try ui.openPlayerSheet("queue", title: "Queue")
        try ui.wait("Recovery must keep the live three-song queue and its second selection") {
            ui.app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "3 songs · 2 of 3")).firstMatch.exists
        }
    }

    func testDismissedLibraryConflictReloadsFromStorageAndPersistsExternalEdits() throws {
        let ui = makeDriver()
        try ui.launch(additionalArguments: ["--library-recovery-fixture"])
        try dismissLibraryMessageFromHome(ui)
        try openStorage(ui)
        let reload = ui.app.buttons["storage.library.reload"]
        try ui.reveal(reload, maxSwipes: 20)
        assertMinimumControlSize(reload)
        XCTAssertTrue(ui.element("storage.library.error").exists)
        try ui.tap(reload)
        try ui.wait("Successful recovery must clear the persistent storage error") {
            !reload.exists && !ui.element("storage.library.error").exists
        }
        try ui.reveal(ui.element("storage.library.likes"), direction: .down)
        XCTAssertTrue(ui.accessibleText(ui.element("storage.library.likes")).contains("4"))
        XCTAssertTrue(ui.accessibleText(ui.element("storage.library.playlists")).contains("1"))

        try ui.relaunch()
        XCTAssertFalse(ui.app.buttons["message.libraryReload"].exists)
        try ui.openPlayer()
        try ui.expectCurrentTrack(AppUIFixture.kesariya)
        try ui.expectPosition(32)
        try ui.expectLabel(ui.app.buttons["player.playPause"], "Play")
        try ui.closePlayer()
        try ui.openSettings()
        XCTAssertEqual(ui.app.sliders["settings.crossfade"].value as? String, "7 s")
        try ui.reveal(ui.app.buttons["settings.storage"])
        try ui.tap(ui.app.buttons["settings.storage"])
        try ui.reveal(ui.element("storage.library.likes"), maxSwipes: 20)
        XCTAssertTrue(ui.accessibleText(ui.element("storage.library.likes")).contains("4"))
        XCTAssertFalse(ui.element("storage.library.error").exists)
        ui.capture("library-recovered-external-edits-iphone17pro")
    }

    func testFutureLibraryReloadSurfacesFailureAndKeepsRecoveryAndPlaybackAvailable() throws {
        let ui = makeDriver()
        try ui.launch(additionalArguments: ["--library-recovery-fixture", "--library-recovery-future"])
        let mini = ui.app.buttons["miniPlayer.open"]
        let selection = mini.label
        let state = mini.value as? String
        try ui.tap(ui.app.buttons["message.libraryReload"])
        try ui.wait("An unsupported library must report a reload failure") {
            ui.element("message.text").label.contains("couldn’t reload")
        }
        XCTAssertTrue(ui.app.buttons["message.libraryReload"].exists)
        XCTAssertEqual(mini.label, selection)
        XCTAssertEqual(mini.value as? String, state)
        try dismissLibraryMessageFromHome(ui)
        try openStorage(ui)
        let reload = ui.app.buttons["storage.library.reload"]
        try ui.reveal(reload, maxSwipes: 20)
        XCTAssertTrue(ui.accessibleText(ui.element("storage.library.error")).contains("couldn’t reload"))
        try ui.tap(reload)
        try ui.reveal(reload)
        XCTAssertTrue(ui.element("storage.library.error").exists)
        ui.capture("library-future-version-reload-failure-iphone17pro")
    }

    private func dismissLibraryMessageFromHome(_ ui: AppUITestDriver) throws {
        let dismiss = ui.app.buttons["message.dismiss"]
        try ui.requireHittable(dismiss)
        assertMinimumControlSize(dismiss)
        try ui.tap(dismiss)
        XCTAssertFalse(ui.app.navigationBars["Settings"].exists,
                       "Dismiss must not activate the covered Home Settings button")
        try ui.wait("Dismissing the library message must remove its controls and leave Home visible") {
            ui.app.buttons.matching(identifier: "message.dismiss").count == 0
                && ui.app.buttons.matching(identifier: "message.libraryReload").count == 0
                && !ui.app.navigationBars["Settings"].exists
        }
        try ui.requireHittable(ui.app.tabBars.buttons["Home"])
    }

    private func assertMinimumControlSize(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        // AX frame conversion can report 43.999999999999986 for 44 points; allow only sub-pixel arithmetic noise.
        let minimum: CGFloat = 44 - 1e-6
        let frame = element.frame
        XCTAssertGreaterThanOrEqual(frame.width, minimum, file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.height, minimum, file: file, line: line)
    }

    private func makeDriver() -> AppUITestDriver {
        let ui = AppUITestDriver(testCase: self, prefix: "storage")
        addTeardownBlock { await ui.finish() }
        return ui
    }

    private func openStorage(_ ui: AppUITestDriver) throws {
        try ui.openSettings()
        let storage = ui.app.buttons["settings.storage"]
        try ui.reveal(storage, maxSwipes: 12)
        try ui.tap(storage)
        try ui.wait("Settings must open its Storage page") { ui.app.navigationBars["Storage"].exists }
    }
}

import UIKit
import XCTest

/// Settings as a short root list of six pages (R14 item 18), grouped Playback, Following to Library and the
/// removed Right time label row.
@MainActor
final class GanaBajanaSettingsPagesUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testRootListShowsTheStatusSummaryAndSixPageRows() throws {
        let ui = makeDriver()
        try launch(ui)
        try openSettings(ui)
        let account = ui.element("settings.summary.account")
        let status = ui.element("settings.summary.icloud")
        try ui.wait("The summary shows the account and iCloud status") { account.exists && status.exists }
        XCTAssertTrue(ui.accessibleText(account).contains("Not signed in"), ui.accessibleText(account))
        XCTAssertEqual(status.value as? String, "Waiting to sync with iCloud")
        XCTAssertGreaterThanOrEqual(account.frame.height + 1e-6, 44)
        var previousMaxY = status.frame.maxY
        for page in SettingsPageID.allCases {
            let row = ui.app.buttons[page.rowID]
            try ui.reveal(row)
            XCTAssertEqual(row.label, "\(page.title), \(page.summary)")
            XCTAssertGreaterThanOrEqual(row.frame.height + 1e-6, 44, page.rowID)
            XCTAssertGreaterThan(row.frame.minY, previousMaxY - 1, "\(page.rowID) follows the summary and earlier pages")
            previousMaxY = row.frame.maxY
        }
        XCTAssertEqual(ui.app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "settings.page.")).count, 6)
        for id in ["settings.crossfade", "settings.icloud", "settings.appearance", "settings.following", "settings.trailingTime"] {
            XCTAssertFalse(ui.element(id).exists, "\(id) lives on a page, not the root list")
        }
        Thread.sleep(forTimeInterval: 1)
        ui.capture("settings-pages-root")
    }

    func testEachPageOpensWithItsSectionHeaderAndDoneClosesFromAnyPage() throws {
        let ui = makeDriver()
        try launch(ui)
        try openSettings(ui)
        for page in SettingsPageID.allCases {
            try ui.openSettingsPage(page)
            let header = ui.element(page.sectionID)
            XCTAssertTrue(header.exists, "\(page.title) carries \(page.sectionID)")
            XCTAssertTrue(ui.app.navigationBars[page.title].exists)
            XCTAssertFalse(ui.element("settings.trailingTime").exists, "\(page.title) has no Right time label row")
            try ui.requireHittable(ui.app.buttons["settings.done"])
            XCTAssertEqual(ui.app.buttons.matching(identifier: "settings.done").count, 1)
            try ui.tap(ui.app.buttons["settings.done"])
            try ui.wait("Done closes the whole sheet from \(page.title)") {
                !ui.app.navigationBars[page.title].exists && !ui.app.buttons["settings.done"].exists
            }
            try ui.requireHittable(ui.app.buttons["home.settings"])
            if page != SettingsPageID.allCases.last { try openSettings(ui) }
        }
    }

    func testPageHelpersKeepTheCurrentPageAndReturnFromNestedStorage() throws {
        let ui = makeDriver()
        try launch(ui, arguments: ["--cache-fixture"])
        try openSettings(ui)
        try ui.openSettingsPage(.library)
        let storage = ui.app.buttons["settings.storage"]
        try ui.reveal(storage)
        XCTAssertEqual(storage.label, "Storage & Cached Songs", "The Settings entry names its cache browser")
        let frame = storage.frame
        try ui.openSettingsPage(.library)
        try ui.openSettingsPageIfNeeded(for: "settings.storage")
        XCTAssertEqual(storage.frame.minY, frame.minY, accuracy: 1, "Reusing a page preserves its scroll position")
        try ui.tap(storage)
        let cached = ui.app.buttons["storage.cachedSongs"]
        try ui.reveal(cached)
        try ui.tap(cached)
        try ui.wait("Storage opens the cached-song browser") { ui.app.navigationBars["Cached Songs"].exists }
        try ui.requireHittable(ui.element("cachedSongs.screen"))

        try ui.openSettingsPage(.playback)
        try ui.requireHittable(ui.app.buttons["settings.audioQuality"])
        try ui.openSettingsPage(.playback)
        try ui.tap(ui.settingsNavigationBar.buttons.firstMatch)
        try ui.wait("One Back returns to the root without duplicate pages") {
            ui.app.navigationBars["Settings"].exists && ui.app.buttons[SettingsPageID.playback.rowID].isHittable
        }
        try ui.returnToSettingsRoot()
        XCTAssertTrue(ui.app.buttons["settings.done"].isHittable, "Returning to the root must not dismiss Settings")
    }

    func testPlaybackPageGroupsItsRowsByTopic() throws {
        let ui = makeDriver()
        try launch(ui)
        try openSettings(ui)
        try ui.openSettingsPage(.playback)
        let groups: [(header: String, title: String, rows: [String])] = [
            ("settings.section.playback", "Sound", ["settings.audioQuality", "settings.equalizer", "settings.normalize"]),
            ("settings.group.playback.transitions", "Transitions", ["settings.transitions", "settings.gapless", "settings.autoplay"]),
            ("settings.group.playback.player", "Player", ["settings.playerSwipeUp", "settings.sponsorBlock"]),
            ("settings.group.playback.shuffle", "Shuffle", ["settings.shuffleStyle"]),
        ]
        Thread.sleep(forTimeInterval: 1)
        ui.capture("settings-pages-playback")
        // Frames are read together for each adjacent pair, so scrolling between pairs cannot skew the order.
        var previous: XCUIElement?
        for group in groups {
            let header = ui.app.staticTexts[group.header]
            try ui.reveal(header)
            XCTAssertEqual(header.label.lowercased(), group.title.lowercased())
            for element in [header] + group.rows.map({ ui.element($0) }) {
                try ui.reveal(element)
                if element.identifier != group.header { XCTAssertGreaterThanOrEqual(element.frame.height + 1e-6, 44, element.identifier) }
                if let previous, previous.exists, usable(previous.frame) {
                    XCTAssertGreaterThan(element.frame.minY, previous.frame.maxY - 1,
                                         "\(element.identifier) follows \(previous.identifier) under \(group.title)")
                }
                previous = element
            }
        }
        XCTAssertFalse(ui.element("settings.trailingTime").exists)
        ui.capture("settings-pages-playback-end")
    }

    func testFollowingRowLandsOnTheFollowedArtistsInLibrary() throws {
        let ui = makeDriver()
        try launch(ui, arguments: ["--library-organisation-fixture"])
        try openSettings(ui)
        try ui.openSettingsPage(.discovery)
        let row = ui.app.buttons["settings.following"]
        try ui.reveal(row)
        XCTAssertTrue(row.label.contains("Following"))
        try ui.expectValue(row, "3 artists")
        XCTAssertGreaterThanOrEqual(row.frame.height + 1e-6, 44)
        try ui.tap(row)
        let following = ui.element("library.following")
        try ui.wait("Following closes Settings and lands on Library's followed artists", timeout: 15) {
            !ui.app.buttons["settings.done"].exists && following.exists && following.frame.minY >= 0
                && following.frame.maxY <= self.visibleBottom(ui) + 1e-6
        }
        XCTAssertTrue(libraryTabIsSelected(ui))
        XCTAssertTrue(ui.app.buttons["library.following.UCfixtureArijitSingh0001"].isHittable)
        ui.capture("settings-pages-following-in-library")
    }

    // MARK: - Helpers

    private func makeDriver() -> AppUITestDriver {
        let ui = AppUITestDriver(testCase: self, prefix: "settings-pages")
        addTeardownBlock { await ui.finish() }
        return ui
    }

    private func launch(_ ui: AppUITestDriver, arguments: [String] = []) throws {
        if UIDevice.current.userInterfaceIdiom != .pad {
            try ui.launch(additionalArguments: arguments)
            return
        }
        // iPad exposes top tab buttons instead of the shared driver's bottom-tab readiness target.
        XCUIDevice.shared.orientation = .portrait
        ui.app.launchArguments = ["--uitesting", "--seed-ui", "--skip-welcome", "--reset-ui"] + arguments
            + ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        ui.app.launchEnvironment = ["GANABAJANA_TEST_STORE": ui.storeName]
        ui.app.launch()
        try ui.requireHittable(ui.app.buttons["home.settings"], timeout: 25)
    }

    private func openSettings(_ ui: AppUITestDriver) throws {
        try ui.tap(ui.app.buttons["home.settings"])
        try ui.requireHittable(ui.app.buttons["settings.done"])
        try ui.wait("Settings opens on its root list") { ui.app.navigationBars["Settings"].exists }
    }

    private func libraryTabIsSelected(_ ui: AppUITestDriver) -> Bool {
        let top = ui.app.buttons["tab.library"].firstMatch
        if top.exists { return top.isSelected }
        // Resolve descendants only after the container exists; iPad has no TabBar accessibility node.
        let tabs = ui.app.tabBars.firstMatch
        guard tabs.exists else { return false }
        let bottom = tabs.buttons["Library"]
        return bottom.exists && bottom.isSelected
    }

    /// Top of the tab bar, or of the mini-player when one sits above it; the window bottom on iPad's top tabs.
    private func visibleBottom(_ ui: AppUITestDriver) -> CGFloat {
        let tabs = ui.app.tabBars.firstMatch
        var bottom = tabs.exists && tabs.frame.minY > ui.app.windows.firstMatch.frame.midY
            ? tabs.frame.minY : ui.app.windows.firstMatch.frame.maxY
        let mini = ui.app.otherElements["miniPlayer.container"]
        if mini.exists { bottom = min(bottom, mini.frame.minY) }
        return bottom
    }

    private func usable(_ frame: CGRect) -> Bool {
        !frame.isEmpty && !frame.isNull && [frame.minX, frame.minY, frame.maxX, frame.maxY].allSatisfy(\.isFinite)
    }
}

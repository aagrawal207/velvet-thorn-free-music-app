import Foundation
import XCTest

@MainActor
final class GanaBajanaHomeCustomizationUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testRecentlyPlayedIsFirstAndVisibilitySurvivesRelaunch() throws {
        let ui = makeDriver()
        try ui.launch()
        try expectFirstHomeSection("recentlyPlayed", in: ui)
        ui.capture("home-recently-played-first-iphone17pro")
        try openCustomization(ui)
        try ui.setSwitch("home.customization.show.recentlyPlayed", to: false)
        try returnHome(ui)
        XCTAssertFalse(ui.element("home.group.recentlyPlayed").exists)
        try ui.relaunch()
        XCTAssertFalse(ui.element("home.group.recentlyPlayed").exists)
        try openCustomization(ui)
        try ui.expectSwitch("home.customization.show.recentlyPlayed", isOn: false)
        try ui.setSwitch("home.customization.show.recentlyPlayed", to: true)
        try returnHome(ui)
        try expectFirstHomeSection("recentlyPlayed", in: ui)
    }

    func testNativeReorderPersistsAndResetRestoresTheDefaultHome() throws {
        let ui = makeDriver()
        try ui.launch()
        try openCustomization(ui)
        let discovery = ui.app.switches["home.customization.show.discovery"]
        let recent = ui.app.switches["home.customization.show.recentlyPlayed"]
        try ui.reveal(discovery)
        try ui.moveQueueSong(discovery, before: recent)
        try ui.wait("Dragging a section's native handle must change its saved order") {
            discovery.frame.minY < recent.frame.minY
        }
        ui.capture("home-customization-native-order-iphone17pro")
        try returnHome(ui)
        try expectFirstHomeSection("discovery", in: ui)
        try ui.relaunch()
        try expectFirstHomeSection("discovery", in: ui)
        try openCustomization(ui)
        try ui.requireHittable(discovery)
        XCTAssertLessThan(discovery.frame.minY, recent.frame.minY)
        let reset = ui.app.buttons["home.customization.reset"]
        try ui.reveal(reset)
        try ui.tap(reset)
        try ui.wait("Reset must restore the default layout") { reset.exists && !reset.isEnabled }
        try returnHome(ui)
        try expectFirstHomeSection("recentlyPlayed", in: ui)
    }

    func testAllHiddenHomeKeepsSettingsCustomizationAndSavedMusicAvailable() throws {
        let ui = makeDriver()
        try ui.launch()
        try openCustomization(ui)
        for section in ["recentlyPlayed", "madeForYou", "newReleases", "becauseYouLike", "charts", "discovery"] {
            try ui.setSwitch("home.customization.show.\(section)", to: false)
        }
        try returnHome(ui)
        let emptyState = ui.element("home.empty.customized")
        try ui.reveal(emptyState)
        XCTAssertTrue(emptyState.exists)
        XCTAssertFalse(ui.app.buttons["home.customize.empty"].exists)
        XCTAssertFalse(ui.app.buttons["home.customize"].exists)
        let settings = ui.app.buttons["home.settings"]
        try ui.requireHittable(settings)
        XCTAssertGreaterThanOrEqual(settings.frame.height + 1e-6, 44)
        XCTAssertFalse(homeSections(in: ui).firstMatch.exists)
        ui.capture("home-all-sections-hidden-iphone17pro")
        try ui.relaunch()
        try ui.wait("The saved all-hidden layout must survive relaunch") { emptyState.exists && !self.homeSections(in: ui).firstMatch.exists }
        try openCustomization(ui)
        try ui.expectSwitch("home.customization.show.recentlyPlayed", isOn: false)
        try ui.setSwitch("home.customization.show.recentlyPlayed", to: true)
        try returnHome(ui)
        try expectFirstHomeSection("recentlyPlayed", in: ui)
        XCTAssertFalse(ui.element("home.group.charts").exists)
        XCTAssertFalse(ui.element("home.group.discovery").exists)
        try ui.selectTab("library")
        try ui.tap(ui.app.buttons["library.likes"])
        try ui.reveal(ui.app.staticTexts["5 songs"])
        try ui.selectTab("recap")
        try ui.expectMetric("recap.totalListening", number: 89, description: "minutes listened")
    }

    func testCompactEmptyPlaylistCardKeepsItsCreateActionReachableAboveTheMiniPlayer() throws {
        let ui = makeDriver()
        try ui.launch(additionalArguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"])
        try ui.playSeededPlaylist()
        try ui.openPlayer()
        try ui.waitForAdvance(from: 0, by: 1)
        try ui.pause()
        try ui.closePlayer()
        try ui.tap(ui.app.buttons["library.playlist.menu"])
        try ui.tap(ui.app.buttons["library.playlist.delete"])
        try ui.confirmPlaylistDeletion()
        try ui.wait("Deleting the last playlist must expose the empty Library card") { ui.element("library.playlists.empty").exists }
        let card = ui.element("library.playlists.empty")
        let create = card.buttons["library.playlists.createFirst"]
        try ui.reveal(create)
        XCTAssertTrue(card.staticTexts["A place for your next mix"].exists)
        XCTAssertEqual(ui.app.buttons.matching(identifier: "library.playlists.createFirst").count, 1)
        XCTAssertLessThanOrEqual(card.frame.height, 200, "The empty playlist prompt should remain a compact card at the default text size")
        XCTAssertGreaterThanOrEqual(create.frame.height, 44)
        XCTAssertLessThanOrEqual(create.frame.maxY, ui.app.buttons["miniPlayer.open"].frame.minY)
        XCTAssertTrue(ui.app.buttons["miniPlayer.open"].label.contains("Tum Hi Ho"))
        ui.capture("library-compact-empty-playlist-card-above-mini-player")

        try ui.tap(create)
        let name = ui.app.textFields["library.playlist.name"]
        try ui.requireHittable(name)
        try ui.dismissKeyboardIntroduction()
        name.typeText("A new mix")
        try ui.tap(ui.app.buttons["library.playlist.save"])
        try ui.wait("The compact card's action must save a playlist and replace the empty state") {
            !name.exists && !card.exists && ui.playlist(named: "A new mix").exists
        }
        try ui.relaunch()
        try ui.selectTab("library")
        try ui.reveal(ui.playlist(named: "A new mix"))
        XCTAssertFalse(card.exists)
    }

    private func openCustomization(_ ui: AppUITestDriver) throws {
        try ui.openHomeCustomization()
    }

    private func returnHome(_ ui: AppUITestDriver) throws {
        try ui.closeHomeCustomization()
        XCTAssertFalse(ui.app.buttons["home.customize"].exists)
    }

    private func homeSections(in ui: AppUITestDriver) -> XCUIElementQuery {
        ui.app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "home.group."))
    }

    private func expectFirstHomeSection(_ section: String, in ui: AppUITestDriver) throws {
        let sections = homeSections(in: ui)
        try ui.wait("\(section) must be the first displayed Home section") {
            sections.firstMatch.exists && sections.firstMatch.identifier == "home.group.\(section)"
        }
        XCTAssertLessThan(sections.firstMatch.frame.minY, ui.app.windows.firstMatch.frame.midY)
    }

    private func makeDriver() -> AppUITestDriver {
        let ui = AppUITestDriver(testCase: self, prefix: "home-customization")
        addTeardownBlock { await ui.finish() }
        return ui
    }
}

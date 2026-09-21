import XCTest

@MainActor
final class GanaBajanaAccentUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testMintSelectionUpdatesSettingsAndSurvivesBackNavigationAndRelaunch() throws {
        let ui = makeDriver()
        try ui.launch()
        try ui.openSettings()
        try openAccentPicker(ui, expectedColor: "Coral")
        for (id, title) in [("coral", "Coral"), ("mint", "Mint"), ("ocean", "Ocean"), ("violet", "Violet"),
                            ("amber", "Amber"), ("rose", "Rose"), ("teal", "Teal")] {
            let choice = try accentChoice(id, in: ui)
            XCTAssertEqual(choice.state.label, title)
            XCTAssertEqual(choice.state.isSelected, id == "coral")
            try ui.expectValue(choice.state, id == "coral" ? "Selected" : "Not selected")
        }
        try selectAccent("mint", in: ui)
        let coral = try accentChoice("coral", in: ui)
        try ui.expectValue(coral.state, "Not selected")
        XCTAssertFalse(coral.state.isSelected)
        ui.capture("accent-mint-selected-dark-iphone17pro")

        try returnToSettings(ui, expectedColor: "Mint")
        ui.capture("accent-mint-settings-dark-iphone17pro")
        try openAccentPicker(ui, expectedColor: "Mint")
        try expectSelected("mint", in: ui)
        try returnToSettings(ui, expectedColor: "Mint")
        try ui.tap(ui.app.buttons["settings.done"])
        try ui.requireHittable(ui.app.buttons["home.settings"])
        ui.capture("accent-mint-home-dark-iphone17pro")

        try ui.relaunch()
        try ui.openSettings()
        try openAccentPicker(ui, expectedColor: "Mint")
        try expectSelected("mint", in: ui)
        ui.capture("accent-mint-restored-dark-iphone17pro")
    }

    func testMintKeepsItsSelectionAcrossAppearanceAndPresentedScreensAndCanReturnToCoral() throws {
        let ui = makeDriver()
        try ui.launch()
        try ui.openSettings()
        try ui.setAppearance("Light")
        try ui.reveal(ui.element("settings.appIcon"), direction: .down)
        let appIcon = ui.accessibleText(ui.element("settings.appIcon"))
        try openAccentPicker(ui, expectedColor: "Coral")
        try selectAccent("mint", in: ui)
        ui.capture("accent-mint-selected-light-iphone17pro")
        try returnToSettings(ui, expectedColor: "Mint")
        try ui.reveal(ui.element("settings.appIcon"))
        XCTAssertEqual(ui.accessibleText(ui.element("settings.appIcon")), appIcon)

        let support = ui.app.buttons["settings.tipJar"]
        try ui.reveal(support, maxSwipes: 24)
        try ui.tap(support)
        try ui.wait("Support development must open in the Settings navigation stack") {
            ui.app.navigationBars["Support development"].exists
        }
        ui.capture("accent-mint-support-light-iphone17pro")
        try ui.tap(ui.app.navigationBars["Support development"].buttons["Settings"])
        try ui.tap(ui.app.buttons["settings.done"])
        try ui.playSeededPlaylist()
        try ui.openPlayer()
        try ui.pause()
        ui.capture("accent-mint-player-light-iphone17pro")
        try ui.closePlayer()

        try ui.openSettings()
        try ui.setAppearance("Dark")
        try openAccentPicker(ui, expectedColor: "Mint")
        try expectSelected("mint", in: ui)
        try selectAccent("coral", in: ui)
        let mint = try accentChoice("mint", in: ui)
        try ui.expectValue(mint.state, "Not selected")
        XCTAssertFalse(mint.state.isSelected)
        try returnToSettings(ui, expectedColor: "Coral")
        try ui.relaunch()
        try ui.openSettings()
        try openAccentPicker(ui, expectedColor: "Coral")
        try expectSelected("coral", in: ui)
    }

    private func openAccentPicker(_ ui: AppUITestDriver, expectedColor: String) throws {
        let link = ui.app.buttons["settings.accent"]
        try ui.reveal(link, maxSwipes: 24)
        XCTAssertEqual(link.label, "Accent color")
        XCTAssertGreaterThanOrEqual(link.frame.width, 52)
        XCTAssertGreaterThanOrEqual(link.frame.height, 52)
        try ui.expectValue(link, expectedColor)
        try ui.tap(link)
        try ui.wait("Settings must push its Accent color picker") { ui.app.navigationBars["Accent color"].exists }
    }

    private func returnToSettings(_ ui: AppUITestDriver, expectedColor: String) throws {
        try ui.tap(ui.app.navigationBars["Accent color"].buttons["Settings"])
        try ui.wait("Back must return to Settings") {
            ui.app.navigationBars["Settings"].exists && !ui.app.navigationBars["Accent color"].exists
        }
        let link = ui.app.buttons["settings.accent"]
        try ui.reveal(link, maxSwipes: 24)
        try ui.expectValue(link, expectedColor)
    }

    private func selectAccent(_ id: String, in ui: AppUITestDriver) throws {
        let choice = try accentChoice(id, in: ui)
        try ui.tap(choice.button)
        try expectSelected(id, in: ui)
    }

    private func expectSelected(_ id: String, in ui: AppUITestDriver) throws {
        let choice = try accentChoice(id, in: ui)
        try ui.expectValue(choice.state, "Selected")
        XCTAssertTrue(choice.state.isSelected)
    }

    private func accentChoice(_ id: String, in ui: AppUITestDriver) throws -> (state: XCUIElement, button: XCUIElement) {
        let list = ui.element("settings.accent.list")
        let state = list.descendants(matching: .any).matching(identifier: "settings.accent.\(id)").firstMatch
        try ui.wait("The Accent color picker must expose the \(id) choice") { state.exists }

        // UIKit can put Form metadata on a row wrapper; tap and measure the native button inside it.
        let button: XCUIElement
        if state.elementType == .button {
            button = state
        } else {
            XCTAssertEqual(state.buttons.count, 1, "An accent row must contain exactly one selection button")
            button = state.buttons.firstMatch
        }
        try ui.reveal(button)
        try ui.requireHittable(button)
        XCTAssertTrue(button.isEnabled)
        XCTAssertGreaterThanOrEqual(button.frame.width, 52)
        XCTAssertGreaterThanOrEqual(button.frame.height, 52)
        return (state, button)
    }

    private func makeDriver() -> AppUITestDriver {
        let ui = AppUITestDriver(testCase: self, prefix: "accent")
        addTeardownBlock { await ui.finish() }
        return ui
    }
}

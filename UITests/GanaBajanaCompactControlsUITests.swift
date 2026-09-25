import XCTest

@MainActor
final class GanaBajanaCompactControlsUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testCompactSettingsSwitchesToggleAndPersist() throws {
        let ui = makeDriver()
        try ui.launch()
        try ui.openSettings()
        try ui.expectSwitch("settings.gapless", isOn: true)
        let gapless = ui.app.switches["settings.gapless"]
        XCTAssertGreaterThanOrEqual(gapless.frame.height + 1e-6, 44)
        try ui.setSwitch("settings.gapless", to: false)
        try ui.setSwitch("settings.automix", to: true)
        try ui.setSwitch("settings.automix", to: false)
        try ui.setSwitch("settings.autoplay", to: false)
        ui.capture("compact-settings-switches-dark")
        try ui.relaunch()
        try ui.openSettings()
        for id in ["settings.gapless", "settings.automix", "settings.autoplay"] {
            try ui.expectSwitch(id, isOn: false)
        }
    }

    func testLanguageNudgesAndCompactHomeSwitchesKeepPersistenceAndNativeReordering() throws {
        let ui = makeDriver()
        try ui.launch(additionalArguments: ["--light"])
        try ui.openSettings()
        try ui.reveal(ui.app.buttons["settings.languages"], maxSwipes: 16)
        try ui.tap(ui.app.buttons["settings.languages"])
        try ui.wait("Language tuning must use the listening-statistics destination") {
            ui.app.navigationBars["Listening languages"].exists
        }
        XCTAssertFalse(ui.app.switches.matching(NSPredicate(format: "identifier BEGINSWITH %@", "settings.language.")).firstMatch.exists)
        try ui.reveal(ui.app.buttons["listeningLanguages.tune"])
        try ui.tap(ui.app.buttons["listeningLanguages.tune"])
        for code in ["bn", "en", "hi", "ta", "te"] {
            let menu = ui.app.buttons["listeningLanguages.nudge.\(code)"]
            try ui.reveal(menu)
            try ui.expectValue(menu, "Automatic")
            XCTAssertGreaterThanOrEqual(menu.frame.height + 1e-6, 44)
            XCTAssertGreaterThanOrEqual(menu.frame.width + 1e-6, 44)
        }
        let tamil = ui.app.buttons["listeningLanguages.nudge.ta"]
        try ui.reveal(tamil)
        try ui.tap(tamil)
        try ui.tap(ui.app.buttons["More"])
        try ui.expectValue(tamil, "More")
        ui.capture("native-language-adjustments-light")
        let reset = ui.app.buttons["listeningLanguages.reset"]
        try ui.reveal(reset)
        try ui.tap(reset)
        try ui.expectValue(tamil, "Automatic")
        XCTAssertFalse(reset.isEnabled, "All adjustments may return to Automatic without a minimum-language rule")
        try ui.tap(ui.app.navigationBars["Listening languages"].buttons.firstMatch)
        let customize = ui.app.buttons["settings.customizeHome"]
        try ui.reveal(customize)
        try ui.tap(customize)
        try ui.wait("Home customization must open from Settings") { ui.app.navigationBars["Customize Home"].exists }
        try ui.setSwitch("home.customization.show.recentlyPlayed", to: false)
        let discovery = ui.app.switches["home.customization.show.discovery"]
        let recent = ui.app.switches["home.customization.show.recentlyPlayed"]
        try ui.reveal(discovery)
        try ui.moveQueueSong(discovery, before: recent)
        try ui.wait("A compact switch row must retain native reordering") { discovery.frame.minY < recent.frame.minY }
        ui.capture("compact-home-customization-switches-light")
        try ui.expectSwitch("home.customization.show.recentlyPlayed", isOn: false)
        try ui.closeHomeCustomization()
        try ui.relaunch()
        try ui.openHomeCustomization()
        try ui.expectSwitch("home.customization.show.recentlyPlayed", isOn: false)
        try ui.reveal(discovery, direction: .down)
        XCTAssertLessThan(discovery.frame.minY, recent.frame.minY, "Native reordering must survive relaunch")
    }

    func testCompactSwitchesKeepLongLabelsAndActionsAtLargestTextSize() throws {
        let ui = makeDriver()
        try ui.launch(additionalArguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        try ui.openSettings()
        try ui.setSwitch("settings.gapless", to: false)
        try ui.setSwitch("settings.automix", to: true)
        try ui.setSwitch("settings.automix", to: false)
        let control = ui.app.switches["settings.automix"]
        XCTAssertGreaterThanOrEqual(control.frame.height + 1e-6, 44)
        XCTAssertLessThanOrEqual(control.frame.maxX, ui.app.windows.firstMatch.frame.maxX)
        XCTAssertTrue(control.label.contains("Automix"))
        ui.capture("compact-switches-largest-text")
    }

    func testRosePenIconsSelectAndPersistWithoutReplacingThePrimaryChoice() throws {
        let ui = makeDriver()
        try ui.launch()
        try openIcons(ui)
        let primary = ui.app.buttons["settings.icon.Beat"]
        XCTAssertEqual(primary.label, "Leafnote")
        let choices = ui.app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'settings.icon.'"))
        XCTAssertEqual(choices.count, 7, "Retired icons must not appear in the picker")
        XCTAssertFalse(ui.app.buttons["settings.icon.Copper"].exists)
        for title in ["Thorn", "Sonnet"] {
            let option = ui.app.buttons["settings.icon.\(title)"]
            try ui.reveal(option, maxSwipes: 12)
            XCTAssertEqual(option.label, title)
            try ui.tap(option)
            dismissIconConfirmation()
            try ui.wait("The \(title) icon must become selected") { option.isSelected }
        }
        ui.capture("rose-pen-icon-options-in-settings")
        try ui.relaunch()
        try openIcons(ui)
        try ui.reveal(ui.app.buttons["settings.icon.Sonnet"])
        XCTAssertTrue(ui.app.buttons["settings.icon.Sonnet"].isSelected)
        try ui.reveal(primary, direction: .down)
        try ui.tap(primary)
        dismissIconConfirmation()
        try ui.wait("The primary Leafnote icon remains selectable") { primary.isSelected }
    }

    private func openIcons(_ ui: AppUITestDriver) throws {
        try ui.openSettings()
        try ui.reveal(ui.app.buttons["settings.appIcon"], maxSwipes: 16)
        try ui.tap(ui.app.buttons["settings.appIcon"])
        try ui.wait("The native icon picker must open") { ui.app.navigationBars["App icon"].exists }
    }

    private func dismissIconConfirmation() {
        let ok = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["OK"]
        if ok.waitForExistence(timeout: 3) { ok.tap() }
    }

    private func makeDriver() -> AppUITestDriver {
        let ui = AppUITestDriver(testCase: self, prefix: "compact-controls")
        addTeardownBlock { await ui.finish() }
        return ui
    }
}

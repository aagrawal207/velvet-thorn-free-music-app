import XCTest

@MainActor
final class GanaBajanaICloudSettingsUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testSyncDefaultsOnAndTurningItOffPersistsAndKeepsTheLibrary() throws {
        let ui = AppUITestDriver(testCase: self, prefix: "icloud-settings")
        addTeardownBlock { await ui.finish() }
        try ui.launch()
        try openSync(ui, expectingEnabled: true)
        try ui.expectSwitch("settings.icloud.enabled", isOn: true)
        XCTAssertGreaterThanOrEqual(ui.app.switches["settings.icloud.enabled"].frame.height + 1e-6, 44)
        XCTAssertEqual(ui.app.staticTexts["settings.icloud.status"].label, "Waiting to sync with iCloud")
        XCTAssertTrue(ui.app.buttons["settings.icloud.syncNow"].exists)
        XCTAssertFalse(ui.element("settings.icloud.lastSaved").exists)
        ui.capture("icloud-settings-default-enabled")

        try ui.setSwitch("settings.icloud.enabled", to: false)
        XCTAssertFalse(ui.app.buttons["settings.icloud.syncNow"].exists)
        XCTAssertTrue(ui.app.staticTexts["settings.icloud.status"].label.contains("off"))
        ui.capture("icloud-settings-disabled-local-library-kept")
        try ui.tap(ui.app.navigationBars["iCloud Sync"].buttons.firstMatch)
        try expectSummary(ui, isOn: false)
        ui.capture("icloud-summary-disabled")

        try ui.relaunch()
        try openSync(ui, expectingEnabled: false)
        try ui.expectSwitch("settings.icloud.enabled", isOn: false)
        XCTAssertFalse(ui.app.buttons["settings.icloud.syncNow"].exists)
        try ui.tap(ui.app.navigationBars["iCloud Sync"].buttons.firstMatch)
        try ui.tap(ui.app.buttons["settings.done"])
        try ui.selectTab("library")
        try ui.openPlaylist(named: AppUIFixture.seededPlaylist)
        XCTAssertTrue(ui.app.buttons["library.playlist.play"].isEnabled)
    }

    func testReenabledSyncPersistsAndSummaryDistinguishesPreferenceFromDelivery() throws {
        let ui = AppUITestDriver(testCase: self, prefix: "icloud-reenable")
        addTeardownBlock { await ui.finish() }
        try ui.launch(additionalArguments: ["--light"])
        try openSync(ui, expectingEnabled: true)
        try ui.setSwitch("settings.icloud.enabled", to: false)
        try ui.relaunch()
        try openSync(ui, expectingEnabled: false)
        try ui.expectSwitch("settings.icloud.enabled", isOn: false)
        try ui.setSwitch("settings.icloud.enabled", to: true)
        try ui.tap(ui.app.navigationBars["iCloud Sync"].buttons.firstMatch)
        try expectSummary(ui, isOn: true)
        ui.capture("icloud-summary-enabled-waiting-light")

        try ui.relaunch()
        try openSync(ui, expectingEnabled: true)
        try ui.expectSwitch("settings.icloud.enabled", isOn: true)
        try ui.tap(ui.app.buttons["settings.icloud.syncNow"])
        XCTAssertEqual(ui.app.staticTexts["settings.icloud.status"].label, "Waiting to sync with iCloud",
                       "The fixture host must not claim a native iCloud save after a manual retry")
        XCTAssertFalse(ui.element("settings.icloud.lastSaved").exists)
        XCTAssertFalse(ui.element("settings.icloud.error").exists)
        let deliveryNote = ui.app.staticTexts["settings.icloud.deliveryNote"]
        try ui.reveal(deliveryNote)
        XCTAssertTrue(deliveryNote.label.contains("does not confirm upload or delivery"))
        ui.capture("icloud-enabled-is-a-preference-light")
    }

    private func openSync(_ ui: AppUITestDriver, expectingEnabled: Bool) throws {
        try ui.openSettings()
        try expectSummary(ui, isOn: expectingEnabled)
        try ui.tap(ui.app.buttons["settings.icloud"])
        try ui.wait("The iCloud sync settings must open") { ui.app.navigationBars["iCloud Sync"].exists }
    }

    private func expectSummary(_ ui: AppUITestDriver, isOn: Bool) throws {
        try ui.openSettingsPage(.library)
        let row = ui.app.buttons["settings.icloud"]
        try ui.reveal(row, maxSwipes: 20)
        try ui.wait("The iCloud row must expose the preference separately from activity") {
            guard let value = row.value as? String else { return false }
            return value.hasPrefix(isOn ? "On. Status:" : "Off. Status:")
                && value.contains(isOn ? "Waiting to sync with iCloud" : "off")
        }
        XCTAssertEqual(row.label, "iCloud Sync")
        XCTAssertGreaterThanOrEqual(row.frame.height + 1e-6, 44)
    }
}

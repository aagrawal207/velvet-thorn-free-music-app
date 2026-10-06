import XCTest

@MainActor
final class GanaBajanaAudioQualityUITests: XCTestCase {
    private let choices = ["Best Available", "Balanced", "Data Saver"]

    override func setUpWithError() throws { continueAfterFailure = false }

    func testAudioQualityChoicePersistsAndPrefixesThePlayerRow() throws {
        let ui = makeDriver()
        try ui.launch()
        try ui.openSettings()
        try ui.openSettingsPage(.playback)
        let picker = ui.app.buttons["settings.audioQuality"]
        let note = ui.app.staticTexts["settings.audioQuality.description"]
        try ui.reveal(picker, maxSwipes: 24)
        try ui.expectValue(picker, "Best Available")
        XCTAssertTrue(picker.label.contains("Audio Quality"))
        XCTAssertGreaterThanOrEqual(picker.frame.height + 1e-6, 44)
        XCTAssertGreaterThanOrEqual(picker.frame.width + 1e-6, 44)
        try ui.reveal(note, maxSwipes: 24)
        // The note lives in the Playback footer and names the chosen tier: "Audio quality applies from the next song. <Tier>: <detail>."
        XCTAssertTrue(note.label.contains("higher tiers when available"), note.label)
        XCTAssertTrue(note.label.contains("next song"), note.label)
        try choose("Data Saver", from: "Best Available", picker: picker, ui: ui)
        try ui.wait("The description must follow the chosen quality") { note.label.contains("64 kbps") }
        ui.capture("audio-quality-data-saver")
        try ui.tap(ui.app.buttons["settings.done"])
        try ui.requireHittable(ui.app.buttons["home.settings"])

        try ui.relaunch()
        try ui.openSettings()
        try ui.openSettingsPage(.playback)
        try ui.reveal(picker, maxSwipes: 24)
        try ui.expectValue(picker, "Data Saver")
        try ui.reveal(note, maxSwipes: 24)
        XCTAssertTrue(note.label.contains("64 kbps"), note.label)
        try ui.tap(ui.app.buttons["settings.done"])
        try ui.requireHittable(ui.app.buttons["home.settings"])

        try ui.searchAndPlayTumHiHo()
        try ui.openPlayer()
        try ui.openPlayerMenu()
        let row = ui.element("player.options.audioQuality")
        try ui.wait("The player row must name the active preference") {
            row.exists && row.label.contains("Audio Quality") && row.label.contains("Data Saver ·")
        }
        let reload = ui.app.buttons["player.options.reloadAudioQuality"]
        try ui.wait("The reload row must describe the ceiling") { reload.exists && reload.label.contains("Reload best available audio") }
        XCTAssertTrue(ui.accessibleText(reload).contains("up to 64 kbps"), ui.accessibleText(reload))
        // The options sheet opens at half height; one slow swipe expands it so the capture shows both quality rows.
        let sheet = ui.element("player.options.sheet")
        let window = ui.app.windows.firstMatch
        if sheet.frame.height < window.frame.height * 0.8 {
            ui.app.scrollViews["player.options.list"].swipeUp(velocity: .slow)
            _ = try? ui.wait("The options sheet may expand", timeout: 5) { sheet.frame.height >= window.frame.height * 0.8 }
        }
        ui.capture("audio-quality-player-row")
        try ui.tap(ui.app.buttons["player.options.toolbarDone"])
        try ui.wait("Done must close the options sheet") { !ui.element("player.options.sheet").exists }
    }

    /// Picker options live in the native menu overlay; the checked entry must be the saved choice.
    private func choose(_ choice: String, from previous: String, picker: XCUIElement, ui: AppUITestDriver) throws {
        try ui.tap(picker)
        for title in choices {
            let option = ui.app.buttons[title]
            try ui.requireHittable(option)
            let selected = option.isSelected || (option.value as? String) == "1"
            XCTAssertEqual(selected, title == previous, "The native audio quality menu must check only \(previous)")
        }
        let option = ui.app.buttons[choice]
        try ui.tap(option)
        try ui.wait("Choosing \(choice) must dismiss the native menu") { !option.exists }
        try ui.expectValue(picker, choice)
    }

    private func makeDriver() -> AppUITestDriver {
        let ui = AppUITestDriver(testCase: self, prefix: "audio-quality")
        addTeardownBlock { await ui.finish() }
        return ui
    }
}

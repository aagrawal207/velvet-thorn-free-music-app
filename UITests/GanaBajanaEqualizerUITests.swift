import XCTest

@MainActor
final class GanaBajanaEqualizerUITests: XCTestCase {
    private let presetChoices = ["Flat", "Bass Boost", "Rock", "Custom"]

    override func setUpWithError() throws { continueAfterFailure = false }

    func testSettingsRowOpensTheEqualizerAndShowsTheChosenPresetAfterBack() throws {
        let ui = makeDriver()
        try ui.launch(additionalArguments: ["--light"])
        try ui.openSettings()
        try ui.openSettingsPage(.playback)
        let row = ui.app.buttons["settings.equalizer"]
        try ui.reveal(row, maxSwipes: 24)
        try ui.expectValue(row, "Off")
        XCTAssertTrue(row.label.contains("Equalizer"))
        XCTAssertGreaterThanOrEqual(row.frame.height + 1e-6, 44)
        XCTAssertGreaterThanOrEqual(row.frame.width + 1e-6, 44)
        try openEqualizer(ui)

        try setSwitch("equalizer.enabled", to: true, ui: ui)
        let preset = ui.app.buttons["equalizer.preset"]
        try ui.reveal(preset, direction: .down, maxSwipes: 8)
        XCTAssertGreaterThanOrEqual(preset.frame.height + 1e-6, 44)
        try choose("Bass Boost", from: "Flat", picker: preset, ui: ui)
        XCTAssertEqual(ui.element("equalizer.preset.description").label, "Bass boost: more thump for hip hop and EDM")

        // Simple mode is the default: three sliders read the preset's curve and the page explains the regions.
        try selectMode("Simple", ui: ui)
        let bass = ui.app.sliders["equalizer.simple.bass"]
        try ui.reveal(bass, maxSwipes: 8)
        XCTAssertTrue((bass.value as? String)?.hasPrefix("+") == true, "Bass boost lifts the Bass slider: \(String(describing: bass.value))")
        XCTAssertGreaterThan(bass.frame.width, 120, "The Bass slider spans most of its row")
        try ui.expectValue(ui.app.sliders["equalizer.simple.treble"], "0 dB")
        XCTAssertFalse(ui.element("equalizer.band.0").exists, "Simple mode hides the ten bands")
        let hints = ui.element("equalizer.hints")
        try ui.reveal(hints, maxSwipes: 8)
        XCTAssertTrue(hints.label.contains("Bass: thump and warmth"), hints.label)
        XCTAssertTrue(hints.label.contains("Treble: clarity and cymbals"), hints.label)
        ui.capture("equalizer-simple-bass-boost")

        try selectMode("Advanced", ui: ui)
        for (band, gain) in ["+6 dB", "+5 dB", "+4 dB", "+2 dB", "0 dB"].enumerated() {
            let slider = ui.element("equalizer.band.\(band)")
            try ui.reveal(slider, maxSwipes: 8)
            try ui.expectValue(slider, gain)
            XCTAssertGreaterThanOrEqual(slider.frame.width + 1e-6, 44, "band \(band)")
            XCTAssertGreaterThanOrEqual(slider.frame.height + 1e-6, 44, "band \(band)")
            XCTAssertTrue(slider.label.contains("Hz"), slider.label)
        }
        XCTAssertEqual(ui.element("equalizer.band.0").label, "Sub-bass, 31 Hz")
        let preamp = ui.app.sliders["equalizer.preamp"]
        try ui.reveal(preamp, maxSwipes: 8)
        try ui.expectValue(preamp, "Auto -6 dB")
        ui.capture("equalizer-bass-boost")

        try goBackToSettings(ui)
        try ui.reveal(row, maxSwipes: 24)
        try ui.expectValue(row, "Bass Boost")
        try ui.tap(ui.app.buttons["settings.done"])
        try ui.requireHittable(ui.app.buttons["home.settings"])

        try ui.relaunch()
        try ui.openSettings()
        try ui.openSettingsPage(.playback)
        try ui.reveal(row, maxSwipes: 24)
        try ui.expectValue(row, "Bass Boost")
        try openEqualizer(ui)
        let enabled = ui.app.switches["equalizer.enabled"]
        try ui.requireHittable(enabled)
        try ui.expectValue(enabled, "1")
        try ui.expectValue(preset, "Bass Boost")
    }

    func testDraggingABandSwitchesToCustomResetReturnsToFlatAndPlaybackKeepsAdvancing() throws {
        let ui = makeDriver()
        try ui.launch()
        try ui.openSettings()
        try ui.openSettingsPage(.playback)
        let row = ui.app.buttons["settings.equalizer"]
        try ui.reveal(row, maxSwipes: 24)
        try openEqualizer(ui)
        let preset = ui.app.buttons["equalizer.preset"]
        try ui.reveal(preset, direction: .down, maxSwipes: 8)
        try choose("Rock", from: "Flat", picker: preset, ui: ui)
        try selectMode("Advanced", ui: ui)
        let band = ui.element("equalizer.band.0")
        try ui.reveal(band, maxSwipes: 8)
        try ui.expectValue(band, "+5 dB")

        // The column maps touch height to gain, so a press at its centre reads 0 dB and a lift higher up is a boost.
        let start = band.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = band.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        start.press(forDuration: 0.1, thenDragTo: end)
        try ui.wait("Moving a band must leave the preset") { (preset.value as? String) == "Custom" }
        try ui.wait("The dragged band must report a boost") {
            guard let value = band.value as? String else { return false }
            return value.hasPrefix("+") && value != "+5 dB"
        }
        let neighbour = ui.element("equalizer.band.1")
        try ui.expectValue(neighbour, "+4 dB")
        ui.capture("equalizer-custom-after-drag")

        let reset = ui.app.buttons["equalizer.reset"]
        try ui.reveal(reset, maxSwipes: 8)
        XCTAssertTrue(reset.isEnabled)
        XCTAssertGreaterThanOrEqual(reset.frame.height + 1e-6, 44)
        try ui.tap(reset)
        // The page is longer than one screen, so the preset row scrolls back into view before its value is read.
        try ui.reveal(preset, direction: .down, maxSwipes: 8)
        try ui.expectValue(preset, "Flat")
        for index in 0..<10 {
            let slider = ui.element("equalizer.band.\(index)")
            try ui.reveal(slider, maxSwipes: 8)
            try ui.expectValue(slider, "0 dB")
        }
        let preamp = ui.app.sliders["equalizer.preamp"]
        try ui.reveal(preamp, maxSwipes: 8)
        try ui.expectValue(preamp, "0 dB")
        try ui.wait("Reset has nothing left to undo") { !reset.isEnabled }

        try choose("Bass Boost", from: "Flat", picker: preset, ui: ui)
        try setSwitch("equalizer.enabled", to: true, ui: ui)
        try goBackToSettings(ui)
        try ui.reveal(row, maxSwipes: 24)
        try ui.expectValue(row, "Bass Boost")
        try ui.tap(ui.app.buttons["settings.done"])
        try ui.requireHittable(ui.app.buttons["home.settings"])

        try ui.searchAndPlayTumHiHo()
        try ui.openPlayer()
        let position = try ui.position()
        try ui.waitForAdvance(from: position, by: 2)
        try ui.pause()
        try ui.assertPausedPositionStaysPut(for: 1.5)
        try ui.play()
        try ui.waitForAdvance(from: try ui.position(), by: 2)
        ui.capture("equalizer-playback-advances")
    }

    // MARK: - Helpers

    private func makeDriver() -> AppUITestDriver {
        let ui = AppUITestDriver(testCase: self, prefix: "equalizer")
        addTeardownBlock { await ui.finish() }
        return ui
    }

    private func openEqualizer(_ ui: AppUITestDriver) throws {
        let row = ui.app.buttons["settings.equalizer"]
        try ui.reveal(row, maxSwipes: 24)
        try ui.tap(row)
        try ui.wait("Settings must push the equalizer") { ui.app.navigationBars["Equalizer"].exists }
        try ui.requireHittable(ui.app.switches["equalizer.enabled"])
    }

    private func goBackToSettings(_ ui: AppUITestDriver) throws {
        let bar = ui.app.navigationBars["Equalizer"]
        try ui.tap(bar.buttons.firstMatch)
        try ui.wait("Back must return to the Playback page") { ui.app.navigationBars[SettingsPageID.playback.title].exists }
    }

    /// Picker options live in the native menu overlay; the checked entry must be the saved choice.
    private func choose(_ choice: String, from previous: String, picker: XCUIElement, ui: AppUITestDriver) throws {
        // The row can sit under the navigation bar or be recycled after scrolling to Reset; it is always near the top.
        try ui.reveal(picker, direction: .down, maxSwipes: 12)
        try ui.expectValue(picker, previous)
        try ui.tap(picker)
        for title in presetChoices {
            let option = ui.app.buttons[title]
            try ui.requireHittable(option)
            let selected = option.isSelected || (option.value as? String) == "1"
            XCTAssertEqual(selected, title == previous, "The native preset menu must check only \(previous)")
        }
        let option = ui.app.buttons[choice]
        try ui.tap(option)
        try ui.wait("Choosing \(choice) must dismiss the native menu") { !option.exists }
        try ui.expectValue(picker, choice)
    }

    private func selectMode(_ title: String, ui: AppUITestDriver) throws {
        let id = "equalizer.mode.\(title.lowercased())"
        let segment = ui.app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", id, title)).firstMatch
        try ui.reveal(segment, direction: .down, maxSwipes: 8)
        if !segment.isSelected { try ui.tap(segment) }
        try ui.wait("\(title) mode must be selected") { segment.isSelected }
    }

    private func setSwitch(_ id: String, to enabled: Bool, ui: AppUITestDriver) throws {
        let row = ui.app.switches[id]
        try ui.reveal(row, direction: .down, maxSwipes: 8)
        let value = try XCTUnwrap(row.value as? String)
        XCTAssertTrue(value == "0" || value == "1", "\(id) must expose native Toggle state")
        if value != (enabled ? "1" : "0") {
            let native = row.switches.firstMatch
            let frame = native.exists ? native.frame : .null
            // A virtual native Toggle child can have zero bounds; its visible parent still owns the row tap.
            if !frame.isEmpty, !frame.isNull, row.frame.contains(frame), native.isHittable { try ui.tap(native) }
            else { try ui.tap(row) }
        }
        try ui.expectValue(row, enabled ? "1" : "0")
    }
}

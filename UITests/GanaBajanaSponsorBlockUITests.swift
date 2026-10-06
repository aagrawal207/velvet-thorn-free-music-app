import XCTest

@MainActor
final class GanaBajanaSponsorBlockUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    /// The fixture answers lookups locally with one 3 to 8 s section for Tum Hi Ho; the elapsed label must jump
    /// over it and the More sheet must count the jump. The setting defaults off.
    func testSkippingJumpsPastTheFixtureSectionAndTheMoreSheetCountsIt() throws {
        let ui = AppUITestDriver(testCase: self, prefix: "sponsorblock")
        addTeardownBlock { await ui.finish() }
        try ui.launch(additionalArguments: ["--sponsorblock-fixture"])
        try ui.openSettings()
        try ui.openSettingsPage(.playback)
        let row = ui.app.switches["settings.sponsorBlock"]
        try ui.reveal(row, maxSwipes: 24)
        XCTAssertTrue(row.label.contains("Skip Non-Music Sections"), row.label)
        XCTAssertGreaterThanOrEqual(row.frame.height + 1e-6, 44)
        try ui.expectValue(row, "0")
        let note = ui.app.staticTexts["settings.sponsorBlock.description"]
        try ui.reveal(note, maxSwipes: 24)
        XCTAssertTrue(note.label.contains("SponsorBlock's community markers to skip intros, outros and talk in YouTube uploads"), note.label)
        try ui.setSwitch("settings.sponsorBlock", to: true)
        ui.capture("sponsorblock-setting-on")
        try ui.tap(ui.app.buttons["settings.done"])
        try ui.requireHittable(ui.app.buttons["home.settings"])

        try ui.searchAndPlayTumHiHo()
        try ui.openPlayer()
        // Opening the player can outlast the 3 s marker. Previous at 0 to 3 s restarts the song as a fresh play,
        // and past 3 s it first rewinds, so two taps always leave a paused fresh play at 0.
        try ui.pause()
        for _ in 0..<2 {
            try ui.tap(ui.app.buttons["player.previous"])
            try ui.expectPosition(0)
        }
        try ui.play()
        // The label has whole-second resolution: consecutive samples differ by at most a second unless a skip landed.
        var samples: [TimeInterval] = []
        var jumped = false
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            if let value = ui.positionIfVisible() {
                if let last = samples.last, last <= 3.5, value >= 7.5 { jumped = true }
                samples.append(value)
                if value >= 8 { break }
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertTrue(jumped, "Elapsed time must jump from the 3 s marker past 8 s: \(samples)")
        XCTAssertFalse(samples.contains { $0 > 4.5 && $0 < 7.5 }, "The middle of the section must never show: \(samples)")
        try ui.wait("Playback continues after the jump") {
            (ui.positionIfVisible() ?? 0) >= 8 && ui.app.buttons["player.playPause"].label == "Pause"
        }
        ui.capture("sponsorblock-after-jump")

        try ui.openPlayerMenu()
        let skipped = ui.element("player.options.sponsorBlock")
        try ui.wait("The More sheet must count the skipped section") {
            skipped.exists && skipped.label.contains("Skipped 1 non-music section")
        }
        XCTAssertFalse(skipped.label.contains("sections"), skipped.label)
        ui.capture("sponsorblock-more-row")
        try ui.tap(ui.app.buttons["player.options.toolbarDone"])
        try ui.wait("Done must close the options sheet") { !ui.element("player.options.sheet").exists }

        // Relaunching keeps the choice; a fresh play of the same song skips again from the start.
        try ui.relaunch()
        try ui.openSettings()
        try ui.expectSwitch("settings.sponsorBlock", isOn: true)
        try ui.tap(ui.app.buttons["settings.done"])
        try ui.requireHittable(ui.app.buttons["home.settings"])
    }
}

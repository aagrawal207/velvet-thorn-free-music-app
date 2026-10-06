import XCTest

/// Frame-hitch measurements for scrolling and navigation on a realistic-scale library. The in-app probe drives
/// scrolling itself and arms push/pop windows on the next touch, so XCUITest element queries stay outside every
/// measured window. Simulator numbers compare builds; they are not device frame rates.
@MainActor
final class GanaBajanaResponsivenessUITests: XCTestCase {
    private var results: [String] = []

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 900
    }

    func testIdleScrollingAndNavigation() throws {
        let ui = try launchFixture()
        try exercise(ui, phase: "idle")
    }

    func testScrollingAndNavigationDuringPlayback() throws {
        let ui = try launchFixture()
        try ui.tap(ui.app.buttons["miniPlayer.playPause"])
        try ui.wait("Cached audio must play before measuring", timeout: 15) {
            (ui.app.buttons["miniPlayer.open"].value as? String ?? "").hasPrefix("Playing")
        }
        try exercise(ui, phase: "playing")
    }

    func testLikedSongsScrolling() throws {
        let ui = try launchFixture()
        try select("library", ui)
        try ui.requireHittable(ui.element("library.likes"), timeout: 15)
        try ui.tap(ui.element("library.likes"))
        try ui.requireHittable(ui.app.buttons["library.likes.filter.all"], timeout: 15)
        try settle()
        try autoscroll("likes.scroll.first", phase: "focused", ui)
        try autoscroll("likes.scroll.second", phase: "focused", ui)
        print("RESPONSIVENESS-SUMMARY\n\(results.joined(separator: "\n"))")
    }

    private func exercise(_ ui: AppUITestDriver, phase: String) throws {
        try select("home", ui)
        try settle()
        // Control: a tap that changes nothing isolates XCUITest's own tap and idle-wait cost from app work.
        try measureTouch("control.noopTap", phase: phase, ui) { try ui.tap(ui.app.staticTexts["Velvet Thorn"].firstMatch) }
        try autoscroll("home.scroll", phase: phase, ui)

        try measureTouch("home.pushMix", phase: phase, ui) { try ui.tap(ui.element("mix.mix.discoverWeekly")) }
        try ui.requireHittable(ui.element("collection.play"), timeout: 15)
        try settle()
        try autoscroll("mix.scroll", phase: phase, ui)
        try measureTouch("mix.pop", phase: phase, ui) { try ui.tap(ui.app.navigationBars.buttons.firstMatch) }
        try ui.requireHittable(ui.app.buttons["home.settings"], timeout: 15)

        try measureTouch("tab.library", phase: phase, ui) { try ui.tap(ui.app.buttons["tab.library"].firstMatch) }
        try ui.requireHittable(ui.element("library.likes"), timeout: 15)
        try settle()
        try autoscroll("library.scroll", phase: phase, ui)
        try ui.reveal(ui.element("library.likes"), direction: .down, maxSwipes: 20)

        try measureTouch("likes.push", phase: phase, ui) { try ui.tap(ui.element("library.likes")) }
        try ui.requireHittable(ui.app.buttons["library.likes.filter.all"], timeout: 15)
        try settle()
        try autoscroll("likes.scroll", phase: phase, ui)
        try measureTouch("likes.pop", phase: phase, ui) { try ui.tap(ui.app.navigationBars.buttons.firstMatch) }
        try ui.requireHittable(ui.element("library.likes"), timeout: 15)

        try measureTouch("tab.recap", phase: phase, ui) { try ui.tap(ui.app.buttons["tab.recap"].firstMatch) }
        try ui.requireHittable(ui.app.buttons["recap.window.month"], timeout: 15)
        try settle()
        try autoscroll("recap.scroll", phase: phase, ui)

        try measureTouch("tab.home", phase: phase, ui) { try ui.tap(ui.app.buttons["tab.home"].firstMatch) }
        try ui.requireHittable(ui.app.buttons["home.settings"], timeout: 15)

        try measureTouch("player.open", phase: phase, ui) { try ui.tap(ui.app.buttons["miniPlayer.open"]) }
        try settle()

        let summary = results.joined(separator: "\n")
        print("RESPONSIVENESS-SUMMARY\n\(summary)")
        let attachment = XCTAttachment(string: summary)
        attachment.name = "Responsiveness \(phase)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func autoscroll(_ name: String, phase: String, _ ui: AppUITestDriver) throws {
        try ui.tap(ui.app.buttons["scrollPerformance.autoscroll"])
        // No queries while the probe drives the scroll view; 10,000 pt each way at 2,400 pt/s plus start delay.
        Thread.sleep(forTimeInterval: 9.5)
        try ui.wait("The autoscroll window must finish", timeout: 20) { self.number("active", ui) == 0 }
        record(name, phase: phase, ui)
    }

    private func measureTouch(_ name: String, phase: String, _ ui: AppUITestDriver, _ action: () throws -> Void) throws {
        try ui.tap(ui.app.buttons["scrollPerformance.arm"])
        try action()
        Thread.sleep(forTimeInterval: 1.8)
        try ui.wait("The touch window must close", timeout: 10) { self.number("active", ui) == 0 }
        record(name, phase: phase, ui)
    }

    private func record(_ name: String, phase: String, _ ui: AppUITestDriver) {
        let fields = ["frames", "hitches", "hitchMS", "maxGapMS", "durationMS", "error"]
        let values = fields.map { "\($0)=\(Int(number($0, ui).rounded()))" }
        let duration = max(number("durationMS", ui), 1) / 1_000
        let ratio = number("hitchMS", ui) / duration
        let line = "RESPONSIVENESS phase=\(phase) step=\(name) ratioMSperS=\(Int(ratio.rounded())) " + values.joined(separator: " ")
        print(line)
        results.append(line)
        XCTAssertEqual(number("error", ui), 0, probeValue(ui))
    }

    private func settle() throws { Thread.sleep(forTimeInterval: 1.5) }

    private func launchFixture() throws -> AppUITestDriver {
        let ui = AppUITestDriver(testCase: self, prefix: "responsiveness")
        addTeardownBlock { await ui.finish() }
        ui.app.launchArguments = ["--uitesting", "--seed-ui", "--reset-ui", "--skip-welcome",
                                  "--scroll-performance-fixture", "--large-library-fixture", "--responsiveness-probe",
                                  "--natural-checkpoints", "--cache-fixture", "--genre-fixture", "--artwork-fixture",
                                  "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        ui.app.launchEnvironment = ["GANABAJANA_TEST_STORE": ui.storeName]
        ui.app.launch()
        try ui.requireHittable(ui.app.buttons["scrollPerformance.autoscroll"], timeout: 60)
        try ui.wait("The large library must be seeded", timeout: 60) {
            self.number("ready", ui) == 1 && self.number("events", ui) >= 12_000 && self.number("error", ui) == 0
        }
        return ui
    }

    private func select(_ tab: String, _ ui: AppUITestDriver) throws {
        let button = ui.app.buttons["tab.\(tab)"].firstMatch
        if !button.isSelected { try ui.tap(button) }
    }

    private func probeValue(_ ui: AppUITestDriver) -> String {
        ui.app.buttons["scrollPerformance.probe"].value as? String ?? ""
    }

    private func number(_ key: String, _ ui: AppUITestDriver) -> Double {
        let field = probeValue(ui).split(separator: ";").first { $0.hasPrefix("\(key)=") }
        return field.flatMap { Double($0.dropFirst(key.count + 1)) } ?? -1
    }
}

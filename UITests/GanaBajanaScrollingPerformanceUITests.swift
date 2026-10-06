import XCTest

@MainActor
final class GanaBajanaScrollingPerformanceUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 170
    }

    func testHomeScrollingMetricsWhileLocalPlaybackCheckpointsCommit() throws {
        _ = try measureScrolling(tab: "home")
    }

    func testStatsScrollingMetricsWhileLocalPlaybackCheckpointsCommit() throws {
        let ui = try measureScrolling(tab: "recap")
        try assertCollapsedRecentsAndReturnToHeader(ui)
    }

    private func measureScrolling(tab: String) throws -> AppUITestDriver {
        let ui = try launchFixture()
        try startLocalPlayback(ui)
        try select(tab, ui: ui)
        let header = ui.app.buttons[tab == "home" ? "home.settings" : "recap.window.month"]
        let options = XCTMeasureOptions()
        options.iterationCount = 2
        // Manual start leaves auto-stop enabled unless manuallyStop is also set; explicit stop then fails at harvest.
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        // Framework hitch/deceleration measurements are simulator evidence, not a device FPS guarantee.
        measure(metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric], options: options) {
            var measuring = false
            do {
                try ui.requireHittable(header)
                let scroll = try ui.scrollable()
                let start = try playingPosition(ui)
                try beginProbe(ui)
                startMeasuring()
                measuring = true
                scrollRoundTrip(scroll, header: header)
                stopMeasuring()
                measuring = false
                try finishProbe(ui, name: tab, startPosition: start)
                try ui.requireHittable(header)
                XCTAssertTrue(ui.app.staticTexts[tab == "home" ? "Velvet Thorn" : "Stats"].firstMatch.isHittable)
            } catch {
                if measuring { stopMeasuring() }
                XCTFail("Scrolling fixture failed: \(error)")
            }
        }
        return ui
    }

    func testStatsScrollingFrameClockAndIndependentSeedSnapshot() throws {
        let ui = try launchFixture()
        try select("recap", ui: ui)
        try ui.tap(ui.app.buttons["recap.window.month"])
        // Literal fixture oracle: 2,000 three-minute sessions, five songs, all within the last month.
        XCTAssertEqual(ui.element("recap.totalListening").label, "6,000 minutes listened in the last 30 days")
        try ui.reveal(ui.element("recap.plays"), maxSwipes: 3)
        XCTAssertEqual(String(ui.element("recap.plays").label.filter(\.isNumber)), "2000")
        XCTAssertEqual(String(ui.element("recap.songs").label.filter(\.isNumber)), "5")
        try startLocalPlayback(ui)
        try exerciseStats(ui)
    }

    private func exerciseStats(_ ui: AppUITestDriver) throws {
        try select("recap", ui: ui)
        let header = ui.app.buttons["recap.window.month"]
        try ui.reveal(header, direction: .down, maxSwipes: 6)
        let scroll = try ui.scrollable()
        let start = try playingPosition(ui)
        try beginProbe(ui)
        scrollRoundTrip(scroll, header: header)
        try finishProbe(ui, name: "Stats", startPosition: start, checksFrameClock: true)
        try ui.requireHittable(header)
        try assertCollapsedRecentsAndReturnToHeader(ui)
    }

    private func assertCollapsedRecentsAndReturnToHeader(_ ui: AppUITestDriver) throws {
        let header = ui.app.buttons["recap.window.month"]
        let recents = ui.app.buttons["recap.recent.toggle"]
        try ui.reveal(recents, maxSwipes: 20)
        XCTAssertEqual(recents.value as? String, "Collapsed")
        XCTAssertFalse(ui.element("recap.recent.all").exists)
        try ui.reveal(header, direction: .down, maxSwipes: 20)
        try ui.requireHittable(header)
        XCTAssertTrue(ui.app.staticTexts["Stats"].isHittable)
    }

    private func scrollRoundTrip(_ scroll: XCUIElement, header: XCUIElement) {
        for _ in 0..<4 { scroll.swipeUp(velocity: .fast) }
        XCTAssertFalse(header.isHittable, "The page must actually move beyond its header")
        for _ in 0..<4 { scroll.swipeDown(velocity: .fast) }
    }

    private func launchFixture() throws -> AppUITestDriver {
        let ui = AppUITestDriver(testCase: self, prefix: "scroll-performance")
        addTeardownBlock { await ui.finish() }
        ui.app.launchArguments = ["--uitesting", "--seed-ui", "--reset-ui", "--skip-welcome",
                                  "--scroll-performance-fixture", "--cache-fixture", "--genre-fixture",
                                  "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        ui.app.launchEnvironment = ["GANABAJANA_TEST_STORE": ui.storeName]
        ui.app.launch()
        try ui.requireHittable(ui.app.buttons["scrollPerformance.probe"], timeout: 30)
        try ui.wait("The isolated history and local AAC fixture must be ready", timeout: 30) {
            self.number("ready", ui) == 1 && self.number("events", ui) == 2_000 && self.number("error", ui) == 0
        }
        return ui
    }

    private func select(_ tab: String, ui: AppUITestDriver) throws {
        let button = ui.app.buttons["tab.\(tab)"].firstMatch
        if !button.isSelected { try ui.tap(button) }
    }

    private func startLocalPlayback(_ ui: AppUITestDriver) throws {
        try ui.tap(ui.app.buttons["miniPlayer.playPause"])
        try ui.wait("Cached audio must play and advance before collecting frames", timeout: 15) {
            ((try? self.playingPosition(ui)) ?? 0) >= 1
        }
        XCTAssertEqual(ui.element("cacheFixture.playbackSource").value as? String, "local")
    }

    private func beginProbe(_ ui: AppUITestDriver) throws {
        try ui.tap(ui.app.buttons["scrollPerformance.probe"])
        XCTAssertEqual(number("active", ui), 1)
    }

    private func finishProbe(_ ui: AppUITestDriver, name: String, startPosition: TimeInterval,
                             checksFrameClock: Bool = false) throws {
        XCTAssertGreaterThan(number("commits", ui), 0, "A real async model checkpoint must commit during \(name) stress")
        XCTAssertGreaterThan(number("scrollCommits", ui), 0, "An acknowledged commit must overlap dragging/deceleration")
        try ui.tap(ui.app.buttons["scrollPerformance.probe"])
        try ui.wait("The acknowledged session, queue and recent position must exist in the isolated library file", timeout: 10) {
            self.number("diskVerified", ui) == 1
        }
        XCTAssertEqual(number("active", ui), 0)
        XCTAssertEqual(number("error", ui), 0)
        XCTAssertEqual(number("network", ui), 0)
        XCTAssertGreaterThan(number("scrollFrames", ui), 0)
        XCTAssertGreaterThan(number("frames", ui), 1)
        XCTAssertGreaterThan(try playingPosition(ui), startPosition + 1)
        if checksFrameClock {
            // A one-second starvation watchdog catches the reported ~2.2 s callback stall; it is not a frame budget.
            XCTAssertLessThan(number("maxGapMS", ui), 1_000, "The app's display link was starved during real scrolling")
        }
        let attachment = XCTAttachment(string: ui.app.buttons["scrollPerformance.probe"].value as? String ?? "missing probe")
        attachment.name = "\(name) scroll checkpoint and frame-clock diagnostics"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func playingPosition(_ ui: AppUITestDriver) throws -> TimeInterval {
        let value = ui.app.buttons["miniPlayer.open"].value as? String ?? ""
        guard value.hasPrefix("Playing, "), value.hasSuffix(" elapsed"),
              let seconds = AppUIClock.seconds(String(value.dropFirst("Playing, ".count).dropLast(" elapsed".count))) else {
            throw AppUIWorkflowFailure(message: "Expected advancing mini-player audio: \(value)")
        }
        return seconds
    }

    private func number(_ key: String, _ ui: AppUITestDriver) -> Double {
        let value = ui.app.buttons["scrollPerformance.probe"].value as? String ?? ""
        let field = value.split(separator: ";").first { $0.hasPrefix("\(key)=") }
        return field.flatMap { Double($0.dropFirst(key.count + 1)) } ?? -1
    }
}

import UIKit
import XCTest

@MainActor
final class GanaBajanaListeningLanguagesUITests: XCTestCase {
    private let languageCodes = ["bn", "en", "hi", "ta", "te"]

    override func setUpWithError() throws { continueAfterFailure = false }

    func testRecapEntryUsesLastThirtyDaysAndShowsActualCountsWithTuningCollapsed() throws {
        let ui = makeDriver()
        try launch(ui)
        try selectTab("recap", in: ui)
        try ui.tap(ui.app.buttons["recap.window.year"])
        let entry = ui.app.buttons["recap.listeningLanguages"]
        try assertControl(entry, in: ui)
        XCTAssertTrue(entry.label.contains("Last 30 days"), "The language window does not inherit the selected recap window")
        try ui.expectValue(entry, "20 plays · 5 songs")
        try ui.tap(entry)
        try waitForLanguages(ui)
        try expectSeededStats(ui)
        XCTAssertFalse(languageElement("listeningLanguages.nudge.en", in: ui).exists)
        try ui.expectValue(languageElement("listeningLanguages.tune", in: ui), "Collapsed")
        XCTAssertFalse(ui.app.switches.matching(NSPredicate(format: "identifier BEGINSWITH %@", "settings.language.")).firstMatch.exists)
        let source = languageElement("listeningLanguages.source", in: ui)
        try reveal(source, in: ui.app.scrollViews["listeningLanguages.content"], navigationTitle: "Listening Languages", ui: ui)
        XCTAssertTrue(source.label.contains("text on this device"))
        ui.capture("listening-languages-actual-counts-dark")
    }

    func testNudgesPersistAndResetAcrossRelaunchWithoutChangingTrueStatistics() throws {
        let ui = makeDriver()
        try XCTContext.runActivity(named: "Baseline counts and native language adjustments") { _ in
            try launch(ui)
            try openFromSettings(ui)
            try expectSeededStats(ui)
            try openTuning(ui)
            try setNudge("en", to: "Less", in: ui)
            try setNudge("ta", to: "More", in: ui)
            try expectSeededStats(ui)
        }

        try XCTContext.runActivity(named: "Saved adjustments after the first relaunch") { _ in
            try launch(ui, reset: false, arguments: ["--light"])
            try openFromSettings(ui)
            try expectSeededStats(ui)
            try openTuning(ui)
            try expectNudge("ta", value: "More", in: ui)
            try expectNudge("en", value: "Less", in: ui)
            for code in ["bn", "hi", "te"] { try expectNudge(code, value: "Automatic", in: ui) }
        }

        try XCTContext.runActivity(named: "Reset every adjustment without changing listening counts") { _ in
            let content = ui.app.scrollViews["listeningLanguages.content"]
            let reset = content.buttons["listeningLanguages.reset"]
            try assertControl(reset, in: ui, content: content)
            XCTAssertTrue(reset.isEnabled)
            ui.capture("listening-languages-native-adjustments-light")
            try ui.tap(reset)
            for code in languageCodes { try expectNudge(code, value: "Automatic", in: ui) }
            XCTAssertFalse(reset.isEnabled)
            try expectSeededStats(ui)
        }

        try XCTContext.runActivity(named: "Automatic adjustments remain durable after the second relaunch") { _ in
            try launch(ui, reset: false, arguments: ["--light"])
            try openFromSettings(ui)
            try expectSeededStats(ui)
            try openTuning(ui)
            for code in languageCodes { try expectNudge(code, value: "Automatic", in: ui) }
            XCTAssertFalse(languageElement("listeningLanguages.reset", in: ui).isEnabled)
        }
    }

    func testHistoryOffKeepsStatisticsAndClearShowsNoInventedPercentagesOrLostNudges() throws {
        let ui = makeDriver()
        try launch(ui)
        try openFromSettings(ui)
        try openTuning(ui)
        try setNudge("ta", to: "More", in: ui)
        try backToSettings(ui)
        try ui.setSwitch("settings.history", to: false)
        try openSettingsDestination(ui)
        let content = ui.app.scrollViews["listeningLanguages.content"]
        let historyOff = languageElement("listeningLanguages.historyOff", in: ui)
        try reveal(historyOff, in: content, navigationTitle: "Listening Languages", ui: ui)
        XCTAssertTrue(historyOff.exists)
        try assertControl(content.buttons["listeningLanguages.enableHistory"], in: ui, content: content)
        try expectSeededStats(ui)

        try backToSettings(ui)
        try ui.openSettingsPage(.library)
        let clear = ui.app.buttons["settings.clearHistory"]
        try ui.reveal(clear, maxSwipes: 24)
        try ui.tap(clear)
        try ui.tap(ui.app.alerts["Clear Your Listening History?"].buttons["Clear History"])
        try ui.wait("Clearing must finish durably before the empty-state check") { clear.exists && !clear.isEnabled }
        try openSettingsDestination(ui)
        try expectEmptyStats(ui)
        try openTuning(ui)
        try expectNudge("ta", value: "More", in: ui)
        ui.capture("listening-languages-history-off-cleared")

        try launch(ui, reset: false)
        try selectTab("recap", in: ui)
        let entry = ui.app.buttons["recap.listeningLanguages"]
        try ui.reveal(entry, direction: .down, maxSwipes: 24)
        try ui.expectValue(entry, "No counted plays")
        try ui.tap(entry)
        try waitForLanguages(ui)
        try expectEmptyStats(ui)
        try openTuning(ui)
        try expectNudge("ta", value: "More", in: ui)
        let enableHistory = content.buttons["listeningLanguages.enableHistory"]
        try assertControl(enableHistory, in: ui, content: content)
        try ui.tap(enableHistory)
        try ui.wait("Enabling history uses the model and removes the paused notice") {
            !historyOff.exists
        }
        try expectEmptyStats(ui)
    }

    func testWelcomeAndRadioStartWithoutAnyLanguageSelection() throws {
        let ui = makeDriver()
        let arguments = ["--seed-radio-fixture", "--cache-fixture"]
        try launch(ui, showWelcome: true, arguments: arguments)
        XCTAssertFalse(ui.app.buttons["welcome.hindi"].exists)
        XCTAssertFalse(ui.app.buttons["welcome.english"].exists)
        let start = ui.app.buttons["welcome.continue"]
        try assertControl(start, in: ui)
        XCTAssertEqual(start.label, "Start Listening")
        ui.capture("welcome-automatic-learning-no-taste-form")
        try ui.tap(start)
        try ui.reveal(ui.app.buttons["welcome.youtube.notNow"])
        try ui.tap(ui.app.buttons["welcome.youtube.notNow"])
        try ui.wait("Skipping optional connection must open Home") { ui.app.buttons["home.settings"].exists }
        try launch(ui, showWelcome: true, reset: false, arguments: arguments)
        XCTAssertFalse(start.exists, "This relaunch omits skip-welcome and must retain the saved completion")
        XCTAssertFalse(ui.app.buttons["welcome.youtube.notNow"].exists)

        try selectTab("search", in: ui)
        XCTAssertFalse(ui.app.buttons["search.filter.songs"].exists)
        let radio = ui.app.buttons["search.radio.open"]
        try assertControl(radio, in: ui)
        try ui.tap(radio)
        try ui.wait("Song and artist Radio must open in its own navigation destination") {
            ui.app.navigationBars["Radio"].exists && ui.element("search.radio.content").exists
        }
        try ui.requireHittable(ui.app.searchFields["Songs or artists"])
        try ui.expectValue(ui.app.buttons["radio.search.type"], "Songs")
        XCTAssertFalse(ui.app.keyboards.firstMatch.exists)
        XCTAssertFalse(ui.element("radio.session").exists)
        let radioStart = ui.app.buttons["radio.suggestion.\(AppUIFixture.tumHiHo)"]
        try ui.reveal(radioStart)
        try assertControl(radioStart, in: ui)
        XCTAssertTrue(radioStart.isEnabled)
        XCTAssertEqual(radioStart.label, "Start Tum Hi Ho Radio, Arijit Singh")
        try ui.tap(radioStart)
        try ui.wait("One song tap must establish radio without a language selection", timeout: 30) {
            ui.element("radio.session").exists
                && ui.app.buttons["miniPlayer.open"].exists
        }
        try ui.expectLabel(ui.element("radio.session"), "Tum Hi Ho Radio")
        try ui.expectLabel(ui.element("radio.session.tuning"), "Balanced · Automatic Language")
        XCTAssertFalse(ui.element("radio.session.error").exists)
        XCTAssertFalse(ui.app.buttons["radio.tune.done"].exists, "Tuning is optional after starting")
        XCTAssertFalse(ui.app.buttons["player.close"].exists, "Starting radio must leave the Radio page visible")
        ui.capture("radio-song-start-automatic-language")
        try ui.openPlayer()
        try ui.expectCurrentTrack(AppUIFixture.tumHiHo)
        try ui.waitForAdvance(from: 0, by: 1)
        try ui.pause()
    }

    func testNativeTuningControlsRemainReachableAtLargestTextSize() throws {
        let ui = makeDriver()
        try launch(ui, arguments: ["-UIPreferredContentSizeCategoryName", UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue])
        try openFromSettings(ui)
        try openTuning(ui)
        let content = ui.app.scrollViews["listeningLanguages.content"]
        for code in languageCodes { try assertControl(content.buttons["listeningLanguages.nudge.\(code)"], in: ui, content: content) }
        try setNudge("te", to: "More", in: ui)
        try assertControl(content.buttons["listeningLanguages.reset"], in: ui, content: content)
        ui.capture("listening-languages-accessibility-xxxl")
        try expectSeededStats(ui)
    }

    func testUnclassifiedSharesIncludeEveryCountedPlayWithoutANudgeForUnknown() throws {
        let ui = makeDriver()
        // The unknown fixture preserves all 20 sessions and marks Shape of You's two plays unclassified.
        try launch(ui, arguments: ["--listening-languages-unknown"])
        try openFromSettings(ui)
        try expectSeededStats(ui, includesUnclassified: true)
        try openTuning(ui)
        XCTAssertFalse(languageElement("listeningLanguages.nudge.unclassified", in: ui).exists)
        try setNudge("en", to: "More", in: ui)
        try expectSeededStats(ui, includesUnclassified: true)
        ui.capture("listening-languages-known-and-unclassified-shares")
    }

    func testIPadUsesACenteredStatsColumnAndNativeAdjustmentMenus() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("Run this layout case on an iPad simulator.") }
        let ui = makeDriver()
        try launch(ui, arguments: ["--light"])
        try selectTab("recap", in: ui)
        try ui.tap(ui.app.buttons["recap.listeningLanguages"])
        try waitForLanguages(ui)
        try expectSeededStats(ui)
        let content = ui.app.scrollViews["listeningLanguages.content"]
        let card = languageElement("listeningLanguages.breakdown", in: ui)
        try reveal(card, in: content, navigationTitle: "Listening Languages", ui: ui)
        let window = ui.app.windows.firstMatch.frame
        XCTAssertLessThanOrEqual(card.frame.width, 961)
        XCTAssertEqual(card.frame.midX, window.midX, accuracy: 2)
        try openTuning(ui)
        for code in languageCodes { try assertControl(content.buttons["listeningLanguages.nudge.\(code)"], in: ui, content: content) }
        try setNudge("bn", to: "More", in: ui)
        try expectSeededStats(ui)
        ui.capture("listening-languages-ipad-light")
    }

    private func makeDriver() -> AppUITestDriver {
        let ui = AppUITestDriver(testCase: self, prefix: "listening-languages")
        addTeardownBlock { await ui.finish() }
        return ui
    }

    private func launch(_ ui: AppUITestDriver, showWelcome: Bool = false, reset: Bool = true, arguments: [String] = []) throws {
        ui.app.terminate()
        if UIDevice.current.userInterfaceIdiom != .pad {
            try ui.launch(skipWelcome: !showWelcome, reset: reset, additionalArguments: arguments)
            return
        }
        // iPad exposes top-level tab buttons rather than the shared driver's bottom-tab readiness target.
        XCUIDevice.shared.orientation = .portrait
        ui.app.launchArguments = ["--uitesting", "--seed-ui"] + (showWelcome ? [] : ["--skip-welcome"])
            + (reset ? ["--reset-ui"] : []) + arguments + ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        ui.app.launchEnvironment = ["GANABAJANA_TEST_STORE": ui.storeName]
        ui.app.launch()
        try ui.requireHittable(showWelcome && reset ? ui.app.buttons["welcome.continue"] : ui.app.buttons["home.settings"], timeout: 25)
    }

    private func selectTab(_ tab: String, in ui: AppUITestDriver) throws {
        if UIDevice.current.userInterfaceIdiom != .pad { try ui.selectTab(tab); return }
        if ui.app.buttons["search.dismissKeyboard"].exists { try ui.dismissSearchKeyboard() }
        try ui.tap(ui.app.buttons["tab.\(tab)"].firstMatch)
        if tab == "search" { try ui.requireHittable(ui.app.textFields["search.field"]) }
    }

    private func openFromSettings(_ ui: AppUITestDriver) throws {
        try selectTab("home", in: ui)
        let settings = ui.app.buttons["home.settings"]
        try assertControl(settings, in: ui)
        try ui.tap(settings)
        try ui.requireHittable(ui.app.buttons["settings.done"])
        try openSettingsDestination(ui)
    }

    private func openSettingsDestination(_ ui: AppUITestDriver) throws {
        try ui.openSettingsPage(.discovery)
        let form = ui.element("settings.form")
        let link = form.buttons["settings.languages"]
        try assertControl(link, in: ui, content: form, navigationTitle: SettingsPageID.discovery.title)
        XCTAssertTrue(link.label.contains("Listening Languages"))
        try ui.tap(link)
        try waitForLanguages(ui)
    }

    private func waitForLanguages(_ ui: AppUITestDriver) throws {
        let content = ui.app.scrollViews["listeningLanguages.content"]
        let window = content.staticTexts["listeningLanguages.window"]
        try ui.wait("Listening languages must open as a native navigation destination") {
            ui.app.navigationBars["Listening Languages"].exists && content.exists && window.exists
        }
        try reveal(window, in: content, navigationTitle: "Listening Languages", ui: ui)
        try ui.expectLabel(window, "Last 30 days")
    }

    private func backToSettings(_ ui: AppUITestDriver) throws {
        try ui.tap(ui.app.navigationBars["Listening Languages"].buttons.firstMatch)
        try ui.wait("Back must return to the Discovery page") { ui.app.navigationBars[SettingsPageID.discovery.title].exists }
    }

    private func openTuning(_ ui: AppUITestDriver) throws {
        let content = ui.app.scrollViews["listeningLanguages.content"]
        let disclosure = content.buttons["listeningLanguages.tune"]
        try assertControl(disclosure, in: ui, content: content)
        try ui.tap(disclosure)
        try ui.wait("Optional recommendation adjustments must expand after a tap") {
            content.buttons["listeningLanguages.nudge.bn"].exists
        }
        try ui.expectValue(disclosure, "Expanded")
    }

    private func setNudge(_ code: String, to title: String, in ui: AppUITestDriver) throws {
        let content = ui.app.scrollViews["listeningLanguages.content"]
        let menu = content.buttons["listeningLanguages.nudge.\(code)"]
        try assertControl(menu, in: ui, content: content)
        try ui.tap(menu)
        let identified = ui.app.buttons["listeningLanguages.choice.\(code).\(title.lowercased())"]
        let native = ui.app.buttons[title]
        try ui.wait("The native adjustment picker must offer \(title)") { identified.exists || native.exists }
        try ui.tap(identified.exists ? identified : native)
        try ui.expectValue(menu, title)
    }

    private func expectNudge(_ code: String, value: String, in ui: AppUITestDriver) throws {
        let menu = ui.app.scrollViews["listeningLanguages.content"].buttons["listeningLanguages.nudge.\(code)"]
        try ui.expectValue(menu, value)
    }

    private func expectSeededStats(_ ui: AppUITestDriver, includesUnclassified: Bool = false) throws {
        // The non-lazy language content exposes offscreen values; checking state must not move the viewport.
        let plays = languageElement("listeningLanguages.total.plays", in: ui)
        let songs = languageElement("listeningLanguages.total.songs", in: ui)
        try ui.expectLabel(plays, "Counted Plays")
        try ui.expectValue(plays, "20")
        try ui.expectLabel(songs, "Different Songs")
        try ui.expectValue(songs, "5")
        let hindi = languageElement("listeningLanguages.row.hi", in: ui)
        let english = languageElement("listeningLanguages.row.en", in: ui)
        try ui.expectValue(hindi, "15 plays · 3 songs, 75% of all counted plays")
        try ui.expectValue(english, includesUnclassified ? "3 plays · 1 song, 15% of all counted plays" : "5 plays · 2 songs, 25% of all counted plays")
        XCTAssertFalse(languageElement("listeningLanguages.row.ta", in: ui).exists, "A More adjustment cannot invent Tamil listening")
        let unknown = languageElement("listeningLanguages.row.unclassified", in: ui)
        if includesUnclassified {
            try ui.expectValue(unknown, "2 plays · 1 song, 10% of all counted plays")
        } else { XCTAssertFalse(unknown.exists) }
        try ui.expectLabel(languageElement("listeningLanguages.coverage", in: ui),
                            "Language identified for \(includesUnclassified ? 18 : 20) of 20 counted plays.")
    }

    private func expectEmptyStats(_ ui: AppUITestDriver) throws {
        let content = ui.app.scrollViews["listeningLanguages.content"]
        try reveal(languageElement("listeningLanguages.empty", in: ui), in: content, navigationTitle: "Listening Languages", ui: ui)
        XCTAssertFalse(languageElement("listeningLanguages.breakdown", in: ui).exists)
        XCTAssertFalse(languageElement("listeningLanguages.total.plays", in: ui).exists)
        XCTAssertFalse(languageElement("listeningLanguages.coverage", in: ui).exists)
        XCTAssertFalse(content.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "%")).firstMatch.exists)
    }

    private func languageElement(_ id: String, in ui: AppUITestDriver) -> XCUIElement {
        ui.app.scrollViews["listeningLanguages.content"].descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func reveal(_ element: XCUIElement, in content: XCUIElement, navigationTitle: String,
                        ui: AppUITestDriver) throws {
        let window = ui.app.windows.firstMatch
        let navigation = ui.app.navigationBars[navigationTitle]
        let maxDrags = 16
        var lastContext = ""
        for attempt in 0...maxDrags {
            let bounds = window.frame
            let contentBounds = content.frame.intersection(bounds)
            var top = max(contentBounds.minY, navigation.frame.maxY)
            var bottom = contentBounds.maxY
            let tabs = ui.app.tabBars.firstMatch
            if tabs.exists, usableFrame(tabs.frame), tabs.frame.intersects(contentBounds), tabs.isHittable {
                let tabFrame = tabs.frame
                if tabFrame.midY < contentBounds.midY {
                    top = max(top, tabFrame.maxY)
                } else {
                    bottom = min(bottom, tabFrame.minY)
                }
                // Rows pass beneath the glass, so the capsule's top, not its inset open button's, ends the visible area.
                let mini = ui.app.otherElements["miniPlayer.container"]
                if mini.exists, usableFrame(mini.frame), mini.frame.intersects(contentBounds) {
                    bottom = min(bottom, mini.frame.minY)
                }
            }
            let viewport = CGRect(x: contentBounds.minX, y: top, width: contentBounds.width, height: max(0, bottom - top))
            guard usableFrame(viewport) else {
                throw AppUIWorkflowFailure(message: "\(navigationTitle) must have a visible content viewport: \(viewport)")
            }
            let frame = element.exists ? element.frame : CGRect.null
            lastContext = "frame: \(frame), viewport: \(viewport)"
            if usableFrame(frame), viewport.insetBy(dx: -1e-6, dy: -1e-6).contains(frame), element.isHittable { return }
            guard attempt < maxDrags else { break }

            var movement = -viewport.height * 0.4
            if usableFrame(frame) {
                if frame.minY < viewport.minY { movement = viewport.minY - frame.minY + 8 }
                else if frame.maxY > viewport.maxY { movement = viewport.maxY - frame.maxY - 8 }
            }
            let distance = min(max(abs(movement), 14), viewport.height * 0.4)
            let startY = movement > 0 ? viewport.minY + viewport.height * 0.2 : viewport.maxY - viewport.height * 0.2
            let origin = window.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: viewport.minX + min(12, viewport.width * 0.05) - bounds.minX,
                                                  dy: startY - bounds.minY))
            let end = start.withOffset(CGVector(dx: 0, dy: movement > 0 ? distance : -distance))
            // Edge drags avoid native menu actions, and the held release prevents overshooting adjacent rows.
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        throw AppUIWorkflowFailure(message: "\(navigationTitle) could not reveal \(element) after at most \(maxDrags) drags; \(lastContext)")
    }

    private func usableFrame(_ frame: CGRect) -> Bool {
        !frame.isEmpty && !frame.isNull && [frame.minX, frame.minY, frame.maxX, frame.maxY].allSatisfy(\.isFinite)
    }

    private func assertControl(_ element: XCUIElement, in ui: AppUITestDriver,
                               content: XCUIElement? = nil, navigationTitle: String = "Listening Languages",
                               file: StaticString = #filePath, line: UInt = #line) throws {
        if let content {
            try reveal(element, in: content, navigationTitle: navigationTitle, ui: ui)
        } else {
            let frame = element.exists ? element.frame : CGRect.null
            if !usableFrame(frame) || !ui.app.windows.firstMatch.frame.contains(frame) || !element.isHittable {
                try ui.reveal(element, maxSwipes: 32)
            }
        }
        let frame = element.frame
        let window = ui.app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(frame.width + 1e-6, 44, file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.height + 1e-6, 44, file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.minX + 1e-6, window.minX, file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxX, window.maxX + 1e-6, file: file, line: line)
    }
}

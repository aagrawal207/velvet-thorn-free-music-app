import UIKit
import XCTest

@MainActor
final class GanaBajanaSettingsOrganizationUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testTransitionDefaultsAreOffAndGroupedTogether() throws {
        let ui = AppUITestDriver(testCase: self, prefix: "transition-defaults")
        addTeardownBlock { await ui.finish() }
        try ui.launch()
        try ui.openSettings()
        try ui.expectSwitch("settings.automix", isOn: false)
        let transitions = ui.app.otherElements["settings.transitions"]
        XCTAssertTrue(transitions.exists)
        XCTAssertTrue(transitions.sliders["settings.crossfade"].exists)
        XCTAssertTrue(transitions.switches["settings.automix"].exists)
        XCTAssertEqual(ui.app.sliders["settings.crossfade"].value as? String, "0 s")
        try ui.setSwitch("settings.automix", to: true)
        ui.capture("playback-transition-settings-together")
        try ui.relaunch()
        try ui.openSettings()
        try ui.expectSwitch("settings.automix", isOn: true)
        XCTAssertEqual(ui.app.sliders["settings.crossfade"].value as? String, "0 s")
    }

    func testListeningNudgesPersistWhileLibraryStorageAndHistoryRemainReachable() throws {
        let ui = AppUITestDriver(testCase: self, prefix: "settings-organization")
        addTeardownBlock { await ui.finish() }
        try ui.launch()
        try ui.openSettings()
        try ui.openSettingsPage(.library)
        try ui.reveal(ui.app.staticTexts["settings.section.library"], maxSwipes: 16)
        let storage = ui.app.buttons["settings.storage"]
        try ui.reveal(storage)
        XCTAssertGreaterThanOrEqual(storage.frame.height + 1e-6, 44)
        try ui.tap(storage)
        try ui.wait("Storage must open from the library settings") { ui.app.navigationBars["Storage"].exists }
        try ui.reveal(ui.element("storage.library.likes"), maxSwipes: 20)
        XCTAssertTrue(ui.accessibleText(ui.element("storage.library.likes")).contains("5"))
        XCTAssertTrue(ui.accessibleText(ui.element("storage.library.playlists")).contains("1"))
        try ui.tap(ui.app.navigationBars["Storage"].buttons.firstMatch)

        let clearHistory = ui.app.buttons["settings.clearHistory"]
        try ui.reveal(clearHistory, direction: .down)
        try ui.tap(clearHistory)
        let confirmation = ui.app.alerts["Clear Your Listening History?"]
        try ui.tap(confirmation.buttons["Cancel"])
        try ui.wait("Cancel must leave listening history available") {
            !confirmation.exists && clearHistory.isEnabled
        }

        try ui.openSettingsPage(.discovery)
        try ui.reveal(ui.app.staticTexts["settings.section.discovery"], maxSwipes: 16)
        let languages = ui.app.buttons["settings.languages"]
        try ui.reveal(languages)
        try ui.tap(languages)
        try ui.wait("Listening statistics must replace the manual discovery-language form") {
            ui.app.navigationBars["Listening Languages"].exists
        }
        XCTAssertFalse(ui.app.switches.matching(NSPredicate(format: "identifier BEGINSWITH %@", "settings.language.")).firstMatch.exists)
        try ui.expectMetric("listeningLanguages.total.plays", number: 20, description: "Counted Plays")
        try ui.expectMetric("listeningLanguages.total.songs", number: 5, description: "Different Songs")
        let tuning = ui.app.buttons["listeningLanguages.tune"]
        try ui.reveal(tuning)
        try ui.tap(tuning)
        try selectNudge("ta", title: "More", in: ui)
        try selectNudge("en", title: "Less", in: ui)
        try ui.expectMetric("listeningLanguages.total.plays", number: 20, description: "Counted Plays")
        XCTAssertFalse(ui.element("listeningLanguages.row.ta").exists, "A nudge must not manufacture listening statistics")
        try ui.tap(ui.app.navigationBars["Listening Languages"].buttons.firstMatch)
        try ui.reveal(languages)
        XCTAssertTrue(ui.accessibleText(languages).contains("Listening Languages"))
        ui.capture("settings-listening-language-return-navigation")

        try ui.relaunch()
        try ui.openSettings()
        try ui.expectSwitch("settings.history", isOn: true)
        try ui.reveal(ui.app.buttons["settings.clearHistory"])
        XCTAssertTrue(ui.app.buttons["settings.clearHistory"].isEnabled)
        try ui.openSettingsPage(.discovery)
        try ui.reveal(languages, maxSwipes: 16)
        try ui.tap(languages)
        try ui.reveal(tuning)
        try ui.tap(tuning)
        for (code, value) in [("ta", "More"), ("en", "Less"), ("hi", "Automatic")] {
            let menu = ui.app.buttons["listeningLanguages.nudge.\(code)"]
            try ui.reveal(menu)
            try ui.expectValue(menu, value)
        }
        try ui.expectMetric("listeningLanguages.total.plays", number: 20, description: "Counted Plays")
        try ui.expectMetric("listeningLanguages.total.songs", number: 5, description: "Different Songs")
        try ui.tap(ui.app.navigationBars["Listening Languages"].buttons.firstMatch)
        try ui.tap(ui.app.buttons["settings.done"])
        try ui.selectTab("library")
        try ui.openPlaylist(named: AppUIFixture.seededPlaylist)
        XCTAssertTrue(ui.app.buttons["library.playlist.play"].isEnabled)
    }

    func testHomeCustomizationIsInSettingsAndCanRestoreHiddenHomeSections() throws {
        let ui = AppUITestDriver(testCase: self, prefix: "settings-home-customization")
        addTeardownBlock { await ui.finish() }
        try ui.launch()
        XCTAssertFalse(ui.app.buttons["home.customize"].exists)
        XCTAssertFalse(ui.app.buttons["home.customize.empty"].exists)
        try ui.openSettings()
        try ui.openSettingsPage(.discovery)
        let customize = ui.app.buttons["settings.customizeHome"]
        try ui.reveal(customize, maxSwipes: 24)
        XCTAssertGreaterThanOrEqual(customize.frame.height + 1e-6, 44)
        try ui.tap(customize)
        try ui.wait("Settings must retain Home customization") { ui.app.navigationBars["Customize Home"].exists }
        for section in ["recentlyPlayed", "madeForYou", "newReleases", "becauseYouLike", "charts", "discovery", "superLiked"] {
            try ui.setSwitch("home.customization.show.\(section)", to: false)
        }
        try ui.tap(ui.app.navigationBars["Customize Home"].buttons.firstMatch)
        try ui.tap(ui.app.buttons["settings.done"])
        try ui.wait("Hiding all sections must leave an honest Home empty state") { ui.element("home.empty.customized").exists }
        XCTAssertFalse(ui.app.buttons["home.customize"].exists)
        XCTAssertFalse(ui.app.buttons["home.customize.empty"].exists)
        try ui.requireHittable(ui.app.buttons["home.settings"])
        ui.capture("home-settings-only-customization-entry")

        try ui.relaunch()
        try ui.wait("Hidden Home sections must remain hidden across relaunch") { ui.element("home.empty.customized").exists }
        try ui.openSettings()
        try ui.openSettingsPage(.discovery)
        try ui.reveal(customize, maxSwipes: 24)
        try ui.tap(customize)
        let reset = ui.app.buttons["home.customization.reset"]
        try ui.reveal(reset, maxSwipes: 24)
        try ui.tap(reset)
        try ui.expectSwitch("home.customization.show.recentlyPlayed", isOn: true)
        try ui.tap(ui.app.navigationBars["Customize Home"].buttons.firstMatch)
        try ui.tap(ui.app.buttons["settings.done"])
        try ui.wait("Settings must be able to restore Home without a second Home shortcut") {
            ui.element("home.group.recentlyPlayed").exists && !ui.element("home.empty.customized").exists
        }
    }

    func testSettingsRowsKeepCompactNativeTargetsAndConsistentDescriptionGaps() throws {
        let ui = AppUITestDriver(testCase: self, prefix: "settings-spacing")
        addTeardownBlock { await ui.finish() }
        try ui.launch()
        try ui.openSettings()
        // Home's scroll containers remain in the accessibility tree behind the presented Settings form.
        let form = ui.element("settings.form")
        try ui.requireHittable(form)
        // Rows never carry description text; a row's note, when it has one, sits in its group's footer.
        let rows: [(id: String, section: String, hasNote: Bool)] = [
            ("settings.automix", "playback.transitions", true), ("settings.gapless", "playback.transitions", false),
            ("settings.autoplay", "playback.transitions", false),
            ("settings.history", "library.history", true), ("settings.customizeHome", "discovery.home", false),
            ("settings.encryptedDNS", "account.connection", true), ("settings.remoteFallback", "account.connection", true),
            ("settings.tipJar", "about.breezy", false), ("settings.support", "about.breezy", false),
            ("settings.privacy", "about.breezy", false), ("settings.acknowledgements", "about.credits", false)
        ]
        var rowHeights: [String: CGFloat] = [:]
        for (id, section, hasNote) in rows {
            try XCTContext.runActivity(named: "Check Settings row \(id)") { _ in
                try ui.openSettingsPage(containing: id)
                // Measure the identified switch row, not its potentially zero-bounds virtual Toggle child.
                let isSwitch = ["settings.automix", "settings.gapless", "settings.autoplay", "settings.history",
                                "settings.encryptedDNS", "settings.remoteFallback"].contains(id)
                let row = isSwitch ? form.switches.matching(identifier: id).firstMatch : form.buttons[id]
                try revealSettingsRow(row, description: nil, in: form, ui: ui)
                let frame = row.frame
                XCTAssertGreaterThanOrEqual(frame.height + 1e-6, 44, id)
                XCTAssertLessThanOrEqual(frame.height, 52, "Rows keep one 44-point shape without description text: \(id)")
                rowHeights[id] = frame.height
                let detail = form.staticTexts["\(id).description"]
                if hasNote {
                    try revealSettingsRow(detail, description: nil, in: form, ui: ui)
                    let footer = form.otherElements["settings.footer.\(section)"]
                    // A footer cell with one note reports that note with the whole cell's frame, so the footer
                    // container carries the geometry and the note is checked by membership.
                    XCTAssertTrue(footer.exists && footer.staticTexts[detail.identifier].exists,
                                  "\(id) explains itself in the \(section) footer")
                    XCTAssertFalse(detail.label.isEmpty)
                    XCTAssertEqual(footer.frame.minX - form.frame.minX, 36, accuracy: 1, "Notes align with the row content inset")
                } else {
                    XCTAssertFalse(detail.exists, "\(id) needs no note")
                }
            }
        }
        // The Automix switch shares its cell with a hairline divider, so heights compare at whole points.
        let distinctHeights = Set(rowHeights.values.map { $0.rounded() })
        XCTAssertEqual(distinctHeights.count, 1, "Every checked row shares one height at the default text size: \(rowHeights)")
        ui.capture("settings-consistent-native-row-spacing")
    }

    func testLargeTextKeepsDisclosuresAndDestructiveActionsReadable() throws {
        let ui = AppUITestDriver(testCase: self, prefix: "settings-spacing-large-text")
        addTeardownBlock { await ui.finish() }
        try ui.launch(additionalArguments: ["--light", "-UIPreferredContentSizeCategoryName",
                                            UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue])
        try ui.openSettings()
        let form = ui.element("settings.form")
        for (id, disclosure) in [("settings.history", "device backups"), ("settings.releaseAlerts", "background"),
                                  ("settings.encryptedDNS", "Cloudflare"), ("settings.remoteFallback", "including headers")] {
            try ui.openSettingsPage(containing: id)
            let detail = ui.app.staticTexts["\(id).description"]
            // Home's scrollers stay in the tree behind the sheet at this size, so drags stay on the page's form.
            try revealSettingsRow(detail, description: nil, in: form, ui: ui, maxDrags: 30)
            XCTAssertTrue(detail.label.contains(disclosure), "The full disclosure must remain available for \(id)")
            let bounds = ui.app.windows.firstMatch.frame
            XCTAssertGreaterThan(detail.frame.height, 20)
            XCTAssertGreaterThanOrEqual(detail.frame.minX + 1e-6, bounds.minX)
            XCTAssertLessThanOrEqual(detail.frame.maxX, bounds.maxX + 1e-6)
        }
        try ui.openSettingsPage(.library)
        let clear = ui.app.buttons["settings.clearHistory"]
        try revealSettingsRow(clear, description: nil, in: form, ui: ui, maxDrags: 30)
        XCTAssertGreaterThanOrEqual(clear.frame.height + 1e-6, 44)
        XCTAssertTrue(clear.label.contains("Clear Listening History"))
        try ui.tap(clear)
        let confirmation = ui.app.alerts["Clear Your Listening History?"]
        try ui.requireHittable(confirmation.buttons["Cancel"])
        XCTAssertTrue(confirmation.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "recommendation adjustments stay")).firstMatch.exists)
        try ui.tap(confirmation.buttons["Cancel"])
        XCTAssertTrue(clear.isEnabled)
        try ui.openSettingsPage(.playback)
        try revealSettingsRow(ui.app.sliders["settings.crossfade"], description: nil, in: form, ui: ui, maxDrags: 30)
        XCTAssertGreaterThanOrEqual(ui.app.sliders["settings.crossfade"].frame.width + 1e-6, 44)
        ui.capture("settings-readable-disclosures-accessibility-xxxl")
    }

    private func revealSettingsRow(_ row: XCUIElement, description: XCUIElement?, in form: XCUIElement,
                                   ui: AppUITestDriver, maxDrags: Int = 8) throws {
        let targets = [row] + (description.map { [$0] } ?? [])
        let window = ui.app.windows.firstMatch
        let navigation = ui.settingsNavigationBar
        var lastContext = ""
        for attempt in 0...maxDrags {
            let bounds = window.frame
            let formBounds = form.frame.intersection(bounds)
            let top = max(formBounds.minY, navigation.frame.maxY)
            let viewport = CGRect(x: formBounds.minX, y: top, width: formBounds.width,
                                  height: max(0, formBounds.maxY - top))
            guard !viewport.isEmpty, !viewport.isNull,
                  [viewport.minX, viewport.minY, viewport.maxX, viewport.maxY].allSatisfy(\.isFinite) else {
                throw AppUIWorkflowFailure(message: "Settings must have a visible form viewport: \(viewport)")
            }
            let frames = targets.map { $0.exists ? $0.frame : CGRect.null }
            let laidOutFrames = frames.filter {
                !$0.isEmpty && !$0.isNull && [$0.minX, $0.minY, $0.maxX, $0.maxY].allSatisfy(\.isFinite)
            }
            lastContext = "frames: \(frames), viewport: \(viewport)"
            if laidOutFrames.count == targets.count,
               frames.allSatisfy({ viewport.insetBy(dx: -1e-6, dy: -1e-6).contains($0) }),
               targets.allSatisfy(\.isHittable) { return }
            guard attempt < maxDrags else { break }

            let targetBounds = laidOutFrames.reduce(CGRect.null) { $0.union($1) }
            var movement = -viewport.height * 0.4
            if !targetBounds.isNull {
                if targetBounds.minY < viewport.minY {
                    movement = viewport.minY - targetBounds.minY + 8
                } else if targetBounds.maxY > viewport.maxY {
                    movement = viewport.maxY - targetBounds.maxY - 8
                }
            }
            let distance = min(max(abs(movement), 14), viewport.height * 0.4)
            let startY = movement > 0 ? viewport.minY + viewport.height * 0.2 : viewport.maxY - viewport.height * 0.2
            let origin = window.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: viewport.minX + min(12, viewport.width * 0.05) - bounds.minX,
                                                  dy: startY - bounds.minY))
            let end = start.withOffset(CGVector(dx: 0, dy: movement > 0 ? distance : -distance))
            // Edge drags avoid toggling a switch; the held release prevents momentum from skipping a row.
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        throw AppUIWorkflowFailure(message: "Settings row \(row.identifier) and its description must be fully visible after at most \(maxDrags) drags; \(lastContext)")
    }

    private func selectNudge(_ code: String, title: String, in ui: AppUITestDriver) throws {
        let menu = ui.app.buttons["listeningLanguages.nudge.\(code)"]
        try ui.reveal(menu)
        XCTAssertGreaterThanOrEqual(menu.frame.height + 1e-6, 44)
        try ui.tap(menu)
        let identified = ui.app.buttons["listeningLanguages.choice.\(code).\(title.lowercased())"]
        let native = ui.app.buttons[title]
        try ui.wait("The native adjustment picker must offer \(title)") { identified.exists || native.exists }
        try ui.tap(identified.exists ? identified : native)
        try ui.expectValue(menu, title)
    }
}

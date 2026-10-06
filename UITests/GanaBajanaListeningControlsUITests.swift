import UIKit
import XCTest

@MainActor
final class GanaBajanaListeningControlsUITests: XCTestCase {
    private let shuffleChoices = ["Random", "Fewer Repeats"]
    private let discoveryChoices = ["More Familiar", "Balanced", "More New"]

    override func setUpWithError() throws { continueAfterFailure = false }

    func testFewerRepeatsChoiceSurvivesTurningHistoryOffAndOn() throws {
        let ui = makeDriver()
        try launch(ui)
        var form = try openSettings(ui)
        // Selecting the default exercises the same native menu path as any other saved choice.
        try choose("Fewer Repeats", from: "Fewer Repeats", picker: "settings.shuffleStyle", choices: shuffleChoices, in: form, ui: ui)
        try setSwitch("settings.history", to: false, in: form, ui: ui)
        try expectHistoryOffShuffleNote(in: form, ui: ui)
        try expectHistoryPreserved(in: form, ui: ui)

        try launch(ui, reset: false)
        form = try openSettings(ui)
        try choose("Fewer Repeats", from: "Fewer Repeats", picker: "settings.shuffleStyle", choices: shuffleChoices, in: form, ui: ui)
        try expectHistoryOffShuffleNote(in: form, ui: ui)
        try setSwitch("settings.history", to: true, in: form, ui: ui)

        try launch(ui, reset: false)
        form = try openSettings(ui)
        try choose("Fewer Repeats", from: "Fewer Repeats", picker: "settings.shuffleStyle", choices: shuffleChoices, in: form, ui: ui)
        let note = form.staticTexts["settings.shuffleStyle.description"]
        try reveal([note], in: form, ui: ui)
        XCTAssertTrue(note.label.contains("7 days of saved plays"))
        try ui.openSettingsPage(.library)
        let history = form.switches.matching(identifier: "settings.history").firstMatch
        try reveal([history], in: form, ui: ui)
        try ui.expectValue(history, "1")
    }

    func testNativeListeningChoicesPersistAndResetWhileHistoryStaysOff() throws {
        let ui = makeDriver()
        try launch(ui)
        var form = try openSettings(ui)
        try setSwitch("settings.gapless", to: false, in: form, ui: ui)
        try setSwitch("settings.autoplay", to: false, in: form, ui: ui)

        try ui.openSettingsPage(.playback)
        let shuffle = form.buttons["settings.shuffleStyle"]
        let shuffleNote = form.staticTexts["settings.shuffleStyle.description"]
        try reveal([shuffle], in: form, ui: ui)
        try ui.expectValue(shuffle, "Fewer Repeats")
        try reveal([shuffleNote], in: form, ui: ui)
        XCTAssertTrue(shuffleNote.label.contains("7 days of saved plays"))
        XCTAssertTrue(shuffleNote.label.contains("next shuffle"))
        XCTAssertTrue(shuffleNote.label.contains("current queue stays the same"))
        try assertFooterNote(shuffleNote, explains: shuffle, section: "playback.shuffle", in: form, ui: ui)

        try setSwitch("settings.history", to: false, in: form, ui: ui)
        try choose("Random", from: "Fewer Repeats", picker: "settings.shuffleStyle", choices: shuffleChoices, in: form, ui: ui)
        try expectHistoryOffShuffleNote(in: form, ui: ui)
        try expectHistoryPreserved(in: form, ui: ui)
        try choose("Light", from: "Dark", picker: "settings.appearance", choices: ["System", "Dark", "Light"], in: form, ui: ui)
        try choose("More Familiar", from: "Balanced", picker: "settings.discoveryFamiliarity", choices: discoveryChoices, in: form, ui: ui)
        try ui.openSettingsPage(.discovery)
        let discovery = form.buttons["settings.discoveryFamiliarity"]
        let discoveryNote = form.staticTexts["settings.discoveryFamiliarity.description"]
        try reveal([discoveryNote], in: form, ui: ui)
        XCTAssertTrue(discoveryNote.label.contains("new Home recommendations and future mixes"))
        XCTAssertTrue(discoveryNote.label.contains("Existing mixes keep their songs"))
        try assertFooterNote(discoveryNote, explains: discovery, section: "discovery.home", in: form, ui: ui)
        ui.capture("listening-controls-more-familiar-light")

        try launch(ui, reset: false)
        form = try openSettings(ui)
        try expectOrdinaryPlayback(in: form, ui: ui)
        // History being off must not erase an explicit Random choice across relaunch.
        try choose("Random", from: "Random", picker: "settings.shuffleStyle", choices: shuffleChoices, in: form, ui: ui)
        try expectHistoryOffShuffleNote(in: form, ui: ui)
        try expectHistoryPreserved(in: form, ui: ui)
        try choose("Light", from: "Light", picker: "settings.appearance", choices: ["System", "Dark", "Light"], in: form, ui: ui)
        try choose("More New", from: "More Familiar", picker: "settings.discoveryFamiliarity", choices: discoveryChoices, in: form, ui: ui)
        ui.capture("listening-controls-more-new-after-relaunch")

        try launch(ui, reset: false)
        form = try openSettings(ui)
        try choose("Fewer Repeats", from: "Random", picker: "settings.shuffleStyle", choices: shuffleChoices, in: form, ui: ui)
        try expectHistoryPreserved(in: form, ui: ui)
        try choose("Balanced", from: "More New", picker: "settings.discoveryFamiliarity", choices: discoveryChoices, in: form, ui: ui)

        try launch(ui, reset: false)
        form = try openSettings(ui)
        try expectOrdinaryPlayback(in: form, ui: ui)
        try choose("Fewer Repeats", from: "Fewer Repeats", picker: "settings.shuffleStyle", choices: shuffleChoices, in: form, ui: ui)
        try expectHistoryOffShuffleNote(in: form, ui: ui)
        try expectHistoryPreserved(in: form, ui: ui)
        try choose("Light", from: "Light", picker: "settings.appearance", choices: ["System", "Dark", "Light"], in: form, ui: ui)
        try choose("Balanced", from: "Balanced", picker: "settings.discoveryFamiliarity", choices: discoveryChoices, in: form, ui: ui)
    }

    func testIconLabeledSettingsKeepSixSectionsAndNativeTargetsAtLargestTextSize() throws {
        let ui = makeDriver()
        try launch(ui, arguments: ["--light", "-UIPreferredContentSizeCategoryName",
                                   UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue])
        let form = try openSettings(ui)
        // Each page's first group header carries the section identifier; the page title names the section.
        let firstGroupTitles = ["playback": "Sound", "library": "iCloud", "appearance": "Theme",
                                "discovery": "Home and Mixes", "account": "YouTube", "about": "Velvet Thorn"]
        let rows: [(section: String, controls: [(id: String, title: String, type: XCUIElement.ElementType)])] = [
            ("playback", [("settings.audioQuality", "Audio Quality", .button), ("settings.equalizer", "Equalizer", .button),
                          ("settings.normalize", "Normalize Volume", .switch),
                          ("settings.crossfade", "Crossfade", .slider), ("settings.automix", "Automix", .switch),
                          ("settings.gapless", "Gapless Playback", .switch), ("settings.autoplay", "Autoplay", .switch),
                          ("settings.playerSwipeUp", "Swipe Up on the Player", .button),
                          ("settings.sponsorBlock", "Skip Non-Music Sections", .switch),
                          ("settings.shuffleStyle", "Shuffle Order", .button)]),
            ("library", [("settings.icloud", "iCloud Sync", .button), ("settings.storage", "Storage & Cached Songs", .button),
                         ("settings.history", "Save Listening History", .switch),
                         ("settings.clearHistory", "Clear Listening History", .button)]),
            ("appearance", [("settings.appearance", "Appearance", .button), ("settings.accent", "Accent Color", .button)]),
            ("discovery", [("settings.discoveryFamiliarity", "Discovery Balance", .button), ("settings.customizeHome", "Customize Home", .button),
                           ("settings.languages", "Listening Languages", .button), ("settings.genres", "Listening Genres", .button),
                           ("settings.following", "Following", .any),
                           ("settings.releaseAlerts", "New Release Alerts", .switch)]),
            ("account", [("settings.youtubeSignIn", "Sign In to YouTube", .button), ("settings.encryptedDNS", "Encrypted DNS", .switch),
                         ("settings.remoteFallback", "Remote Playback Fallback", .switch)]),
            ("about", [("settings.tipJar", "Support Development", .button), ("settings.support", "Help & Feedback", .button),
                       ("settings.privacy", "Privacy Policy", .button), ("settings.version", "Version", .any),
                       ("settings.provider.catalog", "Catalog", .button),
                       ("settings.provider.audio", "On-Device Audio Lookup", .button), ("settings.provider.lyrics", "Lyrics", .button),
                       ("settings.acknowledgements", "Acknowledgements", .button)])
        ]
        var observedSections = Set<String>()
        for (section, controls) in rows {
            let page = try XCTUnwrap(SettingsPageID(rawValue: section))
            try ui.returnToSettingsRoot()
            try assertControl(form.buttons[page.rowID], title: page.title, in: form, ui: ui)
            try ui.openSettingsPage(page)
            let header = form.staticTexts[page.sectionID]
            try reveal([header], in: form, ui: ui)
            XCTAssertEqual(header.label.lowercased(), firstGroupTitles[section]?.lowercased())
            observedSections.insert(header.identifier)
            XCTAssertEqual(form.staticTexts.matching(identifier: header.identifier).count, 1)
            for (id, title, type) in controls {
                let row = form.descendants(matching: type).matching(identifier: id).firstMatch
                try assertControl(row, title: title, in: form, ui: ui)
                if id == "settings.shuffleStyle" {
                    try choose("Random", from: "Fewer Repeats", picker: id, choices: shuffleChoices, in: form, ui: ui)
                    try assertControl(row, title: title, in: form, ui: ui)
                } else if id == "settings.discoveryFamiliarity" {
                    try choose("More New", from: "Balanced", picker: id, choices: discoveryChoices, in: form, ui: ui)
                    try assertControl(row, title: title, in: form, ui: ui)
                }
            }
            XCTAssertFalse(form.descendants(matching: .any)["settings.trailingTime"].exists, "Right time label has no Settings row")
            if section == "appearance", form.buttons["settings.appIcon"].exists {
                try assertControl(form.buttons["settings.appIcon"], title: "App Icon", in: form, ui: ui)
            }
            // Every explanation lives in a group footer; on Appearance only the Player group needs one.
            let footers = form.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH %@", "settings.footer.\(section)"))
            if section == "appearance" {
                for _ in 0..<6 where footers.count == 0 { try scrollForm(form, ui: ui, fraction: 0.4) }
                XCTAssertEqual(footers.allElementsBoundByIndex.map(\.identifier), ["settings.footer.appearance.player"])
            } else {
                // Accessibility-size footers can exceed the viewport, so existence after a short scroll is the check.
                for _ in 0..<6 where footers.count == 0 { try scrollForm(form, ui: ui, fraction: 0.4) }
                XCTAssertGreaterThan(footers.count, 0, "The \(section) page ends its groups with footers")
                XCTAssertFalse(footers.firstMatch.staticTexts.allElementsBoundByIndex.isEmpty, "The \(section) footer carries its notes")
            }
            ui.capture("settings-icon-rows-\(section)-accessibility-xxxl")
        }
        XCTAssertEqual(observedSections, Set(SettingsPageID.allCases.map(\.sectionID)))

        let acknowledgements = form.buttons["settings.acknowledgements"]
        try reveal([acknowledgements], in: form, ui: ui)
        try ui.tap(acknowledgements)
        try ui.wait("The icon-labeled Acknowledgements row must retain native navigation") {
            ui.app.navigationBars["Acknowledgements"].exists
        }
    }

    private func makeDriver() -> AppUITestDriver {
        let ui = AppUITestDriver(testCase: self, prefix: "listening-controls")
        addTeardownBlock { await ui.finish() }
        return ui
    }

    private func launch(_ ui: AppUITestDriver, reset: Bool = true, arguments: [String] = []) throws {
        ui.app.terminate()
        if UIDevice.current.userInterfaceIdiom != .pad {
            try ui.launch(reset: reset, additionalArguments: arguments)
            return
        }
        // iPad exposes top tab buttons instead of the shared driver's bottom-tab readiness target.
        XCUIDevice.shared.orientation = .portrait
        ui.app.launchArguments = ["--uitesting", "--seed-ui", "--skip-welcome"] + (reset ? ["--reset-ui"] : [])
            + arguments + ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        ui.app.launchEnvironment = ["GANABAJANA_TEST_STORE": ui.storeName]
        ui.app.launch()
        try ui.requireHittable(ui.app.buttons["home.settings"], timeout: 25)
    }

    private func openSettings(_ ui: AppUITestDriver) throws -> XCUIElement {
        try ui.tap(ui.app.buttons["home.settings"])
        try ui.requireHittable(ui.app.buttons["settings.done"])
        let form = ui.element("settings.form")
        try ui.wait("Settings must expose its own form") { form.exists }
        return form
    }

    private func choose(_ choice: String, from previous: String, picker id: String, choices: [String],
                        in form: XCUIElement, ui: AppUITestDriver) throws {
        try ui.openSettingsPage(containing: id)
        let picker = form.buttons[id]
        try reveal([picker], in: form, ui: ui)
        XCTAssertGreaterThanOrEqual(picker.frame.height + 1e-6, 44)
        XCTAssertGreaterThanOrEqual(picker.frame.width + 1e-6, 44)
        try ui.expectValue(picker, previous)
        try ui.tap(picker)
        // Picker options live in the native overlay, outside settings.form.
        for title in choices {
            let option = ui.app.buttons[title]
            try ui.requireHittable(option)
            XCTAssertTrue(option.isEnabled)
            let selected = option.isSelected || (option.value as? String) == "1"
            XCTAssertEqual(selected, title == previous, "The native \(id) menu must check only \(previous)")
        }
        let option = ui.app.buttons[choice]
        try ui.tap(option)
        try ui.wait("Choosing \(choice) must dismiss the native menu") { !option.exists }
        try ui.expectValue(picker, choice)
    }

    private func setSwitch(_ id: String, to enabled: Bool, in form: XCUIElement, ui: AppUITestDriver) throws {
        try ui.openSettingsPage(containing: id)
        let row = form.switches.matching(identifier: id).firstMatch
        try reveal([row], in: form, ui: ui)
        let value = try XCTUnwrap(row.value as? String)
        XCTAssertTrue(value == "0" || value == "1", "\(id) must expose native Toggle state")
        if value != (enabled ? "1" : "0") {
            let native = row.switches.firstMatch
            let frame = native.exists ? native.frame : .null
            // A virtual native Toggle child can have zero bounds; its visible parent still owns the row tap.
            if usableFrame(frame), row.frame.contains(frame), native.isHittable { try ui.tap(native) }
            else { try ui.tap(row) }
        }
        try ui.expectValue(row, enabled ? "1" : "0")
    }

    private func expectOrdinaryPlayback(in form: XCUIElement, ui: AppUITestDriver) throws {
        try ui.openSettingsPage(.playback)
        let crossfade = form.sliders["settings.crossfade"]
        try reveal([crossfade], in: form, ui: ui)
        try ui.expectValue(crossfade, "0 s")
        for (id, enabled) in [("settings.automix", false), ("settings.gapless", false),
                              ("settings.autoplay", false), ("settings.normalize", true)] {
            let row = form.switches.matching(identifier: id).firstMatch
            try reveal([row], in: form, ui: ui)
            try ui.expectValue(row, enabled ? "1" : "0")
        }
    }

    private func expectHistoryPreserved(in form: XCUIElement, ui: AppUITestDriver) throws {
        try ui.openSettingsPage(.library)
        let history = form.switches.matching(identifier: "settings.history").firstMatch
        try reveal([history], in: form, ui: ui)
        try ui.expectValue(history, "0")
        let clear = form.buttons["settings.clearHistory"]
        try reveal([clear], in: form, ui: ui)
        XCTAssertTrue(clear.isEnabled, "Changing listening controls must retain existing history")
    }

    private func expectHistoryOffShuffleNote(in form: XCUIElement, ui: AppUITestDriver) throws {
        try ui.openSettingsPage(.playback)
        let note = form.staticTexts["settings.shuffleStyle.description"]
        try reveal([note], in: form, ui: ui)
        XCTAssertTrue(note.label.contains("random while Save listening history is off"))
        XCTAssertTrue(note.label.contains("Your choice is saved"))
        XCTAssertTrue(note.label.contains("without changing the current queue"))
    }

    private func assertControl(_ row: XCUIElement, title: String, in form: XCUIElement, ui: AppUITestDriver,
                               file: StaticString = #filePath, line: UInt = #line) throws {
        try reveal([row], in: form, ui: ui)
        XCTAssertGreaterThanOrEqual(row.frame.height + 1e-6, 44, title, file: file, line: line)
        XCTAssertGreaterThanOrEqual(row.frame.width + 1e-6, 44, title, file: file, line: line)
        XCTAssertGreaterThanOrEqual(row.frame.minX + 1e-6, form.frame.minX, title, file: file, line: line)
        XCTAssertLessThanOrEqual(row.frame.maxX, form.frame.maxX + 1e-6, title, file: file, line: line)
        XCTAssertTrue(row.label.contains(title), "The accessible row must retain its text label", file: file, line: line)
        if row.elementType == .button {
            // Native menu/link buttons can sit inside the named row's content insets and expose image metadata.
            XCTAssertEqual(form.buttons.matching(identifier: row.identifier).count, 1, title, file: file, line: line)
            for native in row.buttons.allElementsBoundByIndex {
                XCTAssertGreaterThanOrEqual(native.frame.width + 1e-6, 44, title, file: file, line: line)
                XCTAssertGreaterThanOrEqual(native.frame.height + 1e-6, 44, title, file: file, line: line)
                XCTAssertTrue(row.frame.insetBy(dx: -1, dy: -1).contains(native.frame), title, file: file, line: line)
                XCTAssertTrue(native.label.isEmpty || native.label == row.label, title, file: file, line: line)
            }
        } else if row.elementType == .staticText {
            // Combined informational rows can expose image metadata while retaining one named, noninteractive value.
            XCTAssertEqual(row.label, title, file: file, line: line)
            XCTAssertEqual(row.buttons.count, 0, "Informational icons must not add an action", file: file, line: line)
        }
    }

    /// A row's note lives in its section footer: below every row of the section, aligned with the row content
    /// inset, and never inside the row it explains.
    private func assertFooterNote(_ note: XCUIElement, explains row: XCUIElement, section: String,
                                  in form: XCUIElement, ui: AppUITestDriver,
                                  file: StaticString = #filePath, line: UInt = #line) throws {
        let footer = form.otherElements["settings.footer.\(section)"]
        try reveal([note], in: form, ui: ui)
        XCTAssertTrue(footer.exists, "The \(section) footer exists", file: file, line: line)
        // A footer cell with one note reports that note with the whole cell's frame, so the footer container
        // carries the geometry and the note is checked by membership.
        XCTAssertTrue(footer.staticTexts[note.identifier].exists, "\(note.identifier) sits in its section footer", file: file, line: line)
        XCTAssertEqual(footer.frame.minX - form.frame.minX, 36, accuracy: 1, "Notes align with the row content inset", file: file, line: line)
        try reveal([row], in: form, ui: ui)
        XCTAssertGreaterThanOrEqual(row.frame.height + 1e-6, 44, file: file, line: line)
        XCTAssertLessThanOrEqual(row.frame.height, 52, "Rows carry no description text", file: file, line: line)
        XCTAssertFalse(row.frame.intersects(footer.frame), "The note is outside the row", file: file, line: line)
    }

    private func reveal(_ targets: [XCUIElement], in form: XCUIElement, ui: AppUITestDriver) throws {
        let window = ui.app.windows.firstMatch
        let navigation = ui.settingsNavigationBar
        let maxDrags = 16
        var lastContext = ""
        for attempt in 0...maxDrags {
            let bounds = window.frame
            let formBounds = form.frame.intersection(bounds)
            let top = max(formBounds.minY, navigation.frame.maxY)
            let viewport = CGRect(x: formBounds.minX, y: top, width: formBounds.width,
                                  height: max(0, formBounds.maxY - top))
            guard usableFrame(viewport) else { throw AppUIWorkflowFailure(message: "Settings needs a visible form viewport: \(viewport)") }
            let frames = targets.map { $0.exists ? $0.frame : CGRect.null }
            lastContext = "frames: \(frames), viewport: \(viewport)"
            if frames.allSatisfy(usableFrame), frames.allSatisfy({ viewport.insetBy(dx: -1e-6, dy: -1e-6).contains($0) }),
               targets.allSatisfy(\.isHittable) { return }
            guard attempt < maxDrags else { break }

            let targetBounds = frames.filter(usableFrame).reduce(CGRect.null) { $0.union($1) }
            var movement = -viewport.height * 0.4
            if !targetBounds.isNull {
                if targetBounds.minY < viewport.minY { movement = viewport.minY - targetBounds.minY + 8 }
                else if targetBounds.maxY > viewport.maxY { movement = viewport.maxY - targetBounds.maxY - 8 }
            }
            // Short edge motions can stay below the native iPad pan threshold without moving the form.
            let distance = min(max(abs(movement), 44), viewport.height * 0.4)
            let startY = movement > 0 ? viewport.minY + viewport.height * 0.2 : viewport.maxY - viewport.height * 0.2
            let origin = window.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: viewport.minX + min(12, viewport.width * 0.05) - bounds.minX,
                                                  dy: startY - bounds.minY))
            let end = start.withOffset(CGVector(dx: 0, dy: movement > 0 ? distance : -distance))
            // Form-edge drags avoid switches and sliders; the held release keeps lazy rows from being skipped.
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        throw AppUIWorkflowFailure(message: "Settings targets \(targets.map(\.identifier)) were not visible after \(maxDrags) drags; \(lastContext)")
    }

    /// One slow edge drag that moves the form up by a fraction of its viewport.
    private func scrollForm(_ form: XCUIElement, ui: AppUITestDriver, fraction: CGFloat) throws {
        let window = ui.app.windows.firstMatch
        let bounds = window.frame
        let formBounds = form.frame.intersection(bounds)
        let top = max(formBounds.minY, ui.settingsNavigationBar.frame.maxY)
        let viewport = CGRect(x: formBounds.minX, y: top, width: formBounds.width, height: max(0, formBounds.maxY - top))
        guard usableFrame(viewport) else { throw AppUIWorkflowFailure(message: "Settings needs a visible form viewport: \(viewport)") }
        let origin = window.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: viewport.minX + min(12, viewport.width * 0.05) - bounds.minX,
                                              dy: viewport.maxY - viewport.height * 0.2 - bounds.minY))
        let end = start.withOffset(CGVector(dx: 0, dy: -viewport.height * fraction))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
    }

    private func usableFrame(_ frame: CGRect) -> Bool {
        !frame.isEmpty && !frame.isNull && [frame.minX, frame.minY, frame.maxX, frame.maxY].allSatisfy(\.isFinite)
    }
}

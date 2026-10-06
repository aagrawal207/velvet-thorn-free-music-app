import UIKit
import XCTest

/// Settings visual system: uniform rows, footer descriptions, system section spacing and a stable iCloud status slot.
@MainActor
final class GanaBajanaSettingsLayoutUITests: XCTestCase {
    /// One group on a Settings page: its header, its rows with the accessibility type each exposes, and its footer.
    private struct Group {
        let header: String
        let rows: [(id: String, type: XCUIElement.ElementType)]
        let footer: String?
    }

    /// Every page and group in on-screen order. The first header of each page carries `settings.section.<page>`.
    private static let pages: [(page: SettingsPageID, groups: [Group])] = [
        (.playback, [
            Group(header: "settings.section.playback", rows: [("settings.audioQuality", .button), ("settings.equalizer", .button),
                                                               ("settings.normalize", .switch)], footer: "settings.footer.playback.sound"),
            Group(header: "settings.group.playback.transitions", rows: [("settings.crossfade", .slider), ("settings.automix", .switch),
                                                                         ("settings.gapless", .switch), ("settings.autoplay", .switch)],
                  footer: "settings.footer.playback.transitions"),
            Group(header: "settings.group.playback.player", rows: [("settings.playerSwipeUp", .button), ("settings.sponsorBlock", .switch)],
                  footer: "settings.footer.playback.player"),
            Group(header: "settings.group.playback.shuffle", rows: [("settings.shuffleStyle", .button)], footer: "settings.footer.playback.shuffle"),
        ]),
        (.library, [
            Group(header: "settings.section.library", rows: [("settings.icloud", .button)], footer: "settings.footer.library.icloud"),
            Group(header: "settings.group.library.downloads", rows: [("settings.downloadsCellular", .switch), ("settings.autoDownloadLiked", .button)],
                  footer: "settings.footer.library.downloads"),
            Group(header: "settings.group.library.storage", rows: [("settings.storage", .button)], footer: nil),
            Group(header: "settings.group.library.history", rows: [("settings.history", .switch), ("settings.clearHistory", .button)],
                  footer: "settings.footer.library.history"),
        ]),
        (.appearance, [
            Group(header: "settings.section.appearance", rows: [("settings.appearance", .button), ("settings.accent", .button)], footer: nil),
        ]),
        (.discovery, [
            Group(header: "settings.section.discovery", rows: [("settings.discoveryFamiliarity", .button), ("settings.customizeHome", .button),
                                                               ("settings.moments.open", .button)],
                  footer: "settings.footer.discovery.home"),
            Group(header: "settings.group.discovery.languages", rows: [("settings.languages", .button), ("settings.genres", .button)],
                  footer: "settings.footer.discovery.languages"),
            Group(header: "settings.group.discovery.artists", rows: [("settings.following", .button), ("settings.releaseAlerts", .switch)],
                  footer: "settings.footer.discovery.artists"),
            Group(header: "settings.group.discovery.sources", rows: [("settings.sources", .button)], footer: "settings.footer.discovery.sources"),
        ]),
        (.account, [
            Group(header: "settings.section.account", rows: [("settings.youtubeSignIn", .button), ("settings.youtubeChanges", .button)],
                  footer: "settings.footer.account.youtube"),
            Group(header: "settings.group.account.connection", rows: [("settings.encryptedDNS", .switch), ("settings.remoteFallback", .switch),
                                                                       ("settings.extractorUpdates", .button), ("settings.devices", .button)],
                  footer: "settings.footer.account.connection"),
        ]),
        (.about, [
            Group(header: "settings.section.about", rows: [("settings.tipJar", .button), ("settings.support", .button), ("settings.privacy", .button),
                                                            ("settings.version", .any)], footer: "settings.footer.about.breezy"),
            Group(header: "settings.group.about.credits", rows: [("settings.provider.catalog", .button), ("settings.provider.audio", .button),
                                                                  ("settings.provider.lyrics", .button), ("settings.acknowledgements", .button)],
                  footer: nil),
        ]),
    ]

    override func setUpWithError() throws { continueAfterFailure = false }

    // MARK: Rows and rhythm

    /// At the default text size every row on the root list and every page is the same 44-point shape, notes sit only
    /// in footers 10 points below their group's last row, and a footer or card ends 24 points above the next header.
    func testRowsShareOneHeightAndSectionsShareOneRhythm() throws {
        let ui = AppUITestDriver(testCase: self, prefix: "settings-layout-rhythm")
        addTeardownBlock { await ui.finish() }
        try launch(ui, arguments: [])
        try openSettings(ui)
        let form = ui.element("settings.form")
        try ui.requireHittable(form)
        var rowHeights: [String: CGFloat] = [:]
        var headerToFirstRow: [String: CGFloat] = [:]
        var rowToFooter: [String: CGFloat] = [:]
        var footerToHeader: [String: CGFloat] = [:]
        var cardToHeader: [String: CGFloat] = [:]
        for page in SettingsPageID.allCases {
            let row = ui.app.buttons[page.rowID]
            try reveal(row, ui: ui)
            rowHeights[page.rowID] = row.frame.height
        }
        rowHeights["settings.summary.account"] = ui.element("settings.summary.account").frame.height
        for (page, groups) in Self.pages {
            try ui.openSettingsPage(page)
            var previous: (key: String, element: XCUIElement, isFooter: Bool)?
            for group in groups {
                let header = form.staticTexts[group.header]
                try reveal(header, ui: ui)
                if let previous {
                    // Frames are read together: the previous group's end sits right above this header.
                    let gap = header.frame.minY - previous.element.frame.maxY
                    if previous.isFooter { footerToHeader[previous.key] = gap } else { cardToHeader[previous.key] = gap }
                }
                var lastRow: XCUIElement?
                for (index, (id, type)) in group.rows.enumerated() {
                    let row = form.descendants(matching: type).matching(identifier: id).firstMatch
                    try reveal(row, ui: ui)
                    let frame = row.frame
                    XCTAssertGreaterThanOrEqual(frame.height + 1e-6, 44, id)
                    rowHeights[id] = frame.height
                    if index == 0 { headerToFirstRow[group.header] = frame.minY - header.frame.maxY }
                    lastRow = row
                    if id == "settings.crossfade" { continue }
                    let notes = form.staticTexts.matching(NSPredicate(format: "identifier ENDSWITH %@", ".description")).allElementsBoundByIndex
                    for note in notes where note.exists && frame.minY < note.frame.midY && note.frame.midY < frame.maxY {
                        XCTFail("\(note.identifier) is laid out inside \(id); notes belong in the group footer")
                    }
                }
                if page == .appearance, form.buttons["settings.appIcon"].exists {
                    let appIcon = form.buttons["settings.appIcon"]
                    try reveal(appIcon, ui: ui)
                    rowHeights["settings.appIcon"] = appIcon.frame.height
                    lastRow = appIcon
                }
                guard let lastRow else { continue }
                if let id = group.footer {
                    let footer = form.otherElements[id]
                    try reveal(footer, ui: ui)
                    try reveal(lastRow, ui: ui)
                    XCTAssertEqual(footer.frame.minX, lastRow.frame.minX + 20, accuracy: 1, "\(id) aligns with the row content inset")
                    rowToFooter[id] = footer.frame.minY - lastRow.frame.maxY
                    previous = (id, footer, true)
                } else {
                    previous = (group.header, lastRow, false)
                }
            }
        }
        ui.note("settings-layout-rhythm", "rows=\(rowHeights)\nheaderToFirstRow=\(headerToFirstRow)\nrowToFooter=\(rowToFooter)\nfooterToHeader=\(footerToHeader)\ncardToHeader=\(cardToHeader)")
        // Root page rows carry a one-line caption, so they share their own taller shape.
        let pageRows = rowHeights.filter { $0.key.hasPrefix("settings.page.") }
        let distinct = Set(rowHeights.filter { !$0.key.hasPrefix("settings.page.") }.values.map { $0.rounded() })
        XCTAssertEqual(distinct, [44], "Every row shares the 44-point shape at the default size: \(rowHeights)")
        XCTAssertEqual(pageRows.count, SettingsPageID.allCases.count)
        XCTAssertEqual(Set(pageRows.values.map { $0.rounded() }).count, 1, "Page rows share one captioned height: \(pageRows)")
        XCTAssertGreaterThan(pageRows.values.min() ?? 0, 44)
        XCTAssertEqual(Set(headerToFirstRow.values.map { $0.rounded() }).count, 1, "Headers sit at one distance above their cards: \(headerToFirstRow)")
        for (id, gap) in rowToFooter {
            XCTAssertEqual(gap, SettingsLayout.rowToFooter, accuracy: 1, "\(id): last row to footer text")
        }
        for (id, gap) in footerToHeader {
            XCTAssertEqual(gap, SettingsLayout.footerToHeader, accuracy: 1, "\(id): footer to the next header")
        }
        for (id, gap) in cardToHeader {
            XCTAssertEqual(gap, SettingsLayout.footerToHeader, accuracy: 1, "\(id): card to the next header")
        }
        XCTAssertFalse(rowToFooter.isEmpty)
        XCTAssertFalse(footerToHeader.isEmpty)
        ui.capture("settings-layout-rhythm")
    }

    // MARK: iCloud status slot

    /// The fixture replays one sync cycle: two 120 ms states around a 1.6 s read. The Library section and the next
    /// header keep their frames, the short states never appear, and the slot shows exactly two changes.
    func testICloudStatusChangesLeaveTheLibrarySectionStill() throws {
        let ui = AppUITestDriver(testCase: self, prefix: "settings-icloud-flicker")
        addTeardownBlock { await ui.finish() }
        try launch(ui, arguments: ["--icloud-status-fixture"])
        try openSettings(ui)
        try ui.openSettingsPage(.library)
        let form = ui.element("settings.form")
        try ui.requireHittable(form)
        let header = form.staticTexts["settings.section.library"]
        let status = ui.element("settings.icloud.summary")
        let nextHeader = form.staticTexts["settings.group.library.downloads"]
        try reveal(header, ui: ui)
        try reveal(nextHeader, ui: ui)
        try ui.wait("The Library section must be fully visible with its footer and the next header") {
            header.exists && header.isHittable && nextHeader.exists && nextHeader.isHittable && status.exists
        }
        let watched = ["settings.section.library", "settings.icloud", "settings.icloud.summary", "settings.group.library.downloads",
                       "settings.downloadsCellular", "settings.autoDownloadLiked", "settings.downloadsCellular.description"]
        let elements = Dictionary(uniqueKeysWithValues: watched.map { ($0, ui.element($0)) })
        let baseline = elements.mapValues(\.frame)
        for (id, frame) in baseline { XCTAssertTrue(usable(frame), id) }
        XCTAssertEqual(statusText(status), "Waiting to sync with iCloud")
        XCTAssertEqual(statusChanges(status), 0)
        ui.capture("settings-icloud-status-before-cycle")

        Self.requestStatusCycle()
        var seen: Set<String> = []
        var drift: [String] = []
        let deadline = Date().addingTimeInterval(2.8)
        while Date() < deadline {
            seen.insert(statusText(status))
            for (id, element) in elements where !frameMatches(element.frame, baseline[id] ?? .null, id: id) {
                drift.append("\(id): \(element.frame) vs \(baseline[id] ?? .null)")
            }
        }
        try ui.wait("The cycle ends on the handed-over status", timeout: 5) {
            self.statusText(status) == "Handed to iCloud. Other devices may update later."
        }
        ui.capture("settings-icloud-status-after-cycle")
        XCTAssertTrue(drift.isEmpty, "Status changes must not move the section: \(drift.prefix(5))")
        XCTAssertFalse(seen.contains("Checking iCloud Drive…"), "A 120 ms state never reaches the screen: \(seen)")
        XCTAssertFalse(seen.contains("Saving your library to iCloud Drive…"), "A 120 ms state never reaches the screen: \(seen)")
        XCTAssertTrue(seen.contains("Reading your iCloud library…"), "A 1.6 s state is shown after the hold: \(seen)")
        XCTAssertEqual(statusChanges(status), 2, "Reading and Handed are the only visible transitions")
        for (id, element) in elements {
            XCTAssertTrue(frameMatches(element.frame, baseline[id] ?? .null, id: id), "\(id) keeps its frame after the cycle")
        }
    }

    private func launch(_ ui: AppUITestDriver, arguments: [String]) throws {
        if UIDevice.current.userInterfaceIdiom != .pad {
            try ui.launch(additionalArguments: arguments)
            return
        }
        // iPad exposes top tab buttons instead of the shared driver's bottom-tab readiness target.
        XCUIDevice.shared.orientation = .portrait
        ui.app.launchArguments = ["--uitesting", "--seed-ui", "--skip-welcome", "--reset-ui"] + arguments
            + ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        ui.app.launchEnvironment = ["GANABAJANA_TEST_STORE": ui.storeName]
        ui.app.launch()
        try ui.requireHittable(ui.app.buttons["home.settings"], timeout: 25)
    }

    private func openSettings(_ ui: AppUITestDriver) throws {
        try ui.tap(ui.app.buttons["home.settings"])
        try ui.requireHittable(ui.app.buttons["settings.done"])
        try ui.wait("Settings must expose its own form") { ui.element("settings.form").exists }
    }

    private func statusText(_ status: XCUIElement) -> String {
        let value = status.value as? String ?? ""
        guard let range = value.range(of: " (changes ") else { return value }
        return String(value[..<range.lowerBound])
    }

    private func statusChanges(_ status: XCUIElement) -> Int {
        let value = status.value as? String ?? ""
        guard let range = value.range(of: " (changes ") else { return -1 }
        return Int(value[range.upperBound...].filter(\.isNumber)) ?? -1
    }

    /// The status slot's text width follows its wording; its vertical placement and everything else must not move.
    private func frameMatches(_ lhs: CGRect, _ rhs: CGRect, id: String) -> Bool {
        guard usable(lhs), usable(rhs), abs(lhs.minY - rhs.minY) < 0.5, abs(lhs.height - rhs.height) < 0.5 else { return false }
        if id == "settings.icloud.summary" { return abs(lhs.minX - rhs.minX) < 0.5 }
        return abs(lhs.minX - rhs.minX) < 0.5 && abs(lhs.width - rhs.width) < 0.5
    }

    private static func requestStatusCycle() {
        let name = CFNotificationName(rawValue: "com.agraabhi.ganabajana.uitests.icloud.cycle" as CFString)
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), name, nil, nil, true)
    }

    /// Brings one element fully into the Settings viewport with slow edge drags, like the inventory test does.
    private func reveal(_ target: XCUIElement, ui: AppUITestDriver) throws {
        let form = ui.element("settings.form")
        let window = ui.app.windows.firstMatch
        var lastContext = ""
        for attempt in 0...16 {
            let bounds = window.frame
            let formBounds = form.frame.intersection(bounds)
            let top = max(formBounds.minY, ui.settingsNavigationBar.frame.maxY)
            let viewport = CGRect(x: formBounds.minX, y: top, width: formBounds.width, height: max(0, formBounds.maxY - top))
            guard usable(viewport) else { throw AppUIWorkflowFailure(message: "Settings needs a visible form viewport: \(viewport)") }
            let frame = target.exists ? target.frame : CGRect.null
            lastContext = "frame: \(frame), viewport: \(viewport)"
            if usable(frame), viewport.insetBy(dx: -1e-6, dy: -1e-6).contains(frame), target.isHittable { return }
            guard attempt < 16 else { break }
            var movement = -viewport.height * 0.4
            if usable(frame) {
                if frame.minY < viewport.minY { movement = viewport.minY - frame.minY + 8 }
                else if frame.maxY > viewport.maxY { movement = viewport.maxY - frame.maxY - 8 }
            }
            let distance = min(max(abs(movement), 44), viewport.height * 0.4)
            let startY = movement > 0 ? viewport.minY + viewport.height * 0.2 : viewport.maxY - viewport.height * 0.2
            let origin = window.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: viewport.minX + min(12, viewport.width * 0.05) - bounds.minX, dy: startY - bounds.minY))
            let end = start.withOffset(CGVector(dx: 0, dy: movement > 0 ? distance : -distance))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        throw AppUIWorkflowFailure(message: "Settings target \(target.identifier) was not visible after 16 drags; \(lastContext)")
    }

    // MARK: Measurements

    /// Captures each Form-based sub-page on the shared components, for the docs and the review.
    func testRecordsSubPageCaptures() throws {
        let ui = AppUITestDriver(testCase: self, prefix: "settings-subpages")
        addTeardownBlock { await ui.finish() }
        try launch(ui, arguments: ["--saavn-fixture"])
        try openSettings(ui)
        let pages: [(row: String, title: String, capture: String)] = [
            ("settings.icloud", "iCloud Sync", "subpage-icloud"), ("settings.storage", "Storage", "subpage-storage"),
            ("settings.equalizer", "Equalizer", "subpage-equalizer"), ("settings.accent", "Accent Color", "subpage-accent"),
            ("settings.customizeHome", "Customize Home", "subpage-customize-home"),
            ("settings.sources", "Catalog Sources", "subpage-catalog-sources"),
        ]
        for page in pages {
            let parent = try XCTUnwrap(SettingsPageID.containing(page.row))
            try ui.openSettingsPage(parent)
            let row = ui.app.buttons[page.row]
            try reveal(row, ui: ui)
            try ui.tap(row)
            try ui.wait("\(page.title) must open") { ui.app.navigationBars[page.title].exists }
            Thread.sleep(forTimeInterval: 1)
            ui.capture(page.capture)
            try ui.tap(ui.app.navigationBars[page.title].buttons.firstMatch)
            try ui.wait("Back returns to \(parent.title)") { ui.app.navigationBars[parent.title].exists }
        }
    }

    /// Records the frame of every identified Settings element while paging through the form, with one capture per page.
    /// The attachment is the evidence for the row-height and rhythm numbers in docs/SETTINGS.md.
    func testRecordsSettingsLayoutMeasurementsDarkDefault() throws {
        try recordMeasurements(variant: "dark-default", arguments: [])
    }

    func testRecordsSettingsLayoutMeasurementsLightDefault() throws {
        try recordMeasurements(variant: "light-default", arguments: ["--light"])
    }

    func testRecordsSettingsLayoutMeasurementsDarkAccessibilityXXXL() throws {
        try recordMeasurements(variant: "dark-ax-xxxl", arguments: ["-UIPreferredContentSizeCategoryName",
                                                                  UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue])
    }

    func testRecordsSettingsLayoutMeasurementsLightAccessibilityXXXL() throws {
        try recordMeasurements(variant: "light-ax-xxxl", arguments: ["--light", "-UIPreferredContentSizeCategoryName",
                                                                   UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue])
    }

    private func recordMeasurements(variant: String, arguments: [String]) throws {
        let ui = AppUITestDriver(testCase: self, prefix: "settings-layout-\(variant)")
        addTeardownBlock { await ui.finish() }
        try launch(ui, arguments: arguments)
        try openSettings(ui)
        let form = ui.element("settings.form")
        try ui.requireHittable(form)
        var report = "variant=\(variant) window=\(ui.app.windows.firstMatch.frame)\n"
        for screen in ["root"] + SettingsPageID.allCases.map(\.rawValue) {
            if let page = SettingsPageID(rawValue: screen) { try ui.openSettingsPage(page) }
            var previous: String?
            for index in 0..<40 {
                let snapshot = snapshotFrames(in: form, ui: ui)
                if snapshot == previous { break }
                previous = snapshot
                report += "screen=\(screen) page=\(index)\n\(snapshot)\n"
                ui.capture("settings-\(variant)-\(screen)-\(index)")
                scrollForm(form, ui: ui, fraction: 0.7)
            }
        }
        ui.note("settings-layout-\(variant)", report)
    }

    /// Identified elements with on-screen geometry, top to bottom: identifier, type, frame and label.
    private func snapshotFrames(in form: XCUIElement, ui: AppUITestDriver) -> String {
        let window = ui.app.windows.firstMatch.frame
        let elements = ui.app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "settings."))
            .allElementsBoundByIndex
        var lines: [(CGFloat, String)] = []
        for element in elements {
            let frame = element.frame
            guard usable(frame), frame.intersects(window), element.identifier != "settings.form", element.identifier != "settings.done" else { continue }
            let label = element.label.replacingOccurrences(of: "\n", with: " ")
            lines.append((frame.minY, "\(element.identifier)\t\(element.elementType.rawValue)\t\(frame)\t\(label.prefix(60))"))
        }
        return lines.sorted { $0.0 < $1.0 }.map(\.1).joined(separator: "\n")
    }

    private func scrollForm(_ form: XCUIElement, ui: AppUITestDriver, fraction: CGFloat) {
        let window = ui.app.windows.firstMatch
        let bounds = window.frame
        let navigation = ui.settingsNavigationBar.frame
        let formBounds = form.frame.intersection(bounds)
        let top = max(formBounds.minY, navigation.maxY)
        let viewport = CGRect(x: formBounds.minX, y: top, width: formBounds.width, height: max(0, formBounds.maxY - top))
        guard usable(viewport) else { return }
        let distance = viewport.height * fraction
        let origin = window.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: viewport.minX + 8 - bounds.minX, dy: viewport.maxY - viewport.height * 0.15 - bounds.minY))
        let end = start.withOffset(CGVector(dx: 0, dy: -distance))
        // Edge drags avoid toggling a switch; the held release keeps the form from coasting past a row.
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
    }

    private func usable(_ frame: CGRect) -> Bool {
        !frame.isEmpty && !frame.isNull && [frame.minX, frame.minY, frame.maxX, frame.maxY].allSatisfy(\.isFinite)
    }
}

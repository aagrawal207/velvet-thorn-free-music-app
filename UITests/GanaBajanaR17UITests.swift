import XCTest

@MainActor
final class GanaBajanaR17UITests: XCTestCase {
    private let firstTrackID = "R17song0001"
    private let momentID = "weekday.morning.general"
    private let gurmukhiLine = "ਕਾਗਜ਼ ਦੀ ਕਿਸ਼ਤੀ ਹੌਲੀ ਤੁਰੇ"
    private let latinLine = "Kaagaz di kishti hauli ture"

    override func setUpWithError() throws { continueAfterFailure = false }

    func testLyricsMenuAndTVFollowGurmukhiAndLatinInLightAndDark() throws {
        for appearance in ["dark", "light"] {
            let ui = try launch(appearance)
            defer { ui.finish() }
            try ui.openPlayer()
            try ui.expectCurrentTrack(firstTrackID)
            try ui.openPlayerSheet("lyrics", title: "Lyrics")
            let picker = ui.app.buttons["lyrics.variantPicker"]
            try ui.wait("Both published fixture versions must be available") { picker.exists }
            try assertTarget(picker, ui: ui)
            XCTAssertTrue(picker.label.contains("Lyric Version"))
            XCTAssertTrue(picker.label.contains("Original Script · Gurmukhi"))
            try expectLyric(gurmukhiLine, ui: ui)
            capture("lyrics-gurmukhi", appearance: appearance, ui: ui)

            try startTV(expectedLine: gurmukhiLine, script: "Gurmukhi", ui: ui)
            try stopTV(ui)
            try chooseVariant("Romanised / Latin", ui: ui)
            try expectLyric(latinLine, ui: ui)
            try startTV(expectedLine: latinLine, script: "Romanised / Latin", ui: ui)
            capture("tv-latin", appearance: appearance, ui: ui)
            try stopTV(ui)
            try chooseVariant("Original Script · Gurmukhi", ui: ui)
            try expectLyric(gurmukhiLine, ui: ui)
            try assertTarget(ui.app.buttons["lyrics.done"], ui: ui)
            try ui.tap(ui.app.buttons["lyrics.done"])
            try ui.wait("Done returns to the player") { ui.app.buttons["player.playPause"].isHittable }
            try ui.expectLabel(ui.app.buttons["player.playPause"], "Play")
        }
    }

    func testMomentMixSettingsControlTheLearnedHomeCardAndPlaybackInLightAndDark() throws {
        for appearance in ["dark", "light"] {
            let ui = try launch(appearance)
            defer { ui.finish() }
            let card = ui.app.buttons.matching(NSPredicate(format: "identifier == %@ AND label == %@",
                "home.moment.\(momentID)", "Morning Mix, From Your Listening")).firstMatch
            try ui.reveal(card, maxSwipes: 20)
            XCTAssertTrue(ui.accessibleText(card).contains("Morning Mix"))
            try assertTarget(card, ui: ui)
            try assertTarget(momentPlayButton(ui), ui: ui)
            capture("moments-home", appearance: appearance, ui: ui)
            try openMomentSettings(ui)
            try ui.expectSwitch("settings.moments.learning", isOn: true)
            try assertTarget(ui.app.switches["settings.moments.learning"], ui: ui)
            XCTAssertEqual(ui.app.switches["settings.moments.learning"].label, "Learn Moment Mixes")
            let motion = ui.app.switches["settings.moments.motion"]
            try ui.reveal(motion)
            XCTAssertEqual(motion.label, "Use Motion Activity")
            XCTAssertFalse(motion.isEnabled, "This fixture never requests motion permission")
            let mixSwitch = "settings.moments.mix.\(momentID)"
            try ui.expectSwitch(mixSwitch, isOn: true)
            try assertTarget(ui.app.switches[mixSwitch], ui: ui)
            XCTAssertEqual(ui.app.switches[mixSwitch].label, "Morning Mix")
            try ui.setSwitch(mixSwitch, to: false)
            try closeSettings(ui)
            try ui.wait("The disabled learned mix leaves Home") { !card.exists }

            ui.app.terminate()
            try ui.relaunch()
            try openMomentSettings(ui)
            try ui.expectSwitch(mixSwitch, isOn: false)
            try ui.setSwitch(mixSwitch, to: true)
            try closeSettings(ui)
            try ui.reveal(card, maxSwipes: 20)
            try ui.tap(card)
            let play = ui.app.buttons["collection.play"]
            try ui.reveal(play)
            try assertTarget(play, ui: ui)
            try ui.tap(play)
            try ui.openPlayer()
            let initialPosition = try ui.position()
            try ui.waitForAdvance(from: initialPosition, by: 1)
            try ui.pause()
            XCTAssertTrue((1...3).contains { ui.app.staticTexts["player.track.R17song000\($0)"].exists },
                          "The moment must play one of its three local fixture recordings")
            try ui.closePlayer()
            try openMomentSettings(ui)
            try ui.setSwitch("settings.moments.learning", to: false)
            try ui.setSwitch("settings.moments.learning", to: true)
            try closeSettings(ui)
            try ui.wait("Re-enabling learning must not backfill the retired three days") { !card.exists }
        }
    }

    func testAllTimeUsesLifetimeMinutesAndRetainedRankingsThenSharesInLightAndDark() throws {
        for appearance in ["dark", "light"] {
            let ui = try launch(appearance)
            defer { ui.finish() }
            try ui.selectTab("recap")
            let allTime = ui.app.buttons["recap.window.allTime"]
            try assertTarget(allTime, ui: ui)
            try ui.tap(allTime)
            XCTAssertTrue(allTime.isSelected)
            let coverage = ui.app.staticTexts["recap.historyCoverage"]
            try ui.reveal(coverage)
            XCTAssertTrue(coverage.label.contains("Lifetime totals"))
            XCTAssertTrue(coverage.label.contains("Charts and rankings use retained history"))
            XCTAssertTrue(coverage.label.contains("cannot be recovered"))
            try ui.reveal(ui.element("recap.totalListening"))
            XCTAssertEqual(try ui.recapSeconds(), 15_480, accuracy: 1)
            XCTAssertTrue(ui.accessibleText(ui.element("recap.totalListening")).contains("since lifetime coverage began"))
            capture("lifetime-total", appearance: appearance, ui: ui)
            for index in 1...3 { try ui.reveal(ui.element("recap.track.R17song000\(index)")) }
            XCTAssertFalse(ui.element("recap.track.R17old00001").exists)
            try ui.reveal(ui.app.staticTexts["Over Time"])
            let share = ui.app.buttons["recap.share"]
            try ui.reveal(share, direction: .down)
            try assertTarget(share, ui: ui)
            XCTAssertEqual(share.label, "Share")
            try ui.tap(share)
            let preview = ui.element("recap.share.previewImage")
            try ui.wait("The lifetime Stats Card must finish rendering", timeout: 25) { preview.exists }
            XCTAssertTrue(preview.label.contains("Lifetime Listening"))
            let numberStyle = IntegerFormatStyle<Int>.number.locale(Locale(identifier: "en_US"))
            XCTAssertEqual(preview.value as? String, "\(1_080.formatted(numberStyle)) by \(1_350.formatted(numberStyle)) pixels")
            try revealStatsCardNote(ui)
            capture("lifetime-stats-card", appearance: appearance, ui: ui)
            let systemShare = ui.app.buttons["recap.share.previewShare"]
            try ui.reveal(systemShare, direction: .down)
            try assertTarget(systemShare, ui: ui)
            try ui.tap(systemShare)
            try expectSystemShare(ui)
        }
    }

    func testDownloadedAACExportsWithSongDetailsAndSharesInLightAndDark() throws {
        for appearance in ["dark", "light"] {
            let ui = try launch(appearance)
            defer { ui.finish() }
            try openDownloads(ui)
            try ui.openPlayer()
            try ui.expectCurrentTrack(firstTrackID)
            try ui.openExpandedPlayerMenu()
            let downloaded = ui.app.buttons["player.options.download"]
            try ui.reveal(downloaded)
            try ui.wait("The fixture publishes verified audio in the permanent download tier", timeout: 40) {
                downloaded.exists && downloaded.label == "Downloaded"
            }
            let export = ui.app.buttons["player.options.export"]
            try ui.reveal(export)
            try assertTarget(export, ui: ui)
            XCTAssertEqual(export.label, "Export Audio")
            try ui.tap(export)
            let share = ui.app.buttons["export.share"]
            try ui.wait("The real exporter must verify its output before offering Share File", timeout: 120) { share.exists }
            XCTAssertFalse(ui.element("export.error").exists)
            XCTAssertEqual(ui.app.staticTexts["export.fileName"].label, "Breezy Fixture Ensemble - Paper Lantern.m4a")
            let detail = ui.app.staticTexts["export.detail"]
            XCTAssertTrue(detail.label.contains("AAC"))
            XCTAssertTrue(detail.label.contains("Song details included"))
            XCTAssertTrue(detail.label.contains("Original AAC preserved"))
            XCTAssertFalse(detail.label.contains("Converted to AAC"))
            try assertTarget(share, ui: ui)
            XCTAssertEqual(share.label, "Share File")
            capture("export-aac-details", appearance: appearance, ui: ui)
            try ui.tap(share)
            try expectSystemShare(ui)
        }
    }

    func testNotLikedDownloadsUpdatesWhenPlayerHeartChangesInLightAndDark() throws {
        for appearance in ["dark", "light"] {
            let ui = try launch(appearance)
            defer { ui.finish() }
            try openDownloads(ui)
            try expectAllFixtureDownloads(ui)
            for (key, title) in [("all", "All"), ("liked", "Liked"), ("notLiked", "Not Liked")] {
                let chip = ui.app.buttons["downloads.filter.\(key)"]
                try ui.reveal(chip, direction: .down)
                try assertTarget(chip, ui: ui)
                XCTAssertEqual(chip.label, title)
            }
            let notLiked = ui.app.buttons["downloads.filter.notLiked"]
            try ui.tap(notLiked)
            try expectNotLikedEmpty(ui)
            for action in ["downloads.play", "downloads.shuffle"] {
                let button = ui.app.buttons[action]
                try assertTarget(button, ui: ui)
                XCTAssertFalse(button.isEnabled, "Empty filtered queues must not start another download")
            }

            try setCurrentFixtureLiked(false, ui: ui)
            try ui.wait("Not Liked must update in the existing Downloads page after unliking") {
                notLiked.isSelected && ui.app.buttons["downloads.play.\(self.firstTrackID)"].exists
                    && !ui.app.buttons["downloads.play.R17song0002"].exists
                    && !ui.app.buttons["downloads.play.R17song0003"].exists
                    && !ui.element("downloads.filter.empty").exists
            }
            let row = ui.app.buttons["downloads.play.\(firstTrackID)"]
            try assertTarget(row, ui: ui)
            XCTAssertTrue(row.isEnabled)
            XCTAssertTrue(ui.accessibleText(row).contains("Downloaded."))
            XCTAssertTrue(ui.accessibleText(row).contains("Paper Lantern"))
            XCTAssertTrue(ui.app.staticTexts["downloads.summary"].label.hasPrefix("3 songs on this device"),
                          "Unliking does not delete the downloaded file")
            capture("downloads-not-liked", appearance: appearance, ui: ui)

            try setCurrentFixtureLiked(true, ui: ui)
            try expectNotLikedEmpty(ui)
            for key in ["all", "liked"] {
                let chip = ui.app.buttons["downloads.filter.\(key)"]
                try ui.reveal(chip, direction: .down)
                try ui.tap(chip)
                XCTAssertTrue(chip.isSelected)
                try expectAllFixtureDownloads(ui)
            }
        }
    }

    private func launch(_ appearance: String) throws -> AppUITestDriver {
        let ui = AppUITestDriver(testCase: self, prefix: "r17-\(appearance)")
        addTeardownBlock { await ui.finish() }
        try ui.launch(additionalArguments: ["--r17-fixture"] + (appearance == "light" ? ["--light"] : []))
        return ui
    }

    private func chooseVariant(_ title: String, ui: AppUITestDriver) throws {
        let picker = ui.app.buttons["lyrics.variantPicker"]
        try ui.reveal(picker, direction: .down)
        try ui.tap(picker)
        let choice = ui.app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                                                        "lyrics.variant.", title)).firstMatch
        try ui.tap(choice)
        try ui.wait("The selected published script must be named by the menu") { picker.label.contains(title) }
    }

    private func expectLyric(_ line: String, ui: AppUITestDriver) throws {
        let first = ui.element("lyrics.line.0")
        try ui.reveal(first)
        try ui.wait("The phone lyrics must render the selected script") { ui.accessibleText(first).contains(line) }
    }

    private func startTV(expectedLine: String, script: String, ui: AppUITestDriver) throws {
        let start = ui.app.buttons["tvLyrics.start"]
        try ui.reveal(start, direction: .down)
        try assertTarget(start, ui: ui)
        XCTAssertEqual(start.label, "TV Lyrics")
        try ui.tap(start)
        try ui.wait("Full-screen TV lyrics must use the selected version") {
            ui.element("tvLyrics.phone").exists && ui.app.staticTexts["tvLyrics.currentLine"].label == expectedLine
        }
        let header = tvText("tvLyrics.track", prefix: "Paper Lantern", ui: ui)
        let source = tvText("tvLyrics.source", prefix: "Lyrics · ", ui: ui)
        try ui.wait("TV must retain the recording header and selected published source") {
            header.exists && header.label == "Paper Lantern, Breezy Fixture Ensemble"
                && source.exists && source.label.contains(script) && source.label.contains("Breezy Original Fixture")
        }
    }

    private func stopTV(_ ui: AppUITestDriver) throws {
        let stop = ui.app.buttons.matching(NSPredicate(format:
            "(identifier == %@ OR identifier == %@) AND label == %@",
            "tvLyrics.stop", "tvLyrics.phone", "Stop TV Lyrics")).firstMatch
        try assertTarget(stop, ui: ui)
        XCTAssertEqual(stop.label, "Stop TV Lyrics")
        try ui.tap(stop)
        try ui.wait("Stop must dismiss TV and return to the same lyrics sheet") {
            !ui.element("tvLyrics.phone").exists && ui.app.buttons["lyrics.variantPicker"].exists
        }
        XCTAssertFalse(ui.app.buttons["tvLyrics.stopFromOptions"].exists)
    }

    private func openMomentSettings(_ ui: AppUITestDriver) throws {
        try ui.openSettings()
        try ui.openSettingsPage(.discovery)
        let link = ui.app.buttons["settings.moments.open"]
        try ui.reveal(link)
        try assertTarget(link, ui: ui)
        XCTAssertTrue(link.label.contains("Moment Mixes"))
        try ui.tap(link)
        try ui.wait("Discovery opens Moment Mixes") { ui.app.navigationBars["Moment Mixes"].exists }
    }

    private func closeSettings(_ ui: AppUITestDriver) throws {
        try ui.tap(ui.app.buttons["settings.done"])
        try ui.wait("Settings must close") { !ui.app.buttons["settings.done"].exists }
    }

    private func momentPlayButton(_ ui: AppUITestDriver) -> XCUIElement {
        let identified = ui.app.buttons["mix.play.moment.\(momentID)"]
        if identified.exists { return identified }
        // Home's ID propagates to the overlay wrapper; its real button and the browse link remain separate targets.
        let overlay = ui.app.otherElements.matching(NSPredicate(format: "identifier == %@ AND label == %@",
            "home.moment.\(momentID)", "Play Morning Mix")).firstMatch
        return overlay.buttons.firstMatch
    }

    private func revealStatsCardNote(_ ui: AppUITestDriver) throws {
        let sheet = ui.element("recap.share.preview")
        let scroll = sheet.scrollViews.firstMatch
        let navigation = sheet.navigationBars["Stats Card"]
        let note = sheet.staticTexts["Lifetime total; rankings use retained history. Earlier deleted plays cannot be recovered."]
        try ui.wait("The Stats Card must own its scroll view and coverage note") {
            scroll.exists && navigation.exists && note.exists
        }
        for attempt in 0...4 {
            let window = ui.app.windows.firstMatch
            var viewport = scroll.frame.intersection(sheet.frame).intersection(window.frame)
            let top = max(viewport.minY, navigation.frame.maxY)
            viewport = CGRect(x: viewport.minX, y: top, width: viewport.width, height: max(0, viewport.maxY - top))
            // Scroll indicators stop before this sheet's visible footer; they are not the content's clipping bounds.
            if !note.frame.isEmpty, viewport.contains(note.frame), note.isHittable { return }
            guard attempt < 4, !viewport.isEmpty, viewport.height > 88 else { break }
            let upward = note.frame.midY >= viewport.midY
            let origin = window.coordinate(withNormalizedOffset: .zero)
            let x = viewport.midX - window.frame.minX
            let startY = viewport.minY + viewport.height * (upward ? 0.75 : 0.35) - window.frame.minY
            let endY = viewport.minY + viewport.height * (upward ? 0.35 : 0.75) - window.frame.minY
            origin.withOffset(CGVector(dx: x, dy: startY)).press(forDuration: 0.05,
                thenDragTo: origin.withOffset(CGVector(dx: x, dy: endY)),
                withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        ui.captureFailure("r17-stats-note-unreachable", detail: "The complete coverage note must be visible inside the Stats Card sheet.")
        throw AppUIWorkflowFailure(message: "The Stats Card coverage note could not be revealed inside its sheet.")
    }

    // SwiftUI can propagate the surface ID onto immediate children; preserve exact labels within that TV surface.
    private func tvText(_ id: String, prefix: String, ui: AppUITestDriver) -> XCUIElement {
        ui.app.staticTexts.matching(NSPredicate(format:
            "(identifier == %@ OR identifier == %@) AND label BEGINSWITH %@", id, "tvLyrics.phone", prefix)).firstMatch
    }

    private func openDownloads(_ ui: AppUITestDriver) throws {
        try ui.selectTab("library")
        let downloads = ui.app.buttons["library.downloads"]
        try ui.reveal(downloads)
        try assertTarget(downloads, ui: ui)
        try ui.tap(downloads)
        let summary = ui.app.staticTexts["downloads.summary"]
        let failure = ui.element("message.text")
        try ui.wait("Fixture AAC preparation must publish all three downloaded files", timeout: 110) {
            (summary.exists && summary.label.hasPrefix("3 songs on this device"))
                || ui.accessibleText(failure).contains("R17 fixture audio")
        }
        XCTAssertTrue(summary.exists && summary.label.hasPrefix("3 songs on this device"), ui.accessibleText(failure))
        XCTAssertTrue(ui.app.navigationBars["Downloads"].exists)
    }

    private func expectAllFixtureDownloads(_ ui: AppUITestDriver) throws {
        for index in 1...3 {
            let row = ui.app.buttons["downloads.play.R17song000\(index)"]
            try ui.reveal(row)
            XCTAssertTrue(row.isEnabled)
            XCTAssertTrue(ui.accessibleText(row).contains("Downloaded."))
        }
        XCTAssertFalse(ui.element("downloads.filter.empty").exists)
    }

    private func expectNotLikedEmpty(_ ui: AppUITestDriver) throws {
        try ui.wait("All three liked downloads are excluded by Not Liked") {
            ui.app.buttons["downloads.filter.notLiked"].isSelected
                && ui.app.staticTexts["All Downloads Are Liked"].exists
                && !(1...3).contains { ui.app.buttons["downloads.play.R17song000\($0)"].exists }
        }
    }

    private func setCurrentFixtureLiked(_ liked: Bool, ui: AppUITestDriver) throws {
        try ui.openPlayer()
        try ui.expectCurrentTrack(firstTrackID)
        let heart = ui.app.buttons["player.like"]
        try assertTarget(heart, ui: ui)
        try ui.expectLabel(heart, liked ? "Like this song" : "Unlike this song")
        try ui.tap(heart)
        try ui.expectLabel(heart, liked ? "Unlike this song" : "Like this song")
        try ui.closePlayer()
        try ui.wait("Closing the player preserves the filtered Downloads destination") {
            ui.app.navigationBars["Downloads"].exists && ui.app.buttons["downloads.filter.notLiked"].isSelected
        }
    }

    private func assertTarget(_ element: XCUIElement, ui: AppUITestDriver,
                              file: StaticString = #filePath, line: UInt = #line) throws {
        try ui.reveal(element)
        try ui.requireHittable(element)
        XCTAssertGreaterThanOrEqual(element.frame.width + 1e-6, 44, element.identifier, file: file, line: line)
        XCTAssertGreaterThanOrEqual(element.frame.height + 1e-6, 44, element.identifier, file: file, line: line)
        let window = ui.app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(element.frame.minX + 1e-6, window.minX, file: file, line: line)
        XCTAssertLessThanOrEqual(element.frame.maxX, window.maxX + 1e-6, file: file, line: line)
    }

    private func expectSystemShare(_ ui: AppUITestDriver) throws {
        try ui.wait("The native share sheet must open from the verified artifact") {
            ui.app.buttons["Copy"].exists || ui.app.buttons["Save to Files"].exists
                || ui.app.buttons["Save Image"].exists || ui.app.otherElements["ActivityListView"].exists
        }
    }

    private func capture(_ stage: String, appearance: String, ui: AppUITestDriver) {
        let width = ui.app.windows.firstMatch.frame.width
        let device = width >= 700 ? "ipad" : width <= 390 ? "small-phone" : "phone"
        ui.capture("r17-\(device)-\(appearance)-\(stage)")
    }
}

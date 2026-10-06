import XCTest

@MainActor
final class GanaBajanaR18UITests: XCTestCase {
    private let gaanaID = "gaana:R18quiet"
    private let youtubeID = "R18song0001"
    private let publicStation = "18000000-0000-0000-0000-000000000001"
    private let jazzStation = "18000000-0000-0000-0000-000000000002"

    override func setUpWithError() throws { continueAfterFailure = false }

    func testDirectoryNPRFavoritesLiveSurfacesAndPausedMusicRestorationInLightAndDark() throws {
        for appearance in ["dark", "light"] {
            let ui = try launch(appearance)
            defer { ui.finish() }
            try openDirectory(ui)
            let station = ui.app.buttons["liveRadio.station.\(publicStation)"]
            let jazz = ui.app.buttons["liveRadio.station.\(jazzStation)"]
            try step("Directory / \(appearance): reveal and verify both parsed fixture stations before filtering", ui) {
                // Lazy List rows enter the accessibility tree when scrolled into the small-phone viewport.
                for (row, label) in [(station, "Play KBRZ Public Radio, Live Radio"), (jazz, "Play Breezy Jazz Radio, Live Radio")] {
                    try ui.reveal(row)
                    try ui.wait("The parsed station \(row.identifier) must be visible") { row.exists && row.isHittable }
                    XCTAssertEqual(row.label, label)
                }
            }
            try ui.reveal(ui.app.buttons["liveRadio.npr"], direction: .down)
            try tap("liveRadio.npr", ui)
            try ui.reveal(station)
            try ui.wait("NPR tag filtering finds the call-sign affiliate and excludes Jazz") { station.exists && !jazz.exists }
            XCTAssertTrue(station.label.contains("KBRZ Public Radio"))
            try tap("liveRadio.favorite.\(publicStation)", ui)
            try ui.expectLabel(ui.app.buttons["liveRadio.favorite.\(publicStation)"], "Remove Station Favorite")
            try target(station, ui)
            try ui.tap(station)
            try ui.wait("Live selection replaces the mini-player without opening the full player") {
                ui.app.buttons["miniPlayer.open"].label.contains("KBRZ Public Radio")
                    && ui.app.buttons["miniPlayer.live.stop"].exists
            }
            XCTAssertFalse(ui.app.buttons["player.close"].exists)
            XCTAssertFalse(ui.app.buttons["miniPlayer.next"].exists)
            try target(ui.app.buttons["miniPlayer.playPause"], ui)
            try target(ui.app.buttons["miniPlayer.live.stop"], ui)
            // The shared song helper requires elapsed time; live mode deliberately has no elapsed/seek row.
            try tap("miniPlayer.open", ui)
            try ui.wait("The full player must present the station identity") {
                ui.app.staticTexts["player.live.title"].label == "KBRZ Public Radio"
            }
            for id in ["player.seek", "player.lyrics", "player.download", "player.queue", "player.like"] {
                XCTAssertFalse(ui.element(id).exists, "Live mode must omit \(id)")
            }
            try target(ui.app.buttons["player.playPause"], ui)
            try target(ui.app.buttons["player.live.favorite"], ui)
            try target(ui.app.buttons["player.live.sleep"], ui)
            try target(ui.element("player.airplay.anchor"), ui)
            try ui.wait("The injected local URL must fail closed before any broadcaster fetch", timeout: 100) {
                ui.app.staticTexts["This station doesn’t offer a supported secure audio stream."].exists
            }
            capture("live-local-policy-boundary", appearance, ui)
            try tap("player.live.stop", ui)
            try ui.expectCurrentTrack(gaanaID)
            try ui.expectLabel(ui.app.buttons["player.playPause"], "Play")
            try ui.closePlayer()
            try ui.relaunch()
            try openDirectory(ui)
            try ui.setSwitch("liveRadio.favorites", to: true)
            try ui.reveal(station)
            try ui.wait("Station favorites must survive the isolated-store relaunch") { station.exists && !jazz.exists }
            try ui.expectLabel(ui.app.buttons["liveRadio.favorite.\(publicStation)"], "Remove Station Favorite")
            try ui.tap(station)
            try tap("miniPlayer.live.stop", ui)
            try ui.wait("Mini-player Stop restores the song paused") {
                ui.app.buttons["miniPlayer.open"].label.contains("Paper Radio")
                    && ui.app.buttons["miniPlayer.playPause"].label == "Play"
            }
        }
    }

    func testGaanaFallbackQualityUsesActualSourceAfterCachedRelaunchInLightAndDark() throws {
        for appearance in ["dark", "light"] {
            let ui = try launch(appearance)
            defer { ui.finish() }
            var firstSummary: String?
            for relaunch in [false, true] {
                if relaunch { try ui.relaunch() }
                try playAndPauseCurrent(ui)
                try ui.expectCurrentTrack(gaanaID)
                try ui.openExpandedPlayerMenu()
                let quality = ui.element("player.options.audioQuality")
                try ui.reveal(quality)
                let summary = ui.accessibleText(quality)
                XCTAssertTrue(summary.contains("AAC"), summary)
                XCTAssertTrue(summary.contains("via JioSaavn"), summary)
                XCTAssertFalse(summary.contains("Playback source unknown"), summary)
                XCTAssertFalse(summary.lowercased().contains("lossless"), summary)
                XCTAssertFalse(ui.app.buttons["player.options.youtubeChanges"].exists,
                               "The remote write menu follows catalog identity, not fallback provenance")
                if let firstSummary { XCTAssertEqual(summary, firstSummary) } else { firstSummary = summary }
                capture(relaunch ? "quality-relaunched" : "quality-cached", appearance, ui)
            }
        }
    }

    func testExportUsesRealAACAndEmbeddedCoverBeforeNativeShareInLightAndDark() throws {
        for appearance in ["dark", "light"] {
            let ui = try launch(appearance)
            defer { ui.finish() }
            try playAndPauseCurrent(ui)
            try ui.openExpandedPlayerMenu()
            try tap("player.options.share", ui)
            try ui.wait("The cached artwork must render in the actual Song Card preview", timeout: 25) {
                ui.element("songShare.preview").label == "Song card for Paper Radio"
                    && ui.app.buttons["songShare.share"].exists
            }
            try target(ui.app.buttons["songShare.share"], ui)
            try target(ui.app.buttons["songShare.linkOnly"], ui)
            capture("song-share-preview", appearance, ui)
            try tap("player.options.back", ui)
            try step("Export / \(appearance): export Paper Radio and require verified AAC, song details and embedded cover", ui) {
                try tap("player.options.export", ui)
                try ui.wait("Real export verification must complete before Share File appears", timeout: 120) {
                    ui.app.buttons["export.share"].exists || ui.element("export.error").exists
                }
                let error = ui.element("export.error")
                if error.exists { ui.note("r18-export-error", "Track: \(gaanaID)\nDisplayed error: \(ui.accessibleText(error))") }
                XCTAssertFalse(error.exists, ui.accessibleText(error))
                XCTAssertEqual(ui.app.staticTexts["export.fileName"].label, "Breezy Fixture Ensemble - Paper Radio.m4a")
                let detail = ui.app.staticTexts["export.detail"]
                XCTAssertTrue(detail.label.contains("Original AAC preserved"), detail.label)
                XCTAssertTrue(detail.label.contains("Song details included"), detail.label)
                XCTAssertTrue(detail.label.contains("Cover art included"), detail.label)
                let evidence = ui.app.staticTexts["export.coverEvidence"]
                try ui.reveal(evidence)
                XCTAssertTrue(evidence.label.contains("verified inside this M4A"))
            }
            capture("export-cover-verified", appearance, ui)
            try step("Export / \(appearance): Share File opens the native M4A activity sheet", ui) {
                try tap("export.share", ui)
                try ui.wait("The verified M4A must open the native share sheet") {
                    ui.app.buttons["Copy"].exists || ui.app.buttons["Save to Files"].exists
                        || ui.app.otherElements["ActivityListView"].exists
                }
            }
        }
    }

    func testAccountOptInAndExplicitConfirmationProduceFakeReceiptWithoutLocalHeartChangeInLightAndDark() throws {
        for appearance in ["dark", "light"] {
            let ui = try launch(appearance)
            defer { ui.finish() }
            try ui.openSettings()
            try ui.openSettingsPage(.account)
            try tap("settings.youtubeChanges", ui)
            try ui.expectSwitch("youtubeWrite.allow", isOn: false)
            XCTAssertFalse(ui.app.buttons["youtubeWrite.like"].exists)
            XCTAssertFalse(ui.element("youtubeWrite.status").exists)
            try target(ui.app.switches["youtubeWrite.allow"], ui)
            try ui.setSwitch("youtubeWrite.allow", to: true)
            try tap("youtubeWrite.done", ui)
            try ui.wait("Done must close Settings") { !ui.app.buttons["settings.done"].exists }
            try step("Account / \(appearance): select \(youtubeID) with paused Next, then explicitly play local AAC", ui) {
                try ui.openPlayer()
                try ui.expectLabel(ui.app.buttons["player.playPause"], "Play")
                try tap("player.next", ui)
                try ui.expectCurrentTrack(youtubeID)
                try ui.expectLabel(ui.app.buttons["player.playPause"], "Play")
                try ui.expectPosition(0)
                try playAndPauseVisiblePlayer(ui)
            }
            try ui.expectLabel(ui.app.buttons["player.like"], "Like this song")
            try ui.openExpandedPlayerMenu()
            try tap("player.options.youtubeChanges", ui)
            try ui.expectSwitch("youtubeWrite.allow", isOn: true)
            XCTAssertFalse(ui.app.buttons["youtubeWrite.done"].exists, "The player sheet's own Done is the only Done")
            XCTAssertEqual(ui.app.buttons.matching(NSPredicate(format: "label == %@", "Done")).count, 1)
            try tap("youtubeWrite.like", ui)
            let confirmation = confirmationButton("Like on YouTube", excluding: "youtubeWrite.like", ui)
            try ui.requireHittable(confirmation)
            XCTAssertTrue(ui.app.staticTexts["Changes the connected YouTube account. Check that this is the account you intend to change."].exists)
            XCTAssertFalse(ui.element("youtubeWrite.status").exists, "Opening confirmation alone must not submit the fake action")
            try step("Account / \(appearance): cancel the Like confirmation without submitting", ui) {
                try cancelYouTubeConfirmation(confirmation, ui)
            }
            XCTAssertFalse(ui.element("youtubeWrite.status").exists)
            try tap("youtubeWrite.like", ui)
            try step("Account / \(appearance): confirm Like on YouTube for \(youtubeID) and require its fake-client receipt", ui) {
                try ui.requireHittable(confirmation)
                XCTAssertTrue(ui.app.staticTexts["Changes the connected YouTube account. Check that this is the account you intend to change."].exists)
                XCTAssertFalse(ui.element("youtubeWrite.status").exists)
                try ui.tap(confirmation)
                let status = ui.element("youtubeWrite.status")
                try ui.reveal(status, maxSwipes: 12)
                try ui.wait("Only confirmed fake-client success may publish the production receipt") {
                    status.exists && ui.accessibleText(status).contains("Confirmed on YouTube.")
                }
            }
            capture("account-fake-receipt", appearance, ui)
            try tap("player.options.back", ui)
            try dismissMore(ui)
            try ui.expectLabel(ui.app.buttons["player.like"], "Like this song")
        }
    }

    func testNormalizationCopyPersistenceAndManualExtractorTrustRollbackInLightAndDark() throws {
        for appearance in ["dark", "light"] {
            let ui = try launch(appearance, arguments: ["--r18-import-candidate"])
            defer { ui.finish() }
            try ui.openSettings()
            try ui.openSettingsPage(.playback)
            try ui.expectSwitch("settings.normalize", isOn: true)
            try target(ui.app.switches["settings.normalize"], ui)
            let copy = ui.app.staticTexts["settings.normalize.description"]
            try ui.reveal(copy)
            XCTAssertTrue(copy.label.contains("up to 6 dB"))
            XCTAssertTrue(copy.label.contains("Peak limiting"))
            XCTAssertTrue(copy.label.contains("live radio"))
            try ui.setSwitch("settings.normalize", to: false)
            try ui.openSettingsPage(.account)
            try tap("settings.extractorUpdates", ui)
            try target(ui.app.buttons["extractorUpdates.import"], ui)
            XCTAssertTrue(ui.app.buttons["extractorUpdates.import"].isEnabled)
            XCTAssertFalse(ui.app.buttons["extractorUpdates.check"].exists)
            let disclosure = ui.app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "No trusted update feed is configured.")).firstMatch
            try ui.reveal(disclosure)
            XCTAssertTrue(disclosure.label.contains("Automatic upstream updates are unavailable"))
            try step("Extractor / \(appearance): reveal the validated Revision 1 candidate and its Activate button", ui) {
                let compatible = ui.app.staticTexts["Revision 1 is compatible with this app."]
                try ui.reveal(compatible)
                XCTAssertEqual(compatible.label, "Revision 1 is compatible with this app.")
                let activate = ui.app.buttons["extractorUpdates.activate"]
                try ui.reveal(activate)
                try ui.wait("DEBUG staging must pass the real Files reader and candidate validator", timeout: 100) {
                    activate.exists && activate.isHittable && activate.isEnabled
                }
            }
            let unverified = ui.app.staticTexts["Publisher identity is not verified. The file’s checksum only checks its integrity."]
            try ui.reveal(unverified)
            XCTAssertTrue(unverified.exists)
            try tap("extractorUpdates.activate", ui)
            let trust = ui.app.buttons["Trust Source and Activate"]
            try ui.requireHittable(trust)
            XCTAssertFalse(ui.app.buttons["extractorUpdates.rollback"].exists)
            try step("Extractor / \(appearance): trust the staged manual candidate and require active Revision 1", ui) {
                try ui.tap(trust)
                let rollback = ui.app.buttons["extractorUpdates.rollback"]
                try ui.reveal(rollback)
                try ui.wait("Explicit trust activates provisional rules") { rollback.exists && rollback.isHittable }
                try expectActiveRules("Revision 1", ui)
            }
            let waiting = ui.app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Waiting for successful playback.")).firstMatch
            try ui.reveal(waiting, direction: .down)
            XCTAssertTrue(waiting.exists)
            capture("extractor-provisional", appearance, ui)
            try step("Extractor / \(appearance): roll back Revision 1 and require bundled rules with no provisional state", ui) {
                try tap("extractorUpdates.rollback", ui)
                try expectActiveRules("Bundled", ui)
                XCTAssertFalse(ui.app.buttons["extractorUpdates.rollback"].exists)
                XCTAssertFalse(ui.app.buttons["extractorUpdates.bundled"].exists)
                XCTAssertFalse(ui.app.buttons["extractorUpdates.activate"].exists)
                XCTAssertFalse(waiting.exists)
            }
            try step("Extractor / \(appearance): relaunch the same store and verify normalization Off plus durable rollback", ui) {
                try ui.relaunch()
                try ui.openSettings()
                try ui.openSettingsPage(.playback)
                try ui.expectSwitch("settings.normalize", isOn: false)
                try ui.openSettingsPage(.account)
                try tap("settings.extractorUpdates", ui)
                XCTAssertFalse(ui.app.buttons["extractorUpdates.activate"].exists, "The bootstrap cannot restage an already activated revision")
                XCTAssertFalse(ui.app.buttons["extractorUpdates.rollback"].exists)
                try expectActiveRules("Bundled", ui)
            }
        }
    }

    private func launch(_ appearance: String, arguments: [String] = []) throws -> AppUITestDriver {
        let ui = AppUITestDriver(testCase: self, prefix: "r18-\(appearance)")
        addTeardownBlock { await ui.finish() }
        try ui.launch(additionalArguments: ["--r18-fixture", "--artwork-fixture"]
            + (appearance == "light" ? ["--light"] : []) + arguments)
        return ui
    }

    private func openDirectory(_ ui: AppUITestDriver) throws {
        try ui.selectTab("search")
        try tap("search.liveRadio.open", ui)
        try ui.wait("Search must open the distinct Live Radio destination") { ui.app.navigationBars["Live Radio"].exists }
    }

    private func playAndPauseCurrent(_ ui: AppUITestDriver) throws {
        try ui.openPlayer()
        try playAndPauseVisiblePlayer(ui)
    }

    private func playAndPauseVisiblePlayer(_ ui: AppUITestDriver) throws {
        try step("Player: tap Play, require advancing local AAC, then pause", ui) {
            try ui.expectLabel(ui.app.buttons["player.playPause"], "Play")
            try tap("player.playPause", ui)
            try ui.wait("Locally encoded AAC must actually advance", timeout: 100) {
                ui.app.buttons["player.playPause"].label == "Pause" && (ui.positionIfVisible() ?? 0) > 1
            }
            let position = try ui.position()
            try ui.waitForAdvance(from: position, by: 0.5)
            try ui.pause()
        }
    }

    private func expectActiveRules(_ value: String, _ ui: AppUITestDriver) throws {
        // LabeledContent exposes its title and value as one accessibility label inside the Settings form.
        let row = ui.app.collectionViews["extractorUpdates"].staticTexts["Active Rules, \(value)"]
        try ui.reveal(row, direction: .down)
        try ui.wait("Extractor Updates must display Active Rules, \(value)") { row.exists && row.isHittable }
        XCTAssertEqual(row.label, "Active Rules, \(value)")
    }

    private func dismissMore(_ ui: AppUITestDriver) throws {
        let done = ui.app.buttons["player.options.toolbarDone"]
        if done.exists { try target(done, ui); try ui.tap(done) }
        try ui.wait("The song heart must be reachable after leaving YouTube Changes") { ui.app.buttons["player.like"].isHittable }
    }

    private func confirmationButton(_ title: String, excluding identifier: String, _ ui: AppUITestDriver) -> XCUIElement {
        ui.app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", title, identifier)).firstMatch
    }

    private func cancelYouTubeConfirmation(_ confirmation: XCUIElement, _ ui: AppUITestDriver) throws {
        try ui.requireHittable(confirmation)
        let cancel = ui.app.buttons["Cancel"]
        if cancel.exists {
            try ui.tap(cancel)
        } else {
            try dismissYouTubePopoverOutside(confirmation, ui)
        }
        let like = ui.app.buttons["youtubeWrite.like"]
        try ui.wait("Cancel must remove the native confirmation and return to the enabled YouTube Like row") {
            !confirmation.exists && !ui.app.sheets["Like on YouTube"].exists
                && !ui.app.popovers.buttons.matching(NSPredicate(format: "label == %@", "Like on YouTube")).firstMatch.exists
                && like.exists && like.isHittable && like.isEnabled
        }
        XCTAssertFalse(ui.element("youtubeWrite.status").exists, "Cancelling cannot submit or confirm a fake YouTube write")
        try ui.expectSwitch("youtubeWrite.allow", isOn: true)
    }

    private func dismissYouTubePopoverOutside(_ confirmation: XCUIElement, _ ui: AppUITestDriver) throws {
        let window = ui.app.windows.firstMatch
        let page = ui.app.collectionViews["youtubeWrite.content"]
        let navigation = ui.app.navigationBars["YouTube Changes"]
        let popover = ui.app.popovers.firstMatch
        let textTargets = [
            "Google can see these requests. This unofficial connection may stop working or be refused by YouTube.",
            "Uses the default Google account. Multiple-account and brand-account selection are not supported.",
            "Applies to this YouTube sign-in on this device. Each action below changes YouTube. Local likes, playlists and follows stay separate.",
            "Little Green Receiver",
        ]
        func valid(_ frame: CGRect) -> Bool {
            !frame.isEmpty && !frame.isNull
                && [frame.minX, frame.minY, frame.maxX, frame.maxY].allSatisfy(\.isFinite)
        }
        for attempt in 1...3 {
            let dismissRegions = ui.app.otherElements.matching(identifier: "PopoverDismissRegion").allElementsBoundByIndex
            guard let dismiss = dismissRegions.filter({ valid($0.frame) }).max(by: {
                $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
            }), !ui.app.buttons["Cancel"].exists, ui.app.popovers.count == 1, dismiss.exists,
                  page.exists, navigation.exists, confirmation.exists, confirmation.isHittable else { break }
            let bounds = window.frame, popup = popover.frame, dismissFrame = dismiss.frame
            let pageFrame = page.frame, bar = navigation.frame, confirmFrame = confirmation.frame
            guard [bounds, popup, dismissFrame, pageFrame, bar, confirmFrame].allSatisfy(valid),
                  popup.contains(confirmFrame) else { continue }
            var viewport = bounds.insetBy(dx: 22, dy: 22).intersection(dismissFrame).intersection(pageFrame)
            let top = max(viewport.minY, bar.maxY)
            viewport = CGRect(x: viewport.minX, y: top, width: viewport.width, height: max(0, viewport.maxY - top))
            guard valid(viewport) else { continue }
            for text in textTargets {
                let label = page.staticTexts[text]
                guard label.exists else { continue }
                let labelFrame = label.frame
                let visible = labelFrame.intersection(viewport)
                guard valid(visible), visible.width >= 44, visible.height >= 44 else { continue }
                let point = CGPoint(x: visible.midX, y: visible.midY)
                let touchArea = CGRect(x: point.x - 22, y: point.y - 22, width: 44, height: 44)
                guard viewport.contains(touchArea), !popup.insetBy(dx: -22, dy: -22).intersects(touchArea) else { continue }
                ui.note("r18-cancel-popover-geometry", "Attempt: \(attempt)\nText: \(text)\nWindow: \(bounds)\nPopover: \(popup)\nConfirmation: \(confirmFrame)\nOutside tap: \(point)")
                // Never tap the dismiss region's center: it can overlap the confirmation. Use inert text if a tap passes through.
                guard !ui.app.buttons["Cancel"].exists, ui.app.popovers.count == 1, dismiss.exists,
                      confirmation.exists, confirmation.isHittable, popover.frame == popup,
                      confirmation.frame == confirmFrame, dismiss.frame == dismissFrame, window.frame == bounds,
                      page.frame == pageFrame, navigation.frame == bar, label.frame == labelFrame else { continue }
                window.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: point.x - bounds.minX, dy: point.y - bounds.minY)).tap()
                return
            }
        }
        let message = "No stable, noninteractive point outside the YouTube confirmation popover; no dismissal tap was sent."
        ui.captureFailure("r18-cancel-popover-geometry", detail: message)
        throw AppUIWorkflowFailure(message: message)
    }

    private func tap(_ id: String, _ ui: AppUITestDriver) throws {
        try step("Tap button \(id)", ui) {
            let element = ui.app.buttons[id]
            try target(element, ui)
            try ui.tap(element)
        }
    }

    private func step(_ name: String, _ ui: AppUITestDriver, perform action: () throws -> Void) throws {
        try XCTContext.runActivity(named: "R18: \(name)") { _ in
            do { try action() }
            catch {
                let rules = ui.app.collectionViews["extractorUpdates"].staticTexts
                    .matching(NSPredicate(format: "label BEGINSWITH %@", "Active Rules,")).firstMatch
                ui.note("r18-action-failure", """
                Action: \(name)
                Store: \(ui.storeName)
                Mini-player: \(ui.accessibleText(ui.app.buttons["miniPlayer.open"]))
                Play/pause: \(ui.accessibleText(ui.app.buttons["player.playPause"]))
                Elapsed: \(ui.accessibleText(ui.element("player.elapsed")))
                YouTube result: \(ui.accessibleText(ui.element("youtubeWrite.status")))
                Active rules: \(ui.accessibleText(rules))
                Export error: \(ui.accessibleText(ui.element("export.error")))
                Failure: \(error.localizedDescription)
                """)
                throw error
            }
        }
    }

    private func target(_ element: XCUIElement, _ ui: AppUITestDriver,
                        file: StaticString = #filePath, line: UInt = #line) throws {
        try ui.reveal(element)
        try ui.requireHittable(element)
        XCTAssertGreaterThanOrEqual(element.frame.width + 1e-6, 44, element.identifier, file: file, line: line)
        XCTAssertGreaterThanOrEqual(element.frame.height + 1e-6, 44, element.identifier, file: file, line: line)
        let window = ui.app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(element.frame.minX + 1e-6, window.minX, file: file, line: line)
        XCTAssertLessThanOrEqual(element.frame.maxX, window.maxX + 1e-6, file: file, line: line)
    }

    private func capture(_ stage: String, _ appearance: String, _ ui: AppUITestDriver) {
        let width = ui.app.windows.firstMatch.frame.width
        let device = width >= 700 ? "ipad" : width <= 390 ? "small-phone" : "phone"
        ui.capture("r18-\(device)-\(appearance)-\(stage)")
    }
}

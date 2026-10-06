import XCTest

@MainActor
final class GanaBajanaSeedRadioUITests: XCTestCase {
    private let baseSongs = [AppUIFixture.tumHiHo, AppUIFixture.kesariya, AppUIFixture.agarTumSaathHo,
                             AppUIFixture.blindingLights, AppUIFixture.shapeOfYou]
    private let weekndID = "UCfixtureTheWeeknd000001"

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 600
    }

    func testSongSearchTuneAndListenAgainSurviveRelaunchInLightAndDark() throws {
        for appearance in ["light", "dark"] {
            let ui = try launch("seed-radio-\(appearance)", arguments: appearance == "light" ? ["--light"] : [])
            try openRadio(ui)
            try ui.requireHittable(ui.element("radio.search.guidance"))
            XCTAssertFalse(ui.element("radio.setup").exists, "Browsing Radio must not present a setup sheet")
            XCTAssertFalse(ui.element("radio.session").exists)
            ui.capture("seed-radio-browse-\(appearance)")

            try search("Tum Hi Ho", ui: ui)
            let result = ui.app.buttons["radio.search.song.\(AppUIFixture.tumHiHo)"]
            try ui.requireHittable(result)
            XCTAssertEqual(result.label, "Start Tum Hi Ho Radio, Arijit Singh")
            assertTouchTarget(result)
            try ui.tap(result)
            try expectSession("Tum Hi Ho Radio", ui: ui)
            XCTAssertFalse(ui.app.buttons["player.close"].exists, "Starting radio must leave the listener browsing")

            try ui.openPlayer()
            try readyAndPause(AppUIFixture.tumHiHo, ui: ui)
            let position = try seekWhilePaused(ui)
            try ui.openPlayerSheet("queue", title: "Queue")
            try expectQueueTitle("Tum Hi Ho Radio", ui: ui)
            let originalQueue = try baseQueueSnapshot(ui)
            try openTune("queue.radio", ui: ui)
            try choose("Familiar", picker: "radio.tune.familiarity", ui: ui)
            try choose("English", picker: "radio.tune.language", ui: ui)
            try ui.tap(ui.app.buttons["radio.tune.cancel"])
            try expectTuneDismissed(ui)
            try ui.expectLabel(ui.element("queue.radio.tuning"), "Balanced · Automatic Language")

            try openTune("queue.radio", ui: ui)
            try ui.expectValue(ui.app.buttons["radio.tune.familiarity"], "Balanced")
            try ui.expectValue(ui.app.buttons["radio.tune.language"], "Automatic")
            try choose("Discover", picker: "radio.tune.familiarity", ui: ui)
            try choose("Hindi", picker: "radio.tune.language", ui: ui)
            XCTAssertTrue(ui.app.staticTexts["Applies to future radio additions. Songs already queued keep their place."].exists)
            ui.capture("seed-radio-tune-\(appearance)")
            try ui.tap(ui.app.buttons["radio.tune.done"])
            try expectTuneDismissed(ui)
            try ui.expectLabel(ui.element("queue.radio.tuning"), "Discover · Hindi")
            XCTAssertEqual(try baseQueueSnapshot(ui), originalQueue, "Tuning must keep even the already-queued English songs in place")
            try ui.closeSheet("Queue")
            try ui.expectCurrentTrack(AppUIFixture.tumHiHo)
            try ui.expectLabel(ui.app.buttons["player.playPause"], "Play")
            try ui.expectPosition(position)
            try ui.closePlayer()

            try ui.relaunch()
            try openRadio(ui)
            XCTAssertFalse(ui.element("radio.session").exists, "A restored queue does not silently restart radio")
            let again = ui.app.buttons["radio.listenAgain.song:\(AppUIFixture.tumHiHo)"]
            try ui.reveal(again)
            XCTAssertEqual(again.label, "Start Tum Hi Ho Radio, Discover · Hindi")
            assertTouchTarget(again)
            ui.capture("seed-radio-listen-again-\(appearance)")
            try ui.tap(again)
            try expectSession("Tum Hi Ho Radio", tuning: "Discover · Hindi", ui: ui)
            XCTAssertFalse(ui.app.buttons["player.close"].exists)
            try ui.openPlayer()
            try ui.expectCurrentTrack(AppUIFixture.tumHiHo)
            try ui.expectPosition(position)
            try ui.openPlayerSheet("queue", title: "Queue")
            try expectQueueTitle("Tum Hi Ho Radio", ui: ui)
            XCTAssertEqual(try baseQueueSnapshot(ui), originalQueue)

            // Next reaches the refill threshold while staying within the five cached base recordings.
            let nextID = try XCTUnwrap(originalQueue.first { $0.value.hasPrefix("queue.play.1.") }?.key)
            try ui.closeSheet("Queue")
            try ui.tap(ui.app.buttons["player.next"])
            try ui.expectCurrentTrack(nextID)
            try ui.play()
            try ui.waitForAdvance(from: 0, by: 1)
            try ui.openPlayerSheet("queue", title: "Queue")
            try ui.reveal(queueCountLabel(ui))
            try ui.wait("The restarted tuned radio must add songs beyond the original five", timeout: 15) {
                self.queueCount(ui).map { $0 > 5 } == true
            }
            try ui.closeSheet("Queue")
            try ui.pause()
            try ui.expectCurrentTrack(nextID)
            try ui.closePlayer()
            ui.app.terminate()
        }
    }

    func testExactArtistSearchAndPlayerMoreKeepTheCurrentSongPositionAndQueue() throws {
        let ui = try launch("seed-radio-artist")
        try openRadio(ui)
        try choose("Artists", picker: "radio.search.type", ui: ui)
        try search("The Weeknd", ui: ui)
        let artist = ui.app.buttons["radio.search.artist.\(weekndID)"]
        try ui.requireHittable(artist)
        XCTAssertEqual(artist.label, "Start The Weeknd Radio, Artist")
        assertTouchTarget(artist)
        try ui.tap(artist)
        try expectSession("The Weeknd Radio", ui: ui)
        XCTAssertFalse(ui.app.buttons["player.close"].exists)
        try ui.openPlayer()
        try readyAndPause(AppUIFixture.blindingLights, ui: ui)
        XCTAssertEqual(ui.app.staticTexts["player.track.\(AppUIFixture.blindingLights)"].label, "Blinding Lights")
        let position = try seekWhilePaused(ui)
        try ui.openPlayerSheet("queue", title: "Queue")
        try expectQueueTitle("The Weeknd Radio", ui: ui)
        let originalQueue = try baseQueueSnapshot(ui)
        try ui.closeSheet("Queue")

        try ui.openExpandedPlayerMenu()
        let start = ui.app.buttons["player.options.radio"]
        try ui.reveal(start, direction: .down)
        XCTAssertEqual(start.label, "Start Radio")
        assertTouchTarget(start)
        try ui.tap(start)
        try ui.wait("Start Radio must dismiss Song Options") { !ui.element("player.options.sheet").exists }
        try ui.expectCurrentTrack(AppUIFixture.blindingLights)
        try ui.expectLabel(ui.app.buttons["player.playPause"], "Play")
        try ui.expectPosition(position)
        try ui.openPlayerSheet("queue", title: "Queue")
        try expectQueueTitle("Blinding Lights Radio", ui: ui)
        XCTAssertEqual(try baseQueueSnapshot(ui), originalQueue, "Player More must preserve every queue occurrence")
        ui.capture("seed-radio-player-more-queue")
        try ui.closeSheet("Queue")
        try ui.expectPosition(position)
        try ui.closePlayer()
        try expectSession("Blinding Lights Radio", ui: ui)
        XCTAssertFalse(ui.app.buttons["player.close"].exists)
    }

    func testSongMenuAndArtistPageStartRadioWithoutSetup() throws {
        let ui = try launch("seed-radio-entry-points")
        try ui.search("Tum Hi Ho")
        try ui.tap(ui.app.buttons["track.options.\(AppUIFixture.tumHiHo)"])
        let songRadio = ui.app.buttons["track.radio.\(AppUIFixture.tumHiHo)"]
        try ui.requireHittable(songRadio)
        try ui.tap(songRadio)
        XCTAssertFalse(ui.element("radio.setup").exists)
        XCTAssertFalse(ui.app.buttons["player.close"].exists)
        try ui.openPlayer()
        try readyAndPause(AppUIFixture.tumHiHo, ui: ui)
        XCTAssertEqual(ui.element("player.context").label, "Tum Hi Ho Radio")
        try ui.closePlayer()

        try ui.search("The Weeknd")
        try ui.selectSearchFilter("artists")
        try ui.tap(ui.app.buttons["collection.\(weekndID)"])
        let artistRadio = ui.app.buttons["collection.radio"]
        try ui.reveal(artistRadio)
        assertTouchTarget(artistRadio)
        XCTAssertEqual(artistRadio.label, "Start The Weeknd Radio")
        try ui.tap(artistRadio)
        XCTAssertFalse(ui.element("radio.setup").exists)
        XCTAssertFalse(ui.app.buttons["player.close"].exists)
        try ui.openPlayer()
        try readyAndPause(AppUIFixture.blindingLights, ui: ui)
        XCTAssertEqual(ui.element("player.context").label, "The Weeknd Radio")
        ui.capture("seed-radio-artist-page-start")
    }

    func testTuneToolbarRemainsReadableAndCancelKeepsTheQueue() throws {
        for appearance in ["light", "dark"] {
            let ui = try launch("radio-toolbar-\(appearance)", arguments: appearance == "light" ? ["--light"] : [])
            try openRadio(ui)
            try search("Tum Hi Ho", ui: ui)
            try ui.tap(ui.app.buttons["radio.search.song.\(AppUIFixture.tumHiHo)"])
            try expectSession("Tum Hi Ho Radio", ui: ui)
            try ui.openPlayer()
            try ui.openPlayerSheet("queue", title: "Queue")
            try openTune("queue.radio", ui: ui)
            let cancel = ui.app.buttons["radio.tune.cancel"]
            XCTAssertEqual(cancel.label, "Cancel")
            XCTAssertGreaterThanOrEqual(cancel.frame.width, 64, "Cancel must fit on one line in the nested toolbar")
            ui.capture("radio-tune-toolbar-\(appearance)")
            try ui.tap(cancel)
            try expectTuneDismissed(ui)
            try expectQueueTitle("Tum Hi Ho Radio", ui: ui)
            ui.app.terminate()
        }
    }

    func testContinuationFailureRetriesWithoutLosingSeedAndHistoryPrivacyClearsListenAgain() throws {
        let ui = try launch("seed-radio-retry-privacy", arguments: ["--seed-radio-fail-once"])
        try openRadio(ui)
        let suggestion = ui.app.buttons["radio.suggestion.\(AppUIFixture.kesariya)"]
        try ui.reveal(suggestion)
        XCTAssertEqual(suggestion.label, "Start Kesariya Radio, Arijit Singh")
        assertTouchTarget(suggestion)
        try ui.tap(suggestion)
        try expectSession("Kesariya Radio", ui: ui)
        try ui.wait("The failed continuation must offer an explicit retry") {
            ui.element("radio.session.continuationError").exists && ui.app.buttons["radio.session.retryContinuation"].exists
        }
        XCTAssertFalse(ui.element("radio.session.error").exists, "Continuation failure is not seed-start failure")
        try ui.openPlayer()
        try readyAndPause(AppUIFixture.kesariya, expectedSongs: 1, ui: ui)
        let position = try ui.position()
        try ui.openPlayerSheet("queue", title: "Queue")
        try expectQueueTitle("Kesariya Radio", ui: ui)
        try ui.reveal(queueCountLabel(ui))
        try ui.wait("Only the playable seed remains after the failed first fetch") { self.queueCount(ui) == 1 }
        let seed = ui.app.buttons["queue.play.0.\(AppUIFixture.kesariya)"]
        try ui.reveal(seed)
        XCTAssertEqual(seed.label, "Current song, Kesariya, Arijit Singh")
        let retry = ui.app.buttons["queue.radio.retryContinuation"]
        try ui.reveal(retry, direction: .down)
        XCTAssertEqual(retry.label, "Try More Songs")
        assertTouchTarget(retry)
        ui.capture("seed-radio-continuation-failed")
        try ui.tap(retry)
        try ui.reveal(queueCountLabel(ui))
        try ui.wait("Retry must clear the failure and append the other four base songs") {
            !ui.element("queue.radio.continuationError").exists && self.queueCount(ui) == 5
        }
        _ = try baseQueueSnapshot(ui)
        try ui.closeSheet("Queue")
        try ui.expectCurrentTrack(AppUIFixture.kesariya)
        try ui.expectPosition(position)
        try ui.expectLabel(ui.app.buttons["player.playPause"], "Play")
        try ui.closePlayer()
        let again = ui.app.buttons["radio.listenAgain.song:\(AppUIFixture.kesariya)"]
        try ui.reveal(again)

        try ui.openSettings()
        try ui.setSwitch("settings.history", to: false)
        try closeSettings(ui)
        try openRadio(ui)
        try expectNoListenAgain(ui)
        try expectSession("Kesariya Radio", ui: ui)
        try ui.openSettings()
        try ui.setSwitch("settings.history", to: true)
        try closeSettings(ui)
        try openRadio(ui)
        try expectNoListenAgain(ui)
        try ui.reveal(suggestion)
        try ui.tap(suggestion)
        try ui.reveal(again)
        XCTAssertEqual(again.label, "Start Kesariya Radio, Balanced · Automatic Language")

        try ui.openSettings()
        try ui.openSettingsPage(.library)
        let clear = ui.app.buttons["settings.clearHistory"]
        try ui.reveal(clear)
        try ui.tap(clear)
        let confirmation = ui.app.alerts["Clear Your Listening History?"]
        try ui.tap(confirmation.buttons["Clear History"])
        try ui.wait("Clear History must finish and dismiss confirmation") { !confirmation.exists }
        try closeSettings(ui)
        try openRadio(ui)
        try expectNoListenAgain(ui)
        try expectSession("Kesariya Radio", ui: ui)
        try ui.openPlayer()
        try ui.expectCurrentTrack(AppUIFixture.kesariya)
        try ui.expectPosition(position)
        try ui.closePlayer()
        try ui.relaunch()
        try openRadio(ui)
        try expectNoListenAgain(ui)
        ui.capture("seed-radio-history-cleared")
    }

    func testCancellingAndSupersedingSlowArtistStartsKeepsOnlyTheLatestSelection() throws {
        let ui = try launch("seed-radio-cancel", arguments: ["--seed-radio-slow-artist"])
        try ui.playSeededPlaylist()
        try ui.openPlayer()
        try readyAndPause(AppUIFixture.tumHiHo, ui: ui)
        let position = try seekWhilePaused(ui)
        try ui.closePlayer()
        try openRadio(ui)
        try choose("Artists", picker: "radio.search.type", ui: ui)
        try search("The Weeknd", ui: ui)
        try ui.tap(ui.app.buttons["radio.search.artist.\(weekndID)"])
        let cancel = ui.app.buttons["radio.session.cancel"]
        try ui.requireHittable(cancel)
        XCTAssertTrue(ui.element("radio.session.loading").exists)
        try ui.tap(cancel)
        try ui.wait("Cancel must retire the pending artist start") {
            !ui.element("radio.session.loading").exists && !cancel.exists
        }
        try ui.openPlayer()
        try ui.expectCurrentTrack(AppUIFixture.tumHiHo)
        try ui.expectPosition(position)
        try ui.assertPausedPositionStaysPut(for: 3.5)
        try ui.expectCurrentTrack(AppUIFixture.tumHiHo)
        try ui.openPlayerSheet("queue", title: "Queue")
        XCTAssertFalse(ui.element("queue.radio").exists)
        _ = try baseQueueSnapshot(ui)
        try ui.closeSheet("Queue")
        try ui.closePlayer()
        XCTAssertFalse(ui.app.buttons["radio.listenAgain.artist:\(weekndID)"].exists)

        try search("a", ui: ui)
        let arijit = ui.app.buttons["radio.search.artist.\(AppUIFixture.arijitSinghID)"]
        let alka = ui.app.buttons["radio.search.artist.\(AppUIFixture.alkaYagnikID)"]
        try ui.requireHittable(arijit)
        try ui.requireHittable(alka)
        try ui.tap(arijit)
        try ui.tap(alka)
        try expectSession("Alka Yagnik Radio", ui: ui)
        XCTAssertFalse(ui.app.buttons["radio.listenAgain.artist:\(AppUIFixture.arijitSinghID)"].exists,
                       "The superseded artist must not enter Listen Again")
        XCTAssertFalse(ui.app.buttons["player.close"].exists)
        try ui.openPlayer()
        try readyAndPause(AppUIFixture.agarTumSaathHo, ui: ui)
        try ui.openPlayerSheet("queue", title: "Queue")
        try expectQueueTitle("Alka Yagnik Radio", ui: ui)
        _ = try baseQueueSnapshot(ui)
        ui.capture("seed-radio-latest-artist-after-cancel")
    }

    private func launch(_ prefix: String, arguments: [String] = []) throws -> AppUITestDriver {
        let ui = AppUITestDriver(testCase: self, prefix: prefix)
        addTeardownBlock { await ui.finish() }
        try ui.launch(additionalArguments: ["--cache-fixture", "--seed-radio-fixture"] + arguments)
        return ui
    }

    private func openRadio(_ ui: AppUITestDriver) throws {
        try ui.tap(ui.tabButton("search"))
        try ui.wait("Search must show Radio or its browse entry") {
            ui.app.navigationBars["Radio"].exists || ui.app.buttons["search.radio.open"].exists
        }
        if !ui.app.navigationBars["Radio"].exists {
            let entry = ui.app.buttons["search.radio.open"]
            try ui.reveal(entry, direction: .down)
            try ui.tap(entry)
        }
        try ui.requireHittable(ui.app.searchFields["Songs or artists"])
    }

    private func search(_ query: String, ui: AppUITestDriver) throws {
        let field = ui.app.searchFields["Songs or artists"]
        try ui.tap(field)
        if field.buttons["Clear text"].exists {
            try ui.tap(field.buttons["Clear text"])
            // Clearing a native search field can relinquish keyboard focus on iPad.
            try ui.tap(field)
        }
        try ui.dismissKeyboardIntroduction()
        try ui.wait("Radio search must have keyboard focus before typing") {
            (field.value(forKey: "hasKeyboardFocus") as? Bool) == true
        }
        field.typeText(query)
    }

    private func choose(_ title: String, picker: String, ui: AppUITestDriver) throws {
        let control = ui.app.buttons[picker]
        try ui.reveal(control, direction: .down)
        assertTouchTarget(control)
        try ui.tap(control)
        try ui.tap(ui.app.buttons[title])
        try ui.expectValue(control, title)
    }

    private func expectSession(_ title: String, tuning: String = "Balanced · Automatic Language", ui: AppUITestDriver) throws {
        try ui.wait("Radio must accept the selected seed") { !ui.element("radio.session.loading").exists && ui.element("radio.session").exists }
        try ui.reveal(ui.element("radio.session"), direction: .down)
        try ui.expectLabel(ui.element("radio.session"), title)
        try ui.expectLabel(ui.element("radio.session.tuning"), tuning)
    }

    private func expectQueueTitle(_ title: String, ui: AppUITestDriver) throws {
        try ui.reveal(ui.element("queue.radio"), direction: .down)
        try ui.expectLabel(ui.element("queue.radio"), title)
    }

    private func readyAndPause(_ id: String, expectedSongs: Int = 5, ui: AppUITestDriver) throws {
        try ui.expectCurrentTrack(id)
        try ui.wait("The cached seed must become ready", timeout: 15) {
            ["Play", "Pause"].contains(ui.app.buttons["player.playPause"].label) && ui.app.sliders["player.seek"].isEnabled
        }
        if ui.app.buttons["player.playPause"].label == "Play" { try ui.play() }
        try ui.waitForAdvance(from: try ui.position(), by: 1)
        try ui.openPlayerSheet("queue", title: "Queue")
        try ui.reveal(queueCountLabel(ui))
        try ui.wait("The initial queue must settle before pausing cancels pending requests", timeout: 15) {
            self.queueCount(ui) == expectedSongs
        }
        try ui.closeSheet("Queue")
        try ui.pause()
    }

    private func seekWhilePaused(_ ui: AppUITestDriver) throws -> TimeInterval {
        let target = try ui.duration() * 0.25
        try ui.seek(to: 0.25)
        try ui.expectPosition(target, tolerance: 2)
        return try ui.position()
    }

    private func openTune(_ session: String, ui: AppUITestDriver) throws {
        let tune = ui.app.buttons["\(session).tune"]
        try ui.reveal(tune, direction: .down)
        assertTouchTarget(tune)
        try ui.tap(tune)
        try ui.requireHittable(ui.app.buttons["radio.tune.done"])
        assertTouchTarget(ui.app.buttons["radio.tune.done"])
        assertTouchTarget(ui.app.buttons["radio.tune.cancel"])
    }

    private func expectTuneDismissed(_ ui: AppUITestDriver) throws {
        try ui.wait("Tune must dismiss back to the queue") { !ui.app.buttons["radio.tune.done"].exists }
    }

    private func baseQueueSnapshot(_ ui: AppUITestDriver) throws -> [String: String] {
        try ui.reveal(queueCountLabel(ui))
        try ui.wait("The queue must contain exactly the five base recordings") { self.queueCount(ui) == 5 }
        var snapshot: [String: String] = [:]
        for id in baseSongs {
            let row = ui.queueSong(id: id)
            try ui.reveal(row)
            snapshot[id] = row.identifier
        }
        return snapshot
    }

    private func queueCount(_ ui: AppUITestDriver) -> Int? {
        let count = queueCountLabel(ui)
        guard count.exists else { return nil }
        return count.label.split(separator: " ").first.flatMap { Int($0) }
    }

    private func queueCountLabel(_ ui: AppUITestDriver) -> XCUIElement {
        ui.app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@ AND label CONTAINS[c] %@", "song", " of ")).firstMatch
    }

    private func closeSettings(_ ui: AppUITestDriver) throws {
        try ui.tap(ui.app.buttons["settings.done"])
        try ui.wait("Settings must dismiss") { !ui.app.buttons["settings.done"].exists }
    }

    private func expectNoListenAgain(_ ui: AppUITestDriver) throws {
        try ui.wait("History privacy must remove Listen Again") {
            !ui.app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "radio.listenAgain.")).firstMatch.exists
        }
    }

    private func assertTouchTarget(_ control: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(control.frame.width + 1e-6, 44, control.identifier, file: file, line: line)
        XCTAssertGreaterThanOrEqual(control.frame.height + 1e-6, 44, control.identifier, file: file, line: line)
    }
}

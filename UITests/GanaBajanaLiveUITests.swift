import Foundation
import XCTest

final class GanaBajanaLiveUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLiveRecordingPlaysSeeksShowsSyncedLyricsAndContinuesInBackground() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["GANABAJANA_LIVE_UI"] == "1",
                          "Set GANABAJANA_LIVE_UI=1 in the UI-test runner environment to exercise live providers.")
        let ui = AppUITestDriver(testCase: self, prefix: "live-ui")
        addTeardownBlock { await ui.finish() }
        try ui.launch(mode: .live)
        XCTAssertFalse(ui.app.launchArguments.contains("--seed-ui"))

        // Pin the recording: music videos and covers can have different durations and lyric timings.
        let recordingID = "fsiPzT50ZiM"
        try ui.search("Tum Hi Ho Arijit Singh")
        try ui.playSearchResult(id: recordingID, title: "Tum Hi Ho", timeout: 90)
        try ui.openPlayer()
        try ui.expectCurrentTrack(recordingID)
        try expectLiveAdvance(ui, from: 0, by: 4, phase: "initial-stream")
        XCTAssertEqual(try ui.duration(), 262, accuracy: 3, "The test must use the verified studio recording.")
        // The artist line is a button now, so the name lives in its label rather than a static text.
        XCTAssertTrue(ui.app.buttons["player.artistName"].label.localizedCaseInsensitiveContains("Arijit Singh"))
        ui.capture("live-player-tum-hi-ho-advancing")
        ui.note("live-recording", "Recording: \(recordingID)\nVisible duration: \(try ui.duration()) seconds\nStore: \(ui.storeName)")

        try ui.pause()
        try ui.assertPausedPositionStaysPut(for: 3)
        let duration = try ui.duration()
        try ui.seek(to: 0.35)
        try ui.expectPosition(duration * 0.35, tolerance: 4)
        try ui.assertPausedPositionStaysPut()
        let soughtPosition = try ui.position()
        try ui.play()
        try expectLiveAdvance(ui, from: soughtPosition, by: 3, phase: "after-seek")
        try ui.pause()
        let beforeLyricSeek = try ui.position()
        ui.capture("live-player-paused-after-real-seek")

        try ui.openPlayerSheet("lyrics", title: "Lyrics")
        try ui.requireSyncedLyrics(timeout: 90)
        let current = ui.app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND value == %@", "lyrics.line.", "Current line"
        )).firstMatch
        try ui.requireHittable(current, timeout: 15)
        guard let currentIndex = lyricIndex(current.identifier) else {
            throw AppUIWorkflowFailure(message: "The matched lyric has no usable line identifier.")
        }
        ui.capture("live-lyrics-matched-synchronized-recording")
        let nextLine = try futureLyric(after: currentIndex, using: ui)
        let nextLineID = nextLine.identifier
        try ui.tap(nextLine)
        try ui.expectCurrentLyric(nextLineID)
        ui.capture("live-lyrics-tapped-future-line")
        try ui.closeSheet("Lyrics")
        try ui.reveal(ui.app.sliders["player.seek"], direction: .down)
        try ui.wait("Tapping a future live lyric must seek the visible player forward") {
            guard let position = ui.positionIfVisible() else { return false }
            return position > beforeLyricSeek
        }
        try ui.expectLabel(ui.app.buttons["player.playPause"], "Play")
        let lyricPosition = try ui.position()
        try ui.play()
        try expectLiveAdvance(ui, from: lyricPosition, by: 3, phase: "after-lyric-seek")

        let beforeBackground = try ui.position()
        let sampleStarted = Date()
        XCUIDevice.shared.press(.home)
        try ui.wait("GanaBajana must enter the background without terminating", timeout: 10) {
            ui.app.state == .runningBackground || ui.app.state == .runningBackgroundSuspended
        }
        // A real background interval is needed; the app's accessibility tree cannot show live audio progress here.
        try await Task.sleep(for: .seconds(8))
        ui.app.activate()
        try ui.wait("GanaBajana must return to the foreground", timeout: 15) { ui.app.state == .runningForeground }
        let afterBackground = try ui.position()
        let wallSeconds = Date().timeIntervalSince(sampleStarted)
        let playbackSeconds = afterBackground - beforeBackground
        ui.note("live-background-timing", """
        Before background: \(beforeBackground)
        First position after activation: \(afterBackground)
        Playback delta: \(playbackSeconds)
        Wall-clock delta: \(wallSeconds)
        These observations verify transport progress, not audible quality.
        """)
        XCTAssertGreaterThanOrEqual(playbackSeconds, 6, "Playback must advance during the background interval.")
        XCTAssertEqual(playbackSeconds, wallSeconds, accuracy: 4,
                       "The first foreground sample must include background playback, not just resumed playback after activation.")
        try ui.expectCurrentTrack(recordingID)
        try ui.waitForAdvance(from: afterBackground, by: 2, timeout: 20)
        ui.capture("live-player-after-background-reactivation")
        try ui.pause()
        try ui.assertPausedPositionStaysPut()
    }

    @MainActor
    func testLiveArtistSearchLeadsWithTheArtistAndCrossfadeStartsBeforeTheSongEnds() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["GANABAJANA_LIVE_UI"] == "1",
                          "Set GANABAJANA_LIVE_UI=1 in the UI-test runner environment to exercise live providers.")
        let ui = AppUITestDriver(testCase: self, prefix: "live-crossfade")
        addTeardownBlock { await ui.finish() }
        try ui.launch(mode: .live)

        // Crossfade is off by default; the test turns it up through the real setting.
        try ui.openSettings()
        try ui.openSettingsPage(.playback)
        let slider = ui.app.sliders["settings.crossfade"]
        try ui.reveal(slider)
        slider.adjust(toNormalizedSliderPosition: 0.5)
        try ui.wait("The crossfade slider must report the chosen seconds") {
            (slider.value as? String).map { $0.hasPrefix("6 s") || $0.hasPrefix("5 s") || $0.hasPrefix("7 s") } ?? false
        }
        let crossfade = TimeInterval(Int((slider.value as? String)?.prefix(1) ?? "6") ?? 6)
        ui.capture("live-settings-crossfade")
        try ui.tap(ui.app.buttons["settings.done"])

        // "A. R. Rahman" used to surface Quran recitations titled "Al Rahman" first.
        try ui.search("A. R. Rahman")
        try ui.waitForSearchResults(timeout: 90)
        try ui.wait("An artist query must resolve to the artist card", timeout: 30) {
            ui.app.buttons["search.featuredArtist"].exists || ui.app.otherElements["search.featuredArtist"].exists
        }
        let rows = ui.app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "track.play."))
        try ui.wait("Song results must be present", timeout: 30) { rows.count >= 3 }
        let leading = rows.allElementsBoundByIndex.prefix(3).map(\.label)
        ui.note("live-rahman-results", leading.joined(separator: "\n"))
        for label in leading {
            XCTAssertTrue(label.localizedCaseInsensitiveContains("Rahman"), "Leading result must be by the artist: \(label)")
            XCTAssertFalse(label.hasPrefix("Al Rahman,") || label.hasPrefix("Surah Ar-Rahman,"),
                           "Recitations must not lead an artist search: \(label)")
        }
        ui.capture("live-search-rahman")

        let first = rows.element(boundBy: 0)
        let firstID = String(first.identifier.dropFirst("track.play.".count))
        try ui.tap(first)
        try ui.wait("Playing the result must update the mini-player", timeout: 60) { ui.app.buttons["miniPlayer.open"].exists }
        try ui.openPlayer()
        try ui.expectCurrentTrack(firstID)
        try expectLiveAdvance(ui, from: 0, by: 4, phase: "artist-first-result")
        let duration = try ui.duration()
        XCTAssertGreaterThan(duration, 60)

        // Leave about twice the crossfade before the end so the blend has a clear window to start in.
        try ui.seek(to: (duration - crossfade * 2 - 2) / duration)
        try ui.wait("The seek must land near the end") {
            guard let position = ui.positionIfVisible() else { return false }
            return position > duration - crossfade * 2 - 8 && position < duration - crossfade - 1
        }
        let seekPosition = try ui.position()
        let seekWall = Date()
        try ui.wait("The next song must start before the first one ends", timeout: crossfade * 2 + 20) {
            !ui.app.staticTexts["player.track.\(firstID)"].exists
        }
        let switchedAfter = Date().timeIntervalSince(seekWall)
        let remainingAtSwitch = duration - seekPosition - switchedAfter
        ui.note("live-crossfade-timing", """
        Crossfade setting: \(crossfade) s
        Position after seek: \(seekPosition) of \(duration)
        Song changed \(switchedAfter) s after the seek; about \(remainingAtSwitch) s of the first song remained.
        """)
        XCTAssertGreaterThan(remainingAtSwitch, 1.5, "The incoming song must take over while the outgoing song still has time left.")
        XCTAssertLessThan(remainingAtSwitch, crossfade + 4, "The blend must start close to the configured crossfade, not long before.")
        let nextTitle = ui.app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "player.track.")).firstMatch
        try ui.requireHittable(nextTitle, timeout: 10)
        XCTAssertNotEqual(nextTitle.identifier, "player.track.\(firstID)")
        try ui.waitForAdvance(from: 0, by: 3, timeout: 30)
        try ui.expectLabel(ui.app.buttons["player.playPause"], "Pause")
        ui.capture("live-player-after-crossfade")
        try ui.pause()
    }

    @MainActor
    private func expectLiveAdvance(_ ui: AppUITestDriver, from start: TimeInterval,
                                   by delta: TimeInterval, phase: String) throws {
        let retry = ui.app.buttons["player.retry"]
        try ui.wait("Live audio must advance or expose a retryable error during \(phase)", timeout: 100) {
            if retry.exists { return true }
            guard let position = ui.positionIfVisible(), ui.app.buttons["player.playPause"].exists else { return false }
            return position >= start + delta && ui.app.buttons["player.playPause"].label == "Pause"
        }
        if retry.exists {
            ui.capture("live-\(phase)-before-retry")
            ui.note("live-\(phase)-retry-diagnostics", ui.app.debugDescription)
            try ui.reveal(retry)
            try ui.tap(retry)
            try ui.reveal(ui.app.sliders["player.seek"], direction: .down)
        }
        try ui.waitForAdvance(from: start, by: delta, timeout: 100)
        XCTAssertFalse(retry.exists, "A retry must recover playback, not leave an error alongside a stale counter.")
    }

    @MainActor
    private func futureLyric(after index: Int, using ui: AppUITestDriver) throws -> XCUIElement {
        for attempt in 0..<4 {
            let candidates = ui.app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "lyrics.line."))
                .allElementsBoundByIndex.filter { element in
                    element.exists && element.isHittable && (lyricIndex(element.identifier) ?? -1) > index
                }
            if let last = candidates.max(by: { (lyricIndex($0.identifier) ?? -1) < (lyricIndex($1.identifier) ?? -1) }) {
                return last
            }
            if attempt < 3 { try ui.scrollable().swipeUp() }
        }
        throw AppUIWorkflowFailure(message: "The verified live recording has no reachable future synchronized lyric near the current line.")
    }

    private func lyricIndex(_ identifier: String) -> Int? {
        guard identifier.hasPrefix("lyrics.line."), let suffix = identifier.split(separator: ".").last else { return nil }
        return Int(suffix)
    }
}

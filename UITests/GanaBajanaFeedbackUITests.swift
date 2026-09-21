import Foundation
import XCTest

@MainActor
final class GanaBajanaFeedbackUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testCollapsedPlaybackFailureKeepsItsRetryAfterTheBannerExpiresAndRecoversInPlace() throws {
        let ui = makeDriver()
        try ui.launch(additionalArguments: ["--fail-audio-once", "--slow-audio"])
        try ui.searchAndPlayTumHiHo()
        let transport = ui.app.buttons["miniPlayer.playPause"]
        let next = ui.app.buttons["miniPlayer.next"]
        let open = ui.app.buttons["miniPlayer.open"]
        try ui.expectValue(transport, "Loading")
        let loadingFrame = transport.frame
        let nextFrame = next.frame

        try ui.expectLabel(transport, "Retry playback")
        try ui.expectValue(transport, "Synthetic audio connection failure")
        try ui.expectLabel(open, "Open player, Tum Hi Ho, Arijit Singh")
        try ui.expectValue(open, "Playback failed. Synthetic audio connection failure")
        let message = ui.app.staticTexts["message.text"]
        try ui.expectLabel(message, "Couldn’t play Tum Hi Ho. Synthetic audio connection failure")
        XCTAssertTrue(ui.app.buttons["message.playbackRetry"].exists)
        XCTAssertFalse(ui.app.buttons["player.close"].exists)
        assertSameFrame(transport.frame, loadingFrame)
        assertSameFrame(next.frame, nextFrame)
        XCTAssertEqual(ui.element("miniPlayer.container").frame.height, 64, accuracy: 1)
        XCTAssertEqual(transport.frame.width, 52, accuracy: 1)
        XCTAssertEqual(transport.frame.height, 52, accuracy: 1)
        ui.capture("feedback-collapsed-playback-failure")

        try ui.wait("The temporary banner must expire", timeout: 8) { !message.exists }
        try ui.expectLabel(transport, "Retry playback")
        try ui.expectValue(open, "Playback failed. Synthetic audio connection failure")
        try ui.assertMiniPlayerAboveTabs()
        try ui.selectTab("library")
        try ui.requireHittable(ui.app.buttons["library.createPlaylist"])
        try ui.selectTab("search")
        try ui.expectValue(ui.app.textFields["search.field"], "Tum Hi Ho")
        try ui.requireHittable(ui.app.buttons["track.options.\(AppUIFixture.tumHiHo)"])

        try ui.tap(transport)
        try ui.expectValue(transport, "Loading")
        assertSameFrame(transport.frame, loadingFrame)
        assertSameFrame(next.frame, nextFrame)
        try waitForCollapsedPlaybackToAdvance(ui)
        XCTAssertFalse(message.exists)
        try ui.expectLabel(open, "Open player, Tum Hi Ho, Arijit Singh")
        XCTAssertFalse(ui.app.buttons["player.close"].exists, "Retry must recover without opening the full player")
        try ui.tap(transport)
        try ui.expectLabel(transport, "Play")
        ui.capture("feedback-collapsed-playback-recovered")
    }

    func testPlaybackFailureBannerCanRetryWhileTheSearchKeyboardHidesTheMiniPlayer() throws {
        let ui = makeDriver()
        try ui.launch(additionalArguments: ["--fail-audio-once", "--slow-audio"])
        try ui.searchAndPlayTumHiHo()
        try ui.tap(ui.app.textFields["search.field"])
        try ui.wait("Editing Search must hide the mini-player") {
            ui.app.keyboards.firstMatch.exists && !ui.app.buttons["miniPlayer.open"].exists
        }

        let retry = ui.app.buttons["message.playbackRetry"]
        try ui.requireHittable(retry)
        try ui.expectLabel(ui.app.staticTexts["message.text"], "Couldn’t play Tum Hi Ho. Synthetic audio connection failure")
        XCTAssertGreaterThanOrEqual(retry.frame.width, 44)
        XCTAssertGreaterThanOrEqual(retry.frame.height, 44)
        ui.capture("feedback-browser-retry-with-keyboard")
        try ui.tap(retry)
        try ui.wait("Retry must retire the old failure banner") { !retry.exists }
        try ui.expectValue(ui.app.textFields["search.field"], "Tum Hi Ho")
        try ui.requireHittable(ui.app.buttons["search.dismissKeyboard"])
        try ui.dismissSearchKeyboard()
        try waitForCollapsedPlaybackToAdvance(ui)
        XCTAssertFalse(ui.app.staticTexts["message.text"].exists)
        XCTAssertFalse(ui.app.buttons["player.close"].exists)
        try ui.tap(ui.app.buttons["miniPlayer.playPause"])
        try ui.expectLabel(ui.app.buttons["miniPlayer.playPause"], "Play")
    }

    func testRecapRowsExposePersonalRankListeningTimeAndPlaysForEachWindow() throws {
        let ui = makeDriver()
        try ui.launch()
        try ui.selectTab("recap")
        for (window, days) in [("week", 7), ("month", 30), ("year", 365)] {
            let selector = ui.app.buttons["recap.window.\(window)"]
            try ui.reveal(selector, direction: .down)
            try ui.tap(selector)
            let first = ui.app.buttons["track.play.\(AppUIFixture.tumHiHo)"]
            let second = ui.app.buttons["track.play.\(AppUIFixture.agarTumSaathHo)"]
            try ui.reveal(first)
            try ui.expectLabel(first, "Tum Hi Ho, Arijit Singh")
            try ui.expectValue(first, "Rank 1. Your listening in the last \(days) days: 26 min listened, 6 plays")
            try ui.reveal(second)
            try ui.expectLabel(second, "Agar Tum Saath Ho, Alka Yagnik, Arijit Singh")
            try ui.expectValue(second, "Rank 2. Your listening in the last \(days) days: 22 min listened, 4 plays")
            XCTAssertFalse((first.value as? String ?? "").contains("worldwide"))
        }
        ui.capture("feedback-recap-personal-row-metadata")
    }

    func testThisIsRowsExposeProviderWorldwideCountsWithoutChangingSongLabels() throws {
        let ui = makeDriver()
        @MainActor
        func waitForPageReady(_ identifier: String, label: String) throws {
            let marker = ui.app.staticTexts[identifier]
            let scroll = ui.app.scrollViews.containing(.staticText, identifier: identifier).firstMatch
            try ui.expectLabel(marker, label)
            // A destination marker can appear before its navigation transition has valid scroll geometry.
            try ui.wait("The \(identifier) destination must have a visible scroll viewport") {
                guard scroll.exists else { return false }
                let frame = scroll.frame
                return [frame.minX, frame.minY, frame.maxX, frame.maxY].allSatisfy(\.isFinite)
                    && !frame.isEmpty && frame.intersection(ui.app.windows.firstMatch.frame).height > 50
            }
            try ui.requireHittable(marker)
        }
        try ui.launch(additionalArguments: ["--artist-spotlight-fixture", "--search-results", "A. R. Rahman"])
        try ui.waitForSearchResults()
        try ui.tap(ui.app.buttons["search.featuredArtist"])
        try waitForPageReady("collection.monthlyAudience", label: "12.3M monthly audience")
        try ui.reveal(ui.app.buttons["artist.spotlight.open"])
        try ui.tap(ui.app.buttons["artist.spotlight.open"])
        try waitForPageReady("artist.spotlight.countProvenance", label: "Sorted by available play counts")

        let first = ui.app.buttons["track.play.fixture.spotlight.tamil"]
        let second = ui.app.buttons["track.play.fixture.spotlight.hindi"]
        try ui.reveal(first)
        try ui.expectLabel(first, "Garden Paths, Spotlight Fixture Singer, A. R. Rahman")
        try ui.expectValue(first, "YouTube Music: 1,200 plays worldwide")
        try ui.reveal(second)
        try ui.expectLabel(second, "Morning Windows, Spotlight Fixture Singer, A. R. Rahman")
        try ui.expectValue(second, "YouTube Music: 800 plays worldwide")
        XCTAssertLessThan(first.frame.minY, second.frame.minY)
        XCTAssertFalse((first.value as? String ?? "").contains("Your listening"))
        try ui.requireHittable(ui.app.buttons["track.options.fixture.spotlight.hindi"])
        ui.capture("feedback-this-is-provider-row-metadata")
    }

    func testTrackMenuFeedbackPreservesSearchNavigationAndTheRemainingActions() throws {
        let ui = makeDriver()
        try ui.launch()
        try ui.search("Tum Hi Ho")
        try ui.waitForSearchResults()
        let options = ui.app.buttons["track.options.\(AppUIFixture.tumHiHo)"]
        try ui.reveal(options)
        try ui.tap(options)
        try ui.tap(ui.app.buttons["Add to queue"])

        try ui.expectLabel(ui.app.staticTexts["message.text"], "Added to queue")
        XCTAssertEqual(ui.app.staticTexts.matching(identifier: "message.text").count, 1)
        XCTAssertTrue(ui.app.tabBars.buttons["Search"].isSelected)
        try ui.expectValue(ui.app.textFields["search.field"], "Tum Hi Ho")
        XCTAssertFalse(ui.app.buttons["message.playbackRetry"].exists)
        XCTAssertFalse(ui.app.buttons["player.close"].exists)
        try ui.tap(ui.app.buttons["message.dismiss"])
        try ui.requireHittable(options)
        try ui.requireHittable(ui.app.buttons["track.play.\(AppUIFixture.tumHiHo)"])
        try ui.assertMiniPlayerAboveTabs()
        ui.capture("feedback-menu-preserves-browser-context")
    }

    private func waitForCollapsedPlaybackToAdvance(_ ui: AppUITestDriver) throws {
        let open = ui.app.buttons["miniPlayer.open"]
        try ui.wait("Retried audio must reach actual playback in the mini-player", timeout: 15) {
            open.exists && (open.value as? String ?? "").hasPrefix("Playing, ")
                && ui.app.buttons["miniPlayer.playPause"].label == "Pause"
        }
        let start = try XCTUnwrap(collapsedPosition(open))
        try ui.wait("The collapsed player's elapsed time must advance after retry", timeout: 10) {
            guard let position = self.collapsedPosition(open) else { return false }
            return position >= start + 2 && ui.app.buttons["miniPlayer.playPause"].label == "Pause"
                && !ui.app.buttons["player.close"].exists
        }
    }

    private func collapsedPosition(_ open: XCUIElement) -> TimeInterval? {
        guard open.exists, let value = open.value as? String, value.hasPrefix("Playing, "), value.hasSuffix(" elapsed") else { return nil }
        return AppUIClock.seconds(String(value.dropFirst("Playing, ".count).dropLast(" elapsed".count)))
    }

    private func assertSameFrame(_ actual: CGRect, _ expected: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 1, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 1, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 1, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 1, file: file, line: line)
    }

    private func makeDriver() -> AppUITestDriver {
        let ui = AppUITestDriver(testCase: self, prefix: "feedback")
        addTeardownBlock { await ui.finish() }
        return ui
    }
}

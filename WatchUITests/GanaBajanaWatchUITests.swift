import XCTest

/// Native watchOS UI workflows for the Watch SE 3 (40 mm), using the DEBUG fixture transport and real request client.
/// Target the Watch app; these exercise leased fixture responses, not paired-iPhone transport or audible playback.
@MainActor
final class GanaBajanaWatchUITests: XCTestCase {
    private let app = XCUIApplication()
    private var fixture = "unlaunched"
    private var screenshotNumber = 0
    private var didMovePlayerControlsWithCrown = false
    private let geometryEpsilon: CGFloat = 1e-6
    private let playlistID = "BFEEF100-1D98-4C91-8120-13C48800F101"
    private let longTitle = "बारिश की शाम · A very long song title for a quiet evening"
    private let longArtist = "A long artist credit with a guest vocalist"
    private let playbackError = "Playback couldn’t continue. Open Breezy on iPhone to try again."
    private let libraryError = "Your saved library needs attention. Open Breezy on iPhone to check or recover it."

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() async throws {
        if app.state != .notRunning,
           (testRun?.failureCount ?? 0) > 0 || (testRun?.unexpectedExceptionCount ?? 0) > 0 {
            capture("Failure - \(name)")
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "watch-\(fixture)-failure-hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        app.terminate()
    }

    func testStoreEmptyPlayerAndLibraryUseRealPhoneState() throws {
        guard ProcessInfo.processInfo.environment["GANABAJANA_WATCH_STORE_CAPTURE"] == "1" else {
            throw XCTSkip("Store capture requires an explicitly paired, empty, account-free phone installation.")
        }
        fixture = "native-store"
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        try wait("The real paired phone must confirm its empty player", timeout: 120) {
            self.element("watch.empty").exists && !self.element("watch.connection").exists
        }
        XCTAssertFalse(element("watch.track.title").exists)
        XCTAssertFalse(element("watch.lastSeen").exists)
        XCTAssertFalse(element("watch.library.error").exists)
        XCTAssertTrue(app.staticTexts["Find your next song"].exists)
        capture("Store - Empty player confirmed by iPhone")

        try openLibrary()
        for identifier in ["favorites", "recent", "playlists", "queue"] {
            let row = app.buttons["watch.browse.\(identifier)"]
            XCTAssertTrue(row.exists)
            XCTAssertTrue(row.isEnabled)
        }
        try reveal(app.buttons["watch.browse.favorites"])
        capture("Store - Real library folders")
        let provenance = XCTAttachment(string: "Breezy 1.0.0 (3), Watch SE 3 44mm, en-US. Real WatchConnectivity and an empty paired phone; no --watch-fixture, seeded tracks, media or simulated connection state.")
        provenance.name = "store-watch-provenance"
        provenance.lifetime = .keepAlways
        add(provenance)
    }

    func testPausedPlayerConfirmsPlayPauseNextAndFavoriteChanges() throws {
        try launch("paused")
        try wait("Transport must be ready on the first screen") { self.app.buttons["watch.playPause"].isEnabled }
        let initialViewport = viewport(of: element("watch.nowPlaying"))
        for identifier in ["watch.previous", "watch.playPause", "watch.next"] {
            let control = app.buttons[identifier]
            XCTAssertTrue(visible(control, in: initialViewport), "\(identifier) must be fully visible before scrolling")
            XCTAssertTrue(control.isHittable)
        }
        capture("Primary controls fit the first screen")
        try expectTrack("Evening breeze", artist: "Breezy Sessions")
        try expectPlayback(playing: false)
        try expectProgress("0:42 of 3:34")
        capture("Paused launch retains the selected song")

        try tap(app.buttons["watch.playPause"])
        try expectPlayback(playing: true)
        try expectClockAdvance()
        capture("Play confirmed with advancing progress")

        try tap(app.buttons["watch.playPause"])
        try expectPlayback(playing: false)
        let pausedProgress = try progressValue()
        try remain("Paused playback must keep its elapsed time", for: 1.5) {
            self.element("watch.progress").value as? String == pausedProgress
        }
        capture("Pause confirmed with frozen progress")

        try tap(app.buttons["watch.next"])
        try expectTrack("A little sunshine", artist: "The Window Seat")
        try expectPlayback(playing: false)
        try expectProgress("0:00 of 3:34")
        capture("Next selects a different song and preserves pause")

        try expectFavorite(false)
        try tap(app.buttons["watch.favorite"])
        try expectFavorite(true)
        XCTAssertEqual(app.buttons["watch.playPause"].label, "Play on iPhone")
        capture("Favorite confirmed on the selected song")

        try tap(app.buttons["watch.favorite"])
        try expectFavorite(false)
        XCTAssertEqual(app.buttons["watch.playPause"].label, "Play on iPhone")
        capture("Favorite removal confirmed without starting playback")
    }

    func testFavoriteHoldPromotesToSuperLikeAndTapRemovesIt() throws {
        try launch("paused")
        try expectTrack("Evening breeze", artist: "Breezy Sessions")
        try expectPlayback(playing: false)
        try expectFavorite(false)
        let heart = app.buttons["watch.favorite"]
        try tap(heart)
        try expectFavorite(true)
        capture("Tap confirms a favorite on the paused song")

        try hold(heart)
        try expectFavorite(true, superLiked: true)
        XCTAssertEqual(app.buttons["watch.playPause"].label, "Play on iPhone")
        capture("Hold confirms the super like without starting playback")

        try tap(heart)
        try expectFavorite(false)
        try expectTrack("Evening breeze", artist: "Breezy Sessions")
        XCTAssertEqual(app.buttons["watch.playPause"].label, "Play on iPhone")
        capture("Tap on a super liked song removes it from favorites")
    }

    func testLibraryFoldersPlaylistSelectionAndQueuePlayback() throws {
        try launch("playing")
        try expectPlayback(playing: true)
        try openLibrary()
        try reveal(app.buttons["watch.browse.favorites"])
        XCTAssertEqual(app.buttons["watch.browse.favorites"].label, "Favorites")
        capture("Library folders ready")

        try tap(app.buttons["watch.browse.favorites"])
        try expectPage("favorites")
        try selectSong("item:2", title: "On the way home", artist: "Sunday Company")
        try expectTrack("On the way home", artist: "Sunday Company")
        try expectPlayback(playing: true)
        capture("Favorites selection returns to Now Playing")

        try tap(app.buttons["watch.playPause"])
        try expectPlayback(playing: false)
        try openLibrary()
        try tap(app.buttons["watch.browse.playlists"])
        try expectPage("playlists")
        let playlist = app.buttons["watch.browse.\(playlistID)"]
        try reveal(playlist)
        XCTAssertTrue(playlist.label.contains("Evening breeze"))
        XCTAssertTrue(playlist.label.contains("3 songs"))
        capture("Playlists folder shows its song count")

        try tap(playlist)
        try expectPage("playlist:\(playlistID)")
        try selectSong("item:1", title: "A little sunshine", artist: "The Window Seat")
        try expectTrack("A little sunshine", artist: "The Window Seat")
        try expectPlayback(playing: true)
        capture("Nested playlist selection starts the chosen song")

        try openLibrary()
        try tap(app.buttons["watch.browse.queue"])
        try expectPage("queue")
        try selectSong("item:0", title: "Evening breeze", artist: "Breezy Sessions")
        try expectTrack("Evening breeze", artist: "Breezy Sessions")
        try expectPlayback(playing: true)
        capture("Queue selection confirms a different current song")
    }

    func testDisconnectedPlayerShowsLastSeenAndDisablesCommands() throws {
        try launch("disconnected")
        try expectTrack("Evening breeze", artist: "Breezy Sessions")
        try expectProgress("0:42 of 3:34", label: "Last known progress")
        try remain("Cached playback must not advance while disconnected", for: 1.5) {
            self.element("watch.progress").value as? String == "0:42 of 3:34"
        }

        for identifier in ["watch.previous", "watch.playPause", "watch.next", "watch.favorite"] {
            let control = app.buttons[identifier]
            try reveal(control)
            XCTAssertFalse(control.isEnabled, "\(identifier) must reject disconnected commands")
        }
        XCTAssertEqual(app.buttons["watch.playPause"].label, "Playback unavailable")
        try reveal(element("watch.lastSeen"))
        XCTAssertTrue(app.staticTexts["Last seen on iPhone"].exists)
        capture("Last seen with disabled cached controls")

        try tap(app.buttons["watch.options"])
        let shuffle = app.switches["watch.shuffle"]
        try wait("Disconnected playback options must load") { shuffle.exists }
        try reveal(shuffleTarget())
        XCTAssertFalse(shuffle.isEnabled)
        XCTAssertEqual(shuffle.value as? String, "0")
        let repeatButton = app.buttons["watch.repeat"]
        try reveal(repeatButton)
        XCTAssertFalse(repeatButton.isEnabled)
        XCTAssertEqual(repeatButton.value as? String, "Off")
        capture("Shuffle and repeat unavailable while disconnected")

        try back()
        try reveal(element("watch.connection"))
        XCTAssertTrue(app.staticTexts["iPhone unavailable"].exists)
        XCTAssertTrue(app.staticTexts["Open Breezy on your paired iPhone and keep it nearby."].exists)
        capture("Disconnected recovery guidance")
        try tap(app.buttons["watch.refresh"])
        try expectProgress("0:42 of 3:34", label: "Last known progress")
        XCTAssertFalse(app.buttons["watch.playPause"].isEnabled)
        XCTAssertFalse(element("watch.pending").exists)

        try openLibrary()
        let guidance = app.staticTexts["Open Breezy on iPhone to load your library."]
        try reveal(guidance)
        XCTAssertFalse(element("watch.browse.empty").exists)
        let reload = app.buttons["watch.browse.refresh"]
        try reveal(reload)
        XCTAssertFalse(reload.isEnabled)
        capture("Disconnected library has recovery guidance instead of an empty list")
    }

    func testLongMetadataKeepsCrownReachableControlsAnd44PointTargets() throws {
        try launch("long")
        try expectTrack(longTitle, artist: longArtist)
        let title = trackText("watch.track.title", title: longTitle, artist: longArtist)
        let artist = trackText("watch.track.artist", title: longTitle, artist: longArtist)
        try assertReadable(title)
        XCTAssertGreaterThan(title.frame.height, 30, "Long metadata must wrap on the 40 mm display")
        try assertReadable(artist)
        capture("Long Hindi title and full artist accessibility text")

        for identifier in ["watch.previous", "watch.playPause", "watch.next"] {
            try assert44PointTarget(app.buttons[identifier])
        }
        try tap(app.buttons["watch.playPause"])
        try expectPlayback(playing: false)
        try tap(app.buttons["watch.next"])
        try expectPlayback(playing: false)
        try expectProgress("0:00 of 3:34")
        capture("Crown-reached transport accepts Pause and Next")

        try assert44PointTarget(app.buttons["watch.favorite"])
        try tap(app.buttons["watch.favorite"])
        try expectFavorite(true)
        capture("Crown-reached favorite confirms its value")
        try assert44PointTarget(app.buttons["watch.options"])
        try tap(app.buttons["watch.options"])
        try expectShuffle(false)
        try expectRepeat("Off")
        try assert44PointTarget(shuffleTarget())
        try tap(shuffleTarget())
        try expectShuffle(true)
        capture("Native shuffle switch confirms On")

        for value in ["All", "One"] {
            try assert44PointTarget(app.buttons["watch.repeat"])
            try tap(app.buttons["watch.repeat"])
            try expectRepeat(value)
            capture("Repeat confirms \(value)")
        }
        try back()
        try expectFavorite(true)
        try tap(app.buttons["watch.options"])
        try expectShuffle(true)
        try expectRepeat("One")
        try tap(app.buttons["watch.repeat"])
        try expectRepeat("Off")
        try tap(shuffleTarget())
        try expectShuffle(false)
        capture("Reopened options retain confirmed values and can turn Off")
        XCTAssertTrue(didMovePlayerControlsWithCrown, "The Digital Crown must visibly move native player controls")

        try back()
        try assert44PointTarget(app.buttons["watch.library"])
        try openLibrary()
        try assert44PointTarget(app.buttons["watch.browse.playlists"])
        try tap(app.buttons["watch.browse.playlists"])
        try expectPage("playlists")
        try assert44PointTarget(app.buttons["watch.browse.\(playlistID)"])
        try tap(app.buttons["watch.browse.\(playlistID)"])
        try expectPage("playlist:\(playlistID)")
        try assert44PointTarget(app.buttons["watch.browse.item:2"])
        try selectSong("item:2", title: longTitle, artist: longArtist)
        try expectTrack(longTitle, artist: longArtist)
        try expectPlayback(playing: true)
        capture("Long song row is reachable and starts playback from pause")
    }

    func testLoadingPlaybackErrorAndLibraryFailuresHaveDistinctRecovery() throws {
        try launch("loading")
        let playPause = app.buttons["watch.playPause"]
        try reveal(playPause)
        try wait("Loading must expose a usable pause action") {
            playPause.label == "Pause on iPhone" && playPause.value as? String == "Loading" && playPause.isEnabled
        }
        try expectProgress("0:42 of 3:34")
        XCTAssertFalse(element("watch.playback.error").exists)
        XCTAssertFalse(element("watch.library.error").exists)
        capture("Loading on iPhone has a distinct control state")
        try tap(playPause)
        try expectPlayback(playing: false)
        try expectProgress("0:42 of 3:34")
        capture("Pause cancels fixture loading without starting playback")

        try launch("error")
        try expectPlayback(playing: false)
        let failure = element("watch.playback.error")
        try reveal(failure)
        XCTAssertEqual(failure.label, playbackError)
        XCTAssertFalse(element("watch.library.error").exists)
        capture("Playback failure offers iPhone recovery guidance")
        try tap(app.buttons["watch.playPause"])
        try expectPlayback(playing: true)
        try wait("Acknowledged Play must clear the playback failure") { !failure.exists }
        try expectClockAdvance()
        capture("Play acknowledgement clears the playback error")

        try launch("library-error")
        try expectPlayback(playing: true)
        try expectClockAdvance()
        try expectFavorite(false, enabled: false)
        try expectLibraryFailure()
        XCTAssertFalse(element("watch.playback.error").exists)
        capture("Library failure leaves the playing clock running")
        try tap(app.buttons["watch.playPause"])
        try expectPlayback(playing: false)
        XCTAssertFalse(app.buttons["watch.favorite"].isEnabled)
        capture("Playback remains controllable while library writes are disabled")
        try openLibrary()
        try tap(app.buttons["watch.browse.favorites"])
        try expectPage("favorites")
        try expectLibraryFailure()
        XCTAssertFalse(element("watch.browse.empty").exists)
        try tap(app.buttons["watch.browse.refresh"])
        try expectPage("favorites")
        try expectLibraryFailure()
        capture("Failed Favorites refresh preserves the library error")

        try launch("library-empty")
        try expectLibraryFailure()
        XCTAssertFalse(element("watch.empty").exists)
        XCTAssertFalse(app.buttons["watch.playPause"].exists)
        capture("Library failure without a song is not a healthy empty player")
        try openLibrary()
        try tap(app.buttons["watch.browse.playlists"])
        try expectPage("playlists")
        try expectLibraryFailure()
        XCTAssertFalse(element("watch.browse.empty").exists)
        capture("Failed playlists do not claim Nothing here yet")

        try launch("empty")
        try reveal(element("watch.empty"))
        XCTAssertTrue(app.staticTexts["Find your next song"].exists)
        XCTAssertFalse(element("watch.library.error").exists)
        XCTAssertFalse(app.buttons["watch.playPause"].exists)
        capture("Healthy empty player invites a library selection")
        try openLibrary()
        try tap(app.buttons["watch.browse.playlists"])
        try expectPage("playlists")
        try reveal(element("watch.browse.empty"))
        XCTAssertTrue(app.staticTexts["Nothing here yet"].exists)
        XCTAssertTrue(app.staticTexts["Create a playlist in Breezy on iPhone."].exists)
        XCTAssertFalse(element("watch.library.error").exists)
        capture("Healthy empty playlists have creation guidance")
    }

    func testPendingDoubleTapWaitsForTimeoutAndReadReconciliation() throws {
        try launch("pending")
        try expectTrack("Evening breeze", artist: "Breezy Sessions")
        try expectPlayback(playing: true)
        let before = try elapsedSeconds()
        try expectFavorite(false)
        let playPause = app.buttons["watch.playPause"]
        try reveal(playPause, hittable: true)
        capture("Confirmed playing state before rapid Pause taps")

        let started = ProcessInfo.processInfo.systemUptime
        playPause.doubleTap()
        try wait("Rapid Pause taps must retain confirmed playback and block further commands", timeout: 2) {
            playPause.label == "Pause on iPhone" && playPause.value as? String == "Pending"
                && !playPause.isEnabled && !self.app.buttons["watch.next"].isEnabled
                && !self.app.buttons["watch.favorite"].isEnabled
                && self.app.buttons["watch.favorite"].value as? String == "Not a favorite"
                && self.element("watch.pending").label == "Sending to iPhone…"
        }
        capture("Double tap stays pending without an optimistic Pause or Favorite")

        // The fixture drops mutations but answers reads; the automatic reread can replace the timeout notice immediately.
        // Its 12-second heartbeat can also clear the reconciliation notice, so recovery is asserted through confirmed controls.
        try wait("The eight-second mutation deadline must reconcile through a fresh read", timeout: 12) {
            !self.element("watch.pending").exists && playPause.isEnabled
                && playPause.label == "Pause on iPhone" && playPause.value as? String != "Pending"
                && !self.element("watch.lastSeen").exists
        }
        XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - started, 8)
        capture("Timeout reread restores confirmed playing controls")
        try expectTrack("Evening breeze", artist: "Breezy Sessions")
        try expectPlayback(playing: true)
        XCTAssertGreaterThanOrEqual(try elapsedSeconds(), before + 7)
        try expectFavorite(false)
        capture("Readback preserves the song and favorite while progress advances")

        try openLibrary()
        try tap(app.buttons["watch.browse.queue"])
        try expectPage("queue")
        let song = app.buttons["watch.browse.item:0"]
        try reveal(song)
        XCTAssertTrue(song.isEnabled)
        XCTAssertTrue(song.label.contains("Evening breeze"))
        try tap(app.buttons["watch.browse.refresh"])
        try expectPage("queue")
        try reveal(song, toward: .start)
        XCTAssertTrue(song.isEnabled)
        XCTAssertFalse(element("watch.pending").exists)
        capture("Read-only queue refresh remains usable after reconciliation")
    }

    private func launch(_ mode: String) throws {
        if app.state != .notRunning { app.terminate() }
        fixture = mode
        didMovePlayerControlsWithCrown = false
        app.launchArguments = ["--watch-fixture", mode, "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        try wait("The native Watch Now Playing screen must launch", timeout: 8) {
            self.playerIsVisible
        }
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private var playerIsVisible: Bool {
        let player = element("watch.nowPlaying")
        return player.exists && usable(viewport(of: player)) && player.isHittable
    }

    private func expectPlayback(playing: Bool) throws {
        let control = app.buttons["watch.playPause"]
        try reveal(control)
        try wait("Playback must be confirmed \(playing ? "playing" : "paused")") {
            control.label == (playing ? "Pause on iPhone" : "Play on iPhone") && control.isEnabled
                && control.value as? String != "Pending" && control.value as? String != "Loading"
                && !self.element("watch.pending").exists && !self.element("watch.lastSeen").exists
        }
        let status = app.staticTexts[playing ? "Playing on iPhone" : "Paused on iPhone"]
        try reveal(status)
    }

    private func expectFavorite(_ favorite: Bool, superLiked: Bool = false, enabled: Bool = true) throws {
        let control = app.buttons["watch.favorite"]
        try reveal(control)
        let value = superLiked ? "Super liked" : favorite ? "Favorite" : "Not a favorite"
        try wait("Favorite must have the acknowledged value \(value)") {
            control.label == (favorite ? "Remove from favorites" : "Add to favorites")
                && control.value as? String == value
                && control.isEnabled == enabled && !self.element("watch.pending").exists
        }
    }

    private func expectRepeat(_ value: String) throws {
        let control = app.buttons["watch.repeat"]
        try reveal(control)
        try wait("Repeat must confirm \(value)") { control.isEnabled && control.value as? String == value }
    }

    private func expectShuffle(_ enabled: Bool) throws {
        try wait("Playback options must expose a native shuffle switch") { self.app.switches["watch.shuffle"].exists }
        try reveal(shuffleTarget())
        try wait("Shuffle must confirm \(enabled ? "On" : "Off")") {
            let control = self.app.switches["watch.shuffle"]
            return control.isEnabled && control.value as? String == (enabled ? "1" : "0")
        }
    }

    private func shuffleTarget() -> XCUIElement {
        let row = app.cells.containing(.switch, identifier: "watch.shuffle").firstMatch
        // A native switch may expose a virtual child; the containing row supplies its actual touch region.
        return row.exists && usable(row.frame) ? row : app.switches["watch.shuffle"]
    }

    private func trackText(_ identifier: String, title: String, artist: String) -> XCUIElement {
        // SwiftUI can fold the two identified texts into one combined accessibility element.
        let predicate = NSPredicate(format: "identifier == %@ OR (label CONTAINS %@ AND label CONTAINS %@)",
                                    identifier, title, artist)
        return element("watch.nowPlaying").descendants(matching: .any).matching(predicate).firstMatch
    }

    private func expectTrack(_ title: String, artist: String) throws {
        try wait("The native Now Playing screen must be visible") { self.playerIsVisible }
        let titleText = trackText("watch.track.title", title: title, artist: artist)
        let artistText = trackText("watch.track.artist", title: title, artist: artist)
        try reveal(titleText, toward: .start)
        try wait("The selected song and artist must match the fixture response") {
            titleText.label.contains(title) && artistText.exists && artistText.label.contains(artist)
        }
    }

    private func expectProgress(_ value: String, label: String = "Playback progress") throws {
        let progress = element("watch.progress")
        try reveal(progress)
        try wait("Progress must expose \(label): \(value)") { progress.label == label && progress.value as? String == value }
    }

    private func progressValue() throws -> String {
        let progress = element("watch.progress")
        try reveal(progress)
        return try XCTUnwrap(progress.value as? String, "Progress needs an accessible elapsed/duration value")
    }

    private func elapsedSeconds() throws -> Int {
        let value = try progressValue()
        return try XCTUnwrap(parseElapsed(value), "Unexpected progress value: \(value)")
    }

    private func parseElapsed(_ value: String) -> Int? {
        let parts = value.components(separatedBy: " of ")
        guard parts.count == 2, parts[1] == "3:34" else { return nil }
        let clock = parts[0].split(separator: ":")
        guard clock.count == 2, let minutes = Int(clock[0]), let seconds = Int(clock[1]),
              minutes >= 0, (0..<60).contains(seconds) else { return nil }
        return minutes * 60 + seconds
    }

    private func expectClockAdvance() throws {
        let start = try elapsedSeconds()
        try wait("Confirmed playing progress must advance", timeout: 4) {
            guard let value = self.element("watch.progress").value as? String,
                  let current = self.parseElapsed(value) else { return false }
            return current >= start + 1
        }
    }

    private func openLibrary() throws {
        try tap(app.buttons["watch.library"])
        try expectPage("root")
    }

    private func expectPage(_ location: String) throws {
        try wait("The \(location) browse page must finish loading") {
            let page = self.element("watch.browse.\(location)")
            guard page.exists, page.elementType != .button, self.usable(self.viewport(of: page)), page.isHittable,
                  !self.element("watch.browse.loading").exists else { return false }
            // Native List rows are lazy; readiness must not depend on the offscreen Refresh page footer.
            return page.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "watch.browse.")).firstMatch.exists
                || self.element("watch.browse.empty").exists || self.element("watch.library.error").exists
                || self.element("watch.connection").exists
        }
    }

    private func selectSong(_ itemID: String, title: String, artist: String) throws {
        let song = app.buttons["watch.browse.\(itemID)"]
        try reveal(song)
        XCTAssertTrue(song.label.contains(title))
        XCTAssertTrue(song.label.contains(artist))
        XCTAssertTrue(song.isEnabled)
        capture("Ready to select \(title)")
        try tap(song)
    }

    private func expectLibraryFailure() throws {
        let failure = element("watch.library.error")
        try reveal(failure, toward: .start)
        XCTAssertTrue(failure.label.contains("Library needs attention"))
        XCTAssertTrue(failure.label.contains(libraryError))
        XCTAssertFalse(element("watch.empty").exists)
    }

    private enum Direction { case start, end }

    private func usable(_ frame: CGRect) -> Bool {
        !frame.isNull && !frame.isEmpty && [frame.minX, frame.minY, frame.maxX, frame.maxY].allSatisfy(\.isFinite)
    }

    private var windowFrame: CGRect {
        let window = app.windows.firstMatch
        return window.exists ? window.frame : app.frame
    }

    private func viewport(of scroll: XCUIElement) -> CGRect {
        guard usable(scroll.frame), usable(windowFrame) else { return .null }
        var bounds = scroll.frame.intersection(windowFrame)
        for bar in app.navigationBars.allElementsBoundByIndex + app.statusBars.allElementsBoundByIndex {
            let frame = bar.frame
            if usable(frame), frame.intersects(bounds), frame.minY < bounds.midY, frame.maxY < bounds.maxY {
                let top = max(bounds.minY, frame.maxY)
                bounds = CGRect(x: bounds.minX, y: top, width: bounds.width, height: bounds.maxY - top)
            }
        }
        return bounds
    }

    private func scrollRegion(containing target: XCUIElement) throws -> (XCUIElement, CGRect) {
        let scrolls = app.scrollViews.allElementsBoundByIndex + app.tables.allElementsBoundByIndex
            + app.collectionViews.allElementsBoundByIndex
        let regions = scrolls.map { ($0, viewport(of: $0)) }
            .filter { usable($0.1) && $0.1.height > 44 }
            .sorted { $0.1.height > $1.1.height }
        if target.exists {
            for region in regions {
                let descendants = region.0.descendants(matching: target.elementType)
                let match = target.identifier.isEmpty
                    ? descendants.matching(NSPredicate(format: "label == %@", target.label))
                    : descendants.matching(identifier: target.identifier)
                if match.firstMatch.exists { return region }
            }
        }
        if let region = regions.first(where: { $0.0.isHittable }) ?? regions.first { return region }
        throw WatchUIFailure(description: "No visible native Watch scroll viewport for \(target.identifier)")
    }

    private func visible(_ target: XCUIElement, in viewport: CGRect) -> Bool {
        guard target.exists, usable(target.frame), usable(viewport) else { return false }
        let frame = target.frame
        let intersection = frame.intersection(viewport)
        return viewport.contains(CGPoint(x: frame.midX, y: frame.midY))
            && intersection.width + geometryEpsilon >= frame.width
            && intersection.height + geometryEpsilon >= min(frame.height, viewport.height - 2)
    }

    private struct ScrollGeometry: Equatable {
        let frame: CGRect
        let childFrames: [CGRect]
    }

    private func scrollGeometry(_ target: XCUIElement) -> ScrollGeometry? {
        guard target.exists, let snapshot = try? target.snapshot(), usable(snapshot.frame) else { return nil }
        // Watch List scales row contents independently of the button's unscaled hit frame.
        return ScrollGeometry(frame: snapshot.frame, childFrames: snapshot.children.map { $0.frame })
    }

    private func settledScrollGeometry(_ target: XCUIElement, from before: ScrollGeometry?) throws -> ScrollGeometry? {
        let deadline = ProcessInfo.processInfo.systemUptime + 1.2
        var previous = before
        var stableSince = ProcessInfo.processInfo.systemUptime
        var sampled = false
        var moved = false
        repeat {
            let current = scrollGeometry(target)
            let now = ProcessInfo.processInfo.systemUptime
            moved = moved || current != before
            if !sampled || current != previous { stableSince = now }
            if sampled, current == previous, now - stableSince >= (moved ? 0.15 : 0.35) { return current }
            previous = current
            sampled = true
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw WatchUIFailure(description: "Scroll geometry did not settle for \(target.identifier): \(String(describing: previous))")
    }

    private func scrollCorrection(for frame: CGRect?, in viewport: CGRect, toward preferred: Direction) -> CGFloat {
        guard let frame, usable(frame) else { return (preferred == .end ? 1 : -1) * viewport.height }
        // Aim inside the clipped edge rather than accepting a card that still overhangs by a rounded point.
        let margin = min(4, max(0, (viewport.height - frame.height) / 2))
        if frame.height <= viewport.height {
            if frame.maxY > viewport.maxY { return frame.maxY - viewport.maxY + margin }
            if frame.minY < viewport.minY { return frame.minY - viewport.minY - margin }
        }
        return frame.midY - viewport.midY
    }

    private func reveal(_ target: XCUIElement, toward preferred: Direction = .end, hittable: Bool = false) throws {
        let (scroll, _) = try scrollRegion(containing: target)
        var lastViewport = CGRect.null
        var pointsPerTurn: CGFloat = 200
        var minimumRotation: CGFloat = 0.08
        var needsSwipe = false
        var usedSwipe = false
        var revealed = false
        var trace: [String] = []
        defer {
            if !trace.isEmpty, usedSwipe || !revealed {
                let attachment = XCTAttachment(string: trace.joined(separator: "\n"))
                attachment.name = "watch-\(fixture)-scroll-\(target.identifier)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
        for attempt in 0...8 {
            lastViewport = viewport(of: scroll)
            guard usable(lastViewport) else { break }
            if visible(target, in: lastViewport) {
                if hittable {
                    try wait("The visible target must settle before tapping: \(target.identifier)") {
                        self.visible(target, in: self.viewport(of: scroll)) && target.isHittable
                    }
                }
                revealed = true
                return
            }
            guard attempt < 8 else { break }
            let before = scrollGeometry(target)
            let correction = scrollCorrection(for: before?.frame, in: lastViewport, toward: preferred)
            let rotation = min(0.5, max(minimumRotation, abs(correction) / pointsPerTurn))
            let swiping = needsSwipe
            trace.append("\(attempt + 1): \(swiping ? "swipe" : "Crown \(rotation)") correction \(correction), frame \(before?.frame ?? .null), viewport \(lastViewport)")
            if swiping {
                // Short Crown gestures can snap back to the same List row; a native swipe crosses that dead zone.
                usedSwipe = true
                if correction >= 0 { scroll.swipeUp(velocity: .slow) }
                else { scroll.swipeDown(velocity: .slow) }
            } else {
                XCUIDevice.shared.rotateDigitalCrown(delta: correction >= 0 ? rotation : -rotation)
            }
            let after = try settledScrollGeometry(target, from: before)
            lastViewport = viewport(of: scroll)
            trace.append("Settled frame \(after?.frame ?? .null), content \(after?.childFrames ?? []), viewport \(lastViewport)")
            needsSwipe = !swiping && before?.frame == after?.frame
            if !swiping, let before, let after {
                let shift = before.frame.midY - after.frame.midY
                if shift * correction > geometryEpsilon {
                    pointsPerTurn = min(800, max(80, abs(shift) / rotation))
                    if scroll.identifier == "watch.nowPlaying", target.elementType == .button {
                        didMovePlayerControlsWithCrown = true
                    }
                }
                let remaining = scrollCorrection(for: after.frame, in: lastViewport, toward: preferred)
                if correction * remaining < 0 { minimumRotation = max(0.01, minimumRotation / 2) }
            }
        }
        throw WatchUIFailure(description: "Could not reveal \(target.identifier) / \(target.label) in \(lastViewport)")
    }

    private func tap(_ target: XCUIElement) throws {
        try reveal(target, hittable: true)
        try wait("Expected an enabled action: \(target.identifier)") { target.isEnabled }
        target.tap()
    }

    /// Holds past the heart's 0.4-second threshold; the release after a recognized hold must not count as a tap.
    private func hold(_ target: XCUIElement) throws {
        try reveal(target, hittable: true)
        try wait("Expected an enabled hold target: \(target.identifier)") { target.isEnabled }
        target.press(forDuration: 0.8)
    }

    private func back() throws {
        let navigationBack = app.navigationBars.buttons.firstMatch
        let back = navigationBack.exists ? navigationBack : app.buttons["Back"]
        try wait("The native navigation Back button must be reachable") {
            back.exists && self.usable(back.frame) && self.windowFrame.contains(back.frame)
                && back.isHittable && back.isEnabled
        }
        back.tap()
        try wait("Back must return to Now Playing") { self.playerIsVisible }
    }

    private func assert44PointTarget(_ target: XCUIElement) throws {
        try reveal(target, hittable: true)
        XCTAssertGreaterThanOrEqual(target.frame.width + geometryEpsilon, 44, target.identifier)
        XCTAssertGreaterThanOrEqual(target.frame.height + geometryEpsilon, 44, target.identifier)
    }

    private func assertReadable(_ text: XCUIElement) throws {
        try reveal(text, toward: .start)
        let (_, bounds) = try scrollRegion(containing: text)
        XCTAssertFalse(text.label.isEmpty)
        XCTAssertGreaterThan(text.frame.height, 0)
        XCTAssertGreaterThanOrEqual(text.frame.minX + geometryEpsilon, bounds.minX)
        XCTAssertLessThanOrEqual(text.frame.maxX, bounds.maxX + geometryEpsilon)
    }

    private func wait(_ message: String, timeout: TimeInterval = 4,
                      condition: @escaping @MainActor @Sendable () -> Bool) throws {
        if condition() { return }
        let predicate = NSPredicate { _, _ in MainActor.assumeIsolated { condition() } }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        guard result == .completed else { throw WatchUIFailure(description: "\(message) (\(result))") }
    }

    private func remain(_ message: String, for duration: TimeInterval,
                        condition: @escaping @MainActor @Sendable () -> Bool) throws {
        XCTAssertTrue(condition(), message)
        let predicate = NSPredicate { _, _ in MainActor.assumeIsolated { !condition() } }
        let changed = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        changed.isInverted = true
        let result = XCTWaiter.wait(for: [changed], timeout: duration)
        guard result == .completed else { throw WatchUIFailure(description: message) }
        XCTAssertTrue(condition(), message)
    }

    private func capture(_ title: String) {
        screenshotNumber += 1
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        let device = fixture == "native-store" ? "Watch SE 3 44mm" : "Watch SE 3 40mm"
        screenshot.name = "\(device) - \(fixture) - \(screenshotNumber) - \(title)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}

private struct WatchUIFailure: Error, CustomStringConvertible {
    let description: String
}

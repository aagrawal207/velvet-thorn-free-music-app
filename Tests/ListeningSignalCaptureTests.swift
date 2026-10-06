import XCTest
@testable import GanaBajana

@MainActor
final class ListeningSignalCaptureTests: XCTestCase {
    private let first = Track(id: "signal-first", title: "First", artists: ["Artist One"])
    private let second = Track(id: "signal-second", title: "Second", artists: ["Artist Two"])
    private let third = Track(id: "signal-third", title: "Third", artists: ["Artist Three"])
    private let fourth = Track(id: "signal-fourth", title: "Fourth", artists: ["Artist Four"])
    private var directories: [URL] = []

    override func tearDown() async throws {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories.removeAll()
    }

    // MARK: - Pure rules

    func testThirdSkipInsideTheWindowIsRapidAndOlderSkipsAgeOut() {
        var window = ListeningSignalSkipWindow()
        XCTAssertFalse(window.record(at: 100))
        XCTAssertFalse(window.record(at: 105))
        XCTAssertTrue(window.record(at: 120), "Three skips within 20 seconds")
        XCTAssertTrue(window.record(at: 121))
        XCTAssertFalse(window.record(at: 150), "Earlier skips have left the window")
        XCTAssertFalse(window.record(at: 160))
        XCTAssertTrue(window.record(at: 170), "Exactly 20 seconds apart is still inside the window")
        XCTAssertFalse(window.record(at: .nan))
    }

    func testSessionCreditsOnlyPositiveFiniteDeltasAndClosesOnce() {
        var session = ListeningSignalSession()
        session.credit(1.5)
        session.credit(-1)
        session.credit(.nan)
        session.credit(.infinity)
        session.credit(0.25)
        XCTAssertEqual(session.seconds, 1.75)
        XCTAssertTrue(session.close())
        XCTAssertFalse(session.close())
    }

    func testStrengthNamesFollowTheSharedWeights() {
        func strength(_ seconds: Double, _ duration: Double?, _ ending: ListeningSignal.Ending = .skipped) -> String {
            ListeningSignal(trackID: "signal-strength", title: "Song", artists: [], endedAt: Date(timeIntervalSince1970: 1_800_000_000),
                            listenedSeconds: seconds, duration: duration, ending: ending, origin: .chosen, rapid: false).strengthName
        }
        XCTAssertEqual(strength(1, 200), "strong")
        XCTAssertEqual(strength(12, 200), "mild")
        XCTAssertEqual(strength(45, 200), "light")
        XCTAssertEqual(strength(45, nil), "light")
        XCTAssertEqual(strength(120, 200), "none")
        XCTAssertEqual(strength(1, 200, .completed), "none")
    }

    // MARK: - Native playback

    func testManualNextWhilePlayingRecordsOneStrongSkipWithItsCreditedSeconds() async throws {
        let player = try makePlayer(seconds: [first.id: 20, second.id: 20])
        defer { player.pause() }
        var signals: [ListeningSignal] = []
        player.onListeningSignal = { signals.append($0) }
        player.play([first, second])
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.position > 1 }
        player.next()
        XCTAssertEqual(signals.count, 1)
        let signal = try XCTUnwrap(signals.first)
        XCTAssertEqual(signal.trackID, first.id)
        XCTAssertEqual(signal.title, first.title)
        XCTAssertEqual(signal.artists, first.artists)
        XCTAssertEqual(signal.ending, .skipped)
        XCTAssertEqual(signal.origin, .chosen)
        XCTAssertFalse(signal.rapid)
        XCTAssertEqual(signal.listenedSeconds, 1, accuracy: 0.6)
        XCTAssertEqual(signal.duration, 20)
        XCTAssertEqual(signal.strengthName, "strong")
        try await PlaybackTestSupport.waitUntil { player.currentTrack == self.second && player.isPlaying }
        XCTAssertEqual(signals.count, 1, "The next song's session is still open")
        XCTAssertNil(player.errorMessage)
    }

    func testNextWhilePausedRecordsNothing() async throws {
        let player = try makePlayer(seconds: [first.id: 20, second.id: 20])
        defer { player.pause() }
        var signals: [ListeningSignal] = []
        player.onListeningSignal = { signals.append($0) }
        player.play([first, second])
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.position > 1 }
        player.pause()
        player.next()
        XCTAssertEqual(player.currentTrack, second)
        XCTAssertTrue(signals.isEmpty, "A paused listener was not listening")
    }

    func testNaturalEndRecordsACompletionWithTheHeardSeconds() async throws {
        let player = try makePlayer(seconds: [first.id: 2, second.id: 20])
        defer { player.pause() }
        var signals: [ListeningSignal] = []
        player.onListeningSignal = { signals.append($0) }
        player.play([first, second])
        try await PlaybackTestSupport.waitUntil(timeout: 10) { player.currentTrack == self.second && player.isPlaying }
        XCTAssertEqual(signals.map(\.ending), [.completed])
        XCTAssertEqual(signals.first?.trackID, first.id)
        XCTAssertEqual(signals.first?.listenedSeconds ?? 0, 2, accuracy: 0.5)
        XCTAssertEqual(signals.first?.strengthName, "none")
    }

    func testRepeatOneRestartRecordsACompletionForEachFinishedPlay() async throws {
        let player = try makePlayer(seconds: [first.id: 2])
        defer { player.pause() }
        var signals: [ListeningSignal] = []
        var starts = 0
        player.onTrackStarted = { _ in starts += 1 }
        player.onListeningSignal = { signals.append($0) }
        player.cycleRepeatMode()
        player.cycleRepeatMode()
        XCTAssertEqual(player.repeatMode, .one)
        player.play([first])
        try await PlaybackTestSupport.waitUntil(timeout: 10) { starts >= 2 && player.isPlaying }
        player.pause()
        XCTAssertFalse(signals.isEmpty)
        XCTAssertEqual(signals.count, starts - 1, "The repetition still playing has not ended")
        XCTAssertTrue(signals.allSatisfy { $0.ending == .completed && $0.trackID == self.first.id })
    }

    func testCrossfadeBoundaryCountsTheBlendedSongAsCompleted() async throws {
        let player = try makePlayer(seconds: [first.id: 3, second.id: 4])
        defer { player.pause() }
        var settings = PlaybackTransitionSettings()
        settings.crossfadeSeconds = 1
        settings.autoplay = false
        player.apply(settings)
        var signals: [ListeningSignal] = []
        player.onListeningSignal = { signals.append($0) }
        player.play([first, second])
        try await PlaybackTestSupport.waitUntil(timeout: 8) { player.crossfadeState != nil }
        XCTAssertEqual(signals.map(\.ending), [.completed])
        XCTAssertEqual(signals.first?.trackID, first.id)
        XCTAssertEqual(signals.first?.listenedSeconds ?? 0, 2, accuracy: 0.45, "The blend ends the session early")
    }

    func testQueueJumpWhilePlayingIsASkipButReselectingThePlayingEntryIsNot() async throws {
        let player = try makePlayer(seconds: [first.id: 20, second.id: 20, third.id: 20])
        defer { player.pause() }
        var signals: [ListeningSignal] = []
        player.onListeningSignal = { signals.append($0) }
        player.play([first, second, third])
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.position > 1 }
        XCTAssertTrue(player.selectQueueTrack(at: player.currentIndex))
        XCTAssertTrue(signals.isEmpty, "Selecting the playing entry restarts it")
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.position > 0.6 }
        XCTAssertTrue(player.selectQueueTrack(at: 2))
        XCTAssertEqual(signals.map(\.ending), [.skipped])
        XCTAssertEqual(signals.first?.trackID, first.id)
        XCTAssertLessThan(signals.first?.listenedSeconds ?? .infinity, 1.4, "The restart began a new session")
        XCTAssertEqual(player.currentTrack, third)
    }

    func testPreviousRestartAndStepBackRecordNothing() async throws {
        let player = try makePlayer(seconds: [first.id: 20, second.id: 20])
        defer { player.pause() }
        var signals: [ListeningSignal] = []
        player.onListeningSignal = { signals.append($0) }
        player.play([first, second], startingAt: 1)
        try await PlaybackTestSupport.waitUntil(timeout: 10) { player.isPlaying && player.position > 3.2 }
        player.previous()
        XCTAssertEqual(player.currentTrack, second, "Previous after three seconds restarts the song")
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.position > 0.5 && player.position < 3 }
        player.previous()
        XCTAssertEqual(player.currentTrack, first)
        try await PlaybackTestSupport.waitUntil { player.isPlaying }
        XCTAssertTrue(signals.isEmpty)
    }

    func testRemovingThePlayingSongRecordsNothing() async throws {
        let player = try makePlayer(seconds: [first.id: 20, second.id: 20, third.id: 20])
        defer { player.pause() }
        var signals: [ListeningSignal] = []
        player.onListeningSignal = { signals.append($0) }
        player.play([first, second, third])
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.position > 1 }
        player.removeFromQueue(at: player.currentIndex)
        XCTAssertEqual(player.currentTrack, second)
        try await PlaybackTestSupport.waitUntil { player.isPlaying }
        XCTAssertTrue(signals.isEmpty)
    }

    func testScrubbingToTheEndIsASkipWhilePlayingAndRecordsNothingWhilePaused() async throws {
        let player = try makePlayer(seconds: [first.id: 20, second.id: 20])
        defer { player.pause() }
        var signals: [ListeningSignal] = []
        player.onListeningSignal = { signals.append($0) }
        player.play([first, second])
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.position > 1 }
        player.seek(to: 20)
        try await PlaybackTestSupport.waitUntil { player.currentTrack == self.second && player.isPlaying && player.position > 1 }
        XCTAssertEqual(signals.map(\.ending), [.skipped])
        XCTAssertEqual(signals.first?.trackID, first.id)
        XCTAssertLessThan(signals.first?.listenedSeconds ?? .infinity, 3, "The scrubbed span is not listening")
        player.pause()
        player.seek(to: 20)
        try await PlaybackTestSupport.waitUntil { !player.isLoading && player.position >= 19.9 }
        XCTAssertEqual(signals.count, 1, "A paused scrub to the end records nothing")
    }

    func testThirdSkipWithinTwentySecondsIsRapid() async throws {
        let player = try makePlayer(seconds: [first.id: 20, second.id: 20, third.id: 20, fourth.id: 20])
        defer { player.pause() }
        var signals: [ListeningSignal] = []
        player.onListeningSignal = { signals.append($0) }
        player.play([first, second, third, fourth])
        for target in [second, third, fourth] {
            try await PlaybackTestSupport.waitUntil { player.isPlaying && player.position > 0.4 }
            player.next()
            try await PlaybackTestSupport.waitUntil { player.currentTrack == target }
        }
        XCTAssertEqual(signals.map(\.trackID), [first.id, second.id, third.id])
        XCTAssertEqual(signals.map(\.ending), [.skipped, .skipped, .skipped])
        XCTAssertEqual(signals.map(\.rapid), [false, false, true])
    }

    func testRadioAndAutoplayEntriesAreGeneratedWhileTheListenersOwnListIsChosen() async throws {
        let player = try makePlayer(seconds: [first.id: 20, second.id: 20, third.id: 20], autoplay: true)
        defer { player.pause() }
        var signals: [ListeningSignal] = []
        var continuations = 0
        player.onListeningSignal = { signals.append($0) }
        player.onQueueExhausted = { _ in
            continuations += 1
            return continuations == 1 ? [self.second] : []
        }
        player.play([first])
        try await PlaybackTestSupport.waitUntil {
            player.autoplayTrackIDs == [self.second.id] && player.isPlaying && player.position > 0.6
        }
        player.next()
        try await PlaybackTestSupport.waitUntil { player.currentTrack == self.second && player.isPlaying && player.position > 0.6 }
        XCTAssertTrue(player.selectQueueTrack(at: 0))
        XCTAssertEqual(signals.map(\.trackID), [first.id, second.id])
        XCTAssertEqual(signals.map(\.origin), [.chosen, .generated], "Autoplay chose the second song")

        player.play([second, third], isRadio: true)
        try await PlaybackTestSupport.waitUntil { player.currentTrack == self.second && player.isPlaying && player.position > 0.6 }
        player.next()
        XCTAssertEqual(signals.last?.trackID, second.id)
        XCTAssertEqual(signals.last?.origin, .generated, "Every song in a radio session is generated")
    }

    func testPrivacyDiscardRecordsNothingAndKeepsEarlierSecondsOutOfTheNextSignal() async throws {
        let player = try makePlayer(seconds: [first.id: 20, second.id: 20])
        defer { player.pause() }
        var signals: [ListeningSignal] = []
        player.onListeningSignal = { signals.append($0) }
        player.play([first, second])
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.position > 1.5 }
        player.discardPendingListening()
        XCTAssertTrue(signals.isEmpty)
        let boundary = player.position
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.position > boundary + 0.6 }
        player.next()
        let signal = try XCTUnwrap(signals.first)
        XCTAssertEqual(signals.count, 1)
        XCTAssertGreaterThan(signal.listenedSeconds, 0.3)
        XCTAssertLessThan(signal.listenedSeconds, 1.4, "Seconds before the privacy boundary are discarded")
    }

    // MARK: - Model wiring

    func testModelMarksASavedMixGeneratedAndAnOrdinaryListChosen() async throws {
        let mix = (0..<2).map { AppModelFixtures.track("signal-mix-\($0)") }
        let list = (0..<2).map { AppModelFixtures.track("signal-list-\($0)") }
        let context = try makeContext(tracks: mix + list)
        context.library.saveMix(GeneratedPlaylist(kind: .discoverWeekly, tracks: mix, generatedAt: Date(),
                                                  periodKey: "signal-period", seedArtists: []))
        XCTAssertEqual(context.library.mix(.discoverWeekly)?.tracks, mix)
        context.model.play(mix)
        try await skipAfterListening(context.player, to: mix[1])
        try await PlaybackTestSupport.waitUntil { context.player.isPlaying && context.player.position > 0.6 }
        context.model.play(list[0], in: list)
        try await skipAfterListening(context.player, to: list[1])
        XCTAssertEqual(context.model.listeningSignals.map(\.trackID), [mix[0].id, mix[1].id, list[0].id])
        XCTAssertEqual(context.model.listeningSignals.map(\.origin), [.generated, .generated, .chosen])
        XCTAssertEqual(context.model.listeningSignals.map(\.ending), [.skipped, .skipped, .skipped])
    }

    func testDislikeAutoSkipRecordsNothingWhileALaterSkipStillCounts() async throws {
        let tracks = (0..<3).map { AppModelFixtures.track("signal-dislike-\($0)") }
        let context = try makeContext(tracks: tracks)
        context.model.play(tracks)
        try await PlaybackTestSupport.waitUntil { context.player.isPlaying && context.player.position > 0.6 }
        context.model.toggleDislike(tracks[0])
        XCTAssertTrue(context.library.isDisliked(tracks[0]))
        XCTAssertEqual(context.player.currentTrack, tracks[1])
        XCTAssertTrue(context.model.listeningSignals.isEmpty, "The dislike is the judgement")
        try await skipAfterListening(context.player, to: tracks[2])
        XCTAssertEqual(context.model.listeningSignals.map(\.trackID), [tracks[1].id])
    }

    func testHistoryOffAndClearHistoryEraseSignalsAndHistoryOffRecordsNothing() async throws {
        let tracks = (0..<4).map { AppModelFixtures.track("signal-privacy-\($0)") }
        let context = try makeContext(tracks: tracks)
        context.model.play(tracks)
        try await skipAfterListening(context.player, to: tracks[1])
        XCTAssertEqual(context.model.listeningSignals.map(\.trackID), [tracks[0].id])
        let revision = context.model.listeningSignalsRevision

        context.model.updatePreferences { $0.saveListeningHistory = false }
        XCTAssertFalse(context.library.preferences.saveListeningHistory)
        XCTAssertTrue(context.model.listeningSignals.isEmpty)
        XCTAssertGreaterThan(context.model.listeningSignalsRevision, revision)
        try await skipAfterListening(context.player, to: tracks[2])
        XCTAssertTrue(context.model.listeningSignals.isEmpty, "History Off records no signal")

        context.model.updatePreferences { $0.saveListeningHistory = true }
        try await skipAfterListening(context.player, to: tracks[3])
        XCTAssertEqual(context.model.listeningSignals.map(\.trackID), [tracks[2].id])

        context.library.clearHistory()
        XCTAssertNil(context.library.errorMessage)
        XCTAssertTrue(context.model.listeningSignals.isEmpty)
        XCTAssertFalse(context.model.listeningSignalStore.isBlocked)
    }

    // MARK: - Helpers

    private func makePlayer(seconds: [String: Int], autoplay: Bool = false) throws -> PlayerController {
        var files: [Int: URL] = [:]
        var entries: [String: PlaybackFixtureResolver.Entry] = [:]
        for (id, length) in seconds {
            if files[length] == nil {
                let url = try PlaybackTestSupport.audioFile(seconds: length)
                directories.append(url.deletingLastPathComponent())
                files[length] = url
            }
            entries[id] = .init(url: try XCTUnwrap(files[length]), duration: TimeInterval(length))
        }
        let player = PlayerController(resolver: PlaybackFixtureResolver(entries))
        var settings = PlaybackTransitionSettings()
        settings.autoplay = autoplay
        player.apply(settings)
        player.onListeningProgress = { _, _, _, _ in true }
        return player
    }

    private func makeContext(tracks: [Track]) throws -> AppModelTestContext {
        let url = try PlaybackTestSupport.audioFile(seconds: 20)
        directories.append(url.deletingLastPathComponent())
        let resolver = PlaybackFixtureResolver(Dictionary(uniqueKeysWithValues: tracks.map {
            ($0.id, PlaybackFixtureResolver.Entry(url: url, duration: 20))
        }))
        let context = try AppModelTestContext(resolver: resolver)
        addTeardownBlock { @MainActor in try await context.close() }
        context.model.updatePreferences {
            $0.autoplay = false
            $0.newReleaseAlerts = false
        }
        XCTAssertTrue(context.library.preferences.saveListeningHistory)
        return context
    }

    /// Waits for fresh credited audio on the current song, then skips to `target`.
    private func skipAfterListening(_ player: PlayerController, to target: Track) async throws {
        let start = player.isPlaying ? player.position : 0
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.position > start + 0.6 }
        player.next()
        try await PlaybackTestSupport.waitUntil { player.currentTrack == target }
    }
}

import XCTest
@testable import GanaBajana

@MainActor
final class PlaybackTransitionTests: XCTestCase {
    private let first = Track(id: "transition-first", title: "First")
    private let second = Track(id: "transition-second", title: "Second")
    private let third = Track(id: "transition-third", title: "Third")
    private var directories: [URL] = []

    override func tearDown() async throws {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories.removeAll()
    }

    // MARK: - Gapless

    func testGaplessSwapStartsTheNextTrackWithoutAGapAndReportsEachStartOnce() async throws {
        let resolver = try fixtures([(first, 3, nil), (second, 4, nil)])
        let player = PlayerController(resolver: resolver)
        defer { player.pause() }
        player.apply(settings(crossfade: 0, gapless: true, automix: false))
        var starts: [String] = []
        player.onTrackStarted = { starts.append($0.id) }
        player.play([first, second])
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.standbyTrack == self.second && player.isStandbyReady }
        XCTAssertNil(player.crossfadeState)
        var flipAt: ContinuousClock.Instant?
        try await PlaybackTestSupport.waitUntil(timeout: 6) {
            guard player.currentTrack == self.second else { return false }
            flipAt = .now
            return true
        }
        let flip = try XCTUnwrap(flipAt)
        XCTAssertNil(player.crossfadeState)
        XCTAssertTrue(player.hasStandbyPlayer, "The outgoing player returns to the deck after a cut")
        XCTAssertNil(player.standbyTrack)
        try await Task.sleep(for: .milliseconds(400))
        player.flushListeningProgress()
        let gap = Self.seconds(flip.duration(to: .now)) - player.position
        XCTAssertLessThan(gap, 0.15, "Second track must start within 150 ms of the first ending")
        XCTAssertGreaterThan(gap, -0.1)
        try await PlaybackTestSupport.waitUntil { player.isPlaying }
        try await PlaybackTestSupport.waitUntil(timeout: 8) { !player.isPlaying && player.position >= 3.9 }
        XCTAssertEqual(starts, [first.id, second.id])
        XCTAssertNil(player.errorMessage)
        let requests = await resolver.requests.map(\.trackID)
        XCTAssertEqual(requests, [first.id, second.id], "The standby resolution is the only resolution of the next track")
    }

    func testWithoutBlendingFeaturesNoStandbyIsPreparedAndTheResolvePathStillAdvances() async throws {
        let resolver = try fixtures([(first, 3, nil), (second, 4, nil)])
        let player = PlayerController(resolver: resolver)
        defer { player.pause() }
        player.apply(settings(crossfade: 0, gapless: false, automix: false))
        var starts: [String] = []
        player.onTrackStarted = { starts.append($0.id) }
        player.play([first, second])
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.position > 1 }
        XCTAssertNil(player.standbyTrack)
        try await PlaybackTestSupport.waitUntil(timeout: 6) { player.currentTrack == self.second && player.isPlaying }
        XCTAssertNil(player.standbyTrack)
        XCTAssertEqual(starts, [first.id, second.id])
    }

    // MARK: - Crossfade

    func testCrossfadeStartsBeforeTheEndRampsBothDecksAndCreditsOnlyPlayedSeconds() async throws {
        let resolver = try fixtures([(first, 3, nil), (second, 4, nil)])
        let player = PlayerController(resolver: resolver)
        defer { player.pause() }
        player.apply(settings(crossfade: 1, gapless: true, automix: false))
        var listened: [String: TimeInterval] = [:]
        var lastFirstPosition: TimeInterval = 0
        var starts: [String] = []
        player.onListeningProgress = { track, _, _, delta in listened[track.id, default: 0] += delta; return true }
        player.onSnapshotChanged = { if $0.currentIndex == 0 { lastFirstPosition = max(lastFirstPosition, $0.position) } }
        player.onTrackStarted = { starts.append($0.id) }
        player.play([first, second])
        try await PlaybackTestSupport.waitUntil { player.isStandbyReady }
        try await PlaybackTestSupport.waitUntil(timeout: 6) { player.crossfadeState != nil }
        let started = try XCTUnwrap(player.crossfadeState)
        XCTAssertEqual(started.duration, 1, accuracy: 0.15)
        XCTAssertEqual(player.currentTrack, second, "Ordering advances at transition start")
        XCTAssertEqual(player.currentIndex, 1)
        XCTAssertLessThan(player.position, 0.5)
        XCTAssertFalse(player.hasStandbyPlayer, "The deck's player is lent out as the incoming side")
        XCTAssertEqual(lastFirstPosition, 2, accuracy: 0.3, "The blend starts at duration minus crossfade")
        try await Task.sleep(for: .milliseconds(400))
        let mid = try XCTUnwrap(player.crossfadeState)
        XCTAssertTrue((0.05...0.95).contains(mid.outgoingVolume), "outgoing \(mid.outgoingVolume)")
        XCTAssertTrue((0.05...0.95).contains(mid.incomingVolume), "incoming \(mid.incomingVolume)")
        XCTAssertEqual(mid.outgoingVolume * mid.outgoingVolume + mid.incomingVolume * mid.incomingVolume, 1, accuracy: 0.05,
                       "Equal-power curve keeps summed power constant")
        try await PlaybackTestSupport.waitUntil { player.crossfadeState == nil }
        XCTAssertTrue(player.hasStandbyPlayer, "The outgoing player is cleared and returned at the end")
        XCTAssertEqual(try XCTUnwrap(listened[first.id]), 2, accuracy: 0.35, "Only the seconds before the blend count")
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.position > 1.3 }
        player.pause()
        XCTAssertEqual(starts, [first.id, second.id])
        XCTAssertGreaterThan(try XCTUnwrap(listened[second.id]), 0.5)
        XCTAssertNil(player.errorMessage)
    }

    func testPauseDuringACrossfadeDropsTheOutgoingSideAndResumesTheIncomingTrack() async throws {
        let resolver = try fixtures([(first, 3, nil), (second, 4, nil)])
        let player = PlayerController(resolver: resolver)
        defer { player.pause() }
        player.apply(settings(crossfade: 1, gapless: true, automix: false))
        player.play([first, second])
        try await PlaybackTestSupport.waitUntil(timeout: 6) { player.crossfadeState != nil }
        player.pause()
        XCTAssertNil(player.crossfadeState)
        XCTAssertTrue(player.hasStandbyPlayer)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.currentTrack, second)
        player.resumePlayback()
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.currentTrack == self.second && player.position > 0.5 }
        XCTAssertNil(player.crossfadeState)
        XCTAssertNil(player.errorMessage)
    }

    func testManualSkipWithCrossfadeBlendsBrieflyAndSeekDuringTheBlendDropsTheOutgoingSide() async throws {
        let resolver = try fixtures([(first, 8, nil), (second, 4, nil)])
        let player = PlayerController(resolver: resolver)
        defer { player.pause() }
        player.apply(settings(crossfade: 4, gapless: true, automix: false))
        player.play([first, second])
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.isStandbyReady }
        XCTAssertNil(player.crossfadeState)
        player.next()
        let state = try XCTUnwrap(player.crossfadeState)
        XCTAssertEqual(state.duration, 3, "Manual skips blend for min(crossfade, 3 s)")
        XCTAssertEqual(player.currentTrack, second)
        player.seek(to: 2)
        XCTAssertNil(player.crossfadeState)
        XCTAssertTrue(player.hasStandbyPlayer)
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.currentTrack == self.second && player.position > 2.2 }
        XCTAssertNil(player.errorMessage)
    }

    func testSeekingIntoTheBlendWindowSkipsTheRampAndCutsAtTheEnd() async throws {
        let resolver = try fixtures([(first, 6, nil), (second, 4, nil)])
        let player = PlayerController(resolver: resolver)
        defer { player.pause() }
        player.apply(settings(crossfade: 1, gapless: true, automix: false))
        player.play([first, second])
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.isStandbyReady }
        player.seek(to: 5.4)
        var sawRamp = false
        try await PlaybackTestSupport.waitUntil(timeout: 4) {
            if player.crossfadeState != nil { sawRamp = true }
            return player.currentTrack == self.second
        }
        XCTAssertFalse(sawRamp, "A seek into the last second must not start a truncated crossfade")
        XCTAssertNil(player.crossfadeState)
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.position > 0.3 }
        XCTAssertNil(player.errorMessage)
    }

    func testApplyingSettingsMidCrossfadeFinishesTheTransitionWithItsOriginalValues() async throws {
        let resolver = try fixtures([(first, 3, 6), (second, 4, nil)])
        let player = PlayerController(resolver: resolver)
        defer { player.pause() }
        player.apply(settings(crossfade: 1, gapless: true, automix: false))
        player.play([first, second])
        try await PlaybackTestSupport.waitUntil(timeout: 6) { player.crossfadeState != nil }
        var changed = player.settings
        changed.crossfadeSeconds = 6
        changed.normalizeVolume = false
        changed.automix = true
        player.apply(changed)
        player.apply(changed)
        let state = try XCTUnwrap(player.crossfadeState)
        XCTAssertEqual(state.duration, 1, accuracy: 0.15)
        XCTAssertEqual(player.settings.crossfadeSeconds, 6)
        try await PlaybackTestSupport.waitUntil { player.crossfadeState == nil }
        XCTAssertEqual(player.currentTrack, second)
        XCTAssertTrue(player.hasStandbyPlayer)
        XCTAssertEqual(player.normalizationGain, 1)
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.position > 1.2 }
        XCTAssertNil(player.errorMessage)
    }

    // MARK: - Automix

    func testAutomixIsIgnoredForManualSkips() async throws {
        let resolver = try fixtures([(first, 3, nil), (second, 4, nil)])
        let player = PlayerController(resolver: resolver)
        defer { player.pause() }
        player.apply(settings(crossfade: 0, gapless: true, automix: true))
        player.play([first, second])
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.isStandbyReady }
        player.next()
        XCTAssertNil(player.crossfadeState, "Automix only blends automatic transitions")
        XCTAssertEqual(player.currentTrack, second)
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.currentTrack == self.second && player.position > 0.3 }
        XCTAssertNil(player.crossfadeState)
        XCTAssertNil(player.errorMessage)
    }

    func testAutomixBlendsAutomaticTransitionsForFourSecondsWhenCrossfadeIsOff() async throws {
        let resolver = try fixtures([(first, 6, nil), (second, 8, nil)])
        let player = PlayerController(resolver: resolver)
        defer { player.pause() }
        player.apply(settings(crossfade: 0, gapless: true, automix: true))
        var lastFirstPosition: TimeInterval = 0
        player.onSnapshotChanged = { if $0.currentIndex == 0 { lastFirstPosition = max(lastFirstPosition, $0.position) } }
        player.play([first, second])
        try await PlaybackTestSupport.waitUntil(timeout: 8) { player.crossfadeState != nil }
        let state = try XCTUnwrap(player.crossfadeState)
        XCTAssertEqual(state.duration, 4, accuracy: 0.2)
        XCTAssertEqual(lastFirstPosition, 2, accuracy: 0.3)
        XCTAssertEqual(player.currentTrack, second)
        try await PlaybackTestSupport.waitUntil(timeout: 6) { player.crossfadeState == nil }
        XCTAssertTrue(player.isPlaying)
        XCTAssertNil(player.errorMessage)
    }

    // MARK: - Autoplay

    func testAutoplayRequestsContinuationWhenTheLastTrackStartsAndPlaysWhatComesBack() async throws {
        let resolver = try fixtures([(first, 3, nil), (second, 3, nil)])
        let player = PlayerController(resolver: resolver)
        defer { player.pause() }
        player.apply(settings(crossfade: 0, gapless: true, automix: false, autoplay: true))
        var requests: [String] = []
        player.onQueueExhausted = { track in
            requests.append(track.id)
            return [self.second, self.first, self.second]
        }
        player.play([first])
        try await PlaybackTestSupport.waitUntil { requests == [self.first.id] }
        try await PlaybackTestSupport.waitUntil { player.queue == [self.first, self.second] }
        XCTAssertEqual(player.autoplayTrackIDs, [second.id])
        try await PlaybackTestSupport.waitUntil { player.standbyTrack == self.second && player.isStandbyReady }
        try await PlaybackTestSupport.waitUntil(timeout: 6) { player.currentTrack == self.second && player.isPlaying }
        try await PlaybackTestSupport.waitUntil { requests.count == 2 }
        XCTAssertEqual(requests, [first.id, second.id], "Each newly last track asks for its own continuation")
        XCTAssertEqual(player.queue, [first, second], "Duplicates of queued tracks are not appended")
        try await PlaybackTestSupport.waitUntil(timeout: 6) { !player.isPlaying && !player.isLoading && player.position >= 2.9 }
        XCTAssertEqual(requests, [first.id, second.id, second.id],
                       "An early answer that added nothing earns the last track one more request when the queue ends")
        XCTAssertNil(player.errorMessage)
    }

    func testAutoplayNeverFiresWhenOffOrAfterAnExplicitPauseAndReasksOnResume() async throws {
        let resolver = try fixtures([(first, 6, nil), (second, 3, nil)])
        let disabled = PlayerController(resolver: resolver)
        defer { disabled.pause() }
        disabled.apply(settings(crossfade: 0, gapless: true, automix: false, autoplay: false))
        var disabledRequests = 0
        disabled.onQueueExhausted = { _ in disabledRequests += 1; return [self.second] }
        disabled.play([first])
        try await PlaybackTestSupport.waitUntil { disabled.isPlaying && disabled.position > 0.8 }
        XCTAssertEqual(disabledRequests, 0)
        XCTAssertEqual(disabled.queue, [first])
        disabled.pause()

        let player = PlayerController(resolver: resolver)
        defer { player.pause() }
        player.apply(settings(crossfade: 0, gapless: true, automix: false, autoplay: true))
        var requests = 0
        player.onQueueExhausted = { _ in
            requests += 1
            try? await Task.sleep(for: .milliseconds(700))
            return [self.second]
        }
        player.play([first])
        try await PlaybackTestSupport.waitUntil { requests == 1 }
        player.pause()
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertEqual(player.queue, [first], "A request in flight during an explicit pause is discarded")
        XCTAssertTrue(player.autoplayTrackIDs.isEmpty)
        player.resumePlayback()
        try await PlaybackTestSupport.waitUntil { requests == 2 }
        try await PlaybackTestSupport.waitUntil { player.queue == [self.first, self.second] }
        XCTAssertEqual(player.autoplayTrackIDs, [second.id])
        var off = player.settings
        off.autoplay = false
        player.apply(off)
        XCTAssertEqual(player.queue, [first, second], "Turning Autoplay off keeps already appended tracks")
        player.play([first])
        XCTAssertTrue(player.autoplayTrackIDs.isEmpty)
    }

    // MARK: - Normalization

    func testNormalizationRequestsAttenuationAndGainUpAndFollowsTheSetting() async throws {
        let loud = Track(id: "transition-loud", title: "Loud")
        let quiet = Track(id: "transition-quiet", title: "Quiet")
        let resolver = try fixtures([(loud, 3, 6), (quiet, 4, -3)])
        let player = PlayerController(resolver: resolver)
        defer { player.pause() }
        player.apply(settings(crossfade: 0, gapless: true, automix: false))
        player.play([loud, quiet])
        try await PlaybackTestSupport.waitUntil { player.isPlaying }
        XCTAssertEqual(player.normalizationGain, 0.501, accuracy: 0.002)
        var changed = player.settings
        changed.normalizeVolume = false
        player.apply(changed)
        XCTAssertEqual(player.normalizationGain, 1)
        changed.normalizeVolume = true
        player.apply(changed)
        XCTAssertEqual(player.normalizationGain, 0.501, accuracy: 0.002)
        try await PlaybackTestSupport.waitUntil(timeout: 6) { player.currentTrack == quiet && player.isPlaying }
        XCTAssertEqual(player.normalizationGain, 1.412_538, accuracy: 0.000_001, "Quiet tracks request gain-up through the shared tap")
        player.play([loud])
        try await PlaybackTestSupport.waitUntil { player.isPlaying }
        XCTAssertEqual(player.normalizationGain, 0.501, accuracy: 0.002)
    }

    func testNormalizationGainFormula() {
        XCTAssertEqual(PlaybackNormalization.gain(loudnessDb: 6, enabled: true), 0.501, accuracy: 0.001)
        XCTAssertEqual(PlaybackNormalization.gain(loudnessDb: 20, enabled: true), 0.1, accuracy: 0.0001)
        XCTAssertEqual(PlaybackNormalization.gain(loudnessDb: -3, enabled: true), 1.412_538, accuracy: 0.000_001)
        XCTAssertEqual(PlaybackNormalization.gain(loudnessDb: 0, enabled: true), 1)
        XCTAssertEqual(PlaybackNormalization.gain(loudnessDb: nil, enabled: true), 1)
        XCTAssertEqual(PlaybackNormalization.gain(loudnessDb: .nan, enabled: true), 1)
        XCTAssertEqual(PlaybackNormalization.gain(loudnessDb: 6, enabled: false), 1)
    }

    // MARK: - Standby deck upkeep

    func testRestorePreparesNoStandbyAndDoesNotAutoplay() async throws {
        let gate = PlaybackResolutionGate()
        let player = PlayerController(resolver: gate)
        player.apply(settings(crossfade: 3, gapless: true, automix: true, autoplay: true))
        var requests = 0
        player.onQueueExhausted = { _ in requests += 1; return [self.third] }
        player.restore(PlaybackSnapshot(queue: [first, second], currentIndex: 1, position: 10))
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertNil(player.standbyTrack)
        XCTAssertFalse(player.isStandbyReady)
        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(player.isLoading)
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(player.queue, [first, second])
        let resolutions = await gate.requests
        XCTAssertTrue(resolutions.isEmpty)
    }

    func testStandbyFollowsQueueEditsShuffleAndRepeatChanges() async throws {
        let resolver = try fixtures([(first, 8, nil), (second, 3, nil), (third, 3, nil)])
        let player = PlayerController(resolver: resolver)
        defer { player.pause() }
        player.apply(settings(crossfade: 0, gapless: true, automix: false))
        player.play([first, second, third])
        try await PlaybackTestSupport.waitUntil { player.standbyTrack == self.second && player.isStandbyReady }
        player.moveQueue(from: IndexSet(integer: 2), to: 1)
        XCTAssertEqual(player.queue, [first, third, second])
        try await PlaybackTestSupport.waitUntil { player.standbyTrack == self.third && player.isStandbyReady }
        player.removeFromQueue(at: 1)
        try await PlaybackTestSupport.waitUntil { player.standbyTrack == self.second && player.isStandbyReady }
        player.enqueue(third, next: true)
        try await PlaybackTestSupport.waitUntil { player.standbyTrack == self.third && player.isStandbyReady }
        player.toggleShuffle()
        try await PlaybackTestSupport.waitUntil { player.standbyTrack == player.queue[1] && player.isStandbyReady }
        player.cycleRepeatMode()
        XCTAssertEqual(player.repeatMode, .all)
        XCTAssertEqual(player.standbyTrack, player.queue[1])
        player.cycleRepeatMode()
        XCTAssertEqual(player.repeatMode, .one)
        XCTAssertNil(player.standbyTrack, "Repeat one restarts the same item and never blends")
        player.cycleRepeatMode()
        try await PlaybackTestSupport.waitUntil { player.standbyTrack == player.queue[1] && player.isStandbyReady }
        let requests = await resolver.requests
        XCTAssertTrue(requests.allSatisfy { !$0.forceRefresh })
        XCTAssertNil(player.errorMessage)
    }

    func testStandbyStreamsNearExpiryAreResolvedAgainBeforeUse() async throws {
        let firstFile = try audio(seconds: 6)
        let secondFile = try audio(seconds: 3)
        let resolver = PlaybackFixtureResolver([
            first.id: .init(url: firstFile, duration: 6),
            second.id: .init(url: secondFile, duration: 3, expiresAt: Date().addingTimeInterval(45),
                             refreshedExpiresAt: Date().addingTimeInterval(7_200))
        ])
        let player = PlayerController(resolver: resolver)
        defer { player.pause() }
        player.apply(settings(crossfade: 0, gapless: true, automix: false))
        player.play([first, second])
        try await PlaybackTestSupport.eventually {
            await resolver.requests.filter { $0.trackID == self.second.id }.map(\.forceRefresh) == [false, true]
        }
        try await PlaybackTestSupport.waitUntil { player.standbyTrack == self.second && player.isStandbyReady }
        try await PlaybackTestSupport.waitUntil(timeout: 8) { player.currentTrack == self.second && player.isPlaying }
        let requests = await resolver.requests.map(\.trackID)
        XCTAssertEqual(requests, [first.id, second.id, second.id])
        XCTAssertNil(player.errorMessage)
    }

    // MARK: - Helpers

    private func settings(crossfade: TimeInterval, gapless: Bool, automix: Bool, autoplay: Bool = false) -> PlaybackTransitionSettings {
        var settings = PlaybackTransitionSettings()
        settings.crossfadeSeconds = crossfade
        settings.gapless = gapless
        settings.automix = automix
        settings.autoplay = autoplay
        return settings
    }

    private func audio(seconds: Int) throws -> URL {
        let url = try PlaybackTestSupport.audioFile(seconds: seconds)
        directories.append(url.deletingLastPathComponent())
        return url
    }

    private func fixtures(_ tracks: [(Track, Int, Double?)]) throws -> PlaybackFixtureResolver {
        var entries: [String: PlaybackFixtureResolver.Entry] = [:]
        for (track, seconds, loudness) in tracks {
            entries[track.id] = .init(url: try audio(seconds: seconds), duration: TimeInterval(seconds), loudnessDb: loudness)
        }
        return PlaybackFixtureResolver(entries)
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}

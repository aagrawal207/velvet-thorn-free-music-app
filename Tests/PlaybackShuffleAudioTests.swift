import XCTest
@testable import GanaBajana

@MainActor
final class PlaybackShuffleAudioTests: XCTestCase {
    private let a = Track(id: "shuffle-audio-a", title: "A", duration: 180)
    private let b = Track(id: "shuffle-audio-b", title: "B", duration: 180)
    private let c = Track(id: "shuffle-audio-c", title: "C", duration: 180)

    func testNativePausedPositionAndInstalledAudioSurviveStyleHistoryAndShuffleChanges() async throws {
        let source = [a, b, a, c]
        let (player, resolver) = try makePlayer(tracks: source)
        defer { player.pause() }
        var starts = 0
        var reads = 0
        var history: [ListeningEvent]? = [event(a)]
        var snapshots: [PlaybackSnapshot] = []
        player.onTrackStarted = { _ in starts += 1 }
        player.onSnapshotChanged = { snapshots.append($0) }
        player.shuffleHistoryProvider = { reads += 1; return history }
        player.play(source, startingAt: 2, shuffle: false)
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.position > 0.7 }
        player.pause()
        player.seek(to: 4.25)
        try await Task.sleep(for: .milliseconds(350))
        player.flushListeningProgress()
        let pausedPosition = player.position
        let stream = try XCTUnwrap(player.currentStreamURL)
        let requests = await resolver.requests
        let publications = snapshots.count

        player.setShuffleStyle(.fewerRepeats)
        history = []
        player.setShuffleStyle(.random)
        history = nil
        player.setShuffleStyle(.fewerRepeats)
        player.shuffleHistoryProvider = { reads += 1; return history }
        XCTAssertEqual(snapshots.count, publications)
        try await Task.sleep(for: .milliseconds(550))
        player.flushListeningProgress()
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(player.queue, source)
        XCTAssertEqual(player.currentIndex, 2)
        XCTAssertEqual(player.position, pausedPosition, accuracy: 0.05)
        XCTAssertEqual(player.position, 4.25, accuracy: 0.05)
        XCTAssertEqual(player.currentStreamURL, stream)
        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(player.isLoading)

        history = [event(a)]
        player.toggleShuffle()
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(player.currentTrack, a)
        XCTAssertEqual(player.currentIndex, 0)
        XCTAssertEqual(player.queue.count, source.count)
        XCTAssertEqual(player.queue.filter { $0 == a }.count, 2)
        XCTAssertEqual(snapshots.last?.originalQueue, source)
        player.toggleShuffle()
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(player.queue, source)
        XCTAssertEqual(player.currentIndex, 2)
        try await Task.sleep(for: .milliseconds(550))
        player.flushListeningProgress()
        XCTAssertEqual(player.currentStreamURL, stream)
        XCTAssertEqual(player.position, pausedPosition, accuracy: 0.05)
        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(player.isLoading)
        XCTAssertEqual(starts, 1)
        let after = await resolver.requests
        XCTAssertEqual(after, requests, "Config and queue order changes must not reinstall the active item")
        player.resumePlayback()
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.position > pausedPosition + 0.2 }
        XCTAssertEqual(starts, 1, "The selected occurrence keeps its once-only start acknowledgement")
        XCTAssertEqual(reads, 1)
        XCTAssertNil(player.errorMessage)
    }

    func testNewShuffledNativePlaybackReadsTheCheckpointJustAcknowledgedAndKeepsSourceOrder() async throws {
        let source = [a, b, c, a]
        let (player, _) = try makePlayer(tracks: source)
        defer { player.pause() }
        var first = a
        first.duration = 2
        var durable: [ListeningEvent] = []
        var captured: [ListeningEvent] = []
        var reads = 0
        var starts: [Track] = []
        var latest: PlaybackSnapshot?
        player.onListeningProgress = { track, id, startedAt, seconds in
            if let index = durable.firstIndex(where: { $0.id == id }) { durable[index].listenedSeconds += seconds }
            else { durable.append(ListeningEvent(id: id, track: track, startedAt: startedAt, listenedSeconds: seconds)) }
            return true
        }
        player.onTrackStarted = { starts.append($0) }
        player.onSnapshotChanged = { latest = $0 }
        player.shuffleHistoryProvider = { reads += 1; captured = durable; return durable }
        player.setShuffleStyle(.fewerRepeats)
        player.play([first], shuffle: false)
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.position > 1.2 }
        XCTAssertEqual(reads, 0)
        player.playShuffled(source)
        let selected = try XCTUnwrap(player.currentTrack)
        XCTAssertEqual(reads, 1)
        XCTAssertTrue(captured.contains { $0.track == first && $0.listenedSeconds >= ListeningAnalytics.qualifyingSeconds(for: first) })
        XCTAssertEqual(player.position, 0)
        XCTAssertEqual(player.currentIndex, 0)
        XCTAssertEqual(latest?.originalQueue, source)
        XCTAssertEqual(player.queue.count, source.count)
        XCTAssertEqual(player.queue.filter { $0 == a }.count, 2)
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.currentTrack == selected && starts.count == 2 }
        XCTAssertEqual(starts, [first, selected])
        player.pause()
        let pausedPosition = player.position
        player.toggleShuffle()
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(player.queue, source)
        XCTAssertEqual(player.currentTrack, selected)
        XCTAssertEqual(player.position, pausedPosition, accuracy: 0.05)
        XCTAssertFalse(player.isPlaying)
        XCTAssertNil(player.errorMessage)
    }

    func testStartingAShuffledQueueRetiresOldStandbyAndPreparesTheActualWeightedNextOccurrence() async throws {
        let oldNext = Track(id: "shuffle-audio-old-next", title: "Old next", duration: 180)
        let (player, resolver) = try makePlayer(tracks: [a, oldNext, b, c], gapless: true)
        defer { player.pause() }
        var starts: [Track] = []
        var reads = 0
        let history = [event(b)]
        player.onTrackStarted = { starts.append($0) }
        player.shuffleHistoryProvider = { reads += 1; return history }
        player.play([a, oldNext], shuffle: false)
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.standbyTrack == oldNext && player.isStandbyReady }
        let activeURL = player.currentStreamURL
        player.setShuffleStyle(.fewerRepeats)
        XCTAssertEqual(player.currentStreamURL, activeURL)
        XCTAssertEqual(player.standbyTrack, oldNext)
        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(reads, 0)

        player.playShuffled([b, c, b])
        XCTAssertEqual(reads, 1)
        XCTAssertNotEqual(player.standbyTrack, oldNext)
        let selected = try XCTUnwrap(player.currentTrack)
        let next = player.nextAutomaticTrack
        try await PlaybackTestSupport.waitUntil {
            player.isPlaying && player.currentTrack == selected && player.standbyTrack == next && player.isStandbyReady
        }
        XCTAssertEqual(starts, [a, selected])
        XCTAssertEqual(player.queue.count, 3)
        XCTAssertTrue(player.shuffleEnabled)
        XCTAssertEqual(player.queue.filter { $0 == b }.count, 2)
        let requests = await resolver.requests
        XCTAssertTrue(requests.allSatisfy { !$0.forceRefresh })
        XCTAssertNil(player.errorMessage)
    }

    func testRejectedListeningSurvivesShuffledReplacementAndIsAcknowledgedWithoutHiddenHistoryReads() async throws {
        let (player, _) = try makePlayer(tracks: [a, b, c])
        defer { player.pause() }
        var canWrite = false
        var attempts: [ListeningEvent] = []
        var saved: [ListeningEvent] = []
        var reads = 0
        player.onListeningProgress = { track, id, startedAt, seconds in
            let checkpoint = ListeningEvent(id: id, track: track, startedAt: startedAt, listenedSeconds: seconds)
            attempts.append(checkpoint)
            if canWrite { saved.append(checkpoint) }
            return canWrite
        }
        player.setShuffleStyle(.fewerRepeats)
        player.shuffleHistoryProvider = { reads += 1; return saved }
        player.play([a], shuffle: false)
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.position > 0.7 }
        player.pause()
        let rejected = try XCTUnwrap(attempts.last)
        XCTAssertTrue(saved.isEmpty)
        player.playShuffled([b, c])
        let selected = try XCTUnwrap(player.currentTrack)
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.position > 0.7 }
        player.pause()
        let order = player.queue
        XCTAssertEqual(reads, 1)
        XCTAssertTrue(saved.isEmpty)
        canWrite = true
        player.flushListeningProgress()
        player.flushListeningProgress()
        XCTAssertEqual(saved.map(\.track), [a, selected])
        XCTAssertEqual(saved.first?.id, rejected.id)
        XCTAssertEqual(saved.first?.startedAt, rejected.startedAt)
        XCTAssertEqual(try XCTUnwrap(saved.first?.listenedSeconds), rejected.listenedSeconds, accuracy: 0.001)
        XCTAssertNotEqual(saved.first?.id, saved.last?.id)
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(player.queue, order)
        XCTAssertTrue(player.shuffleEnabled)
        XCTAssertFalse(player.isPlaying)
        XCTAssertNil(player.errorMessage)
    }

    func testNativeRepeatOneReusesTheWeightedTailAndRecordsDistinctPlaybackSessions() async throws {
        let source = [a, b, c]
        let (player, _) = try makePlayer(tracks: source, seconds: 2)
        defer { player.pause() }
        var reads = 0
        var starts: [Track] = []
        var sessions = Set<UUID>()
        let history = [event(b)]
        player.setShuffleStyle(.fewerRepeats)
        player.shuffleHistoryProvider = { reads += 1; return history }
        player.onTrackStarted = { starts.append($0) }
        player.onListeningProgress = { _, id, _, _ in sessions.insert(id); return true }
        player.cycleRepeatMode()
        player.cycleRepeatMode()
        player.play(source, shuffle: true)
        let order = player.queue
        try await PlaybackTestSupport.waitUntil(timeout: 10) { starts.count >= 2 && player.isPlaying }
        player.pause()
        XCTAssertEqual(player.currentTrack, a)
        XCTAssertEqual(player.repeatMode, .one)
        XCTAssertEqual(player.queue, order)
        XCTAssertEqual(reads, 1)
        XCTAssertTrue(starts.allSatisfy { $0 == a })
        XCTAssertGreaterThanOrEqual(sessions.count, 2)
        XCTAssertNil(player.standbyTrack)
        XCTAssertNil(player.errorMessage)
    }

    private func makePlayer(tracks: [Track], seconds: Int = 20, gapless: Bool = false) throws -> (PlayerController, PlaybackFixtureResolver) {
        let url = try PlaybackTestSupport.audioFile(seconds: seconds)
        addTeardownBlock { try FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var entries: [String: PlaybackFixtureResolver.Entry] = [:]
        for track in tracks { entries[track.id] = .init(url: url, duration: TimeInterval(seconds)) }
        let resolver = PlaybackFixtureResolver(entries)
        let player = PlayerController(resolver: resolver)
        var settings = PlaybackTransitionSettings()
        settings.gapless = gapless
        settings.automix = false
        settings.autoplay = false
        settings.crossfadeSeconds = 0
        player.apply(settings)
        player.onListeningProgress = { _, _, _, _ in true }
        return (player, resolver)
    }

    private func event(_ track: Track) -> ListeningEvent {
        ListeningEvent(id: UUID(), track: track, startedAt: Date().addingTimeInterval(-60), listenedSeconds: 30)
    }
}

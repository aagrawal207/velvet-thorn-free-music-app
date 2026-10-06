import AVFoundation
import MediaPlayer
import XCTest
@testable import GanaBajana

@MainActor
final class LiveRadioPlaybackTests: XCTestCase {
    private let song = Track(id: "JGwWNGJdvx8", title: "Saved Song", artists: ["Saved Artist"], duration: 100)

    func testLiveModeReusesPlayerRetainsPausedQueueAndNeverCreatesRecordingEvents() async throws {
        let music = PlaybackResolutionGate()
        let live = LiveRadioResolutionGate()
        let player = PlayerController(resolver: music, liveRadioResolver: live)
        var starts: [Track] = []
        var events: [Track] = []
        var snapshots: [PlaybackSnapshot] = []
        player.onTrackStarted = { starts.append($0) }
        player.onListeningProgress = { track, _, _, _ in events.append(track); return true }
        player.onSnapshotChanged = { snapshots.append($0) }
        player.restore(PlaybackSnapshot(queue: [song, song], currentIndex: 1, position: 42, repeatMode: .all))
        snapshots.removeAll()
        let identity = player.activePlayerIdentity
        XCTAssertTrue(player.playLiveRadio(LiveRadioTestSupport.station))
        try await PlaybackTestSupport.eventually { await live.requests.count == 1 }
        XCTAssertNil(player.currentTrack)
        XCTAssertTrue(player.hasPlaybackSelection)
        XCTAssertEqual(player.displayTitle, "Public Radio")
        XCTAssertEqual(player.activePlayerIdentity, identity)
        XCTAssertFalse(player.activePlayerAllowsExternalPlayback)
        XCTAssertNil(player.standbyTrack)
        XCTAssertNil(player.standbyStreamURL)
        XCTAssertFalse(player.isStandbyReady)
        XCTAssertFalse(player.isRadioSession)
        XCTAssertNil(player.currentPlayCount)
        XCTAssertNil(player.resolvedViewCount)
        XCTAssertNil(player.sourceAudioQuality)
        XCTAssertFalse(player.isCurrentTrackCached)
        XCTAssertNil(player.nextAutomaticTrack)
        XCTAssertFalse(player.canReloadAudioQuality)
        player.seek(to: 90)
        player.next()
        player.previous()
        player.toggleShuffle()
        player.cycleRepeatMode()
        player.appendAutoplay([Track(id: "BddP6PYo2gs", title: "Not Radio")])
        player.handleLifecycleCheckpoint()
        XCTAssertEqual(player.position, 0)
        XCTAssertEqual(player.duration, 0)
        XCTAssertEqual(player.queue, [song, song])
        XCTAssertTrue(starts.isEmpty)
        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(snapshots.allSatisfy { $0.queue == [song, song] && $0.position == 42 })
        let musicRequests = await music.requests
        XCTAssertTrue(musicRequests.isEmpty)
        let snapshotJSON = String(decoding: try JSONEncoder().encode(snapshots), as: UTF8.self)
        XCTAssertFalse(snapshotJSON.contains("example.org"))
        XCTAssertFalse(snapshotJSON.contains("Public Radio"))
        player.stopLiveRadio()
        XCTAssertFalse(player.isLiveRadio)
        XCTAssertEqual(player.currentTrack, song)
        XCTAssertEqual(player.currentIndex, 1)
        XCTAssertEqual(player.position, 42)
        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(player.isLoading)
        await live.cancelRemaining()
    }

    func testNormalSelectionCancelsStationAndRejectsLateConnection() async throws {
        let music = PlaybackResolutionGate()
        let live = LiveRadioResolutionGate()
        let player = PlayerController(resolver: music, liveRadioResolver: live)
        player.playLiveRadio(LiveRadioTestSupport.station)
        try await PlaybackTestSupport.eventually { await live.requests.count == 1 }
        let first = await live.requests[0]
        player.play([song])
        let songRequest = try await PlaybackTestSupport.waitForRequests(1, on: music)[0]
        await music.finish(songRequest, with: .failure(MusicServiceError.unavailable("Selected song failure")))
        try await PlaybackTestSupport.waitUntil { player.errorMessage == "Selected song failure" }
        await live.finish(first, result: .success(LiveRadioConnection(station: LiveRadioTestSupport.station,
                                                                   streamingURL: LiveRadioTestSupport.station.streamingURL)))
        await Task.yield()
        XCTAssertNil(player.liveStation)
        XCTAssertEqual(player.currentTrack, song)
        XCTAssertEqual(player.errorMessage, "Selected song failure")
        XCTAssertNil(player.currentStreamURL)
        player.pause()
    }

    func testStationSelectionCancelsStaleSongResolutionAndDoesNotCacheStation() async throws {
        let music = PlaybackResolutionGate()
        let live = LiveRadioResolutionGate()
        let player = PlayerController(resolver: music, liveRadioResolver: live)
        player.play([song])
        let songRequest = try await PlaybackTestSupport.waitForRequests(1, on: music)[0]
        player.playLiveRadio(LiveRadioTestSupport.station)
        await music.finish(songRequest, with: .failure(MusicServiceError.unavailable("Stale song failure")))
        try await PlaybackTestSupport.eventually { await live.requests.count == 1 }
        XCTAssertNil(player.currentTrack)
        XCTAssertNil(player.errorMessage)
        XCTAssertTrue(player.isLoading)
        XCTAssertTrue(player.autoplayTrackIDs.isEmpty)
        player.pause()
        XCTAssertNil(player.currentStreamURL)
        await live.cancelRemaining()
    }

    func testNativeTransportDispatchAndLiveNowPlayingClearAllSongMetadata() async throws {
        let live = LiveRadioResolutionGate()
        let player = PlayerController(resolver: PlaybackResolutionGate(), liveRadioResolver: live)
        player.restore(PlaybackSnapshot(queue: [song], position: 37))
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyAlbumTitle: "Stale Album",
            MPNowPlayingInfoPropertyExternalContentIdentifier: song.id, MPMediaItemPropertyPlaybackDuration: 100]
        player.playLiveRadio(LiveRadioTestSupport.station)
        try await PlaybackTestSupport.eventually { await live.requests.count == 1 }
        let center = MPRemoteCommandCenter.shared()
        XCTAssertTrue(center.playCommand.isEnabled)
        XCTAssertTrue(center.pauseCommand.isEnabled)
        XCTAssertTrue(center.stopCommand.isEnabled)
        XCTAssertFalse(center.nextTrackCommand.isEnabled)
        XCTAssertFalse(center.previousTrackCommand.isEnabled)
        XCTAssertFalse(center.changePlaybackPositionCommand.isEnabled)
        let info = try XCTUnwrap(MPNowPlayingInfoCenter.default().nowPlayingInfo)
        XCTAssertEqual(info[MPNowPlayingInfoPropertyIsLiveStream] as? Bool, true)
        XCTAssertEqual(info[MPMediaItemPropertyTitle] as? String, "Public Radio")
        for key in [MPMediaItemPropertyAlbumTitle, MPMediaItemPropertyArtwork, MPMediaItemPropertyPlaybackDuration,
                    MPNowPlayingInfoPropertyElapsedPlaybackTime, MPNowPlayingInfoPropertyExternalContentIdentifier,
                    MPNowPlayingInfoPropertyPlaybackQueueIndex, MPNowPlayingInfoPropertyPlaybackQueueCount] { XCTAssertNil(info[key]) }
        PlaybackSystemControls.performTransport(.pause, owner: player)
        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(player.isLoading)
        PlaybackSystemControls.performTransport(.play, owner: player)
        try await PlaybackTestSupport.eventually { await live.requests.count == 2 }
        PlaybackSystemControls.performTransport(.stop, owner: player)
        XCTAssertNil(player.liveStation)
        XCTAssertEqual(player.position, 37)
        XCTAssertNil(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyIsLiveStream])
        XCTAssertFalse(player.isLoading)
        XCTAssertEqual(PlaybackAudioRoute.session.policy, .longFormAudio)
        await live.cancelRemaining()
    }

    func testPauseCancelsPendingRetryAndInterruptionCannotRestartExplicitPause() async throws {
        let live = LiveRadioResolutionGate()
        let player = PlayerController(resolver: PlaybackResolutionGate(), liveRadioResolver: live)
        player.playLiveRadio(LiveRadioTestSupport.station)
        try await PlaybackTestSupport.eventually { await live.requests.count == 1 }
        await live.finishFirst(result: .failure(LiveRadioError.unavailable))
        try await PlaybackTestSupport.waitUntil { player.isWaitingForLiveRadioRetry }
        player.handleInterruption(began: true)
        player.pause()
        player.handleInterruption(began: false, shouldResume: true)
        try await Task.sleep(for: .milliseconds(1_200))
        let requests = await live.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertFalse(player.isLoading)
        XCTAssertNil(player.currentStreamURL)
        player.stopLiveRadio()
        await live.cancelRemaining()
    }

    func testRetryBudgetEndsAfterThreeAttemptsAndNeverLeaksUnderlyingError() async throws {
        let live = LiveRadioResolutionGate()
        let player = PlayerController(resolver: PlaybackResolutionGate(), liveRadioResolver: live)
        player.playLiveRadio(LiveRadioTestSupport.station)
        for count in 1...3 {
            try await PlaybackTestSupport.eventually { await live.requests.count == count }
            let request = await live.requests[count - 1]
            await live.finish(request, result: .failure(MusicServiceError.unavailable("https://private.example.org/?account=secret")))
        }
        try await PlaybackTestSupport.waitUntil { player.errorMessage != nil }
        XCTAssertEqual(player.errorMessage, LiveRadioError.unavailable.localizedDescription)
        XCTAssertFalse(player.isLoading)
        XCTAssertFalse(player.isPlaying)
        player.stopLiveRadio()
    }

    func testRouteLossSleepAndMediaResetKeepLivePausedAndMusicResumePosition() async throws {
        let live = LiveRadioResolutionGate()
        let player = PlayerController(resolver: PlaybackResolutionGate(), liveRadioResolver: live)
        player.restore(PlaybackSnapshot(queue: [song], position: 29))
        player.playLiveRadio(LiveRadioTestSupport.station)
        try await PlaybackTestSupport.eventually { await live.requests.count == 1 }
        player.handleRouteDetached()
        player.handleMediaServicesReset()
        XCTAssertTrue(player.isLiveRadio)
        XCTAssertFalse(player.isLoading)
        XCTAssertFalse(player.activePlayerAllowsExternalPlayback)
        player.resumePlayback()
        try await PlaybackTestSupport.eventually { await live.requests.count == 2 }
        player.setSleepTimer(minutes: 1)
        let deadline = try XCTUnwrap(player.sleepUntil)
        player.expireSleepTimer(expected: deadline, now: deadline)
        XCTAssertFalse(player.isLoading)
        XCTAssertNil(player.currentStreamURL)
        player.stopLiveRadio()
        XCTAssertEqual(player.position, 29)
        await live.cancelRemaining()
    }

    func testOfflineOrInvalidStationDoesNotReplaceMusic() {
        let player = PlayerController(resolver: PlaybackResolutionGate(), liveRadioResolver: LiveRadioResolutionGate())
        player.restore(PlaybackSnapshot(queue: [song], position: 12))
        player.setNetworkOffline(true)
        XCTAssertFalse(player.playLiveRadio(LiveRadioTestSupport.station))
        XCTAssertEqual(player.currentTrack, song)
        XCTAssertEqual(player.position, 12)
        player.setNetworkOffline(false)
        let invalid = LiveRadioStation(id: UUID(), name: "Local File", streamingURL: URL(fileURLWithPath: "/audio.mp3"),
            homepageURL: nil, artworkURL: nil, countryCode: "", languages: [], tags: [], codec: "MP3", isHLS: false)
        XCTAssertFalse(player.playLiveRadio(invalid))
        XCTAssertEqual(player.currentTrack, song)
        XCTAssertFalse(AudioCache.isProviderTrackID(LiveRadioTestSupport.station.id.uuidString))
    }

    func testStationReplacementAndPauseFenceOlderConnectionResults() async throws {
        let live = LiveRadioResolutionGate()
        let player = PlayerController(resolver: PlaybackResolutionGate(), liveRadioResolver: live)
        let other = LiveRadioStation(id: UUID(), name: "Other Station", streamingURL: URL(string: "https://other.example.org/live")!,
            homepageURL: nil, artworkURL: nil, countryCode: "GB", languages: ["english"], tags: [], codec: "MP3", isHLS: false)
        player.playLiveRadio(LiveRadioTestSupport.station)
        try await PlaybackTestSupport.eventually { await live.requests.count == 1 }
        player.playLiveRadio(other)
        try await PlaybackTestSupport.eventually { await live.requests.count == 2 }
        player.pause()
        let requests = await live.requests
        await live.finish(requests[1], result: .failure(LiveRadioError.unavailable))
        await live.finish(requests[0], result: .success(LiveRadioConnection(station: LiveRadioTestSupport.station,
                                                                        streamingURL: LiveRadioTestSupport.station.streamingURL)))
        await Task.yield()
        XCTAssertEqual(player.liveStation, other)
        XCTAssertNil(player.currentStreamURL)
        XCTAssertNil(player.errorMessage)
        XCTAssertFalse(player.isLoading)
        player.stopLiveRadio()
    }

    func testAsynchronousCheckpointCarriesOnlyPendingSongAndSavedMusicResumeState() async throws {
        let live = LiveRadioResolutionGate()
        let player = PlayerController(resolver: PlaybackResolutionGate(), liveRadioResolver: live)
        var checkpoints: [PlaybackListeningCheckpoint] = []
        player.onListeningCheckpoint = { checkpoint in checkpoints.append(checkpoint); return true }
        player.restore(PlaybackSnapshot(queue: [song], position: 42))
        await player.waitForListeningCheckpointDelivery()
        let event = ListeningEvent(id: UUID(), track: song, startedAt: Date(), listenedSeconds: 3)
        XCTAssertTrue(player.enqueueListeningCheckpoint(event))
        player.playLiveRadio(LiveRadioTestSupport.station)
        try await PlaybackTestSupport.eventually { await live.requests.count == 1 }
        player.handleLifecycleCheckpoint()
        await player.waitForListeningCheckpointDelivery()
        XCTAssertTrue(checkpoints.allSatisfy { $0.snapshot.queue == [song] && $0.snapshot.position == 42 })
        XCTAssertEqual(checkpoints.flatMap(\.events).map(\.id), [event.id])
        XCTAssertTrue(checkpoints.allSatisfy { $0.recent == nil })
        player.discardPendingListening()
        player.handleLifecycleCheckpoint()
        await player.waitForListeningCheckpointDelivery()
        XCTAssertTrue(player.pendingListeningCheckpoints.isEmpty)
        XCTAssertNil(player.currentTrack)
        player.stopLiveRadio()
        await player.waitForListeningCheckpointDelivery()
        await live.cancelRemaining()
    }
}

actor LiveRadioResolutionGate: LiveRadioResolving {
    private(set) var requests: [UUID] = []
    private var pending: [UUID: CheckedContinuation<LiveRadioConnection, Error>] = [:]

    func resolve(_ station: LiveRadioStation) async throws -> LiveRadioConnection {
        let request = UUID()
        requests.append(request)
        return try await withCheckedThrowingContinuation { pending[request] = $0 }
    }

    func finish(_ request: UUID, result: Result<LiveRadioConnection, Error>) { pending.removeValue(forKey: request)?.resume(with: result) }
    func finishFirst(result: Result<LiveRadioConnection, Error>) {
        guard let first = requests.first else { return }
        finish(first, result: result)
    }
    func cancelRemaining() {
        let waiting = Array(pending.values)
        pending.removeAll()
        waiting.forEach { $0.resume(throwing: CancellationError()) }
    }
}

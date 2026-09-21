import XCTest
@testable import GanaBajana

@MainActor
final class LibraryRecoveryPlaybackTests: XCTestCase {
    func testExternalClearRecoveryDiscardsPlayerBacklogAndContinuesWithAFreshListeningIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GanaBajana-PrivacyRecoveryPlayback-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = try PlaybackTestSupport.audioFile()
        defer { try? FileManager.default.removeItem(at: audio.deletingLastPathComponent()) }
        let library = LibraryStore(directory: directory)
        let player = PlayerController(resolver: PlaybackFileResolver(url: audio, duration: 8))
        defer { player.pause() }
        var settings = PlaybackTransitionSettings()
        settings.autoplay = false
        settings.gapless = false
        settings.automix = false
        player.apply(settings)
        var rejected: [ListeningEvent] = []
        player.onListeningProgress = { track, session, started, seconds in
            let saved = library.recordListening(track: track, sessionID: session, startedAt: started, seconds: seconds)
            if !saved { rejected.append(ListeningEvent(id: session, track: track, startedAt: started, listenedSeconds: seconds)) }
            return saved
        }
        player.onSnapshotChanged = { snapshot in library.updatePlayback(snapshot) }
        var resets = 0
        library.onHistoryCleared = { [weak player] in resets += 1; player?.discardPendingListening() }
        let song = libraryTestTrack()
        player.play([song])
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.position > 0.7 }
        player.pause()
        let old = try XCTUnwrap(library.events.first)
        let external = LibraryStore(directory: directory)
        external.clearHistory()
        let boundary = player.position
        player.resumePlayback()
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.position > boundary + 0.7 }
        player.pause()
        XCTAssertEqual(rejected.last?.id, old.id)
        let resetAt = Date()
        let position = player.position
        XCTAssertEqual(library.reloadFromDisk(), .historyBoundary)
        XCTAssertEqual(resets, 1)
        XCTAssertTrue(library.events.isEmpty)
        XCTAssertEqual(player.currentTrack, song)
        // pause() checkpoints before AVPlayer.pause(); the privacy reset samples the native playhead again.
        XCTAssertEqual(player.position, position, accuracy: 0.05)
        XCTAssertFalse(player.isPlaying)
        player.flushListeningProgress()
        XCTAssertTrue(library.events.isEmpty)
        let resumePosition = player.position
        player.resumePlayback()
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.position > resumePosition + 0.7 }
        player.pause()
        player.flushListeningProgress()
        let restored = LibraryStore(directory: directory)
        let fresh = try XCTUnwrap(restored.events.first)
        XCTAssertEqual(restored.events.count, 1)
        XCTAssertNotEqual(fresh.id, old.id)
        XCTAssertGreaterThanOrEqual(fresh.startedAt, resetAt.addingTimeInterval(-0.05))
        XCTAssertGreaterThan(fresh.listenedSeconds, 0.5)
        XCTAssertLessThanOrEqual(fresh.listenedSeconds, player.position - resumePosition + 0.05)
    }

    func testReloadAndFlushKeepTheLivePlayerQueueAndRetryItsOriginalSessionExactlyOnce() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GanaBajana-RecoveryPlayback-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = try PlaybackTestSupport.audioFile()
        defer { try? FileManager.default.removeItem(at: audio.deletingLastPathComponent()) }
        let library = LibraryStore(directory: directory)
        let player = PlayerController(resolver: PlaybackFileResolver(url: audio, duration: 8))
        defer { player.pause() }
        var settings = PlaybackTransitionSettings()
        settings.autoplay = false
        settings.gapless = false
        settings.automix = false
        player.apply(settings)
        var rejected: [ListeningEvent] = []
        var accepted: [ListeningEvent] = []
        player.onListeningProgress = { track, session, started, seconds in
            let checkpoint = ListeningEvent(id: session, track: track, startedAt: started, listenedSeconds: seconds)
            let saved = library.recordListening(track: track, sessionID: session, startedAt: started, seconds: seconds)
            if saved { accepted.append(checkpoint) }
            else { rejected.append(checkpoint) }
            return saved
        }
        player.onSnapshotChanged = { snapshot in library.updatePlayback(snapshot) }
        var resets = 0
        library.onHistoryCleared = { [weak player] in resets += 1; player?.discardPendingListening() }
        let song = libraryTestTrack()
        player.play([song])
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.position > 0.7 }
        player.pause()
        let savedSession = try XCTUnwrap(library.events.first)
        let external = LibraryStore(directory: directory)
        let favorite = libraryTestTrack("external-favorite")
        external.toggleFavorite(favorite)
        let boundary = player.position
        player.resumePlayback()
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.position > boundary + 0.7 }
        player.pause()
        XCTAssertTrue(library.requiresReload)
        let failed = try XCTUnwrap(rejected.last)
        let position = player.position
        XCTAssertEqual(failed.id, savedSession.id)
        XCTAssertGreaterThan(failed.listenedSeconds, 0.5)
        let acceptedBeforeReload = accepted.count

        XCTAssertEqual(library.reloadFromDisk(), .reloaded)
        XCTAssertEqual(resets, 0)
        XCTAssertEqual(player.queue, [song])
        XCTAssertEqual(player.currentTrack, song)
        XCTAssertEqual(player.position, position)
        XCTAssertFalse(player.isPlaying)
        player.flushListeningProgress()
        player.flushListeningProgress()
        let flushedPosition = player.position
        // The saved cursor follows the post-pause sample, not the earlier pre-pause checkpoint.
        XCTAssertEqual(flushedPosition, position, accuracy: 0.05)
        XCTAssertEqual(accepted.count, acceptedBeforeReload + 1)
        let acknowledged = try XCTUnwrap(accepted.last)
        XCTAssertEqual(acknowledged.id, failed.id)
        XCTAssertEqual(acknowledged.startedAt, failed.startedAt)
        XCTAssertEqual(acknowledged.listenedSeconds, failed.listenedSeconds, accuracy: 0.001)
        let restored = LibraryStore(directory: directory)
        XCTAssertNil(restored.errorMessage)
        XCTAssertEqual(restored.events.count, 1)
        XCTAssertEqual(restored.events.first?.id, savedSession.id)
        XCTAssertEqual(try XCTUnwrap(restored.events.first?.listenedSeconds),
                       savedSession.listenedSeconds + failed.listenedSeconds, accuracy: 0.001)
        XCTAssertEqual(restored.favorites, [favorite])
        XCTAssertEqual(restored.playback.queue, [song])
        XCTAssertEqual(restored.playback.position, flushedPosition, accuracy: 0.001)
    }
}

import XCTest
@testable import GanaBajana

@MainActor
final class LibrarySyncPlaybackTests: XCTestCase {
    func testMergingRemoteLibraryAndQueueMetadataDoesNotReplaceOrPauseAnActivePlayer() async throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let audio = try PlaybackTestSupport.audioFile()
        defer { try? FileManager.default.removeItem(at: audio.deletingLastPathComponent()) }
        let library = LibraryStore(directory: harness.root.appendingPathComponent("playing"))
        let remote = harness.device(LibrarySyncTestData.b)
        let player = PlayerController(resolver: PlaybackFileResolver(url: audio, duration: 8))
        defer { player.pause() }
        var settings = PlaybackTransitionSettings()
        settings.autoplay = false
        settings.gapless = false
        settings.automix = false
        player.apply(settings)
        player.onSnapshotChanged = { [weak library] snapshot in library?.updatePlayback(snapshot) }
        let queue = [libraryTestTrack("live-a", duration: 8), libraryTestTrack("live-b", duration: 8)]
        player.play(queue)
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.position > 0.4 }
        remote.library.updatePlayback(PlaybackSnapshot(queue: [libraryTestTrack("other-device")], position: 70))
        remote.library.toggleFavorite(libraryTestTrack("remote-like"))
        let before = player.position
        let saved = library.playback
        try library.mergeCloudState(remote.state())
        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(player.queue, queue)
        XCTAssertEqual(player.currentTrack, queue.first)
        XCTAssertEqual(library.playback.queue, saved.queue)
        XCTAssertEqual(library.playback.position, saved.position)
        XCTAssertEqual(library.favorites.map(\.id), ["remote-like"])
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.position > before + 0.25 }
    }

    func testRemoteClearRetiresListeningIdentityWhileTheSameSongKeepsPlaying() async throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let audio = try PlaybackTestSupport.audioFile()
        defer { try? FileManager.default.removeItem(at: audio.deletingLastPathComponent()) }
        let library = LibraryStore(directory: harness.root.appendingPathComponent("privacy-playing"))
        let remote = harness.device(LibrarySyncTestData.b)
        let player = PlayerController(resolver: PlaybackFileResolver(url: audio, duration: 8))
        defer { player.pause() }
        var settings = PlaybackTransitionSettings()
        settings.autoplay = false
        settings.gapless = false
        settings.automix = false
        player.apply(settings)
        player.onSnapshotChanged = { [weak library] snapshot in library?.updatePlayback(snapshot) }
        player.onListeningProgress = { [weak library] track, id, start, seconds in
            library?.recordListening(track: track, sessionID: id, startedAt: start, seconds: seconds) ?? false
        }
        var boundaries = 0
        library.onHistoryCleared = { [weak player] in boundaries += 1; player?.discardPendingListening() }
        let song = libraryTestTrack("live", duration: 8)
        player.play([song])
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.position > 0.5 }
        player.flushListeningProgress()
        let previousID = try XCTUnwrap(library.events.first?.id)
        try remote.library.mergeCloudState(library.cloudReplica(replicaID: LibrarySyncTestData.a).state)
        remote.library.clearHistory()
        let before = player.position
        try library.mergeCloudState(remote.state())
        XCTAssertEqual(boundaries, 1)
        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(player.currentTrack, song)
        XCTAssertFalse(library.events.contains { $0.id == previousID })
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.position > before + 0.3 }
        player.flushListeningProgress()
        XCTAssertFalse(library.events.contains { $0.id == previousID })
        XCTAssertTrue(library.events.allSatisfy { $0.listenedSeconds < 1.5 })
    }
}

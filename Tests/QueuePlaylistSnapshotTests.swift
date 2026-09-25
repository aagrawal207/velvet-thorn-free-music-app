import XCTest
@testable import GanaBajana

final class QueuePlaylistSnapshotTests: XCTestCase {
    func testIncludesCurrentAndUpcomingSongsAtFirstMiddleAndLastIndexes() {
        let past = libraryTestTrack("past")
        let current = libraryTestTrack("current")
        let upcoming = libraryTestTrack("upcoming")
        let queue = [past, current, upcoming]

        XCTAssertEqual(QueuePlaylistSnapshot(queue: queue, currentIndex: 0).tracks, [past, current, upcoming])
        XCTAssertEqual(QueuePlaylistSnapshot(queue: queue, currentIndex: 1).tracks, [current, upcoming])
        XCTAssertEqual(QueuePlaylistSnapshot(queue: queue, currentIndex: 2).tracks, [upcoming])
    }

    func testEmptyAndInvalidIndexesNeverFallBackToSavingTheWholeQueue() {
        let queue = [libraryTestTrack("first"), libraryTestTrack("last")]
        for index in [Int.min, -1, queue.count, Int.max] {
            XCTAssertTrue(QueuePlaylistSnapshot(queue: queue, currentIndex: index).tracks.isEmpty, "Index: \(index)")
        }
        XCTAssertTrue(QueuePlaylistSnapshot(queue: [], currentIndex: 0).tracks.isEmpty)
    }

    func testDeduplicatesRecordingIDsAfterSlicingAndKeepsFirstRemainingMetadata() {
        let old = libraryTestTrack("same-recording", artist: "Old credit")
        var current = old
        current.title = "Current recording title"
        current.credits = [ArtistCredit(name: "Current artist"), ArtistCredit(name: "Featured artist")]
        current.albumTitle = "Current album"
        current.playCount = 42
        var laterDuplicate = current
        laterDuplicate.title = "Later duplicate title"
        let next = libraryTestTrack("next-recording")
        var alternate = current
        alternate.id = "alternate-recording"

        let snapshot = QueuePlaylistSnapshot(queue: [old, current, next, laterDuplicate, alternate, next], currentIndex: 1)

        XCTAssertEqual(snapshot.tracks, [current, next, alternate])
        XCTAssertEqual(snapshot.tracks.first?.credits, current.credits)
        XCTAssertEqual(snapshot.tracks.first?.playCount, 42)
        XCTAssertEqual(snapshot.tracks.last?.title, current.title, "A different recording with the same title stays selected")
    }

    func testCapturesVisibleShuffledOrderWithoutChangingOccurrenceIdentityOrOriginalOrder() {
        let a = libraryTestTrack("a"), b = libraryTestTrack("b"), c = libraryTestTrack("c")
        var queue = PlaybackQueue()
        queue.restore(PlaybackSnapshot(queue: [c, b, a, b], currentIndex: 1, shuffleEnabled: true,
                                       originalQueue: [a, b, b, c]))
        let selected = queue.selectedID
        let occurrences = queue.entries.map(\.id)
        let original = queue.original.map(\.id)

        let snapshot = QueuePlaylistSnapshot(queue: queue.tracks, currentIndex: queue.index)

        XCTAssertEqual(snapshot.tracks, [b, a])
        XCTAssertEqual(queue.tracks, [c, b, a, b])
        XCTAssertEqual(queue.selectedID, selected)
        XCTAssertEqual(queue.entries.map(\.id), occurrences)
        XCTAssertEqual(queue.original.map(\.id), original)
        XCTAssertEqual(queue.index, 1)
        XCTAssertTrue(queue.shuffled)
    }

    func testCapturedSelectionSurvivesAdvanceRemovalAndNewPlaybackMetadata() {
        let past = libraryTestTrack("past"), current = libraryTestTrack("current"), next = libraryTestTrack("next")
        var queue = PlaybackQueue()
        queue.replace([past, current, next], startingAt: 1)
        let captured = QueuePlaylistSnapshot(queue: queue.tracks, currentIndex: queue.index)
        XCTAssertTrue(queue.advance(repeatMode: .off, automatic: true))
        queue.remove(at: 1)
        var updated = current
        updated.title = "Metadata from a newer play session"
        let replacement = libraryTestTrack("replacement")
        queue.replace([replacement, updated], startingAt: 1)

        XCTAssertEqual(captured.tracks, [current, next])
        XCTAssertEqual(QueuePlaylistSnapshot(queue: queue.tracks, currentIndex: queue.index).tracks, [updated])
    }

    @MainActor
    func testAtomicCreationPublishesOnePopulatedPlaylistAndPreservesSavedPlayback() throws {
        try withLibraryTestDirectory { directory in
            let store = LibraryStore(directory: directory)
            let past = libraryTestTrack("past"), next = libraryTestTrack("next")
            let old = libraryTestTrack("current", artist: "Old library credit")
            var current = old
            current.title = "Current playback title"
            current.credits = [ArtistCredit(name: "Current credit")]
            store.toggleFavorite(old)
            let playback = PlaybackSnapshot(queue: [past, current, next, current], currentIndex: 1, position: 32,
                                            shuffleEnabled: true, repeatMode: .all,
                                            originalQueue: [current, current, past, next])
            store.updatePlayback(playback)
            let captured = QueuePlaylistSnapshot(queue: playback.queue, currentIndex: playback.currentIndex)
            var publications: [[Track]] = []
            store.onSyncChange = { [weak store] in publications.append(store?.playlists.first?.tracks ?? []) }
            defer { store.onSyncChange = nil }

            let id = store.createPlaylist(name: "  Saved selection\n", tracks: captured.tracks + [current])

            XCTAssertNil(store.errorMessage)
            XCTAssertEqual(publications, [[current, next]], "A create must never publish an empty intermediate playlist")
            let saved = try XCTUnwrap(store.playlists.first { $0.id == id })
            XCTAssertEqual(saved.name, "Saved selection")
            XCTAssertEqual(saved.tracks, [current, next])
            let reloaded = LibraryStore(directory: directory)
            XCTAssertEqual(reloaded.playlists.first { $0.id == id }?.tracks, [current, next])
            XCTAssertEqual(reloaded.favorites, [old])
            XCTAssertEqual(reloaded.playback.queue, playback.queue)
            XCTAssertEqual(reloaded.playback.originalQueue, playback.originalQueue)
            XCTAssertEqual(reloaded.playback.currentIndex, 1)
            XCTAssertEqual(reloaded.playback.position, 32)
            XCTAssertTrue(reloaded.playback.shuffleEnabled)
            XCTAssertEqual(reloaded.playback.repeatMode, .all)
        }
    }

    @MainActor
    func testFailedWritePublishesNothingAndRetriesTheCapturedSelectionAfterQueueAdvance() throws {
        try withLibraryTestDirectory { directory in
            let store = LibraryStore(directory: directory)
            let past = libraryTestTrack("past"), current = libraryTestTrack("current"), next = libraryTestTrack("next")
            var queue = PlaybackQueue()
            queue.replace([past, current, next, current], startingAt: 1)
            let selected = queue.selectedID
            let captured = QueuePlaylistSnapshot(queue: queue.tracks, currentIndex: queue.index)
            var publications = 0
            store.onSyncChange = { publications += 1 }
            let file = directory.appendingPathComponent(LibraryPersistence.fileName)
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)

            let rejectedID = store.createPlaylist(name: "Keep this selection", tracks: captured.tracks)

            XCTAssertNotNil(store.errorMessage)
            XCTAssertFalse(store.playlists.contains { $0.id == rejectedID })
            XCTAssertTrue(store.playlists.isEmpty)
            XCTAssertEqual(publications, 0)
            XCTAssertEqual(queue.tracks, [past, current, next, current])
            XCTAssertEqual(queue.selectedID, selected)
            XCTAssertEqual(queue.index, 1)

            XCTAssertTrue(queue.advance(repeatMode: .off, automatic: true))
            try FileManager.default.removeItem(at: file)
            let id = store.createPlaylist(name: "Keep this selection", tracks: captured.tracks)

            XCTAssertNil(store.errorMessage)
            XCTAssertEqual(publications, 1)
            XCTAssertEqual(store.playlists.count, 1)
            XCTAssertEqual(LibraryStore(directory: directory).playlists.first { $0.id == id }?.tracks, [current, next])
            XCTAssertFalse(store.playlists.contains { $0.id == rejectedID })
            XCTAssertEqual(queue.current, next)
            XCTAssertEqual(queue.index, 2)
        }
    }

    @MainActor
    func testInvalidTrackRejectsTheEntirePlaylistWithoutAnEmptyOrPartialSave() throws {
        try withLibraryTestDirectory { directory in
            let store = LibraryStore(directory: directory)
            let existing = store.createPlaylist(name: "Already saved", tracks: [libraryTestTrack("existing")])
            let file = directory.appendingPathComponent(LibraryPersistence.fileName)
            let before = try Data(contentsOf: file)
            var invalid = libraryTestTrack("invalid")
            invalid.duration = -1
            let captured = QueuePlaylistSnapshot(queue: [libraryTestTrack("valid"), invalid], currentIndex: 0)

            let rejected = store.createPlaylist(name: "Must be atomic", tracks: captured.tracks)

            XCTAssertNotNil(store.errorMessage)
            XCTAssertEqual(store.playlists.map(\.id), [existing])
            XCTAssertFalse(store.playlists.contains { $0.id == rejected })
            XCTAssertEqual(try Data(contentsOf: file), before)
        }
    }

    @MainActor
    func testSavingDoesNotReplacePausedAudioPositionOrPlaybackModes() async throws {
        let file = try PlaybackTestSupport.audioFile(seconds: 30)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let resolver = PlaybackFileResolver(url: file, duration: 30)
        let player = PlayerController(resolver: resolver)
        defer { player.pause() }
        let a = libraryTestTrack("a", duration: 30), b = libraryTestTrack("b", duration: 30)
        let c = libraryTestTrack("c", duration: 30)
        player.play([a, b, c], startingAt: 1)
        try await PlaybackTestSupport.waitUntil { player.isPlaying }
        player.pause()
        player.seek(to: 12)
        try await PlaybackTestSupport.waitUntil { abs(player.position - 12) < 0.2 }
        player.cycleRepeatMode()
        player.toggleShuffle()
        let queue = player.queue
        let position = player.position
        let stream = try XCTUnwrap(player.currentStreamURL)
        let captured = QueuePlaylistSnapshot(queue: queue, currentIndex: player.currentIndex)

        try withLibraryTestDirectory { directory in
            let store = LibraryStore(directory: directory)
            let id = store.createPlaylist(name: "Paused selection", tracks: captured.tracks)
            XCTAssertNil(store.errorMessage)
            XCTAssertEqual(store.playlists.first { $0.id == id }?.tracks, queue)
        }

        XCTAssertEqual(player.queue, queue)
        XCTAssertEqual(player.currentTrack, b)
        XCTAssertEqual(player.currentIndex, 0)
        XCTAssertEqual(player.position, position, accuracy: 0.001)
        XCTAssertEqual(player.currentStreamURL, stream)
        XCTAssertTrue(player.shuffleEnabled)
        XCTAssertEqual(player.repeatMode, .all)
        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(player.isLoading)
    }
}

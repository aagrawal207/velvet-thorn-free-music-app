import XCTest
@testable import GanaBajana

final class ListeningHistoryTests: XCTestCase {
    @MainActor
    func testDeltaCheckpointsMergeAcrossReloadAndOnlyQualifyOnePlayPerSession() async throws {
        try withLibraryTestDirectory { directory in
            let track = libraryTestTrack()
            let session = UUID()
            let startedAt = Date().addingTimeInterval(-3600)
            let store = LibraryStore(directory: directory)
            store.recordListening(track: track, sessionID: session, startedAt: startedAt, seconds: 15)
            XCTAssertEqual(store.summary(for: .week).plays, 0)
            store.recordListening(track: track, sessionID: session, startedAt: startedAt, seconds: 15)
            XCTAssertEqual(store.events.count, 1)
            XCTAssertEqual(store.summary(for: .week).plays, 1)
            XCTAssertEqual(store.summary(for: .week).seconds, 30)
            let restored = LibraryStore(directory: directory)
            restored.recordListening(track: track, sessionID: session, startedAt: startedAt, seconds: 15)
            XCTAssertEqual(restored.events.count, 1)
            XCTAssertEqual(restored.summary(for: .week).seconds, 45)
            XCTAssertEqual(restored.summary(for: .week).plays, 1)
            restored.recordListening(track: track, sessionID: UUID(), startedAt: startedAt, seconds: 30)
            XCTAssertEqual(restored.summary(for: .week).seconds, 75)
            XCTAssertEqual(restored.summary(for: .week).plays, 2)
            XCTAssertEqual(restored.summary(for: .week).uniqueTracks, 1)
        }
    }

    @MainActor
    func testSeekPositionsAndQueueSnapshotsNeverBecomeListeningTime() async throws {
        try withLibraryTestDirectory { directory in
            let store = LibraryStore(directory: directory)
            let track = libraryTestTrack()
            for position in [0.0, 180, 40, 220] {
                store.updatePlayback(PlaybackSnapshot(queue: [track], position: position))
                store.recordRecent(track: track, position: position)
            }
            XCTAssertTrue(store.events.isEmpty)
            XCTAssertEqual(store.summary(for: .week).seconds, 0)
            store.recordListening(track: track, sessionID: UUID(), startedAt: Date().addingTimeInterval(-60), seconds: 10)
            store.updatePlayback(PlaybackSnapshot(queue: [track], position: 200))
            XCTAssertEqual(store.summary(for: .week).seconds, 10)
            XCTAssertEqual(store.summary(for: .week).plays, 0)
            XCTAssertEqual(LibraryStore(directory: directory).summary(for: .week).seconds, 10)
        }
    }

    @MainActor
    func testHistoryDisabledSkipsNewEntriesAndUpdatesToExistingSessionsAndRecents() async throws {
        try withLibraryTestDirectory { directory in
            let store = LibraryStore(directory: directory)
            let first = libraryTestTrack()
            let second = libraryTestTrack("song-b")
            let session = UUID()
            let start = Date().addingTimeInterval(-3600)
            store.recordListening(track: first, sessionID: session, startedAt: start, seconds: 20)
            store.recordRecent(track: first, position: 20)
            let originalRecentDate = store.recentlyPlayed[0].playedAt
            store.preferences.saveListeningHistory = false
            store.recordListening(track: first, sessionID: session, startedAt: start, seconds: 100)
            store.recordListening(track: second, sessionID: UUID(), startedAt: start, seconds: 100)
            store.recordRecent(track: first, position: 80)
            store.recordRecent(track: second, position: 100)
            store.updatePlayback(PlaybackSnapshot(queue: [second], position: 100))
            XCTAssertEqual(store.events.count, 1)
            XCTAssertEqual(store.events[0].listenedSeconds, 20)
            XCTAssertEqual(store.recentlyPlayed.count, 1)
            XCTAssertEqual(store.recentlyPlayed[0].position, 20)
            XCTAssertEqual(store.recentlyPlayed[0].playedAt, originalRecentDate)
            XCTAssertEqual(store.playback.position, 100)
            XCTAssertFalse(LibraryStore(directory: directory).preferences.saveListeningHistory)
            store.preferences.saveListeningHistory = true
            store.recordListening(track: first, sessionID: session, startedAt: start, seconds: 10)
            XCTAssertEqual(store.summary(for: .week).seconds, 30)
            XCTAssertEqual(store.summary(for: .week).plays, 1)
        }
    }

    @MainActor
    func testClearHistoryPreservesLikesPlaylistsPreferencesQueueAndLyricsTiming() async throws {
        try withLibraryTestDirectory { directory in
            let store = LibraryStore(directory: directory)
            let track = libraryTestTrack()
            store.toggleFavorite(track)
            let id = store.createPlaylist(name: "Keep me")
            store.add(track, to: id)
            store.setLyricsOffset(-1.2345, for: track.id)
            store.updatePlayback(PlaybackSnapshot(queue: [track], position: 20))
            store.recordRecent(track: track, position: 20)
            store.recordListening(track: track, sessionID: UUID(), startedAt: Date().addingTimeInterval(-60), seconds: 30)
            store.preferences.saveListeningHistory = false
            store.clearHistory()
            let restored = LibraryStore(directory: directory)
            XCTAssertTrue(restored.events.isEmpty)
            XCTAssertTrue(restored.recentlyPlayed.isEmpty)
            XCTAssertEqual(restored.summary(for: .year).seconds, 0)
            XCTAssertEqual(restored.favorites, [track])
            XCTAssertEqual(restored.playlists[0].tracks, [track])
            XCTAssertEqual(restored.playback.position, 20)
            XCTAssertEqual(restored.lyricsOffset(for: track.id), -1.2345)
            XCTAssertFalse(restored.preferences.saveListeningHistory)
        }
    }

    @MainActor
    func testInvalidDeltasDatesAndReusedSessionIdentitiesAreRejected() async throws {
        try withLibraryTestDirectory { directory in
            let store = LibraryStore(directory: directory)
            let track = libraryTestTrack()
            let session = UUID()
            let start = Date().addingTimeInterval(-3600)
            XCTAssertTrue(store.recordListening(track: track, sessionID: UUID(), startedAt: start, seconds: 0))
            for seconds in [-1.0, .nan, .infinity, -.infinity, 1e300] {
                XCTAssertFalse(store.recordListening(track: track, sessionID: UUID(), startedAt: start, seconds: seconds))
            }
            for timestamp in [-1.0, 253_402_300_800, 1e300, .infinity, -.infinity, .nan] {
                XCTAssertFalse(store.recordListening(track: track, sessionID: UUID(),
                                                     startedAt: Date(timeIntervalSince1970: timestamp), seconds: 30))
            }
            XCTAssertTrue(store.events.isEmpty)
            XCTAssertTrue(store.recordListening(track: track, sessionID: session, startedAt: start, seconds: 30))
            XCTAssertFalse(store.recordListening(track: libraryTestTrack("different"), sessionID: session, startedAt: start, seconds: 30))
            XCTAssertFalse(store.recordListening(track: track, sessionID: session, startedAt: start.addingTimeInterval(10), seconds: 30))
            XCTAssertEqual(store.events.count, 1)
            XCTAssertEqual(store.events[0].listenedSeconds, 30)
            XCTAssertNotNil(store.errorMessage)
        }
    }

    @MainActor
    func testRecentsUseStableSongIdentityAndPreserveFractionalResumePositions() async throws {
        try withLibraryTestDirectory { directory in
            let store = LibraryStore(directory: directory)
            let first = libraryTestTrack()
            let second = libraryTestTrack("song-b")
            store.recordRecent(track: first, position: 1.25)
            store.recordRecent(track: second, position: 2.5)
            store.recordRecent(track: first, position: 12.875)
            XCTAssertEqual(store.recentlyPlayed.map(\.id), [first.id, second.id])
            XCTAssertEqual(store.recentlyPlayed[0].position, 12.875)
            store.recordRecent(track: first, position: .nan)
            XCTAssertEqual(store.recentlyPlayed[0].position, 12.875)
            XCTAssertEqual(LibraryStore(directory: directory).recentlyPlayed[0].position, 12.875)
        }
    }

    @MainActor
    func testOffsetsArePerSongPrecisePersistentAndRejectNonfiniteInput() async throws {
        try withLibraryTestDirectory { directory in
            let store = LibraryStore(directory: directory)
            XCTAssertEqual(store.lyricsOffset(for: "unknown"), 0)
            store.setLyricsOffset(0.012345, for: "a")
            store.setLyricsOffset(-2.75, for: "b")
            store.setLyricsOffset(.nan, for: "a")
            store.setLyricsOffset(.infinity, for: "b")
            store.setLyricsOffset(1e300, for: "a")
            store.setLyricsOffset(1, for: "  ")
            let restored = LibraryStore(directory: directory)
            XCTAssertEqual(restored.lyricsOffset(for: "a"), 0.012345)
            XCTAssertEqual(restored.lyricsOffset(for: "b"), -2.75)
            restored.setLyricsOffset(0, for: "a")
            XCTAssertEqual(LibraryStore(directory: directory).lyricsOffset(for: "a"), 0)
            XCTAssertEqual(LibraryStore(directory: directory).lyricsOffset(for: "b"), -2.75)
        }
    }
}

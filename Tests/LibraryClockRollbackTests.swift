import XCTest
@testable import GanaBajana

@MainActor
final class LibraryClockRollbackTests: XCTestCase {
    func testReopenSixtySecondsEarlierAllowsPreferencesAndTipsWithoutChangingSavedData() throws {
        try withLibraryTestDirectory { directory in
            let time = RecommendationFixtures.now
            let clock = RecommendationTestClock(time)
            let store = LibraryStore(directory: directory, now: { clock.now })
            store.preferences.languages = [.hindi]
            let song = libraryTestTrack()
            let other = libraryTestTrack("other")
            let session = UUID()
            store.toggleFavorite(song)
            let playlistID = store.createPlaylist(name: "Saved before clock correction")
            store.add(song, to: playlistID)
            XCTAssertTrue(store.recordListening(track: song, sessionID: session, startedAt: time, seconds: 45))
            store.recordRecent(track: song, position: 12.5)
            store.recordSearch("Keep this search")
            store.updatePlayback(PlaybackSnapshot(queue: [song], position: 12.5, originalQueue: [song]))
            store.setLyricsOffset(-0.125, for: song.id)
            XCTAssertTrue(store.setRecordingLanguageOverride("hi", for: song.id))
            store.follow(FollowedArtist(id: "artist", name: "Artist", followedAt: time, knownReleaseIDs: ["old"]))
            let release = ArtistRelease(id: "new", title: "New release", subtitle: "Album • 2026",
                                        artistID: "artist", artistName: "Artist", discoveredAt: time)
            XCTAssertTrue(store.recordReleaseCheck(artistID: "artist", knownReleaseIDs: ["old", "new"],
                                                   newReleases: [release], checkedAt: time))
            store.saveMix(GeneratedPlaylist(kind: .dailyMix, tracks: [song], generatedAt: time,
                                            periodKey: "saved-day", seedArtists: song.artists))
            store.toggleDislike(other)
            XCTAssertTrue(store.recordTip(transactionID: 1, credited: true))
            XCTAssertNil(store.errorMessage)

            let url = directory.appendingPathComponent(LibraryPersistence.fileName)
            let original = try Data(contentsOf: url)
            clock.advance(by: -60)
            let reopened = LibraryStore(directory: directory, now: { clock.now })
            XCTAssertNil(reopened.errorMessage)
            XCTAssertEqual(try Data(contentsOf: url), original, "Opening at T−60 must not rewrite any timestamps")
            XCTAssertEqual(reopened.events.first?.startedAt, time)
            XCTAssertEqual(reopened.recentlyPlayed.first?.playedAt, time)
            XCTAssertEqual(reopened.playlists.first?.createdAt, time)
            XCTAssertEqual(reopened.followedArtists.first?.followedAt, time)
            XCTAssertEqual(reopened.followedArtists.first?.lastCheckedAt, time)
            XCTAssertEqual(reopened.releases.first?.discoveredAt, time)
            XCTAssertEqual(reopened.mixes.first?.generatedAt, time)
            XCTAssertEqual(reopened.disliked.first?.dislikedAt, time)

            reopened.preferences.appearance = .light
            XCTAssertTrue(reopened.recordTip(transactionID: 1, credited: false))
            XCTAssertTrue(reopened.recordTip(transactionID: 2, credited: true))
            XCTAssertNil(reopened.errorMessage)
            var expected = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
            var preferences = try XCTUnwrap(expected["preferences"] as? [String: Any])
            preferences["appearance"] = "light"
            expected["preferences"] = preferences
            expected["tipTransactions"] = ["1": false, "2": true]
            let saved = try Data(contentsOf: url)
            var actual = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
            let previousClock = try LibraryPersistence.decode(original, now: clock.now).syncState?.clock
            let savedClock = try LibraryPersistence.decode(saved, now: clock.now).syncState?.clock
            XCTAssertGreaterThan(try XCTUnwrap(savedClock), try XCTUnwrap(previousClock))
            expected.removeValue(forKey: "syncState")
            actual.removeValue(forKey: "syncState")
            XCTAssertEqual(NSDictionary(dictionary: actual), NSDictionary(dictionary: expected))

            let restored = LibraryStore(directory: directory, now: { clock.now })
            XCTAssertNil(restored.errorMessage)
            XCTAssertEqual(restored.playlists.first?.id, playlistID)
            XCTAssertEqual(restored.events.first?.id, session)
            XCTAssertEqual(restored.events.first?.listenedSeconds, 45)
            XCTAssertEqual(restored.summary(for: .week, now: clock.now).seconds, 0,
                           "A future-dated session remains stored but is outside the current recap")
            XCTAssertEqual(restored.summary(for: .week, now: time).seconds, 45)
            XCTAssertEqual(try Data(contentsOf: url), saved)
        }
    }

    func testPlaylistMutationsAfterRollbackPreserveCreationAndLastUpdateUntilClockCatchesUp() throws {
        try withLibraryTestDirectory { directory in
            let createdAt = RecommendationFixtures.now.addingTimeInterval(-10)
            let clock = RecommendationTestClock(createdAt)
            let store = LibraryStore(directory: directory, now: { clock.now })
            let first = libraryTestTrack("a")
            let second = libraryTestTrack("b")
            let third = libraryTestTrack("c")
            let id = store.createPlaylist(name: "First name")
            store.add(first, to: id)
            store.add(second, to: id)
            clock.advance(by: 10)
            store.renamePlaylist(id: id, name: "Before correction")
            let updatedAt = clock.now
            clock.advance(by: -60)
            let reopened = LibraryStore(directory: directory, now: { clock.now })

            let mutations: [() -> Void] = [
                { reopened.renamePlaylist(id: id, name: "After correction") },
                { reopened.add(third, to: id) },
                { reopened.moveTracks(in: id, from: IndexSet(integer: 2), to: 0) },
                { reopened.remove(trackID: first.id, from: id) },
            ]
            for mutate in mutations {
                mutate()
                XCTAssertNil(reopened.errorMessage)
                let playlist = try XCTUnwrap(LibraryStore(directory: directory, now: { clock.now }).playlists.first)
                XCTAssertEqual(playlist.id, id)
                XCTAssertEqual(playlist.createdAt, createdAt)
                XCTAssertEqual(playlist.updatedAt, updatedAt)
                XCTAssertGreaterThanOrEqual(playlist.updatedAt, playlist.createdAt)
            }
            XCTAssertEqual(reopened.playlists.first?.name, "After correction")
            XCTAssertEqual(reopened.playlists.first?.tracks, [third, second])
            clock.advance(by: 61)
            reopened.renamePlaylist(id: id, name: "Clock caught up")
            XCTAssertNil(reopened.errorMessage)
            let updated = try XCTUnwrap(LibraryStore(directory: directory, now: { clock.now }).playlists.first)
            XCTAssertEqual(updated.createdAt, createdAt)
            XCTAssertEqual(updated.updatedAt, updatedAt.addingTimeInterval(1))
        }
    }

    func testListeningCheckpointAfterRollbackKeepsOriginalSessionStart() throws {
        try withLibraryTestDirectory { directory in
            let clock = RecommendationTestClock()
            let start = clock.now
            let song = libraryTestTrack()
            let id = UUID()
            let store = LibraryStore(directory: directory, now: { clock.now })
            XCTAssertTrue(store.recordListening(track: song, sessionID: id, startedAt: start, seconds: 15))
            clock.advance(by: -60)
            let reopened = LibraryStore(directory: directory, now: { clock.now })
            XCTAssertTrue(reopened.recordListening(track: song, sessionID: id, startedAt: start, seconds: 20))
            let restored = LibraryStore(directory: directory, now: { clock.now })
            XCTAssertNil(restored.errorMessage)
            XCTAssertEqual(restored.events.count, 1)
            XCTAssertEqual(restored.events.first?.id, id)
            XCTAssertEqual(restored.events.first?.startedAt, start)
            XCTAssertEqual(restored.events.first?.listenedSeconds, 35)
        }
    }

    func testInvalidDateBoundsAndBackwardsPlaylistMetadataStillPreserveTheWholeFile() throws {
        let time = RecommendationFixtures.now
        for invalid in [-1.0, 253_402_300_800, 1e300] {
            try withLibraryTestDirectory { directory in
                var document = LibraryDocument()
                document.favorites = [libraryTestTrack()]
                document.events = [ListeningEvent(id: UUID(), track: libraryTestTrack(),
                                                  startedAt: Date(timeIntervalSince1970: invalid), listenedSeconds: 30)]
                let bytes = try LibraryPersistence.encode(document)
                let url = directory.appendingPathComponent(LibraryPersistence.fileName)
                try LibraryPersistence.write(bytes, to: url, replacing: nil)
                let store = LibraryStore(directory: directory, now: { time.addingTimeInterval(-60) })
                let error = try XCTUnwrap(store.errorMessage)
                store.preferences.appearance = .light
                XCTAssertFalse(store.recordTip(transactionID: 1, credited: true))
                XCTAssertEqual(store.errorMessage, error)
                XCTAssertEqual(try Data(contentsOf: url), bytes)
            }
        }
        try withLibraryTestDirectory { directory in
            var document = LibraryDocument()
            document.playlists = [UserPlaylist(name: "Invalid ordering", createdAt: time,
                                                updatedAt: time.addingTimeInterval(-1))]
            let bytes = try LibraryPersistence.encode(document)
            let url = directory.appendingPathComponent(LibraryPersistence.fileName)
            try LibraryPersistence.write(bytes, to: url, replacing: nil)
            let store = LibraryStore(directory: directory, now: { time.addingTimeInterval(-60) })
            XCTAssertNotNil(store.errorMessage)
            store.clearHistory()
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
    }

    func testNonfiniteAndAbsurdDatesAreRejectedInEveryDatedCollection() throws {
        let time = RecommendationFixtures.now
        let song = libraryTestTrack()
        var valid = LibraryDocument()
        valid.playlists = [UserPlaylist(name: "Playlist", createdAt: time, updatedAt: time)]
        valid.events = [ListeningEvent(id: UUID(), track: song, startedAt: time, listenedSeconds: 30)]
        valid.recentlyPlayed = [RecentListen(track: song, playedAt: time, position: 1)]
        valid.followedArtists = [FollowedArtist(id: "artist", name: "Artist", followedAt: time, lastCheckedAt: time)]
        valid.releases = [ArtistRelease(id: "release", title: "Release", subtitle: "", artistID: "artist",
                                       artistName: "Artist", discoveredAt: time)]
        valid.mixes = [GeneratedPlaylist(kind: .dailyMix, tracks: [song], generatedAt: time,
                                        periodKey: "day", seedArtists: [])]
        valid.disliked = [DislikedSong(id: "other", title: "Other song", artists: [], dislikedAt: time)]
        let mutations: [(inout LibraryDocument, Date) -> Void] = [
            { $0.playlists[0].createdAt = $1 }, { $0.playlists[0].updatedAt = $1 },
            { $0.events[0].startedAt = $1 }, { $0.recentlyPlayed[0].playedAt = $1 },
            { $0.followedArtists[0].followedAt = $1 }, { $0.followedArtists[0].lastCheckedAt = $1 },
            { $0.releases[0].discoveredAt = $1 }, { $0.mixes[0].generatedAt = $1 },
            { $0.disliked[0].dislikedAt = $1 },
        ]
        XCTAssertNoThrow(try LibraryValidation.validate(valid, now: time.addingTimeInterval(-60)))
        for timestamp in [-1.0, 253_402_300_800, 1e300, .infinity, -.infinity, .nan] {
            for mutate in mutations {
                var document = valid
                mutate(&document, Date(timeIntervalSince1970: timestamp))
                XCTAssertThrowsError(try LibraryValidation.validate(document, now: time))
            }
        }
    }
}

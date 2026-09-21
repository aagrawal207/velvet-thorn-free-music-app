import XCTest
@testable import GanaBajana

final class LibraryPersistenceTests: XCTestCase {
    @MainActor
    func testAllStateReloadsTogetherWithoutLosingHistoryToAQueueSnapshot() async throws {
        try withLibraryTestDirectory { directory in
            let store = LibraryStore(directory: directory)
            let first = libraryTestTrack()
            let second = libraryTestTrack("song-b")
            let session = UUID()
            let startedAt = Date().addingTimeInterval(-3600)
            store.toggleFavorite(first)
            let playlist = store.createPlaylist(name: "  Late night \n")
            store.add(second, to: playlist)
            store.add(first, to: playlist)
            store.moveTracks(in: playlist, from: IndexSet(integer: 1), to: 0)
            store.recordListening(track: first, sessionID: session, startedAt: startedAt, seconds: 30)
            store.recordListening(track: first, sessionID: session, startedAt: startedAt, seconds: 22.5)
            store.recordRecent(track: first, position: 17.25)
            store.setLyricsOffset(-0.125, for: first.id)
            store.setLyricsOffset(2.875, for: second.id)
            store.preferences.languages = [.hindi]
            store.preferences.appearance = .light
            store.preferences.hasCompletedWelcome = true
            store.preferences.saveListeningHistory = false
            store.preferences.allowRemoteFallback = true
            store.preferences.useEncryptedDNS = false
            store.updatePlayback(PlaybackSnapshot(
                queue: [second, first, second], currentIndex: 1, position: 17.25,
                shuffleEnabled: true, repeatMode: .one, originalQueue: [first, second, second]
            ))
            XCTAssertNil(store.errorMessage)

            let restored = LibraryStore(directory: directory)
            XCTAssertNil(restored.errorMessage)
            XCTAssertEqual(restored.favorites, [first])
            XCTAssertEqual(restored.playlists.first?.id, playlist)
            XCTAssertEqual(restored.playlists.first?.name, "Late night")
            XCTAssertEqual(restored.playlists.first?.tracks, [first, second])
            XCTAssertEqual(restored.events.count, 1)
            XCTAssertEqual(restored.events.first?.id, session)
            XCTAssertEqual(restored.events.first?.listenedSeconds, 52.5)
            XCTAssertEqual(restored.events.first!.startedAt.timeIntervalSince1970, startedAt.timeIntervalSince1970, accuracy: 0.001)
            XCTAssertEqual(restored.recentlyPlayed.first?.position, 17.25)
            XCTAssertEqual(restored.preferences, store.preferences)
            XCTAssertEqual(restored.lyricsOffset(for: first.id), -0.125)
            XCTAssertEqual(restored.lyricsOffset(for: second.id), 2.875)
            XCTAssertEqual(restored.playback.queue, [second, first, second])
            XCTAssertEqual(restored.playback.originalQueue, [first, second, second])
            XCTAssertEqual(restored.playback.currentIndex, 1)
            XCTAssertEqual(restored.playback.position, 17.25)
            XCTAssertTrue(restored.playback.shuffleEnabled)
            XCTAssertEqual(restored.playback.repeatMode, .one)
        }
    }

    @MainActor
    func testNewLibraryIsEmptyAndCreatesOnlyItsSuppliedDirectoryOnFirstSave() async throws {
        try withLibraryTestDirectory { directory in
            let nested = directory.appendingPathComponent("isolated/nested", isDirectory: true)
            let store = LibraryStore(directory: nested)
            XCTAssertTrue(store.events.isEmpty)
            XCTAssertTrue(store.favorites.isEmpty)
            XCTAssertTrue(store.playlists.isEmpty)
            XCTAssertTrue(store.recentlyPlayed.isEmpty)
            XCTAssertNil(store.errorMessage)
            XCTAssertFalse(FileManager.default.fileExists(atPath: nested.path))
            store.toggleFavorite(libraryTestTrack())
            XCTAssertTrue(FileManager.default.fileExists(atPath: nested.appendingPathComponent(LibraryPersistence.fileName).path))
            XCTAssertEqual(LibraryStore(directory: nested).favorites.count, 1)
        }
    }

    @MainActor
    func testCorruptStoreRemainsByteForByteUnchangedAndRefusesMutations() async throws {
        try withLibraryTestDirectory { directory in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(LibraryPersistence.fileName)
            let corrupt = Data("{\"version\":1,\"favorites\":[this is not JSON".utf8)
            try corrupt.write(to: url, options: .atomic)
            let store = LibraryStore(directory: directory)
            let originalError = try XCTUnwrap(store.errorMessage)
            store.toggleFavorite(libraryTestTrack())
            store.createPlaylist(name: "Keep the original")
            store.preferences.appearance = .light
            store.clearHistory()
            store.updatePlayback(PlaybackSnapshot())
            XCTAssertEqual(try Data(contentsOf: url), corrupt)
            XCTAssertEqual(store.errorMessage, originalError)
            XCTAssertTrue(store.favorites.isEmpty)
            XCTAssertTrue(store.playlists.isEmpty)
            XCTAssertEqual(store.preferences.appearance, .dark)
        }
    }

    @MainActor
    func testFutureVersionIsDetectedBeforeDecodingItsUnknownPayload() async throws {
        try withLibraryTestDirectory { directory in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(LibraryPersistence.fileName)
            let future = Data("{\"version\":9999,\"futurePayload\":{\"keep\":\"everything\"}}".utf8)
            try future.write(to: url, options: .atomic)
            let store = LibraryStore(directory: directory)
            XCTAssertTrue(try XCTUnwrap(store.errorMessage).contains("newer version"))
            store.clearHistory()
            store.preferences.saveListeningHistory = false
            store.setLyricsOffset(1, for: "song")
            XCTAssertEqual(try Data(contentsOf: url), future)
            XCTAssertEqual(store.lyricsOffset(for: "song"), 0)
            XCTAssertTrue(store.preferences.saveListeningHistory)
        }
    }

    @MainActor
    func testStructurallyInvalidStoresArePreservedInsteadOfPartiallyLoaded() async throws {
        let invalidations: [(inout [String: Any]) -> Void] = [
            { $0.removeValue(forKey: "preferences") },
            { $0["version"] = 0 },
            { value in value["favorites"] = (value["favorites"] as! [Any]) + (value["favorites"] as! [Any]) },
            { value in value["events"] = (value["events"] as! [Any]) + (value["events"] as! [Any]) },
            { value in
                var events = value["events"] as! [[String: Any]]
                events[0]["listenedSeconds"] = -10
                value["events"] = events
            },
            { value in
                var events = value["events"] as! [[String: Any]]
                events[0]["startedAt"] = 1e300
                value["events"] = events
            },
            { value in
                var playback = value["playback"] as! [String: Any]
                playback["currentIndex"] = 100
                value["playback"] = playback
            },
            { $0["lyricsOffsets"] = ["song-a": "not a number"] }
        ]
        for invalidate in invalidations {
            try withLibraryTestDirectory { directory in
                let store = LibraryStore(directory: directory)
                let track = libraryTestTrack()
                store.toggleFavorite(track)
                store.recordListening(track: track, sessionID: UUID(), startedAt: Date().addingTimeInterval(-60), seconds: 30)
                let url = directory.appendingPathComponent(LibraryPersistence.fileName)
                var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
                invalidate(&json)
                let invalid = try JSONSerialization.data(withJSONObject: json, options: .sortedKeys)
                try invalid.write(to: url, options: .atomic)
                let restored = LibraryStore(directory: directory)
                XCTAssertNotNil(restored.errorMessage)
                XCTAssertTrue(restored.favorites.isEmpty)
                restored.clearHistory()
                XCTAssertEqual(try Data(contentsOf: url), invalid)
            }
        }
    }

    @MainActor
    func testStaleWriterCannotOverwriteANewerLibrarySnapshot() async throws {
        try withLibraryTestDirectory { directory in
            let first = LibraryStore(directory: directory)
            let stale = LibraryStore(directory: directory)
            first.toggleFavorite(libraryTestTrack())
            let url = directory.appendingPathComponent(LibraryPersistence.fileName)
            let original = try Data(contentsOf: url)
            stale.updatePlayback(PlaybackSnapshot(queue: [libraryTestTrack("other")]))
            XCTAssertNotNil(stale.errorMessage)
            XCTAssertTrue(stale.playback.queue.isEmpty)
            XCTAssertEqual(try Data(contentsOf: url), original)
            XCTAssertEqual(LibraryStore(directory: directory).favorites, first.favorites)
        }
    }

    @MainActor
    func testFailedWriteDoesNotPublishUnpersistedStateAndCanBeRetried() async throws {
        try withLibraryTestDirectory { directory in
            let store = LibraryStore(directory: directory)
            let url = directory.appendingPathComponent(LibraryPersistence.fileName)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            store.toggleFavorite(libraryTestTrack())
            XCTAssertNotNil(store.errorMessage)
            XCTAssertTrue(store.favorites.isEmpty)
            try FileManager.default.removeItem(at: url)
            store.toggleFavorite(libraryTestTrack())
            XCTAssertNil(store.errorMessage)
            XCTAssertEqual(LibraryStore(directory: directory).favorites.count, 1)
        }
    }

    @MainActor
    func testUnsafeQueueSnapshotsAreRejectedWithoutTruncatingPositionsToCatalogDuration() async throws {
        try withLibraryTestDirectory { directory in
            let store = LibraryStore(directory: directory)
            let track = libraryTestTrack(duration: 100)
            store.updatePlayback(PlaybackSnapshot(queue: [track], position: 120))
            store.recordRecent(track: track, position: 120)
            XCTAssertEqual(store.playback.position, 120)
            XCTAssertEqual(store.recentlyPlayed.first?.position, 120)
            for invalid in [
                PlaybackSnapshot(queue: [track], currentIndex: -1),
                PlaybackSnapshot(queue: [track], currentIndex: 1),
                PlaybackSnapshot(queue: [track], position: .nan),
                PlaybackSnapshot(queue: [track], position: -.infinity),
                PlaybackSnapshot(queue: [track], position: 1e300),
                PlaybackSnapshot(queue: [], position: 1)
            ] {
                store.updatePlayback(invalid)
                XCTAssertNotNil(store.errorMessage)
                XCTAssertEqual(store.playback.queue, [track])
                XCTAssertEqual(store.playback.position, 120)
            }
            XCTAssertEqual(LibraryStore(directory: directory).playback.position, 120)
        }
    }

    @MainActor
    func testOriginalQueueValidatesTrackDetailsAndIDMultiplicityWithoutRequiringMatchingMetadata() async throws {
        try withLibraryTestDirectory { directory in
            let store = LibraryStore(directory: directory)
            let first = libraryTestTrack("a")
            let second = libraryTestTrack("b")
            var updatedFirst = first
            updatedFirst.title = "Updated catalog title"
            let snapshot = PlaybackSnapshot(
                queue: [second, first, second], currentIndex: 1, position: 12.5,
                shuffleEnabled: true, originalQueue: [updatedFirst, second, second]
            )
            store.updatePlayback(snapshot)
            XCTAssertNil(store.errorMessage)
            XCTAssertEqual(LibraryStore(directory: directory).playback.originalQueue, snapshot.originalQueue)
            let url = directory.appendingPathComponent(LibraryPersistence.fileName)
            let saved = try Data(contentsOf: url)
            var invalidTitle = second
            invalidTitle.title = "  "
            var invalidDuration = second
            invalidDuration.duration = .nan
            let invalidOriginals = [
                [first, first, second],
                [first, second],
                [first, second, second, second],
                [first, second, libraryTestTrack("c")],
                [first, invalidTitle, second],
                [first, invalidDuration, second],
                []
            ]
            for original in invalidOriginals {
                var invalid = snapshot
                invalid.originalQueue = original
                store.updatePlayback(invalid)
                XCTAssertNotNil(store.errorMessage)
                XCTAssertEqual(store.playback.queue, snapshot.queue)
                XCTAssertEqual(store.playback.originalQueue, snapshot.originalQueue)
                XCTAssertEqual(try Data(contentsOf: url), saved)
            }
            store.updatePlayback(PlaybackSnapshot(originalQueue: [first]))
            XCTAssertNotNil(store.errorMessage)
            XCTAssertEqual(try Data(contentsOf: url), saved)
        }
    }

    @MainActor
    func testInvalidStoredOriginalQueueBlocksLoadingAndPreservesTheFile() async throws {
        let track = libraryTestTrack()
        var invalidTrack = track
        invalidTrack.title = ""
        for original in [[track, track], [libraryTestTrack("different")], [invalidTrack]] {
            try withLibraryTestDirectory { directory in
                var document = LibraryDocument()
                document.favorites = [track]
                document.playback = PlaybackSnapshot(queue: [track], originalQueue: original)
                let data = try LibraryPersistence.encode(document)
                let url = directory.appendingPathComponent(LibraryPersistence.fileName)
                try LibraryPersistence.write(data, to: url, replacing: nil)
                let store = LibraryStore(directory: directory)
                let error = try XCTUnwrap(store.errorMessage)
                store.clearHistory()
                store.preferences.useEncryptedDNS = false
                XCTAssertEqual(store.errorMessage, error)
                XCTAssertEqual(try Data(contentsOf: url), data)
            }
        }
    }

    @MainActor
    func testEmptyAndLegacyNilOriginalQueuesRemainValid() async throws {
        let track = libraryTestTrack()
        for snapshot in [
            PlaybackSnapshot(),
            PlaybackSnapshot(originalQueue: []),
            PlaybackSnapshot(queue: [track, track], shuffleEnabled: true)
        ] {
            try withLibraryTestDirectory { directory in
                let store = LibraryStore(directory: directory)
                store.toggleFavorite(track)
                store.updatePlayback(snapshot)
                XCTAssertNil(store.errorMessage)
                let restored = LibraryStore(directory: directory)
                XCTAssertNil(restored.errorMessage)
                XCTAssertEqual(restored.playback.queue, snapshot.queue)
                XCTAssertEqual(restored.playback.originalQueue, snapshot.originalQueue)
                XCTAssertEqual(restored.playback.shuffleEnabled, snapshot.shuffleEnabled)
            }
        }
    }

    @MainActor
    func testLegacySnapshotAndDNSDefaultsPreserveExistingPreferencesAndHistory() async throws {
        for explicitNullQueue in [false, true] {
            try withLibraryTestDirectory { directory in
                let track = libraryTestTrack()
                var document = LibraryDocument()
                document.favorites = [track]
                document.events = [ListeningEvent(
                    id: UUID(), track: track, startedAt: Date().addingTimeInterval(-3600), listenedSeconds: 45
                )]
                document.preferences.languages = [.english]
                document.preferences.appearance = .light
                document.preferences.hasCompletedWelcome = true
                document.preferences.saveListeningHistory = false
                document.preferences.allowRemoteFallback = true
                document.playback = PlaybackSnapshot(queue: [track], position: 12.75, shuffleEnabled: true)
                var json = try XCTUnwrap(JSONSerialization.jsonObject(with: LibraryPersistence.encode(document)) as? [String: Any])
                var preferences = try XCTUnwrap(json["preferences"] as? [String: Any])
                preferences.removeValue(forKey: "useEncryptedDNS")
                json["preferences"] = preferences
                var playback = try XCTUnwrap(json["playback"] as? [String: Any])
                if explicitNullQueue { playback["originalQueue"] = NSNull() }
                else { playback.removeValue(forKey: "originalQueue") }
                json["playback"] = playback
                let legacy = try JSONSerialization.data(withJSONObject: json, options: .sortedKeys)
                let url = directory.appendingPathComponent(LibraryPersistence.fileName)
                try LibraryPersistence.write(legacy, to: url, replacing: nil)

                let store = LibraryStore(directory: directory)
                XCTAssertNil(store.errorMessage)
                XCTAssertTrue(store.preferences.useEncryptedDNS)
                XCTAssertEqual(store.preferences, document.preferences)
                XCTAssertNil(store.playback.originalQueue)
                XCTAssertEqual(store.playback.position, 12.75)
                XCTAssertTrue(store.playback.shuffleEnabled)
                XCTAssertEqual(store.events.first?.listenedSeconds, 45)
                store.updatePlayback(store.playback)
                let unchangedPreferences = store.preferences
                store.preferences = unchangedPreferences
                XCTAssertEqual(try Data(contentsOf: url), legacy)

                store.preferences.useEncryptedDNS = false
                let restored = LibraryStore(directory: directory)
                XCTAssertNil(restored.errorMessage)
                XCTAssertFalse(restored.preferences.useEncryptedDNS)
                XCTAssertFalse(restored.preferences.saveListeningHistory)
                XCTAssertEqual(restored.preferences.appearance, .light)
                XCTAssertEqual(restored.favorites, [track])
                XCTAssertEqual(restored.events.first?.listenedSeconds, 45)
                XCTAssertNil(restored.playback.originalQueue)
            }
        }
    }

    @MainActor
    func testMalformedEncryptedDNSPreferenceDoesNotSilentlyDefault() async throws {
        try withLibraryTestDirectory { directory in
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: LibraryPersistence.encode(LibraryDocument())) as? [String: Any])
            var preferences = try XCTUnwrap(json["preferences"] as? [String: Any])
            preferences["useEncryptedDNS"] = "true"
            json["preferences"] = preferences
            let data = try JSONSerialization.data(withJSONObject: json)
            let url = directory.appendingPathComponent(LibraryPersistence.fileName)
            try LibraryPersistence.write(data, to: url, replacing: nil)
            let store = LibraryStore(directory: directory)
            XCTAssertNotNil(store.errorMessage)
            store.toggleFavorite(libraryTestTrack())
            XCTAssertEqual(try Data(contentsOf: url), data)
        }
    }

    @MainActor
    func testUnchangedSnapshotsAndPreferencesDoNotClearAnExistingError() async throws {
        try withLibraryTestDirectory { directory in
            let store = LibraryStore(directory: directory)
            let track = libraryTestTrack()
            let valid = PlaybackSnapshot(queue: [track], originalQueue: [track])
            store.updatePlayback(valid)
            let url = directory.appendingPathComponent(LibraryPersistence.fileName)
            let saved = try Data(contentsOf: url)
            store.updatePlayback(PlaybackSnapshot(queue: [track], originalQueue: []))
            let error = try XCTUnwrap(store.errorMessage)
            store.updatePlayback(valid)
            let preferences = store.preferences
            store.preferences = preferences
            XCTAssertEqual(store.errorMessage, error)
            XCTAssertEqual(try Data(contentsOf: url), saved)
            store.updatePlayback(PlaybackSnapshot(queue: [track], position: 1, originalQueue: [track]))
            XCTAssertNil(store.errorMessage)
            XCTAssertEqual(store.playback.position, 1)
        }
    }
}

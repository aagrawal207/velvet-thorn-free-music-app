import Foundation
import XCTest
@testable import GanaBajana

@MainActor
final class LibrarySearchSelectionTests: XCTestCase {
    func testAllDestinationTypesRoundTripWithExistingMetadataAndDisplayProperties() throws {
        try withLibraryTestDirectory { directory in
            let artwork = URL(string: "https://i.ytimg.com/vi/Recording/hqdefault.jpg")!
            let track = Track(id: "Recording", title: "A song", credits: [ArtistCredit(name: "Singer", id: "UCArtist")],
                              albumTitle: "An album", albumID: "MPREAlbum", duration: 231.25,
                              artworkURL: artwork, language: .hindi, isExplicit: true, isAudioRecording: true, playCount: 123)
            let selections: [SearchSelection] = [
                .track(track),
                .collection(MusicCollection(id: "UCArtist", title: "Singer", artworkURL: artwork, kind: .artist)),
                .collection(MusicCollection(id: "MPREAlbum", title: "An album", subtitle: "Singer", artworkURL: artwork, kind: .album)),
                .collection(MusicCollection(id: "VLPlaylist", title: "A playlist", subtitle: "Curator", kind: .playlist)),
                .collection(MusicCollection(id: "Mix", title: "A mix", kind: .mix))
            ]
            XCTAssertEqual(selections.map(\.typeTitle), ["Song", "Artist", "Album", "Playlist", "Mix"])
            XCTAssertEqual(selections.map(\.title), ["A song", "Singer", "An album", "A playlist", "A mix"])
            XCTAssertEqual(selections.map(\.subtitle), ["Singer", "", "Singer", "Curator", ""])
            XCTAssertEqual(selections.first?.artworkURL, artwork)
            XCTAssertNil(selections.last?.artworkURL)
            XCTAssertEqual(SearchSelectionSource.result.rawValue, "result")
            XCTAssertEqual(SearchSelectionSource.recent.rawValue, "recent")
            XCTAssertEqual(SearchSelectionSource.resultMenu.rawValue, "resultMenu")

            let library = LibraryStore(directory: directory)
            for selection in selections { XCTAssertTrue(library.recordSearchSelection(selection)) }
            let reopened = LibraryStore(directory: directory)
            XCTAssertNil(reopened.errorMessage)
            XCTAssertEqual(reopened.recentSearchSelections, Array(selections.reversed()))
            XCTAssertTrue(reopened.recentSearches.isEmpty)
            for selection in selections {
                XCTAssertEqual(try LibrarySyncCodec.decode(SearchSelection.self, from: LibrarySyncCodec.encode(selection)), selection)
            }
        }
    }

    func testIdentityUsesCaseSensitiveProviderIDsAndCollectionKindsRatherThanTitles() throws {
        try withLibraryTestDirectory { directory in
            let library = LibraryStore(directory: directory)
            let selections: [SearchSelection] = [
                .track(Track(id: "SameID", title: "Same title")),
                .track(Track(id: "sameid", title: "Same title")),
                .collection(MusicCollection(id: "SameID", title: "Same title", kind: .album)),
                .collection(MusicCollection(id: "SameID", title: "Same title", kind: .artist)),
                .collection(MusicCollection(id: "SameID", title: "Same title", kind: .playlist)),
                .collection(MusicCollection(id: "sameid", title: "Same title", kind: .album))
            ]
            XCTAssertEqual(selections.map(\.id), ["track:SameID", "track:sameid", "collection:album:SameID",
                                                  "collection:artist:SameID", "collection:playlist:SameID", "collection:album:sameid"])
            for selection in selections { XCTAssertTrue(library.recordSearchSelection(selection)) }
            XCTAssertEqual(library.recentSearchSelections.count, 6)

            let renamed = SearchSelection.collection(MusicCollection(id: "SameID", title: "Corrected title", kind: .album))
            XCTAssertTrue(library.recordSearchSelection(renamed))
            XCTAssertEqual(library.recentSearchSelections.count, 6)
            XCTAssertEqual(library.recentSearchSelections.first, renamed)
            XCTAssertTrue(library.removeRecentSearchSelection(id: "collection:album:SameID"))
            XCTAssertTrue(library.recentSearchSelections.contains(selections[5]))
            XCTAssertTrue(library.recentSearchSelections.contains(selections[0]))
            XCTAssertEqual(LibraryStore(directory: directory).recentSearchSelections, library.recentSearchSelections)
        }
    }

    func testCollectionSnapshotsAreStrippedWithoutChangingTheCallersCollection() throws {
        try withLibraryTestDirectory { directory in
            let library = LibraryStore(directory: directory)
            for kind in [CollectionKind.artist, .album, .playlist, .mix] {
                let collection = MusicCollection(id: kind.rawValue, title: "Destination", kind: kind,
                                                 tracks: [libraryTestTrack("stale-embedded-recording")])
                XCTAssertTrue(library.recordSearchSelection(.collection(collection)))
                XCTAssertEqual(collection.tracks.count, 1)
                guard case .collection(let saved)? = library.recentSearchSelections.first else {
                    return XCTFail("The persisted destination must still be a collection")
                }
                XCTAssertTrue(saved.tracks.isEmpty)
                XCTAssertEqual(saved.id, collection.id)
                XCTAssertEqual(saved.kind, kind)
            }
            let bytes = try Data(contentsOf: directory.appendingPathComponent(LibraryPersistence.fileName))
            XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("stale-embedded-recording"))
            let reopened = LibraryStore(directory: directory)
            XCTAssertNil(reopened.errorMessage)
            XCTAssertEqual(reopened.recentSearchSelections, library.recentSearchSelections)
        }
    }

    func testTwentyDestinationBoundAndRepeatedOpeningStampOnlyTheSelectedRevision() throws {
        try withLibraryTestDirectory { directory in
            let now = LibrarySyncTestData.now
            let library = LibraryStore(directory: directory, now: { now }, writerID: LibrarySyncTestData.a)
            for index in 0..<25 { XCTAssertTrue(library.recordSearchSelection(.track(libraryTestTrack("song-\(index)")))) }
            XCTAssertEqual(library.recentSearchSelections.map(\.id), (5..<25).reversed().map { "track:song-\($0)" })
            let selected = SearchSelection.track(libraryTestTrack("song-10"))
            XCTAssertTrue(library.recordSearchSelection(selected))
            XCTAssertEqual(library.recentSearchSelections.first, selected)
            XCTAssertEqual(library.recentSearchSelections.count, 20)
            XCTAssertEqual(library.recentSearchSelections.last?.id, "track:song-5")

            let before = try library.cloudReplica(replicaID: LibrarySyncTestData.a).state
            let order = library.recentSearchSelections
            XCTAssertTrue(library.recordSearchSelection(selected), "A new opening matters even when the destination is already first")
            let after = try library.cloudReplica(replicaID: LibrarySyncTestData.a).state
            let key = LibrarySyncKey(.searchSelection, selected.id)
            XCTAssertGreaterThan(try XCTUnwrap(after.registers[key]?.revision), try XCTUnwrap(before.registers[key]?.revision))
            XCTAssertEqual(after.registers.filter { $0.key != key }, before.registers.filter { $0.key != key })
            XCTAssertEqual(library.recentSearchSelections, order)
            XCTAssertEqual(LibraryStore(directory: directory, now: { now }).recentSearchSelections, order)
        }
    }

    func testEmptyReadAndMissingRemovalDoNotWriteButAnEmptyClearPersistsTheReset() throws {
        try withLibraryTestDirectory { directory in
            let library = LibraryStore(directory: directory)
            XCTAssertTrue(library.recentSearchSelections.isEmpty)
            XCTAssertNil(library.searchHistoryResetRevision)
            XCTAssertTrue(library.removeRecentSearchSelection(id: "track:missing"))
            XCTAssertEqual(library.storageBytes, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
            XCTAssertTrue(library.clearRecentSearches())
            let firstReset = try XCTUnwrap(library.searchHistoryResetRevision)
            XCTAssertTrue(library.clearRecentSearches())
            XCTAssertGreaterThan(try XCTUnwrap(library.searchHistoryResetRevision), firstReset)
            XCTAssertEqual(LibraryStore(directory: directory).searchHistoryResetRevision, library.searchHistoryResetRevision)
        }
    }

    func testSearchClearAndListeningHistoryPreferencesHaveIndependentBoundaries() throws {
        try withLibraryTestDirectory { directory in
            let now = LibrarySyncTestData.now
            let library = LibraryStore(directory: directory, now: { now })
            let song = libraryTestTrack()
            library.toggleFavorite(song)
            library.recordListening(track: song, sessionID: UUID(), startedAt: now.addingTimeInterval(-60), seconds: 30)
            library.recordRecent(track: song, position: 12)
            library.updatePlayback(PlaybackSnapshot(queue: [song], position: 12))
            library.preferences.saveListeningHistory = false
            library.recordSearch("Legacy query")
            XCTAssertTrue(library.recordSearchSelection(.track(song)))
            var listeningClears = 0
            library.onHistoryCleared = { listeningClears += 1 }

            XCTAssertTrue(library.clearRecentSearches())
            XCTAssertTrue(library.recentSearchSelections.isEmpty)
            XCTAssertTrue(library.recentSearches.isEmpty)
            XCTAssertEqual(library.events.first?.listenedSeconds, 30)
            XCTAssertEqual(library.recentlyPlayed.first?.position, 12)
            XCTAssertEqual(library.favorites, [song])
            XCTAssertEqual(library.playback.position, 12)
            XCTAssertEqual(listeningClears, 0)
            let reset = library.searchHistoryResetRevision
            XCTAssertTrue(library.recordSearchSelection(.track(song)))
            library.recordSearch("After clear")
            library.clearHistory()
            XCTAssertEqual(listeningClears, 1)
            XCTAssertEqual(library.searchHistoryResetRevision, reset)
            XCTAssertEqual(library.recentSearchSelections, [.track(song)])
            XCTAssertEqual(library.recentSearches, ["After clear"])
        }
    }

    func testInvalidSelectionMetadataRejectsTheWholeWrite() throws {
        try withLibraryTestDirectory { directory in
            let library = LibraryStore(directory: directory)
            let original = SearchSelection.track(libraryTestTrack("keep"))
            XCTAssertTrue(library.recordSearchSelection(original))
            let url = directory.appendingPathComponent(LibraryPersistence.fileName)
            let bytes = try Data(contentsOf: url)
            var invalid: [SearchSelection] = [
                .track(Track(id: "", title: "Missing ID")),
                .track(Track(id: " padded ", title: "Padded ID")),
                .track(Track(id: "bad\nID", title: "Control character")),
                .track(Track(id: "long" + String(repeating: "a", count: 16_384), title: "Long ID")),
                .track(Track(id: "valid", title: " \n")),
                .track(libraryTestTrack("invalid-duration", duration: 0)),
                .track(libraryTestTrack("invalid-duration", duration: .infinity)),
                .collection(MusicCollection(id: "", title: "Missing ID", kind: .album)),
                .collection(MusicCollection(id: "album", title: " ", kind: .album))
            ]
            for artwork in ["file:///private/audio.m4a", "http://example.com/art.jpg", "https://user:secret@example.com/art.jpg",
                            "https://r1.googlevideo.com/videoplayback?sig=secret", "https://example.com/videoplayback?sig=secret"] {
                invalid.append(.track(Track(id: "bad-art", title: "Song", artworkURL: URL(string: artwork))))
                invalid.append(.collection(MusicCollection(id: "bad-art", title: "Album", artworkURL: URL(string: artwork), kind: .album)))
            }
            for selection in invalid {
                XCTAssertFalse(library.recordSearchSelection(selection))
                XCTAssertNotNil(library.errorMessage)
                XCTAssertEqual(library.recentSearchSelections, [original])
                XCTAssertEqual(try Data(contentsOf: url), bytes)
            }
            for id in ["", "track:", "collection:album:", "collection:unknown:ID", "song:ID"] {
                XCTAssertFalse(library.removeRecentSearchSelection(id: id))
                XCTAssertEqual(try Data(contentsOf: url), bytes)
            }
        }
    }

    func testFailedWritesDoNotPublishSelectionsOrClearEitherHistoryAndCanRetry() throws {
        try withLibraryTestDirectory { directory in
            let library = LibraryStore(directory: directory)
            let kept = SearchSelection.track(libraryTestTrack("keep"))
            library.recordSearch("Keep legacy")
            XCTAssertTrue(library.recordSearchSelection(kept))
            let reset = library.searchHistoryResetRevision
            let url = directory.appendingPathComponent(LibraryPersistence.fileName)
            let backup = directory.appendingPathComponent("saved.json")
            let bytes = try Data(contentsOf: url)
            try FileManager.default.moveItem(at: url, to: backup)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            XCTAssertFalse(library.recordSearchSelection(.track(libraryTestTrack("unsaved"))))
            XCTAssertFalse(library.removeRecentSearchSelection(id: kept.id))
            XCTAssertFalse(library.clearRecentSearches())
            XCTAssertEqual(library.recentSearchSelections, [kept])
            XCTAssertEqual(library.recentSearches, ["Keep legacy"])
            XCTAssertEqual(library.searchHistoryResetRevision, reset)
            XCTAssertEqual(library.storageBytes, Int64(bytes.count))
            XCTAssertEqual(try Data(contentsOf: backup), bytes)
            try FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: backup, to: url)
            XCTAssertTrue(library.clearRecentSearches())
            XCTAssertNil(library.errorMessage)
            XCTAssertTrue(LibraryStore(directory: directory).recentSearchSelections.isEmpty)
        }
    }

    func testExternalWriterBlocksInsertRemovalClearAndMissingRemovalAcknowledgement() throws {
        for operation in 0..<4 {
            try withLibraryTestDirectory { directory in
                let writer = LibraryStore(directory: directory)
                let kept = SearchSelection.track(libraryTestTrack("keep"))
                XCTAssertTrue(writer.recordSearchSelection(kept))
                let stale = LibraryStore(directory: directory)
                XCTAssertTrue(writer.recordSearchSelection(.track(libraryTestTrack("newer"))))
                let url = directory.appendingPathComponent(LibraryPersistence.fileName)
                let bytes = try Data(contentsOf: url)
                let result: Bool
                switch operation {
                case 0: result = stale.recordSearchSelection(.track(libraryTestTrack("stale")))
                case 1: result = stale.removeRecentSearchSelection(id: kept.id)
                case 2: result = stale.clearRecentSearches()
                default: result = stale.removeRecentSearchSelection(id: "track:missing")
                }
                XCTAssertFalse(result)
                XCTAssertTrue(stale.requiresReload)
                XCTAssertEqual(stale.recentSearchSelections, [kept])
                XCTAssertEqual(try Data(contentsOf: url), bytes)
                XCTAssertEqual(stale.reloadFromDisk(), .reloaded)
                XCTAssertEqual(stale.recentSearchSelections, writer.recentSearchSelections)
            }
        }
    }

    func testV1AndV2ReadersPreserveQueriesPreferencesAndJournalRevisionsUntilARealEdit() throws {
        for (version, journal) in [(1, false), (2, false), (2, true)] {
            try withLibraryTestDirectory { directory in
                let now = LibrarySyncTestData.now
                let song = libraryTestTrack("legacy")
                var legacy = LibraryDocument()
                legacy.version = version
                legacy.favorites = [song]
                legacy.recentSearches = ["Beyoncé", "Earlier query"]
                legacy.preferences.languages = [.english]
                legacy.preferences.languageNudges[.bengali] = .more
                legacy.preferences.languageNudges[.hindi] = .less
                legacy.preferences.appearance = .light
                legacy.preferences.saveListeningHistory = false
                legacy.playback = PlaybackSnapshot(queue: [song], position: 27)
                legacy.recordingLanguageOverrides = [song.id: "future-language-code"]
                if journal {
                    var state = try LibrarySyncJournal.seed(legacy, now: now, writer: LibrarySyncTestData.a)
                    state.searchReset = try state.nextRevision(now: now, writer: LibrarySyncTestData.a)
                    for query in legacy.recentSearches.reversed() {
                        let revision = try state.nextRevision(now: now, writer: LibrarySyncTestData.a)
                        state.put(LibrarySyncKey(.search, SearchHistory.key(query)), value: try LibrarySyncCodec.encode(query), revision: revision)
                    }
                    state.version = 1
                    legacy.syncState = state
                }
                var json = try XCTUnwrap(JSONSerialization.jsonObject(with: LibrarySyncTestData.legacyDocumentBytes(legacy)) as? [String: Any])
                json.removeValue(forKey: "recentSearchSelections")
                let original = try JSONSerialization.data(withJSONObject: json, options: .sortedKeys)
                let url = directory.appendingPathComponent(LibraryPersistence.fileName)
                try LibraryPersistence.write(original, to: url, replacing: nil)

                let library = LibraryStore(directory: directory, now: { now }, writerID: LibrarySyncTestData.a)
                XCTAssertNil(library.errorMessage)
                XCTAssertTrue(library.recentSearchSelections.isEmpty)
                XCTAssertEqual(library.preferences, legacy.preferences)
                XCTAssertEqual(library.recentSearches, legacy.recentSearches)
                XCTAssertEqual(library.searchHistoryResetRevision, legacy.syncState?.searchReset)
                XCTAssertEqual(library.recordingLanguageOverrides, legacy.recordingLanguageOverrides)
                let decoded = try LibraryPersistence.decode(original, now: now)
                XCTAssertEqual(decoded.version, LibraryPersistence.currentVersion)
                XCTAssertEqual(decoded.syncState?.registers, legacy.syncState?.registers)
                XCTAssertEqual(decoded.syncState?.clock, legacy.syncState?.clock)
                XCTAssertEqual(decoded.syncState?.version, journal ? LibrarySyncState.currentVersion : nil)
                let unchangedPreferences = library.preferences
                library.preferences = unchangedPreferences
                library.updatePlayback(library.playback)
                XCTAssertTrue(library.removeRecentSearchSelection(id: "track:absent"))
                XCTAssertEqual(try Data(contentsOf: url), original, "Reading and no-op actions cannot seed or rewrite a legacy library")

                let selected = SearchSelection.collection(MusicCollection(id: "Album", title: "Opened album", kind: .album))
                XCTAssertTrue(library.recordSearchSelection(selected))
                let savedBytes = try Data(contentsOf: url)
                let header = try JSONDecoder().decode(LibraryPersistence.VersionHeader.self, from: savedBytes)
                XCTAssertEqual(header.version, LibraryPersistence.currentVersion)
                let saved = try LibraryPersistence.decode(savedBytes, now: now)
                XCTAssertEqual(saved.syncState?.version, LibrarySyncState.currentVersion)
                XCTAssertEqual(saved.recentSearchSelections, [selected])
                XCTAssertEqual(saved.preferences, legacy.preferences)
                XCTAssertEqual(saved.recentSearches, legacy.recentSearches)
                XCTAssertEqual(saved.playback.queue, [song])
                XCTAssertEqual(saved.playback.position, 27)
                XCTAssertEqual(saved.recordingLanguageOverrides, legacy.recordingLanguageOverrides)
                if let old = legacy.syncState {
                    XCTAssertEqual(saved.syncState?.registers.filter { $0.key.collection != .searchSelection }, old.registers)
                    XCTAssertEqual(saved.syncState?.searchReset, old.searchReset)
                }
            }
        }
    }

    func testUnjournalledTypedLibraryDoesNotSeedOnReadAndPreservesOrderOnItsFirstRealEdit() throws {
        try withLibraryTestDirectory { directory in
            let now = LibrarySyncTestData.now
            var document = LibraryDocument()
            document.recentSearchSelections = [
                .collection(MusicCollection(id: "z", title: "Newest", kind: .album)),
                .track(libraryTestTrack("a"))
            ]
            document.recentSearches = ["Legacy query"]
            let bytes = try LibraryPersistence.encode(document)
            let url = directory.appendingPathComponent(LibraryPersistence.fileName)
            try LibraryPersistence.write(bytes, to: url, replacing: nil)
            let library = LibraryStore(directory: directory, now: { now })
            XCTAssertNil(library.errorMessage)
            XCTAssertEqual(library.recentSearchSelections, document.recentSearchSelections)
            XCTAssertNil(try LibraryPersistence.decode(Data(contentsOf: url), now: now).syncState)
            XCTAssertEqual(try Data(contentsOf: url), bytes)
            library.preferences.appearance = .light
            XCTAssertNil(library.errorMessage)
            let saved = try LibraryPersistence.decode(Data(contentsOf: url), now: now)
            XCTAssertEqual(saved.recentSearchSelections, document.recentSearchSelections)
            XCTAssertEqual(saved.recentSearches, document.recentSearches)
            XCTAssertEqual(saved.syncState?.registers.filter { $0.key.collection == .searchSelection }.count, 2)
        }
    }

    func testMalformedTypedPayloadsAndFutureStoresArePreservedByteForByte() throws {
        var document = LibraryDocument()
        document.recentSearchSelections = [.track(libraryTestTrack("original"))]
        let valid = try XCTUnwrap(JSONSerialization.jsonObject(with: LibraryPersistence.encode(document)) as? [String: Any])
        var invalids: [Data] = [Data("{broken".utf8), Data("{\"version\":0}".utf8),
                               Data("{\"version\":\(LibraryPersistence.currentVersion + 1),\"future\":true}".utf8)]
        let malformedPayloads: [Any] = ["not an array", [1]]
        for payload in malformedPayloads {
            var json = valid
            json["recentSearchSelections"] = payload
            invalids.append(try JSONSerialization.data(withJSONObject: json, options: .sortedKeys))
        }
        for count in [2, 21] {
            var malformed = document
            malformed.recentSearchSelections = count == 2
                ? [.track(libraryTestTrack("duplicate")), .track(Track(id: "duplicate", title: "Another title"))]
                : (0..<count).map { .track(libraryTestTrack("song-\($0)")) }
            invalids.append(try LibraryPersistence.encode(malformed))
        }
        var embedded = document
        embedded.recentSearchSelections = [.collection(MusicCollection(id: "album", title: "Album", kind: .album, tracks: [libraryTestTrack()]))]
        invalids.append(try LibraryPersistence.encode(embedded))
        var wrongVersion = document
        wrongVersion.version = 2
        let typedLegacy = try LibrarySyncTestData.legacyDocumentBytes(wrongVersion)
        XCTAssertThrowsError(try LibraryPersistence.decode(typedLegacy, now: LibrarySyncTestData.now)) { error in
            guard let failure = error as? LibraryStorageError, case .invalidData(let detail) = failure else {
                return XCTFail("Expected the typed-selection version guard: \(error)")
            }
            XCTAssertEqual(detail, "search selection format version")
        }
        invalids.append(typedLegacy)
        var unknownKind = valid
        let unknownCollection: [String: Any] = ["id": "id", "title": "Title", "subtitle": "", "kind": "unknown", "tracks": [Any]()]
        unknownKind["recentSearchSelections"] = [["collection": ["_0": unknownCollection]]]
        invalids.append(try JSONSerialization.data(withJSONObject: unknownKind, options: .sortedKeys))
        var unknownMetadata = valid
        var rows = try XCTUnwrap(unknownMetadata["recentSearchSelections"] as? [[String: Any]])
        var trackCase = try XCTUnwrap(rows[0]["track"] as? [String: Any])
        var track = try XCTUnwrap(trackCase["_0"] as? [String: Any])
        track["audioURL"] = "https://r1.googlevideo.com/videoplayback?sig=do-not-persist"
        trackCase["_0"] = track
        rows[0]["track"] = trackCase
        unknownMetadata["recentSearchSelections"] = rows
        invalids.append(try JSONSerialization.data(withJSONObject: unknownMetadata, options: .sortedKeys))

        for bytes in invalids {
            try withLibraryTestDirectory { directory in
                let url = directory.appendingPathComponent(LibraryPersistence.fileName)
                try LibraryPersistence.write(bytes, to: url, replacing: nil)
                let library = LibraryStore(directory: directory)
                XCTAssertTrue(library.requiresReload)
                XCTAssertFalse(library.hasLoadedDocument)
                XCTAssertFalse(library.recordSearchSelection(.track(libraryTestTrack("replacement"))))
                XCTAssertFalse(library.clearRecentSearches())
                XCTAssertTrue(library.recentSearchSelections.isEmpty)
                XCTAssertEqual(try Data(contentsOf: url), bytes)
            }
        }
    }
}

import Foundation
import XCTest
@testable import GanaBajana

@MainActor
final class LibrarySearchHistoryTests: XCTestCase {
    func testEmptyQueriesDoNotCreateAStore() throws {
        try withLibraryTestDirectory { directory in
            let store = LibraryStore(directory: directory)
            for query in ["", " ", "\n\t "] { store.recordSearch(query) }
            store.removeRecentSearch("missing")
            store.clearRecentSearches()
            XCTAssertTrue(store.recentSearches.isEmpty)
            XCTAssertEqual(store.storageBytes, 0)
            XCTAssertNil(store.errorMessage)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        }
    }

    func testSearchesPersistNewestFirstWithTrimmedCaseAndDiacriticDeduplication() throws {
        try withLibraryTestDirectory { directory in
            let store = LibraryStore(directory: directory)
            store.recordSearch("  Beyoncé\n")
            store.recordSearch("Radiohead")
            store.recordSearch(" BEYONCE ")
            store.recordSearch("A. R. Rahman")
            store.recordSearch("  rádiohead  ")
            XCTAssertEqual(store.recentSearches, ["rádiohead", "A. R. Rahman", "BEYONCE"])

            let url = directory.appendingPathComponent(LibraryPersistence.fileName)
            let data = try Data(contentsOf: url)
            XCTAssertEqual(store.storageBytes, Int64(data.count))
            let restored = LibraryStore(directory: directory)
            XCTAssertNil(restored.errorMessage)
            XCTAssertEqual(restored.recentSearches, ["rádiohead", "A. R. Rahman", "BEYONCE"])
            XCTAssertEqual(restored.storageBytes, Int64(data.count))
            restored.recordSearch("rádiohead")
            XCTAssertEqual(try Data(contentsOf: url), data, "Repeating the unchanged newest query needs no write")
        }
    }

    func testHistoryIsBoundedAndRepeatingAnOlderQueryMovesItToTheFront() throws {
        try withLibraryTestDirectory { directory in
            let store = LibraryStore(directory: directory)
            for index in 0..<25 { store.recordSearch("Query \(index)") }
            XCTAssertEqual(store.recentSearches, (5..<25).reversed().map { "Query \($0)" })
            store.recordSearch("query 10")
            XCTAssertEqual(store.recentSearches.first, "query 10")
            XCTAssertEqual(store.recentSearches.count, 20)
            XCTAssertEqual(store.recentSearches.filter { SearchHistory.key($0) == "query 10" }.count, 1)
            XCTAssertEqual(store.recentSearches.last, "Query 5")
            XCTAssertEqual(LibraryStore(directory: directory).recentSearches, store.recentSearches)
        }
    }

    func testRemovingSearchesDoesNotClearListeningLikesMixesOrResumeState() throws {
        try withLibraryTestDirectory { directory in
            let store = LibraryStore(directory: directory)
            let song = libraryTestTrack()
            store.toggleFavorite(song)
            store.recordListening(track: song, sessionID: UUID(), startedAt: Date().addingTimeInterval(-60), seconds: 40)
            store.recordRecent(track: song, position: 25)
            store.updatePlayback(PlaybackSnapshot(queue: [song], position: 25))
            store.saveMix(GeneratedPlaylist(kind: .dailyMix, tracks: [song], generatedAt: Date(),
                                            periodKey: "fixture-day", seedArtists: song.artists))
            store.recordSearch("Beyoncé")
            store.recordSearch("Pixies")
            var clearedListening = false
            store.onHistoryCleared = { clearedListening = true }

            store.removeRecentSearch(" BEYONCE ")
            XCTAssertEqual(store.recentSearches, ["Pixies"])
            XCTAssertEqual(LibraryStore(directory: directory).recentSearches, ["Pixies"])
            store.clearRecentSearches()
            let restored = LibraryStore(directory: directory)
            XCTAssertTrue(restored.recentSearches.isEmpty)
            XCTAssertEqual(restored.favorites, [song])
            XCTAssertEqual(restored.events.first?.listenedSeconds, 40)
            XCTAssertEqual(restored.recentlyPlayed.first?.position, 25)
            XCTAssertEqual(restored.playback.queue, [song])
            XCTAssertEqual(restored.playback.position, 25)
            XCTAssertEqual(restored.mixes.first?.tracks, [song])
            XCTAssertFalse(clearedListening)
            let url = directory.appendingPathComponent(LibraryPersistence.fileName)
            XCTAssertEqual(store.storageBytes, Int64(try Data(contentsOf: url).count))
        }
    }

    func testSearchesAreIndependentOfListeningHistoryPreferencesAndDeletion() throws {
        try withLibraryTestDirectory { directory in
            let store = LibraryStore(directory: directory)
            store.preferences.saveListeningHistory = false
            store.recordSearch("Char Diwaari")
            store.clearHistory()
            XCTAssertEqual(store.recentSearches, ["Char Diwaari"])
            XCTAssertEqual(LibraryStore(directory: directory).recentSearches, ["Char Diwaari"])
            XCTAssertTrue(store.events.isEmpty)
            XCTAssertTrue(store.recentlyPlayed.isEmpty)
        }
    }

    func testOldVersionOneJSONWithoutSearchesOrWithNullMigratesOnTheNextCommit() throws {
        for explicitNull in [false, true] {
            try withLibraryTestDirectory { directory in
                let song = libraryTestTrack()
                var document = LibraryDocument()
                document.favorites = [song]
                document.playback = PlaybackSnapshot(queue: [song], position: 42)
                var json = try XCTUnwrap(JSONSerialization.jsonObject(with: LibraryPersistence.encode(document)) as? [String: Any])
                if explicitNull { json["recentSearches"] = NSNull() }
                else { json.removeValue(forKey: "recentSearches") }
                let original = try JSONSerialization.data(withJSONObject: json, options: .sortedKeys)
                let url = directory.appendingPathComponent(LibraryPersistence.fileName)
                try LibraryPersistence.write(original, to: url, replacing: nil)

                let store = LibraryStore(directory: directory)
                XCTAssertNil(store.errorMessage)
                XCTAssertTrue(store.recentSearches.isEmpty)
                XCTAssertEqual(store.storageBytes, Int64(original.count))
                XCTAssertEqual(try Data(contentsOf: url), original)
                store.recordSearch("Kanye West")
                let restored = LibraryStore(directory: directory)
                XCTAssertNil(restored.errorMessage)
                XCTAssertEqual(restored.recentSearches, ["Kanye West"])
                XCTAssertEqual(restored.favorites, [song])
                XCTAssertEqual(restored.playback.queue, [song])
                XCTAssertEqual(restored.playback.position, 42)
            }
        }
    }

    func testMalformedSearchesPreserveTheOriginalStoreAndBlockMutations() throws {
        let invalid: [Any] = [[""], ["  Pixies"], ["Beyoncé", "beyonce"], [1], "not an array",
                              (0..<21).map { "Query \($0)" }]
        for searches in invalid {
            try withLibraryTestDirectory { directory in
                var json = try XCTUnwrap(JSONSerialization.jsonObject(with: LibraryPersistence.encode(LibraryDocument())) as? [String: Any])
                json["recentSearches"] = searches
                let original = try JSONSerialization.data(withJSONObject: json, options: .sortedKeys)
                let url = directory.appendingPathComponent(LibraryPersistence.fileName)
                try LibraryPersistence.write(original, to: url, replacing: nil)
                let store = LibraryStore(directory: directory)
                let error = try XCTUnwrap(store.errorMessage)
                store.recordSearch("Please preserve this store")
                store.clearRecentSearches()
                XCTAssertTrue(store.recentSearches.isEmpty)
                XCTAssertEqual(store.errorMessage, error)
                XCTAssertEqual(store.storageBytes, Int64(original.count))
                XCTAssertEqual(try Data(contentsOf: url), original)
            }
        }
    }

    func testFailedAndStaleWritesNeverPublishUnsavedRecentSearches() throws {
        try withLibraryTestDirectory { directory in
            let store = LibraryStore(directory: directory)
            let url = directory.appendingPathComponent(LibraryPersistence.fileName)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            store.recordSearch("Radiohead")
            XCTAssertNotNil(store.errorMessage)
            XCTAssertTrue(store.recentSearches.isEmpty)
            XCTAssertEqual(store.storageBytes, 0)
            try FileManager.default.removeItem(at: url)
            store.recordSearch("Radiohead")
            XCTAssertNil(store.errorMessage)
            let saved = try Data(contentsOf: url)
            let stale = LibraryStore(directory: directory)
            store.recordSearch("Pixies")
            stale.clearRecentSearches()
            XCTAssertNotNil(stale.errorMessage)
            XCTAssertEqual(stale.recentSearches, ["Radiohead"])
            XCTAssertEqual(stale.storageBytes, Int64(saved.count))
            XCTAssertEqual(LibraryStore(directory: directory).recentSearches, ["Pixies", "Radiohead"])
        }
    }
}

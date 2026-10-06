import Foundation
import XCTest
@testable import GanaBajana

/// Super likes in the library file (format v5), `LibraryValidation`, the store's tier operations and the taste credit.
@MainActor
final class SuperLikeLibraryTests: XCTestCase {
    private static let now = LibrarySyncTestData.now

    // MARK: - Persistence

    func testVersionFiveWritesTheTierAndTheStoreReadsItBack() throws {
        XCTAssertEqual(LibraryPersistence.currentVersion, 5)
        let bolt = libraryTestTrack("bolt")
        let heart = libraryTestTrack("heart")
        var document = LibraryDocument()
        document.favorites = [bolt, heart]
        document.superLikedIDs = [bolt.id]
        let data = try LibraryPersistence.encode(document)
        let object = try Self.json(data)
        XCTAssertEqual(object["version"] as? Int, 5)
        XCTAssertEqual(object["superLikedIDs"] as? [String], [bolt.id])

        let decoded = try LibraryPersistence.decode(data, now: Self.now)
        XCTAssertEqual(decoded.version, 5)
        XCTAssertEqual(decoded.favorites, [bolt, heart])
        XCTAssertEqual(decoded.superLikedIDs, [bolt.id])

        try withLibraryTestDirectory { directory in
            try LibraryPersistence.write(data, to: directory.appendingPathComponent(LibraryPersistence.fileName), replacing: nil)
            let store = LibraryStore(directory: directory, now: { LibrarySyncTestData.now })
            XCTAssertNil(store.errorMessage)
            XCTAssertTrue(store.isSuperLiked(bolt))
            XCTAssertFalse(store.isSuperLiked(heart))
            XCTAssertTrue(store.isFavorite(bolt), "A super like is still a like")
            XCTAssertEqual(store.superLikedIDs, [bolt.id])
            XCTAssertEqual(store.superLikes, [bolt])
            XCTAssertEqual(store.favorites, [bolt, heart])
        }
    }

    func testVersionFourWithoutTheKeyReadsAsNoSuperLikesAndMigratesOnTheNextRealEdit() throws {
        let bolt = libraryTestTrack("bolt")
        let heart = libraryTestTrack("heart")
        var document = LibraryDocument()
        document.favorites = [bolt, heart]
        var object = try Self.json(LibraryPersistence.encode(document))
        object["version"] = 4
        object.removeValue(forKey: "superLikedIDs")
        let legacy = try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)

        let decoded = try LibraryPersistence.decode(legacy, now: Self.now)
        XCTAssertEqual(decoded.version, LibraryPersistence.currentVersion, "The in-memory document is already migrated")
        XCTAssertEqual(decoded.favorites, [bolt, heart])
        XCTAssertEqual(decoded.superLikedIDs, [])

        try withLibraryTestDirectory { directory in
            let url = directory.appendingPathComponent(LibraryPersistence.fileName)
            try LibraryPersistence.write(legacy, to: url, replacing: nil)
            let store = LibraryStore(directory: directory, now: { LibrarySyncTestData.now })
            XCTAssertNil(store.errorMessage)
            XCTAssertEqual(store.favorites, [bolt, heart])
            XCTAssertTrue(store.superLikedIDs.isEmpty)
            XCTAssertTrue(store.superLikes.isEmpty)
            XCTAssertEqual(store.durableCommitCount, 0)
            XCTAssertEqual(try Data(contentsOf: url), legacy, "Reading an older format is not an edit")

            store.setSuperLiked(heart, true)
            XCTAssertNil(store.errorMessage)
            let saved = try Data(contentsOf: url)
            XCTAssertEqual(try JSONDecoder().decode(LibraryPersistence.VersionHeader.self, from: saved).version, 5)
            XCTAssertEqual(try Self.json(saved)["superLikedIDs"] as? [String], [heart.id])
            let reopened = LibraryStore(directory: directory, now: { LibrarySyncTestData.now })
            XCTAssertNil(reopened.errorMessage)
            XCTAssertEqual(reopened.favorites, [heart, bolt])
            XCTAssertEqual(reopened.superLikes, [heart])
        }
    }

    func testAFileBelowVersionFiveThatCarriesTheKeyIsRejectedAndKept() throws {
        let bolt = libraryTestTrack("bolt")
        var document = LibraryDocument()
        document.favorites = [bolt]
        document.superLikedIDs = [bolt.id]
        let current = try Self.json(LibraryPersistence.encode(document))
        for version in 1...4 {
            for ids in [[bolt.id], []] {
                var object = current
                object["version"] = version
                object["superLikedIDs"] = ids
                let bytes = try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
                Self.assertInvalidData(try LibraryPersistence.decode(bytes, now: Self.now), "super like format version",
                                       "version \(version), ids \(ids)")
            }
        }

        var object = current
        object["version"] = 4
        let bytes = try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
        try withLibraryTestDirectory { directory in
            let url = directory.appendingPathComponent(LibraryPersistence.fileName)
            try LibraryPersistence.write(bytes, to: url, replacing: nil)
            let store = LibraryStore(directory: directory, now: { LibrarySyncTestData.now })
            let message = try XCTUnwrap(store.errorMessage)
            XCTAssertTrue(message.contains("super like format version"), message)
            XCTAssertTrue(store.requiresReload)
            XCTAssertTrue(store.favorites.isEmpty)
            XCTAssertTrue(store.superLikedIDs.isEmpty)
            store.setSuperLiked(bolt, true)
            store.toggleFavorite(libraryTestTrack("other"))
            XCTAssertEqual(store.errorMessage, message)
            XCTAssertEqual(try Data(contentsOf: url), bytes, "A rejected file is never replaced")
        }
    }

    func testVersionSixIsNewerBeforeItsPayloadIsDecoded() throws {
        let future = Data("{\"version\":6,\"futurePayload\":{\"keep\":\"everything\"}}".utf8)
        XCTAssertThrowsError(try LibraryPersistence.decode(future, now: Self.now)) { error in
            guard let storage = error as? LibraryStorageError, case .newerVersion = storage else {
                return XCTFail("Expected newerVersion, got \(error)")
            }
        }
        try withLibraryTestDirectory { directory in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(LibraryPersistence.fileName)
            try future.write(to: url, options: .atomic)
            let store = LibraryStore(directory: directory, now: { LibrarySyncTestData.now })
            XCTAssertTrue(try XCTUnwrap(store.errorMessage).contains("newer version"))
            store.setSuperLiked(libraryTestTrack(), true)
            XCTAssertFalse(store.isSuperLiked(libraryTestTrack()))
            XCTAssertEqual(try Data(contentsOf: url), future)
        }
    }

    // MARK: - Validation

    func testValidationRejectsStrayDuplicateAndMisorderedSuperLikesAndAcceptsAnOrderedSubset() throws {
        let favorites = [libraryTestTrack("a"), libraryTestTrack("b"), libraryTestTrack("c")]
        XCTAssertNoThrow(try LibraryValidation.validateSuperLikes([], favorites: favorites))
        XCTAssertNoThrow(try LibraryValidation.validateSuperLikes(["a", "c"], favorites: favorites))
        XCTAssertNoThrow(try LibraryValidation.validateSuperLikes(["b"], favorites: favorites))
        XCTAssertNoThrow(try LibraryValidation.validateSuperLikes(["a", "b", "c"], favorites: favorites))
        XCTAssertNoThrow(try LibraryValidation.validateSuperLikes([], favorites: []))
        Self.assertInvalidData(try LibraryValidation.validateSuperLikes(["ghost"], favorites: favorites), "super liked songs")
        Self.assertInvalidData(try LibraryValidation.validateSuperLikes(["a"], favorites: []), "super liked songs")
        Self.assertInvalidData(try LibraryValidation.validateSuperLikes(["a", "a"], favorites: favorites), "super liked songs")
        Self.assertInvalidData(try LibraryValidation.validateSuperLikes(["a", "ghost"], favorites: favorites), "super liked songs")
        Self.assertInvalidData(try LibraryValidation.validateSuperLikes(["c", "a"], favorites: favorites), "super liked song order")
        Self.assertInvalidData(try LibraryValidation.validateSuperLikes(["b", "a", "c"], favorites: favorites), "super liked song order")
    }

    func testDocumentValidationRejectsASuperLikeThatIsAlsoDislikedOrOutsideFavorites() throws {
        let a = libraryTestTrack("a")
        let b = libraryTestTrack("b")
        var document = LibraryDocument()
        document.favorites = [a, b]
        document.superLikedIDs = [b.id]
        XCTAssertNoThrow(try LibraryValidation.validate(document, now: Self.now))

        var conflicting = document
        conflicting.disliked = [DislikedSong(id: b.id, title: b.title, artists: b.artists, dislikedAt: Self.now)]
        Self.assertInvalidData(try LibraryValidation.validate(conflicting, now: Self.now), "conflicting song reactions")

        var strayDislike = document
        strayDislike.superLikedIDs = ["c"]
        strayDislike.disliked = [DislikedSong(id: "c", title: "Song c", artists: ["An Artist"], dislikedAt: Self.now)]
        Self.assertInvalidData(try LibraryValidation.validate(strayDislike, now: Self.now), "super liked songs",
                               "A dislike is never a favorite, so the id fails the subset check")

        var misordered = document
        misordered.superLikedIDs = [b.id, a.id]
        Self.assertInvalidData(try LibraryValidation.validate(misordered, now: Self.now), "super liked song order")

        var duplicated = document
        duplicated.superLikedIDs = [a.id, a.id]
        Self.assertInvalidData(try LibraryValidation.validate(duplicated, now: Self.now), "super liked songs")
    }

    func testAnInvalidSuperLikeOnDiskBlocksTheStoreWithoutRewritingTheFile() throws {
        let a = libraryTestTrack("a")
        var document = LibraryDocument()
        document.favorites = [a]
        document.superLikedIDs = ["ghost"]
        let bytes = try LibraryPersistence.encode(document)
        try withLibraryTestDirectory { directory in
            let url = directory.appendingPathComponent(LibraryPersistence.fileName)
            try LibraryPersistence.write(bytes, to: url, replacing: nil)
            let store = LibraryStore(directory: directory, now: { LibrarySyncTestData.now })
            let message = try XCTUnwrap(store.errorMessage)
            XCTAssertTrue(message.contains("super liked songs"), message)
            XCTAssertTrue(store.favorites.isEmpty)
            store.setSuperLiked(a, true)
            store.toggleFavorite(a)
            XCTAssertEqual(store.errorMessage, message)
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
    }

    // MARK: - Store

    func testPromotingAnUnlikedSongLikesItAtTheTopLiftsItsDislikeAndCommitsOnce() throws {
        try Self.withStore { store, _ in
            let a = libraryTestTrack("a")
            let b = libraryTestTrack("b")
            let c = libraryTestTrack("c")
            store.toggleFavorite(b)
            store.toggleFavorite(c)
            store.toggleDislike(a)
            XCTAssertTrue(store.isDisliked(a))
            XCTAssertEqual(store.favorites.map(\.id), ["c", "b"])
            let commits = store.durableCommitCount

            store.setSuperLiked(a, true)

            XCTAssertNil(store.errorMessage)
            XCTAssertEqual(store.durableCommitCount, commits + 1)
            XCTAssertEqual(store.favorites.map(\.id), ["a", "c", "b"])
            XCTAssertTrue(store.isFavorite(a))
            XCTAssertTrue(store.isSuperLiked(a))
            XCTAssertFalse(store.isDisliked(a), "A promotion is the newer, stronger reaction")
            XCTAssertTrue(store.disliked.isEmpty)
            XCTAssertEqual(store.superLikedIDs, ["a"])
            XCTAssertEqual(store.superLikes, [a])
            XCTAssertFalse(store.isSuperLiked(b))
            XCTAssertFalse(store.isSuperLiked(c))
        }
    }

    func testPromotingALikedSongMovesItToTheTopAndKeepsTheOthersInOrder() throws {
        try Self.withStore { store, _ in
            let a = libraryTestTrack("a")
            let b = libraryTestTrack("b")
            let c = libraryTestTrack("c")
            var renamed = a
            renamed.title = "Refreshed catalog title"
            store.toggleFavorite(a)
            store.toggleFavorite(b)
            store.toggleFavorite(c)
            XCTAssertEqual(store.favorites.map(\.id), ["c", "b", "a"])

            store.setSuperLiked(renamed, true)

            XCTAssertNil(store.errorMessage)
            XCTAssertEqual(store.favorites.map(\.id), ["a", "c", "b"])
            XCTAssertEqual(store.favorites[0], a, "The saved like keeps its own metadata; promotion is not a metadata refresh")
            XCTAssertEqual(store.superLikes, [a])
            XCTAssertEqual(store.superLikedIDs, ["a"])
            XCTAssertTrue(store.isSuperLiked(a))

            store.setSuperLiked(c, true)
            XCTAssertEqual(store.favorites.map(\.id), ["c", "a", "b"])
            XCTAssertEqual(store.superLikes.map(\.id), ["c", "a"], "Super likes follow Liked Songs order")
            XCTAssertEqual(store.superLikes.map(\.id), store.favorites.filter { store.isSuperLiked($0) }.map(\.id))
        }
    }

    func testDemotingKeepsTheLikeAndMovesTheSongToTheTop() throws {
        try Self.withStore { store, _ in
            let a = libraryTestTrack("a")
            let b = libraryTestTrack("b")
            let c = libraryTestTrack("c")
            store.setSuperLiked(a, true)
            store.setSuperLiked(b, true)
            store.toggleFavorite(c)
            XCTAssertEqual(store.favorites.map(\.id), ["c", "b", "a"])
            XCTAssertEqual(store.superLikes.map(\.id), ["b", "a"])
            let commits = store.durableCommitCount

            store.setSuperLiked(a, false)

            XCTAssertNil(store.errorMessage)
            XCTAssertEqual(store.durableCommitCount, commits + 1)
            XCTAssertEqual(store.favorites.map(\.id), ["a", "c", "b"], "Change to Like is a new reaction, so the song leads")
            XCTAssertTrue(store.isFavorite(a))
            XCTAssertFalse(store.isSuperLiked(a))
            XCTAssertEqual(store.superLikes.map(\.id), ["b"])
            XCTAssertEqual(store.superLikedIDs, ["b"])
        }
    }

    func testUnlikingASuperLikedSongRemovesBothTiers() throws {
        try Self.withStore { store, directory in
            let a = libraryTestTrack("a")
            let b = libraryTestTrack("b")
            store.setSuperLiked(a, true)
            store.toggleFavorite(b)

            store.toggleFavorite(a)

            XCTAssertNil(store.errorMessage)
            XCTAssertFalse(store.isFavorite(a))
            XCTAssertFalse(store.isSuperLiked(a))
            XCTAssertEqual(store.favorites, [b])
            XCTAssertTrue(store.superLikedIDs.isEmpty)
            XCTAssertTrue(store.superLikes.isEmpty)
            let saved = try LibraryPersistence.decode(Data(contentsOf: directory.appendingPathComponent(LibraryPersistence.fileName)),
                                                      now: Self.now)
            XCTAssertEqual(saved.favorites, [b])
            XCTAssertEqual(saved.superLikedIDs, [])

            store.toggleFavorite(a)
            XCTAssertTrue(store.isFavorite(a))
            XCTAssertFalse(store.isSuperLiked(a), "A fresh like starts at the plain tier")
        }
    }

    func testDislikingASuperLikedSongRemovesBothTiersAndAPromotionLiftsTheDislikeAgain() throws {
        try Self.withStore { store, _ in
            let a = libraryTestTrack("a")
            let b = libraryTestTrack("b")
            store.setSuperLiked(a, true)
            store.setSuperLiked(b, true)

            store.toggleDislike(a)

            XCTAssertNil(store.errorMessage)
            XCTAssertTrue(store.isDisliked(a))
            XCTAssertFalse(store.isFavorite(a))
            XCTAssertFalse(store.isSuperLiked(a))
            XCTAssertEqual(store.favorites, [b])
            XCTAssertEqual(store.superLikedIDs, ["b"])
            XCTAssertEqual(store.disliked.map(\.id), ["a"])

            store.setSuperLiked(a, true)
            XCTAssertNil(store.errorMessage)
            XCTAssertFalse(store.isDisliked(a))
            XCTAssertEqual(store.favorites.map(\.id), ["a", "b"])
            XCTAssertEqual(store.superLikes.map(\.id), ["a", "b"])
        }
    }

    func testSameStateSuperLikeCallsWriteNothing() throws {
        try Self.withStore { store, directory in
            let a = libraryTestTrack("a")
            let url = directory.appendingPathComponent(LibraryPersistence.fileName)
            store.setSuperLiked(a, false)
            XCTAssertNil(store.errorMessage)
            XCTAssertEqual(store.durableCommitCount, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "Demoting a song that was never liked is a no-op")
            XCTAssertFalse(store.isFavorite(a))

            store.setSuperLiked(a, true)
            XCTAssertEqual(store.durableCommitCount, 1)
            let saved = try Data(contentsOf: url)
            store.setSuperLiked(a, true)
            XCTAssertEqual(store.durableCommitCount, 1)
            XCTAssertEqual(try Data(contentsOf: url), saved)
            XCTAssertEqual(store.favorites, [a])

            store.setSuperLiked(a, false)
            XCTAssertEqual(store.durableCommitCount, 2)
            let demoted = try Data(contentsOf: url)
            store.setSuperLiked(a, false)
            XCTAssertEqual(store.durableCommitCount, 2)
            XCTAssertEqual(try Data(contentsOf: url), demoted)
            XCTAssertTrue(store.isFavorite(a))
            XCTAssertNil(store.errorMessage)
        }
    }

    func testAddFavoritesNeverDowngradesASuperLikeAndInsertsOnlyUnknownSongs() throws {
        try Self.withStore { store, _ in
            let a = libraryTestTrack("a")
            let b = libraryTestTrack("b")
            let c = libraryTestTrack("c")
            store.setSuperLiked(a, true)
            store.toggleFavorite(b)
            let commits = store.durableCommitCount

            XCTAssertEqual(store.addFavorites([a, c, b, c]), 1)

            XCTAssertNil(store.errorMessage)
            XCTAssertEqual(store.durableCommitCount, commits + 1)
            XCTAssertEqual(store.favorites.map(\.id), ["c", "b", "a"])
            XCTAssertTrue(store.isSuperLiked(a), "An import re-listing a super liked song keeps the tier")
            XCTAssertFalse(store.isSuperLiked(c), "Imports create plain likes only")
            XCTAssertEqual(store.superLikedIDs, ["a"])
            XCTAssertEqual(store.superLikes, [a])

            XCTAssertEqual(store.addFavorites([a, b]), 0)
            XCTAssertEqual(store.durableCommitCount, commits + 1, "Nothing new means no write")
            XCTAssertTrue(store.isSuperLiked(a))
        }
    }

    func testSuperLikesSurviveReloadFromDiskAndReopeningInLikedSongsOrder() throws {
        try Self.withStore { store, directory in
            let a = libraryTestTrack("a")
            let b = libraryTestTrack("b")
            let c = libraryTestTrack("c")
            store.setSuperLiked(a, true)
            store.toggleFavorite(b)
            store.setSuperLiked(c, true)
            XCTAssertEqual(store.favorites.map(\.id), ["c", "b", "a"])
            XCTAssertEqual(store.superLikes.map(\.id), ["c", "a"])

            XCTAssertEqual(store.reloadFromDisk(), .reloaded)
            XCTAssertNil(store.errorMessage)
            XCTAssertEqual(store.favorites.map(\.id), ["c", "b", "a"])
            XCTAssertEqual(store.superLikedIDs, ["c", "a"])
            XCTAssertEqual(store.superLikes.map(\.id), ["c", "a"])
            XCTAssertTrue(store.isSuperLiked(a))
            XCTAssertFalse(store.isSuperLiked(b))
            XCTAssertTrue(store.isSuperLiked(c))

            let reopened = LibraryStore(directory: directory, now: { LibrarySyncTestData.now })
            XCTAssertNil(reopened.errorMessage)
            XCTAssertEqual(reopened.favorites, store.favorites)
            XCTAssertEqual(reopened.superLikes, store.superLikes)
            XCTAssertEqual(reopened.superLikes.map(\.id), reopened.favorites.filter { reopened.isSuperLiked($0) }.map(\.id))
            let saved = try LibraryPersistence.decode(Data(contentsOf: directory.appendingPathComponent(LibraryPersistence.fileName)),
                                                      now: Self.now)
            XCTAssertEqual(saved.superLikedIDs, ["c", "a"], "The file keeps the ids in favorites order")
        }
    }

    // MARK: - Taste profile

    func testASuperLikeCreditsTrackAndArtistWithThreeLikesAndExposesItsID() {
        let bolt = libraryTestTrack("bolt", artist: "Kanye West")
        let heart = libraryTestTrack("heart", artist: "Frank Ocean")
        XCTAssertEqual(TasteProfile.superLikeBoost, 540)
        XCTAssertEqual(TasteProfile.superLikeBoost, 3 * TasteProfile.favoriteBoost)

        let profile = TasteProfile.build(events: [], favorites: [bolt, heart], playlists: [], recents: [],
                                         superLikedIDs: [bolt.id], now: Self.now)
        XCTAssertEqual(profile.trackAffinity["bolt"] ?? 0, 540, accuracy: 1e-9)
        XCTAssertEqual(profile.artistAffinity["kanye west"] ?? 0, 540, accuracy: 1e-9)
        XCTAssertEqual(profile.trackAffinity["heart"] ?? 0, 180, accuracy: 1e-9)
        XCTAssertEqual(profile.artistAffinity["frank ocean"] ?? 0, 180, accuracy: 1e-9)
        XCTAssertEqual(profile.superLikedTrackIDs, ["bolt"])
        XCTAssertEqual(profile.heardTrackIDs, ["bolt", "heart"])
        XCTAssertEqual(profile.topTracks(limit: 2).map(\.id), ["bolt", "heart"])

        let plain = TasteProfile.build(events: [], favorites: [bolt, heart], playlists: [], recents: [], now: Self.now)
        XCTAssertEqual(plain.trackAffinity["bolt"] ?? 0, 180, accuracy: 1e-9)
        XCTAssertTrue(plain.superLikedTrackIDs.isEmpty)

        let stray = TasteProfile.build(events: [], favorites: [heart], playlists: [], recents: [],
                                       superLikedIDs: [bolt.id], now: Self.now)
        XCTAssertTrue(stray.superLikedTrackIDs.isEmpty, "Only favorites can carry the tier")
        XCTAssertNil(stray.trackAffinity["bolt"])
    }

    func testADislikedSongLeavesTheSuperLikedSetAndItsArtistLosesTheDislikePenalty() {
        let bolt = libraryTestTrack("bolt", artist: "Kanye West")
        let dislike = DislikedSong(id: bolt.id, title: bolt.title, artists: bolt.artists, dislikedAt: Self.now)
        let profile = TasteProfile.build(events: [], favorites: [bolt], playlists: [], recents: [], disliked: [dislike],
                                         superLikedIDs: [bolt.id], now: Self.now)
        XCTAssertTrue(profile.superLikedTrackIDs.isEmpty)
        XCTAssertEqual(profile.dislikedTrackIDs, ["bolt"])
        XCTAssertNil(profile.trackAffinity["bolt"])
        XCTAssertEqual(profile.artistAffinity["kanye west"] ?? 0, TasteProfile.superLikeBoost - TasteProfile.dislikePenalty, accuracy: 1e-9)
    }

    // MARK: - Helpers

    private static func withStore(_ body: @MainActor (LibraryStore, URL) throws -> Void) throws {
        try withLibraryTestDirectory { directory in
            let store = LibraryStore(directory: directory, now: { LibrarySyncTestData.now })
            XCTAssertNil(store.errorMessage)
            try body(store, directory)
        }
    }

    private static func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func assertInvalidData<T>(_ expression: @autoclosure () throws -> T, _ reason: String, _ context: String = "",
                                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try expression(), context, file: file, line: line) { error in
            guard let storage = error as? LibraryStorageError, case .invalidData(let detail) = storage else {
                return XCTFail("Expected invalidData(\(reason)), got \(error). \(context)", file: file, line: line)
            }
            XCTAssertEqual(detail, reason, context, file: file, line: line)
        }
    }
}

import Foundation
import XCTest
@testable import GanaBajana

/// The super like tier on the sync wire: projection and materialization of the `(.reaction, id)` register, identity
/// validation, last-writer-wins between like, super like and removal, and the journal/replica v3 to v4 boundary.
@MainActor
final class SuperLikeSyncTests: XCTestCase {
    private static let now = LibrarySyncTestData.now

    // MARK: - Projection and materialization

    func testProjectionWritesTheTierIntoTheReactionRegisterOfASuperLikedFavoriteOnly() throws {
        let a = libraryTestTrack("a")
        let b = libraryTestTrack("b")
        let c = libraryTestTrack("c")
        let disliked = DislikedSong(id: "d", title: "Song d", artists: ["An Artist"], dislikedAt: Self.now)
        var document = LibraryDocument()
        document.favorites = [b, c, a]
        document.superLikedIDs = [b.id]
        document.disliked = [disliked]

        let values = try LibrarySyncProjection.values(document)
        func value(_ id: String) throws -> Data { try XCTUnwrap(values[LibrarySyncKey(.reaction, id)]) }
        func reaction(_ id: String) throws -> LibrarySyncReaction { try LibrarySyncCodec.decode(LibrarySyncReaction.self, from: value(id)) }
        XCTAssertEqual(try reaction("b"), .superLiked(b))
        XCTAssertEqual(try reaction("c"), .liked(c))
        XCTAssertEqual(try reaction("a"), .liked(a))
        XCTAssertEqual(try reaction("d"), .disliked(disliked))
        XCTAssertEqual(values.keys.filter { $0.collection == .reaction }.count, 4, "One register per recording, whatever the tier")
        XCTAssertTrue(LibrarySyncReaction.isSuperLikedValue(try value("b")))
        XCTAssertFalse(LibrarySyncReaction.isSuperLikedValue(try value("a")))
        XCTAssertFalse(LibrarySyncReaction.isSuperLikedValue(try value("d")))

        document.superLikedIDs = []
        XCTAssertEqual(try LibrarySyncCodec.decode(LibrarySyncReaction.self, from: XCTUnwrap(LibrarySyncProjection.values(document)[LibrarySyncKey(.reaction, "b")])),
                       .liked(b), "Change to Like is a different register value, so it earns a new revision")
    }

    func testMaterializeRebuildsFavoritesNewestFirstWithTheTierAndDislikesFromLiveRegisters() throws {
        let a = libraryTestTrack("a")
        let b = libraryTestTrack("b")
        let c = libraryTestTrack("c")
        let d = DislikedSong(id: "d", title: "Song d", artists: ["An Artist"], dislikedAt: Self.now)
        let entries: [(String, LibrarySyncReaction?, Int64)] = [
            ("a", .liked(a), 1), ("c", .liked(c), 2), ("b", .superLiked(b), 3), ("d", .disliked(d), 4), ("e", nil, 5),
        ]
        var state = LibrarySyncState()
        for (id, reaction, counter) in entries {
            let revision = LibrarySyncTestData.revision(counter)
            state.clock = revision
            state.put(LibrarySyncKey(.reaction, id), value: try reaction.map { try LibrarySyncCodec.encode($0) }, revision: revision)
        }
        try LibrarySyncValidation.validate(state, now: Self.now)

        var stale = LibraryDocument()
        stale.favorites = [libraryTestTrack("x"), a]
        stale.superLikedIDs = ["x"]
        stale.disliked = [DislikedSong(id: "y", title: "Song y", artists: [], dislikedAt: Self.now)]
        let document = try LibrarySyncProjection.materialize(state, onto: stale, now: Self.now)
        XCTAssertEqual(document.favorites.map(\.id), ["b", "c", "a"], "Newest reaction first; the tombstone contributes nothing")
        XCTAssertEqual(document.superLikedIDs, ["b"])
        XCTAssertEqual(document.disliked.map(\.id), ["d"])
        XCTAssertTrue(document.favorites.contains(b))
        XCTAssertNoThrow(try LibraryValidation.validate(document, now: Self.now))
        XCTAssertEqual(try LibrarySyncProjection.values(document).filter { $0.key.collection == .reaction }.count, 4)
        XCTAssertEqual(try LibrarySyncTestData.rendered(state).superLikedIDs, ["b"])
    }

    func testMaterializeKeepsFavoritesOrderForTheTierWhenSeveralSongsAreSuperLiked() throws {
        let a = libraryTestTrack("a")
        let b = libraryTestTrack("b")
        let c = libraryTestTrack("c")
        let entries: [(String, LibrarySyncReaction, Int64)] = [("a", .superLiked(a), 1), ("b", .liked(b), 2), ("c", .superLiked(c), 3)]
        var state = LibrarySyncState()
        for (id, reaction, counter) in entries {
            let revision = LibrarySyncTestData.revision(counter)
            state.clock = revision
            state.put(LibrarySyncKey(.reaction, id), value: try LibrarySyncCodec.encode(reaction), revision: revision)
        }
        let document = try LibrarySyncTestData.rendered(state)
        XCTAssertEqual(document.favorites.map(\.id), ["c", "b", "a"])
        XCTAssertEqual(document.superLikedIDs, ["c", "a"], "The ids follow favorites order so validation accepts the projection")
        XCTAssertNoThrow(try LibraryValidation.validate(document, now: Self.now))
    }

    // MARK: - Validation

    func testValidationRejectsASuperLikeWhoseTrackDiffersFromItsKey() throws {
        let mismatched = try LibrarySyncTestData.single(.reaction, "key", value: LibrarySyncReaction.superLiked(libraryTestTrack("other")),
                                                        revision: LibrarySyncTestData.revision(1))
        XCTAssertThrowsError(try LibrarySyncValidation.validate(mismatched, now: Self.now)) {
            XCTAssertEqual($0 as? LibrarySyncError, .invalidData("super liked song identity"))
        }
        let replica = LibrarySyncReplica(replicaID: LibrarySyncTestData.b, state: mismatched)
        XCTAssertThrowsError(try LibrarySyncCodec.decodeReplica(LibrarySyncCodec.encodeReplica(replica),
                                                               expectedReplicaID: LibrarySyncTestData.b, now: Self.now)) {
            XCTAssertEqual($0 as? LibrarySyncError, .invalidData("super liked song identity"))
        }

        let matching = try LibrarySyncTestData.single(.reaction, "same", value: LibrarySyncReaction.superLiked(libraryTestTrack("same")),
                                                      revision: LibrarySyncTestData.revision(1))
        XCTAssertNoThrow(try LibrarySyncValidation.validate(matching, now: Self.now))

        // A remote journal with the mismatch never reaches the local file.
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device()
        a.library.toggleFavorite(libraryTestTrack("kept-local"))
        let bytes = try Data(contentsOf: a.fileURL)
        XCTAssertThrowsError(try a.library.mergeCloudState(mismatched))
        XCTAssertEqual(try Data(contentsOf: a.fileURL), bytes)
        XCTAssertFalse(a.library.isFavorite(libraryTestTrack("other")))
        XCTAssertTrue(a.library.superLikedIDs.isEmpty)
    }

    // MARK: - Two writers

    func testSuperLikeAgainstUnlikeLetsTheLaterRevisionWinInBothDirections() throws {
        for superLikeIsLater in [false, true] {
            let harness = LibrarySyncTestHarness()
            defer { harness.remove() }
            let a = harness.device()
            let b = harness.device(LibrarySyncTestData.b)
            let song = libraryTestTrack("shared")
            a.library.toggleFavorite(song)
            try b.library.mergeCloudState(a.state())
            XCTAssertTrue(b.library.isFavorite(song))

            harness.clock.advance(by: 1)
            if superLikeIsLater { b.library.toggleFavorite(song) } else { a.library.setSuperLiked(song, true) }
            harness.clock.advance(by: 1)
            if superLikeIsLater { a.library.setSuperLiked(song, true) } else { b.library.toggleFavorite(song) }
            XCTAssertNil(a.library.errorMessage)
            XCTAssertNil(b.library.errorMessage)
            XCTAssertTrue(a.library.isSuperLiked(song))
            XCTAssertFalse(b.library.isFavorite(song))

            let aOffline = try a.state()
            let bOffline = try b.state()
            let key = LibrarySyncKey(.reaction, song.id)
            XCTAssertTrue(LibrarySyncReaction.isSuperLikedValue(try XCTUnwrap(aOffline.registers[key]?.value)))
            XCTAssertNil(try XCTUnwrap(bOffline.registers[key]).value, "Unliking leaves a tombstone in the same register")
            XCTAssertEqual(try LibrarySyncMerge.joined(aOffline, bOffline), try LibrarySyncMerge.joined(bOffline, aOffline))

            try a.library.mergeCloudState(bOffline)
            try b.library.mergeCloudState(aOffline)
            for library in [a.library, b.library] {
                XCTAssertEqual(library.isFavorite(song), superLikeIsLater, "superLikeIsLater=\(superLikeIsLater)")
                XCTAssertEqual(library.isSuperLiked(song), superLikeIsLater, "superLikeIsLater=\(superLikeIsLater)")
                XCTAssertEqual(library.superLikes.map(\.id), superLikeIsLater ? [song.id] : [])
            }
            XCTAssertEqual(try a.state(), try b.state())
            XCTAssertEqual(try a.saved().superLikedIDs, superLikeIsLater ? [song.id] : [])
            XCTAssertEqual(try b.saved().favorites.map(\.id), superLikeIsLater ? [song.id] : [])
        }
    }

    func testSuperLikeAgainstPlainLikeLetsTheLaterRevisionWinInBothDirections() throws {
        for superLikeIsLater in [false, true] {
            let harness = LibrarySyncTestHarness()
            defer { harness.remove() }
            let a = harness.device()
            let b = harness.device(LibrarySyncTestData.b)
            let song = libraryTestTrack("shared")

            harness.clock.advance(by: 1)
            if superLikeIsLater { b.library.toggleFavorite(song) } else { a.library.setSuperLiked(song, true) }
            harness.clock.advance(by: 1)
            if superLikeIsLater { a.library.setSuperLiked(song, true) } else { b.library.toggleFavorite(song) }
            XCTAssertTrue(a.library.isSuperLiked(song))
            XCTAssertTrue(b.library.isFavorite(song))
            XCTAssertFalse(b.library.isSuperLiked(song))

            let aOffline = try a.state()
            let bOffline = try b.state()
            XCTAssertEqual(try LibrarySyncMerge.joined(aOffline, bOffline), try LibrarySyncMerge.joined(bOffline, aOffline))
            try a.library.mergeCloudState(bOffline)
            try b.library.mergeCloudState(aOffline)
            for library in [a.library, b.library] {
                XCTAssertTrue(library.isFavorite(song), "Both reactions keep the song liked")
                XCTAssertEqual(library.isSuperLiked(song), superLikeIsLater, "superLikeIsLater=\(superLikeIsLater)")
                XCTAssertEqual(library.favorites.map(\.id), [song.id])
            }
            XCTAssertEqual(try a.state(), try b.state())
            XCTAssertEqual(try a.saved().superLikedIDs, superLikeIsLater ? [song.id] : [])
            XCTAssertEqual(try b.saved().superLikedIDs, superLikeIsLater ? [song.id] : [])
        }
    }

    func testASuperLikeFollowedByTheSameWritersTombstoneRemovesItEverywhere() throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device()
        let b = harness.device(LibrarySyncTestData.b)
        let song = libraryTestTrack("shared")
        a.library.setSuperLiked(song, true)
        let promoted = try a.state()
        try b.library.mergeCloudState(promoted)
        XCTAssertTrue(b.library.isSuperLiked(song))
        XCTAssertEqual(try b.saved().superLikedIDs, [song.id])

        harness.clock.advance(by: 1)
        a.library.toggleFavorite(song)
        XCTAssertFalse(a.library.isFavorite(song))
        let removed = try a.state()
        let key = LibrarySyncKey(.reaction, song.id)
        let register = try XCTUnwrap(removed.registers[key])
        XCTAssertNil(register.value)
        XCTAssertGreaterThan(register.revision, try XCTUnwrap(promoted.registers[key]?.revision))
        XCTAssertEqual(try LibrarySyncMerge.joined(promoted, removed), try LibrarySyncMerge.joined(removed, promoted))
        XCTAssertEqual(try LibrarySyncMerge.joined(promoted, removed).registers[key], register)

        try b.library.mergeCloudState(removed)
        XCTAssertFalse(b.library.isFavorite(song))
        XCTAssertFalse(b.library.isSuperLiked(song))
        XCTAssertTrue(b.library.superLikes.isEmpty)
        XCTAssertEqual(try b.saved().superLikedIDs, [])
        XCTAssertTrue(try b.saved().favorites.isEmpty)
        XCTAssertEqual(try a.state(), try b.state())
    }

    // MARK: - Schema

    func testAVersionThreeJournalOrReplicaCarryingASuperLikeIsRejected() throws {
        let song = libraryTestTrack("bolt")
        let state = try LibrarySyncTestData.single(.reaction, song.id, value: LibrarySyncReaction.superLiked(song),
                                                   revision: LibrarySyncTestData.revision(1))
        XCTAssertEqual(LibrarySyncState.currentVersion, 4)
        XCTAssertEqual(LibrarySyncReplica.currentVersion, 4)

        var journal = try Self.json(LibrarySyncCodec.encode(state))
        XCTAssertEqual(journal["version"] as? Int, 4)
        XCTAssertEqual(try LibrarySyncCodec.decode(LibrarySyncState.self, from: LibrarySyncCodec.encode(state)), state)
        journal["version"] = 3
        let journalBytes = try JSONSerialization.data(withJSONObject: journal, options: .sortedKeys)
        XCTAssertThrowsError(try LibrarySyncCodec.decode(LibrarySyncState.self, from: journalBytes)) {
            XCTAssertEqual($0 as? LibrarySyncError, .invalidData("super like journal version"))
        }

        let replica = LibrarySyncReplica(replicaID: LibrarySyncTestData.a, state: state)
        var envelope = try Self.json(LibrarySyncCodec.encodeReplica(replica))
        XCTAssertEqual(envelope["version"] as? Int, 4)
        envelope["version"] = 3
        let envelopeBytes = try JSONSerialization.data(withJSONObject: envelope, options: .sortedKeys)
        XCTAssertThrowsError(try LibrarySyncCodec.decodeReplica(envelopeBytes, expectedReplicaID: LibrarySyncTestData.a, now: Self.now)) {
            XCTAssertEqual($0 as? LibrarySyncError, .invalidData("super like replica version"))
        }
        var innerJournal = try XCTUnwrap(envelope["state"] as? [String: Any])
        innerJournal["version"] = 3
        envelope["state"] = innerJournal
        let bothBytes = try JSONSerialization.data(withJSONObject: envelope, options: .sortedKeys)
        XCTAssertThrowsError(try LibrarySyncCodec.decodeReplica(bothBytes, expectedReplicaID: LibrarySyncTestData.a, now: Self.now)) {
            XCTAssertEqual($0 as? LibrarySyncError, .invalidData("super like journal version"), "The journal is decoded before the envelope check")
        }

        // The library file carries the same journal; a v3 journal with the case blocks the whole file.
        var document = LibraryDocument()
        document.favorites = [song]
        document.superLikedIDs = [song.id]
        document.syncState = try LibrarySyncJournal.seed(document, now: Self.now, writer: LibrarySyncTestData.a)
        var library = try Self.json(LibraryPersistence.encode(document))
        var saved = try XCTUnwrap(library["syncState"] as? [String: Any])
        XCTAssertEqual(saved["version"] as? Int, 4)
        saved["version"] = 3
        library["syncState"] = saved
        let libraryBytes = try JSONSerialization.data(withJSONObject: library, options: .sortedKeys)
        XCTAssertThrowsError(try LibraryPersistence.decode(libraryBytes, now: Self.now)) {
            XCTAssertEqual($0 as? LibrarySyncError, .invalidData("super like journal version"))
        }
        try withLibraryTestDirectory { directory in
            let url = directory.appendingPathComponent(LibraryPersistence.fileName)
            try LibraryPersistence.write(libraryBytes, to: url, replacing: nil)
            let store = LibraryStore(directory: directory, now: { LibrarySyncTestData.now })
            XCTAssertTrue(try XCTUnwrap(store.errorMessage).contains("super like journal version"))
            store.setSuperLiked(song, false)
            XCTAssertEqual(try Data(contentsOf: url), libraryBytes)
        }
    }

    func testAVersionThreeJournalOrReplicaWithoutSuperLikesReadsAsVersionFourWithoutRestamping() throws {
        let song = libraryTestTrack("plain")
        let revision = LibrarySyncTestData.revision(7, writer: LibrarySyncTestData.c)
        var state = try LibrarySyncTestData.single(.reaction, song.id, value: LibrarySyncReaction.liked(song), revision: revision)
        let disliked = DislikedSong(id: "d", title: "Song d", artists: ["An Artist"], dislikedAt: Self.now)
        state.put(LibrarySyncKey(.reaction, disliked.id), value: try LibrarySyncCodec.encode(LibrarySyncReaction.disliked(disliked)),
                  revision: LibrarySyncTestData.revision(3))
        state.put(LibrarySyncKey(.reaction, "gone"), value: nil, revision: LibrarySyncTestData.revision(2))

        var journal = try Self.json(LibrarySyncCodec.encode(state))
        journal["version"] = 3
        let decoded = try LibrarySyncCodec.decode(LibrarySyncState.self, from: JSONSerialization.data(withJSONObject: journal, options: .sortedKeys))
        XCTAssertEqual(decoded.version, 4)
        XCTAssertEqual(decoded.registers, state.registers, "Reading an older journal is not a new edit")
        XCTAssertEqual(decoded.clock, revision)
        XCTAssertEqual(decoded.registers[LibrarySyncKey(.reaction, song.id)]?.revision, revision)
        let rendered = try LibrarySyncTestData.rendered(decoded)
        XCTAssertEqual(rendered.favorites, [song])
        XCTAssertEqual(rendered.superLikedIDs, [])
        XCTAssertEqual(rendered.disliked, [disliked])

        var legacy = state
        legacy.version = 3
        let replica = LibrarySyncReplica(version: 3, replicaID: LibrarySyncTestData.a, state: legacy)
        let bytes = try LibrarySyncCodec.encodeReplica(replica)
        XCTAssertEqual(try Self.json(bytes)["version"] as? Int, 3)
        let remote = try LibrarySyncCodec.decodeReplica(bytes, expectedReplicaID: LibrarySyncTestData.a, now: Self.now)
        XCTAssertEqual(remote.version, 4)
        XCTAssertEqual(remote.state.version, 4)
        XCTAssertEqual(remote.state.registers, state.registers)
        XCTAssertEqual(remote.state.clock, revision)
        XCTAssertTrue(try LibrarySyncTestData.rendered(remote.state).superLikedIDs.isEmpty)

        // A current device merges the older replica and can then promote the song it received.
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device()
        try a.library.mergeCloudState(remote.state)
        XCTAssertTrue(a.library.isFavorite(song))
        XCTAssertFalse(a.library.isSuperLiked(song))
        XCTAssertEqual(try a.state().registers[LibrarySyncKey(.reaction, song.id)]?.revision, revision)
        a.library.setSuperLiked(song, true)
        XCTAssertTrue(a.library.isSuperLiked(song))
        XCTAssertEqual(try a.saved().syncState?.version, 4)
    }

    func testIsSuperLikedValueMatchesOnlyTheSuperLikedEncoding() throws {
        let song = libraryTestTrack("bolt")
        XCTAssertTrue(LibrarySyncReaction.isSuperLikedValue(try LibrarySyncCodec.encode(LibrarySyncReaction.superLiked(song))))
        XCTAssertFalse(LibrarySyncReaction.isSuperLikedValue(try LibrarySyncCodec.encode(LibrarySyncReaction.liked(song))))
        XCTAssertFalse(LibrarySyncReaction.isSuperLikedValue(try LibrarySyncCodec.encode(
            LibrarySyncReaction.disliked(DislikedSong(id: song.id, title: song.title, artists: song.artists, dislikedAt: Self.now)))))
        XCTAssertFalse(LibrarySyncReaction.isSuperLikedValue(Data()))
        var lookalike = song
        lookalike.title = "superLiked"
        XCTAssertFalse(LibrarySyncReaction.isSuperLikedValue(try LibrarySyncCodec.encode(LibrarySyncReaction.liked(lookalike))),
                       "Only the case name at the start of the sorted-key encoding counts")
        XCTAssertTrue(try LibrarySyncCodec.encode(LibrarySyncReaction.superLiked(song)).starts(with: Data("{\"superLiked\":".utf8)))
    }

    // MARK: - Store round trip

    func testTheStoreJournalsASuperLikeAsItsOwnRegisterValueAndTheSavedFileStaysConsistent() throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device()
        let song = libraryTestTrack("bolt")
        let key = LibrarySyncKey(.reaction, song.id)

        a.library.setSuperLiked(song, true)
        XCTAssertNil(a.library.errorMessage)
        var saved = try a.saved()
        var value = try XCTUnwrap(XCTUnwrap(saved.syncState?.registers[key]).value)
        XCTAssertTrue(LibrarySyncReaction.isSuperLikedValue(value))
        XCTAssertEqual(try LibrarySyncCodec.decode(LibrarySyncReaction.self, from: value), .superLiked(song))
        XCTAssertEqual(saved.superLikedIDs, [song.id])
        XCTAssertEqual(saved.favorites, [song])
        XCTAssertEqual(saved.syncState?.version, LibrarySyncState.currentVersion)
        XCTAssertNoThrow(try LibrarySyncValidation.validateLocal(saved, now: Self.now))
        let promotion = try XCTUnwrap(saved.syncState?.registers[key]?.revision)

        harness.clock.advance(by: 1)
        a.library.setSuperLiked(song, false)
        saved = try a.saved()
        value = try XCTUnwrap(XCTUnwrap(saved.syncState?.registers[key]).value)
        XCTAssertFalse(LibrarySyncReaction.isSuperLikedValue(value))
        XCTAssertEqual(try LibrarySyncCodec.decode(LibrarySyncReaction.self, from: value), .liked(song))
        XCTAssertEqual(saved.superLikedIDs, [])
        XCTAssertEqual(saved.favorites, [song])
        XCTAssertGreaterThan(try XCTUnwrap(saved.syncState?.registers[key]?.revision), promotion, "Demotion is a new reaction revision")
        XCTAssertNoThrow(try LibrarySyncValidation.validateLocal(saved, now: Self.now))

        // A saved file whose tier disagrees with its journal is inconsistent and is never opened for writing.
        var inconsistent = saved
        inconsistent.superLikedIDs = [song.id]
        XCTAssertThrowsError(try LibrarySyncValidation.validateLocal(inconsistent, now: Self.now)) { error in
            guard let storage = error as? LibraryStorageError, case .invalidData(let detail) = storage else {
                return XCTFail("Expected a consistency failure, got \(error)")
            }
            XCTAssertEqual(detail, "sync journal and saved library consistency")
        }
        let bytes = try LibraryPersistence.encode(inconsistent)
        try bytes.write(to: a.fileURL, options: .atomic)
        let reopened = LibraryStore(directory: a.directory, now: { LibrarySyncTestData.now })
        XCTAssertTrue(reopened.requiresReload)
        reopened.setSuperLiked(song, false)
        XCTAssertEqual(try Data(contentsOf: a.fileURL), bytes)
    }

    // MARK: - Helpers

    private static func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

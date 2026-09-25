import XCTest
@testable import GanaBajana

final class LibrarySyncMergeTests: XCTestCase {
    func testRegisterJoinIsCommutativeAssociativeIdempotentAndUsesUUIDTieBreaks() throws {
        let a = try LibrarySyncTestData.single(.preference, "appearance", value: "light", revision: LibrarySyncTestData.revision(1))
        let b = try LibrarySyncTestData.single(.preference, "appearance", value: "dark", revision: LibrarySyncTestData.revision(1, writer: LibrarySyncTestData.b))
        let c = try LibrarySyncTestData.single(.reaction, "song", value: LibrarySyncReaction.liked(libraryTestTrack("song")),
                                               revision: LibrarySyncTestData.revision(2, writer: LibrarySyncTestData.c))
        let ab = try LibrarySyncMerge.joined(a, b)
        let result = try LibrarySyncMerge.joined(ab, c)
        XCTAssertEqual(ab, try LibrarySyncMerge.joined(b, a))
        XCTAssertEqual(result, try LibrarySyncMerge.joined(a, LibrarySyncMerge.joined(b, c)))
        XCTAssertEqual(result, try LibrarySyncMerge.joined(c, LibrarySyncMerge.joined(b, a)))
        XCTAssertEqual(result, try LibrarySyncMerge.joined(result, result))
        let document = try LibrarySyncTestData.rendered(result)
        XCTAssertEqual(document.preferences.appearance, .dark)
        XCTAssertEqual(document.favorites.map(\.id), ["song"])
    }

    func testCumulativeListeningJoinsByMaximumInsteadOfAddingDownloadedTotals() throws {
        let id = UUID()
        let song = libraryTestTrack()
        let a = ListeningEvent(id: id, track: song, startedAt: LibrarySyncTestData.now, listenedSeconds: 10)
        let b = ListeningEvent(id: id, track: song, startedAt: LibrarySyncTestData.now, listenedSeconds: 35)
        let c = ListeningEvent(id: id, track: song, startedAt: LibrarySyncTestData.now, listenedSeconds: 20)
        let states = try [a, b, c].enumerated().map {
            try LibrarySyncTestData.single(.event, id.uuidString, value: $0.element, revision: LibrarySyncTestData.revision(Int64($0.offset)))
        }
        let left = try LibrarySyncMerge.joined(LibrarySyncMerge.joined(states[0], states[1]), states[2])
        let right = try LibrarySyncMerge.joined(states[0], LibrarySyncMerge.joined(states[1], states[2]))
        XCTAssertEqual(left, right)
        XCTAssertEqual(try LibrarySyncTestData.rendered(left).events.first?.listenedSeconds, 35)
        XCTAssertEqual(left, try LibrarySyncMerge.joined(left, states[1]))
    }

    func testSessionIdentityMismatchRejectsTheWholeJoin() throws {
        let id = UUID()
        let original = ListeningEvent(id: id, track: libraryTestTrack(), startedAt: LibrarySyncTestData.now, listenedSeconds: 20)
        let a = try LibrarySyncTestData.single(.event, id.uuidString, value: original, revision: LibrarySyncTestData.revision(1))
        for replacement in [
            ListeningEvent(id: id, track: libraryTestTrack("different"), startedAt: original.startedAt, listenedSeconds: 40),
            ListeningEvent(id: id, track: original.track, startedAt: original.startedAt.addingTimeInterval(1), listenedSeconds: 40)
        ] {
            let b = try LibrarySyncTestData.single(.event, id.uuidString, value: replacement, revision: LibrarySyncTestData.revision(2))
            XCTAssertThrowsError(try LibrarySyncMerge.joined(a, b))
            XCTAssertThrowsError(try LibrarySyncMerge.joined(b, a))
        }
    }

    func testClearGenerationDefeatsLaterOfflineClockAndIsAssociative() throws {
        let event = ListeningEvent(id: UUID(), track: libraryTestTrack(), startedAt: LibrarySyncTestData.now, listenedSeconds: 100)
        let offline = try LibrarySyncTestData.single(.event, event.id.uuidString, value: event,
                                                     revision: LibrarySyncTestData.revision(100, writer: LibrarySyncTestData.b))
        var cleared = LibrarySyncState()
        cleared.clock = LibrarySyncTestData.revision(2)
        cleared.historyReset = cleared.clock
        let freshRevision = LibrarySyncTestData.revision(3)
        var fresh = cleared
        fresh.clock = freshRevision
        let freshEvent = ListeningEvent(id: UUID(), track: event.track, startedAt: event.startedAt, listenedSeconds: 5)
        fresh.put(LibrarySyncKey(.event, freshEvent.id.uuidString), value: try LibrarySyncCodec.encode(freshEvent), revision: freshRevision)
        let result = try LibrarySyncMerge.joined(LibrarySyncMerge.joined(offline, cleared), fresh)
        XCTAssertEqual(result, try LibrarySyncMerge.joined(offline, LibrarySyncMerge.joined(cleared, fresh)))
        XCTAssertEqual(try LibrarySyncTestData.rendered(result).events.map(\.id), [freshEvent.id])
        XCTAssertEqual(result.clock, offline.clock, "Observed logical time advances even when a stale-generation value is discarded")
    }

    func testFollowCheckUnionDoesNotReestablishMembership() throws {
        let a = FollowedArtist(id: "artist", name: "Artist", followedAt: LibrarySyncTestData.now,
                               knownReleaseIDs: ["old"], hasEstablishedReleaseBaseline: true)
        var b = a
        b.knownReleaseIDs = ["new"]
        b.lastCheckedAt = LibrarySyncTestData.now.addingTimeInterval(60)
        let first = try LibrarySyncTestData.single(.followMetadata, a.id, value: a, revision: LibrarySyncTestData.revision(1))
        let second = try LibrarySyncTestData.single(.followMetadata, a.id, value: b, revision: LibrarySyncTestData.revision(5))
        var removed = LibrarySyncState()
        removed.clock = LibrarySyncTestData.revision(2)
        removed.put(LibrarySyncKey(.follow, a.id), value: nil, revision: removed.clock!)
        let joined = try LibrarySyncMerge.joined(first, LibrarySyncMerge.joined(removed, second))
        XCTAssertTrue(try LibrarySyncTestData.rendered(joined).followedArtists.isEmpty)
        let data = try XCTUnwrap(joined.registers[LibrarySyncKey(.followMetadata, a.id)]?.value)
        let metadata = try LibrarySyncCodec.decode(FollowedArtist.self, from: data)
        XCTAssertEqual(metadata.knownReleaseIDs, ["new", "old"])
        XCTAssertEqual(metadata.lastCheckedAt, b.lastCheckedAt)
        XCTAssertEqual(joined, try LibrarySyncMerge.joined(LibrarySyncMerge.joined(first, removed), second))
    }

    func testMalformedOlderGenerationAndNewerSchemaAreRejectedBeforeDiscardingAnything() throws {
        var state = LibrarySyncState()
        state.clock = LibrarySyncTestData.revision(5)
        state.historyReset = state.clock
        let invalid = ListeningEvent(id: UUID(), track: libraryTestTrack(), startedAt: LibrarySyncTestData.now.addingTimeInterval(-800 * 86_400),
                                     listenedSeconds: -1)
        state.registers[LibrarySyncKey(.event, invalid.id.uuidString)] = LibrarySyncRegister(
            revision: LibrarySyncTestData.revision(1), value: try LibrarySyncCodec.encode(invalid), generation: nil
        )
        let replica = LibrarySyncReplica(replicaID: LibrarySyncTestData.a, state: state)
        XCTAssertThrowsError(try LibrarySyncCodec.decodeReplica(LibrarySyncCodec.encodeReplica(replica), expectedReplicaID: replica.replicaID,
                                                               now: LibrarySyncTestData.now))
        XCTAssertThrowsError(try LibrarySyncCodec.decodeReplica(Data("{\"version\":999,\"unknown\":true}".utf8),
                                                               expectedReplicaID: replica.replicaID, now: LibrarySyncTestData.now)) {
            XCTAssertEqual($0 as? LibrarySyncError, .newerVersion)
        }
    }

    func testUnknownAndClampedPreferencesCannotSilentlyRoundTripAsDifferentValues() throws {
        for (key, value) in [("futureUnknownSetting", Data("true".utf8)), ("crossfadeSeconds", Data("999".utf8))] {
            var state = LibrarySyncState()
            state.clock = LibrarySyncTestData.revision(1)
            state.put(LibrarySyncKey(.preference, key), value: value, revision: state.clock!)
            XCTAssertThrowsError(try LibrarySyncValidation.validate(state, now: LibrarySyncTestData.now))
        }
    }

    func testFractionalPositionsRemainStrictAcrossRepeatedInsertionsAndConcurrentWriters() throws {
        let first = try LibrarySyncPosition.between(nil, nil, revision: LibrarySyncTestData.revision(1))
        let other = try LibrarySyncPosition.between(nil, nil, revision: LibrarySyncTestData.revision(1, writer: LibrarySyncTestData.b))
        XCTAssertNotEqual(first, other)
        var upper = max(first, other)
        let lower = min(first, other)
        for index in 2..<70 {
            let inserted = try LibrarySyncPosition.between(lower, upper, revision: LibrarySyncTestData.revision(Int64(index)))
            XCTAssertTrue(lower < inserted)
            XCTAssertTrue(inserted < upper)
            upper = inserted
        }
    }

    func testSearchRetentionFloorsAreScopedToTheirResetGenerationAndKeepDeterministicTies() throws {
        var old = LibrarySyncState()
        old.clock = LibrarySyncTestData.revision(100, writer: LibrarySyncTestData.b)
        old.searchFloor = LibrarySyncSearchBoundary(revision: old.clock!, key: "old query")
        var fresh = LibrarySyncState()
        fresh.historyReset = nil
        fresh.searchReset = LibrarySyncTestData.revision(1)
        let revision = LibrarySyncTestData.revision(2)
        fresh.clock = revision
        for index in 0..<25 {
            let query = String(format: "query %02d", index)
            fresh.put(LibrarySyncKey(.search, query), value: try LibrarySyncCodec.encode(query), revision: revision)
        }
        var joined = try LibrarySyncMerge.joined(old, fresh)
        XCTAssertNil(joined.searchFloor, "An old generation's later clock cannot evict post-clear queries")
        let document = try LibrarySyncTestData.rendered(joined)
        LibrarySyncMerge.compact(&joined, retaining: document)
        XCTAssertEqual(try LibrarySyncTestData.rendered(joined).recentSearches, (0..<20).map { String(format: "query %02d", $0) })
        XCTAssertEqual(joined.registers.filter { $0.key.collection == .search }.count, 20)
    }

    func testAPlaylistMetadataRefreshDoesNotReviveRemovedMembership() throws {
        let id = UUID()
        let song = libraryTestTrack("song")
        var document = LibraryDocument()
        document.playlists = [UserPlaylist(id: id, name: "Songs", tracks: [song], createdAt: LibrarySyncTestData.now, updatedAt: LibrarySyncTestData.now)]
        document.syncState = try LibrarySyncJournal.seed(document, now: LibrarySyncTestData.now, writer: LibrarySyncTestData.a)
        var removed = document
        removed.playlists[0].tracks = []
        let removal = try LibrarySyncJournal.recording(previous: document, candidate: removed, mutation: LibrarySyncMutation(),
                                                        now: LibrarySyncTestData.now, writer: LibrarySyncTestData.a)
        var refreshed = document
        refreshed.playlists[0].tracks[0].title = "Corrected catalog title"
        let refresh = try LibrarySyncJournal.recording(previous: document, candidate: refreshed, mutation: LibrarySyncMutation(),
                                                        now: LibrarySyncTestData.now.addingTimeInterval(60), writer: LibrarySyncTestData.b)
        let joined = try LibrarySyncMerge.joined(removal, refresh)
        XCTAssertTrue(try LibrarySyncTestData.rendered(joined).playlists[0].tracks.isEmpty)
    }

    @MainActor
    func testConcurrentRemovalAndReadditionWithClockSkewKeepLiveTracksPositionedInEitherJoinOrder() throws {
        for additionalATick in [false, true] {
            let harness = LibrarySyncTestHarness()
            defer { harness.remove() }
            let updatedAt = LibrarySyncTestData.now
            let playlistID = UUID()
            let x = libraryTestTrack("x")
            let y = libraryTestTrack("y")
            var baseline = LibraryDocument()
            baseline.playlists = [UserPlaylist(id: playlistID, name: "Concurrent edits", tracks: [x, y],
                                               createdAt: updatedAt.addingTimeInterval(-10), updatedAt: updatedAt)]
            baseline.syncState = try LibrarySyncJournal.seed(baseline, now: updatedAt.addingTimeInterval(3600), writer: LibrarySyncTestData.c)
            let bytes = try LibraryPersistence.encode(baseline)
            let aDirectory = harness.root.appendingPathComponent("a")
            let bDirectory = harness.root.appendingPathComponent("b")
            for directory in [aDirectory, bDirectory] {
                try LibraryPersistence.write(bytes, to: directory.appendingPathComponent(LibraryPersistence.fileName), replacing: nil)
            }
            let a = LibraryStore(directory: aDirectory, now: { updatedAt.addingTimeInterval(-1) }, writerID: LibrarySyncTestData.a)
            let b = LibraryStore(directory: bDirectory, now: { updatedAt.addingTimeInterval(1) }, writerID: LibrarySyncTestData.b)
            let positionKey = LibrarySyncKey(.playlistPosition, playlistID.uuidString, member: x.id)
            let originalPosition = try XCTUnwrap(baseline.syncState?.registers[positionKey])
            a.remove(trackID: x.id, from: playlistID)
            XCTAssertEqual(try a.cloudReplica(replicaID: LibrarySyncTestData.a).state.registers[positionKey], originalPosition)
            if additionalATick { a.toggleFavorite(libraryTestTrack("a-clock-tick")) }
            a.add(x, to: playlistID)
            let unrelated = libraryTestTrack("unrelated")
            b.toggleFavorite(unrelated)
            b.toggleFavorite(unrelated)
            b.remove(trackID: x.id, from: playlistID)
            XCTAssertNil(a.errorMessage)
            XCTAssertNil(b.errorMessage)
            let aState = try a.cloudReplica(replicaID: LibrarySyncTestData.a).state
            let bState = try b.cloudReplica(replicaID: LibrarySyncTestData.b).state
            XCTAssertEqual(bState.registers[positionKey], originalPosition)
            let ab = try LibrarySyncMerge.joined(aState, bState)
            let ba = try LibrarySyncMerge.joined(bState, aState)
            XCTAssertEqual(ab, ba)
            for joined in [ab, ba] {
                try LibrarySyncValidation.validate(joined, now: updatedAt.addingTimeInterval(1))
                let projected = try LibrarySyncTestData.rendered(joined)
                let playlist = try XCTUnwrap(projected.playlists.first)
                XCTAssertTrue(playlist.tracks.contains { $0.id == y.id })
                if additionalATick { XCTAssertEqual(playlist.tracks.map(\.id), [y.id, x.id]) }
                XCTAssertNotNil(joined.registers[positionKey]?.value)
            }
        }
    }
}

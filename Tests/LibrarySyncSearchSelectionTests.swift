import Foundation
import XCTest
@testable import GanaBajana

@MainActor
final class LibrarySyncSearchSelectionTests: XCTestCase {
    func testIndependentOfflineSelectionsQueriesAndLanguagePreferencesConverge() throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device()
        let b = harness.device(LibrarySyncTestData.b)
        a.sync.setEnabled(false)
        b.sync.setEnabled(false)
        let track = SearchSelection.track(libraryTestTrack("recording"))
        let artist = SearchSelection.collection(MusicCollection(id: "artist", title: "Artist", kind: .artist))
        let album = SearchSelection.collection(MusicCollection(id: "album", title: "Album", kind: .album))
        let playlist = SearchSelection.collection(MusicCollection(id: "playlist", title: "Playlist", kind: .playlist))
        XCTAssertTrue(a.library.recordSearchSelection(track))
        XCTAssertTrue(b.library.recordSearchSelection(artist))
        XCTAssertTrue(a.library.recordSearchSelection(album))
        XCTAssertTrue(b.library.recordSearchSelection(playlist))
        a.library.recordSearch("Legacy query")
        a.library.preferences.languageNudges[.english] = .more
        b.library.preferences.languageNudges[.hindi] = .less
        let savedOffline = try a.saved()
        XCTAssertNotNil(savedOffline.syncState?.registers[LibrarySyncKey(.searchSelection, track.id)])
        XCTAssertFalse(a.sync.isEnabled)
        XCTAssertEqual(a.transport.publicationAttempts, 0)

        try a.library.mergeCloudState(b.state())
        try b.library.mergeCloudState(a.state())
        XCTAssertEqual(Set(a.library.recentSearchSelections), Set([track, artist, album, playlist]))
        XCTAssertEqual(a.library.recentSearchSelections, b.library.recentSearchSelections)
        XCTAssertEqual(a.library.recentSearches, ["Legacy query"])
        XCTAssertEqual(b.library.recentSearches, ["Legacy query"])
        XCTAssertEqual(a.library.preferences.languageNudges[.english], .more)
        XCTAssertEqual(a.library.preferences.languageNudges[.hindi], .less)
        XCTAssertEqual(a.library.preferences, b.library.preferences)
        XCTAssertEqual(try a.saved().recentSearchSelections, a.library.recentSearchSelections)
        XCTAssertEqual(try a.state(), try b.state())
    }

    func testOpeningTheUnchangedLocalFirstSelectionOrdersItAheadOfAnUnseenRemoteSelection() throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device()
        let b = harness.device(LibrarySyncTestData.b)
        let first = SearchSelection.track(libraryTestTrack("first"))
        let other = SearchSelection.track(libraryTestTrack("other"))
        XCTAssertTrue(a.library.recordSearchSelection(first))
        try b.library.mergeCloudState(a.state())
        harness.clock.advance(by: 10)
        XCTAssertTrue(b.library.recordSearchSelection(other))
        harness.clock.advance(by: 10)
        XCTAssertEqual(a.library.recentSearchSelections, [first])
        XCTAssertTrue(a.library.recordSearchSelection(first))
        try a.library.mergeCloudState(b.state())
        try b.library.mergeCloudState(a.state())
        XCTAssertEqual(a.library.recentSearchSelections, [first, other])
        XCTAssertEqual(b.library.recentSearchSelections, [first, other])
    }

    func testJoinAlgebraUsesRevisionWriterAndStableTypedIdentityTies() throws {
        let first = SearchSelection.track(Track(id: "Song", title: "Original title"))
        let updated = SearchSelection.track(Track(id: "Song", title: "Updated title"))
        let album = SearchSelection.collection(MusicCollection(id: "Song", title: "Original title", kind: .album))
        let a = try LibrarySyncTestData.single(.searchSelection, first.id, value: first, revision: LibrarySyncTestData.revision(1))
        let b = try LibrarySyncTestData.single(.searchSelection, updated.id, value: updated,
                                               revision: LibrarySyncTestData.revision(1, writer: LibrarySyncTestData.b))
        let c = try LibrarySyncTestData.single(.searchSelection, album.id, value: album, revision: LibrarySyncTestData.revision(2))
        let joined = try LibrarySyncMerge.joined(LibrarySyncMerge.joined(a, b), c)
        XCTAssertEqual(joined, try LibrarySyncMerge.joined(a, LibrarySyncMerge.joined(b, c)))
        XCTAssertEqual(joined, try LibrarySyncMerge.joined(c, LibrarySyncMerge.joined(b, a)))
        XCTAssertEqual(joined, try LibrarySyncMerge.joined(joined, joined))
        XCTAssertEqual(try LibrarySyncTestData.rendered(joined).recentSearchSelections, [album, updated])

        let revision = LibrarySyncTestData.revision(3)
        var tied = LibrarySyncState()
        tied.clock = revision
        let lower = SearchSelection.track(libraryTestTrack("same"))
        let upper = SearchSelection.track(libraryTestTrack("Same"))
        for selection in [lower, upper, album] {
            tied.put(LibrarySyncKey(.searchSelection, selection.id), value: try LibrarySyncCodec.encode(selection), revision: revision)
        }
        XCTAssertEqual(try LibrarySyncTestData.rendered(tied).recentSearchSelections.map(\.id),
                       ["collection:album:Song", "track:Same", "track:same"])
        try LibrarySyncValidation.validate(tied, now: LibrarySyncTestData.now)
    }

    func testRemovalTombstoneRejectsAStaleReplicaAndExplicitReopeningCanAddItAgain() throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device()
        let b = harness.device(LibrarySyncTestData.b)
        let selection = SearchSelection.collection(MusicCollection(id: "album", title: "Album", kind: .album))
        XCTAssertTrue(a.library.recordSearchSelection(selection))
        let stale = try a.state()
        try b.library.mergeCloudState(stale)
        XCTAssertTrue(a.library.removeRecentSearchSelection(id: selection.id))
        try a.library.mergeCloudState(stale)
        try b.library.mergeCloudState(a.state())
        XCTAssertTrue(a.library.recentSearchSelections.isEmpty)
        XCTAssertTrue(b.library.recentSearchSelections.isEmpty)
        let tombstone = try XCTUnwrap(a.state().registers[LibrarySyncKey(.searchSelection, selection.id)])
        XCTAssertNil(tombstone.value)
        XCTAssertTrue(b.library.recordSearchSelection(selection))
        try a.library.mergeCloudState(b.state())
        XCTAssertEqual(a.library.recentSearchSelections, [selection])
    }

    func testClearWhileEmptyRejectsLaterOfflineClocksInBothSearchNamespaces() throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device()
        let b = harness.device(LibrarySyncTestData.b)
        XCTAssertTrue(a.library.clearRecentSearches())
        let clear = try a.state()
        let reset = try XCTUnwrap(a.library.searchHistoryResetRevision)
        harness.clock.advance(by: 3600)
        let stale = SearchSelection.track(libraryTestTrack("late-offline"))
        XCTAssertTrue(b.library.recordSearchSelection(stale))
        b.library.recordSearch("Late offline query")
        let late = try b.state()
        XCTAssertGreaterThan(try XCTUnwrap(late.clock), reset)
        try a.library.mergeCloudState(late)
        XCTAssertTrue(a.library.recentSearchSelections.isEmpty)
        XCTAssertTrue(a.library.recentSearches.isEmpty)
        try b.library.mergeCloudState(clear)
        let fresh = SearchSelection.track(libraryTestTrack("after-observing-clear"))
        XCTAssertTrue(b.library.recordSearchSelection(fresh))
        b.library.recordSearch("Fresh query")
        let freshState = try b.state()
        XCTAssertEqual(freshState.registers[LibrarySyncKey(.searchSelection, fresh.id)]?.generation, reset)
        try a.library.mergeCloudState(freshState)
        try a.library.mergeCloudState(late)
        XCTAssertEqual(a.library.recentSearchSelections, [fresh])
        XCTAssertEqual(a.library.recentSearches, ["Fresh query"])
        XCTAssertEqual(try LibrarySyncMerge.joined(LibrarySyncMerge.joined(late, clear), freshState),
                       try LibrarySyncMerge.joined(late, LibrarySyncMerge.joined(clear, freshState)))
    }

    func testTypedFloorIsIndependentOfLegacyQueriesAndScopedToTheSearchReset() throws {
        let revision = LibrarySyncTestData.revision(2)
        var fresh = LibrarySyncState()
        fresh.searchReset = LibrarySyncTestData.revision(1)
        fresh.clock = revision
        for index in 0..<25 {
            let selection = SearchSelection.track(libraryTestTrack(String(format: "Song%02d", index)))
            fresh.put(LibrarySyncKey(.searchSelection, selection.id), value: try LibrarySyncCodec.encode(selection), revision: revision)
        }
        fresh.put(LibrarySyncKey(.search, "keep query"), value: try LibrarySyncCodec.encode("Keep query"), revision: revision)
        var old = LibrarySyncState()
        old.clock = LibrarySyncTestData.revision(100)
        old.searchFloor = LibrarySyncSearchBoundary(revision: old.clock!, key: "old query")
        old.searchSelectionFloor = LibrarySyncSearchBoundary(revision: old.clock!, key: "track:old")
        var joined = try LibrarySyncMerge.joined(old, fresh)
        XCTAssertNil(joined.searchFloor)
        XCTAssertNil(joined.searchSelectionFloor)
        let retained = try LibrarySyncTestData.rendered(joined)
        LibrarySyncMerge.compact(&joined, retaining: retained)
        let rendered = try LibrarySyncTestData.rendered(joined)
        XCTAssertEqual(rendered.recentSearchSelections.map(\.id), (0..<20).map { String(format: "track:Song%02d", $0) })
        XCTAssertEqual(rendered.recentSearches, ["Keep query"])
        XCTAssertNotNil(joined.searchSelectionFloor)
        XCTAssertNil(joined.searchFloor)
        try LibrarySyncValidation.validate(joined, now: LibrarySyncTestData.now)
    }

    func testSearchFloorsCompactSeparatelyAndNeverDropStructuralTombstones() throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device()
        let keep = SearchSelection.track(libraryTestTrack("Keep"))
        XCTAssertTrue(a.library.recordSearchSelection(keep))
        for index in 0..<65 {
            a.library.recordSearch("Query \(index)")
            let track = libraryTestTrack("removed-\(index)")
            a.library.toggleFavorite(track)
            a.library.toggleFavorite(track)
        }
        let before = try a.state()
        XCTAssertNotNil(before.searchFloor)
        XCTAssertNil(before.searchSelectionFloor)
        XCTAssertEqual(a.library.recentSearchSelections, [keep])
        for index in 0..<100 {
            let selection = SearchSelection.track(libraryTestTrack("temporary-\(index)"))
            XCTAssertTrue(a.library.recordSearchSelection(selection))
            XCTAssertTrue(a.library.removeRecentSearchSelection(id: selection.id))
        }
        let retained = try a.state()
        XCTAssertEqual(a.library.recentSearchSelections, [keep])
        XCTAssertEqual(retained.registers.filter { $0.key.collection == .searchSelection }.count, 101,
                       "Newer tombstones must stay while the older live destination is retained")
        XCTAssertEqual(retained.searchFloor, before.searchFloor)
        XCTAssertEqual(retained.registers.filter { $0.key.collection == .reaction && $0.value.value == nil }.count, 65)
        XCTAssertTrue(a.library.removeRecentSearchSelection(id: keep.id))
        let compacted = try a.state()
        XCTAssertLessThanOrEqual(compacted.registers.filter { $0.key.collection == .searchSelection }.count, 40)
        XCTAssertNotNil(compacted.searchSelectionFloor)
        try a.library.mergeCloudState(retained)
        XCTAssertTrue(a.library.recentSearchSelections.isEmpty)
        XCTAssertEqual(a.library.recentSearches.count, 20)
        XCTAssertEqual(try a.state().registers.filter { $0.key.collection == .reaction && $0.value.value == nil }.count, 65)
        let beforeClear = try a.state()
        XCTAssertTrue(a.library.clearRecentSearches())
        let cleared = try a.state()
        XCTAssertNil(cleared.searchFloor)
        XCTAssertNil(cleared.searchSelectionFloor)
        try a.library.mergeCloudState(beforeClear)
        XCTAssertTrue(a.library.recentSearchSelections.isEmpty)
        XCTAssertTrue(a.library.recentSearches.isEmpty)
    }

    func testFortyNewerRemovalsCannotEvictAnOlderLiveDestinationAcrossRestartOrMerge() throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device()
        let keep = SearchSelection.track(libraryTestTrack("Keep"))
        XCTAssertTrue(a.library.recordSearchSelection(keep))
        var stale: LibrarySyncState?
        for index in 0..<40 {
            let selection = SearchSelection.track(libraryTestTrack("Temporary-\(index)"))
            XCTAssertTrue(a.library.recordSearchSelection(selection))
            if index == 0 { stale = try a.state() }
            XCTAssertTrue(a.library.removeRecentSearchSelection(id: selection.id))
            XCTAssertEqual(a.library.recentSearchSelections, [keep])
        }
        XCTAssertEqual(try a.state().registers.filter { $0.key.collection == .searchSelection }.count, 41)
        let reopened = LibraryStore(directory: a.directory, now: { LibrarySyncTestData.now })
        XCTAssertNil(reopened.errorMessage)
        try reopened.mergeCloudState(XCTUnwrap(stale))
        XCTAssertEqual(reopened.recentSearchSelections, [keep])
        let b = harness.device(LibrarySyncTestData.b)
        try b.library.mergeCloudState(a.state())
        XCTAssertEqual(b.library.recentSearchSelections, [keep])
    }

    func testRemoteSelectionApplicationIsDurableAndNeverEchoesALocalSelectionOrReplacesPlayback() throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device()
        let b = harness.device(LibrarySyncTestData.b)
        let selected = SearchSelection.track(libraryTestTrack("remote-selection"))
        let playing = libraryTestTrack("local-queue")
        a.library.updatePlayback(PlaybackSnapshot(queue: [playing], position: 35))
        XCTAssertTrue(b.library.recordSearchSelection(selected))
        var localEdits = 0
        var applied = 0
        a.library.onSyncChange = { localEdits += 1 }
        a.library.onCloudSyncApplied = { [weak a] _, _ in
            applied += 1
            XCTAssertEqual(try? a?.saved().recentSearchSelections, [selected])
        }
        XCTAssertTrue(try a.library.mergeCloudState(b.state()))
        XCTAssertEqual(localEdits, 0)
        XCTAssertEqual(applied, 1)
        XCTAssertEqual(a.library.playback.queue, [playing])
        XCTAssertEqual(a.library.playback.position, 35)
        let bytes = try Data(contentsOf: a.fileURL)
        XCTAssertFalse(try a.library.mergeCloudState(b.state()))
        XCTAssertEqual(applied, 1)
        XCTAssertEqual(try Data(contentsOf: a.fileURL), bytes)
    }

    func testPreparedMergeRejectsEveryNewSelectionMutationIncludingAnIdenticalPromotion() async throws {
        for operation in 0..<4 {
            let harness = LibrarySyncTestHarness()
            defer { harness.remove() }
            let a = harness.device()
            let b = harness.device(LibrarySyncTestData.b)
            let selection = SearchSelection.track(libraryTestTrack("selected"))
            XCTAssertTrue(a.library.recordSearchSelection(selection))
            b.library.preferences.appearance = .light
            let prepared = try await a.library.prepareCloudMerge(b.state())
            switch operation {
            case 0: XCTAssertTrue(a.library.recordSearchSelection(.track(libraryTestTrack("new"))))
            case 1: XCTAssertTrue(a.library.recordSearchSelection(selection))
            case 2: XCTAssertTrue(a.library.removeRecentSearchSelection(id: selection.id))
            default: XCTAssertTrue(a.library.clearRecentSearches())
            }
            let expected = a.library.recentSearchSelections
            let reset = a.library.searchHistoryResetRevision
            let bytes = try Data(contentsOf: a.fileURL)
            XCTAssertThrowsError(try a.library.applyCloudMerge(prepared)) {
                XCTAssertEqual($0 as? LibrarySyncError, .localChangedDuringSync)
            }
            XCTAssertEqual(a.library.preferences.appearance, .dark)
            XCTAssertEqual(a.library.recentSearchSelections, expected)
            XCTAssertEqual(a.library.searchHistoryResetRevision, reset)
            XCTAssertEqual(try Data(contentsOf: a.fileURL), bytes)
        }
    }

    func testFailedRemoteSelectionWriteDoesNotApplyAndRetryPreservesBothDevicesSelections() throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device()
        let b = harness.device(LibrarySyncTestData.b)
        let local = SearchSelection.track(libraryTestTrack("local"))
        let remote = SearchSelection.track(libraryTestTrack("remote"))
        XCTAssertTrue(a.library.recordSearchSelection(local))
        XCTAssertTrue(b.library.recordSearchSelection(remote))
        let incoming = try b.state()
        let bytes = try Data(contentsOf: a.fileURL)
        let backup = a.directory.appendingPathComponent("saved.json")
        try FileManager.default.moveItem(at: a.fileURL, to: backup)
        try FileManager.default.createDirectory(at: a.fileURL, withIntermediateDirectories: false)
        var applied = 0
        a.library.onCloudSyncApplied = { _, _ in applied += 1 }
        XCTAssertThrowsError(try a.library.mergeCloudState(incoming))
        XCTAssertEqual(applied, 0)
        XCTAssertEqual(a.library.recentSearchSelections, [local])
        XCTAssertEqual(try Data(contentsOf: backup), bytes)
        try FileManager.default.removeItem(at: a.fileURL)
        try FileManager.default.moveItem(at: backup, to: a.fileURL)
        XCTAssertTrue(try a.library.mergeCloudState(incoming))
        XCTAssertEqual(applied, 1)
        XCTAssertEqual(Set(a.library.recentSearchSelections), Set([local, remote]))
        XCTAssertEqual(try a.saved().recentSearchSelections, a.library.recentSearchSelections)
    }

    func testVersionOneReplicaAndJournalUpgradeWithoutRestampingRevisionsOrInventingSelections() throws {
        let query = "Beyoncé"
        let revision = LibrarySyncTestData.revision(7)
        var state = try LibrarySyncTestData.single(.search, SearchHistory.key(query), value: query, revision: revision)
        state.searchReset = LibrarySyncTestData.revision(3)
        state.searchFloor = LibrarySyncSearchBoundary(revision: LibrarySyncTestData.revision(4), key: "old query")
        state.historyReset = LibrarySyncTestData.revision(1)
        state.historyRetirement = LibrarySyncTestData.revision(2)
        state.registers[LibrarySyncKey(.search, SearchHistory.key(query))]?.generation = state.searchReset
        state.version = 1
        let replica = LibrarySyncReplica(version: 1, replicaID: LibrarySyncTestData.b, state: state)
        let bytes = try LibrarySyncCodec.encodeReplica(replica)
        let decoded = try LibrarySyncCodec.decodeReplica(bytes, expectedReplicaID: replica.replicaID, now: LibrarySyncTestData.now)
        XCTAssertEqual(decoded.version, LibrarySyncReplica.currentVersion)
        XCTAssertEqual(decoded.state.version, LibrarySyncState.currentVersion)
        XCTAssertEqual(decoded.state.clock, revision)
        XCTAssertEqual(decoded.state.registers, state.registers)
        XCTAssertEqual(decoded.state.searchReset, state.searchReset)
        XCTAssertEqual(decoded.state.searchFloor, state.searchFloor)
        XCTAssertEqual(decoded.state.historyReset, state.historyReset)
        XCTAssertEqual(decoded.state.historyRetirement, state.historyRetirement)
        XCTAssertNil(decoded.state.searchSelectionFloor)
        let rendered = try LibrarySyncTestData.rendered(decoded.state)
        XCTAssertEqual(rendered.recentSearches, [query])
        XCTAssertTrue(rendered.recentSearchSelections.isEmpty)
        let upgradedBytes = try LibrarySyncCodec.encodeReplica(decoded)
        XCTAssertGreaterThan(try JSONDecoder().decode(LibraryPersistence.VersionHeader.self, from: upgradedBytes).version, 1,
                             "A version-one reader must reject this envelope before decoding new namespaces")
    }

    func testInconsistentLocalSelectionOrderAndMetadataCannotBeRepairedByAWrite() throws {
        for changesMetadata in [false, true] {
            let harness = LibrarySyncTestHarness()
            defer { harness.remove() }
            let a = harness.device()
            XCTAssertTrue(a.library.recordSearchSelection(.track(libraryTestTrack("a"))))
            XCTAssertTrue(a.library.recordSearchSelection(.track(libraryTestTrack("b"))))
            var document = try a.saved()
            if changesMetadata { document.recentSearchSelections[0] = .track(Track(id: "b", title: "Unjournalled title")) }
            else { document.recentSearchSelections.reverse() }
            let bytes = try LibraryPersistence.encode(document)
            try bytes.write(to: a.fileURL, options: .atomic)
            let reopened = LibraryStore(directory: a.directory, now: { LibrarySyncTestData.now })
            XCTAssertTrue(reopened.requiresReload)
            XCTAssertFalse(reopened.clearRecentSearches())
            XCTAssertEqual(try Data(contentsOf: a.fileURL), bytes)
        }
    }

    func testUnsupportedSyncVersionsAndTypedPayloadsInLegacyVersionsAreRejected() throws {
        let selection = SearchSelection.track(libraryTestTrack("recording"))
        let state = try LibrarySyncTestData.single(.searchSelection, selection.id, value: selection,
                                                   revision: LibrarySyncTestData.revision(1))
        let replica = LibrarySyncReplica(replicaID: LibrarySyncTestData.b, state: state)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: LibrarySyncCodec.encodeReplica(replica)) as? [String: Any])
        for version in [0, 1] {
            for changesEnvelope in [false, true] {
                var invalid = object
                if changesEnvelope {
                    invalid["version"] = version
                } else {
                    var journal = try XCTUnwrap(invalid["state"] as? [String: Any])
                    journal["version"] = version
                    invalid["state"] = journal
                }
                let bytes = try JSONSerialization.data(withJSONObject: invalid, options: .sortedKeys)
                XCTAssertThrowsError(try LibrarySyncCodec.decodeReplica(bytes, expectedReplicaID: replica.replicaID, now: LibrarySyncTestData.now)) {
                    if version == 0 { XCTAssertEqual($0 as? LibrarySyncError, .unsupportedVersion) }
                    else {
                        guard let error = $0 as? LibrarySyncError, case .invalidData = error else {
                            return XCTFail("A legacy schema cannot claim typed selection payloads: \($0)")
                        }
                    }
                }
            }
        }
    }

    func testMalformedKeysFloorsPayloadsAndRetiredMetadataRejectTheEntireMerge() throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device()
        let kept = SearchSelection.track(libraryTestTrack("keep"))
        XCTAssertTrue(a.library.recordSearchSelection(kept))
        let original = try Data(contentsOf: a.fileURL)
        let revision = LibrarySyncTestData.revision(1)
        let valid = try LibrarySyncTestData.single(.searchSelection, kept.id, value: kept, revision: revision)
        var invalids: [LibrarySyncState] = []
        var wrongID = valid
        wrongID.registers = [LibrarySyncKey(.searchSelection, "track:other"): try XCTUnwrap(valid.registers.values.first)]
        invalids.append(wrongID)
        var invalidTombstone = valid
        invalidTombstone.put(LibrarySyncKey(.searchSelection, "collection:unknown:ID"), value: nil, revision: revision)
        invalids.append(invalidTombstone)
        var floor = valid
        floor.searchSelectionFloor = LibrarySyncSearchBoundary(revision: revision, key: "not a destination")
        invalids.append(floor)
        var generation = valid
        generation.registers[LibrarySyncKey(.searchSelection, kept.id)]?.generation = LibrarySyncTestData.revision(2)
        invalids.append(generation)
        let snapshot = SearchSelection.collection(MusicCollection(id: "album", title: "Album", kind: .album, tracks: [libraryTestTrack()]))
        invalids.append(try LibrarySyncTestData.single(.searchSelection, snapshot.id, value: snapshot, revision: revision))

        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: LibrarySyncCodec.encode(kept)) as? [String: Any])
        var trackCase = try XCTUnwrap(payload["track"] as? [String: Any])
        var track = try XCTUnwrap(trackCase["_0"] as? [String: Any])
        track["audioURL"] = "https://r1.googlevideo.com/videoplayback?sig=private"
        trackCase["_0"] = track
        payload["track"] = trackCase
        var retired = valid
        retired.clock = LibrarySyncTestData.revision(5)
        retired.searchReset = retired.clock
        retired.registers[LibrarySyncKey(.searchSelection, kept.id)]?.value = try JSONSerialization.data(withJSONObject: payload)
        invalids.append(retired)
        for invalid in invalids {
            XCTAssertThrowsError(try a.library.mergeCloudState(invalid))
            XCTAssertEqual(a.library.recentSearchSelections, [kept])
            XCTAssertEqual(try Data(contentsOf: a.fileURL), original)
        }
    }

    func testFutureEnvelopeJournalAndUnknownNamespacePreserveCloudFilesAndReportNewerVersion() async throws {
        let selection = SearchSelection.track(libraryTestTrack("remote"))
        let state = try LibrarySyncTestData.single(.searchSelection, selection.id, value: selection,
                                                   revision: LibrarySyncTestData.revision(1))
        let replica = LibrarySyncReplica(replicaID: LibrarySyncTestData.b, state: state)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: LibrarySyncCodec.encodeReplica(replica)) as? [String: Any])
        var futureEnvelope = object
        futureEnvelope["version"] = LibrarySyncReplica.currentVersion + 1
        var futureJournal = object
        var journal = try XCTUnwrap(object["state"] as? [String: Any])
        journal["version"] = LibrarySyncState.currentVersion + 1
        futureJournal["state"] = journal
        var unknownNamespace = object
        journal = try XCTUnwrap(object["state"] as? [String: Any])
        var registers = try XCTUnwrap(journal["registers"] as? [[String: Any]])
        var key = try XCTUnwrap(registers[0]["key"] as? [String: Any])
        key["collection"] = "futureSearchDestination"
        registers[0]["key"] = key
        journal["registers"] = registers
        unknownNamespace["state"] = journal
        for invalid in [futureEnvelope, futureJournal, unknownNamespace] {
            let bytes = try JSONSerialization.data(withJSONObject: invalid, options: .sortedKeys)
            XCTAssertThrowsError(try LibrarySyncCodec.decodeReplica(bytes, expectedReplicaID: replica.replicaID, now: LibrarySyncTestData.now)) {
                XCTAssertEqual($0 as? LibrarySyncError, .newerVersion)
            }
            let harness = LibrarySyncTestHarness()
            defer { harness.remove() }
            let a = harness.device()
            let kept = SearchSelection.track(libraryTestTrack("local"))
            XCTAssertTrue(a.library.recordSearchSelection(kept))
            let original = try Data(contentsOf: a.fileURL)
            harness.cloud.accounts["account-a"] = [replica.replicaID: bytes]
            await a.sync.syncNow()
            XCTAssertEqual(a.sync.errorMessage, LibrarySyncError.newerVersion.localizedDescription)
            XCTAssertNil(a.sync.lastSyncDate)
            XCTAssertEqual(a.transport.publicationAttempts, 0)
            XCTAssertEqual(harness.cloud.accounts["account-a"], [replica.replicaID: bytes])
            XCTAssertEqual(a.library.recentSearchSelections, [kept])
            XCTAssertEqual(try Data(contentsOf: a.fileURL), original)
        }
    }
}

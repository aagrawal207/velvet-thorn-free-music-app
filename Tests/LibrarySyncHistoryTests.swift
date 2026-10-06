import XCTest
@testable import GanaBajana

@MainActor
final class LibrarySyncHistoryTests: XCTestCase {
    func testTwoDevicesDeduplicateAnAcknowledgedSessionAndKeepTheMaximumCumulativeTime() throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device()
        let b = harness.device(LibrarySyncTestData.b)
        let session = UUID()
        let song = libraryTestTrack()
        XCTAssertTrue(a.library.recordListening(track: song, sessionID: session, startedAt: LibrarySyncTestData.now, seconds: 20))
        try b.library.mergeCloudState(a.state())
        XCTAssertTrue(a.library.recordListening(track: song, sessionID: session, startedAt: LibrarySyncTestData.now, seconds: 15))
        XCTAssertTrue(b.library.recordListening(track: song, sessionID: session, startedAt: LibrarySyncTestData.now, seconds: 5))
        let aOffline = try a.state()
        let bOffline = try b.state()
        try a.library.mergeCloudState(bOffline)
        try b.library.mergeCloudState(aOffline)
        for store in [a.library, b.library] {
            XCTAssertEqual(store.events.count, 1)
            XCTAssertEqual(store.events.first?.id, session)
            XCTAssertEqual(store.events.first?.listenedSeconds, 35)
            XCTAssertEqual(store.lifetimeListeningSummary.seconds, 35)
            XCTAssertEqual(store.lifetimeListeningSummary.plays, 1)
            try store.mergeCloudState(bOffline)
            XCTAssertEqual(store.events.first?.listenedSeconds, 35)
            XCTAssertEqual(store.lifetimeListeningSummary.seconds, 35)
        }
        XCTAssertEqual(try a.saved().events.first?.listenedSeconds, 35)
    }

    func testClearBarrierDefeatsLateOfflineSessionsRecentsAndGeneratedMixesButAllowsFreshSessions() throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device()
        let b = harness.device(LibrarySyncTestData.b)
        let old = UUID()
        let song = libraryTestTrack()
        XCTAssertTrue(a.library.recordListening(track: song, sessionID: old, startedAt: LibrarySyncTestData.now, seconds: 20))
        a.library.recordRecent(track: song, position: 20)
        a.library.saveMix(GeneratedPlaylist(kind: .dailyMix, tracks: [song], generatedAt: LibrarySyncTestData.now, periodKey: "before", seedArtists: []))
        a.library.toggleFavorite(song)
        let baseline = try a.state()
        try b.library.mergeCloudState(baseline)
        a.library.clearHistory()
        let clear = try a.state()
        harness.clock.advance(by: 3600)
        XCTAssertTrue(b.library.recordListening(track: song, sessionID: old, startedAt: LibrarySyncTestData.now, seconds: 50))
        XCTAssertTrue(b.library.recordListening(track: song, sessionID: UUID(), startedAt: harness.clock.now, seconds: 10))
        b.library.recordRecent(track: song, position: 70)
        b.library.saveMix(GeneratedPlaylist(kind: .dailyMix, tracks: [song], generatedAt: harness.clock.now, periodKey: "offline-after-clear", seedArtists: []))
        let lateOffline = try b.state()
        XCTAssertGreaterThan(try XCTUnwrap(lateOffline.clock), try XCTUnwrap(clear.clock))
        try a.library.mergeCloudState(lateOffline)
        try b.library.mergeCloudState(clear)
        for store in [a.library, b.library] {
            XCTAssertTrue(store.events.isEmpty)
            XCTAssertTrue(store.recentlyPlayed.isEmpty)
            XCTAssertTrue(store.mixes.isEmpty)
            XCTAssertEqual(store.lifetimeListeningSummary, LifetimeListeningSummary())
            XCTAssertTrue(store.isFavorite(song))
        }
        let fresh = UUID()
        XCTAssertTrue(b.library.recordListening(track: song, sessionID: fresh, startedAt: harness.clock.now, seconds: 3))
        try a.library.mergeCloudState(b.state())
        try a.library.mergeCloudState(baseline)
        XCTAssertEqual(a.library.events.map(\.id), [fresh])
        XCTAssertEqual(a.library.events.first?.listenedSeconds, 3)
        XCTAssertEqual(a.library.lifetimeListeningSummary.seconds, 3)
        XCTAssertEqual(try a.saved().syncState?.historyReset, clear.historyReset)
    }

    func testClearWhileEmptyEstablishesADurableBoundaryAndCallsBackOnlyAfterTheWrite() throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device()
        var callbacks = 0
        a.library.onHistoryCleared = { [weak a] in
            callbacks += 1
            XCTAssertNotNil(try? a?.saved().syncState?.historyReset)
        }
        a.library.clearHistory()
        XCTAssertEqual(callbacks, 1)
        let boundary = try XCTUnwrap(a.saved().syncState?.historyReset)
        let restarted = LibraryStore(directory: a.directory, now: { LibrarySyncTestData.now })
        XCTAssertTrue(restarted.events.isEmpty)
        XCTAssertEqual(try restarted.cloudReplica(replicaID: a.id).state.historyReset, boundary)
    }

    func testFailedClearMergeCannotRetirePendingPlayerTimeOrAcknowledgeTheBoundary() throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device()
        let b = harness.device(LibrarySyncTestData.b)
        XCTAssertTrue(a.library.recordListening(track: libraryTestTrack(), sessionID: UUID(), startedAt: LibrarySyncTestData.now, seconds: 20))
        try b.library.mergeCloudState(a.state())
        b.library.clearHistory()
        var resets = 0
        a.library.onHistoryCleared = { [weak a] in
            resets += 1
            XCTAssertEqual(try? a?.saved().events.count, 0)
        }
        let backup = a.directory.appendingPathComponent("backup.json")
        try FileManager.default.moveItem(at: a.fileURL, to: backup)
        try FileManager.default.createDirectory(at: a.fileURL, withIntermediateDirectories: false)
        XCTAssertThrowsError(try a.library.mergeCloudState(b.state()))
        XCTAssertEqual(resets, 0)
        XCTAssertEqual(a.library.events.first?.listenedSeconds, 20)
        XCTAssertEqual(a.library.lifetimeListeningSummary.seconds, 20)
        try FileManager.default.removeItem(at: a.fileURL)
        try FileManager.default.moveItem(at: backup, to: a.fileURL)
        try a.library.mergeCloudState(b.state())
        XCTAssertEqual(resets, 1)
        XCTAssertTrue(a.library.events.isEmpty)
        XCTAssertEqual(a.library.lifetimeListeningSummary, LifetimeListeningSummary())
        try a.library.mergeCloudState(b.state())
        XCTAssertEqual(resets, 1)
    }

    func testHistoryDisablePreservesSavedDataAndRetiresPendingDeltasEvenAfterRemoteReenable() throws {
        for reenable in [false, true] {
            let harness = LibrarySyncTestHarness()
            defer { harness.remove() }
            let a = harness.device()
            let b = harness.device(LibrarySyncTestData.b)
            let song = libraryTestTrack()
            let session = UUID()
            XCTAssertTrue(a.library.recordListening(track: song, sessionID: session, startedAt: LibrarySyncTestData.now, seconds: 20))
            a.library.recordRecent(track: song, position: 17)
            try b.library.mergeCloudState(a.state())
            var buffer = PlaybackListeningBuffer()
            XCTAssertTrue(buffer.append(ListeningEvent(id: session, track: song, startedAt: LibrarySyncTestData.now, listenedSeconds: 8)))
            var resets = 0
            a.library.onHistoryCleared = { resets += 1; buffer.discard() }
            b.library.preferences.saveListeningHistory = false
            if reenable { b.library.preferences.saveListeningHistory = true }
            try a.library.mergeCloudState(b.state())
            XCTAssertEqual(resets, 1)
            XCTAssertTrue(buffer.checkpoints.isEmpty)
            XCTAssertEqual(a.library.preferences.saveListeningHistory, reenable)
            XCTAssertEqual(a.library.events.first?.listenedSeconds, 20)
            XCTAssertEqual(a.library.lifetimeListeningSummary.seconds, 20)
            XCTAssertEqual(a.library.recentlyPlayed.first?.position, 17)
            XCTAssertNil(try a.state().historyReset)
            XCTAssertNotNil(try a.state().historyRetirement)
        }
    }

    func testRetentionCompactsJournalPayloadsAndStaleReplicasCannotRestoreExpiredHistory() throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device()
        let song = libraryTestTrack()
        a.library.toggleFavorite(song)
        a.library.toggleFavorite(song)
        let tombstone = try a.state().registers[LibrarySyncKey(.reaction, song.id)]
        var remote = LibrarySyncState()
        let recentID = UUID()
        let expiredID = UUID()
        for (index, event) in [
            ListeningEvent(id: recentID, track: song, startedAt: LibrarySyncTestData.now, listenedSeconds: 20),
            ListeningEvent(id: expiredID, track: song, startedAt: LibrarySyncTestData.now.addingTimeInterval(-700 * 86_400), listenedSeconds: 50)
        ].enumerated() {
            let revision = LibrarySyncTestData.revision(Int64(index + 10), writer: LibrarySyncTestData.b)
            remote.clock = revision
            remote.put(LibrarySyncKey(.event, event.id.uuidString), value: try LibrarySyncCodec.encode(event), revision: revision)
        }
        try a.library.mergeCloudState(remote)
        XCTAssertEqual(a.library.events.map(\.id), [recentID])
        XCTAssertNil(try a.state().registers[LibrarySyncKey(.event, expiredID.uuidString)])
        XCTAssertEqual(try a.state().registers[LibrarySyncKey(.reaction, song.id)], tombstone)
        try a.library.mergeCloudState(remote)
        XCTAssertEqual(a.library.events.map(\.id), [recentID])
        XCTAssertEqual(try a.state().registers.filter { $0.key.collection == .event }.count, 1)
        XCTAssertEqual(try a.state().registers.filter { $0.key.collection == .lifetimeSession }.count, 2)
        XCTAssertEqual(a.library.lifetimeListeningSummary.seconds, 70)
    }

    func testLongCurrentStreakRetainsOneActualOlderSessionPerDayAcrossSync() throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device()
        var remote = LibrarySyncState()
        for day in 1...450 {
            for count in 0..<2 {
                let revision = LibrarySyncTestData.revision(Int64(day * 2 + count), writer: LibrarySyncTestData.b)
                remote.clock = revision
                let event = ListeningEvent(id: UUID(), track: libraryTestTrack(),
                                           startedAt: LibrarySyncTestData.now.addingTimeInterval(Double(-day) * 86_400), listenedSeconds: 30)
                remote.put(LibrarySyncKey(.event, event.id.uuidString), value: try LibrarySyncCodec.encode(event), revision: revision)
            }
        }
        try a.library.mergeCloudState(remote)
        XCTAssertEqual(a.library.events.count, 850)
        XCTAssertEqual(a.library.summary(for: .week, now: LibrarySyncTestData.now).streak, 450)
        XCTAssertEqual(try a.state().registers.filter { $0.key.collection == .event }.count, 850)
        XCTAssertEqual(a.library.lifetimeListeningSummary.seconds, 27_000)
        XCTAssertEqual(a.library.lifetimeListeningSummary.plays, 900)
        harness.clock.advance(by: 3 * 86_400)
        try a.library.mergeCloudState(remote)
        let cutoff = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -400, to: Calendar.current.startOfDay(for: harness.clock.now)))
        XCTAssertTrue(a.library.events.allSatisfy { $0.startedAt >= cutoff })
        XCTAssertEqual(a.library.lifetimeListeningSummary.seconds, 27_000)
        XCTAssertEqual(a.library.lifetimeListeningSummary.plays, 900)
    }

    func testSearchClearWhileEmptyRejectsLateOfflineQueriesAndRemovalRetainsATombstone() throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device()
        let b = harness.device(LibrarySyncTestData.b)
        a.library.clearRecentSearches()
        let clear = try a.state()
        XCTAssertNotNil(clear.searchReset)
        harness.clock.advance(by: 60)
        b.library.recordSearch("Late offline query")
        try a.library.mergeCloudState(b.state())
        XCTAssertTrue(a.library.recentSearches.isEmpty)
        try b.library.mergeCloudState(clear)
        b.library.recordSearch("New query")
        try a.library.mergeCloudState(b.state())
        let baseline = try b.state()
        XCTAssertEqual(a.library.recentSearches, ["New query"])
        a.library.removeRecentSearch("new query")
        try a.library.mergeCloudState(baseline)
        XCTAssertTrue(a.library.recentSearches.isEmpty)
        try b.library.mergeCloudState(a.state())
        XCTAssertTrue(b.library.recentSearches.isEmpty)
        XCTAssertNotNil(try a.state().registers[LibrarySyncKey(.search, "new query")])
    }

    func testSearchMutationRetentionIsBoundedWithoutDroppingStructuralTombstones() throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device()
        for index in 0..<65 {
            let track = libraryTestTrack("removed-\(index)")
            a.library.toggleFavorite(track)
            a.library.toggleFavorite(track)
        }
        for index in 0..<100 {
            a.library.recordSearch("Query \(index)")
            a.library.removeRecentSearch("Query \(index)")
        }
        let state = try a.state()
        XCTAssertLessThanOrEqual(state.registers.filter { $0.key.collection == .search }.count, 40)
        XCTAssertEqual(state.registers.filter { $0.key.collection == .reaction && $0.value.value == nil }.count, 65)
        XCTAssertNotNil(state.searchFloor)
        XCTAssertTrue(try a.saved().recentSearches.isEmpty)
    }

    func testRemovingFortyUnrelatedQueriesDoesNotEvictTheRetainedLiveQuery() throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device()
        a.library.recordSearch("Keep")
        var stale: LibrarySyncState?
        for index in 0..<40 {
            let query = "Temporary \(index)"
            a.library.recordSearch(query)
            XCTAssertLessThanOrEqual(a.library.recentSearches.count, 2)
            if index == 0 { stale = try a.state() }
            a.library.removeRecentSearch(query)
            XCTAssertEqual(a.library.recentSearches, ["Keep"])
            XCTAssertNil(a.library.errorMessage)
        }
        let retained = try a.state()
        XCTAssertEqual(retained.registers.filter { $0.key.collection == .search }.count, 41)
        let keep = try XCTUnwrap(retained.registers[LibrarySyncKey(.search, "keep")])
        if let floor = retained.searchFloor {
            XCTAssertLessThan(floor, LibrarySyncSearchBoundary(revision: keep.revision, key: "keep"))
        }
        let reopened = LibraryStore(directory: a.directory, now: { LibrarySyncTestData.now })
        XCTAssertNil(reopened.errorMessage)
        XCTAssertEqual(reopened.recentSearches, ["Keep"])
        try reopened.mergeCloudState(XCTUnwrap(stale))
        XCTAssertEqual(reopened.recentSearches, ["Keep"])
        let b = harness.device(LibrarySyncTestData.b)
        try b.library.mergeCloudState(retained)
        XCTAssertEqual(b.library.recentSearches, ["Keep"])
        reopened.removeRecentSearch("Keep")
        let cleared = try reopened.cloudReplica(replicaID: LibrarySyncTestData.a).state
        XCTAssertTrue(reopened.recentSearches.isEmpty)
        XCTAssertLessThanOrEqual(cleared.registers.filter { $0.key.collection == .search }.count, 40)
    }
}

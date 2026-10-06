import Observation
import XCTest
@testable import GanaBajana

@MainActor
final class LibraryLifetimeListeningTests: XCTestCase {
    func testV1V2V3MigrationUsesOnlySurvivingHistoryAndWaitsForARealWrite() throws {
        for version in 1...3 {
            try withLibraryTestDirectory { directory in
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let event = ListeningEvent(id: UUID(), track: libraryTestTrack(),
                    startedAt: LibrarySyncTestData.now.addingTimeInterval(-100), listenedSeconds: 35)
                let bytes = try LifetimeListeningTestData.legacyBytes(events: [event], version: version,
                                                                     journalVersion: version == 1 ? nil : version - 1)
                let file = directory.appendingPathComponent(LibraryPersistence.fileName)
                try bytes.write(to: file)
                let library = LibraryStore(directory: directory, now: { LibrarySyncTestData.now })
                XCTAssertNil(library.errorMessage)
                XCTAssertEqual(library.lifetimeListeningSummary.seconds, 35)
                XCTAssertEqual(library.lifetimeListeningSummary.plays, 1)
                XCTAssertEqual(library.lifetimeListeningSummary.coverageStartedAt, event.startedAt)
                XCTAssertEqual(try Data(contentsOf: file), bytes)
                XCTAssertEqual(library.durableCommitCount, 0)
                library.toggleFavorite(event.track)
                let saved = try LibraryPersistence.decode(Data(contentsOf: file), now: LibrarySyncTestData.now)
                XCTAssertEqual(saved.version, LibraryPersistence.currentVersion)
                XCTAssertEqual(saved.lifetimeListening.summary.seconds, 35)
                if version > 1 {
                    XCTAssertEqual(saved.syncState?.registers[LibrarySyncKey(.event, event.id.uuidString)]?.revision,
                                   LibrarySyncTestData.revision(0))
                }
            }
        }
    }

    func testSyncAndAsyncEqualSizedDeltasCrossQualificationExactlyOnce() async throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let library = harness.device().library
        let event = ListeningEvent(id: UUID(), track: libraryTestTrack(), startedAt: harness.clock.now, listenedSeconds: 10)
        XCTAssertTrue(library.recordListening(track: event.track, sessionID: event.id, startedAt: event.startedAt, seconds: 10))
        XCTAssertTrue(library.recordListening(track: event.track, sessionID: event.id, startedAt: event.startedAt, seconds: 10))
        let acknowledged = await library.recordListeningCheckpoint(events: [event])
        XCTAssertTrue(acknowledged)
        XCTAssertEqual(library.lifetimeListeningSummary.seconds, 30)
        XCTAssertEqual(library.lifetimeListeningSummary.plays, 1)
        let prepared = try await library.prepareListeningCheckpoint(events: [event])
        XCTAssertTrue(try library.applyListeningCheckpoint(prepared))
        XCTAssertThrowsError(try library.applyListeningCheckpoint(prepared))
        XCTAssertEqual(library.lifetimeListeningSummary.seconds, 40)
        XCTAssertEqual(library.lifetimeListeningSummary.plays, 1)
    }

    func testRetentionAndRelaunchKeepTotalsAndLateDeltaUsesPrunedReceipt() throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device()
        let event = ListeningEvent(id: UUID(), track: libraryTestTrack(), startedAt: harness.clock.now, listenedSeconds: 35)
        XCTAssertTrue(a.library.recordListening(track: event.track, sessionID: event.id, startedAt: event.startedAt, seconds: 35))
        harness.clock.advance(by: 500 * 86_400)
        let reopened = LibraryStore(directory: a.directory, now: { [clock = harness.clock] in clock.now })
        XCTAssertTrue(reopened.events.isEmpty)
        XCTAssertEqual(reopened.lifetimeListeningSummary.seconds, 35)
        XCTAssertTrue(reopened.recordListening(track: event.track, sessionID: event.id, startedAt: event.startedAt, seconds: 5))
        XCTAssertTrue(reopened.events.isEmpty)
        XCTAssertEqual(reopened.lifetimeListeningSummary.seconds, 40)
        XCTAssertEqual(reopened.lifetimeListeningSummary.plays, 1)
        let again = LibraryStore(directory: a.directory, now: { [clock = harness.clock] in clock.now })
        XCTAssertEqual(again.lifetimeListeningSummary, reopened.lifetimeListeningSummary)
        XCTAssertNil(again.errorMessage)
    }

    func testMigrationFoldsExpiredHistoryBeforeStartupRetention() throws {
        try withLibraryTestDirectory { directory in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let event = ListeningEvent(id: UUID(), track: libraryTestTrack(),
                startedAt: LibrarySyncTestData.now.addingTimeInterval(-700 * 86_400), listenedSeconds: 65)
            try LifetimeListeningTestData.legacyBytes(events: [event], version: 3, journalVersion: 2)
                .write(to: directory.appendingPathComponent(LibraryPersistence.fileName))
            let library = LibraryStore(directory: directory, now: { LibrarySyncTestData.now })
            XCTAssertNil(library.errorMessage)
            XCTAssertTrue(library.events.isEmpty)
            XCTAssertEqual(library.lifetimeListeningSummary.seconds, 65)
            XCTAssertEqual(library.lifetimeListeningSummary.coverageStartedAt, event.startedAt)
        }
    }

    func testDisabledHistoryAcknowledgesWithoutAddingTimeAndClearResetsCoverage() async throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device()
        let event = ListeningEvent(id: UUID(), track: libraryTestTrack(), startedAt: harness.clock.now, listenedSeconds: 35)
        XCTAssertTrue(a.library.recordListening(track: event.track, sessionID: event.id, startedAt: event.startedAt, seconds: 35))
        a.library.preferences.saveListeningHistory = false
        let epoch = a.library.listeningHistoryEpoch
        XCTAssertNotNil(epoch)
        let before = a.library.lifetimeListeningSummary
        XCTAssertTrue(a.library.recordListening(track: event.track, sessionID: event.id, startedAt: event.startedAt, seconds: 100))
        let acknowledged = await a.library.recordListeningCheckpoint(events: [event])
        XCTAssertTrue(acknowledged)
        XCTAssertEqual(a.library.lifetimeListeningSummary, before)
        a.library.clearHistory()
        XCTAssertNotEqual(a.library.listeningHistoryEpoch, epoch)
        XCTAssertEqual(a.library.lifetimeListeningSummary, LifetimeListeningSummary())
        XCTAssertEqual(try a.saved().lifetimeListening.summary, LifetimeListeningSummary())
    }

    func testFailedWriteAndIdentityMismatchPublishNoRollupOrRevision() async throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device()
        let event = ListeningEvent(id: UUID(), track: libraryTestTrack(), startedAt: harness.clock.now, listenedSeconds: 35)
        XCTAssertTrue(a.library.recordListening(track: event.track, sessionID: event.id, startedAt: event.startedAt, seconds: 35))
        let before = a.library.lifetimeListeningSummary
        let revision = a.library.lifetimeListeningRevision
        XCTAssertFalse(a.library.recordListening(track: libraryTestTrack("wrong"), sessionID: event.id,
                                                startedAt: event.startedAt, seconds: 5))
        let prepared = try await a.library.prepareListeningCheckpoint(events: [event])
        let backup = a.directory.appendingPathComponent("backup.json")
        try FileManager.default.moveItem(at: a.fileURL, to: backup)
        try FileManager.default.createDirectory(at: a.fileURL, withIntermediateDirectories: false)
        XCTAssertFalse(a.library.recordListening(track: event.track, sessionID: event.id,
                                                startedAt: event.startedAt, seconds: 5))
        XCTAssertThrowsError(try a.library.applyListeningCheckpoint(prepared))
        XCTAssertEqual(a.library.lifetimeListeningSummary, before)
        XCTAssertEqual(a.library.lifetimeListeningRevision, revision)
        try FileManager.default.removeItem(at: a.fileURL)
        try FileManager.default.moveItem(at: backup, to: a.fileURL)
        XCTAssertTrue(try a.library.applyListeningCheckpoint(prepared))
        XCTAssertEqual(a.library.lifetimeListeningSummary.seconds, 70)
        XCTAssertEqual(a.library.lifetimeListeningSummary.plays, 1)
    }

    func testClearRetiresPreparedCheckpointAndFailedClearKeepsDurableTotals() async throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device()
        let event = ListeningEvent(id: UUID(), track: libraryTestTrack(), startedAt: harness.clock.now, listenedSeconds: 35)
        XCTAssertTrue(a.library.recordListening(track: event.track, sessionID: event.id, startedAt: event.startedAt, seconds: 35))
        let prepared = try await a.library.prepareListeningCheckpoint(events: [event])
        let before = try Data(contentsOf: a.fileURL)
        try Data("external change".utf8).write(to: a.fileURL)
        a.library.clearHistory()
        XCTAssertEqual(a.library.lifetimeListeningSummary.seconds, 35)
        try before.write(to: a.fileURL)
        XCTAssertEqual(a.library.reloadFromDisk(), .reloaded)
        a.library.clearHistory()
        XCTAssertThrowsError(try a.library.applyListeningCheckpoint(prepared))
        XCTAssertEqual(a.library.lifetimeListeningSummary.seconds, 0)
    }

    func testPlaybackOnlyPublicationDoesNotInvalidateLifetimeSlice() throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device()
        let revision = a.library.lifetimeListeningRevision
        a.library.updatePlayback(PlaybackSnapshot(queue: [libraryTestTrack()], position: 10))
        XCTAssertEqual(a.library.lifetimeListeningRevision, revision)
        XCTAssertEqual(a.library.lifetimeListeningSummary, LifetimeListeningSummary())
    }

    func testAsyncRebaseCountsTheCapturedDeltaOnlyOnce() async throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let gate = AsyncListeningCheckpointGate()
        let library = LibraryStore(directory: harness.root, now: { LibrarySyncTestData.now },
            beforeListeningCheckpointPreparation: { await gate.enter(wasMainThread: checkpointPreparationIsOnMainThread()) })
        let event = ListeningEvent(id: UUID(), track: libraryTestTrack(), startedAt: LibrarySyncTestData.now, listenedSeconds: 35)
        let pending = Task { await library.recordListeningCheckpoint(events: [event]) }
        await gate.waitForEntry()
        XCTAssertEqual(library.lifetimeListeningSummary.seconds, 0)
        library.toggleFavorite(event.track)
        await gate.release()
        let accepted = await pending.value
        XCTAssertTrue(accepted)
        XCTAssertEqual(library.lifetimeListeningSummary.seconds, 35)
        XCTAssertEqual(library.lifetimeListeningSummary.plays, 1)
        let attempts = await gate.attempts
        XCTAssertEqual(attempts, 2)
        XCTAssertTrue(library.isFavorite(event.track))
    }

    func testAsyncSummaryProjectionIsPreparedBeforeApplyAndSkippedForPlaybackOnly() async throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let library = harness.device().library
        let event = ListeningEvent(id: UUID(), track: libraryTestTrack(), startedAt: LibrarySyncTestData.now, listenedSeconds: 35)
        let listening = try await library.prepareListeningCheckpoint(events: [event])
        XCTAssertTrue(listening.lifetimeChanged)
        let projection = try XCTUnwrap(listening.lifetimePublication)
        XCTAssertEqual(projection.summary.seconds, 35)
        XCTAssertEqual(projection.summary.plays, 1)
        XCTAssertFalse(projection.hasFutureReceipts)
        XCTAssertEqual(library.lifetimeListeningSummary.seconds, 0)
        XCTAssertTrue(try library.applyListeningCheckpoint(listening))
        XCTAssertEqual(library.lifetimeListeningSummary, projection.summary)
        let revision = library.lifetimeListeningRevision
        let playback = try await library.prepareListeningCheckpoint(events: [],
            snapshot: PlaybackSnapshot(queue: [event.track], position: 10))
        XCTAssertFalse(playback.lifetimeChanged)
        XCTAssertNil(playback.lifetimePublication)
        XCTAssertTrue(try library.applyListeningCheckpoint(playback))
        XCTAssertEqual(library.playback.position, 10)
        XCTAssertEqual(library.lifetimeListeningSummary, projection.summary)
        XCTAssertEqual(library.lifetimeListeningRevision, revision)
    }
}

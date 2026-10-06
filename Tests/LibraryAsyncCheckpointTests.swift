import Foundation
import Observation
import XCTest
@testable import GanaBajana

@MainActor
final class LibraryAsyncCheckpointTests: XCTestCase {
    func testHeldPreparationLeavesMainActorResponsiveAndPublishesOnlyAfterDurability() async throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let gate = AsyncListeningCheckpointGate()
        let library = makeLibrary(harness, gate)
        let event = event()
        var notified = false
        withObservationTracking { _ = library.events } onChange: {
            MainActor.assumeIsolated {
                notified = true
                let reopened = LibraryStore(directory: harness.root, now: { LibrarySyncTestData.now })
                XCTAssertEqual(reopened.events.first?.listenedSeconds, 5)
                XCTAssertEqual(reopened.recentlyPlayed.first?.position, 12)
                XCTAssertEqual(reopened.playback.position, 12)
            }
        }
        let work = Task { await library.recordListeningCheckpoint(events: [event],
            recent: RecentListen(track: event.track, playedAt: LibrarySyncTestData.now, position: 12),
            snapshot: PlaybackSnapshot(queue: [event.track], position: 12, originalQueue: [event.track])) }
        await gate.waitForEntry()
        let heartbeat = await Task { @MainActor in 42 }.value
        XCTAssertEqual(heartbeat, 42)
        let onMain = await gate.enteredOnMainThread
        XCTAssertFalse(onMain, "The preparation hook runs on the detached executor")
        XCTAssertFalse(notified)
        XCTAssertTrue(library.events.isEmpty)
        XCTAssertEqual(library.durableCommitCount, 0)
        do {
            _ = try await library.prepareListeningCheckpoint(events: [event])
            XCTFail("A second detached preparation must not be admitted")
        } catch LibraryListeningCheckpointError.busy { }
        await gate.release()
        let acknowledged = await work.value
        XCTAssertTrue(acknowledged)
        XCTAssertTrue(notified)
        XCTAssertEqual(library.durableCommitCount, 1)
        XCTAssertEqual(library.lastListeningCheckpointMetrics?.outcome, "committed")
        XCTAssertGreaterThan(library.listeningCheckpointMainActorMilliseconds, 0)
    }

    func testSharedMutationRebasesWithoutLosingFavoriteOrDoublingDelta() async throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let gate = AsyncListeningCheckpointGate()
        let library = makeLibrary(harness, gate)
        let event = event()
        let work = Task { await library.recordListeningCheckpoint(events: [event],
            snapshot: PlaybackSnapshot(queue: [event.track], position: 12, originalQueue: [event.track])) }
        await gate.waitForEntry()
        library.toggleFavorite(event.track)
        await gate.release()
        let acknowledged = await work.value
        XCTAssertTrue(acknowledged)
        let attempts = await gate.attempts
        XCTAssertEqual(attempts, 2)
        XCTAssertTrue(library.isFavorite(event.track))
        XCTAssertEqual(library.events.first?.listenedSeconds, 5)
        XCTAssertEqual(library.playback.position, 12)
        XCTAssertEqual(library.durableCommitCount, 2)
    }

    func testDeviceOnlyMutationAndNewerRecentSurviveRebase() async throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let gate = AsyncListeningCheckpointGate()
        let library = makeLibrary(harness, gate)
        let event = event()
        let work = Task { await library.recordListeningCheckpoint(events: [event],
            recent: RecentListen(track: event.track, playedAt: LibrarySyncTestData.now, position: 12),
            snapshot: PlaybackSnapshot(queue: [event.track], position: 12, originalQueue: [event.track])) }
        await gate.waitForEntry()
        let newer = libraryTestTrack("newer")
        library.updatePlayback(PlaybackSnapshot(queue: [newer], position: 88, originalQueue: [newer]))
        library.recordRecent(track: newer, position: 88)
        XCTAssertTrue(library.recordTip(transactionID: 1, credited: true))
        await gate.release()
        let acknowledged = await work.value
        XCTAssertTrue(acknowledged)
        XCTAssertEqual(library.playback.queue, [newer])
        XCTAssertEqual(library.playback.position, 88)
        XCTAssertEqual(library.recentlyPlayed.map(\.id), [newer.id])
        XCTAssertEqual(library.tipCount, 1)
        XCTAssertEqual(library.events.first?.listenedSeconds, 5)
    }

    func testClearAndDisableRetireCaptureEvenAfterHistoryIsReenabled() async throws {
        for disable in [false, true] {
            let harness = LibrarySyncTestHarness()
            defer { harness.remove() }
            let gate = AsyncListeningCheckpointGate()
            let library = makeLibrary(harness, gate)
            let event = event()
            let work = Task { await library.recordListeningCheckpoint(events: [event]) }
            await gate.waitForEntry()
            if disable {
                library.preferences.saveListeningHistory = false
                library.preferences.saveListeningHistory = true
            } else { library.clearHistory() }
            await gate.release()
            let acknowledged = await work.value
            XCTAssertFalse(acknowledged)
            XCTAssertTrue(library.events.isEmpty)
            XCTAssertEqual(library.historyRevision, 0)
            XCTAssertTrue(LibraryStore(directory: harness.root, now: { LibrarySyncTestData.now }).events.isEmpty)
        }
    }

    func testReloadAndAccountBoundaryRetirePreparedWork() async throws {
        for reload in [false, true] {
            let harness = LibrarySyncTestHarness()
            defer { harness.remove() }
            let gate = AsyncListeningCheckpointGate()
            let library = makeLibrary(harness, gate)
            XCTAssertTrue(library.recordTip(transactionID: 1, credited: true))
            let event = event()
            let work = Task { await library.recordListeningCheckpoint(events: [event]) }
            await gate.waitForEntry()
            if reload { XCTAssertEqual(library.reloadFromDisk(), .reloaded) }
            else {
                let sync = ICloudLibrarySync(library: library, transport: LibrarySyncTestTransport(cloud: harness.cloud),
                                            configuration: LibrarySyncTestConfiguration(replicaID: LibrarySyncTestData.a))
                sync.setEnabled(false)
            }
            await gate.release()
            let acknowledged = await work.value
            XCTAssertFalse(acknowledged)
            XCTAssertTrue(library.events.isEmpty)
            let retried = await library.recordListeningCheckpoint(events: [event])
            XCTAssertTrue(retried)
            XCTAssertEqual(library.events.first?.listenedSeconds, 5)
        }
    }

    func testPreparedApplyRejectsPlaybackOnlyChangeAndDuplicateApplication() async throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let library = LibraryStore(directory: harness.root, now: { LibrarySyncTestData.now })
        let event = event()
        let stale = try await library.prepareListeningCheckpoint(events: [event])
        library.updatePlayback(PlaybackSnapshot(queue: [event.track], position: 99, originalQueue: [event.track]))
        XCTAssertThrowsError(try library.applyListeningCheckpoint(stale)) { error in
            guard case LibraryListeningCheckpointError.stale = error else { return XCTFail("Expected a stale preparation") }
        }
        XCTAssertTrue(library.events.isEmpty)
        let current = try await library.prepareListeningCheckpoint(events: [event])
        XCTAssertTrue(try library.applyListeningCheckpoint(current))
        XCTAssertThrowsError(try library.applyListeningCheckpoint(current))
        XCTAssertEqual(library.events.first?.listenedSeconds, 5)
        XCTAssertEqual(library.playback.position, 99)
    }

    func testStaleRebasesStopAfterThreePreparationsAndRemainRetryable() async throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let gate = AsyncListeningCheckpointGate(heldAttempts: [1, 2, 3])
        let library = makeLibrary(harness, gate)
        let event = event()
        let work = Task { await library.recordListeningCheckpoint(events: [event]) }
        for attempt in 1...3 {
            await gate.waitForEntry(attempt)
            XCTAssertTrue(library.recordTip(transactionID: UInt64(attempt), credited: true))
            await gate.release(attempt)
        }
        let acknowledged = await work.value
        XCTAssertFalse(acknowledged)
        XCTAssertTrue(library.events.isEmpty)
        let attempts = await gate.attempts
        XCTAssertEqual(attempts, 3)
        let retried = await library.recordListeningCheckpoint(events: [event])
        XCTAssertTrue(retried)
        XCTAssertEqual(library.events.first?.listenedSeconds, 5)
    }

    func testFailedAtomicWriteKeepsBothRecordsRetryable() async throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let gate = AsyncListeningCheckpointGate()
        let library = makeLibrary(harness, gate)
        XCTAssertTrue(library.recordTip(transactionID: 1, credited: true))
        let event = event()
        let snapshot = PlaybackSnapshot(queue: [event.track], position: 12, originalQueue: [event.track])
        let work = Task { await library.recordListeningCheckpoint(events: [event], snapshot: snapshot) }
        await gate.waitForEntry()
        let file = harness.root.appendingPathComponent(LibraryPersistence.fileName)
        let backup = harness.root.appendingPathComponent("backup.json")
        try FileManager.default.moveItem(at: file, to: backup)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        await gate.release()
        let acknowledged = await work.value
        XCTAssertFalse(acknowledged)
        XCTAssertTrue(library.events.isEmpty)
        XCTAssertTrue(library.playback.queue.isEmpty)
        XCTAssertEqual(library.durableCommitCount, 1)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: backup, to: file)
        let retried = await library.recordListeningCheckpoint(events: [event], snapshot: snapshot)
        XCTAssertTrue(retried)
        XCTAssertEqual(library.events.first?.listenedSeconds, 5)
        XCTAssertEqual(library.playback.position, 12)
        XCTAssertEqual(library.durableCommitCount, 2)
    }

    func testForeignWriterIsPreservedAndReloadAllowsOneRetry() async throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let gate = AsyncListeningCheckpointGate()
        let library = makeLibrary(harness, gate)
        let event = event()
        let work = Task { await library.recordListeningCheckpoint(events: [event]) }
        await gate.waitForEntry()
        let other = LibraryStore(directory: harness.root, now: { LibrarySyncTestData.now })
        other.toggleFavorite(event.track)
        await gate.release()
        let acknowledged = await work.value
        XCTAssertFalse(acknowledged)
        XCTAssertTrue(library.requiresReload)
        XCTAssertTrue(library.events.isEmpty)
        XCTAssertEqual(library.durableCommitCount, 0)
        XCTAssertTrue(LibraryStore(directory: harness.root, now: { LibrarySyncTestData.now }).isFavorite(event.track))
        XCTAssertEqual(library.reloadFromDisk(), .reloaded)
        let retried = await library.recordListeningCheckpoint(events: [event])
        XCTAssertTrue(retried)
        XCTAssertTrue(library.isFavorite(event.track))
        XCTAssertEqual(library.events.first?.listenedSeconds, 5)
    }

    func testBatchCommitsMultipleSessionsRecentAndSnapshotWithOnlyTargetedRegisters() async throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let library = LibraryStore(directory: harness.root, now: { LibrarySyncTestData.now })
        library.toggleFavorite(libraryTestTrack("untouched"))
        let before = try library.cloudReplica(replicaID: LibrarySyncTestData.a).state
        let first = event()
        let second = event()
        let commits = library.durableCommitCount
        let acknowledged = await library.recordListeningCheckpoint(events: [first, second],
            recent: RecentListen(track: second.track, playedAt: LibrarySyncTestData.now, position: 12),
            snapshot: PlaybackSnapshot(queue: [first.track, second.track], currentIndex: 1, position: 12,
                                       originalQueue: [first.track, second.track], originalQueueIndices: [0, 1]))
        XCTAssertTrue(acknowledged)
        XCTAssertEqual(library.durableCommitCount, commits + 1)
        XCTAssertEqual(library.events.count, 2)
        XCTAssertEqual(library.events.reduce(0) { $0 + $1.listenedSeconds }, 10)
        let after = try library.cloudReplica(replicaID: LibrarySyncTestData.a).state
        let expected: Set<LibrarySyncKey> = [LibrarySyncKey(.event, first.id.uuidString), LibrarySyncKey(.event, second.id.uuidString),
                                           LibrarySyncKey(.recent, second.track.id),
                                           LibrarySyncKey(.lifetimeSession, first.id.uuidString), LibrarySyncKey(.lifetimeSession, second.id.uuidString)]
        let changed = Set(before.registers.keys).union(after.registers.keys).filter { before.registers[$0] != after.registers[$0] }
        XCTAssertEqual(Set(changed), expected)
        let reopened = LibraryStore(directory: harness.root, now: { LibrarySyncTestData.now })
        XCTAssertNil(reopened.errorMessage)
        XCTAssertEqual(reopened.events.count, 2)
        XCTAssertEqual(reopened.lifetimeListeningSummary.seconds, 10)
        XCTAssertEqual(reopened.playback.originalQueueIndices, [0, 1])
        XCTAssertEqual(reopened.playback.currentIndex, 1)
    }

    func testDisabledHistoryAcknowledgesWithoutBackfillingAndStillSavesPlayback() async throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let library = LibraryStore(directory: harness.root, now: { LibrarySyncTestData.now })
        library.preferences.saveListeningHistory = false
        let event = event()
        let commits = library.durableCommitCount
        let noOp = await library.recordListeningCheckpoint(events: [event])
        XCTAssertTrue(noOp)
        XCTAssertEqual(library.durableCommitCount, commits)
        let snapshot = PlaybackSnapshot(queue: [event.track], position: 12, originalQueue: [event.track])
        let acknowledged = await library.recordListeningCheckpoint(events: [event],
            recent: RecentListen(track: event.track, playedAt: LibrarySyncTestData.now, position: 12), snapshot: snapshot)
        XCTAssertTrue(acknowledged)
        XCTAssertTrue(library.events.isEmpty)
        XCTAssertTrue(library.recentlyPlayed.isEmpty)
        XCTAssertEqual(library.playback.position, 12)
        XCTAssertEqual(library.durableCommitCount, commits + 1)
    }

    func testInvalidAsyncSessionAndDuplicateBatchRejectAllFields() async throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let library = LibraryStore(directory: harness.root, now: { LibrarySyncTestData.now })
        let saved = event()
        XCTAssertTrue(library.recordListening(track: saved.track, sessionID: saved.id, startedAt: saved.startedAt, seconds: 5))
        let commits = library.durableCommitCount
        var wrong = saved
        wrong.track = libraryTestTrack("different")
        for batch in [[wrong], [saved, saved]] {
            let acknowledged = await library.recordListeningCheckpoint(events: batch,
                recent: RecentListen(track: wrong.track, playedAt: LibrarySyncTestData.now, position: 99),
                snapshot: PlaybackSnapshot(queue: [wrong.track], position: 99, originalQueue: [wrong.track]))
            XCTAssertFalse(acknowledged)
            XCTAssertEqual(library.durableCommitCount, commits)
            XCTAssertEqual(library.events.first?.listenedSeconds, 5)
            XCTAssertEqual(library.events.first?.track, saved.track)
            XCTAssertTrue(library.recentlyPlayed.isEmpty)
            XCTAssertTrue(library.playback.queue.isEmpty)
        }
    }

    private func makeLibrary(_ harness: LibrarySyncTestHarness, _ gate: AsyncListeningCheckpointGate) -> LibraryStore {
        LibraryStore(directory: harness.root, now: { LibrarySyncTestData.now }, beforeListeningCheckpointPreparation: {
            await gate.enter(wasMainThread: checkpointPreparationIsOnMainThread())
        })
    }

    private func event() -> ListeningEvent {
        ListeningEvent(id: UUID(), track: libraryTestTrack("async"), startedAt: LibrarySyncTestData.now, listenedSeconds: 5)
    }
}

nonisolated func checkpointPreparationIsOnMainThread() -> Bool { Thread.isMainThread }

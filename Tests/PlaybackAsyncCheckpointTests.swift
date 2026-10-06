import Foundation
import XCTest
@testable import GanaBajana

@MainActor
final class PlaybackAsyncCheckpointTests: XCTestCase {
    func testProductionDrainAcknowledgesCapturedDeltaAndPreservesSecondsAppendedDuringAwait() async throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let gate = AsyncListeningCheckpointGate()
        let library = heldLibrary(harness, gate)
        let player = PlayerController(resolver: AppModelStreamResolver(), listeningCheckpointLimit: 1)
        let model = asyncCheckpointModel(library: library, player: player)
        defer { stopAsyncCheckpointPlayer(player); withExtendedLifetime(model) {} }
        player.onListeningProgress = { _, _, _, _ in XCTFail("Production drain must not call the synchronous saver"); return false }
        player.onSnapshotChanged = { _ in XCTFail("Production checkpoints must not save snapshots synchronously") }
        let installed = try XCTUnwrap(player.onListeningCheckpoint)
        var delivered: [[ListeningEvent]] = []
        player.onListeningCheckpoint = { checkpoint in
            delivered.append(checkpoint.events)
            return await installed(checkpoint)
        }
        let event = event()
        player.restore(PlaybackSnapshot(queue: [event.track], originalQueue: [event.track]))
        XCTAssertTrue(player.enqueueListeningCheckpoint(event))
        player.flushListeningProgress()
        await gate.waitForEntry()
        XCTAssertEqual(player.pendingListeningCheckpoints.first?.listenedSeconds, 5)
        XCTAssertTrue(library.events.isEmpty)
        player.flushListeningProgress()
        player.flushListeningProgress()
        XCTAssertEqual(delivered.count, 1)
        var more = event
        more.listenedSeconds = 3
        XCTAssertTrue(player.enqueueListeningCheckpoint(more))
        XCTAssertFalse(player.enqueueListeningCheckpoint(self.event()), "An in-flight capture still occupies its bounded session slot")
        player.flushListeningProgress()
        await gate.release()
        await player.waitForListeningCheckpointDelivery()
        XCTAssertTrue(player.pendingListeningCheckpoints.isEmpty)
        XCTAssertEqual(delivered.flatMap { $0 }.map(\.listenedSeconds), [5, 3])
        XCTAssertEqual(Set(delivered.flatMap { $0 }.map(\.id)), [event.id])
        XCTAssertEqual(library.events.count, 1)
        XCTAssertEqual(library.events.first?.listenedSeconds, 8)
        XCTAssertEqual(library.playback.queue, [event.track])
        let preparations = await gate.attempts
        XCTAssertEqual(preparations, 2, "Unchanged flushes must coalesce without invalidating an in-flight snapshot")
        let reopened = LibraryStore(directory: harness.root, now: { LibrarySyncTestData.now })
        XCTAssertEqual(reopened.events.first?.listenedSeconds, 8)
    }

    func testOlderSessionRetryPreservesRecentAndNewestSnapshotOccurrenceOrder() async throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let gate = AsyncListeningCheckpointGate()
        let library = heldLibrary(harness, gate)
        let event = event()
        library.recordRecent(track: event.track, position: 8)
        let player = PlayerController(resolver: AppModelStreamResolver())
        let model = asyncCheckpointModel(library: library, player: player)
        defer { stopAsyncCheckpointPlayer(player); withExtendedLifetime(model) {} }
        player.restore(PlaybackSnapshot(queue: [event.track], position: 8, originalQueue: [event.track]))
        XCTAssertTrue(player.enqueueListeningCheckpoint(event))
        player.flushListeningProgress()
        await gate.waitForEntry()
        let newer = libraryTestTrack("newer")
        let latest = PlaybackSnapshot(queue: [newer, event.track], position: 88, shuffleEnabled: true,
                                      originalQueue: [event.track, newer], originalQueueIndices: [1, 0])
        player.restore(latest)
        await gate.release()
        await player.waitForListeningCheckpointDelivery()
        XCTAssertEqual(library.events.first?.id, event.id)
        XCTAssertEqual(library.events.first?.listenedSeconds, 5)
        XCTAssertEqual(library.recentlyPlayed.first { $0.id == event.track.id }?.position, 8)
        XCTAssertEqual(library.playback.queue, latest.queue)
        XCTAssertEqual(library.playback.originalQueueIndices, [1, 0])
        XCTAssertEqual(library.playback.position, 88)
    }

    func testProductionPrivacyClearAndDisableDiscardHeldGeneration() async throws {
        for disable in [false, true] {
            let harness = LibrarySyncTestHarness()
            defer { harness.remove() }
            let gate = AsyncListeningCheckpointGate()
            let library = heldLibrary(harness, gate)
            let player = PlayerController(resolver: AppModelStreamResolver())
            let model = asyncCheckpointModel(library: library, player: player)
            defer { stopAsyncCheckpointPlayer(player); withExtendedLifetime(model) {} }
            let retired = event()
            XCTAssertTrue(player.enqueueListeningCheckpoint(retired))
            player.flushListeningProgress()
            await gate.waitForEntry()
            if disable { model.updatePreferences { $0.saveListeningHistory = false } }
            else { library.clearHistory() }
            XCTAssertTrue(player.pendingListeningCheckpoints.isEmpty)
            if disable { model.updatePreferences { $0.saveListeningHistory = true } }
            let fresh = event()
            XCTAssertTrue(player.enqueueListeningCheckpoint(fresh))
            player.flushListeningProgress()
            await gate.release()
            await player.waitForListeningCheckpointDelivery()
            XCTAssertEqual(library.events.map(\.id), [fresh.id])
            XCTAssertTrue(player.pendingListeningCheckpoints.isEmpty)
            player.flushListeningProgress()
            await player.waitForListeningCheckpointDelivery()
            XCTAssertEqual(library.events.map(\.id), [fresh.id])
            XCTAssertEqual(library.events.first?.listenedSeconds, 5)
        }
    }

    func testFailedAsyncDeliveryRetainsBufferAndRetriesAllSecondsOnce() async throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let library = LibraryStore(directory: harness.root, now: { LibrarySyncTestData.now })
        let player = PlayerController(resolver: AppModelStreamResolver())
        let model = asyncCheckpointModel(library: library, player: player)
        defer { stopAsyncCheckpointPlayer(player); withExtendedLifetime(model) {} }
        let installed = try XCTUnwrap(player.onListeningCheckpoint)
        player.onListeningCheckpoint = { _ in false }
        let event = event()
        XCTAssertTrue(player.enqueueListeningCheckpoint(event))
        player.flushListeningProgress()
        await player.waitForListeningCheckpointDelivery()
        XCTAssertEqual(player.pendingListeningCheckpoints.first?.listenedSeconds, 5)
        XCTAssertTrue(library.events.isEmpty)
        var more = event
        more.listenedSeconds = 3
        XCTAssertTrue(player.enqueueListeningCheckpoint(more))
        player.onListeningCheckpoint = installed
        player.flushListeningProgress()
        await player.waitForListeningCheckpointDelivery()
        XCTAssertTrue(player.pendingListeningCheckpoints.isEmpty)
        XCTAssertEqual(library.events.first?.listenedSeconds, 8)
        player.flushListeningProgress()
        await player.waitForListeningCheckpointDelivery()
        XCTAssertEqual(library.events.first?.listenedSeconds, 8)
    }

    func testBackgroundLeaseExpirationBeforeApplyKeepsPendingDelta() async throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let gate = AsyncListeningCheckpointGate()
        let library = heldLibrary(harness, gate)
        let player = PlayerController(resolver: AppModelStreamResolver())
        let model = asyncCheckpointModel(library: library, player: player)
        defer { stopAsyncCheckpointPlayer(player); withExtendedLifetime(model) {} }
        let event = event()
        XCTAssertTrue(player.enqueueListeningCheckpoint(event))
        player.handleLifecycleCheckpoint()
        await gate.waitForEntry()
        player.handleListeningCheckpointExpiration()
        await gate.release()
        await player.waitForListeningCheckpointDelivery()
        XCTAssertEqual(player.pendingListeningCheckpoints.first?.listenedSeconds, 5)
        XCTAssertTrue(library.events.isEmpty)
        player.handleLifecycleCheckpoint()
        await player.waitForListeningCheckpointDelivery()
        XCTAssertTrue(player.pendingListeningCheckpoints.isEmpty)
        XCTAssertEqual(library.events.first?.listenedSeconds, 5)
    }

    func testCancellationAfterDurabilityStillAcknowledgesCapturedDelta() async throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let library = LibraryStore(directory: harness.root, now: { LibrarySyncTestData.now })
        let gate = AsyncListeningCheckpointGate()
        let player = PlayerController(resolver: AppModelStreamResolver())
        let model = asyncCheckpointModel(library: library, player: player)
        defer { stopAsyncCheckpointPlayer(player); withExtendedLifetime(model) {} }
        let installed = try XCTUnwrap(player.onListeningCheckpoint)
        player.onListeningCheckpoint = { checkpoint in
            let acknowledged = await installed(checkpoint)
            await gate.enter(wasMainThread: checkpointPreparationIsOnMainThread())
            return acknowledged
        }
        XCTAssertTrue(player.enqueueListeningCheckpoint(event()))
        player.flushListeningProgress()
        await gate.waitForEntry()
        XCTAssertEqual(library.events.first?.listenedSeconds, 5)
        XCTAssertFalse(player.pendingListeningCheckpoints.isEmpty)
        player.handleListeningCheckpointExpiration()
        await gate.release()
        await player.waitForListeningCheckpointDelivery()
        XCTAssertTrue(player.pendingListeningCheckpoints.isEmpty)
        XCTAssertEqual(library.events.first?.listenedSeconds, 5)
    }

    func testRealPlaybackPauseDrainsLastSecondsAndSnapshotThroughProductionAsyncWiring() async throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let audio = try PlaybackTestSupport.audioFile(seconds: 10)
        defer { try? FileManager.default.removeItem(at: audio.deletingLastPathComponent()) }
        let gate = AsyncListeningCheckpointGate()
        let library = LibraryStore(directory: harness.root, beforeListeningCheckpointPreparation: {
            await gate.enter(wasMainThread: checkpointPreparationIsOnMainThread())
        })
        let player = PlayerController(resolver: PlaybackFileResolver(url: audio, duration: 10))
        let model = asyncCheckpointModel(library: library, player: player)
        defer { stopAsyncCheckpointPlayer(player); withExtendedLifetime(model) {} }
        player.onListeningProgress = { _, _, _, _ in XCTFail("Unexpected synchronous listening save"); return false }
        player.onSnapshotChanged = { _ in XCTFail("Unexpected synchronous snapshot save") }
        player.play([libraryTestTrack("audio")])
        await gate.waitForEntry()
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.position > 0.7 }
        player.pause()
        let position = player.position
        XCTAssertFalse(player.pendingListeningCheckpoints.isEmpty)
        XCTAssertTrue(library.events.isEmpty)
        await gate.release()
        await player.waitForListeningCheckpointDelivery()
        XCTAssertFalse(player.isPlaying)
        XCTAssertTrue(player.pendingListeningCheckpoints.isEmpty)
        let seconds = library.events.reduce(0) { $0 + $1.listenedSeconds }
        XCTAssertGreaterThan(seconds, 0.5)
        XCTAssertLessThanOrEqual(seconds, position + 0.05)
        XCTAssertEqual(library.playback.position, position, accuracy: 0.05)
        XCTAssertEqual(library.recentlyPlayed.first?.position ?? -1, position, accuracy: 0.05)
        let reopened = LibraryStore(directory: harness.root)
        XCTAssertEqual(reopened.events.reduce(0) { $0 + $1.listenedSeconds }, seconds, accuracy: 0.001)
    }

    func testAccountSessionGenerationChangeRejectsHeldDeliveryAndKeepsRetryableDelta() async throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let gate = AsyncListeningCheckpointGate()
        let library = heldLibrary(harness, gate)
        let player = PlayerController(resolver: AppModelStreamResolver())
        let model = asyncCheckpointModel(library: library, player: player)
        defer { stopAsyncCheckpointPlayer(player); withExtendedLifetime(model) {} }
        XCTAssertTrue(player.enqueueListeningCheckpoint(event()))
        player.flushListeningProgress()
        await gate.waitForEntry()
        let revision = model.account.sessionRevision
        XCTAssertTrue(model.account.signOut())
        XCTAssertNotEqual(model.account.sessionRevision, revision)
        await gate.release()
        await player.waitForListeningCheckpointDelivery()
        XCTAssertTrue(library.events.isEmpty)
        XCTAssertEqual(player.pendingListeningCheckpoints.first?.listenedSeconds, 5)
        player.flushListeningProgress()
        await player.waitForListeningCheckpointDelivery()
        XCTAssertTrue(player.pendingListeningCheckpoints.isEmpty)
        XCTAssertEqual(library.events.first?.listenedSeconds, 5)
    }

    func testStartupRecoveryPreservesIntentChangedBeforeAsyncDeliveryStarts() async throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let file = harness.root.appendingPathComponent(LibraryPersistence.fileName)
        var future = LibraryDocument()
        future.version = LibraryPersistence.currentVersion + 1
        let futureBytes = try LibraryPersistence.encode(future)
        try LibraryPersistence.write(futureBytes, to: file, replacing: nil)
        let library = LibraryStore(directory: harness.root, now: { LibrarySyncTestData.now })
        XCTAssertFalse(library.hasLoadedDocument)
        let player = PlayerController(resolver: AppModelStreamResolver())
        let model = asyncCheckpointModel(library: library, player: player)
        defer { stopAsyncCheckpointPlayer(player); withExtendedLifetime(model) {} }
        let chosen = libraryTestTrack("new-intent")
        player.restore(PlaybackSnapshot(queue: [chosen], position: 12, originalQueue: [chosen]))
        var repaired = LibraryDocument()
        let recovered = libraryTestTrack("recovered")
        repaired.playback = PlaybackSnapshot(queue: [recovered], position: 88, originalQueue: [recovered])
        try LibraryPersistence.write(LibraryPersistence.encode(repaired), to: file, replacing: futureBytes)
        XCTAssertEqual(model.reloadSavedLibrary(), .reloaded)
        XCTAssertEqual(player.queue, [chosen], "Intent notification must run before a same-turn recovery can restore the old queue")
        XCTAssertEqual(player.position, 12)
        await player.waitForListeningCheckpointDelivery()
        XCTAssertEqual(library.playback.queue, [chosen])
        XCTAssertEqual(library.playback.position, 12)
    }

    private func heldLibrary(_ harness: LibrarySyncTestHarness, _ gate: AsyncListeningCheckpointGate) -> LibraryStore {
        LibraryStore(directory: harness.root, now: { LibrarySyncTestData.now }, beforeListeningCheckpointPreparation: {
            await gate.enter(wasMainThread: checkpointPreparationIsOnMainThread())
        })
    }

    private func event() -> ListeningEvent {
        ListeningEvent(id: UUID(), track: libraryTestTrack("async"), startedAt: LibrarySyncTestData.now, listenedSeconds: 5)
    }
}

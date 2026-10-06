import Foundation
import XCTest
@testable import GanaBajana

@MainActor
final class PlaybackAsyncPrivacyBoundaryTests: XCTestCase {
    func testPausedSnapshotOnlySaveSurvivesClearAndDisableWithoutAnotherFlush() async throws {
        for disable in [false, true] {
            let harness = LibrarySyncTestHarness()
            defer { harness.remove() }
            let gate = AsyncListeningCheckpointGate(heldAttempts: [1, 2])
            let library = heldLibrary(harness, gate)
            let first = libraryTestTrack("first")
            let second = libraryTestTrack("second")
            library.updatePlayback(PlaybackSnapshot(queue: [first, second], position: 5, originalQueue: [first, second]))
            library.recordRecent(track: first, position: 5)
            let player = PlayerController(resolver: AppModelStreamResolver())
            let model = asyncCheckpointModel(library: library, player: player)
            defer { stopAsyncCheckpointPlayer(player); withExtendedLifetime(model) {} }
            let installed = try XCTUnwrap(player.onListeningCheckpoint)
            var deliveries: [PlaybackListeningCheckpoint] = []
            player.onListeningCheckpoint = { checkpoint in
                deliveries.append(checkpoint)
                return await installed(checkpoint)
            }
            let latest = PlaybackSnapshot(queue: [second, first], position: 42, shuffleEnabled: true,
                                          originalQueue: [first, second], originalQueueIndices: [1, 0])
            var selection = latest
            selection.position = 12
            player.restore(selection)
            player.seek(to: latest.position)
            await gate.waitForEntry()
            XCTAssertFalse(player.isPlaying)
            XCTAssertTrue(try XCTUnwrap(deliveries.first).events.isEmpty)
            XCTAssertNil(deliveries.first?.recent)
            XCTAssertEqual(library.playback.position, 5)

            if disable { model.updatePreferences { $0.saveListeningHistory = false } }
            else { library.clearHistory() }
            let commits = library.durableCommitCount
            await gate.release()
            await gate.waitForEntry(2)
            let heartbeat = await Task { @MainActor in 42 }.value
            XCTAssertEqual(heartbeat, 42)
            XCTAssertEqual(library.playback.position, 5, "The replacement snapshot has not reached durability")
            XCTAssertTrue(deliveries.dropFirst().allSatisfy { $0.events.isEmpty && $0.recent == nil })
            await gate.release(2)
            await player.waitForListeningCheckpointDelivery()

            XCTAssertEqual(library.durableCommitCount, commits + 1)
            XCTAssertEqual(library.playback.queue, latest.queue)
            XCTAssertEqual(library.playback.originalQueue, latest.originalQueue)
            XCTAssertEqual(library.playback.originalQueueIndices, [1, 0])
            XCTAssertTrue(library.playback.shuffleEnabled)
            XCTAssertEqual(library.playback.position, 42)
            XCTAssertTrue(library.events.isEmpty)
            if disable {
                XCTAssertEqual(library.recentlyPlayed.first?.position, 5)
            } else { XCTAssertTrue(library.recentlyPlayed.isEmpty) }
            let reopened = LibraryStore(directory: harness.root, now: { LibrarySyncTestData.now })
            XCTAssertEqual(reopened.playback.queue, latest.queue)
            XCTAssertEqual(reopened.playback.position, 42)
            XCTAssertNil(reopened.errorMessage)
        }
    }

    func testSuccessfulEnableRetiresHeldDisabledDeliveryButPreservesAcknowledgedAndNewEnabledTime() async throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let gate = AsyncListeningCheckpointGate()
        let library = heldLibrary(harness, gate)
        let acknowledged = event("acknowledged", seconds: 30)
        XCTAssertTrue(library.recordListening(track: acknowledged.track, sessionID: acknowledged.id,
                                              startedAt: acknowledged.startedAt, seconds: acknowledged.listenedSeconds))
        library.preferences.saveListeningHistory = false
        let player = PlayerController(resolver: AppModelStreamResolver())
        let model = asyncCheckpointModel(library: library, player: player)
        defer { stopAsyncCheckpointPlayer(player); withExtendedLifetime(model) {} }
        let installed = try XCTUnwrap(player.onListeningCheckpoint)
        var deliveries: [PlaybackListeningCheckpoint] = []
        player.onListeningCheckpoint = { checkpoint in
            deliveries.append(checkpoint)
            return await installed(checkpoint)
        }
        let disabled = event("disabled", seconds: 5)
        player.restore(PlaybackSnapshot(queue: [disabled.track], position: 12, originalQueue: [disabled.track]))
        XCTAssertTrue(player.enqueueListeningCheckpoint(disabled))
        player.flushListeningProgress()
        await gate.waitForEntry()
        let retired = try XCTUnwrap(deliveries.first)

        model.updatePreferences { $0.saveListeningHistory = true }
        XCTAssertTrue(library.preferences.saveListeningHistory)
        XCTAssertTrue(player.pendingListeningCheckpoints.isEmpty)
        XCTAssertFalse(player.isCurrentListeningCheckpointGeneration(retired))
        let enabled = event("enabled", seconds: 3)
        XCTAssertTrue(player.enqueueListeningCheckpoint(enabled))
        await gate.release()
        await player.waitForListeningCheckpointDelivery()

        XCTAssertEqual(Set(library.events.map(\.id)), [acknowledged.id, enabled.id])
        XCTAssertEqual(library.events.first { $0.id == acknowledged.id }?.listenedSeconds, 30)
        XCTAssertEqual(library.events.first { $0.id == enabled.id }?.listenedSeconds, 3)
        XCTAssertTrue(player.pendingListeningCheckpoints.isEmpty)
        XCTAssertEqual(library.playback.position, 12)
        let snapshotRecovery = try XCTUnwrap(deliveries.dropFirst().first)
        XCTAssertTrue(snapshotRecovery.events.isEmpty)
        XCTAssertNil(snapshotRecovery.recent)
        XCTAssertEqual(deliveries.dropFirst(2).flatMap(\.events).map(\.id), [enabled.id])
        player.flushListeningProgress()
        await player.waitForListeningCheckpointDelivery()
        XCTAssertNil(library.events.first { $0.id == disabled.id })
        XCTAssertEqual(library.events.first { $0.id == acknowledged.id }?.listenedSeconds, 30)
        XCTAssertEqual(library.events.first { $0.id == enabled.id }?.listenedSeconds, 3)
        XCTAssertTrue(player.pendingListeningCheckpoints.isEmpty)
    }

    func testFailedEnableKeepsPendingGenerationAndResumeIntent() async throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let gate = AsyncListeningCheckpointGate()
        let library = heldLibrary(harness, gate)
        library.preferences.saveListeningHistory = false
        let player = PlayerController(resolver: AppModelStreamResolver())
        let model = asyncCheckpointModel(library: library, player: player)
        defer { stopAsyncCheckpointPlayer(player); withExtendedLifetime(model) {} }
        let installed = try XCTUnwrap(player.onListeningCheckpoint)
        var delivered: PlaybackListeningCheckpoint?
        player.onListeningCheckpoint = { checkpoint in
            delivered = checkpoint
            return await installed(checkpoint)
        }
        let pending = event("disabled", seconds: 5)
        player.restore(PlaybackSnapshot(queue: [pending.track], position: 12, originalQueue: [pending.track]))
        XCTAssertTrue(player.enqueueListeningCheckpoint(pending))
        player.flushListeningProgress()
        await gate.waitForEntry()
        let captured = try XCTUnwrap(delivered)
        let other = LibraryStore(directory: harness.root, now: { LibrarySyncTestData.now })
        other.toggleFavorite(libraryTestTrack("foreign"))

        model.updatePreferences { $0.saveListeningHistory = true }
        XCTAssertFalse(library.preferences.saveListeningHistory)
        XCTAssertNotNil(library.errorMessage)
        XCTAssertTrue(player.isCurrentListeningCheckpointGeneration(captured))
        XCTAssertEqual(player.pendingListeningCheckpoints.first?.listenedSeconds, 5)
        await gate.release()
        await player.waitForListeningCheckpointDelivery()
        XCTAssertEqual(player.pendingListeningCheckpoints.first?.id, pending.id)
        XCTAssertEqual(player.position, 12)
        XCTAssertFalse(library.preferences.saveListeningHistory)
    }

    func testRealPlaybackEnableBetweenCheckpointsRecordsOnlyPostEnableSeconds() async throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let audio = try PlaybackTestSupport.audioFile(seconds: 12)
        defer { try? FileManager.default.removeItem(at: audio.deletingLastPathComponent()) }
        let library = LibraryStore(directory: harness.root)
        let prior = ListeningEvent(id: UUID(), track: libraryTestTrack("prior-enabled"),
                                   startedAt: Date().addingTimeInterval(-60), listenedSeconds: 30)
        XCTAssertTrue(library.recordListening(track: prior.track, sessionID: prior.id,
                                              startedAt: prior.startedAt, seconds: prior.listenedSeconds))
        library.preferences.saveListeningHistory = false
        let player = PlayerController(resolver: PlaybackFileResolver(url: audio, duration: 12))
        let model = asyncCheckpointModel(library: library, player: player)
        defer { stopAsyncCheckpointPlayer(player); withExtendedLifetime(model) {} }
        let track = libraryTestTrack("enabled-period")
        player.play([track])
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.position > 1.1 }
        await player.waitForListeningCheckpointDelivery()
        XCTAssertNil(library.events.first { $0.track.id == track.id })

        let enableBegan = Date()
        model.updatePreferences { $0.saveListeningHistory = true }
        let enabledPosition = player.position
        XCTAssertTrue(library.preferences.saveListeningHistory)
        XCTAssertTrue(player.pendingListeningCheckpoints.isEmpty)
        await player.waitForListeningCheckpointDelivery()
        XCTAssertNil(library.events.first { $0.track.id == track.id }, "Enabling must not drain disabled-period seconds under the new preference")
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.position > enabledPosition + 0.7 }
        player.pause()
        await player.waitForListeningCheckpointDelivery()

        let enabledEvents = library.events.filter { $0.track.id == track.id }
        let seconds = enabledEvents.reduce(0) { $0 + $1.listenedSeconds }
        XCTAssertEqual(Set(enabledEvents.map(\.id)).count, 1)
        XCTAssertTrue(enabledEvents.allSatisfy { $0.startedAt >= enableBegan.addingTimeInterval(-0.05) })
        XCTAssertGreaterThan(seconds, 0.5)
        XCTAssertLessThanOrEqual(seconds, player.position - enabledPosition + 0.05)
        XCTAssertEqual(library.events.first { $0.id == prior.id }?.listenedSeconds, 30)
        let reopened = LibraryStore(directory: harness.root)
        XCTAssertEqual(reopened.events.filter { $0.track.id == track.id }.reduce(0) { $0 + $1.listenedSeconds }, seconds, accuracy: 0.001)
    }

    func testClearRetiresRealCombinedRecentButAutomaticallySavesPausedPosition() async throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let audio = try PlaybackTestSupport.audioFile(seconds: 12)
        defer { try? FileManager.default.removeItem(at: audio.deletingLastPathComponent()) }
        let gate = AsyncListeningCheckpointGate(heldAttempts: [])
        let library = LibraryStore(directory: harness.root, beforeListeningCheckpointPreparation: {
            await gate.enter(wasMainThread: checkpointPreparationIsOnMainThread())
        })
        let player = PlayerController(resolver: PlaybackFileResolver(url: audio, duration: 12))
        let model = asyncCheckpointModel(library: library, player: player)
        defer { stopAsyncCheckpointPlayer(player); withExtendedLifetime(model) {} }
        let installed = try XCTUnwrap(player.onListeningCheckpoint)
        var deliveries: [PlaybackListeningCheckpoint] = []
        player.onListeningCheckpoint = { checkpoint in
            deliveries.append(checkpoint)
            return await installed(checkpoint)
        }
        player.play([libraryTestTrack("clear-playing")])
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.position > 1.1 }
        await player.waitForListeningCheckpointDelivery()
        let pausedAttempt = await gate.holdNextPreparation()
        player.pause()
        await gate.waitForEntry(pausedAttempt)
        let held = try XCTUnwrap(deliveries.last)
        XCTAssertFalse(held.events.isEmpty)
        XCTAssertNotNil(held.recent)
        let pausedPosition = player.position
        let count = deliveries.count
        let recoveryAttempt = await gate.holdNextPreparation()
        library.clearHistory()
        XCTAssertTrue(library.events.isEmpty)
        XCTAssertTrue(library.recentlyPlayed.isEmpty)
        await gate.release(pausedAttempt)
        await gate.waitForEntry(recoveryAttempt)
        XCTAssertTrue(deliveries.dropFirst(count).allSatisfy { $0.events.isEmpty && $0.recent == nil })
        await gate.release(recoveryAttempt)
        await player.waitForListeningCheckpointDelivery()

        XCTAssertEqual(library.playback.position, pausedPosition, accuracy: 0.05)
        XCTAssertTrue(library.events.isEmpty)
        XCTAssertTrue(library.recentlyPlayed.isEmpty)
        XCTAssertTrue(player.pendingListeningCheckpoints.isEmpty)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(LibraryStore(directory: harness.root).playback.position, pausedPosition, accuracy: 0.05)
    }

    func testFailedSnapshotRecoveryStopsAndKeepsTheIntentRetryable() async throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let gate = AsyncListeningCheckpointGate()
        let library = heldLibrary(harness, gate)
        let player = PlayerController(resolver: AppModelStreamResolver())
        let model = asyncCheckpointModel(library: library, player: player)
        defer { stopAsyncCheckpointPlayer(player); withExtendedLifetime(model) {} }
        let installed = try XCTUnwrap(player.onListeningCheckpoint)
        var deliveries = 0
        var rejectRecovery = true
        player.onListeningCheckpoint = { checkpoint in
            deliveries += 1
            if deliveries > 1, rejectRecovery { return false }
            return await installed(checkpoint)
        }
        let track = libraryTestTrack("paused")
        player.restore(PlaybackSnapshot(queue: [track], position: 42, originalQueue: [track]))
        await gate.waitForEntry()
        library.clearHistory()
        await gate.release()
        await player.waitForListeningCheckpointDelivery()
        XCTAssertEqual(deliveries, 2)
        XCTAssertFalse(player.isDeliveringListeningCheckpoint)
        XCTAssertEqual(library.playback.position, 0)

        rejectRecovery = false
        player.flushListeningProgress()
        await player.waitForListeningCheckpointDelivery()
        XCTAssertEqual(library.playback.position, 42)
        XCTAssertTrue(library.events.isEmpty)
        XCTAssertTrue(library.recentlyPlayed.isEmpty)
    }

    private func heldLibrary(_ harness: LibrarySyncTestHarness, _ gate: AsyncListeningCheckpointGate) -> LibraryStore {
        LibraryStore(directory: harness.root, now: { LibrarySyncTestData.now }, beforeListeningCheckpointPreparation: {
            await gate.enter(wasMainThread: checkpointPreparationIsOnMainThread())
        })
    }

    private func event(_ id: String, seconds: TimeInterval) -> ListeningEvent {
        ListeningEvent(id: UUID(), track: libraryTestTrack(id), startedAt: LibrarySyncTestData.now, listenedSeconds: seconds)
    }
}

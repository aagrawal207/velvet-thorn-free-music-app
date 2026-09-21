import Foundation
import XCTest
@testable import GanaBajana

@MainActor
final class AppModelListeningCheckpointTests: XCTestCase {
    func testRetriedOlderCheckpointPreservesThatSongsResumePosition() async throws {
        let context = try makeAudioContext()
        let previous = AppModelFixtures.track("previous-checkpoint")
        context.library.recordRecent(track: previous, position: 8)
        try await playAndPause(in: context)
        let currentPosition = context.player.position
        XCTAssertLessThan(currentPosition, 8)
        let progress = try XCTUnwrap(context.player.onListeningProgress)
        let session = UUID()

        XCTAssertTrue(progress(previous, session, Date().addingTimeInterval(-60), 2))

        let stored = LibraryStore(directory: context.directory)
        XCTAssertNil(stored.errorMessage)
        XCTAssertEqual(stored.events.first { $0.id == session }?.listenedSeconds, 2)
        XCTAssertEqual(stored.recentlyPlayed.first { $0.id == previous.id }?.position, 8)
        XCTAssertEqual(context.player.position, currentPosition)
    }

    func testConfirmedHistoryClearDiscardsUnacknowledgedListening() async throws {
        let context = try makeAudioContext()
        let installed = try XCTUnwrap(context.player.onListeningProgress)
        var rejectsSave = true
        var attempts = 0
        context.player.onListeningProgress = { track, session, started, seconds in
            attempts += 1
            return !rejectsSave && installed(track, session, started, seconds)
        }
        try await playAndPause(in: context)
        XCTAssertGreaterThan(attempts, 0)
        XCTAssertTrue(context.library.events.isEmpty)
        context.library.clearHistory()
        XCTAssertNil(context.library.errorMessage)
        let attemptsAfterClear = attempts
        rejectsSave = false
        context.player.flushListeningProgress()

        XCTAssertEqual(attempts, attemptsAfterClear, "A confirmed clear retires even checkpoints the store never acknowledged")
        XCTAssertTrue(context.library.events.isEmpty)
        XCTAssertTrue(context.library.recentlyPlayed.isEmpty)
        XCTAssertTrue(LibraryStore(directory: context.directory).events.isEmpty)
    }

    func testAppliedHistoryDisableDiscardsPreDisableFailuresBeforeHistoryIsReenabled() async throws {
        let context = try makeAudioContext()
        let installed = try XCTUnwrap(context.player.onListeningProgress)
        var rejectsSave = true
        var attempts = 0
        context.player.onListeningProgress = { track, session, started, seconds in
            attempts += 1
            return !rejectsSave && installed(track, session, started, seconds)
        }
        try await playAndPause(in: context)
        XCTAssertGreaterThan(attempts, 0)
        let attemptsBeforeDisable = attempts
        context.model.updatePreferences { $0.saveListeningHistory = false }
        XCTAssertFalse(context.library.preferences.saveListeningHistory)
        XCTAssertGreaterThan(attempts, attemptsBeforeDisable, "The pre-disable checkpoint still gets a chance to save")
        let attemptsAfterDisable = attempts
        rejectsSave = false
        context.model.updatePreferences { $0.saveListeningHistory = true }
        context.player.flushListeningProgress()

        XCTAssertEqual(attempts, attemptsAfterDisable)
        XCTAssertTrue(context.library.events.isEmpty, "Re-enabling history must not backfill a failed pre-disable checkpoint")
        let reloaded = LibraryStore(directory: context.directory)
        XCTAssertTrue(reloaded.preferences.saveListeningHistory)
        XCTAssertTrue(reloaded.events.isEmpty)
    }

    func testFailedHistoryClearKeepsTheUnacknowledgedCheckpointRetryable() async throws {
        let context = try makeAudioContext()
        var attempts = 0
        context.player.onListeningProgress = { _, _, _, _ in
            attempts += 1
            return false
        }
        context.seedHistory(AppModelFixtures.track("saved-history"))
        try await playAndPause(in: context)
        XCTAssertGreaterThan(attempts, 0)
        let otherWriter = LibraryStore(directory: context.directory)
        otherWriter.toggleFavorite(AppModelFixtures.track("external-edit"))
        XCTAssertNil(otherWriter.errorMessage)
        context.library.clearHistory()
        XCTAssertNotNil(context.library.errorMessage)
        XCTAssertFalse(context.library.events.isEmpty)
        let attemptsAfterFailure = attempts
        context.player.flushListeningProgress()

        XCTAssertGreaterThan(attempts, attemptsAfterFailure, "Only a successful clear may discard pending listening")
    }

    func testRejectedHistoryDisableDoesNotDiscardUnacknowledgedListening() async throws {
        let context = try makeAudioContext()
        var attempts = 0
        context.player.onListeningProgress = { _, _, _, _ in
            attempts += 1
            return false
        }
        try await playAndPause(in: context)
        XCTAssertGreaterThan(attempts, 0)
        let otherWriter = LibraryStore(directory: context.directory)
        otherWriter.toggleFavorite(AppModelFixtures.track("external-edit"))
        XCTAssertNil(otherWriter.errorMessage)
        context.model.updatePreferences { $0.saveListeningHistory = false }
        XCTAssertNotNil(context.library.errorMessage)
        XCTAssertTrue(context.library.preferences.saveListeningHistory)
        let attemptsAfterFailure = attempts
        context.player.flushListeningProgress()

        XCTAssertGreaterThan(attempts, attemptsAfterFailure, "Discarding follows the applied preference, not the rejected edit")
    }

    private func playAndPause(in context: AppModelTestContext) async throws {
        context.model.play(AppModelFixtures.track("local-checkpoint"))
        try await PlaybackTestSupport.waitUntil { context.player.isPlaying && context.player.position > 1.1 }
        context.player.pause()
        XCTAssertFalse(context.player.isPlaying)
    }

    private func makeAudioContext() throws -> AppModelTestContext {
        let url = try PlaybackTestSupport.audioFile(seconds: 10)
        addTeardownBlock { try FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let context = try AppModelTestContext(resolver: PlaybackFileResolver(url: url, duration: 10))
        context.model.updatePreferences { $0.autoplay = false }
        addTeardownBlock { @MainActor in try await context.close() }
        return context
    }
}

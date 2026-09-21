import XCTest
@testable import GanaBajana

@MainActor
final class PlaybackControllerTests: XCTestCase {
    private let a = Track(id: "JGwWNGJdvx8", title: "A", duration: 100)
    private let b = Track(id: "BddP6PYo2gs", title: "B", duration: 200)

    func testRestoreIsPausedAndDoesNotResolveOrRecordAStart() async throws {
        let gate = PlaybackResolutionGate()
        let player = PlayerController(resolver: gate)
        var starts: [Track] = []
        var snapshots: [PlaybackSnapshot] = []
        player.onTrackStarted = { starts.append($0) }
        player.onSnapshotChanged = { snapshots.append($0) }
        player.restore(PlaybackSnapshot(queue: [b, a], currentIndex: 1, position: 42,
                                       shuffleEnabled: true, repeatMode: .all))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(player.currentTrack, a)
        XCTAssertEqual(player.queue, [b, a])
        XCTAssertEqual(player.position, 42)
        XCTAssertTrue(player.shuffleEnabled)
        XCTAssertEqual(player.repeatMode, .all)
        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(player.isLoading)
        XCTAssertTrue(starts.isEmpty)
        XCTAssertEqual(snapshots.last?.position, 42)
        XCTAssertEqual(snapshots.last?.originalQueue, [b, a])
        let requests = await gate.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testObsoleteResolutionCannotOverwriteANewerSelectionOrError() async throws {
        let url = try PlaybackTestSupport.audioFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let gate = PlaybackResolutionGate()
        let player = PlayerController(resolver: gate)
        player.play([a])
        let first = try await PlaybackTestSupport.waitForRequests(1, on: gate)[0]
        player.play([b])
        XCTAssertEqual(player.currentTrack, b)
        XCTAssertTrue(player.isLoading)
        let second = try await PlaybackTestSupport.waitForRequests(2, on: gate)[1]
        await gate.finish(second, with: .failure(MusicServiceError.unavailable("Current failure")))
        try await PlaybackTestSupport.waitUntil { player.errorMessage == "Current failure" }
        await gate.finish(first, with: .success(ResolvedStream(url: url, duration: 8)))
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(player.currentTrack, b)
        XCTAssertEqual(player.errorMessage, "Current failure")
        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(player.isLoading)
        player.pause()
    }

    func testPauseAndRemovingCurrentCancelPendingAutoplay() async throws {
        let gate = PlaybackResolutionGate()
        let player = PlayerController(resolver: gate)
        player.play([a, b])
        let first = try await PlaybackTestSupport.waitForRequests(1, on: gate)[0]
        player.pause()
        player.removeFromQueue(at: 0)
        XCTAssertEqual(player.currentTrack, b)
        XCTAssertFalse(player.isLoading)
        await gate.finish(first, with: .failure(MusicServiceError.unavailable("Late error")))
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertNil(player.errorMessage)
        XCTAssertFalse(player.isPlaying)
        let requests = await gate.requests
        XCTAssertEqual(requests.count, 1)
        player.removeFromQueue(at: 0)
        XCTAssertNil(player.currentTrack)
        XCTAssertTrue(player.queue.isEmpty)
        XCTAssertEqual(player.position, 0)
    }

    func testQueueReorderDuringResolutionKeepsCurrentOccurrence() async throws {
        let gate = PlaybackResolutionGate()
        let player = PlayerController(resolver: gate)
        player.play([a, b], startingAt: 1)
        let request = try await PlaybackTestSupport.waitForRequests(1, on: gate)[0]
        player.moveQueue(from: IndexSet(integer: 1), to: 0)
        XCTAssertEqual(player.currentTrack, b)
        XCTAssertEqual(player.currentIndex, 0)
        await gate.finish(request, with: .failure(MusicServiceError.unavailable("Same selection")))
        try await PlaybackTestSupport.waitUntil { player.errorMessage == "Same selection" }
        player.pause()
    }

    func testExplicitPauseDuringInterruptionPreventsShouldResume() async throws {
        let gate = PlaybackResolutionGate()
        let player = PlayerController(resolver: gate)
        player.play([a])
        _ = try await PlaybackTestSupport.waitForRequests(1, on: gate)
        player.handleInterruption(began: true)
        player.pause()
        player.handleInterruption(began: false, shouldResume: true)
        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(player.isLoading)
        await gate.cancelRemaining()
    }

    func testRouteDetachAlsoPausesAnExtractionThatHasNotStartedPlaying() async throws {
        let gate = PlaybackResolutionGate()
        let player = PlayerController(resolver: gate)
        player.play([a])
        _ = try await PlaybackTestSupport.waitForRequests(1, on: gate)
        player.handleRouteDetached()
        XCTAssertFalse(player.isLoading)
        XCTAssertFalse(player.isPlaying)
        await gate.cancelRemaining()
    }

    func testSleepTimerIgnoresAnObsoleteDeadlineAndPausesAtCurrentDeadline() async throws {
        let gate = PlaybackResolutionGate()
        let player = PlayerController(resolver: gate)
        player.play([a])
        _ = try await PlaybackTestSupport.waitForRequests(1, on: gate)
        player.setSleepTimer(minutes: 1)
        let old = try XCTUnwrap(player.sleepUntil)
        player.setSleepTimer(minutes: 2)
        let current = try XCTUnwrap(player.sleepUntil)
        player.expireSleepTimer(expected: old, now: current.addingTimeInterval(1))
        XCTAssertEqual(player.sleepUntil, current)
        XCTAssertTrue(player.isLoading)
        player.expireSleepTimer(expected: current, now: current.addingTimeInterval(1))
        XCTAssertNil(player.sleepUntil)
        XCTAssertFalse(player.isLoading)
        await gate.cancelRemaining()
    }

    func testPausedMediaResetPreservesPositionWithoutAutoplay() async {
        let gate = PlaybackResolutionGate()
        let player = PlayerController(resolver: gate)
        player.restore(PlaybackSnapshot(queue: [a], position: 40))
        player.handleMediaServicesReset()
        XCTAssertEqual(player.position, 40)
        XCTAssertFalse(player.isLoading)
        XCTAssertFalse(player.isPlaying)
        let requests = await gate.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testExpiredBackgroundTransitionCancelsPendingPlaybackAndSurfacesFailure() async throws {
        let gate = PlaybackResolutionGate()
        let player = PlayerController(resolver: gate)
        player.play([a])
        _ = try await PlaybackTestSupport.waitForRequests(1, on: gate)
        player.handleBackgroundTransitionExpired()
        XCTAssertNotNil(player.errorMessage)
        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(player.isLoading)
        await gate.cancelRemaining()
    }

    func testPlayerSnapshotsRestorePreShuffleOrderWithoutAutoplay() throws {
        let gate = PlaybackResolutionGate()
        let player = PlayerController(resolver: gate)
        let original = [a, b, a]
        player.restore(PlaybackSnapshot(queue: original, currentIndex: 1, position: 20))
        var snapshot: PlaybackSnapshot?
        player.onSnapshotChanged = { snapshot = $0 }
        player.toggleShuffle()
        let saved = try XCTUnwrap(snapshot)
        XCTAssertEqual(saved.originalQueue, original)
        let data = try JSONEncoder().encode(saved)
        let restored = PlayerController(resolver: gate)
        restored.restore(try JSONDecoder().decode(PlaybackSnapshot.self, from: data))
        XCTAssertEqual(restored.queue, saved.queue)
        XCTAssertFalse(restored.isPlaying)
        XCTAssertFalse(restored.isLoading)
        restored.toggleShuffle()
        XCTAssertEqual(restored.queue, original)
        XCTAssertEqual(restored.currentTrack, b)
        XCTAssertEqual(restored.currentIndex, 1)
        XCTAssertEqual(restored.position, 20)
    }

    func testUnpairedInterruptionEndDoesNotCancelPendingPlaybackIntent() async throws {
        let gate = PlaybackResolutionGate()
        let player = PlayerController(resolver: gate)
        player.play([a])
        _ = try await PlaybackTestSupport.waitForRequests(1, on: gate)
        player.handleInterruption(began: false, shouldResume: true)
        try await Task.sleep(for: .milliseconds(550))
        XCTAssertTrue(player.isLoading)
        XCTAssertNil(player.errorMessage)
        player.pause()
        await gate.cancelRemaining()
    }

    func testResolvedViewCountFollowsTheInstalledStreamAndResetsOnTrackChange() async throws {
        let url = try PlaybackTestSupport.audioFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let gate = PlaybackResolutionGate()
        let player = PlayerController(resolver: gate)
        defer { player.pause() }
        XCTAssertNil(player.resolvedViewCount)
        player.play([a, b])
        let first = try await PlaybackTestSupport.waitForRequests(1, on: gate)[0]
        XCTAssertNil(player.resolvedViewCount, "Nothing is known before the stream arrives")
        await gate.finish(first, with: .success(ResolvedStream(url: url, duration: 8, viewCount: 1_234_567_890)))
        try await PlaybackTestSupport.waitUntil { player.resolvedViewCount == 1_234_567_890 }
        try await PlaybackTestSupport.waitUntil { player.isPlaying }
        let before = await gate.requests.count
        player.next()
        XCTAssertNil(player.resolvedViewCount, "A new selection forgets the previous track's count")
        XCTAssertEqual(player.currentTrack, b)
        // The standby deck may have asked for B as well; answer every B request so the main one is satisfied.
        let requests = try await PlaybackTestSupport.waitForRequests(before + 1, on: gate)
        for request in requests where request.trackID == b.id {
            await gate.finish(request, with: .success(ResolvedStream(url: url, duration: 8)))
        }
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.currentTrack == self.b }
        XCTAssertNil(player.resolvedViewCount, "A stream without a count never inherits the previous track's")
    }
}

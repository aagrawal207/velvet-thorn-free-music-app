import XCTest
@testable import GanaBajana

@MainActor
final class PlaybackAudioIntegrationTests: XCTestCase {
    func testNativeAudioListeningSeekPauseAndResolvedDuration() async throws {
        let url = try PlaybackTestSupport.audioFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let resolver = PlaybackFileResolver(url: url, duration: 8)
        let player = PlayerController(resolver: resolver)
        defer { player.pause() }
        var deltas: [TimeInterval] = []
        var sessions: [UUID] = []
        var starts = 0
        player.onTrackStarted = { _ in starts += 1 }
        player.onListeningProgress = { _, session, _, delta in
            deltas.append(delta)
            sessions.append(session)
            return true
        }
        player.play([Track(id: "local-audio", title: "Local test audio", duration: 1)])
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.position > 1.1 }
        XCTAssertEqual(player.duration, 8)
        XCTAssertEqual(starts, 1)
        player.pause()
        let beforePause = deltas.reduce(0, +)
        XCTAssertGreaterThan(beforePause, 0.5)
        try await Task.sleep(for: .milliseconds(400))
        player.flushListeningProgress()
        XCTAssertEqual(deltas.reduce(0, +), beforePause, accuracy: 0.05)
        player.seek(to: 3)
        player.seek(to: 6)
        try await Task.sleep(for: .milliseconds(300))
        player.flushListeningProgress()
        XCTAssertEqual(deltas.reduce(0, +), beforePause, accuracy: 0.05)
        XCTAssertFalse(player.isPlaying)
        player.togglePlayback()
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.position > 6.6 }
        player.flushListeningProgress()
        XCTAssertGreaterThan(deltas.reduce(0, +), beforePause)
        XCTAssertLessThan(deltas.reduce(0, +), 4)
        XCTAssertEqual(Set(sessions).count, 1)
        XCTAssertEqual(starts, 1)
        try await PlaybackTestSupport.waitUntil { !player.isPlaying && player.position >= 7.9 }
        XCTAssertNil(player.errorMessage)
    }

    func testNativeItemFailureRefreshesOnlyTwiceThenOffersRetry() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("GanaBajana-missing-\(UUID()).m4a")
        let resolver = PlaybackFileResolver(url: url, duration: 8)
        let player = PlayerController(resolver: resolver)
        defer { player.pause() }
        player.play([Track(id: "missing-file", title: "Unavailable local audio")])
        try await PlaybackTestSupport.waitUntil(timeout: 12) { player.errorMessage != nil }
        let refreshes = await resolver.refreshes
        XCTAssertEqual(refreshes, [false, true, true])
        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(player.isLoading)
        player.retry()
        try await PlaybackTestSupport.waitUntil(timeout: 12) { player.errorMessage != nil }
        let afterRetry = await resolver.refreshes
        XCTAssertEqual(afterRetry.count, 6)
        XCTAssertEqual(afterRetry[3], true)
    }

    func testInterruptionResumeAndMediaResetKeepTheListeningSession() async throws {
        let url = try PlaybackTestSupport.audioFile(seconds: 12)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let resolver = PlaybackFileResolver(url: url, duration: 12)
        let player = PlayerController(resolver: resolver)
        defer { player.pause() }
        var starts = 0
        player.onTrackStarted = { _ in starts += 1 }
        player.play([Track(id: "local-interruption", title: "Interruption test")])
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.position > 0.7 }
        player.handleInterruption(began: true)
        XCTAssertFalse(player.isPlaying)
        player.handleInterruption(began: false, shouldResume: false)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(player.isPlaying)
        player.togglePlayback()
        try await PlaybackTestSupport.waitUntil { player.isPlaying }
        player.handleInterruption(began: true)
        let interruptedPosition = player.position
        player.handleInterruption(began: false, shouldResume: true)
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.position > interruptedPosition + 0.2 }
        let savedPosition = player.position
        player.handleMediaServicesReset()
        XCTAssertEqual(player.position, savedPosition, accuracy: 0.1)
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.position > savedPosition + 0.2 }
        XCTAssertEqual(starts, 1)
        let refreshes = await resolver.refreshes
        XCTAssertEqual(refreshes, [false, true])
        XCTAssertNil(player.errorMessage)
    }

    func testRepeatOneCreatesDistinctSessionsForActualRepeatedPlayback() async throws {
        let url = try PlaybackTestSupport.audioFile(seconds: 2)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let player = PlayerController(resolver: PlaybackFileResolver(url: url, duration: 2))
        defer { player.pause() }
        var starts = 0
        var sessionOrder: [UUID] = []
        var listened: [UUID: TimeInterval] = [:]
        player.onTrackStarted = { _ in starts += 1 }
        player.onListeningProgress = { _, id, _, delta in
            if listened[id] == nil { sessionOrder.append(id) }
            listened[id, default: 0] += delta
            return true
        }
        player.cycleRepeatMode()
        player.cycleRepeatMode()
        XCTAssertEqual(player.repeatMode, .one)
        player.play([Track(id: "local-repeat", title: "Repeat test")])
        try await PlaybackTestSupport.waitUntil(timeout: 15) { starts >= 3 && player.isPlaying }
        player.pause()
        XCTAssertGreaterThanOrEqual(starts, 3)
        XCTAssertEqual(listened.count, starts)
        XCTAssertEqual(Set(sessionOrder).count, sessionOrder.count)
        XCTAssertTrue(listened.values.allSatisfy { $0 > 0 && $0 <= 2.1 })
        for id in sessionOrder.prefix(2) { XCTAssertGreaterThan(try XCTUnwrap(listened[id]), 1) }
        XCTAssertEqual(player.queue.count, 1)
        XCTAssertNil(player.errorMessage)
    }

    func testMissingLocalDurationComesFromTheAssetNotTheCatalog() async throws {
        let url = try PlaybackTestSupport.audioFile(seconds: 6)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let catalogDurations: [TimeInterval?] = [nil, 1]
        for catalogDuration in catalogDurations {
            let player = PlayerController(resolver: PlaybackFileResolver(url: url))
            defer { player.pause() }
            player.play([Track(id: "local-duration", title: "Local duration test", duration: catalogDuration)])
            try await PlaybackTestSupport.waitUntil { player.isPlaying && player.position > 1.2 }
            XCTAssertEqual(player.duration, 6, accuracy: 0.001)
            XCTAssertNil(player.errorMessage)
        }
    }

    func testCompletedReplayBySeekAndRetryStartsNewListeningSessions() async throws {
        let url = try PlaybackTestSupport.audioFile(seconds: 2)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let player = PlayerController(resolver: PlaybackFileResolver(url: url, duration: 2))
        defer { player.pause() }
        var starts = 0
        var sessions = Set<UUID>()
        player.onTrackStarted = { _ in starts += 1 }
        player.onListeningProgress = { _, id, _, _ in _ = sessions.insert(id); return true }
        player.play([Track(id: "local-replay", title: "Replay test")])
        try await PlaybackTestSupport.waitUntil { !player.isPlaying && !player.isLoading && player.position >= 1.999 }
        XCTAssertEqual(starts, 1)
        player.seek(to: 0)
        player.togglePlayback()
        try await PlaybackTestSupport.waitUntil { !player.isPlaying && !player.isLoading && player.position >= 1.999 }
        XCTAssertEqual(starts, 2)
        XCTAssertEqual(sessions.count, 2)
        player.retry()
        try await PlaybackTestSupport.waitUntil { starts == 3 && player.isPlaying }
        player.pause()
        XCTAssertEqual(sessions.count, 3)
        XCTAssertNil(player.errorMessage)
    }

    func testSeekingToExactEndAdvancesQueueWithoutCountingTheSeek() async throws {
        let url = try PlaybackTestSupport.audioFile(seconds: 6)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let player = PlayerController(resolver: PlaybackFileResolver(url: url, duration: 6))
        defer { player.pause() }
        let first = Track(id: "local-first", title: "First")
        let second = Track(id: "local-second", title: "Second")
        var listened: [String: TimeInterval] = [:]
        player.onListeningProgress = { track, _, _, delta in listened[track.id, default: 0] += delta; return true }
        player.play([first, second])
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.position > 0.6 }
        player.seek(to: 6)
        try await PlaybackTestSupport.waitUntil { player.currentTrack == second && player.isPlaying && player.position > 0.2 }
        player.pause()
        XCTAssertGreaterThan(try XCTUnwrap(listened[first.id]), 0)
        XCTAssertLessThan(try XCTUnwrap(listened[first.id]), 2)
        XCTAssertGreaterThan(try XCTUnwrap(listened[second.id]), 0)
        XCTAssertNil(player.errorMessage)
    }
}

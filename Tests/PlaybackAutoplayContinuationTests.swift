import XCTest
@testable import GanaBajana

@MainActor
final class PlaybackAutoplayContinuationTests: XCTestCase {
    private let first = Track(id: "late-autoplay-first", title: "First")
    private let second = Track(id: "late-autoplay-second", title: "Second")
    private let replacement = Track(id: "late-autoplay-replacement", title: "Replacement")

    func testContinuationArrivingAfterTheEndStartsOnceAndWaitingEarnsNoListeningTime() async throws {
        let player = try makePlayer()
        defer { player.pause() }
        let gate = AppModelRequestGate<Track, [Track]>()
        addTeardownBlock { await gate.close() }
        var starts: [String] = []
        var listened: [String: TimeInterval] = [:]
        player.onTrackStarted = { starts.append($0.id) }
        player.onListeningProgress = { track, _, _, seconds in
            listened[track.id, default: 0] += seconds
            return true
        }
        player.onQueueExhausted = { track in
            guard track == self.first else { return [] }
            return (try? await gate.receive(track)) ?? []
        }
        player.play([first])
        let request = try await gate.request(at: 0)
        try await waitForEndedQueue(player)
        player.flushListeningProgress()
        let before = try XCTUnwrap(listened[first.id])
        XCTAssertGreaterThan(before, 0.5)
        XCTAssertLessThanOrEqual(before, 2.05)
        try await Task.sleep(for: .milliseconds(350))
        player.flushListeningProgress()
        XCTAssertEqual(try XCTUnwrap(listened[first.id]), before, accuracy: 0.001)
        XCTAssertEqual(starts, [first.id])

        try await gate.complete(request, with: .success([second, first, second]))
        try await PlaybackTestSupport.waitUntil { player.currentTrack == self.second && player.isPlaying && player.position > 0.2 }
        player.pause()
        XCTAssertEqual(player.queue, [first, second])
        XCTAssertEqual(player.autoplayTrackIDs, [second.id])
        XCTAssertEqual(starts, [first.id, second.id])
        XCTAssertEqual(try XCTUnwrap(listened[first.id]), before, accuracy: 0.001)
        XCTAssertGreaterThan(try XCTUnwrap(listened[second.id]), 0)
        XCTAssertNil(player.errorMessage)
    }

    func testLateContinuationCannotOverridePauseInterruptionSleepOrNewIntent() async throws {
        for action in SupersedingAction.allCases {
            let player = try makePlayer()
            defer { player.pause() }
            let gate = AppModelRequestGate<Track, [Track]>()
            addTeardownBlock { await gate.close() }
            var requests = 0
            var delivered = false
            player.onQueueExhausted = { track in
                requests += 1
                guard requests == 1 else { return [] }
                let tracks = (try? await gate.receive(track)) ?? []
                delivered = true
                return tracks
            }
            player.play([first])
            let request = try await gate.request(at: 0)
            try await waitForEndedQueue(player)
            switch action {
            case .pause: player.togglePlayback()
            case .interruption: player.handleInterruption(began: true)
            case .sleep:
                player.setSleepTimer(minutes: 1)
                let deadline = try XCTUnwrap(player.sleepUntil)
                player.expireSleepTimer(expected: deadline, now: deadline)
            case .replacement: player.play([replacement])
            case .retry: player.retry()
            case .disabled:
                var settings = player.settings
                settings.autoplay = false
                player.apply(settings)
            case .removed: player.removeFromQueue(at: 0)
            }
            try await PlaybackTestSupport.eventually { await gate.cancellations.contains(request.id) }
            try await gate.complete(request, with: .success([second]))
            try await PlaybackTestSupport.waitUntil { delivered }
            if action == .interruption { player.handleInterruption(began: false, shouldResume: true) }
            XCTAssertFalse(player.queue.contains(second), "Obsolete continuation after \(action)")
            XCTAssertTrue(player.autoplayTrackIDs.isEmpty)
            XCTAssertEqual(player.currentTrack, action == .removed ? nil : (action == .replacement ? replacement : first))
            if action != .replacement && action != .retry {
                XCTAssertFalse(player.isPlaying)
                XCTAssertFalse(player.isLoading)
            }
        }
    }

    func testEmptyOrDuplicateContinuationEndsTheWaitWithoutReplayingTheFinishedTrack() async throws {
        for tracks in [[], [first]] {
            let player = try makePlayer()
            defer { player.pause() }
            let gate = AppModelRequestGate<Track, [Track]>()
            addTeardownBlock { await gate.close() }
            var starts = 0
            player.onTrackStarted = { _ in starts += 1 }
            player.onQueueExhausted = { (try? await gate.receive($0)) ?? [] }
            player.play([first])
            let request = try await gate.request(at: 0)
            try await waitForEndedQueue(player)
            try await gate.complete(request, with: .success(tracks))
            try await PlaybackTestSupport.waitUntil { !player.isLoading }
            XCTAssertFalse(player.isPlaying)
            XCTAssertEqual(player.queue, [first])
            XCTAssertEqual(starts, 1)
            XCTAssertGreaterThanOrEqual(player.position, 1.99)
        }
    }

    private func makePlayer() throws -> PlayerController {
        let url = try PlaybackTestSupport.audioFile(seconds: 2)
        addTeardownBlock { try FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let player = PlayerController(resolver: PlaybackFileResolver(url: url, duration: 2))
        var settings = PlaybackTransitionSettings()
        settings.autoplay = true
        settings.gapless = false
        settings.automix = false
        settings.crossfadeSeconds = 0
        player.apply(settings)
        return player
    }

    private func waitForEndedQueue(_ player: PlayerController) async throws {
        try await PlaybackTestSupport.waitUntil { !player.isPlaying && player.isLoading && player.position >= 1.99 }
    }

    private enum SupersedingAction: CaseIterable {
        case pause, interruption, sleep, replacement, retry, disabled, removed
    }
}

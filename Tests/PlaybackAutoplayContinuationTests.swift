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

    func testEmptyEarlyAnswerEarnsExactlyOneMoreRequestWhenTheQueueEnds() async throws {
        for finalAnswer in [[], [second]] {
            let player = try makePlayer()
            defer { player.pause() }
            let gate = AppModelRequestGate<Track, [Track]>()
            addTeardownBlock { await gate.close() }
            var requests: [String] = []
            player.onQueueExhausted = { track in
                requests.append(track.id)
                // The early request answers empty at once; the end-of-queue request is held by the gate.
                guard requests.count > 1 else { return [] }
                return (try? await gate.receive(track)) ?? []
            }
            player.play([first])
            try await PlaybackTestSupport.waitUntil { requests == [self.first.id] }
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertEqual(requests, [first.id], "An empty early answer is not retried while the song still plays")
            try await waitForEndedQueue(player)
            let request = try await gate.request(at: 0)
            XCTAssertEqual(requests, [first.id, first.id], "The end of the queue asks once more")
            XCTAssertEqual(request.input, first)
            try await gate.complete(request, with: .success(finalAnswer))
            if finalAnswer.isEmpty {
                try await PlaybackTestSupport.waitUntil { !player.isLoading }
                try await Task.sleep(for: .milliseconds(300))
                XCTAssertFalse(player.isPlaying)
                XCTAssertEqual(player.queue, [first])
                XCTAssertEqual(requests.count, 2, "A second empty answer ends Autoplay for this song")
                XCTAssertGreaterThanOrEqual(player.position, 1.99)
            } else {
                try await PlaybackTestSupport.waitUntil { player.currentTrack == self.second && player.isPlaying && player.position > 0.2 }
                XCTAssertEqual(player.queue, [first, second])
                XCTAssertEqual(player.autoplayTrackIDs, [second.id])
                player.pause()
            }
            XCTAssertNil(player.errorMessage)
        }
    }

    func testTheEndOfQueueRequestIsCancelledByPauseOrTurningAutoplayOff() async throws {
        for turnsAutoplayOff in [false, true] {
            let player = try makePlayer()
            defer { player.pause() }
            let gate = AppModelRequestGate<Track, [Track]>()
            addTeardownBlock { await gate.close() }
            var requests = 0
            var delivered = false
            player.onQueueExhausted = { track in
                requests += 1
                guard requests == 2 else { return [] }
                let tracks = (try? await gate.receive(track)) ?? []
                delivered = true
                return tracks
            }
            player.play([first])
            try await waitForEndedQueue(player)
            let request = try await gate.request(at: 0)
            XCTAssertEqual(requests, 2)
            if turnsAutoplayOff {
                var settings = player.settings
                settings.autoplay = false
                player.apply(settings)
            } else {
                player.togglePlayback()
            }
            XCTAssertFalse(player.isLoading)
            try await PlaybackTestSupport.eventually { await gate.cancellations.contains(request.id) }
            try await gate.complete(request, with: .success([second]))
            try await PlaybackTestSupport.waitUntil { delivered }
            XCTAssertFalse(player.queue.contains(second), "A cancelled end-of-queue request cannot append")
            XCTAssertTrue(player.autoplayTrackIDs.isEmpty)
            XCTAssertFalse(player.isPlaying)
            XCTAssertFalse(player.isLoading)
            XCTAssertEqual(player.currentTrack, first)
            XCTAssertEqual(requests, 2, "Cancelling the end-of-queue request schedules no further request")
        }
    }

    func testTheFinalRequestGoesThroughOnQueueEndedAndNeverHappensForRadioSessions() async throws {
        for isRadio in [false, true] {
            let player = try makePlayer()
            defer { player.pause() }
            var early: [String] = []
            var atEnd: [String] = []
            player.onQueueExhausted = { early.append($0.id); return [] }
            player.onQueueEnded = { atEnd.append($0.id); return [] }
            player.play([first], isRadio: isRadio)
            try await waitForSettledEnd(player)
            XCTAssertEqual(early, [first.id])
            XCTAssertEqual(atEnd, isRadio ? [] : [first.id],
                           isRadio ? "A station keeps its own queue-sheet retry and gets no end-of-queue request"
                                   : "The end of the queue asks through the fresh-results callback")
            XCTAssertEqual(player.queue, [first])
            XCTAssertNil(player.errorMessage)
        }
    }

    func testManualContinuationAfterTheQueueEndedPlaysTheFirstNewSongInsteadOfReplayingTheLast() async throws {
        for isRadio in [false, true] {
            let player = try makePlayer()
            defer { player.pause() }
            var requests = 0
            var starts: [String] = []
            player.onTrackStarted = { starts.append($0.id) }
            player.onQueueExhausted = { _ in requests += 1; return [] }
            player.play([first], isRadio: isRadio)
            try await waitForSettledEnd(player)
            XCTAssertEqual(requests, isRadio ? 1 : 2)
            XCTAssertEqual(starts, [first.id])

            player.appendAutoplay([first, second])
            XCTAssertEqual(player.queue, [first, second])
            XCTAssertEqual(player.currentTrack, second, "The listener asked for more songs, not a replay of the finished one")
            XCTAssertEqual(player.currentIndex, 1)
            XCTAssertEqual(player.autoplayTrackIDs, [second.id])
            XCTAssertEqual(player.isRadioSession, isRadio)
            try await PlaybackTestSupport.waitUntil { player.currentTrack == self.second && player.isPlaying && player.position > 0.2 }
            XCTAssertEqual(starts, [first.id, second.id])
            player.pause()
            XCTAssertNil(player.errorMessage)
        }
    }

    func testManualContinuationBeforeTheEndOrDuringAnInterruptionDoesNotStartPlayback() async throws {
        let paused = try makePlayer()
        defer { paused.pause() }
        paused.onQueueExhausted = { _ in [] }
        paused.play([first])
        try await PlaybackTestSupport.waitUntil { paused.isPlaying && paused.position > 0.3 }
        paused.pause()
        paused.appendAutoplay([second])
        XCTAssertEqual(paused.queue, [first, second])
        XCTAssertEqual(paused.currentTrack, first, "A queue that has not ended only grows")
        XCTAssertFalse(paused.isPlaying)
        XCTAssertFalse(paused.isLoading)

        let interrupted = try makePlayer()
        defer { interrupted.pause() }
        var starts: [String] = []
        interrupted.onTrackStarted = { starts.append($0.id) }
        interrupted.onQueueExhausted = { _ in [] }
        interrupted.play([first])
        try await waitForSettledEnd(interrupted)
        interrupted.handleInterruption(began: true)
        interrupted.appendAutoplay([second])
        XCTAssertEqual(interrupted.currentTrack, second, "The new song is selected so the finished one is not replayed later")
        XCTAssertFalse(interrupted.isPlaying)
        XCTAssertFalse(interrupted.isLoading)
        interrupted.handleInterruption(began: false, shouldResume: true)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(interrupted.isPlaying, "Nothing was playing when the interruption began, so nothing resumes by itself")
        XCTAssertEqual(starts, [first.id])
        interrupted.resumePlayback()
        try await PlaybackTestSupport.waitUntil { interrupted.currentTrack == self.second && interrupted.isPlaying && interrupted.position > 0.2 }
        XCTAssertEqual(starts, [first.id, second.id])
        XCTAssertNil(interrupted.errorMessage)
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

    /// The queue has ended and every continuation request, including a final one, has been answered.
    private func waitForSettledEnd(_ player: PlayerController) async throws {
        try await PlaybackTestSupport.waitUntil { !player.isPlaying && !player.isLoading && player.position >= 1.99 }
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertFalse(player.isLoading)
    }

    private enum SupersedingAction: CaseIterable {
        case pause, interruption, sleep, replacement, retry, disabled, removed
    }
}

import XCTest
@testable import GanaBajana

@MainActor
final class PlaybackListeningAcknowledgementTests: XCTestCase {
    private let first = Track(id: "acknowledgement-first", title: "First")
    private let second = Track(id: "acknowledgement-second", title: "Second")

    func testFailedCheckpointRetriesTheSameSessionAndSecondsUntilOneAcknowledgement() async throws {
        let player = try makePlayer()
        defer { player.pause() }
        var canWrite = false
        var attempts: [ListeningEvent] = []
        var saved: [ListeningEvent] = []
        player.onListeningProgress = { track, id, started, seconds in
            let checkpoint = ListeningEvent(id: id, track: track, startedAt: started, listenedSeconds: seconds)
            attempts.append(checkpoint)
            if canWrite { saved.append(checkpoint) }
            return canWrite
        }
        player.play([first])
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.position > 0.7 }
        player.pause()
        let failed = try XCTUnwrap(attempts.last)
        XCTAssertGreaterThan(failed.listenedSeconds, 0.5)
        let count = attempts.count
        player.flushListeningProgress()
        player.flushListeningProgress()
        XCTAssertEqual(attempts.count, count + 2)
        for retry in attempts.suffix(2) {
            XCTAssertEqual(retry.id, failed.id)
            XCTAssertEqual(retry.track, failed.track)
            XCTAssertEqual(retry.startedAt, failed.startedAt)
            XCTAssertEqual(retry.listenedSeconds, failed.listenedSeconds, accuracy: 0.001)
        }
        XCTAssertTrue(saved.isEmpty)

        canWrite = true
        player.flushListeningProgress()
        player.flushListeningProgress()
        player.pause()
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.id, failed.id)
        XCTAssertEqual(try XCTUnwrap(saved.first?.listenedSeconds), failed.listenedSeconds, accuracy: 0.001)
    }

    func testFailedSessionsSurviveTrackChangesAndAnEmptyQueueWithoutMixingTheirIdentity() async throws {
        let player = try makePlayer()
        defer { player.pause() }
        var canWrite = false
        var failedFirst: ListeningEvent?
        var saved: [ListeningEvent] = []
        player.onListeningProgress = { track, id, started, seconds in
            let checkpoint = ListeningEvent(id: id, track: track, startedAt: started, listenedSeconds: seconds)
            guard canWrite else {
                if track == self.first { failedFirst = checkpoint }
                return false
            }
            saved.append(checkpoint)
            return true
        }
        player.play([first, second])
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.position > 0.7 }
        player.next()
        try await PlaybackTestSupport.waitUntil { player.currentTrack == self.second && player.isPlaying && player.position > 0.7 }
        player.pause()
        player.play([])
        let original = try XCTUnwrap(failedFirst)
        XCTAssertTrue(saved.isEmpty)
        canWrite = true
        player.flushListeningProgress()
        player.flushListeningProgress()
        XCTAssertNil(player.currentTrack)
        XCTAssertEqual(saved.map(\.track.id), [first.id, second.id])
        let savedFirst = try XCTUnwrap(saved.first)
        let savedSecond = try XCTUnwrap(saved.dropFirst().first)
        XCTAssertEqual(savedFirst.id, original.id)
        XCTAssertEqual(savedFirst.startedAt, original.startedAt)
        XCTAssertEqual(savedFirst.listenedSeconds, original.listenedSeconds, accuracy: 0.001)
        XCTAssertNotEqual(savedFirst.id, savedSecond.id)
        XCTAssertGreaterThan(savedSecond.startedAt, savedFirst.startedAt)
        XCTAssertTrue(saved.allSatisfy { $0.listenedSeconds > 0.5 && $0.listenedSeconds < 3 })
    }

    func testPrivacyDiscardDropsUnsavedTimeAndStartsAFreshRecordingWithoutAnotherTrackStart() async throws {
        let player = try makePlayer()
        defer { player.pause() }
        var canWrite = false
        var oldID: UUID?
        var saved: [ListeningEvent] = []
        var starts = 0
        player.onTrackStarted = { _ in starts += 1 }
        player.onListeningProgress = { track, id, started, seconds in
            guard canWrite else { oldID = id; return false }
            saved.append(ListeningEvent(id: id, track: track, startedAt: started, listenedSeconds: seconds))
            return true
        }
        player.play([first])
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.position > 0.7 }
        player.flushListeningProgress()
        let retired = try XCTUnwrap(oldID)
        let discardedAt = Date()
        player.discardPendingListening()
        let boundary = player.position
        canWrite = true
        player.flushListeningProgress()
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.position > boundary + 0.7 }
        player.pause()
        XCTAssertFalse(saved.isEmpty)
        XCTAssertTrue(saved.allSatisfy { $0.id != retired && $0.startedAt >= discardedAt.addingTimeInterval(-0.05) })
        XCTAssertEqual(Set(saved.map(\.id)).count, 1)
        let seconds = saved.reduce(0) { $0 + $1.listenedSeconds }
        XCTAssertGreaterThan(seconds, 0.5)
        XCTAssertLessThanOrEqual(seconds, player.position - boundary + 0.05)
        XCTAssertEqual(starts, 1)
    }

    func testReentrantFlushDoesNotRedeliverAnAcknowledgementInProgress() async throws {
        let player = try makePlayer()
        defer { player.pause() }
        var saved: [TimeInterval] = []
        player.onListeningProgress = { [weak player] _, _, _, seconds in
            saved.append(seconds)
            player?.flushListeningProgress()
            return true
        }
        player.play([first])
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.position > 0.7 }
        player.pause()
        let count = saved.count
        player.flushListeningProgress()
        XCTAssertEqual(saved.count, count)
        XCTAssertGreaterThan(saved.reduce(0, +), 0.5)
        XCTAssertLessThanOrEqual(saved.reduce(0, +), player.position + 0.05)
    }

    func testFullCheckpointBufferPausesANewSessionAndRecoveryRetainsAllEarlierTime() async throws {
        let player = try makePlayer(limit: 1)
        defer { player.pause() }
        var canWrite = false
        var saved: [ListeningEvent] = []
        player.onListeningProgress = { track, id, started, seconds in
            guard canWrite else { return false }
            saved.append(ListeningEvent(id: id, track: track, startedAt: started, listenedSeconds: seconds))
            return true
        }
        player.play([first, second])
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.position > 0.7 }
        player.next()
        XCTAssertEqual(player.currentTrack, second)
        XCTAssertNotNil(player.errorMessage)
        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(player.isLoading)
        XCTAssertNil(player.currentStreamURL)
        XCTAssertTrue(saved.isEmpty)

        canWrite = true
        player.retry()
        try await PlaybackTestSupport.waitUntil { player.currentTrack == self.second && player.isPlaying && player.position > 0.7 }
        player.pause()
        player.flushListeningProgress()
        XCTAssertEqual(saved.map(\.track.id), [first.id, second.id])
        XCTAssertNotEqual(try XCTUnwrap(saved.first?.id), try XCTUnwrap(saved.dropFirst().first?.id))
        XCTAssertTrue(saved.allSatisfy { $0.listenedSeconds > 0.5 && $0.listenedSeconds < 3 })
        XCTAssertNil(player.errorMessage)
    }

    func testFullCheckpointBufferAlsoBlocksAPreparedCrossfadeWithoutDiscardingTime() async throws {
        let player = try makePlayer(limit: 1, crossfade: 1)
        defer { player.pause() }
        var canWrite = false
        var saved: [ListeningEvent] = []
        player.onListeningProgress = { track, id, started, seconds in
            guard canWrite else { return false }
            saved.append(ListeningEvent(id: id, track: track, startedAt: started, listenedSeconds: seconds))
            return true
        }
        player.play([first, second])
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.position > 0.7 && player.isStandbyReady }
        player.next()
        XCTAssertEqual(player.currentTrack, first)
        XCTAssertNotNil(player.errorMessage)
        XCTAssertNil(player.crossfadeState)
        XCTAssertFalse(player.isPlaying)
        XCTAssertTrue(player.hasStandbyPlayer)
        canWrite = true
        player.flushListeningProgress()
        player.flushListeningProgress()
        XCTAssertEqual(saved.map(\.track.id), [first.id])
        XCTAssertGreaterThan(try XCTUnwrap(saved.first?.listenedSeconds), 0.5)
    }

    private func makePlayer(limit: Int = PlaybackListeningBuffer.defaultMaximumSessions, crossfade: TimeInterval = 0) throws -> PlayerController {
        let url = try PlaybackTestSupport.audioFile()
        addTeardownBlock { try FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let player = PlayerController(resolver: PlaybackFileResolver(url: url, duration: 8), listeningCheckpointLimit: limit)
        var settings = PlaybackTransitionSettings()
        settings.autoplay = false
        settings.gapless = crossfade > 0
        settings.automix = false
        settings.crossfadeSeconds = crossfade
        player.apply(settings)
        return player
    }
}

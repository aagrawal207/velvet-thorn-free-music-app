import XCTest
@testable import GanaBajana

final class PlaybackListeningTests: XCTestCase {
    func testCreditsActualAdvancingTimeAndDrainsDeltasExactlyOnce() {
        var clock = PlaybackListeningClock()
        XCTAssertEqual(clock.sample(position: 0, uptime: 0, advancing: true), 0)
        XCTAssertEqual(clock.sample(position: 1, uptime: 1, advancing: true), 1)
        XCTAssertEqual(clock.sample(position: 2, uptime: 2, advancing: false), 1)
        XCTAssertEqual(clock.drain(), 2)
        XCTAssertEqual(clock.drain(), 0)
        clock.sample(position: 2, uptime: 40, advancing: false)
        clock.sample(position: 2, uptime: 50, advancing: true)
        clock.sample(position: 2.5, uptime: 50.5, advancing: true)
        XCTAssertEqual(clock.drain(), 0.5)
    }

    func testStallsDoNotCreditElapsedWallTime() {
        var clock = PlaybackListeningClock()
        clock.sample(position: 10, uptime: 10, advancing: true)
        clock.sample(position: 12, uptime: 60, advancing: false)
        XCTAssertEqual(clock.drain(), 2)
        clock.sample(position: 12, uptime: 100, advancing: true)
        clock.sample(position: 12, uptime: 101, advancing: true)
        XCTAssertEqual(clock.drain(), 0)
    }

    func testExplicitAndUnannouncedSeeksNeverCreditTheJump() {
        var clock = PlaybackListeningClock()
        clock.sample(position: 0, uptime: 0, advancing: true)
        clock.sample(position: 1, uptime: 1, advancing: true)
        clock.discontinuity()
        clock.sample(position: 180, uptime: 1.1, advancing: true)
        XCTAssertEqual(clock.drain(), 1)
        clock.sample(position: 181, uptime: 2.1, advancing: true)
        clock.sample(position: 260, uptime: 2.2, advancing: true)
        XCTAssertEqual(clock.drain(), 1, accuracy: 0.0001)
        clock.sample(position: 10, uptime: 2.3, advancing: true)
        XCTAssertEqual(clock.drain(), 0)
    }

    func testInvalidAndReverseClockSamplesCannotInflateTotals() {
        var clock = PlaybackListeningClock()
        clock.sample(position: 1, uptime: 1, advancing: true)
        clock.sample(position: .nan, uptime: 2, advancing: true)
        clock.sample(position: 100, uptime: 3, advancing: true)
        clock.sample(position: 101, uptime: 2, advancing: true)
        XCTAssertEqual(clock.drain(), 0)
    }

    func testDiscontinuityPreservesPendingCreditAndExcludesPausedSeeks() {
        var clock = PlaybackListeningClock()
        clock.sample(position: 0, uptime: 0, advancing: true)
        clock.sample(position: 0.75, uptime: 0.75, advancing: true)
        clock.discontinuity()
        clock.sample(position: 600, uptime: 2, advancing: false)
        clock.sample(position: 600, uptime: 10, advancing: false)
        XCTAssertEqual(clock.drain(), 0.75)
        XCTAssertEqual(clock.drain(), 0)
        clock.sample(position: 600, uptime: 10, advancing: true)
        clock.sample(position: 600.5, uptime: 10.5, advancing: true)
        XCTAssertEqual(clock.drain(), 0.5)
    }

    func testInterruptionRequiresPriorIntentSystemPermissionAndSameGeneration() {
        var interruption = PlaybackInterruption()
        interruption.begin(wantsPlayback: false, generation: 1)
        XCTAssertFalse(interruption.end(shouldResume: true, generation: 1))
        interruption.begin(wantsPlayback: true, generation: 2)
        XCTAssertFalse(interruption.end(shouldResume: false, generation: 2))
        interruption.begin(wantsPlayback: true, generation: 3)
        XCTAssertFalse(interruption.end(shouldResume: true, generation: 4))
        interruption.begin(wantsPlayback: true, generation: 5)
        interruption.cancelResume()
        XCTAssertFalse(interruption.end(shouldResume: true, generation: 5))
        interruption.begin(wantsPlayback: true, generation: 6)
        XCTAssertTrue(interruption.end(shouldResume: true, generation: 6))
        XCTAssertFalse(interruption.end(shouldResume: true, generation: 6))
    }

    func testPendingCheckpointsCoalesceAndAcknowledgementRemovesOnlyTheDeliveredDelta() throws {
        var buffer = PlaybackListeningBuffer(maximumSessions: 2)
        let first = ListeningEvent(id: UUID(), track: Track(id: "listening-first", title: "First"),
                                   startedAt: Date(timeIntervalSince1970: 1_800_000_000), listenedSeconds: 5)
        XCTAssertTrue(buffer.append(first))
        var later = first
        later.listenedSeconds = 2.5
        XCTAssertTrue(buffer.append(later))
        buffer.acknowledge(first)
        let pending = try XCTUnwrap(buffer.checkpoints.first)
        XCTAssertEqual(pending.id, first.id)
        XCTAssertEqual(pending.track, first.track)
        XCTAssertEqual(pending.startedAt, first.startedAt)
        XCTAssertEqual(pending.listenedSeconds, 2.5)
        buffer.acknowledge(pending)
        XCTAssertTrue(buffer.checkpoints.isEmpty)
        XCTAssertTrue(buffer.append(later))
        XCTAssertEqual(buffer.checkpoints.first?.listenedSeconds, 2.5, "Already acknowledged time cannot return")
    }

    func testSessionLimitPreservesAcceptedSecondsAndAllowsTheActiveSessionToAccumulate() throws {
        var buffer = PlaybackListeningBuffer(maximumSessions: 2)
        let first = ListeningEvent(id: UUID(), track: Track(id: "listening-first", title: "First"), startedAt: Date(), listenedSeconds: 1)
        let second = ListeningEvent(id: UUID(), track: Track(id: "listening-second", title: "Second"), startedAt: Date(), listenedSeconds: 2)
        let third = ListeningEvent(id: UUID(), track: Track(id: "listening-third", title: "Third"), startedAt: Date(), listenedSeconds: 3)
        XCTAssertTrue(buffer.append(first))
        XCTAssertTrue(buffer.append(second))
        XCTAssertFalse(buffer.canRecord(sessionID: third.id))
        XCTAssertFalse(buffer.append(third))
        XCTAssertTrue(buffer.canRecord(sessionID: first.id))
        var halfSecond = first
        halfSecond.listenedSeconds = 0.5
        for _ in 0..<100 { XCTAssertTrue(buffer.append(halfSecond)) }
        XCTAssertEqual(buffer.checkpoints.count, 2)
        XCTAssertEqual(buffer.checkpoints.map(\.id), [first.id, second.id])
        XCTAssertEqual(buffer.checkpoints.map(\.listenedSeconds), [51, 2])
        buffer.acknowledge(try XCTUnwrap(buffer.checkpoints.first))
        XCTAssertTrue(buffer.canRecord(sessionID: third.id))
        XCTAssertTrue(buffer.append(third))
        XCTAssertEqual(buffer.checkpoints.map(\.id), [second.id, third.id])
    }

    func testDiscardedCheckpointsCannotAcknowledgeOrRepopulateANewSession() {
        var buffer = PlaybackListeningBuffer()
        let old = ListeningEvent(id: UUID(), track: Track(id: "listening-first", title: "First"), startedAt: Date(), listenedSeconds: 10)
        XCTAssertTrue(buffer.append(old))
        buffer.discard()
        var fresh = old
        fresh.id = UUID()
        fresh.startedAt = old.startedAt.addingTimeInterval(20)
        fresh.listenedSeconds = 1
        XCTAssertTrue(buffer.append(fresh))
        buffer.acknowledge(old)
        XCTAssertEqual(buffer.checkpoints.map(\.id), [fresh.id])
        XCTAssertEqual(buffer.checkpoints.first?.listenedSeconds, 1)
        buffer.acknowledge(fresh)
        XCTAssertTrue(buffer.checkpoints.isEmpty)
    }
}

import XCTest
@testable import GanaBajana

final class WatchSnapshotStateTests: XCTestCase {
    func testCachedPlayingSnapshotIsLastSeenEvenWhenReachable() {
        var state = WatchSnapshotState()
        state.setAvailability(reachable: true, foreground: true, at: 100)
        state.receive(WatchTestSupport.snapshot(), source: .applicationContext, at: 100)
        XCTAssertFalse(state.isCurrent(at: 105))
        XCTAssertFalse(state.isPlaying(at: 105))
        XCTAssertEqual(state.position(at: 105), 42)
    }

    func testLivePlayingPositionUsesLocalMonotonicReceiptAndClampsAtDuration() {
        var state = liveState(WatchTestSupport.snapshot(position: 210))
        XCTAssertEqual(state.position(at: 102), 212)
        XCTAssertEqual(state.position(at: 108), 214)
        XCTAssertEqual(state.position(at: 99), 210)
        state.receive(WatchTestSupport.snapshot(sequence: 2, position: 5), source: .reply, at: 109)
        XCTAssertEqual(state.position(at: 110), 6)
    }

    func testPauseLoadingAndErrorDoNotInterpolate() {
        for snapshot in [WatchTestSupport.snapshot(playing: false),
                         WatchTestSupport.snapshot(loading: true),
                         WatchTestSupport.snapshot(error: "Playback stopped")] {
            let state = liveState(snapshot)
            XCTAssertEqual(state.position(at: 109), 42)
            XCTAssertFalse(state.isPlaying(at: 109))
        }
    }

    func testDisconnectionFreezesProgressAndReconnectRequiresFreshReply() {
        var state = liveState(WatchTestSupport.snapshot())
        state.setAvailability(reachable: false, foreground: true, at: 103)
        XCTAssertEqual(state.position(at: 115), 45)
        XCTAssertFalse(state.isPlaying(at: 115))
        state.setAvailability(reachable: true, foreground: true, at: 120)
        XCTAssertFalse(state.isCurrent(at: 120))
        XCTAssertEqual(state.position(at: 121), 45)
        state.receive(WatchTestSupport.snapshot(position: 42), source: .reply, at: 122)
        XCTAssertEqual(state.position(at: 123), 43)
    }

    func testBackgroundReturnDoesNotInterpolateCachedPlayback() {
        var state = liveState(WatchTestSupport.snapshot())
        state.setAvailability(reachable: true, foreground: false, at: 104)
        XCTAssertEqual(state.position(at: 200), 46)
        state.setAvailability(reachable: true, foreground: true, at: 201)
        XCTAssertEqual(state.position(at: 202), 46)
        XCTAssertFalse(state.isCurrent(at: 202))
    }

    func testReachabilityAloneCannotExtendConfirmationLifetime() {
        var state = liveState(WatchTestSupport.snapshot())
        XCTAssertTrue(state.isCurrent(at: 119))
        XCTAssertFalse(state.isCurrent(at: 120))
        XCTAssertEqual(state.position(at: 150), 62)
        state.receive(WatchTestSupport.snapshot(sequence: 2, position: 50), source: .applicationContext, at: 151)
        XCTAssertFalse(state.isCurrent(at: 152))
        XCTAssertEqual(state.position(at: 152), 50)
    }

    func testOutOfOrderAndDuplicateSnapshotsNeverRewindNewerState() {
        var state = liveState(WatchTestSupport.snapshot(sequence: 5, position: 100))
        state.receive(WatchTestSupport.snapshot(sequence: 7, position: 108), source: .applicationContext, at: 101)
        state.receive(WatchTestSupport.snapshot(sequence: 6, position: 104), source: .reply, at: 102)
        XCTAssertEqual(state.snapshot?.sequence, 7)
        XCTAssertEqual(state.position(at: 103), 110)
        state.receive(WatchTestSupport.snapshot(sequence: 7, position: 108), source: .applicationContext, at: 104)
        XCTAssertEqual(state.position(at: 104), 111)
    }

    func testPhoneRestartRequiresReplyAndRetiresOldProcessReplies() {
        let replacementID = UUID()
        var state = liveState(WatchTestSupport.snapshot(sequence: 20))
        state.receive(WatchTestSupport.snapshot(sessionID: replacementID, playing: false), source: .applicationContext, at: 102)
        XCTAssertEqual(state.snapshot?.sessionID, WatchTestSupport.sessionID)
        state.receive(WatchTestSupport.snapshot(sessionID: replacementID, playing: false), source: .reply, at: 103)
        XCTAssertEqual(state.snapshot?.sessionID, replacementID)
        XCTAssertFalse(state.isPlaying(at: 104))
        state.receive(WatchTestSupport.snapshot(sequence: 21), source: .reply, at: 104)
        state.receive(WatchTestSupport.snapshot(sequence: 22), source: .applicationContext, at: 105)
        XCTAssertEqual(state.snapshot?.sessionID, replacementID)
        XCTAssertFalse(state.isPlaying(at: 105))
    }

    func testEmptySnapshotClearsOldTrackAndProgress() {
        var state = liveState(WatchTestSupport.snapshot())
        state.receive(WatchTestSupport.snapshot(sequence: 2, empty: true), source: .reply, at: 101)
        XCTAssertNil(state.snapshot?.nowPlaying)
        XCTAssertEqual(state.position(at: 102), 0)
        XCTAssertTrue(state.isCurrent(at: 102))
    }

    func testTimestampHandlesInvalidAndLongDurationsWithoutIntegerOverflow() {
        XCTAssertEqual(WatchSnapshotState.timestamp(.nan), "0:00")
        XCTAssertEqual(WatchSnapshotState.timestamp(.infinity), "0:00")
        XCTAssertEqual(WatchSnapshotState.timestamp(-1), "0:00")
        XCTAssertEqual(WatchSnapshotState.timestamp(3_661), "1:01:01")
        XCTAssertEqual(WatchSnapshotState.timestamp(.greatestFiniteMagnitude), "99:59:59")
    }

    func testLibraryFailureAndRecoveryDoNotFreezePlayingClock() {
        var state = liveState(WatchTestSupport.snapshot())
        state.receive(WatchTestSupport.snapshot(sequence: 2, position: 44, libraryError: "Recover the library on iPhone."),
                      source: .applicationContext, at: 102)
        XCTAssertNotNil(state.snapshot?.libraryError)
        XCTAssertNil(state.snapshot?.nowPlaying?.errorMessage)
        XCTAssertTrue(state.isPlaying(at: 106))
        XCTAssertEqual(state.position(at: 106), 48)
        state.receive(WatchTestSupport.snapshot(sequence: 3, position: 49), source: .applicationContext, at: 107)
        XCTAssertNil(state.snapshot?.libraryError)
        XCTAssertTrue(state.isPlaying(at: 108))
        XCTAssertEqual(state.position(at: 108), 50)
    }

    private func liveState(_ snapshot: CompanionSnapshot) -> WatchSnapshotState {
        var state = WatchSnapshotState()
        state.setAvailability(reachable: true, foreground: true, at: 100)
        state.receive(snapshot, source: .reply, at: 100)
        return state
    }
}

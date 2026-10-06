import XCTest
@testable import GanaBajana

@MainActor
final class WatchPhoneSessionTests: XCTestCase {
    func testStartObservesImmediatelyAndPublishesWithoutPlaybackAction() throws {
        let transport = WatchTestTransport()
        let playback = WatchPhonePlaybackSpy()
        let session = makeSession(transport, playback)
        session.start()
        session.start()
        XCTAssertEqual(transport.activationCount, 1)
        XCTAssertEqual(playback.observers.count, 1)
        XCTAssertTrue(playback.requests.isEmpty)
        XCTAssertEqual(transport.contexts.count, 1)
        XCTAssertEqual(try CompanionWire.decode(CompanionSnapshot.self, from: transport.contexts[0]), playback.snapshot)
        session.stop()
        XCTAssertTrue(playback.observers.isEmpty)
    }

    func testInactiveSessionPublishesLatestStateAfterActivationAndReactivatesAfterSwitch() throws {
        let transport = WatchTestTransport()
        transport.state = .activating
        let playback = WatchPhonePlaybackSpy()
        let session = makeSession(transport, playback)
        session.start()
        playback.publish(WatchTestSupport.snapshot(sequence: 3, playing: false))
        XCTAssertTrue(transport.contexts.isEmpty)
        transport.changeState(.ready(reachable: false, installed: true, needsUnlock: false))
        XCTAssertEqual(try CompanionWire.decode(CompanionSnapshot.self, from: transport.contexts[0]).sequence, 3)
        transport.changeState(.inactive)
        transport.onEvent?(.deactivated)
        XCTAssertEqual(transport.activationCount, 2)
        XCTAssertTrue(playback.requests.isEmpty)
        session.stop()
    }

    func testBackgroundContextNeverExecutesInboundPlaybackIntent() throws {
        let transport = WatchTestTransport()
        let playback = WatchPhonePlaybackSpy()
        let session = makeSession(transport, playback)
        session.start()
        transport.onEvent?(.applicationContext(try CompanionWire.encode(CompanionRequest(action: .play))))
        transport.onEvent?(.applicationContext(try CompanionWire.encode(WatchTestSupport.snapshot(playing: true))))
        XCTAssertTrue(playback.requests.isEmpty)
        session.stop()
    }

    func testInteractiveRequestDelegatesExactlyOnceAndCorrelatesReply() throws {
        let transport = WatchTestTransport()
        let playback = WatchPhonePlaybackSpy()
        let session = makeSession(transport, playback)
        session.start()
        let lease = CompanionExecutionLease(id: UUID(), sessionID: playback.snapshot.sessionID)
        let request = CompanionRequest(action: .setFavorite(true), expectedTrackID: "watch-test-track", executionLease: lease)
        let replies = WatchReplyRecorder()
        let reply = WatchReply(receivedAt: 100, handler: replies.record)
        transport.onEvent?(.request(try CompanionWire.encode(request), reply))
        reply.finish(Data("late".utf8))
        XCTAssertEqual(playback.requests, [request])
        XCTAssertEqual(replies.values.count, 1)
        let response = try CompanionWire.decode(CompanionResponse.self, from: replies.values[0])
        XCTAssertEqual(response.id, request.id)
        XCTAssertTrue(response.accepted)
        session.stop()
    }

    func testSuperLikeRequestReachesPlaybackOnceAndTheReplyCarriesTheTier() throws {
        let transport = WatchTestTransport()
        let playback = WatchPhonePlaybackSpy()
        playback.snapshot = WatchTestSupport.snapshot(playing: false, favorite: true, superLiked: true)
        let session = makeSession(transport, playback)
        session.start()
        XCTAssertEqual(try CompanionWire.decode(CompanionSnapshot.self, from: transport.contexts[0]).nowPlaying?.isSuperLiked, true)
        let lease = CompanionExecutionLease(id: UUID(), sessionID: playback.snapshot.sessionID)
        let request = CompanionRequest(action: .setSuperLiked(true), expectedTrackID: "watch-test-track", executionLease: lease)
        let replies = WatchReplyRecorder()
        transport.onEvent?(.request(try CompanionWire.encode(request), WatchReply(receivedAt: 100, handler: replies.record)))
        XCTAssertEqual(playback.requests, [request])
        XCTAssertEqual(playback.requests.first?.version, 2)
        let response = try CompanionWire.decode(CompanionResponse.self, from: try XCTUnwrap(replies.values.first))
        XCTAssertEqual(response.id, request.id)
        XCTAssertTrue(response.accepted)
        XCTAssertEqual(response.snapshot.nowPlaying?.isFavorite, true)
        XCTAssertEqual(response.snapshot.nowPlaying?.isSuperLiked, true)
        session.stop()
    }

    func testExpiredAndAlreadyRepliedRequestsCannotExecute() throws {
        let transport = WatchTestTransport()
        let playback = WatchPhonePlaybackSpy()
        let session = makeSession(transport, playback, uptime: { 107 })
        session.start()
        let replies = WatchReplyRecorder()
        let expired = WatchReply(receivedAt: 100, handler: replies.record)
        let data = try CompanionWire.encode(CompanionRequest(action: .next))
        transport.onEvent?(.request(data, expired))
        let retired = WatchReply(receivedAt: 107, handler: replies.record)
        retired.finish(Data())
        transport.onEvent?(.request(data, retired))
        XCTAssertTrue(playback.requests.isEmpty)
        XCTAssertEqual(replies.values, [Data(), Data()])
        session.stop()
    }

    func testUnreachableRequestIsRejectedWithoutPlayback() throws {
        let transport = WatchTestTransport()
        transport.state = .ready(reachable: false, installed: true, needsUnlock: false)
        let playback = WatchPhonePlaybackSpy()
        let session = makeSession(transport, playback)
        session.start()
        let request = CompanionRequest(action: .next)
        let replies = WatchReplyRecorder()
        transport.onEvent?(.request(try CompanionWire.encode(request), WatchReply(receivedAt: 100, handler: replies.record)))
        let response = try CompanionWire.decode(CompanionResponse.self, from: replies.values[0])
        XCTAssertFalse(response.accepted)
        XCTAssertEqual(response.id, request.id)
        XCTAssertTrue(playback.requests.isEmpty)
        session.stop()
    }

    func testOversizedMalformedAndWrongVersionRequestsNeverReachPlayback() throws {
        let transport = WatchTestTransport()
        let playback = WatchPhonePlaybackSpy()
        let session = makeSession(transport, playback)
        session.start()
        let inputs = [Data(repeating: 32, count: CompanionWire.maximumMessageBytes + 1), Data("{}".utf8),
                      try CompanionWire.encode(CompanionRequest(version: 1, action: .play)),
                      try CompanionWire.encode(CompanionRequest(version: 3, action: .setSuperLiked(true)))]
        for data in inputs {
            let replies = WatchReplyRecorder()
            transport.onEvent?(.request(data, WatchReply(receivedAt: 100, handler: replies.record)))
            XCTAssertEqual(replies.values, [Data()])
        }
        XCTAssertTrue(playback.requests.isEmpty)
        session.stop()
    }

    func testContextFailureRetriesLatestSnapshotOnNextSessionEvent() throws {
        let transport = WatchTestTransport()
        transport.rejectsContext = true
        let playback = WatchPhonePlaybackSpy()
        var uptime: TimeInterval = 100
        let session = makeSession(transport, playback, uptime: { uptime })
        session.start()
        XCTAssertTrue(session.contextNeedsRetry)
        playback.publish(WatchTestSupport.snapshot(sequence: 2, playing: false))
        transport.rejectsContext = false
        uptime = 110
        transport.changeState(.ready(reachable: false, installed: true, needsUnlock: false))
        XCTAssertFalse(session.contextNeedsRetry)
        XCTAssertEqual(transport.contexts.count, 1)
        XCTAssertEqual(try CompanionWire.decode(CompanionSnapshot.self, from: transport.contexts[0]).sequence, 2)
        XCTAssertTrue(playback.requests.isEmpty)
        session.stop()
    }

    func testReplyGateHasOneWinnerAcrossBackgroundCallbacks() async {
        let recorder = WatchReplyRecorder()
        let reply = WatchReply(handler: recorder.record)
        await withTaskGroup(of: Void.self) { group in
            for value in 0..<32 {
                group.addTask { reply.finish(Data([UInt8(value)])) }
            }
        }
        XCTAssertEqual(recorder.values.count, 1)
        XCTAssertFalse(reply.canHandle(at: WatchClock.now))
    }

    private func makeSession(_ transport: WatchTestTransport, _ playback: WatchPhonePlaybackSpy,
                             uptime: @escaping @MainActor () -> TimeInterval = { 100 }) -> WatchPhoneSession {
        WatchPhoneSession(transport: transport, snapshot: { playback.snapshot }, handle: { playback.handle($0) },
                          observe: { playback.observe($0) }, removeObserver: { playback.observers[$0] = nil }, uptime: uptime)
    }
}

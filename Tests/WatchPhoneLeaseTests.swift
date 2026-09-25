import XCTest
@testable import GanaBajana

@MainActor
final class WatchPhoneLeaseTests: XCTestCase {
    func testWatchRequiresLeaseForEveryMutationButNotReadOnlyRequests() throws {
        let transport = WatchTestTransport()
        let playback = WatchPhonePlaybackSpy()
        let session = WatchPhoneSession(transport: transport, snapshot: { playback.snapshot }, handle: { playback.handle($0) },
                                        observe: { playback.observe($0) }, removeObserver: { playback.observers[$0] = nil }, uptime: { 100 })
        session.start()
        defer { session.stop() }
        let actions: [CompanionAction] = [.play, .pause, .next, .previous, .seek(10), .setFavorite(true),
                                          .setShuffle(true), .setRepeatMode(.all),
                                          .playItem(location: "queue", itemID: "item:0", revision: "revision")]
        for action in actions {
            let response = try deliver(.init(action: action), to: transport, receivedAt: 100)
            XCTAssertFalse(response.accepted, "\(action)")
        }
        XCTAssertTrue(playback.requests.isEmpty)
        for action in [CompanionAction.snapshot, .browse("root")] {
            XCTAssertTrue(try deliver(.init(action: action), to: transport, receivedAt: 100).accepted)
        }
        XCTAssertEqual(playback.requests.map(\.action), [.snapshot, .browse("root")])
    }

    func testDeliveryDelayedBeforeDelegateReceiptCannotExecuteAfterClientDeadline() async throws {
        let songs = [libraryTestTrack("a"), libraryTestTrack("b")]
        let context = try makeContext(songs)
        let origin = ContinuousClock.now
        var phoneClock = origin
        var receiverClock: TimeInterval = 100
        let controller = CompanionPlaybackController(model: context.model, monotonicNow: { phoneClock })
        let transport = WatchTestTransport()
        let session = makeSession(transport, controller: controller, clock: { receiverClock })
        session.start()
        defer { session.stop() }

        let watchTransport = WatchTestTransport()
        watchTransport.automaticResponse = { request in
            guard request.action == .snapshot else { return nil }
            return try? self.deliver(request, to: transport, receivedAt: receiverClock)
        }
        let deadline = WatchTestDeadline()
        let client = WatchRequestClient(transport: watchTransport, waitForDeadline: { try await deadline.wait() }, uptime: { receiverClock })
        client.start()
        let displayed = controller.snapshot
        let request = CompanionRequest(action: .next, expectedTrackID: songs[0].id)
        let mutation = Task { try await client.request(request, displayed: displayed) }
        defer { mutation.cancel(); client.cancelAll() }
        try await WatchTestSupport.waitUntil { watchTransport.messages.count == 2 }
        let bytesWaitingForDelivery = watchTransport.messages[1].data
        XCTAssertNotNil(try CompanionWire.decode(CompanionRequest.self, from: bytesWaitingForDelivery).executionLease)
        try await WatchTestSupport.waitForDeadline(deadline, startedCount: 2)
        phoneClock = origin.advanced(by: .seconds(9))
        receiverClock = 109
        XCTAssertGreaterThan(receiverClock - 100, WatchRequestClient.replyDeadline)
        await deadline.fire()
        do { _ = try await mutation.value; XCTFail("Expected the watch command to time out before delivery") }
        catch { XCTAssertEqual(error as? WatchRequestError, .timedOut) }

        let replies = WatchReplyRecorder()
        let newlyReceived = WatchReply(receivedAt: receiverClock, handler: replies.record)
        XCTAssertTrue(newlyReceived.canHandle(at: receiverClock))
        transport.onEvent?(.request(bytesWaitingForDelivery, newlyReceived))
        let response = try CompanionWire.decode(CompanionResponse.self, from: XCTUnwrap(replies.values.first))
        XCTAssertFalse(response.accepted)
        XCTAssertEqual(response.id, request.id)
        XCTAssertNotNil(response.error)
        watchTransport.messages[1].completion(.success(try XCTUnwrap(replies.values.first)))
        await Task.yield()
        XCTAssertEqual(watchTransport.requests.map(\.action), [.snapshot, .next])
        XCTAssertEqual(context.player.currentIndex, 0)
        XCTAssertEqual(context.player.currentTrack?.id, songs[0].id)
        XCTAssertFalse(context.player.isPlaying)
        XCTAssertFalse(context.player.isLoading)
    }

    func testValidLeaseWorksBeforeExpiryAndFabricatedOrWrongSessionLeaseDoesNot() throws {
        let songs = [libraryTestTrack("a"), libraryTestTrack("b")]
        let context = try makeContext(songs)
        let origin = ContinuousClock.now
        var phoneClock = origin
        let controller = CompanionPlaybackController(model: context.model, monotonicNow: { phoneClock })
        let transport = WatchTestTransport()
        let session = makeSession(transport, controller: controller, clock: { 100 })
        session.start()
        defer { session.stop() }
        let lease = try XCTUnwrap(deliver(.init(action: .snapshot), to: transport, receivedAt: 100).executionLease)
        for invalid in [CompanionExecutionLease(id: UUID(), sessionID: lease.sessionID),
                        CompanionExecutionLease(id: lease.id, sessionID: UUID())] {
            let response = try deliver(.init(action: .next, expectedTrackID: songs[0].id, executionLease: invalid),
                                       to: transport, receivedAt: 100)
            XCTAssertFalse(response.accepted)
            XCTAssertEqual(context.player.currentIndex, 0)
        }
        phoneClock = origin.advanced(by: .seconds(5))
        let response = try deliver(.init(action: .next, expectedTrackID: songs[0].id, executionLease: lease),
                                   to: transport, receivedAt: 100)
        XCTAssertTrue(response.accepted)
        XCTAssertEqual(context.player.currentIndex, 1)
    }

    func testPreviouslyExecutedRequestOnlyReplaysReceiptAfterLeaseExpiry() throws {
        let songs = [libraryTestTrack("a"), libraryTestTrack("b"), libraryTestTrack("c")]
        let context = try makeContext(songs)
        let origin = ContinuousClock.now
        var phoneClock = origin
        let controller = CompanionPlaybackController(model: context.model, monotonicNow: { phoneClock })
        let transport = WatchTestTransport()
        let session = makeSession(transport, controller: controller, clock: { 100 })
        session.start()
        defer { session.stop() }
        let lease = try XCTUnwrap(deliver(.init(action: .snapshot), to: transport, receivedAt: 100).executionLease)
        let request = CompanionRequest(action: .next, expectedTrackID: songs[0].id, executionLease: lease)
        let first = try deliver(request, to: transport, receivedAt: 100)
        XCTAssertTrue(first.accepted)
        phoneClock = origin.advanced(by: .seconds(9))
        let duplicate = try deliver(request, to: transport, receivedAt: 100)
        XCTAssertTrue(duplicate.accepted)
        XCTAssertEqual(duplicate.id, first.id)
        XCTAssertEqual(duplicate.snapshot, first.snapshot)
        XCTAssertEqual(context.player.currentIndex, 1)
        let lateNewIntent = CompanionRequest(action: .next, expectedTrackID: songs[1].id, executionLease: lease)
        XCTAssertFalse(try deliver(lateNewIntent, to: transport, receivedAt: 100).accepted)
        XCTAssertEqual(context.player.currentIndex, 1)
    }

    private func deliver(_ request: CompanionRequest, to transport: WatchTestTransport, receivedAt: TimeInterval) throws -> CompanionResponse {
        let replies = WatchReplyRecorder()
        transport.onEvent?(.request(try CompanionWire.encode(request), WatchReply(receivedAt: receivedAt, handler: replies.record)))
        return try CompanionWire.decode(CompanionResponse.self, from: XCTUnwrap(replies.values.first))
    }

    private func makeContext(_ songs: [Track]) throws -> AppModelTestContext {
        let context = try AppModelTestContext(snapshot: PlaybackSnapshot(queue: songs))
        addTeardownBlock { @MainActor in try await context.close() }
        return context
    }

    private func makeSession(_ transport: WatchTestTransport, controller: CompanionPlaybackController,
                             clock: @escaping @MainActor () -> TimeInterval) -> WatchPhoneSession {
        WatchPhoneSession(transport: transport, snapshot: { controller.snapshot }, handle: { controller.handle($0) },
                          observe: { controller.observe($0) }, removeObserver: { controller.removeObserver($0) }, uptime: clock)
    }
}

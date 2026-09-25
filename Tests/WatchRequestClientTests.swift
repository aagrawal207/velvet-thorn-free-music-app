import XCTest
@testable import GanaBajana

@MainActor
final class WatchRequestClientTests: XCTestCase {
    func testActivationAndCachedSnapshotNeverSendPlaybackOrRefresh() throws {
        let transport = WatchTestTransport()
        let client = WatchRequestClient(transport: transport)
        var received: CompanionSnapshot?
        client.onSnapshot = { received = $0 }
        client.start()
        client.start()
        let snapshot = WatchTestSupport.snapshot(playing: true)
        transport.onEvent?(.applicationContext(try CompanionWire.encode(snapshot)))
        XCTAssertEqual(received, snapshot)
        XCTAssertEqual(transport.activationCount, 1)
        XCTAssertTrue(transport.messages.isEmpty)
    }

    func testDisconnectedCommandIsRejectedWithoutSendingOrQueuing() async throws {
        let transport = WatchTestTransport()
        transport.state = .ready(reachable: false, installed: true, needsUnlock: false)
        let client = WatchRequestClient(transport: transport)
        client.start()
        do {
            _ = try await client.request(CompanionRequest(action: .next, expectedTrackID: "watch-test-track"),
                                         displayed: WatchTestSupport.snapshot())
            XCTFail("Expected an unreachable error")
        } catch { XCTAssertEqual(error as? WatchRequestError, .unreachable) }
        transport.changeState(.ready(reachable: true, installed: true, needsUnlock: false))
        XCTAssertTrue(transport.messages.isEmpty)
    }

    func testRequestIDMustMatchAndMalformedReplyNeverPublishesSnapshot() async throws {
        let transport = WatchTestTransport()
        let client = WatchRequestClient(transport: transport)
        client.start()
        var snapshots = 0
        client.onSnapshot = { _ in snapshots += 1 }
        let first = Task { try await client.request(CompanionRequest(action: .snapshot)) }
        try await WatchTestSupport.waitUntil { transport.messages.count == 1 }
        try transport.reply(at: 0, id: UUID())
        do { _ = try await first.value; XCTFail("Expected a mismatched reply") }
        catch { XCTAssertEqual(error as? WatchRequestError, .mismatchedReply) }

        let second = Task { try await client.request(CompanionRequest(action: .snapshot)) }
        try await WatchTestSupport.waitUntil { transport.messages.count == 2 }
        transport.messages[1].completion(.success(Data("not json".utf8)))
        do { _ = try await second.value; XCTFail("Expected an invalid reply") }
        catch { XCTAssertEqual(error as? WatchRequestError, .invalidReply) }
        XCTAssertEqual(snapshots, 0)
    }

    func testConcurrentReadsMatchTheirOwnOutOfOrderReplies() async throws {
        let transport = WatchTestTransport()
        let client = WatchRequestClient(transport: transport)
        client.start()
        let firstRequest = CompanionRequest(action: .snapshot)
        let secondRequest = CompanionRequest(action: .browse("favorites"))
        let first = Task { try await client.request(firstRequest) }
        try await WatchTestSupport.waitUntil { transport.messages.count == 1 }
        let second = Task { try await client.request(secondRequest) }
        try await WatchTestSupport.waitUntil { transport.messages.count == 2 }
        try transport.reply(at: 1, snapshot: WatchTestSupport.snapshot(sequence: 3))
        try transport.reply(at: 0, snapshot: WatchTestSupport.snapshot(sequence: 2))
        let secondResponse = try await second.value
        let firstResponse = try await first.value
        XCTAssertEqual(firstResponse.id, firstRequest.id)
        XCTAssertEqual(secondResponse.id, secondRequest.id)
        XCTAssertEqual(firstResponse.snapshot.sequence, 2)
        XCTAssertEqual(secondResponse.snapshot.sequence, 3)
    }

    func testOnlyOnePlaybackIntentCanBeInFlight() async throws {
        let transport = WatchTestTransport()
        let client = WatchRequestClient(transport: transport)
        client.start()
        let displayed = WatchTestSupport.snapshot()
        let first = Task {
            try await client.request(CompanionRequest(action: .next, expectedTrackID: "watch-test-track"), displayed: displayed)
        }
        try await WatchTestSupport.waitUntil { transport.messages.count == 1 }
        do {
            _ = try await client.request(CompanionRequest(action: .previous, expectedTrackID: "watch-test-track"), displayed: displayed)
            XCTFail("Expected backpressure")
        } catch { XCTAssertEqual(error as? WatchRequestError, .busy) }
        XCTAssertEqual(transport.messages.count, 1)
        try transport.reply(at: 0)
        try await WatchTestSupport.waitUntil { transport.messages.count == 2 }
        try transport.reply(at: 1)
        _ = try await first.value
    }

    func testDeadlineIgnoresLateReplyAndNeverRetriesCommand() async throws {
        let transport = WatchTestTransport()
        let deadline = WatchTestDeadline()
        let client = WatchRequestClient(transport: transport, waitForDeadline: { try await deadline.wait() })
        client.start()
        let pending = try await sendMutation(on: transport, client: client)
        try await WatchTestSupport.waitForDeadline(deadline, startedCount: 2)
        await deadline.fire()
        do { _ = try await pending.value; XCTFail("Expected a timeout") }
        catch { XCTAssertEqual(error as? WatchRequestError, .timedOut) }
        try transport.reply(at: 1)

        let refresh = Task { try await client.request(CompanionRequest(action: .snapshot)) }
        try await WatchTestSupport.waitUntil { transport.messages.count == 3 }
        try transport.reply(at: 2)
        _ = try await refresh.value
        XCTAssertEqual(transport.requests.map(\.action), [.snapshot, .next, .snapshot])
    }

    func testCancellationCompletesWithoutTransportCooperationAndDoesNotRetry() async throws {
        let transport = WatchTestTransport()
        let client = WatchRequestClient(transport: transport)
        client.start()
        let pending = try await sendMutation(on: transport, client: client)
        pending.cancel()
        do { _ = try await pending.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        try transport.reply(at: 1)
        XCTAssertEqual(transport.requests.map(\.action), [.snapshot, .next])
    }

    func testLateReplyCannotBeatDeadlineWhenTimerHasNotRun() async throws {
        let transport = WatchTestTransport()
        let deadline = WatchTestDeadline()
        var uptime: TimeInterval = 100
        let client = WatchRequestClient(transport: transport, waitForDeadline: { try await deadline.wait() }, uptime: { uptime })
        client.start()
        let pending = try await sendMutation(on: transport, client: client)
        uptime = 109
        try transport.reply(at: 1)
        do { _ = try await pending.value; XCTFail("Expected a non-renewing deadline") }
        catch { XCTAssertEqual(error as? WatchRequestError, .timedOut) }
        XCTAssertEqual(transport.requests.map(\.action), [.snapshot, .next])
    }

    func testReplyDeliveredOffMainActorCompletesOnClientActor() async throws {
        let transport = WatchTestTransport()
        let client = WatchRequestClient(transport: transport)
        client.start()
        let request = CompanionRequest(action: .snapshot)
        let pending = Task { try await client.request(request) }
        try await WatchTestSupport.waitUntil { transport.messages.count == 1 }
        let completion = transport.messages[0].completion
        let response = CompanionResponse(id: request.id, accepted: true, snapshot: WatchTestSupport.snapshot())
        let data = try CompanionWire.encode(response)
        await Task.detached { completion(.success(data)) }.value
        let received = try await pending.value
        XCTAssertEqual(received, response)
    }

    func testConnectionResetRetiresOutstandingRepliesAndReactivates() async throws {
        let transport = WatchTestTransport()
        let client = WatchRequestClient(transport: transport)
        client.start()
        let pending = try await sendMutation(on: transport, client: client)
        transport.changeState(.inactive)
        transport.onEvent?(.deactivated)
        do { _ = try await pending.value; XCTFail("Expected a retired request") }
        catch { XCTAssertEqual(error as? WatchRequestError, .connectionChanged) }
        XCTAssertEqual(transport.activationCount, 2)
        transport.changeState(.ready(reachable: true, installed: true, needsUnlock: false))
        let refresh = Task { try await client.request(CompanionRequest(action: .snapshot)) }
        try await WatchTestSupport.waitUntil { transport.messages.count == 3 }
        try transport.reply(at: 1, snapshot: WatchTestSupport.snapshot(sequence: 99))
        try transport.reply(at: 2, snapshot: WatchTestSupport.snapshot(sequence: 1))
        let response = try await refresh.value
        XCTAssertEqual(response.snapshot.sequence, 1)
        XCTAssertEqual(transport.requests.map(\.action), [.snapshot, .next, .snapshot])
    }

    func testOversizedReplyAndContextAreRejectedBeforeUse() async throws {
        let transport = WatchTestTransport()
        let client = WatchRequestClient(transport: transport)
        client.start()
        var contexts = 0
        client.onSnapshot = { _ in contexts += 1 }
        let oversized = Data(repeating: 32, count: CompanionWire.maximumMessageBytes + 1)
        transport.onEvent?(.applicationContext(oversized))
        let pending = Task { try await client.request(CompanionRequest(action: .snapshot)) }
        try await WatchTestSupport.waitUntil { transport.messages.count == 1 }
        transport.messages[0].completion(.success(oversized))
        do { _ = try await pending.value; XCTFail("Expected a bounded reply") }
        catch { XCTAssertEqual(error as? WatchRequestError, .invalidReply) }
        XCTAssertEqual(contexts, 0)
    }

    func testInvalidVersionNeverReachesTransport() async throws {
        let transport = WatchTestTransport()
        let client = WatchRequestClient(transport: transport)
        client.start()
        do {
            _ = try await client.request(CompanionRequest(version: 2, action: .play))
            XCTFail("Expected version validation")
        } catch { XCTAssertEqual(error as? CompanionWireError, .unsupportedVersion) }
        XCTAssertTrue(transport.messages.isEmpty)
    }

    private func sendMutation(on transport: WatchTestTransport, client: WatchRequestClient) async throws -> Task<CompanionResponse, any Error> {
        let start = transport.messages.count
        let displayed = WatchTestSupport.snapshot()
        let request = CompanionRequest(action: .next, expectedTrackID: displayed.nowPlaying?.trackID)
        let task = Task { try await client.request(request, displayed: displayed) }
        do {
            try await WatchTestSupport.waitUntil { transport.messages.count == start + 1 }
            XCTAssertEqual(transport.requests[start].action, .snapshot)
            try transport.reply(at: start, snapshot: displayed)
            try await WatchTestSupport.waitUntil { transport.messages.count == start + 2 }
            return task
        } catch {
            task.cancel()
            throw error
        }
    }
}

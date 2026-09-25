import XCTest
@testable import GanaBajana

@MainActor
final class WatchMutationLeaseTests: XCTestCase {
    func testFreshPreflightLeasePreservesMutationIDActionAndTrack() async throws {
        let transport = WatchTestTransport()
        let client = WatchRequestClient(transport: transport)
        client.start()
        let displayed = WatchTestSupport.snapshot()
        let request = CompanionRequest(action: .next, expectedTrackID: displayed.nowPlaying?.trackID)
        let mutation = Task { try await client.request(request, displayed: displayed) }
        defer { mutation.cancel() }
        try await WatchTestSupport.waitUntil { transport.messages.count == 1 }
        XCTAssertEqual(transport.requests[0].action, .snapshot)
        XCTAssertNil(transport.requests[0].executionLease)
        XCTAssertNotEqual(transport.requests[0].id, request.id)
        let lease = CompanionExecutionLease(id: UUID(), sessionID: displayed.sessionID)
        try transport.reply(at: 0, snapshot: WatchTestSupport.snapshot(sequence: 2, position: 43), executionLease: lease)
        try await WatchTestSupport.waitUntil { transport.messages.count == 2 }
        let sent = transport.requests[1]
        XCTAssertEqual(sent.id, request.id)
        XCTAssertEqual(sent.action, request.action)
        XCTAssertEqual(sent.expectedTrackID, request.expectedTrackID)
        XCTAssertEqual(sent.executionLease, lease)
        try transport.reply(at: 1, snapshot: WatchTestSupport.snapshot(sequence: 3, trackID: "next-song"))
        let result = try await mutation.value
        XCTAssertEqual(result.id, request.id)
        XCTAssertTrue(result.accepted)
    }

    func testEveryMutationPreflightsInsteadOfReusingSuppliedLease() async throws {
        let transport = WatchTestTransport()
        transport.automaticResponse = { WatchTestSupport.response(for: $0) }
        let client = WatchRequestClient(transport: transport)
        client.start()
        let displayed = WatchTestSupport.snapshot()
        let staleLease = CompanionExecutionLease(id: UUID(), sessionID: displayed.sessionID)
        for action in [CompanionAction.setFavorite(true), .setShuffle(true)] {
            let request = CompanionRequest(action: action, expectedTrackID: displayed.nowPlaying?.trackID, executionLease: staleLease)
            _ = try await client.request(request, displayed: displayed)
        }
        XCTAssertEqual(transport.requests.map(\.action), [.snapshot, .setFavorite(true), .snapshot, .setShuffle(true)])
        let firstLease = try XCTUnwrap(transport.requests[1].executionLease)
        let secondLease = try XCTUnwrap(transport.requests[3].executionLease)
        XCTAssertNotEqual(firstLease.id, staleLease.id)
        XCTAssertNotEqual(secondLease.id, staleLease.id)
        XCTAssertNotEqual(firstLease.id, secondLease.id)
    }

    func testMissingLeaseStopsBeforeMutation() async throws {
        let transport = WatchTestTransport()
        transport.automaticResponse = { WatchTestSupport.response(for: $0, includeLease: false) }
        let client = WatchRequestClient(transport: transport)
        client.start()
        let displayed = WatchTestSupport.snapshot()
        do {
            _ = try await client.request(.init(action: .next, expectedTrackID: displayed.nowPlaying?.trackID), displayed: displayed)
            XCTFail("Expected a lease requirement")
        } catch { XCTAssertEqual(error as? WatchRequestError, .leaseUnavailable) }
        XCTAssertEqual(transport.requests.map(\.action), [.snapshot])
    }

    func testChangedPhoneProcessTrackOrLeaseSessionCannotRetargetMutation() async throws {
        let displayed = WatchTestSupport.snapshot()
        let replies = [
            WatchTestSupport.snapshot(sessionID: UUID()),
            WatchTestSupport.snapshot(sequence: 2, trackID: "new-song"),
            displayed
        ]
        for (index, snapshot) in replies.enumerated() {
            let transport = WatchTestTransport()
            transport.automaticResponse = {
                WatchTestSupport.response(for: $0, snapshot: snapshot,
                                          executionLease: .init(id: UUID(), sessionID: index == 2 ? UUID() : snapshot.sessionID))
            }
            let client = WatchRequestClient(transport: transport)
            client.start()
            do {
                _ = try await client.request(.init(action: .next, expectedTrackID: displayed.nowPlaying?.trackID), displayed: displayed)
                XCTFail("Expected captured context rejection")
            } catch { XCTAssertEqual(error as? WatchRequestError, .staleContext) }
            XCTAssertEqual(transport.requests.map(\.action), [.snapshot])
        }
    }

    func testPreflightValidatesDisplayedControlValues() async throws {
        let displayed = WatchTestSupport.snapshot(playing: false)
        let changes: [(CompanionAction, CompanionSnapshot)] = [
            (.play, WatchTestSupport.snapshot(sequence: 2, playing: true)),
            (.pause, WatchTestSupport.snapshot(sequence: 2, playing: false, loading: true)),
            (.setFavorite(true), WatchTestSupport.snapshot(sequence: 2, playing: false, favorite: true)),
            (.setShuffle(true), WatchTestSupport.snapshot(sequence: 2, playing: false, shuffle: true)),
            (.setRepeatMode(.all), WatchTestSupport.snapshot(sequence: 2, playing: false, repeatMode: .one))
        ]
        for (action, current) in changes {
            let transport = WatchTestTransport()
            transport.automaticResponse = { WatchTestSupport.response(for: $0, snapshot: current) }
            let client = WatchRequestClient(transport: transport)
            client.start()
            do {
                _ = try await client.request(.init(action: action, expectedTrackID: displayed.nowPlaying?.trackID), displayed: displayed)
                XCTFail("Expected displayed-value rejection for \(action)")
            } catch { XCTAssertEqual(error as? WatchRequestError, .staleContext) }
            XCTAssertEqual(transport.requests.map(\.action), [.snapshot])
        }
    }

    func testDispatchValidationCanRejectNewerLocalContextAfterPreflight() async throws {
        let transport = WatchTestTransport()
        transport.automaticResponse = { WatchTestSupport.response(for: $0) }
        let client = WatchRequestClient(transport: transport)
        client.start()
        let displayed = WatchTestSupport.snapshot()
        var didDispatch = false
        do {
            _ = try await client.request(.init(action: .next, expectedTrackID: displayed.nowPlaying?.trackID), displayed: displayed,
                                         validateBeforeMutation: { _ in false }, willSendMutation: { didDispatch = true })
            XCTFail("Expected final local validation")
        } catch { XCTAssertEqual(error as? WatchRequestError, .staleContext) }
        XCTAssertFalse(didDispatch)
        XCTAssertEqual(transport.requests.map(\.action), [.snapshot])
    }

    func testPreflightTimeoutDoesNotSendOrRetryMutation() async throws {
        let transport = WatchTestTransport()
        let deadline = WatchTestDeadline()
        let client = WatchRequestClient(transport: transport, waitForDeadline: { try await deadline.wait() })
        client.start()
        let displayed = WatchTestSupport.snapshot()
        let mutation = Task {
            try await client.request(.init(action: .next, expectedTrackID: displayed.nowPlaying?.trackID), displayed: displayed)
        }
        defer { mutation.cancel() }
        try await WatchTestSupport.waitUntil { transport.messages.count == 1 }
        try await WatchTestSupport.waitForDeadline(deadline)
        await deadline.fire()
        do { _ = try await mutation.value; XCTFail("Expected preflight timeout") }
        catch { XCTAssertEqual(error as? WatchRequestError, .timedOut) }
        try transport.reply(at: 0)
        XCTAssertEqual(transport.requests.map(\.action), [.snapshot])
    }

    func testPreflightCancellationCannotSendMutationAfterLateLeaseReply() async throws {
        let transport = WatchTestTransport()
        let client = WatchRequestClient(transport: transport)
        client.start()
        let displayed = WatchTestSupport.snapshot()
        let mutation = Task {
            try await client.request(.init(action: .next, expectedTrackID: displayed.nowPlaying?.trackID), displayed: displayed)
        }
        try await WatchTestSupport.waitUntil { transport.messages.count == 1 }
        mutation.cancel()
        do { _ = try await mutation.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        try transport.reply(at: 0)
        XCTAssertEqual(transport.requests.map(\.action), [.snapshot])
    }

    func testMutationDeadlineStartsAfterPreflightReceipt() async throws {
        let transport = WatchTestTransport()
        let deadline = WatchTestDeadline()
        var clock: TimeInterval = 100
        let client = WatchRequestClient(transport: transport, waitForDeadline: { try await deadline.wait() }, uptime: { clock })
        client.start()
        let displayed = WatchTestSupport.snapshot()
        let mutation = Task {
            try await client.request(.init(action: .next, expectedTrackID: displayed.nowPlaying?.trackID), displayed: displayed)
        }
        defer { mutation.cancel() }
        try await WatchTestSupport.waitUntil { transport.messages.count == 1 }
        clock = 107
        try transport.reply(at: 0)
        try await WatchTestSupport.waitUntil { transport.messages.count == 2 }
        clock = 114
        try transport.reply(at: 1)
        let response = try await mutation.value
        XCTAssertTrue(response.accepted)
        XCTAssertEqual(transport.requests.map(\.action), [.snapshot, .next])
    }
}

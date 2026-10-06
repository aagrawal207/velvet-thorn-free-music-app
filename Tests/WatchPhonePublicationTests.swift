import XCTest
@testable import GanaBajana

@MainActor
final class WatchPhonePublicationTests: XCTestCase {
    func testOneHundredPositionTicksPublishAtMostOnceEveryTenSeconds() throws {
        let transport = WatchTestTransport()
        let playback = WatchPhonePlaybackSpy()
        playback.snapshot = WatchTestSupport.snapshot()
        var clock: TimeInterval = 0
        let session = makeSession(transport, playback: playback, clock: { clock })
        session.start()
        defer { session.stop() }
        for tick in 1...100 {
            clock = Double(tick) * 0.5
            playback.publish(WatchTestSupport.snapshot(sequence: UInt64(tick + 1), position: 42 + clock))
        }
        XCTAssertEqual(transport.contexts.count, 6)
        XCTAssertEqual(transport.contextAttempts, 6)
        let last = try CompanionWire.decode(CompanionSnapshot.self, from: XCTUnwrap(transport.contexts.last))
        XCTAssertEqual(last.sequence, 101)
        XCTAssertEqual(last.nowPlaying?.position, 92)
    }

    func testOfflinePositionTicksSendNothingAndReconnectUsesLatestState() throws {
        let transport = WatchTestTransport()
        let playback = WatchPhonePlaybackSpy()
        playback.snapshot = WatchTestSupport.snapshot()
        var clock: TimeInterval = 0
        let session = makeSession(transport, playback: playback, clock: { clock })
        session.start()
        defer { session.stop() }
        transport.changeState(.ready(reachable: false, installed: true, needsUnlock: false))
        let baseline = transport.contextAttempts
        for tick in 1...100 {
            clock = Double(tick) * 0.5
            playback.publish(WatchTestSupport.snapshot(sequence: UInt64(tick + 1), position: 42 + clock))
        }
        XCTAssertEqual(transport.contextAttempts - baseline, 0)
        transport.changeState(.ready(reachable: true, installed: true, needsUnlock: false))
        XCTAssertEqual(transport.contextAttempts, baseline + 1)
        let last = try CompanionWire.decode(CompanionSnapshot.self, from: XCTUnwrap(transport.contexts.last))
        XCTAssertEqual(last.sequence, 101)
        XCTAssertEqual(last.nowPlaying?.position, 92)
    }

    func testSemanticChangesPublishImmediatelyEvenWhileUnreachable() throws {
        let changes = [
            WatchTestSupport.snapshot(sequence: 2, playing: false),
            WatchTestSupport.snapshot(sequence: 3, loading: true),
            WatchTestSupport.snapshot(sequence: 4, error: "Playback stopped"),
            WatchTestSupport.snapshot(sequence: 5, favorite: true),
            WatchTestSupport.snapshot(sequence: 6, shuffle: true),
            WatchTestSupport.snapshot(sequence: 7, repeatMode: .one),
            WatchTestSupport.snapshot(sequence: 8, duration: 220),
            WatchTestSupport.snapshot(sequence: 9, title: "New title"),
            WatchTestSupport.snapshot(sequence: 10, artist: "New artist"),
            WatchTestSupport.snapshot(sequence: 11, trackID: "new-song"),
            WatchTestSupport.snapshot(sequence: 12, libraryError: "Open Velvet Thorn on iPhone to recover your library."),
            WatchTestSupport.snapshot(sequence: 13, accent: .violet),
            WatchTestSupport.snapshot(sequence: 14, empty: true)
        ]
        for snapshot in changes {
            let transport = WatchTestTransport()
            transport.state = .ready(reachable: false, installed: true, needsUnlock: false)
            let playback = WatchPhonePlaybackSpy()
            playback.snapshot = WatchTestSupport.snapshot()
            var clock: TimeInterval = 0
            let session = makeSession(transport, playback: playback, clock: { clock })
            session.start()
            clock = 0.1
            playback.publish(snapshot)
            XCTAssertEqual(transport.contexts.count, 2)
            XCTAssertEqual(try CompanionWire.decode(CompanionSnapshot.self, from: XCTUnwrap(transport.contexts.last)), snapshot)
            session.stop()
        }
    }

    func testLibraryRecoveryPublishesImmediatelyWithoutChangingPlayback() throws {
        let transport = WatchTestTransport()
        transport.state = .ready(reachable: false, installed: true, needsUnlock: false)
        let playback = WatchPhonePlaybackSpy()
        playback.snapshot = WatchTestSupport.snapshot(libraryError: "Recover the library on iPhone.")
        let session = makeSession(transport, playback: playback, clock: { 0 })
        session.start()
        defer { session.stop() }
        let recovered = WatchTestSupport.snapshot(sequence: 2)
        playback.publish(recovered)
        XCTAssertEqual(transport.contexts.count, 2)
        XCTAssertEqual(try CompanionWire.decode(CompanionSnapshot.self, from: XCTUnwrap(transport.contexts.last)), recovered)
    }

    func testTrailingPublicationRetainsLatestPositionWithoutAnotherTick() async throws {
        let transport = WatchTestTransport()
        let playback = WatchPhonePlaybackSpy()
        playback.snapshot = WatchTestSupport.snapshot()
        let deadline = WatchTestDeadline()
        var clock: TimeInterval = 0
        let session = makeSession(transport, playback: playback, clock: { clock }, wait: { _ in try await deadline.wait() })
        session.start()
        defer { session.stop() }
        for tick in 1...9 {
            clock = Double(tick)
            playback.publish(WatchTestSupport.snapshot(sequence: UInt64(tick + 1), position: 42 + clock))
        }
        XCTAssertEqual(transport.contexts.count, 1)
        try await WatchTestSupport.waitForDeadline(deadline)
        clock = 10
        await deadline.fire()
        try await WatchTestSupport.waitUntil { transport.contexts.count == 2 }
        let last = try CompanionWire.decode(CompanionSnapshot.self, from: XCTUnwrap(transport.contexts.last))
        XCTAssertEqual(last.sequence, 10)
        XCTAssertEqual(last.nowPlaying?.position, 51)
    }

    func testFailedPublicationRetriesAtBoundedCadenceWithLatestState() throws {
        let transport = WatchTestTransport()
        transport.rejectsContext = true
        let playback = WatchPhonePlaybackSpy()
        playback.snapshot = WatchTestSupport.snapshot()
        var clock: TimeInterval = 0
        let session = makeSession(transport, playback: playback, clock: { clock })
        session.start()
        defer { session.stop() }
        for tick in 1...100 {
            clock = Double(tick) * 0.5
            playback.publish(WatchTestSupport.snapshot(sequence: UInt64(tick + 1), position: 42 + clock))
        }
        XCTAssertTrue(session.contextNeedsRetry)
        XCTAssertEqual(transport.contextAttempts, 6)
        XCTAssertTrue(transport.contexts.isEmpty)
        transport.rejectsContext = false
        clock = 60
        transport.refreshState()
        XCTAssertFalse(session.contextNeedsRetry)
        XCTAssertEqual(transport.contextAttempts, 7)
        let last = try CompanionWire.decode(CompanionSnapshot.self, from: XCTUnwrap(transport.contexts.last))
        XCTAssertEqual(last.sequence, 101)
    }

    func testBecomingUnreachableCancelsPendingPositionPublication() async throws {
        let transport = WatchTestTransport()
        let playback = WatchPhonePlaybackSpy()
        playback.snapshot = WatchTestSupport.snapshot()
        let deadline = WatchTestDeadline()
        var clock: TimeInterval = 0
        let session = makeSession(transport, playback: playback, clock: { clock }, wait: { _ in try await deadline.wait() })
        session.start()
        defer { session.stop() }
        clock = 1
        playback.publish(WatchTestSupport.snapshot(sequence: 2, position: 43))
        try await WatchTestSupport.waitForDeadline(deadline)
        transport.changeState(.ready(reachable: false, installed: true, needsUnlock: false))
        clock = 20
        await deadline.fire()
        await Task.yield()
        XCTAssertEqual(transport.contexts.count, 1)
    }

    private func makeSession(_ transport: WatchTestTransport, playback: WatchPhonePlaybackSpy,
                             clock: @escaping @MainActor () -> TimeInterval,
                             wait: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) -> WatchPhoneSession {
        WatchPhoneSession(transport: transport, snapshot: { playback.snapshot }, handle: { playback.handle($0) },
                          observe: { playback.observe($0) }, removeObserver: { playback.observers[$0] = nil },
                          uptime: clock, waitForPublication: wait)
    }
}

import Foundation
import Network
import XCTest
@testable import GanaBajana

// MARK: - Protocol

final class NearbyLinkProtocolTests: XCTestCase {
    func testSplitAndMergedFramesDecodeInOrder() throws {
        let first = Data("first".utf8)
        let second = Data(repeating: 7, count: 70_000)
        let stream = try NearbyLinkWire.frame(first) + NearbyLinkWire.frame(second)

        var merged = NearbyFrameDecoder()
        XCTAssertEqual(try merged.append(stream), [first, second])
        XCTAssertEqual(merged.bufferedBytes, 0)

        var split = NearbyFrameDecoder()
        var frames: [Data] = []
        for byte in stream { frames += try split.append(Data([byte])) }
        XCTAssertEqual(frames, [first, second])

        var uneven = NearbyFrameDecoder()
        let cut = 6
        XCTAssertEqual(try uneven.append(stream.prefix(cut)), [])
        XCTAssertEqual(try uneven.append(stream.dropFirst(cut)), [first, second])
    }

    func testOversizeFrameIsRejectedBeforeItsPayloadIsBuffered() throws {
        var length = UInt32(NearbyLinkWire.maximumFrameBytes + 1).bigEndian
        var header = Data(bytes: &length, count: 4)
        header.append(Data(repeating: 1, count: 1_024))
        var decoder = NearbyFrameDecoder()
        XCTAssertThrowsError(try decoder.append(header)) { XCTAssertEqual($0 as? NearbyLinkError, .oversizedFrame) }
        XCTAssertEqual(decoder.bufferedBytes, 0)
        XCTAssertThrowsError(try decoder.append(Data([0]))) { XCTAssertEqual($0 as? NearbyLinkError, .decoderClosed) }

        var exact = UInt32(NearbyLinkWire.maximumFrameBytes).bigEndian
        var accepted = NearbyFrameDecoder()
        XCTAssertEqual(try accepted.append(Data(bytes: &exact, count: 4)), [])
        XCTAssertThrowsError(try NearbyLinkWire.frame(Data(repeating: 0, count: NearbyLinkWire.maximumFrameBytes + 1))) {
            XCTAssertEqual($0 as? NearbyLinkError, .oversizedFrame)
        }
    }

    func testZeroLengthFrameFailsClosed() throws {
        var decoder = NearbyFrameDecoder()
        XCTAssertThrowsError(try decoder.append(Data([0, 0, 0, 0, 9]))) { XCTAssertEqual($0 as? NearbyLinkError, .emptyFrame) }
        XCTAssertThrowsError(try NearbyLinkWire.frame(Data())) { XCTAssertEqual($0 as? NearbyLinkError, .emptyFrame) }
        XCTAssertThrowsError(try NearbyLinkWire.decode(Data())) { XCTAssertEqual($0 as? NearbyLinkError, .emptyFrame) }
    }

    func testEveryMessageRoundTrips() throws {
        let id = UUID()
        let snapshot = nearbyTestCompanionSnapshot()
        let offer = try NearbyTransferOffer(id: id, snapshot: PlaybackSnapshot(queue: [nearbyTestTrack("a"), nearbyTestTrack("b")],
                                                                                currentIndex: 1, position: 12, shuffleEnabled: true,
                                                                                repeatMode: .all),
                                            wasPlaying: true, position: 12.5)
        let messages: [NearbyLinkMessage] = [
            .hello(NearbyPeerHello(installationID: id, displayName: "Kitchen iPad", deviceKind: .iPad)),
            .snapshot(NearbyNowPlaying(snapshot: snapshot, artworkURL: URL(string: "https://img.example/a.jpg"))),
            .request(CompanionRequest(action: .seek(30), expectedTrackID: "a",
                                      executionLease: CompanionExecutionLease(id: UUID(), sessionID: UUID()))),
            .response(CompanionResponse(id: id, accepted: false, snapshot: snapshot, error: "No")),
            .transferRequest(id: id), .transferOffer(offer), .transferReady(id: id),
            .transferReleased(id: id, position: 44.25, playing: false), .transferPush(id: id),
            .transferCancel(id: id, reason: .liveRadio), .ping(id: id, sentUptime: 12.5), .pong(id: id, sentUptime: 12.5),
            .pairingRequest(try NearbyPairingRequest(publicKey: Data(repeating: 1, count: 32))),
            .pairingGrant(try NearbyPairingGrant(publicKey: Data(repeating: 2, count: 32), sealedLinkKey: Data(repeating: 3, count: 60))),
        ]
        for message in messages {
            XCTAssertEqual(try NearbyLinkWire.decode(NearbyLinkWire.encode(message)), message, message.kind)
        }
    }

    func testEnvelopeFailsClosedOnUnknownCasesExtraKeysAndVersions() throws {
        let id = UUID().uuidString
        let cases: [(String, NearbyLinkError)] = [
            (#"{"version":1,"teleport":{"id":"\#(id)"}}"#, .malformed),
            (#"{"version":1}"#, .malformed),
            (#"{"transferReady":{"id":"\#(id)"}}"#, .malformed),
            (#"{"version":2,"transferReady":{"id":"\#(id)"}}"#, .unsupportedVersion),
            (#"{"version":1,"transferReady":{"id":"\#(id)"},"extra":1}"#, .malformed),
            (#"{"version":1,"transferReady":{"id":"\#(id)"},"transferPush":{"id":"\#(id)"}}"#, .malformed),
            (#"{"version":1,"transferReady":{"id":"\#(id)","position":1}}"#, .malformed),
            (#"{"version":1,"transferCancel":{"id":"\#(id)","reason":"bored"}}"#, .malformed),
            (#"{"version":1,"transferReleased":{"id":"\#(id)","position":-1,"playing":true}}"#, .invalidTransfer),
            (#"{"version":1,"transferReleased":{"id":"\#(id)","position":4}}"#, .malformed),
            (#"{"version":1,"transferReleased":{"id":"\#(id)","position":4,"playing":"yes"}}"#, .malformed),
            (#"{"version":1,"ping":{"id":"\#(id)","sentUptime":-3}}"#, .malformed),
            (#"{"version":1,"hello":{"installationID":"\#(id)","displayName":"A","deviceKind":"watch","wireVersion":1,"companionWireVersion":2}}"#, .malformed),
            (#"{"version":1,"hello":{"installationID":"\#(id)","displayName":"A","deviceKind":"mac","wireVersion":2,"companionWireVersion":2}}"#, .unsupportedVersion),
            (#"{"version":1,"hello":{"installationID":"\#(id)","displayName":"A","deviceKind":"mac","wireVersion":1,"companionWireVersion":1}}"#, .unsupportedVersion),
            (#"{"version":1,"hello":{"installationID":"\#(id)","displayName":"A","deviceKind":"mac","wireVersion":1,"companionWireVersion":2,"model":"x"}}"#, .malformed),
            (#"{"version":1,"pairingRequest":{"publicKey":"AQID"}}"#, .malformed),
        ]
        for (json, expected) in cases {
            XCTAssertThrowsError(try NearbyLinkWire.decode(Data(json.utf8)), json) { error in
                XCTAssertEqual(error as? NearbyLinkError, expected, json)
            }
        }
        // A version-1 Companion request inside a valid envelope is refused by the Companion contract itself.
        let legacy = #"{"version":1,"request":{"version":1,"id":"\#(id)","action":{"play":{}}}}"#
        XCTAssertThrowsError(try NearbyLinkWire.decode(Data(legacy.utf8)))
    }

    func testHelloBoundsDisplayName() throws {
        let hello = NearbyPeerHello(installationID: UUID(), displayName: String(repeating: "é", count: 2_000), deviceKind: .mac)
        XCTAssertLessThanOrEqual(hello.displayName.utf8.count, CompanionWire.maximumTextBytes)
        XCTAssertEqual(NearbyPeerHello(installationID: UUID(), displayName: "   ", deviceKind: .iPhone).displayName, "iPhone")
    }

    func testArtworkURLKeepsOnlyBoundedHTTPS() throws {
        let snapshot = nearbyTestCompanionSnapshot()
        XCTAssertNotNil(NearbyNowPlaying(snapshot: snapshot, artworkURL: URL(string: "https://img.example/a.jpg")).artworkURL)
        XCTAssertNil(NearbyNowPlaying(snapshot: snapshot, artworkURL: URL(string: "http://img.example/a.jpg")).artworkURL)
        XCTAssertNil(NearbyNowPlaying(snapshot: snapshot, artworkURL: URL(string: "file:///etc/hosts")).artworkURL)
        let long = "https://img.example/" + String(repeating: "a", count: NearbyLinkWire.maximumArtworkURLBytes)
        XCTAssertNil(NearbyNowPlaying(snapshot: snapshot, artworkURL: URL(string: long)).artworkURL)
        let empty = CompanionSnapshot(sessionID: UUID(), sequence: 1, updatedAt: Date(timeIntervalSinceReferenceDate: 0), nowPlaying: nil)
        XCTAssertNil(NearbyNowPlaying(snapshot: empty, artworkURL: URL(string: "https://img.example/a.jpg")).artworkURL)

        // An unsafe URL on the wire costs only the artwork, never the snapshot.
        let encoded = try JSONEncoder().encode(snapshot)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object = ["snapshot": object, "artworkURL": "http://img.example/a.jpg"]
        let envelope: [String: Any] = ["version": 1, "snapshot": object]
        let decoded = try NearbyLinkWire.decode(JSONSerialization.data(withJSONObject: envelope))
        guard case .snapshot(let nowPlaying) = decoded else { return XCTFail("Expected a snapshot") }
        XCTAssertNil(nowPlaying.artworkURL)
        XCTAssertEqual(nowPlaying.snapshot, snapshot)

        let offer = try NearbyTransferOffer(id: UUID(), snapshot: PlaybackSnapshot(queue: [
            nearbyTestTrack("a", artwork: "http://img.example/a.jpg"), nearbyTestTrack("b", artwork: "https://img.example/b.jpg"),
        ]), wasPlaying: false, position: 0)
        XCTAssertNil(offer.snapshot.queue[0].artworkURL)
        XCTAssertEqual(offer.snapshot.queue[1].artworkURL?.absoluteString, "https://img.example/b.jpg")
    }

    func testTransferOfferBounds() throws {
        XCTAssertEqual(NearbyLinkWire.maximumQueueOccurrences, PlaybackHandoffCodec.maximumQueueCount)
        let tracks = (0..<NearbyLinkWire.maximumQueueOccurrences).map { nearbyTestTrack("t\($0)") }
        XCTAssertNoThrow(try NearbyTransferOffer(id: UUID(), snapshot: PlaybackSnapshot(queue: tracks), wasPlaying: true, position: 0))
        let invalid: [(PlaybackSnapshot, Double)] = [
            (PlaybackSnapshot(queue: tracks + [nearbyTestTrack("extra")]), 0),
            (PlaybackSnapshot(queue: []), 0),
            (PlaybackSnapshot(queue: [nearbyTestTrack("a")], currentIndex: 1), 0),
            (PlaybackSnapshot(queue: [nearbyTestTrack("a")]), .nan),
            (PlaybackSnapshot(queue: [nearbyTestTrack("a")]), -1),
            (PlaybackSnapshot(queue: [nearbyTestTrack("a")], position: .infinity), 0),
            (PlaybackSnapshot(queue: [nearbyTestTrack("a")], originalQueueIndices: [0, 1]), 0),
            (PlaybackSnapshot(queue: [nearbyTestTrack("a"), nearbyTestTrack("b")], originalQueue: [nearbyTestTrack("a")],
                              originalQueueIndices: [0, 1]), 0),
            (PlaybackSnapshot(queue: [nearbyTestTrack("")]), 0),
        ]
        for (snapshot, position) in invalid {
            XCTAssertThrowsError(try NearbyTransferOffer(id: UUID(), snapshot: snapshot, wasPlaying: true, position: position)) {
                XCTAssertEqual($0 as? NearbyLinkError, .invalidTransfer)
            }
        }
        let heavy = (0..<NearbyLinkWire.maximumQueueOccurrences).map {
            Track(id: "h\($0)", title: String(repeating: "x", count: 2_400), artists: ["A"], duration: 200)
        }
        let offer = try NearbyTransferOffer(id: UUID(), snapshot: PlaybackSnapshot(queue: heavy), wasPlaying: true, position: 0)
        XCTAssertThrowsError(try NearbyLinkWire.encode(.transferOffer(offer))) { XCTAssertEqual($0 as? NearbyLinkError, .oversizedFrame) }
    }

    func testControlMessagesKeepTheCompanionBound() throws {
        let snapshot = nearbyTestCompanionSnapshot()
        let page = CompanionPage(location: "queue", title: "Queue", revision: "r1",
                                 items: (0..<40).map { CompanionItem(id: "item:\($0)", title: String(repeating: "t", count: 380),
                                                                     subtitle: String(repeating: "s", count: 380)) },
                                 isTruncated: false)
        XCTAssertNoThrow(try NearbyLinkWire.encode(.response(CompanionResponse(id: UUID(), accepted: true, snapshot: snapshot, page: page))))
        var json = try XCTUnwrap(String(data: NearbyLinkWire.encode(.transferReady(id: UUID())), encoding: .utf8))
        json.insert(contentsOf: String(repeating: " ", count: NearbyLinkWire.maximumControlFrameBytes), at: json.index(after: json.startIndex))
        XCTAssertThrowsError(try NearbyLinkWire.decode(Data(json.utf8))) { XCTAssertEqual($0 as? NearbyLinkError, .oversizedFrame) }
    }

    func testSemanticComparisonIgnoresPositionOnly() {
        let base = nearbyTestCompanionSnapshot(position: 10)
        let moved = nearbyTestCompanionSnapshot(position: 14, sequence: 2, sessionID: base.sessionID)
        let paused = nearbyTestCompanionSnapshot(position: 14, isPlaying: false, sequence: 3, sessionID: base.sessionID)
        let a = NearbyNowPlaying(snapshot: base, artworkURL: nil)
        XCTAssertTrue(a.hasSameSemantics(as: NearbyNowPlaying(snapshot: moved, artworkURL: nil)))
        XCTAssertFalse(a.hasSameSemantics(as: NearbyNowPlaying(snapshot: paused, artworkURL: nil)))
        XCTAssertFalse(a.hasSameSemantics(as: NearbyNowPlaying(snapshot: moved, artworkURL: URL(string: "https://img.example/x.jpg"))))
    }

    func testLinkKeyAndPairingExchange() throws {
        let store = InMemoryNearbyLinkKeyStore()
        let key = try NearbyLinkKey.current(in: store)
        XCTAssertEqual(key.count, 32)
        XCTAssertEqual(try NearbyLinkKey.current(in: store), key)
        store.key = Data(repeating: 1, count: 16)
        let replaced = try NearbyLinkKey.current(in: store)
        XCTAssertEqual(replaced.count, 32)
        XCTAssertNotEqual(replaced, Data(repeating: 1, count: 16))
        XCTAssertNotEqual(NearbyLinkKey.tlsPSK(linkKey: key), key)
        let first = "7K2MQX9D4RTV8B1C"
        let second = "7K2MQX9D4RTV8B1D"
        // Entry forms of one code derive one PSK; any other code derives another.
        XCTAssertEqual(NearbyLinkKey.pairingPSK(code: first), NearbyLinkKey.pairingPSK(code: "7k2m-qx9d 4rtv-8b1c"))
        XCTAssertEqual(NearbyLinkKey.pairingPSK(code: first), NearbyLinkKey.pairingPSK(code: "7K2M-QX9D-4RTV-8BIC"))
        XCTAssertNotEqual(NearbyLinkKey.pairingPSK(code: first), NearbyLinkKey.pairingPSK(code: second))

        let joiner = try NearbyPairing.makeJoiner()
        let grant = try NearbyPairing.grant(for: joiner.request, linkKey: key, code: first)
        XCTAssertEqual(try NearbyPairing.accept(grant, joiner: joiner, code: first), key)
        XCTAssertEqual(try NearbyPairing.accept(grant, joiner: joiner, code: "7k2m-qx9d-4rtv-8b1c"), key)
        XCTAssertThrowsError(try NearbyPairing.accept(grant, joiner: joiner, code: second))
        XCTAssertThrowsError(try NearbyPairing.accept(grant, joiner: NearbyPairing.makeJoiner(), code: first))
        XCTAssertThrowsError(try NearbyPairing.grant(for: joiner.request, linkKey: key, code: "123456"))

        var code = NearbyPairingCode.generate(at: 100)
        XCTAssertEqual(code.code.count, 16)
        XCTAssertTrue(code.code.allSatisfy { NearbyPairingCode.alphabet.contains($0) })
        XCTAssertTrue(NearbyPairingCode.isWellFormed(code.code))
        XCTAssertEqual(code.display.count, 19)
        XCTAssertEqual(code.display.split(separator: "-").map(\.count), [4, 4, 4, 4])
        XCTAssertEqual(NearbyPairingCode.normalized(code.display), code.code)
        XCTAssertEqual(NearbyPairingCode.normalized(code.display.lowercased()), code.code)
        XCTAssertEqual(NearbyPairingCode.normalized(" 7k2m qx9d-4rtv  8b1c\n"), first)
        XCTAssertEqual(NearbyPairingCode.normalized("OOOO-IIII-LLLL-0000"), "0000111111110000")
        for invalid in ["7K2MQX9D4RTV8B1", "7K2MQX9D4RTV8B1CX", "7K2MQX9D4RTV8B1U", "7K2M_QX9D4RTV8B1C", "123456", ""] {
            XCTAssertNil(NearbyPairingCode.normalized(invalid), invalid)
            XCTAssertFalse(NearbyPairingCode.isWellFormed(invalid), invalid)
        }
        XCTAssertEqual(Set(NearbyPairingCode.alphabet).count, 32)
        XCTAssertTrue(Set(NearbyPairingCode.alphabet).isDisjoint(with: ["I", "L", "O", "U"]))
        let codes = Set((0..<64).map { _ in NearbyPairingCode.generate(at: 0).code })
        XCTAssertEqual(codes.count, 64, "80 random bits never repeat in a handful of draws")
        XCTAssertEqual(NearbyPairingCode.lifetime, 300)
        XCTAssertTrue(code.isUsable(at: 399))
        XCTAssertFalse(code.isUsable(at: 400))
        for _ in 0..<NearbyPairingCode.maximumFailedAttempts { code.recordFailedAttempt() }
        XCTAssertFalse(code.isUsable(at: 101))
        var single = NearbyPairingCode.generate(at: 0)
        single.consume()
        XCTAssertFalse(single.isUsable(at: 1))
    }
}

// MARK: - Controller

@MainActor
final class NearbyDevicesControllerTests: XCTestCase {
    func testDisabledByDefaultAndNothingStartsUntilEnabled() {
        let network = InMemoryNearbyNetwork()
        let a = NearbyHarness(network: network, id: NearbyHarness.smallID, name: "Study Mac", kind: .mac)
        defer { a.shutdown() }
        XCTAssertFalse(a.controller.isEnabled)
        XCTAssertFalse(a.defaults.bool(forKey: NearbyDevicesController.choiceMadeKey))
        XCTAssertNil(a.transport.listening)
        XCTAssertFalse(a.transport.browsing)
        a.controller.enable()
        XCTAssertTrue(a.defaults.bool(forKey: NearbyDevicesController.enabledKey))
        XCTAssertNotNil(a.transport.listening)
        XCTAssertTrue(a.transport.browsing)
        a.controller.disable()
        XCTAssertFalse(a.defaults.bool(forKey: NearbyDevicesController.enabledKey))
        XCTAssertNil(a.transport.listening)
        XCTAssertFalse(a.transport.browsing)
    }

    func testPeersConnectExchangeNamesAndIgnoreThemselves() async {
        let (network, a, b) = await connectedPair()
        defer { a.shutdown(); b.shutdown() }
        XCTAssertEqual(a.controller.peers.map(\.displayName), ["Kitchen iPad"])
        XCTAssertEqual(b.controller.peers.map(\.displayName), ["Study Mac"])
        XCTAssertEqual(b.controller.peers.first?.kind, .mac)
        XCTAssertEqual(b.controller.peers.first?.nowPlaying?.snapshot.nowPlaying?.trackID, "a")
        XCTAssertEqual(b.controller.peers.first?.nowPlaying?.artworkURL?.absoluteString, "https://img.example/a.jpg")
        XCTAssertEqual(network.openConnectionCount, 2, "One session, two ends")
        XCTAssertFalse(a.controller.peers.contains { $0.id == a.controller.installationID })
    }

    func testPositionOnlyPublicationIsThrottledAndSemanticChangesAreImmediate() async {
        let (_, a, b) = await connectedPair()
        defer { a.shutdown(); b.shutdown() }
        let baseline = b.controller.peers.first?.nowPlaying?.snapshot.nowPlaying?.position
        a.host.position = 20
        a.host.bump()
        await nearbySettle()
        XCTAssertEqual(b.controller.peers.first?.nowPlaying?.snapshot.nowPlaying?.position, baseline)
        a.clock.advance(by: 4.5)
        await nearbySettle()
        XCTAssertEqual(b.controller.peers.first?.nowPlaying?.snapshot.nowPlaying?.position, baseline)
        a.clock.advance(by: 0.5)
        await nearbySettle()
        XCTAssertEqual(b.controller.peers.first?.nowPlaying?.snapshot.nowPlaying?.position, 20)

        a.host.position = 21
        a.host.playing = false
        a.host.bump()
        await nearbySettle()
        XCTAssertEqual(b.controller.peers.first?.nowPlaying?.snapshot.nowPlaying?.isPlaying, false)
        XCTAssertEqual(b.controller.peers.first?.nowPlaying?.snapshot.nowPlaying?.position, 21)
    }

    func testReceiverExtrapolatesFromItsOwnClock() async {
        let (_, a, b) = await connectedPair()
        defer { a.shutdown(); b.shutdown() }
        let peer = try? XCTUnwrap(b.controller.peers.first)
        let start = b.clock.now
        XCTAssertEqual(peer?.position(at: start), 10)
        XCTAssertEqual(peer?.position(at: start + 3), 13)
        XCTAssertEqual(peer?.position(at: start + 10_000), 240, "Clamped to the duration")
        a.host.playing = false
        a.host.bump()
        await nearbySettle()
        XCTAssertEqual(b.controller.peers.first?.position(at: start + 30), 10)
    }

    func testRemoteControlUsesLeasesLikeTheWatch() async {
        let (_, a, b) = await connectedPair()
        defer { a.shutdown(); b.shutdown() }
        let peerID = a.controller.installationID

        let paused = await b.controller.send(.pause, to: peerID)
        XCTAssertEqual(paused, .accepted)
        XCTAssertEqual(a.host.handled.map(\.action), [.snapshot, .pause])
        XCTAssertNil(a.host.handled[0].executionLease)
        XCTAssertNotNil(a.host.handled[1].executionLease)
        XCTAssertEqual(a.host.handled[1].expectedTrackID, "a")
        XCTAssertFalse(a.host.playing)
        await nearbySettle()
        XCTAssertEqual(b.controller.peers.first?.nowPlaying?.snapshot.nowPlaying?.isPlaying, false)

        // The response's own lease is still fresh, so no second preflight.
        let skipped = await b.controller.send(.next, to: peerID)
        XCTAssertEqual(skipped, .accepted)
        XCTAssertEqual(a.host.handled.map(\.action), [.snapshot, .pause, .next])

        // Within half a second of expiry the sender asks for a new lease instead of risking a refusal.
        a.clock.advance(by: 5.6)
        b.clock.advance(by: 5.6)
        await nearbySettle()
        let liked = await b.controller.send(.setFavorite(true), to: peerID)
        XCTAssertEqual(liked, .accepted)
        XCTAssertEqual(a.host.handled.suffix(2).map(\.action), [.snapshot, .setFavorite(true)])
        XCTAssertTrue(a.host.favorite)
    }

    func testExpiredLeaseIsRefusedAndTheErrorSurfaces() async {
        let (_, a, b) = await connectedPair()
        defer { a.shutdown(); b.shutdown() }
        let peerID = a.controller.installationID
        _ = await b.controller.send(.setShuffle(true), to: peerID)
        // The receiver's clock runs on; the sender still believes its lease is fresh.
        a.clock.advance(by: 7)
        let result = await b.controller.send(.pause, to: peerID)
        XCTAssertEqual(result, .rejected(FakeNearbyHost.expiredLease))
        XCTAssertEqual(b.controller.peers.first?.controlError, FakeNearbyHost.expiredLease)
        XCTAssertTrue(a.host.playing)
        XCTAssertEqual(a.host.handled.last?.action, .pause)
    }

    func testMutationWithoutLeaseNeverReachesPlayback() async throws {
        let (network, a, b) = await connectedPair()
        defer { a.shutdown(); b.shutdown() }
        let request = CompanionRequest(action: .pause, expectedTrackID: "a")
        network.inject(.request(request), from: b.controller.installationID, to: a.controller.installationID)
        await nearbySettle()
        XCTAssertTrue(a.host.handled.isEmpty)
        XCTAssertTrue(a.host.playing)
    }

    func testStaleDisplayedTrackIsRefusedBeforeSending() async {
        let (_, a, b) = await connectedPair()
        defer { a.shutdown(); b.shutdown() }
        let result = await b.controller.send(.pause, to: a.controller.installationID, displayedTrackID: "other")
        guard case .rejected = result else { return XCTFail("Expected a refusal") }
        XCTAssertTrue(a.host.handled.isEmpty)
    }

    func testOfflineMutationTimesOutAndIsNeverReplayed() async {
        let (network, a, b) = await connectedPair()
        defer { a.shutdown(); b.shutdown() }
        network.dropsMessages = true
        let task = Task { await b.controller.send(.pause, to: a.controller.installationID) }
        await nearbySettle()
        b.clock.advance(by: NearbyDevicesController.responseDeadline)
        await nearbySettle()
        let result = await task.value
        guard case .rejected(let message) = result else { return XCTFail("Expected a refusal") }
        XCTAssertTrue(message.contains("Study Mac"))
        network.dropsMessages = false
        for _ in 0..<10 {
            a.clock.advance(by: 3)
            b.clock.advance(by: 3)
            await nearbySettle()
        }
        XCTAssertFalse(a.host.handled.contains { $0.action == .pause })
        XCTAssertTrue(a.host.playing)
    }

    func testUnreachablePeerIsRefusedWithoutSending() async {
        let network = InMemoryNearbyNetwork()
        let b = NearbyHarness(network: network, id: NearbyHarness.largeID, name: "Kitchen iPad", kind: .iPad)
        defer { b.shutdown() }
        b.controller.enable()
        let result = await b.controller.send(.pause, to: UUID())
        guard case .rejected = result else { return XCTFail("Expected a refusal") }
    }

    func testPlayHereTransfersWithExactHandover() async {
        let (_, a, b) = await connectedPair()
        defer { a.shutdown(); b.shutdown() }
        b.host.readyAfterContinue = false
        b.controller.playHere(from: a.controller.installationID)
        await nearbySettle()
        XCTAssertEqual(b.controller.transferState, .preparing(peerID: a.controller.installationID))
        XCTAssertEqual(b.host.continued.count, 1)
        XCTAssertEqual(b.host.continued.first?.startPlaying, false)
        XCTAssertEqual(b.host.continued.first?.position, 10)
        XCTAssertEqual(b.host.continued.first?.snapshot.queue.map(\.id), ["a", "b"])
        XCTAssertEqual(a.host.pauseCount, 0, "The source never pauses before the target is ready")
        XCTAssertTrue(a.host.playing)

        a.host.position = 42.5
        b.host.ready = true
        b.host.bump()
        await nearbySettle()
        XCTAssertEqual(a.host.pauseCount, 1)
        XCTAssertFalse(a.host.playing)
        XCTAssertEqual(b.host.seeks, [42.5])
        XCTAssertEqual(b.host.resumeCount, 1)
        XCTAssertEqual(b.controller.transferState, .idle)
        XCTAssertFalse(a.controller.isTransferring)
        XCTAssertFalse(b.controller.isTransferring)
    }

    func testPausedSourceMovesPaused() async {
        let (_, a, b) = await connectedPair()
        defer { a.shutdown(); b.shutdown() }
        a.host.playing = false
        a.host.bump()
        await nearbySettle()
        b.controller.playHere(from: a.controller.installationID)
        await nearbySettle()
        XCTAssertEqual(b.host.seeks, [10])
        XCTAssertEqual(b.host.resumeCount, 0)
        XCTAssertEqual(b.controller.transferState, .idle)
    }

    func testRoundTripAdvancesThePlayingTarget() async {
        let (_, a, b) = await connectedPair()
        defer { a.shutdown(); b.shutdown() }
        // A pong 0.4 s after its ping gives this device a 0.2 s one-way estimate.
        b.network.dropsMessages = true
        b.clock.advance(by: NearbyDevicesController.pingInterval)
        await nearbySettle()
        b.network.dropsMessages = false
        let sent = b.clock.now
        b.clock.advance(by: 0.4)
        b.network.inject(.pong(id: UUID(), sentUptime: sent), from: a.controller.installationID, to: b.controller.installationID)
        await nearbySettle()
        XCTAssertEqual(b.controller.peers.first?.roundTrip ?? 0, 0.4, accuracy: 1e-9)
        b.controller.playHere(from: a.controller.installationID)
        await nearbySettle()
        XCTAssertEqual(b.host.continued.first?.position ?? 0, 10.2, accuracy: 1e-9)
        XCTAssertEqual(b.host.seeks.first ?? 0, 10.2, accuracy: 1e-9)
    }

    func testTargetThatNeverBecomesReadyCancelsAndSourceKeepsPlaying() async {
        let (_, a, b) = await connectedPair()
        defer { a.shutdown(); b.shutdown() }
        b.host.queue = [nearbyTestTrack("own")]
        b.host.position = 33
        b.host.bump()
        b.host.readyAfterContinue = false
        b.controller.playHere(from: a.controller.installationID)
        await nearbySettle()
        for _ in 0..<40 {
            b.clock.advance(by: NearbyDevicesController.readinessPollInterval)
            await nearbySettle()
        }
        XCTAssertEqual(b.controller.transferState, .failed(
            message: "The song couldn't be prepared in time. What was playing on this device is back, paused."))
        XCTAssertEqual(a.host.pauseCount, 0)
        XCTAssertTrue(a.host.playing)
        XCTAssertFalse(a.controller.isTransferring)
        // The receiver's own queue comes back paused at its own position.
        XCTAssertEqual(b.host.continued.count, 2)
        XCTAssertEqual(b.host.continued.first?.snapshot.queue.map(\.id), ["a", "b"])
        XCTAssertEqual(b.host.continued.last?.snapshot.queue.map(\.id), ["own"])
        XCTAssertEqual(b.host.continued.last?.position, 33)
        XCTAssertEqual(b.host.continued.last?.startPlaying, false)
        XCTAssertFalse(b.host.playing)
        // A late ready for the retired id is ignored.
        b.host.ready = true
        b.host.bump()
        await nearbySettle()
        XCTAssertEqual(a.host.pauseCount, 0)
    }

    func testSilentSourceTimesOutAfterTwelveSeconds() async {
        let (network, a, b) = await connectedPair()
        defer { a.shutdown(); b.shutdown() }
        network.dropsMessages = true
        b.controller.playHere(from: a.controller.installationID)
        await nearbySettle()
        b.clock.advance(by: NearbyDevicesController.transferDeadline - 0.5)
        await nearbySettle()
        XCTAssertEqual(b.controller.transferState, .preparing(peerID: a.controller.installationID))
        b.clock.advance(by: 0.5)
        await nearbySettle()
        guard case .failed = b.controller.transferState else { return XCTFail("Expected a failure") }
        XCTAssertTrue(b.host.continued.isEmpty)
        XCTAssertEqual(a.host.pauseCount, 0)
    }

    func testSourceDeadlineNeverPausesAndLateReadyIsIgnored() async {
        let (network, a, b) = await connectedPair()
        defer { a.shutdown(); b.shutdown() }
        b.host.readyAfterContinue = false
        b.controller.playHere(from: a.controller.installationID)
        await nearbySettle()
        network.dropsMessages = true
        a.clock.advance(by: NearbyDevicesController.transferDeadline)
        await nearbySettle()
        XCTAssertFalse(a.controller.isTransferring)
        network.dropsMessages = false
        b.host.ready = true
        b.host.bump()
        await nearbySettle()
        XCTAssertEqual(a.host.pauseCount, 0)
        XCTAssertTrue(a.host.playing)
    }

    func testLiveRadioAndEmptySelectionAreRefused() async {
        let (_, a, b) = await connectedPair()
        defer { a.shutdown(); b.shutdown() }
        a.host.liveRadio = true
        b.controller.playHere(from: a.controller.installationID)
        await nearbySettle()
        XCTAssertEqual(b.controller.transferState, .failed(message: "Live Radio stays on the device that is playing it."))
        XCTAssertTrue(b.host.continued.isEmpty)
        XCTAssertEqual(a.host.pauseCount, 0)

        b.controller.dismissTransferFailure()
        a.host.liveRadio = false
        a.host.queue = []
        a.host.bump()
        b.controller.playHere(from: a.controller.installationID)
        await nearbySettle()
        guard case .failed = b.controller.transferState else { return XCTFail("Expected a failure") }
        XCTAssertTrue(b.host.continued.isEmpty)
    }

    func testPushRunsThePullFlowOnThePeer() async {
        let (_, a, b) = await connectedPair()
        defer { a.shutdown(); b.shutdown() }
        b.host.queue = []
        b.host.bump()
        XCTAssertTrue(a.controller.canSendPlayback)
        a.controller.playOn(b.controller.installationID)
        await nearbySettle()
        XCTAssertEqual(b.host.continued.count, 1)
        XCTAssertEqual(a.host.pauseCount, 1)
        XCTAssertEqual(b.host.seeks, [10])
        XCTAssertEqual(b.host.resumeCount, 1)
        XCTAssertEqual(a.controller.transferState, .idle)
        XCTAssertEqual(b.controller.transferState, .idle)
    }

    func testPushFromLiveRadioIsRefusedLocally() async {
        let (_, a, b) = await connectedPair()
        defer { a.shutdown(); b.shutdown() }
        a.host.liveRadio = true
        a.controller.playOn(b.controller.installationID)
        await nearbySettle()
        guard case .failed = a.controller.transferState else { return XCTFail("Expected a failure") }
        XCTAssertTrue(b.host.continued.isEmpty)
    }

    func testOneTransferAtATimeAndStaleIDsAreIgnored() async {
        let (network, a, b) = await connectedPair()
        defer { a.shutdown(); b.shutdown() }
        b.host.readyAfterContinue = false
        b.controller.playHere(from: a.controller.installationID)
        b.controller.playHere(from: a.controller.installationID)
        await nearbySettle()
        XCTAssertEqual(b.host.continued.count, 1)
        network.inject(.transferReleased(id: UUID(), position: 99, playing: true), from: a.controller.installationID, to: b.controller.installationID)
        network.inject(.transferReady(id: UUID()), from: b.controller.installationID, to: a.controller.installationID)
        await nearbySettle()
        XCTAssertTrue(b.host.seeks.isEmpty)
        XCTAssertEqual(a.host.pauseCount, 0)
        XCTAssertEqual(b.controller.transferState, .preparing(peerID: a.controller.installationID))
    }

    func testDisconnectDuringTransferKeepsSourcePlaying() async {
        let (network, a, b) = await connectedPair()
        defer { a.shutdown(); b.shutdown() }
        b.host.readyAfterContinue = false
        b.controller.playHere(from: a.controller.installationID)
        await nearbySettle()
        network.closeAll()
        await nearbySettle()
        XCTAssertEqual(b.controller.transferState, .failed(
            message: "The other device disconnected. What was playing on this device is back, paused."))
        XCTAssertEqual(b.host.continued.count, 2)
        XCTAssertFalse(a.controller.isTransferring)
        XCTAssertEqual(a.host.pauseCount, 0)
        XCTAssertEqual(b.controller.peers.first?.state, .reconnecting)
    }

    func testReconnectsWithBackoffWhileEnabled() async {
        let (network, a, b) = await connectedPair()
        defer { a.shutdown(); b.shutdown() }
        network.refusesConnections = true
        network.closeAll()
        await nearbySettle()
        let dials = network.dialCount
        // Failures back off 1, 2, 4 seconds; no dial happens before each step is due.
        for (attempt, step) in [1.0, 2, 4].enumerated() {
            a.clock.advance(by: step - 0.5)
            await nearbySettle()
            XCTAssertEqual(network.dialCount, dials + attempt)
            a.clock.advance(by: 0.5)
            await nearbySettle()
        }
        XCTAssertEqual(network.dialCount, dials + 3)
        network.refusesConnections = false
        a.clock.advance(by: 8)
        await nearbySettle()
        XCTAssertEqual(a.controller.peers.first?.state, .connected)
        XCTAssertEqual(b.controller.peers.first?.state, .connected)
    }

    func testPairingWithACodeSharesTheLinkKey() async {
        let network = InMemoryNearbyNetwork()
        let a = NearbyHarness(network: network, id: NearbyHarness.smallID, name: "Study Mac", kind: .mac)
        let b = NearbyHarness(network: network, id: NearbyHarness.largeID, name: "Kitchen iPad", kind: .iPad)
        defer { a.shutdown(); b.shutdown() }
        a.controller.enable()
        b.controller.enable()
        await nearbySettle()
        XCTAssertTrue(a.controller.peers.isEmpty, "Different keys never connect")
        XCTAssertNotEqual(a.store.key, b.store.key)

        let code = try? XCTUnwrap(a.controller.showPairingCode())
        await nearbySettle()
        XCTAssertEqual(a.transport.listening?.pairing, true)
        b.controller.joinPairing(code: code ?? "")
        await nearbySettle()
        XCTAssertEqual(b.controller.pairingState, .paired)
        XCTAssertEqual(a.controller.pairingState, .paired)
        XCTAssertNil(a.controller.pairingCode)
        XCTAssertEqual(a.store.key, b.store.key)
        XCTAssertEqual(a.transport.listening?.pairing, false)
        for _ in 0..<8 {
            a.clock.advance(by: 4)
            b.clock.advance(by: 4)
            await nearbySettle()
        }
        XCTAssertEqual(a.controller.peers.first?.state, .connected)
        XCTAssertEqual(b.controller.peers.first?.displayName, "Study Mac")

        // The code was single use.
        let other = NearbyHarness(network: network, id: UUID(), name: "Phone", kind: .iPhone)
        defer { other.shutdown() }
        other.controller.enable()
        other.controller.joinPairing(code: code ?? "")
        await nearbySettle()
        other.clock.advance(by: NearbyDevicesController.joinDeadline)
        await nearbySettle()
        guard case .failed = other.controller.pairingState else { return XCTFail("Expected a failure") }
        XCTAssertNotEqual(other.store.key, a.store.key)
    }

    func testWrongPairingCodeFailsAndCountsAgainstTheCode() async {
        let network = InMemoryNearbyNetwork()
        let a = NearbyHarness(network: network, id: NearbyHarness.smallID, name: "Study Mac", kind: .mac)
        let b = NearbyHarness(network: network, id: NearbyHarness.largeID, name: "Kitchen iPad", kind: .iPad)
        defer { a.shutdown(); b.shutdown() }
        a.controller.enable()
        b.controller.enable()
        let code = a.controller.showPairingCode() ?? ""
        await nearbySettle()
        var wrong = NearbyPairingCode.generate(at: 0).display
        while NearbyPairingCode.normalized(wrong) == NearbyPairingCode.normalized(code) { wrong = NearbyPairingCode.generate(at: 0).display }
        let keyBefore = b.store.key
        b.controller.joinPairing(code: wrong)
        await nearbySettle()
        XCTAssertEqual(b.controller.pairingState,
                       .failed(message: "That code didn't work. Check the code on the other device and try again."))
        XCTAssertEqual(b.store.key, keyBefore)
        XCTAssertEqual(a.controller.pairingCode?.failedAttempts, 1)
        b.controller.joinPairing(code: "12a")
        XCTAssertEqual(b.controller.pairingState, .failed(message: "Enter the 16-character code shown on the other device."))
    }

    func testPairingCodeExpiresAfterFiveMinutes() async {
        let network = InMemoryNearbyNetwork()
        let a = NearbyHarness(network: network, id: NearbyHarness.smallID, name: "Study Mac", kind: .mac)
        defer { a.shutdown() }
        a.controller.enable()
        _ = a.controller.showPairingCode()
        await nearbySettle()
        XCTAssertEqual(a.transport.listening?.pairing, true)
        a.clock.advance(by: NearbyPairingCode.lifetime)
        await nearbySettle()
        XCTAssertNil(a.controller.pairingCode)
        XCTAssertEqual(a.transport.listening?.pairing, false)
    }

    func testSecondSessionFromTheSamePeerKeepsOnlyOne() async {
        let (network, a, b) = await connectedPair()
        defer { a.shutdown(); b.shutdown() }
        network.dialDirectly(from: b.controller.installationID, to: a.controller.installationID, security: b.linkSecurity)
        await nearbySettle()
        XCTAssertEqual(network.openConnectionCount, 2)
        XCTAssertEqual(a.controller.peers.count, 1)
        XCTAssertEqual(b.controller.peers.first?.state, .connected)
    }


    // MARK: Review fixes

    func testOpeningDevicesEnablesOnlyUntilAChoiceIsSaved() {
        let network = InMemoryNearbyNetwork()
        let a = NearbyHarness(network: network, id: NearbyHarness.smallID, name: "Study Mac", kind: .mac)
        defer { a.shutdown() }
        a.controller.enableOnFirstVisit()
        XCTAssertTrue(a.controller.isEnabled)
        XCTAssertTrue(a.defaults.bool(forKey: NearbyDevicesController.choiceMadeKey))
        a.controller.disable()
        a.controller.enableOnFirstVisit()
        XCTAssertFalse(a.controller.isEnabled, "An explicit Off survives reopening Devices")
        XCTAssertNil(a.transport.listening)

        let relaunched = NearbyDevicesController(host: a.host, transport: InMemoryNearbyTransport(id: UUID(), network: network),
                                                 keyStore: a.store, defaults: a.defaults, displayName: "Study Mac",
                                                 deviceKind: .mac, uptime: { 0 }, sleep: { _ in })
        relaunched.enableOnFirstVisit()
        XCTAssertFalse(relaunched.isEnabled)
        a.controller.enable()
        XCTAssertTrue(a.controller.isEnabled)
        XCTAssertNotNil(a.transport.listening)
    }

    func testInstallationIDIsFreshPerLaunchAndNeverStored() {
        let network = InMemoryNearbyNetwork()
        let suite = "nearby-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = ManualNearbyClock()
        let transport = InMemoryNearbyTransport(id: UUID(), network: network)
        func launch(_ transport: InMemoryNearbyTransport) -> NearbyDevicesController {
            NearbyDevicesController(host: FakeNearbyHost(clock: clock), transport: transport, keyStore: InMemoryNearbyLinkKeyStore(),
                                    defaults: defaults, displayName: "Study Mac", deviceKind: .mac,
                                    uptime: { clock.now }, sleep: { try await clock.sleep($0) })
        }
        let first = launch(transport)
        let second = launch(InMemoryNearbyTransport(id: UUID(), network: network))
        XCTAssertNotEqual(first.installationID, second.installationID)
        first.enable()
        XCTAssertEqual(transport.advertisedID, first.installationID)
        let stored = defaults.persistentDomain(forName: suite) ?? [:]
        XCTAssertNil(stored["nearby.installationID"])
        XCTAssertFalse(stored.values.contains { ($0 as? String) == first.installationID.uuidString })
        first.disable()
        clock.drain()
    }

    func testResetDeviceKeyDropsSessionsAndRestartsTheListener() async throws {
        let (network, a, b) = await connectedPair()
        defer { a.shutdown(); b.shutdown() }
        let old = try XCTUnwrap(a.store.key)
        XCTAssertTrue(a.controller.resetLinkKey())
        let new = try XCTUnwrap(a.store.key)
        XCTAssertNotEqual(new, old)
        XCTAssertEqual(new.count, NearbyLinkKey.byteCount)
        XCTAssertEqual(a.transport.listening?.security, .link(psk: NearbyLinkKey.tlsPSK(linkKey: new)))
        XCTAssertEqual(a.transport.listening?.pairing, false)
        await nearbySettle()
        XCTAssertEqual(network.openConnectionCount, 0)
        // The other device still holds the old key, so no redial ever completes.
        for _ in 0..<8 {
            a.clock.advance(by: 4)
            b.clock.advance(by: 4)
            await nearbySettle()
        }
        XCTAssertFalse(a.controller.peers.contains(where: \.isConnected))
        XCTAssertFalse(b.controller.peers.contains(where: \.isConnected))

        a.store.failsWrites = true
        XCTAssertFalse(a.controller.resetLinkKey())
        XCTAssertEqual(a.store.key, new)
    }

    func testOnlyFailedHandshakesCountAgainstAPairingCode() async {
        let network = InMemoryNearbyNetwork()
        let a = NearbyHarness(network: network, id: NearbyHarness.smallID, name: "Study Mac", kind: .mac)
        let b = NearbyHarness(network: network, id: NearbyHarness.largeID, name: "Kitchen iPad", kind: .iPad)
        defer { a.shutdown(); b.shutdown() }
        a.controller.enable()
        b.controller.enable()
        let code = a.controller.showPairingCode() ?? ""
        await nearbySettle()
        var wrong = NearbyPairingCode.generate(at: 0).display
        while NearbyPairingCode.normalized(wrong) == NearbyPairingCode.normalized(code) { wrong = NearbyPairingCode.generate(at: 0).display }

        network.handshakeFailure = .network
        b.controller.joinPairing(code: wrong)
        await nearbySettle()
        guard case .failed = b.controller.pairingState else { return XCTFail("Expected a failure") }
        XCTAssertEqual(a.controller.pairingCode?.failedAttempts, 0, "A bare connection failure is not a guess")

        network.handshakeFailure = .tls
        for attempt in 1...NearbyPairingCode.maximumFailedAttempts {
            b.controller.joinPairing(code: wrong)
            await nearbySettle()
            if attempt < NearbyPairingCode.maximumFailedAttempts {
                XCTAssertEqual(a.controller.pairingCode?.failedAttempts, attempt)
            }
        }
        XCTAssertNil(a.controller.pairingCode, "Ten failed handshakes retire the code")
        XCTAssertEqual(a.transport.listening?.pairing, false)
    }

    func testPairingSessionsCloseWhenIdleAndAfterTheGrant() async throws {
        let network = InMemoryNearbyNetwork()
        let a = NearbyHarness(network: network, id: NearbyHarness.smallID, name: "Study Mac", kind: .mac)
        let b = NearbyHarness(network: network, id: NearbyHarness.largeID, name: "Kitchen iPad", kind: .iPad)
        defer { a.shutdown(); b.shutdown() }
        b.store.key = a.store.key
        a.controller.enable()
        let code = try XCTUnwrap(a.controller.showPairingCode())
        await nearbySettle()
        let security = NearbyLinkSecurity.pairing(psk: NearbyLinkKey.pairingPSK(code: code))

        network.dialDirectly(from: b.transport.id, to: a.transport.id, security: security, onReady: { _ in })
        await nearbySettle()
        XCTAssertEqual(network.openConnectionCount, 2)
        a.clock.advance(by: NearbyDevicesController.pairingIdleDeadline - 0.5)
        await nearbySettle()
        XCTAssertEqual(network.openConnectionCount, 2)
        a.clock.advance(by: 0.5)
        await nearbySettle()
        XCTAssertEqual(network.openConnectionCount, 0, "A silent pairing session is closed after 60 s")
        XCTAssertNotNil(a.controller.pairingCode, "An idle session is not a failed guess")
        XCTAssertEqual(a.controller.pairingCode?.failedAttempts, 0)

        let joiner = try NearbyPairing.makeJoiner()
        network.dialDirectly(from: b.transport.id, to: a.transport.id, security: security, onReady: { connection in
            if let payload = try? NearbyLinkWire.encode(.pairingRequest(joiner.request)) { connection.send(payload) }
        })
        await nearbySettle()
        XCTAssertEqual(a.controller.pairingState, .paired)
        XCTAssertNil(a.controller.pairingCode)
        XCTAssertEqual(network.openConnectionCount, 2, "The grant gets time to flush")
        a.clock.advance(by: NearbyDevicesController.pairingGrantLinger - 0.5)
        await nearbySettle()
        XCTAssertEqual(network.openConnectionCount, 2)
        a.clock.advance(by: 0.5)
        await nearbySettle()
        XCTAssertEqual(network.openConnectionCount, 0, "The shower closes 30 s after the grant even if the joiner stays")
    }

    func testQueueOverTheHandoffLimitIsRefusedWithClearCopy() async {
        let (_, a, b) = await connectedPair()
        defer { a.shutdown(); b.shutdown() }
        let limit = NearbyLinkWire.maximumQueueOccurrences
        let copy = "The queue has more than \(limit.formatted()) songs, which is too many to move. Remove some songs and try again."
        a.host.queue = (0...limit).map { nearbyTestTrack("q\($0)") }
        a.host.bump()
        await nearbySettle()
        b.controller.playHere(from: a.controller.installationID)
        await nearbySettle()
        XCTAssertEqual(b.controller.transferState, .failed(message: copy))
        XCTAssertTrue(b.host.continued.isEmpty)
        XCTAssertEqual(a.host.pauseCount, 0)

        b.controller.dismissTransferFailure()
        a.controller.playOn(b.controller.installationID)
        await nearbySettle()
        XCTAssertEqual(a.controller.transferState, .failed(message: copy + " Playback stayed on this device."))
        XCTAssertTrue(b.host.continued.isEmpty)
        XCTAssertTrue(a.host.playing)
    }

    func testDeadlineBudgetLetsEveryReleaseArriveBeforeTheReceiverGivesUp() {
        typealias C = NearbyDevicesController
        // Measured from the receiver's request: the offer leaves after half a round trip, the release within the window.
        XCTAssertLessThan(C.sourceReleaseWindow + C.maximumRoundTrip, C.transferDeadline)
        XCTAssertLessThan(C.readinessDeadline + C.maximumRoundTrip, C.sourceReleaseWindow)
        XCTAssertGreaterThan(C.releasedMemory, C.transferDeadline)
    }

    func testReceiverTimeoutAfterReleaseHandsPlaybackBackToTheSender() async {
        let (network, a, b) = await connectedPair()
        defer { a.shutdown(); b.shutdown() }
        b.host.queue = [nearbyTestTrack("own")]
        b.host.position = 33
        b.host.bump()
        network.dropMessage = { if case .transferReleased = $0 { true } else { false } }
        b.controller.playHere(from: a.controller.installationID)
        await nearbySettle()
        XCTAssertEqual(a.host.pauseCount, 1)
        XCTAssertFalse(a.host.playing)
        XCTAssertEqual(b.controller.transferState, .preparing(peerID: a.controller.installationID))

        b.clock.advance(by: NearbyDevicesController.transferDeadline)
        await nearbySettle()
        XCTAssertEqual(a.host.resumeCount, 1, "The sender takes its playback back instead of both staying silent")
        XCTAssertTrue(a.host.playing)
        XCTAssertEqual(b.controller.transferState, .failed(
            message: "The other device didn't respond in time. What was playing on this device is back, paused."))
        XCTAssertEqual(b.host.continued.last?.snapshot.queue.map(\.id), ["own"])
        XCTAssertEqual(b.host.continued.last?.position, 33)
        XCTAssertEqual(b.host.resumeCount, 0)
        XCTAssertTrue(b.host.seeks.isEmpty)
    }

    func testReleasedTransferIsForgottenAfterFifteenSeconds() async {
        let (network, a, b) = await connectedPair()
        defer { a.shutdown(); b.shutdown() }
        network.dropMessage = { if case .transferReleased = $0 { true } else { false } }
        b.controller.playHere(from: a.controller.installationID)
        await nearbySettle()
        XCTAssertEqual(a.host.pauseCount, 1)
        a.clock.advance(by: NearbyDevicesController.releasedMemory)
        b.clock.advance(by: NearbyDevicesController.transferDeadline)
        await nearbySettle()
        XCTAssertEqual(a.host.resumeCount, 0)
        XCTAssertFalse(a.host.playing)
    }

    func testSenderPausedDuringPreparationLeavesTheReceiverPaused() async {
        let (_, a, b) = await connectedPair()
        defer { a.shutdown(); b.shutdown() }
        b.host.readyAfterContinue = false
        b.controller.playHere(from: a.controller.installationID)
        await nearbySettle()
        XCTAssertEqual(b.host.continued.first?.position, 10)
        a.host.playing = false
        a.host.position = 50
        a.host.bump()
        await nearbySettle()
        b.host.ready = true
        b.host.bump()
        await nearbySettle()
        XCTAssertEqual(b.host.seeks, [50])
        XCTAssertEqual(b.host.resumeCount, 0)
        XCTAssertFalse(b.host.playing)
        XCTAssertEqual(b.controller.transferState, .idle)
        XCTAssertEqual(a.host.resumeCount, 0)
    }

    func testReceiverNotReadyAtReleaseCancelsAndTheSenderResumes() async {
        let (network, a, b) = await connectedPair()
        defer { a.shutdown(); b.shutdown() }
        b.host.queue = [nearbyTestTrack("own")]
        b.host.position = 33
        b.host.bump()
        network.holdMessage = { if case .transferReleased = $0 { true } else { false } }
        b.controller.playHere(from: a.controller.installationID)
        await nearbySettle()
        XCTAssertEqual(a.host.pauseCount, 1)
        b.host.ready = false
        network.releaseHeld()
        await nearbySettle()
        XCTAssertTrue(b.host.seeks.isEmpty)
        XCTAssertEqual(b.host.resumeCount, 0)
        XCTAssertEqual(b.host.continued.last?.snapshot.queue.map(\.id), ["own"])
        XCTAssertEqual(a.host.resumeCount, 1)
        XCTAssertTrue(a.host.playing)
        XCTAssertEqual(b.controller.transferState, .failed(
            message: "The song couldn't be prepared in time. What was playing on this device is back, paused."))
    }

    func testLinkKeyIsCachedForThirtySecondsAndFollowsAKeychainUpdate() async {
        let (_, a, b) = await connectedPair()
        defer { a.shutdown(); b.shutdown() }
        let reads = a.store.readCount
        for _ in 0..<5 {
            a.clock.advance(by: 5)
            await nearbySettle()
        }
        XCTAssertEqual(a.store.readCount, reads, "Maintenance passes within 30 s reuse the cached key")
        a.clock.advance(by: 6)
        await nearbySettle()
        XCTAssertGreaterThan(a.store.readCount, reads)

        let synced = NearbyLinkKey.random()
        a.store.key = synced
        a.clock.advance(by: NearbyDevicesController.keyCacheLifetime + 1)
        await nearbySettle()
        XCTAssertEqual(a.transport.listening?.security, .link(psk: NearbyLinkKey.tlsPSK(linkKey: synced)))
    }

    func testFailedHandshakeRereadsTheKeyImmediately() async {
        let network = InMemoryNearbyNetwork()
        let a = NearbyHarness(network: network, id: NearbyHarness.smallID, name: "Study Mac", kind: .mac)
        let b = NearbyHarness(network: network, id: NearbyHarness.largeID, name: "Kitchen iPad", kind: .iPad)
        defer { a.shutdown(); b.shutdown() }
        a.controller.enable()
        b.controller.enable()
        await nearbySettle()
        let reads = a.store.readCount
        a.clock.advance(by: 1)
        await nearbySettle()
        XCTAssertGreaterThan(a.store.readCount, reads, "A TLS failure drops the cache well inside 30 s")

        // The failed redial drops the stale cached key, so the one after it uses the update well before 30 s.
        a.store.key = b.store.key
        a.clock.advance(by: 2)
        await nearbySettle()
        a.clock.advance(by: 4)
        await nearbySettle()
        XCTAssertEqual(a.controller.peers.first?.state, .connected)
    }

    // MARK: Helpers

    private func connectedPair() async -> (InMemoryNearbyNetwork, NearbyHarness, NearbyHarness) {
        let network = InMemoryNearbyNetwork()
        let a = NearbyHarness(network: network, id: NearbyHarness.smallID, name: "Study Mac", kind: .mac)
        let b = NearbyHarness(network: network, id: NearbyHarness.largeID, name: "Kitchen iPad", kind: .iPad)
        b.store.key = a.store.key
        a.controller.enable()
        b.controller.enable()
        await nearbySettle()
        XCTAssertEqual(a.controller.peers.first?.state, .connected)
        XCTAssertEqual(b.controller.peers.first?.state, .connected)
        return (network, a, b)
    }
}

@MainActor
func nearbySettle() async {
    for _ in 0..<40 { await Task.yield() }
}

// MARK: - Loopback

@MainActor
final class NearbyLinkLoopbackTests: XCTestCase {
    func testTLSPSKHelloOverLoopbackAndWrongKeyFails() async throws {
        let key = NearbyLinkKey.random()
        let security = NearbyLinkSecurity.link(psk: NearbyLinkKey.tlsPSK(linkKey: key))
        let parameters = NearbyLinkTLS.parameters(security: security)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        parameters.includePeerToPeer = false
        let listener: NWListener
        do { listener = try NWListener(using: parameters) } catch { throw XCTSkip("Loopback listener could not be created") }
        defer { listener.cancel() }

        let probe = LoopbackProbe()
        let listening = expectation(description: "listening")
        listening.assertForOverFulfill = false
        let received = expectation(description: "hello received")
        listener.stateUpdateHandler = { state in
            MainActor.assumeIsolated {
                switch state {
                case .ready: probe.listenerReady = true; listening.fulfill()
                case .failed, .waiting: probe.listenerFailed = true; listening.fulfill()
                default: break
                }
            }
        }
        listener.newConnectionHandler = { connection in
            MainActor.assumeIsolated {
                let server = NearbyNWConnection(connection: connection)
                server.onEvent = { event in
                    switch event {
                    case .received(let payload):
                        probe.message = try? NearbyLinkWire.decode(payload)
                        received.fulfill()
                    case .ready: probe.serverReadyCount += 1
                    case .failed: probe.serverFailures += 1
                    }
                }
                probe.servers.append(server)
                server.start()
            }
        }
        listener.start(queue: .main)
        await fulfillment(of: [listening], timeout: 5)
        guard probe.listenerReady, let port = listener.port else { throw XCTSkip("Loopback listener could not bind") }

        let hello = NearbyPeerHello(installationID: UUID(), displayName: "Loopback", deviceKind: .iPhone)
        let client = NearbyNWConnection(connection: NWConnection(host: "127.0.0.1", port: port,
                                                                 using: NearbyLinkTLS.parameters(security: security)))
        client.onEvent = { event in
            if case .ready = event, let payload = try? NearbyLinkWire.encode(.hello(hello)) { client.send(payload) }
        }
        client.start()
        await fulfillment(of: [received], timeout: 10)
        XCTAssertEqual(probe.message, .hello(hello))
        client.cancel()

        let rejected = expectation(description: "wrong key fails")
        let wrongSecurity = NearbyLinkSecurity.link(psk: NearbyLinkKey.tlsPSK(linkKey: NearbyLinkKey.random()))
        let wrong = NearbyNWConnection(connection: NWConnection(host: "127.0.0.1", port: port,
                                                                using: NearbyLinkTLS.parameters(security: wrongSecurity)))
        wrong.onEvent = { event in
            switch event {
            case .ready: probe.wrongKeyReady = true
            case .failed: rejected.fulfill()
            case .received: probe.wrongKeyReceived = true
            }
        }
        wrong.start()
        await fulfillment(of: [rejected], timeout: NearbyNWConnection.readyDeadline + 5)
        XCTAssertFalse(probe.wrongKeyReady)
        XCTAssertFalse(probe.wrongKeyReceived)
        XCTAssertEqual(probe.serverReadyCount, 1)
        for server in probe.servers { server.cancel() }
    }
}

@MainActor
private final class LoopbackProbe {
    var listenerReady = false
    var listenerFailed = false
    var message: NearbyLinkMessage?
    var servers: [NearbyNWConnection] = []
    var serverReadyCount = 0
    var serverFailures = 0
    var wrongKeyReady = false
    var wrongKeyReceived = false
}

// MARK: - Support

func nearbyTestTrack(_ id: String, artwork: String? = "https://img.example/a.jpg") -> Track {
    Track(id: id, title: "Song \(id)", artists: ["An Artist"], duration: 240, artworkURL: artwork.flatMap(URL.init(string:)))
}

func nearbyTestCompanionSnapshot(position: Double = 10, isPlaying: Bool = true, sequence: UInt64 = 1,
                                 sessionID: UUID = UUID()) -> CompanionSnapshot {
    CompanionSnapshot(sessionID: sessionID, sequence: sequence, updatedAt: Date(timeIntervalSinceReferenceDate: 1_000),
                      nowPlaying: CompanionNowPlaying(trackID: "a", title: "Song a", artist: "An Artist", position: position,
                                                      duration: 240, isPlaying: isPlaying, isLoading: false, isFavorite: false,
                                                      shuffleEnabled: false, repeatMode: .off))
}

final class InMemoryNearbyLinkKeyStore: NearbyLinkKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Data?

    var key: Data? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    private var reads = 0
    private var failing = false

    var readCount: Int { lock.withLock { reads } }
    var failsWrites: Bool {
        get { lock.withLock { failing } }
        set { lock.withLock { failing = newValue } }
    }

    func readLinkKey() throws -> Data? {
        lock.withLock { reads += 1 }
        return key
    }

    func writeLinkKey(_ key: Data) throws {
        if failsWrites { throw NearbyLinkKeyError.keychain(-25_300) }
        self.key = key
    }
}

@MainActor
final class ManualNearbyClock {
    private(set) var now: TimeInterval = 1_000
    private var sleepers: [(deadline: TimeInterval, continuation: CheckedContinuation<Void, any Error>)] = []

    func sleep(_ seconds: TimeInterval) async throws {
        let deadline = now + max(0, seconds)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            sleepers.append((deadline, continuation))
        }
    }

    func advance(by seconds: TimeInterval) {
        now += seconds
        let due = sleepers.filter { $0.deadline <= now + 1e-9 }
        sleepers.removeAll { $0.deadline <= now + 1e-9 }
        for sleeper in due { sleeper.continuation.resume() }
    }

    func drain() {
        let all = sleepers
        sleepers = []
        for sleeper in all { sleeper.continuation.resume(throwing: CancellationError()) }
    }
}

@MainActor
final class NearbyHarness {
    static let smallID = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    static let largeID = UUID(uuidString: "FFFFFFFF-0000-0000-0000-00000000000B")!

    let network: InMemoryNearbyNetwork
    let clock: ManualNearbyClock
    let store: InMemoryNearbyLinkKeyStore
    let host: FakeNearbyHost
    let transport: InMemoryNearbyTransport
    let defaults: UserDefaults
    let suite: String
    let controller: NearbyDevicesController

    var linkSecurity: NearbyLinkSecurity { .link(psk: NearbyLinkKey.tlsPSK(linkKey: store.key ?? Data())) }

    init(network: InMemoryNearbyNetwork, id: UUID, name: String, kind: NearbyDeviceKind) {
        let clock = ManualNearbyClock()
        let store = InMemoryNearbyLinkKeyStore()
        store.key = NearbyLinkKey.random()
        let host = FakeNearbyHost(clock: clock)
        let transport = InMemoryNearbyTransport(id: id, network: network)
        let suite = "nearby-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        self.network = network
        self.clock = clock
        self.store = store
        self.host = host
        self.transport = transport
        self.suite = suite
        self.defaults = defaults
        controller = NearbyDevicesController(host: host, transport: transport, keyStore: store, defaults: defaults,
                                             installationID: id, displayName: name, deviceKind: kind,
                                             uptime: { clock.now }, sleep: { try await clock.sleep($0) })
    }

    func shutdown() {
        controller.disable()
        clock.drain()
        defaults.removePersistentDomain(forName: suite)
    }
}

@MainActor
final class FakeNearbyHost: NearbyPlaybackHost {
    static let expiredLease = "This playback request expired. Refresh and try again."

    let clock: ManualNearbyClock
    let sessionID = UUID()
    var sequence: UInt64 = 1
    var queue = [nearbyTestTrack("a"), nearbyTestTrack("b", artwork: "https://img.example/b.jpg")]
    var index = 0
    var playing = true
    var position: TimeInterval = 10
    var favorite = false
    var superLiked = false
    var shuffle = false
    var repeatMode: CompanionRepeatMode = .off
    var liveRadio = false
    var ready = true
    var readyAfterContinue = true
    var continueResult = true

    private(set) var handled: [CompanionRequest] = []
    private(set) var continued: [(snapshot: PlaybackSnapshot, position: TimeInterval, startPlaying: Bool)] = []
    private(set) var seeks: [TimeInterval] = []
    private(set) var pauseCount = 0
    private(set) var resumeCount = 0
    private var leases: [UUID: TimeInterval] = [:]
    private var observers: [UUID: @MainActor () -> Void] = [:]

    init(clock: ManualNearbyClock) {
        self.clock = clock
    }

    private var current: Track? { liveRadio || !queue.indices.contains(index) ? nil : queue[index] }

    func bump() {
        sequence += 1
        for observer in Array(observers.values) { observer() }
    }

    var companionSnapshot: CompanionSnapshot {
        CompanionSnapshot(sessionID: sessionID, sequence: sequence, updatedAt: Date(timeIntervalSinceReferenceDate: 0),
                          nowPlaying: current.map {
                              CompanionNowPlaying(trackID: $0.id, title: $0.title, artist: $0.artistName, position: position,
                                                  duration: $0.duration ?? 0, isPlaying: playing, isLoading: false,
                                                  isFavorite: favorite, isSuperLiked: superLiked, shuffleEnabled: shuffle,
                                                  repeatMode: repeatMode)
                          })
    }

    var artworkURL: URL? { current?.artworkURL }

    func observe(_ observer: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        observer()
        return id
    }

    func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }

    func handle(_ request: CompanionRequest) -> CompanionResponse {
        handled.append(request)
        var error: String?
        if !NearbyDevicesController.isReadOnly(request.action) {
            if let lease = request.executionLease, lease.sessionID == sessionID, let issued = leases[lease.id],
               clock.now - issued < 6 {
                if let expected = request.expectedTrackID, expected != current?.id { error = "The song has changed." }
            } else {
                error = Self.expiredLease
            }
            if error == nil { apply(request.action) }
        }
        let lease = CompanionExecutionLease(id: UUID(), sessionID: sessionID)
        leases[lease.id] = clock.now
        if error == nil, !NearbyDevicesController.isReadOnly(request.action) { sequence += 1 }
        return CompanionResponse(id: request.id, accepted: error == nil, snapshot: companionSnapshot, error: error,
                                 executionLease: lease)
    }

    private func apply(_ action: CompanionAction) {
        switch action {
        case .play: playing = true
        case .pause: playing = false
        case .next: index = min(index + 1, queue.count - 1)
        case .previous: index = max(index - 1, 0)
        case .seek(let target): position = target
        case .setFavorite(let value): favorite = value
            if !value { superLiked = false }
        case .setSuperLiked(let value): superLiked = value
            if value { favorite = true }
        case .setShuffle(let value): shuffle = value
        case .setRepeatMode(let mode): repeatMode = mode
        case .snapshot, .browse, .playItem: break
        }
    }

    var handoffSnapshot: PlaybackSnapshot? {
        guard current != nil else { return nil }
        return PlaybackSnapshot(queue: queue, currentIndex: index, position: position, shuffleEnabled: shuffle)
    }

    var hasHandoffSelection: Bool { current != nil }
    var isPlaying: Bool { playing }
    var isLiveRadio: Bool { liveRadio }

    func pause() {
        pauseCount += 1
        playing = false
        bump()
    }

    func continuePlayback(from snapshot: PlaybackSnapshot, at position: TimeInterval, startPlaying: Bool) -> Bool {
        continued.append((snapshot, position, startPlaying))
        guard continueResult else { return false }
        queue = snapshot.queue
        index = snapshot.currentIndex
        self.position = position
        playing = startPlaying
        ready = readyAfterContinue
        bump()
        return true
    }

    func isReady(for trackID: String) -> Bool { ready && current?.id == trackID }

    func seek(to position: TimeInterval) {
        seeks.append(position)
        self.position = position
    }

    func resume() {
        resumeCount += 1
        playing = true
        bump()
    }
}

@MainActor
final class InMemoryNearbyNetwork {
    var transports: [UUID: InMemoryNearbyTransport] = [:]
    var dropsMessages = false
    var refusesConnections = false
    /// How a handshake with mismatched keys fails; a TLS error by default, like Network.framework.
    var handshakeFailure: NearbyConnectionFailure = .tls
    var dropMessage: ((NearbyLinkMessage) -> Bool)?
    var holdMessage: ((NearbyLinkMessage) -> Bool)?
    private var held: [() -> Void] = []

    func hold(_ delivery: @escaping () -> Void) { held.append(delivery) }

    func releaseHeld() {
        holdMessage = nil
        let deliveries = held
        held = []
        for delivery in deliveries { enqueue(delivery) }
    }
    private(set) var dialCount = 0
    private var queue: [() -> Void] = []
    private var flushScheduled = false
    private var connections: [WeakConnection] = []

    var openConnectionCount: Int { connections.compactMap(\.value).filter { $0.isOpen }.count }

    func enqueue(_ work: @escaping () -> Void) {
        queue.append(work)
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { @MainActor in self.flush() }
    }

    func flush() {
        flushScheduled = false
        var budget = 100_000
        while !queue.isEmpty, budget > 0 {
            budget -= 1
            queue.removeFirst()()
        }
    }

    func announce() {
        enqueue { [weak self] in
            guard let self else { return }
            for transport in self.transports.values where transport.browsing {
                transport.onServicesChanged?(self.services(excluding: transport.id))
            }
        }
    }

    func services(excluding id: UUID) -> [NearbyDiscoveredService] {
        transports.values.compactMap { transport in
            guard transport.id != id, let listening = transport.listening else { return nil }
            return NearbyDiscoveredService(installationID: transport.id, isPairing: listening.pairing)
        }
    }

    func track(_ connection: InMemoryNearbyConnection) {
        if connection.isClient { dialCount += 1 }
        connections.append(WeakConnection(value: connection))
    }

    func closeAll() {
        for connection in connections.compactMap(\.value) where connection.isOpen { connection.drop() }
    }

    /// Sends a raw message over the open session from one installation to another, bypassing its controller.
    func inject(_ message: NearbyLinkMessage, from: UUID, to: UUID) {
        guard let connection = connections.compactMap(\.value).first(where: {
            $0.isOpen && $0.isReady && $0.localID == from && $0.remoteID == to
        }), let payload = try? NearbyLinkWire.encode(message) else { return XCTFail("No open session to inject into") }
        connection.send(payload)
    }

    /// Opens a second session outside the controller's dial rule, as a crossing dial would.
    func dialDirectly(from: UUID, to: UUID, security: NearbyLinkSecurity,
                      onReady: ((InMemoryNearbyConnection) -> Void)? = nil) {
        guard let transport = transports[from] else { return }
        let connection = InMemoryNearbyConnection(network: self, localID: from, remoteID: to, security: security, isClient: true)
        track(connection)
        transport.onIncomingDirect(connection, onReady: onReady)
    }

    private struct WeakConnection {
        weak var value: InMemoryNearbyConnection?
    }
}

@MainActor
final class InMemoryNearbyTransport: NearbyLinkTransporting {
    let id: UUID
    unowned let network: InMemoryNearbyNetwork
    var onServicesChanged: (@MainActor ([NearbyDiscoveredService]) -> Void)?
    var onIncomingConnection: (@MainActor (any NearbyLinkConnection) -> Void)?
    var onListenerFailed: (@MainActor () -> Void)?
    private(set) var listening: (pairing: Bool, security: NearbyLinkSecurity)?
    private(set) var browsing = false
    private(set) var advertisedID: UUID?
    private var directConnections: [InMemoryNearbyConnection] = []

    init(id: UUID, network: InMemoryNearbyNetwork) {
        self.id = id
        self.network = network
        network.transports[id] = self
    }

    func startListening(installationID: UUID, pairing: Bool, security: NearbyLinkSecurity) {
        listening = (pairing, security)
        advertisedID = installationID
        network.announce()
    }

    func stopListening() {
        listening = nil
        network.announce()
    }

    func startBrowsing() {
        browsing = true
        network.announce()
    }

    func stopBrowsing() { browsing = false }

    func connect(to service: NearbyDiscoveredService, security: NearbyLinkSecurity) -> (any NearbyLinkConnection)? {
        guard network.transports[service.installationID] != nil else { return nil }
        let connection = InMemoryNearbyConnection(network: network, localID: id, remoteID: service.installationID,
                                                  security: security, isClient: true)
        network.track(connection)
        return connection
    }

    /// A raw client end that no controller owns; its hello comes from the harness itself.
    func onIncomingDirect(_ connection: InMemoryNearbyConnection, onReady: ((InMemoryNearbyConnection) -> Void)? = nil) {
        directConnections.append(connection)
        connection.onEvent = { [weak connection, id] event in
            guard case .ready = event, let connection else { return }
            if let onReady { onReady(connection); return }
            let hello = NearbyPeerHello(installationID: id, displayName: "Duplicate", deviceKind: .iPad)
            if let payload = try? NearbyLinkWire.encode(.hello(hello)) { connection.send(payload) }
        }
        connection.start()
    }
}

@MainActor
final class InMemoryNearbyConnection: NearbyLinkConnection {
    var onEvent: (@MainActor (NearbyConnectionEvent) -> Void)?
    let localID: UUID
    let remoteID: UUID
    let security: NearbyLinkSecurity
    let isClient: Bool
    private unowned let network: InMemoryNearbyNetwork
    private weak var peer: InMemoryNearbyConnection?
    private var retainedPeer: InMemoryNearbyConnection?
    private var decoder = NearbyFrameDecoder()
    private(set) var isReady = false
    private var closed = false

    var isOpen: Bool { !closed }

    init(network: InMemoryNearbyNetwork, localID: UUID, remoteID: UUID, security: NearbyLinkSecurity, isClient: Bool) {
        self.network = network
        self.localID = localID
        self.remoteID = remoteID
        self.security = security
        self.isClient = isClient
    }

    func start() {
        network.enqueue { [self] in isClient ? dial() : serverStarted() }
    }

    private func dial() {
        guard !closed else { return }
        guard !network.refusesConnections, let target = network.transports[remoteID], let listening = target.listening else {
            fail(.network)
            return
        }
        let server = InMemoryNearbyConnection(network: network, localID: remoteID, remoteID: localID,
                                              security: listening.security, isClient: false)
        network.track(server)
        server.peer = self
        peer = server
        // The listener's owner retains the accepted end; until then the dialer keeps it alive.
        retainedPeer = server
        target.onIncomingConnection?(server)
    }

    private func serverStarted() {
        guard !closed, let client = peer else { return }
        client.retainedPeer = nil
        if client.security == security {
            becomeReady()
            client.becomeReady()
        } else {
            fail(network.handshakeFailure)
            client.fail(network.handshakeFailure)
        }
    }

    private func becomeReady() {
        guard !closed, !isReady else { return }
        isReady = true
        onEvent?(.ready)
    }

    func send(_ payload: Data) {
        guard isReady, !closed, !network.dropsMessages, let framed = try? NearbyLinkWire.frame(payload) else { return }
        let message = try? NearbyLinkWire.decode(payload)
        if let message, network.dropMessage?(message) == true { return }
        let peer = self.peer
        if let message, network.holdMessage?(message) == true {
            network.hold { peer?.deliver(framed) }
            return
        }
        network.enqueue { peer?.deliver(framed) }
    }

    private func deliver(_ framed: Data) {
        guard !closed else { return }
        do {
            for frame in try decoder.append(framed) {
                guard !closed else { return }
                onEvent?(.received(frame))
            }
        } catch {
            fail(.protocolError)
        }
    }

    func cancel() {
        guard !closed else { return }
        closed = true
        onEvent = nil
        let peer = self.peer
        network.enqueue { peer?.remoteClosed() }
    }

    func drop() { fail(.network) }

    private func remoteClosed() { fail(.network) }

    private func fail(_ failure: NearbyConnectionFailure) {
        guard !closed else { return }
        closed = true
        let handler = onEvent
        onEvent = nil
        let peer = self.peer
        network.enqueue { peer?.remoteClosed() }
        handler?(.failed(failure))
    }
}

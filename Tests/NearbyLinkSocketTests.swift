import Foundation
import Network
import XCTest
@testable import GanaBajana

/// Two production controllers over real TLS-PSK sockets on 127.0.0.1; a registry stands in for Bonjour,
/// so this runs where Local Network privacy blocks discovery.
@MainActor
final class NearbyLinkSocketIntegrationTests: XCTestCase {
    private var fixtures: [SocketPeer] = []

    override func tearDown() async throws {
        for fixture in fixtures { fixture.shutdown() }
        fixtures = []
        try await super.tearDown()
    }

    func testPeersDiscoverHandshakeAndShareNowPlaying() async throws {
        let (a, b) = try await connectedPair()
        XCTAssertEqual(a.controller.peers.map(\.displayName), ["Kitchen iPad"])
        XCTAssertEqual(a.controller.peers.first?.kind, .iPad)
        XCTAssertEqual(b.controller.peers.map(\.displayName), ["Study Mac"])
        XCTAssertEqual(b.controller.peers.first?.kind, .mac)
        XCTAssertEqual(b.controller.peers.first?.id, a.controller.installationID)
        XCTAssertEqual(a.transport.stats.outboundReady, 1, "The smaller installation dials once")
        XCTAssertEqual(b.transport.stats.outboundReady, 0)
        XCTAssertEqual(b.transport.stats.inboundReady, 1)

        try await eventually("A's snapshot on B") { b.controller.peers.first?.nowPlaying?.snapshot.nowPlaying?.trackID == "a" }
        let nowPlaying = try XCTUnwrap(b.controller.peers.first?.nowPlaying)
        XCTAssertEqual(nowPlaying.snapshot.sessionID, a.host.sessionID)
        XCTAssertEqual(nowPlaying.snapshot.nowPlaying?.title, "Song a")
        XCTAssertEqual(nowPlaying.snapshot.nowPlaying?.position, 10)
        XCTAssertEqual(nowPlaying.snapshot.nowPlaying?.isPlaying, true)
        XCTAssertEqual(nowPlaying.artworkURL?.absoluteString, "https://img.example/a.jpg")

        // A semantic change crosses the socket at once, without waiting for the position throttle.
        a.host.playing = false
        a.host.bump()
        try await eventually("A's pause on B", timeout: 5) {
            b.controller.peers.first?.nowPlaying?.snapshot.nowPlaying?.isPlaying == false
        }
        try await eventually("ping round trip", timeout: 5) { b.controller.peers.first?.roundTrip != nil }
        XCTAssertLessThan(b.controller.peers.first?.roundTrip ?? .infinity, 2)
    }

    func testRemotePauseIsAppliedWithALease() async throws {
        let (a, b) = try await connectedPair()
        try await eventually("A's snapshot on B") { b.controller.peers.first?.nowPlaying?.snapshot.nowPlaying?.trackID == "a" }

        let result = await b.controller.send(.pause, to: a.controller.installationID, displayedTrackID: "a")
        XCTAssertEqual(result, .accepted)
        XCTAssertEqual(a.host.handled.map(\.action), [.snapshot, .pause])
        XCTAssertNil(a.host.handled[0].executionLease)
        let lease = try XCTUnwrap(a.host.handled[1].executionLease)
        XCTAssertEqual(lease.sessionID, a.host.sessionID)
        XCTAssertEqual(a.host.handled[1].expectedTrackID, "a")
        XCTAssertFalse(a.host.playing)
        XCTAssertNil(b.controller.peers.first?.controlError)
        try await eventually("pause reflected on B", timeout: 5) {
            b.controller.peers.first?.nowPlaying?.snapshot.nowPlaying?.isPlaying == false
        }
    }

    func testPlayHereOverSocketsHandsOverAtTheReleasedPosition() async throws {
        let (a, b) = try await connectedPair()
        try await eventually("ping round trip") { b.controller.peers.first?.roundTrip != nil }
        b.host.queue = []
        b.host.bump()
        b.host.readyAfterContinue = false

        b.controller.playHere(from: a.controller.installationID)
        XCTAssertEqual(b.controller.transferState, .preparing(peerID: a.controller.installationID))
        try await eventually("offer applied on B") { b.host.continued.count == 1 }
        let applied = try XCTUnwrap(b.host.continued.first)
        XCTAssertFalse(applied.startPlaying)
        XCTAssertEqual(applied.snapshot.queue.map(\.id), ["a", "b"])
        XCTAssertGreaterThanOrEqual(applied.position, 10)
        XCTAssertLessThan(applied.position, 11)
        // B is not ready yet; hold briefly so a premature pause on A would have time to arrive.
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(a.host.pauseCount, 0, "The source never pauses before the target is ready")
        XCTAssertTrue(a.host.playing)
        XCTAssertTrue(a.controller.isTransferring)

        a.host.position = 42.5
        b.host.ready = true
        b.host.bump()
        try await eventually("B resumes") { b.host.resumeCount == 1 }
        XCTAssertEqual(a.host.pauseCount, 1)
        XCTAssertFalse(a.host.playing)
        XCTAssertEqual(b.host.seeks.count, 1)
        let seek = try XCTUnwrap(b.host.seeks.first)
        XCTAssertGreaterThanOrEqual(seek, 42.5)
        XCTAssertEqual(seek, 42.5, accuracy: 0.05, "Released position plus half a loopback round trip")
        XCTAssertTrue(b.host.playing)
        XCTAssertEqual(b.controller.transferState, .idle)
        try await eventually("source retires its transfer", timeout: 5) { !a.controller.isTransferring }
        XCTAssertFalse(b.controller.isTransferring)
    }

    func testDifferentLinkKeyNeverConnects() async throws {
        let registry = LoopbackRegistry()
        let a = makePeer(registry: registry, id: NearbyHarness.smallID, name: "Study Mac", kind: .mac)
        let c = makePeer(registry: registry, id: NearbyHarness.largeID, name: "Stranger", kind: .iPhone)
        XCTAssertNotEqual(a.store.key, c.store.key)
        a.controller.enable()
        c.controller.enable()
        try await requireListeners(registry, count: 2)

        // Two failed handshakes prove the dialer retried with backoff and every attempt was refused.
        try await eventually("two refused handshakes") { a.transport.stats.outboundFailed >= 2 }
        XCTAssertEqual(a.transport.stats.outboundReady, 0)
        XCTAssertEqual(c.transport.stats.inboundReady, 0)
        XCTAssertGreaterThanOrEqual(c.transport.stats.inboundFailed, 1)
        XCTAssertTrue(a.controller.peers.isEmpty)
        XCTAssertTrue(c.controller.peers.isEmpty)
    }

    // MARK: Helpers

    private func connectedPair() async throws -> (SocketPeer, SocketPeer) {
        let registry = LoopbackRegistry()
        let a = makePeer(registry: registry, id: NearbyHarness.smallID, name: "Study Mac", kind: .mac)
        let b = makePeer(registry: registry, id: NearbyHarness.largeID, name: "Kitchen iPad", kind: .iPad)
        b.store.key = a.store.key
        a.controller.enable()
        b.controller.enable()
        try await requireListeners(registry, count: 2)
        try await eventually("TLS-PSK hello on both ends") {
            a.controller.peers.first?.state == .connected && b.controller.peers.first?.state == .connected
        }
        return (a, b)
    }

    private func makePeer(registry: LoopbackRegistry, id: UUID, name: String, kind: NearbyDeviceKind) -> SocketPeer {
        let peer = SocketPeer(registry: registry, id: id, name: name, kind: kind)
        fixtures.append(peer)
        return peer
    }

    private func requireListeners(_ registry: LoopbackRegistry, count: Int) async throws {
        try await eventually("loopback listeners", timeout: 10) { registry.ports.count >= count || registry.bindFailures > 0 }
        if registry.bindFailures > 0 { throw XCTSkip("A loopback listener could not bind 127.0.0.1") }
    }

    private func eventually(_ what: String, timeout: TimeInterval = 20,
                            _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting for \(what)")
                throw LoopbackTimeout()
            }
            try await Task.sleep(for: .milliseconds(25))
        }
    }
}

private struct LoopbackTimeout: Error {}

/// One production controller with a fake host, its own key store and a loopback transport.
@MainActor
private final class SocketPeer {
    let store: InMemoryNearbyLinkKeyStore
    let host: FakeNearbyHost
    let transport: LoopbackSocketTransport
    let defaults: UserDefaults
    let suite: String
    let controller: NearbyDevicesController

    init(registry: LoopbackRegistry, id: UUID, name: String, kind: NearbyDeviceKind) {
        let store = InMemoryNearbyLinkKeyStore()
        store.key = NearbyLinkKey.random()
        // The host's lease clock never advances, so every lease the host issues stays valid on its side.
        let host = FakeNearbyHost(clock: ManualNearbyClock())
        let transport = LoopbackSocketTransport(id: id, registry: registry)
        let suite = "nearby-socket-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        self.store = store
        self.host = host
        self.transport = transport
        self.suite = suite
        self.defaults = defaults
        // Production clock and sleep: these tests exercise real socket timing.
        controller = NearbyDevicesController(host: host, transport: transport, keyStore: store, defaults: defaults,
                                             installationID: id, displayName: name, deviceKind: kind)
    }

    func shutdown() {
        controller.disable()
        transport.stopListening()
        transport.stopBrowsing()
        defaults.removePersistentDomain(forName: suite)
    }
}

/// Stands in for Bonjour: each listener publishes its bound loopback port under its installation ID.
@MainActor
final class LoopbackRegistry {
    private(set) var ports: [UUID: (port: NWEndpoint.Port, pairing: Bool)] = [:]
    private(set) var bindFailures = 0
    private var transports: [WeakTransport] = []

    func register(_ transport: LoopbackSocketTransport) {
        transports.append(WeakTransport(value: transport))
    }

    func publish(_ id: UUID, port: NWEndpoint.Port, pairing: Bool) {
        ports[id] = (port, pairing)
        announce()
    }

    func unpublish(_ id: UUID) {
        guard ports.removeValue(forKey: id) != nil else { return }
        announce()
    }

    func recordBindFailure() { bindFailures += 1 }

    func services(excluding id: UUID) -> [NearbyDiscoveredService] {
        ports.filter { $0.key != id }.map { NearbyDiscoveredService(installationID: $0.key, isPairing: $0.value.pairing) }
    }

    /// Delivered on a later main-queue turn, as a browser's results would be.
    private func announce() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                for transport in self.transports.compactMap(\.value) { transport.deliverServices() }
            }
        }
    }

    private struct WeakTransport {
        weak var value: LoopbackSocketTransport?
    }
}

/// Real NWListener and NWConnection with the production TLS parameters and framing, minus Bonjour.
@MainActor
final class LoopbackSocketTransport: NearbyLinkTransporting {
    struct Stats {
        var outboundReady = 0
        var outboundFailed = 0
        var inboundReady = 0
        var inboundFailed = 0
    }

    var onServicesChanged: (@MainActor ([NearbyDiscoveredService]) -> Void)?
    var onIncomingConnection: (@MainActor (any NearbyLinkConnection) -> Void)?
    var onListenerFailed: (@MainActor () -> Void)?
    private(set) var stats = Stats()

    let id: UUID
    private let registry: LoopbackRegistry
    private var listener: NWListener?
    private var listenerToken: UUID?
    private var browsing = false

    init(id: UUID, registry: LoopbackRegistry) {
        self.id = id
        self.registry = registry
        registry.register(self)
    }

    func startListening(installationID: UUID, pairing: Bool, security: NearbyLinkSecurity) {
        stopListening()
        let parameters = NearbyLinkTLS.parameters(security: security)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        parameters.includePeerToPeer = false
        let token = UUID()
        let listener: NWListener
        do { listener = try NWListener(using: parameters) } catch {
            registry.recordBindFailure()
            onListenerFailed?()
            return
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated {
                guard let self, self.listenerToken == token else { connection.cancel(); return }
                let observed = ObservedConnection(inner: NearbyNWConnection(connection: connection)) { [weak self] event in
                    self?.record(event, outbound: false)
                }
                self.onIncomingConnection?(observed)
            }
        }
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self, self.listenerToken == token else { return }
                switch state {
                case .ready:
                    guard let port = self.listener?.port else { return }
                    self.registry.publish(installationID, port: port, pairing: pairing)
                case .failed, .waiting:
                    self.registry.recordBindFailure()
                    self.stopListening()
                    self.onListenerFailed?()
                default:
                    break
                }
            }
        }
        self.listener = listener
        listenerToken = token
        listener.start(queue: .main)
    }

    func stopListening() {
        listenerToken = nil
        listener?.newConnectionHandler = nil
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil
        registry.unpublish(id)
    }

    func startBrowsing() {
        browsing = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.deliverServices() }
        }
    }

    func stopBrowsing() { browsing = false }

    func deliverServices() {
        guard browsing else { return }
        onServicesChanged?(registry.services(excluding: id))
    }

    func connect(to service: NearbyDiscoveredService, security: NearbyLinkSecurity) -> (any NearbyLinkConnection)? {
        guard let entry = registry.ports[service.installationID] else { return nil }
        let connection = NWConnection(host: "127.0.0.1", port: entry.port, using: NearbyLinkTLS.parameters(security: security))
        return ObservedConnection(inner: NearbyNWConnection(connection: connection)) { [weak self] event in
            self?.record(event, outbound: true)
        }
    }

    private func record(_ event: NearbyConnectionEvent, outbound: Bool) {
        switch (event, outbound) {
        case (.ready, true): stats.outboundReady += 1
        case (.ready, false): stats.inboundReady += 1
        case (.failed, true): stats.outboundFailed += 1
        case (.failed, false): stats.inboundFailed += 1
        case (.received, _): break
        }
    }
}

/// Forwards to the production connection while counting its lifecycle events for assertions.
@MainActor
final class ObservedConnection: NearbyLinkConnection {
    var onEvent: (@MainActor (NearbyConnectionEvent) -> Void)?
    private let inner: NearbyNWConnection
    private let observe: @MainActor (NearbyConnectionEvent) -> Void

    init(inner: NearbyNWConnection, observe: @escaping @MainActor (NearbyConnectionEvent) -> Void) {
        self.inner = inner
        self.observe = observe
        inner.onEvent = { [weak self] event in
            guard let self else { return }
            self.observe(event)
            self.onEvent?(event)
        }
    }

    func start() { inner.start() }
    func send(_ payload: Data) { inner.send(payload) }
    func cancel() {
        onEvent = nil
        inner.cancel()
    }
}

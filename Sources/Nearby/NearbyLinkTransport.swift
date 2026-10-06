import Foundation
import Network
import OSLog
import Security

/// Which pre-shared key protects a session: the shared link key, or a pairing code.
enum NearbyLinkSecurity: Equatable, Sendable {
    case link(psk: Data)
    case pairing(psk: Data)

    var psk: Data {
        switch self {
        case .link(let psk), .pairing(let psk): psk
        }
    }

    var identity: String {
        switch self {
        case .link: NearbyLinkKey.linkIdentity
        case .pairing: NearbyLinkKey.pairingIdentity
        }
    }

    var isPairing: Bool { if case .pairing = self { true } else { false } }
}

/// A Bonjour result; the service name is a per-installation UUID, never a device name.
struct NearbyDiscoveredService: Equatable, Hashable, Sendable {
    let installationID: UUID
    let isPairing: Bool
}

enum NearbyConnectionFailure: String, Equatable, Sendable {
    case tls, timeout, network, protocolError
}

enum NearbyConnectionEvent: Equatable, Sendable {
    case ready
    /// One complete frame payload; framing never reaches the controller.
    case received(Data)
    case failed(NearbyConnectionFailure)
}

@MainActor
protocol NearbyLinkConnection: AnyObject {
    var onEvent: (@MainActor (NearbyConnectionEvent) -> Void)? { get set }
    func start()
    func send(_ payload: Data)
    func cancel()
}

@MainActor
protocol NearbyLinkTransporting: AnyObject {
    var onServicesChanged: (@MainActor ([NearbyDiscoveredService]) -> Void)? { get set }
    var onIncomingConnection: (@MainActor (any NearbyLinkConnection) -> Void)? { get set }
    var onListenerFailed: (@MainActor () -> Void)? { get set }
    func startListening(installationID: UUID, pairing: Bool, security: NearbyLinkSecurity)
    func stopListening()
    func startBrowsing()
    func stopBrowsing()
    func connect(to service: NearbyDiscoveredService, security: NearbyLinkSecurity) -> (any NearbyLinkConnection)?
}

/// TLS 1.2 PSK parameters in the pattern of Apple's TicTacToe sample; Network.framework supports PSK only on 1.2.
enum NearbyLinkTLS {
    /// TLS_PSK_WITH_AES_128_GCM_SHA256 (RFC 5487).
    static let cipherSuite: UInt16 = 0x00A8

    static func parameters(security: NearbyLinkSecurity) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        let key = security.psk.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data(security.identity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(options, key as __DispatchData, identity as __DispatchData)
        if let suite = tls_ciphersuite_t(rawValue: cipherSuite) {
            sec_protocol_options_append_tls_ciphersuite(options, suite)
        }
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        // A cached session would resume without the PSK, so a replaced or revoked link key would still connect.
        sec_protocol_options_set_tls_resumption_enabled(options, false)
        sec_protocol_options_set_tls_tickets_enabled(options, false)

        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3
        tcp.connectionTimeout = 10
        tcp.noDelay = true
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = true
        return parameters
    }
}

/// Wraps one NWConnection. Callbacks run on the main queue, so every hop lands on the MainActor in arrival order.
@MainActor
final class NearbyNWConnection: NearbyLinkConnection {
    nonisolated static let readyDeadline: TimeInterval = 10

    var onEvent: (@MainActor (NearbyConnectionEvent) -> Void)?

    private let connection: NWConnection
    private var decoder = NearbyFrameDecoder()
    private var isReady = false
    private var finished = false
    private var started = false

    init(connection: NWConnection) {
        self.connection = connection
    }

    func start() {
        guard !started else { return }
        started = true
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.handle(state) }
        }
        connection.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.readyDeadline) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isReady else { return }
                self.fail(.timeout)
            }
        }
    }

    func send(_ payload: Data) {
        guard isReady, !finished, let framed = try? NearbyLinkWire.frame(payload) else { return }
        connection.send(content: framed, completion: .contentProcessed { [weak self] error in
            guard error != nil else { return }
            MainActor.assumeIsolated { self?.fail(.network) }
        })
    }

    func cancel() {
        guard !finished else { return }
        finished = true
        onEvent = nil
        connection.cancel()
    }

    private func handle(_ state: NWConnection.State) {
        guard !finished else { return }
        switch state {
        case .ready:
            guard !isReady else { return }
            isReady = true
            onEvent?(.ready)
            receiveNext()
        case .waiting(let error), .failed(let error):
            // Waiting retries forever by default; the controller owns backoff, so a stalled attempt fails here.
            fail(Self.classify(error))
        case .cancelled:
            fail(.network)
        case .setup, .preparing:
            break
        @unknown default:
            break
        }
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) { [weak self] content, _, isComplete, error in
            MainActor.assumeIsolated { self?.received(content, isComplete: isComplete, failed: error != nil) }
        }
    }

    private func received(_ content: Data?, isComplete: Bool, failed: Bool) {
        guard !finished else { return }
        if let content, !content.isEmpty {
            do {
                for frame in try decoder.append(content) {
                    guard !finished else { return }
                    onEvent?(.received(frame))
                }
            } catch {
                fail(.protocolError)
                return
            }
        }
        guard !finished else { return }
        if failed || isComplete { fail(.network); return }
        receiveNext()
    }

    private func fail(_ reason: NearbyConnectionFailure) {
        guard !finished else { return }
        finished = true
        let handler = onEvent
        onEvent = nil
        connection.cancel()
        handler?(.failed(reason))
    }

    private static func classify(_ error: NWError) -> NearbyConnectionFailure {
        switch error {
        case .tls: .tls
        case .posix(let code) where code == .ETIMEDOUT: .timeout
        default: .network
        }
    }
}

@MainActor
final class NearbyNetworkTransport: NearbyLinkTransporting {
    var onServicesChanged: (@MainActor ([NearbyDiscoveredService]) -> Void)?
    var onIncomingConnection: (@MainActor (any NearbyLinkConnection) -> Void)?
    var onListenerFailed: (@MainActor () -> Void)?

    private let log = Logger(subsystem: "com.agraabhi.ganabajana", category: "nearby")
    private var listener: NWListener?
    private var listenerToken: UUID?
    private var browser: NWBrowser?
    private var browserToken: UUID?
    /// Set by `startBrowsing` and cleared only by `stopBrowsing`; a failed browser restarts while this holds.
    private var wantsBrowsing = false
    private var browserRetry: Task<Void, Never>?
    private var endpoints: [UUID: NWEndpoint] = [:]

    init() {}

    func startListening(installationID: UUID, pairing: Bool, security: NearbyLinkSecurity) {
        stopListening()
        let token = UUID()
        do {
            let listener = try NWListener(using: NearbyLinkTLS.parameters(security: security))
            var txt = NWTXTRecord()
            txt["v"] = String(NearbyLinkWire.version)
            if pairing { txt["pair"] = "1" }
            listener.service = NWListener.Service(name: installationID.uuidString, type: NearbyLinkWire.serviceType,
                                                  domain: nil, txtRecord: txt)
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated {
                    guard let self, self.listenerToken == token else { connection.cancel(); return }
                    self.onIncomingConnection?(NearbyNWConnection(connection: connection))
                }
            }
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated { self?.listenerChanged(state, token: token) }
            }
            self.listener = listener
            listenerToken = token
            listener.start(queue: .main)
        } catch {
            log.error("event=nearby_listener result=failed")
            onListenerFailed?()
        }
    }

    func stopListening() {
        listenerToken = nil
        listener?.newConnectionHandler = nil
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil
    }

    func startBrowsing() {
        wantsBrowsing = true
        guard browser == nil else { return }
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: NearbyLinkWire.serviceType, domain: nil), using: parameters)
        let token = UUID()
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated {
                guard let self, self.browserToken == token else { return }
                self.update(results)
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self, self.browserToken == token else { return }
                if case .waiting(let error) = state {
                    // Local Network denial and missing NSBonjourServices surface here rather than as a failure.
                    self.log.error("event=nearby_browser result=waiting code=\(Self.errorCode(error))")
                }
                if case .failed = state {
                    self.log.error("event=nearby_browser result=failed")
                    self.tearDownBrowser()
                    self.onServicesChanged?([])
                    self.scheduleBrowserRetry()
                }
            }
        }
        self.browser = browser
        browserToken = token
        browser.start(queue: .main)
    }

    func stopBrowsing() {
        wantsBrowsing = false
        browserRetry?.cancel()
        browserRetry = nil
        tearDownBrowser()
    }

    private func tearDownBrowser() {
        browserToken = nil
        browser?.browseResultsChangedHandler = nil
        browser?.stateUpdateHandler = nil
        browser?.cancel()
        browser = nil
        endpoints = [:]
    }

    /// Network changes and mDNSResponder restarts fail a browser; discovery must come back without a relaunch.
    private func scheduleBrowserRetry() {
        browserRetry?.cancel()
        browserRetry = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, !Task.isCancelled, self.wantsBrowsing, self.browser == nil else { return }
            self.browserRetry = nil
            self.startBrowsing()
        }
    }

    var isBrowsing: Bool { browser != nil }

    func connect(to service: NearbyDiscoveredService, security: NearbyLinkSecurity) -> (any NearbyLinkConnection)? {
        guard let endpoint = endpoints[service.installationID] else { return nil }
        return NearbyNWConnection(connection: NWConnection(to: endpoint, using: NearbyLinkTLS.parameters(security: security)))
    }

    private func listenerChanged(_ state: NWListener.State, token: UUID) {
        guard listenerToken == token else { return }
        switch state {
        case .failed, .waiting:
            log.error("event=nearby_listener result=failed")
            stopListening()
            onListenerFailed?()
        default:
            break
        }
    }

    private static func errorCode(_ error: NWError) -> Int {
        switch error {
        case .posix(let code): Int(code.rawValue)
        case .dns(let code): Int(code)
        case .tls(let code): Int(code)
        default: 0
        }
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        log.info("event=nearby_browse_results count=\(results.count)")
        var found: [UUID: NearbyDiscoveredService] = [:]
        var endpoints: [UUID: NWEndpoint] = [:]
        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint, let id = UUID(uuidString: name) else { continue }
            guard case .bonjour(let txt) = result.metadata, txt["v"] == String(NearbyLinkWire.version) else { continue }
            let pairing = txt["pair"] == "1"
            // One installation can appear on Wi-Fi and peer-to-peer at once; either endpoint reaches it.
            if endpoints[id] == nil { endpoints[id] = result.endpoint }
            found[id] = NearbyDiscoveredService(installationID: id, isPairing: pairing || (found[id]?.isPairing ?? false))
        }
        self.endpoints = endpoints
        onServicesChanged?(Array(found.values))
    }
}

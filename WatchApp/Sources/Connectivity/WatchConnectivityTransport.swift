import Foundation
import WatchConnectivity

@MainActor
final class WatchConnectivityTransport: WatchTransport {
    nonisolated static let contextKey = "breezy.snapshot.v1"

    private(set) var state: WatchConnectionState = .activating
    var onEvent: (@MainActor (WatchTransportEvent) -> Void)?

    private let session: WCSession?
    private let delegate: WatchConnectivityDelegate
    private var eventTask: Task<Void, Never>?
    private var activationRequested = false

    init() {
        let (stream, continuation) = AsyncStream.makeStream(of: WatchTransportEvent.self)
        delegate = WatchConnectivityDelegate(events: continuation)
        session = WCSession.isSupported() ? WCSession.default : nil
        if session == nil { state = .unsupported }
        session?.delegate = delegate
        // One consumer preserves the delegate queue's ordering without transferring WCSession or [String: Any].
        eventTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                receive(event)
            }
        }
    }

    deinit { eventTask?.cancel() }

    func activate() {
        guard let session else {
            publishState(.unsupported)
            return
        }
        if session.activationState == .activated {
            refreshState()
        } else if !activationRequested, session.activationState != .inactive {
            activationRequested = true
            publishState(.activating)
            session.activate()
        }
    }

    func refreshState() {
        guard let session else { return }
        publishState(WatchConnectivityDelegate.state(of: session))
    }

    func send(_ data: Data, completion: @escaping @Sendable (Result<Data, WatchTransportFailure>) -> Void) {
        guard data.count <= CompanionWire.maximumMessageBytes else {
            completion(.failure(.oversized))
            return
        }
        guard let session, session.activationState == .activated, session.isReachable else {
            completion(.failure(.unreachable))
            return
        }
        WatchConnectivityDelegate.send(data, using: session, completion: completion)
    }

    func updateApplicationContext(_ data: Data) throws {
        guard data.count <= CompanionWire.maximumMessageBytes else { throw WatchTransportFailure.oversized }
        guard let session, session.activationState == .activated, state.canPublish else {
            throw WatchTransportFailure.unreachable
        }
        try session.updateApplicationContext([Self.contextKey: data])
    }

    func finishBackgroundDelivery() async {
        guard let session else { return }
        activate()
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !Task.isCancelled, ContinuousClock.now < deadline {
            if session.activationState == .activated, !session.hasContentPending {
                // Read the retained context before releasing background time, even if a delegate event is still buffered.
                if let data = session.receivedApplicationContext[Self.contextKey] as? Data,
                   data.count <= CompanionWire.maximumMessageBytes {
                    onEvent?(.applicationContext(data))
                }
                return
            }
            if state == .failed { return }
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
        }
    }

    private func receive(_ event: WatchTransportEvent) {
        switch event {
        case .stateChanged(let newState):
            if newState != .activating { activationRequested = false }
            publishState(newState)
        case .deactivated:
            activationRequested = false
            publishState(.inactive)
            onEvent?(.deactivated)
        case .applicationContext:
            onEvent?(event)
        case .request:
            refreshState()
            onEvent?(event)
        }
    }

    private func publishState(_ newState: WatchConnectionState) {
        state = newState
        onEvent?(.stateChanged(newState))
    }
}

private final class WatchConnectivityDelegate: NSObject, WCSessionDelegate {
    private let events: AsyncStream<WatchTransportEvent>.Continuation

    init(events: AsyncStream<WatchTransportEvent>.Continuation) {
        self.events = events
        super.init()
    }

    deinit { events.finish() }

    // SDK reply blocks have no Sendable annotation and must not inherit the caller's main-actor isolation.
    nonisolated static func send(
        _ data: Data,
        using session: WCSession,
        completion: @escaping @Sendable (Result<Data, WatchTransportFailure>) -> Void
    ) {
        session.sendMessageData(data) { reply in
            if reply.count <= CompanionWire.maximumMessageBytes {
                completion(.success(reply))
            } else {
                completion(.failure(.oversized))
            }
        } errorHandler: { _ in
            completion(.failure(.deliveryFailed))
        }
    }

    nonisolated static func state(of session: WCSession) -> WatchConnectionState {
        switch session.activationState {
        case .notActivated: return .activating
        case .inactive: return .inactive
        case .activated:
            #if os(iOS)
            let installed = session.isPaired && session.isWatchAppInstalled
            let needsUnlock = false
            #else
            let installed = session.isCompanionAppInstalled
            let needsUnlock = session.iOSDeviceNeedsUnlockAfterRebootForReachability
            #endif
            return .ready(reachable: session.isReachable, installed: installed, needsUnlock: needsUnlock)
        @unknown default: return .failed
        }
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        events.yield(.stateChanged(error == nil && activationState == .activated ? Self.state(of: session) : .failed))
        if activationState == .activated,
           let data = session.receivedApplicationContext[WatchConnectivityTransport.contextKey] as? Data,
           data.count <= CompanionWire.maximumMessageBytes {
            events.yield(.applicationContext(data))
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        events.yield(.stateChanged(Self.state(of: session)))
    }

    #if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        events.yield(.stateChanged(.inactive))
    }

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        events.yield(.deactivated)
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        events.yield(.stateChanged(Self.state(of: session)))
    }
    #else
    nonisolated func sessionCompanionAppInstalledDidChange(_ session: WCSession) {
        events.yield(.stateChanged(Self.state(of: session)))
    }
    #endif

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let data = applicationContext[WatchConnectivityTransport.contextKey] as? Data,
              data.count <= CompanionWire.maximumMessageBytes else { return }
        events.yield(.applicationContext(data))
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessageData messageData: Data,
        replyHandler: @escaping (Data) -> Void
    ) {
        guard messageData.count <= CompanionWire.maximumMessageBytes else {
            replyHandler(Data())
            return
        }
        let reply = WatchReply(handler: replyHandler)
        reply.scheduleDeadline()
        events.yield(.request(messageData, reply))
    }
}

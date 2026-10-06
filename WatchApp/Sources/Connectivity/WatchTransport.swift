import Foundation

enum WatchClock {
    private static let origin = ContinuousClock.now

    // Continuous time includes suspension, so a late command cannot acquire extra time when a device wakes.
    static var now: TimeInterval {
        let elapsed = origin.duration(to: .now).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1_000_000_000_000_000_000
    }
}

enum WatchConnectionState: Equatable, Sendable {
    case unsupported
    case activating
    case inactive
    case failed
    case ready(reachable: Bool, installed: Bool, needsUnlock: Bool)

    var canMessage: Bool {
        if case .ready(let reachable, let installed, _) = self { return reachable && installed }
        return false
    }

    var canPublish: Bool {
        if case .ready(_, let installed, _) = self { return installed }
        return false
    }
}

enum WatchTransportFailure: Error, Equatable, Sendable {
    case unreachable
    case deliveryFailed
    case oversized
}

enum WatchTransportEvent: Sendable {
    case stateChanged(WatchConnectionState)
    case deactivated
    case applicationContext(Data)
    case request(Data, WatchReply)
}

@MainActor
protocol WatchTransport: AnyObject {
    var state: WatchConnectionState { get }
    var onEvent: (@MainActor (WatchTransportEvent) -> Void)? { get set }
    func activate()
    func refreshState()
    func send(_ data: Data, completion: @escaping @Sendable (Result<Data, WatchTransportFailure>) -> Void)
    func updateApplicationContext(_ data: Data) throws
}

// WCSession's reply block is not Sendable. The lock transfers its single invocation between the deadline and receiver.
final class WatchReply: @unchecked Sendable {
    static let deadline: TimeInterval = 6

    private let lock = NSLock()
    private var handler: ((Data) -> Void)?
    let receivedAt: TimeInterval

    init(receivedAt: TimeInterval = WatchClock.now, handler: @escaping (Data) -> Void) {
        self.receivedAt = receivedAt
        self.handler = handler
    }

    func canHandle(at uptime: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return handler != nil && uptime >= receivedAt && uptime - receivedAt < Self.deadline
    }

    func finish(_ data: Data) {
        lock.lock()
        let reply = handler
        handler = nil
        lock.unlock()
        reply?(data)
    }

    func scheduleDeadline() {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + Self.deadline) { [self] in
            finish(Data())
        }
    }
}

enum WatchActionPolicy {
    static func isReadOnly(_ action: CompanionAction) -> Bool {
        switch action {
        case .snapshot, .browse: true
        default: false
        }
    }

    static func matches(_ action: CompanionAction, displayed: CompanionSnapshot, current: CompanionSnapshot) -> Bool {
        guard displayed.sessionID == current.sessionID,
              displayed.nowPlaying?.trackID == current.nowPlaying?.trackID else { return false }
        switch action {
        case .play, .pause:
            return displayed.nowPlaying?.isPlaying == current.nowPlaying?.isPlaying
                && displayed.nowPlaying?.isLoading == current.nowPlaying?.isLoading
        case .setFavorite, .setSuperLiked:
            // The heart is one three-state control; a tap or hold made against a stale tier is rejected, not reinterpreted.
            return displayed.nowPlaying?.isFavorite == current.nowPlaying?.isFavorite
                && displayed.nowPlaying?.isSuperLiked == current.nowPlaying?.isSuperLiked
        case .setShuffle:
            return displayed.nowPlaying?.shuffleEnabled == current.nowPlaying?.shuffleEnabled
        case .setRepeatMode:
            return displayed.nowPlaying?.repeatMode == current.nowPlaying?.repeatMode
        default:
            return true
        }
    }
}

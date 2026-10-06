import Foundation

@MainActor
final class WatchPhoneSession {
    static let positionPublicationInterval: TimeInterval = 10

    private let transport: any WatchTransport
    private let readSnapshot: @MainActor () -> CompanionSnapshot
    private let handleRequest: @MainActor (CompanionRequest) -> CompanionResponse
    private let observe: @MainActor (@escaping @MainActor (CompanionSnapshot) -> Void) -> UUID
    private let removeObserver: @MainActor (UUID) -> Void
    private let uptime: @MainActor () -> TimeInterval
    private let waitForPublication: @Sendable (TimeInterval) async throws -> Void
    private var observationID: UUID?
    private var latestSnapshot: CompanionSnapshot?
    private var lastPublished: CompanionSnapshot?
    private var lastAttempted: CompanionSnapshot?
    private var lastAttemptAt: TimeInterval?
    private var publicationTask: Task<Void, Never>?
    private var publicationID: UUID?
    private var started = false

    private(set) var contextNeedsRetry = false

    convenience init(playback: CompanionPlaybackController) {
        self.init(transport: WatchConnectivityTransport(), snapshot: { playback.snapshot },
                  handle: { playback.handle($0) }, observe: { playback.observe($0) },
                  removeObserver: { playback.removeObserver($0) })
    }

    init(
        transport: any WatchTransport,
        snapshot: @escaping @MainActor () -> CompanionSnapshot,
        handle: @escaping @MainActor (CompanionRequest) -> CompanionResponse,
        observe: @escaping @MainActor (@escaping @MainActor (CompanionSnapshot) -> Void) -> UUID,
        removeObserver: @escaping @MainActor (UUID) -> Void,
        uptime: @escaping @MainActor () -> TimeInterval = { WatchClock.now },
        waitForPublication: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.transport = transport
        readSnapshot = snapshot
        handleRequest = handle
        self.observe = observe
        self.removeObserver = removeObserver
        self.uptime = uptime
        self.waitForPublication = waitForPublication
    }

    deinit { publicationTask?.cancel() }

    func start() {
        guard !started else { return }
        started = true
        transport.onEvent = { [weak self] event in self?.receive(event) }
        observationID = observe { [weak self] snapshot in self?.publish(snapshot) }
        transport.activate()
        publish(readSnapshot())
    }

    func stop() {
        guard started else { return }
        started = false
        if let observationID { removeObserver(observationID) }
        observationID = nil
        transport.onEvent = nil
        cancelPublication()
        latestSnapshot = nil
        lastPublished = nil
        lastAttempted = nil
        lastAttemptAt = nil
        contextNeedsRetry = false
    }

    private func receive(_ event: WatchTransportEvent) {
        guard started else { return }
        switch event {
        case .stateChanged(let state):
            if state.canPublish { publish(readSnapshot()) }
            else {
                cancelPublication()
                lastPublished = nil
                lastAttempted = nil
                lastAttemptAt = nil
            }
        case .deactivated:
            cancelPublication()
            lastPublished = nil
            lastAttempted = nil
            lastAttemptAt = nil
            transport.activate()
        case .applicationContext:
            break
        case .request(let data, let reply):
            handle(data, reply: reply)
        }
    }

    private func handle(_ data: Data, reply: WatchReply) {
        guard reply.canHandle(at: uptime()) else {
            reply.finish(Data())
            return
        }
        do {
            let request = try CompanionWire.decode(CompanionRequest.self, from: data)
            guard transport.state.canMessage else {
                let rejected = CompanionResponse(id: request.id, accepted: false, snapshot: readSnapshot(),
                                                 error: "Open Velvet Thorn on iPhone, then try again.")
                reply.finish(try CompanionWire.encode(rejected))
                return
            }
            guard WatchActionPolicy.isReadOnly(request.action) || request.executionLease != nil else {
                let rejected = CompanionResponse(id: request.id, accepted: false, snapshot: readSnapshot(),
                                                 error: "Refresh from iPhone before trying this action.")
                reply.finish(try CompanionWire.encode(rejected))
                return
            }
            // Recheck after decoding so an expired request cannot start a playback operation.
            guard reply.canHandle(at: uptime()) else {
                reply.finish(Data())
                return
            }
            let response = handleRequest(request)
            guard response.id == request.id else {
                reply.finish(Data())
                return
            }
            reply.finish(try CompanionWire.encode(response))
            publish(readSnapshot())
        } catch {
            // Empty replies fail closed; a sender with an uncertain command must refresh rather than replay it.
            reply.finish(Data())
        }
    }

    private func publish(_ snapshot: CompanionSnapshot) {
        latestSnapshot = snapshot
        publishLatest()
    }

    private func publishLatest() {
        guard started, transport.state.canPublish, let snapshot = latestSnapshot else { return }
        guard snapshot != lastPublished || contextNeedsRetry else {
            cancelPublication()
            return
        }
        let semanticChange = lastPublished.map { !Self.sameSemantics(snapshot, $0) } ?? true
        guard semanticChange || transport.state.canMessage else {
            cancelPublication()
            return
        }
        let newSemanticChange = lastAttempted.map { !Self.sameSemantics(snapshot, $0) } ?? true
        let now = uptime()
        if !newSemanticChange, let lastAttemptAt, now < lastAttemptAt + Self.positionPublicationInterval {
            schedulePublication(after: lastAttemptAt + Self.positionPublicationInterval - now)
            return
        }
        cancelPublication()
        lastAttemptAt = now
        lastAttempted = snapshot
        do {
            let data = try CompanionWire.encode(snapshot)
            try transport.updateApplicationContext(data)
            lastPublished = snapshot
            contextNeedsRetry = false
        } catch {
            contextNeedsRetry = true
            schedulePublication(after: Self.positionPublicationInterval)
        }
    }

    private func schedulePublication(after seconds: TimeInterval) {
        guard publicationTask == nil else { return }
        let id = UUID()
        publicationID = id
        publicationTask = Task { [weak self, waitForPublication] in
            do { try await waitForPublication(seconds) } catch { return }
            guard let self, publicationID == id else { return }
            publicationTask = nil
            publicationID = nil
            publishLatest()
        }
    }

    private func cancelPublication() {
        publicationID = nil
        publicationTask?.cancel()
        publicationTask = nil
    }

    private static func sameSemantics(_ lhs: CompanionSnapshot, _ rhs: CompanionSnapshot) -> Bool {
        guard lhs.sessionID == rhs.sessionID, lhs.libraryError == rhs.libraryError, lhs.accent == rhs.accent else { return false }
        switch (lhs.nowPlaying, rhs.nowPlaying) {
        case (nil, nil): return true
        case (.some(let lhs), .some(let rhs)):
            return lhs.trackID == rhs.trackID && lhs.title == rhs.title && lhs.artist == rhs.artist
                && lhs.duration == rhs.duration && lhs.isPlaying == rhs.isPlaying && lhs.isLoading == rhs.isLoading
                && lhs.isFavorite == rhs.isFavorite && lhs.isSuperLiked == rhs.isSuperLiked && lhs.shuffleEnabled == rhs.shuffleEnabled
                && lhs.repeatMode == rhs.repeatMode && lhs.errorMessage == rhs.errorMessage
        default: return false
        }
    }
}

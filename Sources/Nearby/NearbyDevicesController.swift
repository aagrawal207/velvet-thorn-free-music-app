import Foundation
import Observation
import OSLog
import UIKit

/// What the controller needs from playback; production wraps `MusicAppModel`, tests use a fake.
@MainActor
protocol NearbyPlaybackHost: AnyObject {
    var companionSnapshot: CompanionSnapshot { get }
    var artworkURL: URL? { get }
    func observe(_ observer: @escaping @MainActor () -> Void) -> UUID
    func removeObserver(_ id: UUID)
    func handle(_ request: CompanionRequest) -> CompanionResponse
    /// Nil when nothing is selected or Live Radio is on.
    var handoffSnapshot: PlaybackSnapshot? { get }
    /// Cheap form of `handoffSnapshot != nil` for views that re-render on every position tick.
    var hasHandoffSelection: Bool { get }
    /// True while playing or starting to play, the intent a handover must carry.
    var isPlaying: Bool { get }
    /// The most exact position available, read again right after `pause()`.
    var position: TimeInterval { get }
    var isLiveRadio: Bool { get }
    func pause()
    func continuePlayback(from snapshot: PlaybackSnapshot, at position: TimeInterval, startPlaying: Bool) -> Bool
    func isReady(for trackID: String) -> Bool
    func seek(to position: TimeInterval)
    func resume()
}

@MainActor
final class MusicAppNearbyHost: NearbyPlaybackHost {
    private let model: MusicAppModel
    private let playback: CompanionPlaybackController

    init(model: MusicAppModel, playback: CompanionPlaybackController) {
        self.model = model
        self.playback = playback
    }

    var companionSnapshot: CompanionSnapshot { playback.snapshot }
    var artworkURL: URL? { model.player.displayArtworkURL }

    func observe(_ observer: @escaping @MainActor () -> Void) -> UUID {
        playback.observe { _ in observer() }
    }

    func removeObserver(_ id: UUID) { playback.removeObserver(id) }

    func handle(_ request: CompanionRequest) -> CompanionResponse {
        playback.handle(request, origin: .nearbyDevice)
    }

    var handoffSnapshot: PlaybackSnapshot? {
        let player = model.player
        guard !player.isLiveRadio, player.currentTrack != nil else { return nil }
        var snapshot = player.handoffSnapshot
        snapshot.position = player.handoffPosition
        return snapshot
    }

    var hasHandoffSelection: Bool { !model.player.isLiveRadio && model.player.currentTrack != nil }
    var isPlaying: Bool { model.player.isPlaying || model.player.isLoading }
    var position: TimeInterval { model.player.handoffPosition }
    var isLiveRadio: Bool { model.player.isLiveRadio }

    func pause() {
        model.cancelPendingRadio()
        model.player.pause()
    }

    func continuePlayback(from snapshot: PlaybackSnapshot, at position: TimeInterval, startPlaying: Bool) -> Bool {
        model.continuePlayback(from: snapshot, at: position, startPlaying: startPlaying, origin: .nearbyDevice)
    }

    func isReady(for trackID: String) -> Bool {
        let player = model.player
        guard let track = player.currentTrack, track.id == trackID, !player.isLoading else { return false }
        // A paused restore resolves no stream, so a song without catalog duration can never report one before Play.
        return player.duration > 0 || PlaybackTiming.validDuration(track.duration) == nil
    }

    func seek(to position: TimeInterval) { model.player.seek(to: position) }

    func resume() {
        model.cancelPendingRadio()
        model.player.resumePlayback()
    }
}

struct NearbyPeer: Identifiable, Equatable {
    enum ConnectionState: Equatable { case connected, reconnecting }

    let id: UUID
    var displayName: String
    var kind: NearbyDeviceKind
    var state: ConnectionState
    var nowPlaying: NearbyNowPlaying?
    /// Local uptime when `nowPlaying` arrived; the peer's own clock is never used.
    var receivedAt: TimeInterval?
    var roundTrip: TimeInterval?
    var controlError: String?

    var isConnected: Bool { state == .connected }

    func position(at uptime: TimeInterval) -> Double? {
        guard let playing = nowPlaying?.snapshot.nowPlaying else { return nil }
        guard playing.isPlaying, !playing.isLoading, let receivedAt else { return playing.position }
        let elapsed = max(0, uptime - receivedAt) + (roundTrip ?? 0) / 2
        let position = playing.position + elapsed
        return playing.duration > 0 ? min(position, playing.duration) : position
    }
}

enum NearbyTransferState: Equatable {
    case idle
    case preparing(peerID: UUID)
    case failed(message: String)
}

enum NearbyPairingState: Equatable {
    case idle, joining, paired
    case failed(message: String)
}

enum NearbyControlResult: Equatable {
    case accepted
    case rejected(String)
}

enum NearbyClock {
    private static let origin = ContinuousClock.now

    /// Continuous time includes suspension, so an old lease cannot look fresh after this device wakes.
    static var now: TimeInterval {
        let elapsed = origin.duration(to: .now).components
        return TimeInterval(elapsed.seconds) + TimeInterval(elapsed.attoseconds) / 1e18
    }
}

@MainActor
@Observable
final class NearbyDevicesController {
    static let enabledKey = "nearby.enabled"
    /// Set by any explicit On or Off, so opening Devices turns discovery on only before the listener has chosen.
    static let choiceMadeKey = "nearby.choiceMade"
    static let positionPublicationInterval: TimeInterval = 5
    static let leaseLifetime: TimeInterval = 6
    static let responseDeadline: TimeInterval = 4
    /// The receiver's whole budget, measured from its request.
    static let transferDeadline: TimeInterval = 12
    static let readinessDeadline: TimeInterval = 6.5
    /// The sender releases only within this window after its offer; with round trips under `maximumRoundTrip`
    /// its release always reaches the receiver before `transferDeadline`.
    static let sourceReleaseWindow: TimeInterval = 9
    static let maximumRoundTrip: TimeInterval = 2
    /// How long a sender can still take its playback back if the receiver cancels after the release.
    static let releasedMemory: TimeInterval = 15
    static let readinessPollInterval: TimeInterval = 0.25
    static let pingInterval: TimeInterval = 15
    static let maximumBackoff: TimeInterval = 30
    static let joinDeadline: TimeInterval = 20
    static let maximumJoinCandidates = 8
    static let pairingIdleDeadline: TimeInterval = 60
    static let pairingGrantLinger: TimeInterval = 30
    static let keyCacheLifetime: TimeInterval = 30

    private(set) var isEnabled: Bool
    private(set) var peers: [NearbyPeer] = []
    private(set) var transferState: NearbyTransferState = .idle
    private(set) var pairingCode: NearbyPairingCode?
    private(set) var pairingState: NearbyPairingState = .idle

    let installationID: UUID
    let displayName: String
    let deviceKind: NearbyDeviceKind

    @ObservationIgnored private let host: any NearbyPlaybackHost
    @ObservationIgnored private let transport: any NearbyLinkTransporting
    @ObservationIgnored private let keyStore: any NearbyLinkKeyStoring
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let uptime: @MainActor () -> TimeInterval
    @ObservationIgnored private let sleep: @MainActor (TimeInterval) async throws -> Void
    @ObservationIgnored private let log = Logger(subsystem: "com.agraabhi.ganabajana", category: "nearby")

    @ObservationIgnored private var running = false
    @ObservationIgnored private var hostObservation: UUID?
    @ObservationIgnored private var sessions: [ObjectIdentifier: Session] = [:]
    @ObservationIgnored private var services: [UUID: NearbyDiscoveredService] = [:]
    @ObservationIgnored private var dialing: [UUID: DialState] = [:]
    @ObservationIgnored private var controls: [UUID: PeerControl] = [:]
    @ObservationIgnored private var pending: [UUID: PendingResponse] = [:]
    @ObservationIgnored private var listenerKey: Data?
    @ObservationIgnored private var listenerIsPairing = false
    @ObservationIgnored private var listenerRetryAt: TimeInterval?
    @ObservationIgnored private var listenerFailures = 0
    @ObservationIgnored private var maintenanceToken: UUID?
    @ObservationIgnored private var maintenanceTask: Task<Void, Never>?
    @ObservationIgnored private var publicationToken: UUID?
    @ObservationIgnored private var publicationDue: TimeInterval?
    @ObservationIgnored private var pull: PullTransfer?
    @ObservationIgnored private var source: SourceTransfer?
    @ObservationIgnored private var push: PushTransfer?
    @ObservationIgnored private var join: JoinAttempt?
    @ObservationIgnored private var released: [ReleasedTransfer] = []
    @ObservationIgnored private var cachedKey: (key: Data, readAt: TimeInterval)?

    convenience init(model: MusicAppModel, playback: CompanionPlaybackController) {
        let identity = NearbyDeviceIdentity.current
        self.init(host: MusicAppNearbyHost(model: model, playback: playback), transport: NearbyNetworkTransport(),
                  keyStore: KeychainNearbyLinkKeyStore(), displayName: identity.name, deviceKind: identity.kind)
    }

    init(
        host: any NearbyPlaybackHost,
        transport: any NearbyLinkTransporting,
        keyStore: any NearbyLinkKeyStoring,
        defaults: UserDefaults = .standard,
        installationID: UUID? = nil,
        displayName: String,
        deviceKind: NearbyDeviceKind,
        uptime: @escaping @MainActor () -> TimeInterval = { NearbyClock.now },
        sleep: @escaping @MainActor (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.host = host
        self.transport = transport
        self.keyStore = keyStore
        self.defaults = defaults
        // Fresh per launch: the Bonjour name is visible to every device on the network and must not track this one.
        self.installationID = installationID ?? UUID()
        self.displayName = NearbyPeerHello(installationID: UUID(), displayName: displayName, deviceKind: deviceKind).displayName
        self.deviceKind = deviceKind
        self.uptime = uptime
        self.sleep = sleep
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        // A saved On means Local Network access was already requested by an explicit user action.
        if isEnabled { start() }
    }

    // MARK: Lifecycle

    /// Call only from an explicit user action: starting the listener and browser triggers the Local Network prompt.
    func enable() {
        if !isEnabled {
            isEnabled = true
            defaults.set(true, forKey: Self.enabledKey)
        }
        defaults.set(true, forKey: Self.choiceMadeKey)
        start()
    }

    func disable() {
        if isEnabled {
            isEnabled = false
            defaults.set(false, forKey: Self.enabledKey)
        }
        defaults.set(true, forKey: Self.choiceMadeKey)
        stop()
    }

    /// Opening Devices is the explicit action for a first enable; an explicit Off survives reopening the screen.
    func enableOnFirstVisit() {
        guard !defaults.bool(forKey: Self.choiceMadeKey) else { return }
        enable()
    }

    /// Replaces the synced link key: every session drops and only devices that receive the new key reconnect.
    @discardableResult
    func resetLinkKey() -> Bool {
        let key = NearbyLinkKey.random()
        do { try keyStore.writeLinkKey(key) } catch {
            log.error("event=nearby_key result=reset_failed")
            return false
        }
        cachedKey = (key, uptime())
        log.info("event=nearby_key result=reset")
        guard running else { return true }
        for session in sessions.values { close(session) }
        for id in Array(dialing.keys) { dialing[id] = DialState() }
        startListener()
        kickMaintenance()
        return true
    }

    private func start() {
        guard !running else { return }
        running = true
        transport.onServicesChanged = { [weak self] services in self?.servicesChanged(services) }
        transport.onIncomingConnection = { [weak self] connection in self?.accept(connection) }
        transport.onListenerFailed = { [weak self] in self?.listenerFailed() }
        hostObservation = host.observe { [weak self] in self?.hostChanged() }
        startListener()
        transport.startBrowsing()
        log.info("event=nearby_enabled")
        kickMaintenance()
    }

    private func stop() {
        guard running else { return }
        running = false
        if let hostObservation { host.removeObserver(hostObservation) }
        hostObservation = nil
        transport.onServicesChanged = nil
        transport.onIncomingConnection = nil
        transport.onListenerFailed = nil
        transport.stopListening()
        transport.stopBrowsing()
        for session in sessions.values { session.connection.cancel() }
        sessions = [:]
        for id in Array(pending.keys) { finishPending(id, with: nil) }
        services = [:]
        dialing = [:]
        controls = [:]
        peers = []
        pull = nil
        source = nil
        push = nil
        join = nil
        released = []
        cachedKey = nil
        transferState = .idle
        pairingCode = nil
        pairingState = .idle
        listenerKey = nil
        listenerIsPairing = false
        listenerRetryAt = nil
        listenerFailures = 0
        maintenanceToken = nil
        maintenanceTask?.cancel()
        maintenanceTask = nil
        publicationToken = nil
        publicationDue = nil
        log.info("event=nearby_disabled")
    }

    // MARK: Queries for the UI

    /// True when this device has a song selected that can move to another device.
    var canSendPlayback: Bool { host.hasHandoffSelection }

    var isTransferring: Bool { pull != nil || source != nil || push != nil }

    func now() -> TimeInterval { uptime() }

    func peer(_ id: UUID) -> NearbyPeer? { peers.first { $0.id == id } }

    func dismissTransferFailure() {
        if case .failed = transferState { transferState = .idle }
    }

    func dismissPairingResult() {
        switch pairingState {
        case .paired, .failed: pairingState = .idle
        default: break
        }
    }

    // MARK: Remote control

    /// Mirrors the Watch: a fresh lease (or a snapshot preflight for one), then the action; nothing is queued or replayed.
    /// Pass the track the listener saw when tapping; a mismatch with the latest snapshot refuses the action.
    @discardableResult
    func send(_ action: CompanionAction, to peerID: UUID, displayedTrackID: String? = nil) async -> NearbyControlResult {
        let result = await performControl(action, peerID: peerID, displayedTrackID: displayedTrackID)
        if let index = peers.firstIndex(where: { $0.id == peerID }) {
            if case .rejected(let message) = result { peers[index].controlError = message }
            else { peers[index].controlError = nil }
        }
        return result
    }

    private func performControl(_ action: CompanionAction, peerID: UUID, displayedTrackID: String?) async -> NearbyControlResult {
        guard let peer = peer(peerID), peer.isConnected, let session = linkSession(for: peerID) else {
            return .rejected(Copy.unreachable)
        }
        let displayed = peer.nowPlaying?.snapshot
        let expectedTrackID = displayed?.nowPlaying?.trackID
        if let displayedTrackID, displayedTrackID != expectedTrackID { return .rejected(Copy.staleTrack) }
        if Self.isReadOnly(action) {
            guard let response = await exchange(CompanionRequest(action: action), on: session) else {
                return .rejected(Copy.noResponse(peer.displayName))
            }
            return response.accepted ? .accepted : .rejected(response.error ?? Copy.rejected)
        }
        guard controls[peerID]?.mutationInFlight != true else { return .rejected(Copy.busy) }
        controls[peerID, default: PeerControl()].mutationInFlight = true
        defer { controls[peerID]?.mutationInFlight = false }

        var lease = freshLease(for: peerID)
        if lease == nil {
            guard let preflight = await exchange(CompanionRequest(action: .snapshot), on: session) else {
                return .rejected(Copy.noResponse(peer.displayName))
            }
            guard preflight.accepted, let issued = preflight.executionLease else {
                return .rejected(preflight.error ?? Copy.rejected)
            }
            guard displayed == nil || displayed?.sessionID == preflight.snapshot.sessionID,
                  preflight.snapshot.nowPlaying?.trackID == expectedTrackID else { return .rejected(Copy.staleTrack) }
            lease = issued
        }
        // The session may have closed while the preflight was outstanding; a mutation never moves to a newer one.
        guard sessions[ObjectIdentifier(session.connection)] === session, session.peerID == peerID else {
            return .rejected(Copy.unreachable)
        }
        let request = CompanionRequest(action: action, expectedTrackID: expectedTrackID, executionLease: lease)
        guard let response = await exchange(request, on: session) else { return .rejected(Copy.noResponse(peer.displayName)) }
        return response.accepted ? .accepted : .rejected(response.error ?? Copy.rejected)
    }

    private func freshLease(for peerID: UUID) -> CompanionExecutionLease? {
        guard let control = controls[peerID], let lease = control.lease, let receivedAt = control.leaseReceivedAt else { return nil }
        let age = uptime() - receivedAt
        // Issuance precedes receipt by at least the reply's flight time; the margin covers scheduling on both ends.
        let margin = (peer(peerID)?.roundTrip ?? 0) + 0.5
        guard age >= 0, age + margin < Self.leaseLifetime else { return nil }
        if let sessionID = peer(peerID)?.nowPlaying?.snapshot.sessionID, sessionID != lease.sessionID { return nil }
        return lease
    }

    private func exchange(_ request: CompanionRequest, on session: Session) async -> CompanionResponse? {
        guard let payload = try? NearbyLinkWire.encode(.request(request)) else { return nil }
        let id = request.id
        return await withCheckedContinuation { continuation in
            pending[id] = PendingResponse(session: ObjectIdentifier(session.connection), continuation: continuation)
            session.connection.send(payload)
            Task { [weak self] in
                guard let self else { return }
                try? await self.sleep(Self.responseDeadline)
                self.finishPending(id, with: nil)
            }
        }
    }

    private func finishPending(_ id: UUID, with response: CompanionResponse?) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.continuation.resume(returning: response)
    }

    // MARK: Transfers

    /// "Play Here": pulls the peer's playback to this device with a paused preparation before the peer lets go.
    func playHere(from peerID: UUID) {
        guard !isTransferring else { return }
        guard let session = linkSession(for: peerID) else {
            transferState = .failed(message: Copy.unreachable)
            return
        }
        beginPull(id: UUID(), peerID: peerID, session: session)
    }

    /// "Play on <device>": the peer pulls this device's playback through the same flow.
    func playOn(_ peerID: UUID) {
        guard !isTransferring else { return }
        guard let session = linkSession(for: peerID) else {
            transferState = .failed(message: Copy.unreachable)
            return
        }
        guard canSendPlayback else {
            transferState = .failed(message: host.isLiveRadio ? Copy.liveRadio : Copy.nothingHere)
            return
        }
        let id = UUID()
        push = PushTransfer(id: id, peerID: peerID, startedAt: uptime())
        transferState = .preparing(peerID: peerID)
        send(.transferPush(id: id), on: session)
        log.info("event=nearby_transfer phase=push")
        let deadline = Self.transferDeadline + 2
        Task { [weak self] in
            guard let self else { return }
            try? await self.sleep(deadline)
            guard let push = self.push, push.id == id else { return }
            self.push = nil
            if let session = self.linkSession(for: push.peerID) { self.send(.transferCancel(id: id, reason: .timeout), on: session) }
            self.failTransfer(.timeout, startedAt: push.startedAt, note: Copy.stayedHere)
        }
    }

    private func beginPull(id: UUID, peerID: UUID, session: Session) {
        let now = uptime()
        pull = PullTransfer(id: id, peerID: peerID, startedAt: now, requestSentAt: now)
        transferState = .preparing(peerID: peerID)
        send(.transferRequest(id: id), on: session)
        log.info("event=nearby_transfer phase=request")
        Task { [weak self] in
            guard let self else { return }
            try? await self.sleep(Self.transferDeadline)
            guard let pull = self.pull, pull.id == id else { return }
            self.abandonPull(.timeout, notifyPeer: true)
        }
    }

    /// Ends this device's pull; once the offer was applied, the queue it replaced comes back paused.
    private func abandonPull(_ reason: NearbyTransferCancelReason, notifyPeer: Bool) {
        guard let pull else { return }
        self.pull = nil
        if notifyPeer, let session = linkSession(for: pull.peerID) {
            send(.transferCancel(id: pull.id, reason: reason), on: session)
        }
        var note: String?
        if pull.applied {
            if let prior = pull.prior, host.continuePlayback(from: prior.snapshot, at: prior.position, startPlaying: false) {
                note = Copy.restoredHere
            } else {
                note = Copy.loadedHere
            }
            log.info("event=nearby_transfer phase=restore result=\(note == Copy.restoredHere ? "prior" : "none", privacy: .public)")
        }
        failTransfer(reason, startedAt: pull.startedAt, note: note)
    }

    private func failTransfer(_ reason: NearbyTransferCancelReason, startedAt: TimeInterval, note: String? = nil) {
        transferState = .failed(message: [Copy.transfer(reason), note].compactMap { $0 }.joined(separator: " "))
        log.info("event=nearby_transfer phase=cancel reason=\(reason.rawValue, privacy: .public) duration_ms=\(Self.durationBucket(self.uptime() - startedAt), privacy: .public)")
    }

    private func receiveTransferRequest(_ id: UUID, from session: Session, peerID: UUID) {
        var initiatedHere = false
        if let push, push.id == id, push.peerID == peerID {
            initiatedHere = true
            self.push = nil
        } else if isTransferring {
            send(.transferCancel(id: id, reason: .busy), on: session)
            return
        }
        let startedAt = uptime()
        func refuse(_ reason: NearbyTransferCancelReason) {
            send(.transferCancel(id: id, reason: reason), on: session)
            if initiatedHere { failTransfer(reason, startedAt: startedAt, note: Copy.stayedHere) }
            else { log.info("event=nearby_transfer phase=cancel reason=\(reason.rawValue, privacy: .public) duration_ms=lt250") }
        }
        guard !host.isLiveRadio else { refuse(.liveRadio); return }
        guard let snapshot = host.handoffSnapshot else { refuse(.nothingSelected); return }
        let limit = NearbyLinkWire.maximumQueueOccurrences
        guard snapshot.queue.count <= limit, (snapshot.originalQueue?.count ?? 0) <= limit else { refuse(.queueTooLarge); return }
        let offer: NearbyTransferOffer
        do {
            offer = try NearbyTransferOffer(id: id, snapshot: snapshot, wasPlaying: host.isPlaying,
                                            position: PlaybackTiming.position(host.position))
            _ = try NearbyLinkWire.encode(.transferOffer(offer))
        } catch {
            refuse((error as? NearbyLinkError) == .oversizedFrame ? .queueTooLarge : .nothingSelected)
            return
        }
        source = SourceTransfer(id: id, peerID: peerID, startedAt: startedAt, offeredAt: uptime(), initiatedHere: initiatedHere)
        send(.transferOffer(offer), on: session)
        log.info("event=nearby_transfer phase=offer playing=\(offer.wasPlaying ? 1 : 0)")
        Task { [weak self] in
            guard let self else { return }
            try? await self.sleep(Self.sourceReleaseWindow)
            // Without a ready this device simply keeps playing; it never paused for the offer.
            guard let source = self.source, source.id == id else { return }
            self.source = nil
            if source.initiatedHere { self.failTransfer(.timeout, startedAt: source.startedAt, note: Copy.stayedHere) }
        }
    }

    private func receiveTransferOffer(_ offer: NearbyTransferOffer, from peerID: UUID) {
        guard var pull, pull.id == offer.id, pull.peerID == peerID, pull.phase == .requested else { return }
        let measured = uptime() - pull.requestSentAt
        let roundTrip = min(max(peer(peerID)?.roundTrip ?? measured, 0), Self.maximumRoundTrip)
        pull.roundTrip = roundTrip
        pull.offer = offer
        pull.phase = .applying
        pull.applyingSince = uptime()
        // Captured before applying so a failed move can hand this device its own queue back.
        pull.prior = host.handoffSnapshot.map { PriorPlayback(snapshot: $0, position: PlaybackTiming.position(host.position)) }
        self.pull = pull
        log.info("event=nearby_transfer phase=offer_received playing=\(offer.wasPlaying ? 1 : 0)")
        let target = offer.position + (offer.wasPlaying ? roundTrip / 2 : 0)
        guard host.continuePlayback(from: offer.snapshot, at: PlaybackTiming.position(target), startPlaying: false) else {
            abandonPull(.applyFailed, notifyPeer: true)
            return
        }
        self.pull?.applied = true
        checkPullReadiness()
        guard self.pull?.id == offer.id, self.pull?.phase == .applying else { return }
        let id = offer.id
        Task { [weak self] in
            while let self, let pull = self.pull, pull.id == id, pull.phase == .applying {
                if self.uptime() - pull.applyingSince >= Self.readinessDeadline {
                    self.abandonPull(.notReady, notifyPeer: true)
                    return
                }
                self.checkPullReadiness()
                guard self.pull?.phase == .applying else { return }
                do { try await self.sleep(Self.readinessPollInterval) } catch { return }
            }
        }
    }

    private func checkPullReadiness() {
        guard var pull, pull.phase == .applying, pull.applied, let offer = pull.offer, host.isReady(for: offer.currentTrackID),
              let session = linkSession(for: pull.peerID) else { return }
        pull.phase = .awaitingRelease
        self.pull = pull
        send(.transferReady(id: pull.id), on: session)
        log.info("event=nearby_transfer phase=ready duration_ms=\(Self.durationBucket(self.uptime() - pull.startedAt), privacy: .public)")
    }

    private func receiveTransferReady(_ id: UUID, from session: Session, peerID: UUID) {
        guard let source, source.id == id, source.peerID == peerID,
              uptime() - source.offeredAt < Self.sourceReleaseWindow else { return }
        self.source = nil
        let wasPlaying = host.isPlaying
        host.pause()
        let position = PlaybackTiming.position(host.position)
        pruneReleased()
        released.append(ReleasedTransfer(id: id, peerID: peerID, wasPlaying: wasPlaying, releasedAt: uptime(),
                                         initiatedHere: source.initiatedHere))
        send(.transferReleased(id: id, position: position, playing: wasPlaying), on: session)
        if source.initiatedHere { transferState = .idle }
        log.info("event=nearby_transfer phase=released role=source duration_ms=\(Self.durationBucket(self.uptime() - source.startedAt), privacy: .public)")
    }

    private func receiveTransferReleased(_ id: UUID, position: Double, playing: Bool, from peerID: UUID) {
        guard let pull, pull.id == id, pull.peerID == peerID, pull.phase == .awaitingRelease, let offer = pull.offer else { return }
        // Readiness can lapse between ready and release; the sender then takes its playback back on the cancel.
        guard host.isReady(for: offer.currentTrackID) else {
            abandonPull(.notReady, notifyPeer: true)
            return
        }
        self.pull = nil
        if playing {
            host.seek(to: PlaybackTiming.position(position + pull.roundTrip / 2))
            host.resume()
        } else {
            host.seek(to: PlaybackTiming.position(position))
        }
        transferState = .idle
        log.info("event=nearby_transfer phase=released role=target playing=\(playing ? 1 : 0) duration_ms=\(Self.durationBucket(self.uptime() - pull.startedAt), privacy: .public)")
    }

    private func receiveTransferPush(_ id: UUID, from session: Session, peerID: UUID) {
        guard !isTransferring else {
            send(.transferCancel(id: id, reason: .busy), on: session)
            return
        }
        beginPull(id: id, peerID: peerID, session: session)
    }

    private func receiveTransferCancel(_ id: UUID, reason: NearbyTransferCancelReason, from peerID: UUID) {
        if let pull, pull.id == id, pull.peerID == peerID {
            abandonPull(reason, notifyPeer: false)
        }
        if let source, source.id == id, source.peerID == peerID {
            self.source = nil
            if source.initiatedHere { failTransfer(reason, startedAt: source.startedAt, note: Copy.stayedHere) }
        }
        if let push, push.id == id, push.peerID == peerID {
            self.push = nil
            failTransfer(reason, startedAt: push.startedAt, note: Copy.stayedHere)
        }
        pruneReleased()
        if let index = released.firstIndex(where: { $0.id == id && $0.peerID == peerID }) {
            let entry = released.remove(at: index)
            // The receiver gave up after this device let go; without this both devices would stay silent.
            if entry.wasPlaying, !host.isPlaying, host.hasHandoffSelection { host.resume() }
            if entry.initiatedHere { failTransfer(reason, startedAt: entry.releasedAt, note: Copy.stayedHere) }
            log.info("event=nearby_transfer phase=reclaimed playing=\(entry.wasPlaying ? 1 : 0)")
        }
    }

    private func pruneReleased() {
        let now = uptime()
        released.removeAll { now - $0.releasedAt >= Self.releasedMemory }
    }

    private func retireTransfers(with peerID: UUID) {
        if let pull, pull.peerID == peerID {
            abandonPull(.disconnected, notifyPeer: false)
        }
        if let source, source.peerID == peerID {
            self.source = nil
            if source.initiatedHere { failTransfer(.disconnected, startedAt: source.startedAt, note: Copy.stayedHere) }
        }
        if let push, push.peerID == peerID {
            self.push = nil
            failTransfer(.disconnected, startedAt: push.startedAt, note: Copy.stayedHere)
        }
    }

    // MARK: Pairing

    /// Shows a code on this device; the listener accepts only that code until it is used, expires or is cancelled.
    @discardableResult
    func showPairingCode() -> String? {
        guard running else { return nil }
        let code = NearbyPairingCode.generate(at: uptime())
        pairingCode = code
        pairingState = .idle
        startListener()
        log.info("event=nearby_pairing result=shown")
        Task { [weak self] in
            guard let self else { return }
            try? await self.sleep(NearbyPairingCode.lifetime)
            guard self.pairingCode?.code == code.code, self.pairingCode?.issuedAt == code.issuedAt else { return }
            self.endPairingCode(result: "expired")
        }
        return code.display
    }

    func cancelPairingCode() {
        guard pairingCode != nil else { return }
        endPairingCode(result: "cancelled")
    }

    private func endPairingCode(result: String) {
        pairingCode = nil
        log.info("event=nearby_pairing result=\(result, privacy: .public)")
        for session in sessions.values where session.purpose == .pairingShower { close(session) }
        if running { startListener() }
    }

    /// Joins a device showing `code`, adopting its link key so the two connect from then on.
    func joinPairing(code: String) {
        guard running else { return }
        guard let code = NearbyPairingCode.normalized(code) else {
            pairingState = .failed(message: Copy.malformedCode)
            return
        }
        join = nil
        for session in sessions.values where session.isJoiner { close(session) }
        let attempt = JoinAttempt(id: UUID(), code: code, startedAt: uptime())
        join = attempt
        pairingState = .joining
        tryJoinCandidates()
        Task { [weak self] in
            guard let self else { return }
            try? await self.sleep(Self.joinDeadline)
            guard self.join?.id == attempt.id else { return }
            self.finishJoin(failure: "timeout")
        }
    }

    private func tryJoinCandidates() {
        guard var join else { return }
        let psk = NearbyLinkKey.pairingPSK(code: join.code)
        let candidates = services.values.filter { $0.isPairing && !join.tried.contains($0.installationID) }
            .sorted { $0.installationID.uuidString < $1.installationID.uuidString }
        for service in candidates where join.tried.count < Self.maximumJoinCandidates {
            join.tried.insert(service.installationID)
            guard let joiner = try? NearbyPairing.makeJoiner(),
                  let connection = transport.connect(to: service, security: .pairing(psk: psk)) else { continue }
            let session = Session(connection: connection, outbound: true, expectedPeer: service.installationID,
                                  purpose: .pairingJoiner, startedAt: uptime())
            session.joiner = joiner
            session.joinID = join.id
            register(session)
            connection.start()
            schedulePairingClose(session, after: Self.pairingIdleDeadline)
        }
        self.join = join
    }

    private func finishJoin(failure: String?) {
        guard join != nil else { return }
        join = nil
        for session in sessions.values where session.isJoiner { close(session) }
        if let failure {
            pairingState = .failed(message: Copy.pairingFailed)
            log.info("event=nearby_pairing result=\(failure, privacy: .public)")
        } else {
            pairingState = .paired
            log.info("event=nearby_pairing result=joined")
            // The new key must reach the listener and every dial; earlier failures were against the old key.
            for id in Array(dialing.keys) { dialing[id] = DialState() }
            startListener()
            kickMaintenance()
        }
    }

    private func receivePairingRequest(_ request: NearbyPairingRequest, on session: Session) {
        guard var code = pairingCode, code.isUsable(at: uptime()) else { close(session); return }
        do {
            let key = try linkKey()
            let grant = try NearbyPairing.grant(for: request, linkKey: key, code: code.code)
            // Consumed before sending, so a second joiner racing on the same listener is refused.
            code.consume()
            pairingCode = code
            send(.pairingGrant(grant), on: session)
            schedulePairingClose(session, after: Self.pairingGrantLinger)
            log.info("event=nearby_pairing result=granted")
            // The joiner closes once it stores the key; leaving this session open lets the grant flush first.
            pairingCode = nil
            pairingState = .paired
            startListener()
        } catch {
            log.error("event=nearby_pairing result=grant_failed")
            close(session)
        }
    }

    private func receivePairingGrant(_ grant: NearbyPairingGrant, on session: Session) {
        guard let join, session.joinID == join.id, let joiner = session.joiner else { close(session); return }
        do {
            let key = try NearbyPairing.accept(grant, joiner: joiner, code: join.code)
            try keyStore.writeLinkKey(key)
            cachedKey = (key, uptime())
            finishJoin(failure: nil)
        } catch {
            finishJoin(failure: "rejected")
        }
    }

    // MARK: Listener and discovery

    private func startListener() {
        guard running else { return }
        let key: Data
        do { key = try linkKey() } catch {
            log.error("event=nearby_key result=unavailable")
            transport.stopListening()
            listenerKey = nil
            scheduleListenerRetry()
            return
        }
        let pairing = pairingCode.map { $0.isUsable(at: uptime()) } ?? false
        let security: NearbyLinkSecurity = pairing
            ? .pairing(psk: NearbyLinkKey.pairingPSK(code: pairingCode?.code ?? ""))
            : .link(psk: NearbyLinkKey.tlsPSK(linkKey: key))
        listenerKey = key
        listenerIsPairing = pairing
        listenerRetryAt = nil
        transport.startListening(installationID: installationID, pairing: pairing, security: security)
    }

    private func listenerFailed() {
        guard running else { return }
        listenerKey = nil
        scheduleListenerRetry()
    }

    private func scheduleListenerRetry() {
        listenerFailures += 1
        listenerRetryAt = uptime() + Self.backoff(failures: listenerFailures)
        kickMaintenance()
    }

    private func servicesChanged(_ discovered: [NearbyDiscoveredService]) {
        guard running else { return }
        let previous = Set(services.keys)
        services = Dictionary(discovered.filter { $0.installationID != installationID }.map { ($0.installationID, $0) },
                              uniquingKeysWith: { $1 })
        let current = Set(services.keys)
        let found = current.subtracting(previous).count
        let lost = previous.subtracting(current).count
        if found > 0 { log.info("event=nearby_peer_found count=\(found)") }
        if lost > 0 { log.info("event=nearby_peer_lost count=\(lost)") }
        for id in previous.subtracting(current) {
            dialing.removeValue(forKey: id)
            if linkSession(for: id) == nil { peers.removeAll { $0.id == id } }
        }
        if join != nil { tryJoinCandidates() }
        maintain()
    }

    private func accept(_ connection: any NearbyLinkConnection) {
        guard running else { connection.cancel(); return }
        listenerFailures = 0
        let session = Session(connection: connection, outbound: false, expectedPeer: nil,
                              purpose: listenerIsPairing ? .pairingShower : .link, startedAt: uptime())
        register(session)
        connection.start()
        if session.purpose == .pairingShower { schedulePairingClose(session, after: Self.pairingIdleDeadline) }
    }

    private func dial(_ service: NearbyDiscoveredService) {
        // Cached for at most 30 s and dropped on a TLS failure, so an iCloud Keychain update reaches the next dial.
        guard let key = try? linkKey() else { return }
        guard let connection = transport.connect(to: service, security: .link(psk: NearbyLinkKey.tlsPSK(linkKey: key))) else {
            return
        }
        dialing[service.installationID, default: DialState()].inFlight = true
        let session = Session(connection: connection, outbound: true, expectedPeer: service.installationID,
                              purpose: .link, startedAt: uptime())
        register(session)
        connection.start()
    }

    private func register(_ session: Session) {
        sessions[ObjectIdentifier(session.connection)] = session
        session.connection.onEvent = { [weak self, weak session] event in
            guard let self, let session else { return }
            self.receive(event, on: session)
        }
    }

    // MARK: Maintenance

    private func kickMaintenance() {
        guard running else { return }
        maintain()
    }

    private func linkKey() throws -> Data {
        if let cachedKey, uptime() - cachedKey.readAt < Self.keyCacheLifetime { return cachedKey.key }
        let key = try NearbyLinkKey.current(in: keyStore)
        cachedKey = (key, uptime())
        return key
    }

    /// Pairing sessions carry one request and one grant; none outlives its deadline even if the peer stays silent.
    private func schedulePairingClose(_ session: Session, after seconds: TimeInterval) {
        let key = ObjectIdentifier(session.connection)
        Task { [weak self, weak session] in
            guard let self else { return }
            try? await self.sleep(seconds)
            guard let session, self.sessions[key] === session else { return }
            self.close(session)
        }
    }

    /// Dials due peers, pings, restarts a failed or stale listener, then sleeps until the next due moment.
    private func maintain() {
        guard running else { return }
        let now = uptime()
        if let retry = listenerRetryAt, now >= retry { startListener() }
        else if listenerRetryAt == nil, !listenerIsPairing, let key = try? linkKey(), key != listenerKey {
            startListener()
        }
        var nextDue = now + Self.pingInterval
        if let retry = listenerRetryAt { nextDue = min(nextDue, retry) }
        for service in services.values where shouldDial(service) {
            let state = dialing[service.installationID, default: DialState()]
            if state.nextAttemptAt <= now { dial(service) }
            else { nextDue = min(nextDue, state.nextAttemptAt) }
        }
        for session in sessions.values where session.isReady && session.peerID != nil && session.purpose == .link {
            let due = (session.lastPingAt ?? -.infinity) + Self.pingInterval
            if now >= due {
                session.lastPingAt = now
                send(.ping(id: UUID(), sentUptime: now), on: session)
            } else {
                nextDue = min(nextDue, due)
            }
        }
        let token = UUID()
        maintenanceToken = token
        maintenanceTask?.cancel()
        let delay = max(0.05, nextDue - now)
        maintenanceTask = Task { [weak self] in
            guard let self else { return }
            do { try await self.sleep(delay) } catch { return }
            guard self.maintenanceToken == token else { return }
            self.maintain()
        }
    }

    /// The installation with the smaller identifier dials, so two devices never race to open duplicate sessions.
    private func shouldDial(_ service: NearbyDiscoveredService) -> Bool {
        guard !service.isPairing, installationID.uuidString < service.installationID.uuidString else { return false }
        guard dialing[service.installationID]?.inFlight != true else { return false }
        return !sessions.values.contains { $0.expectedPeer == service.installationID || $0.peerID == service.installationID }
    }

    static func backoff(failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        return min(maximumBackoff, pow(2, Double(min(failures, 6) - 1)))
    }

    // MARK: Session events

    private func receive(_ event: NearbyConnectionEvent, on session: Session) {
        guard running, sessions[ObjectIdentifier(session.connection)] === session else { return }
        switch event {
        case .ready:
            session.isReady = true
            if session.outbound || session.purpose == .pairingShower {
                log.info("event=nearby_connect result=ok")
            }
            switch session.purpose {
            case .link:
                send(.hello(NearbyPeerHello(installationID: installationID, displayName: displayName, deviceKind: deviceKind)),
                     on: session)
            case .pairingJoiner:
                if let request = session.joiner?.request { send(.pairingRequest(request), on: session) }
            case .pairingShower:
                break
            }
        case .received(let payload):
            let message: NearbyLinkMessage
            do { message = try NearbyLinkWire.decode(payload) } catch {
                let reason = (error as? NearbyLinkError) == .unsupportedVersion ? "unsupported_version" : "malformed"
                log.notice("event=nearby_message result=rejected reason=\(reason, privacy: .public)")
                close(session)
                return
            }
            handle(message, on: session)
        case .failed(let failure):
            if !session.isReady {
                let result = switch failure {
                case .tls: "tls_failed"
                case .timeout: "timeout"
                case .network, .protocolError: "network"
                }
                log.info("event=nearby_connect result=\(result, privacy: .public)")
                if failure == .tls, session.purpose == .link { cachedKey = nil }
                // A bare TCP connect proves nothing about the code; only a failed handshake counts as a guess.
                if session.purpose == .pairingShower, failure == .tls, var code = pairingCode {
                    code.recordFailedAttempt()
                    pairingCode = code
                    if !code.isUsable(at: uptime()) { endPairingCode(result: "locked") }
                }
            }
            close(session)
        }
    }

    private func handle(_ message: NearbyLinkMessage, on session: Session) {
        switch session.purpose {
        case .pairingShower:
            guard case .pairingRequest(let request) = message else { close(session); return }
            receivePairingRequest(request, on: session)
            return
        case .pairingJoiner:
            guard case .pairingGrant(let grant) = message else { close(session); return }
            receivePairingGrant(grant, on: session)
            return
        case .link:
            break
        }
        guard let peerID = session.peerID else {
            guard case .hello(let hello) = message else { close(session); return }
            receiveHello(hello, on: session)
            return
        }
        switch message {
        case .hello, .pairingRequest, .pairingGrant:
            close(session)
        case .snapshot(let nowPlaying):
            receiveSnapshot(nowPlaying, from: peerID)
        case .request(let request):
            receiveRequest(request, on: session)
        case .response(let response):
            guard let entry = pending[response.id], entry.session == ObjectIdentifier(session.connection) else { return }
            if let lease = response.executionLease {
                controls[peerID, default: PeerControl()].lease = lease
                controls[peerID, default: PeerControl()].leaseReceivedAt = uptime()
            }
            receiveSnapshot(NearbyNowPlaying(snapshot: response.snapshot, artworkURL: artwork(for: response.snapshot, peerID: peerID)),
                            from: peerID)
            finishPending(response.id, with: response)
        case .ping(let id, let sent):
            send(.pong(id: id, sentUptime: sent), on: session)
        case .pong(_, let sent):
            let roundTrip = uptime() - sent
            if roundTrip >= 0, roundTrip < 10, let index = peers.firstIndex(where: { $0.id == peerID }) {
                peers[index].roundTrip = roundTrip
            }
        case .transferRequest(let id):
            receiveTransferRequest(id, from: session, peerID: peerID)
        case .transferOffer(let offer):
            receiveTransferOffer(offer, from: peerID)
        case .transferReady(let id):
            receiveTransferReady(id, from: session, peerID: peerID)
        case .transferReleased(let id, let position, let playing):
            receiveTransferReleased(id, position: position, playing: playing, from: peerID)
        case .transferPush(let id):
            receiveTransferPush(id, from: session, peerID: peerID)
        case .transferCancel(let id, let reason):
            receiveTransferCancel(id, reason: reason, from: peerID)
        }
    }

    private func receiveHello(_ hello: NearbyPeerHello, on session: Session) {
        let peerID = hello.installationID
        guard peerID != installationID, session.expectedPeer.map({ $0 == peerID }) ?? true else { close(session); return }
        if let existing = linkSession(for: peerID), existing !== session {
            // Keep the session the smaller installation dialed; both ends apply the same rule.
            let keepNew = (installationID.uuidString < peerID.uuidString) == session.outbound
            guard keepNew else { close(session); return }
            existing.peerID = nil
            close(existing, retiring: false)
        }
        session.peerID = peerID
        dialing[peerID] = DialState()
        let peer = NearbyPeer(id: peerID, displayName: hello.displayName, kind: hello.deviceKind, state: .connected)
        if let index = peers.firstIndex(where: { $0.id == peerID }) {
            peers[index].displayName = peer.displayName
            peers[index].kind = peer.kind
            peers[index].state = .connected
        } else {
            peers.append(peer)
        }
        session.lastPingAt = uptime()
        send(.ping(id: UUID(), sentUptime: uptime()), on: session)
        publish(to: session, current: currentNowPlaying(), now: uptime())
        kickMaintenance()
    }

    private func receiveSnapshot(_ nowPlaying: NearbyNowPlaying, from peerID: UUID) {
        guard let index = peers.firstIndex(where: { $0.id == peerID }) else { return }
        if let lease = controls[peerID]?.lease, lease.sessionID != nowPlaying.snapshot.sessionID {
            controls[peerID]?.lease = nil
            controls[peerID]?.leaseReceivedAt = nil
        }
        // Responses and publications can cross; an older sequence from the same session never replaces a newer one.
        if let current = peers[index].nowPlaying?.snapshot, current.sessionID == nowPlaying.snapshot.sessionID,
           current.sequence > nowPlaying.snapshot.sequence { return }
        peers[index].nowPlaying = nowPlaying
        peers[index].receivedAt = uptime()
    }

    private func artwork(for snapshot: CompanionSnapshot, peerID: UUID) -> URL? {
        guard let current = peer(peerID)?.nowPlaying, current.snapshot.nowPlaying?.trackID == snapshot.nowPlaying?.trackID else {
            return nil
        }
        return current.artworkURL
    }

    private func receiveRequest(_ request: CompanionRequest, on session: Session) {
        let response: CompanionResponse
        if !Self.isReadOnly(request.action), request.executionLease == nil {
            response = CompanionResponse(id: request.id, accepted: false, snapshot: host.companionSnapshot, error: Copy.needsRefresh)
        } else {
            response = host.handle(request)
        }
        guard response.id == request.id else { return }
        send(.response(response), on: session)
        log.info("event=nearby_request action=\(Self.actionName(request.action), privacy: .public) accepted=\(response.accepted ? 1 : 0)")
        publishAll()
    }

    private func close(_ session: Session, retiring: Bool = true) {
        let key = ObjectIdentifier(session.connection)
        guard sessions[key] === session else { return }
        sessions.removeValue(forKey: key)
        session.connection.cancel()
        for (id, entry) in pending where entry.session == key { finishPending(id, with: nil) }
        if session.outbound, session.purpose == .link, let expected = session.expectedPeer {
            var state = dialing[expected, default: DialState()]
            state.inFlight = false
            if session.peerID == nil {
                state.failures += 1
                state.nextAttemptAt = uptime() + Self.backoff(failures: state.failures)
            } else {
                state.failures = 1
                state.nextAttemptAt = uptime() + Self.backoff(failures: 1)
            }
            dialing[expected] = state
        }
        if session.isJoiner, let join, session.joinID == join.id, running {
            let others = sessions.values.contains { $0.isJoiner && $0.joinID == join.id }
            let untried = services.values.contains { $0.isPairing && !join.tried.contains($0.installationID) }
            if !others && (!untried || join.tried.count >= Self.maximumJoinCandidates) {
                finishJoin(failure: session.isReady ? "closed" : "tls_failed")
            }
        }
        if retiring, let peerID = session.peerID, linkSession(for: peerID) == nil {
            controls.removeValue(forKey: peerID)
            retireTransfers(with: peerID)
            if services[peerID] != nil, let index = peers.firstIndex(where: { $0.id == peerID }) {
                peers[index].state = .reconnecting
                peers[index].controlError = nil
            } else {
                peers.removeAll { $0.id == peerID }
            }
        }
        if running { kickMaintenance() }
    }

    private func linkSession(for peerID: UUID) -> Session? {
        sessions.values.first { $0.purpose == .link && $0.isReady && $0.peerID == peerID }
    }

    private func send(_ message: NearbyLinkMessage, on session: Session) {
        do { session.connection.send(try NearbyLinkWire.encode(message)) } catch {
            log.error("event=nearby_message result=encode_failed kind=\(message.kind, privacy: .public)")
        }
    }

    // MARK: Publication

    private func hostChanged() {
        guard running else { return }
        publishAll()
        checkPullReadiness()
    }

    private func currentNowPlaying() -> NearbyNowPlaying {
        NearbyNowPlaying(snapshot: host.companionSnapshot, artworkURL: host.artworkURL)
    }

    /// Semantic changes go out at once; position-only changes at most every five seconds per peer.
    private func publishAll() {
        guard running else { return }
        let current = currentNowPlaying()
        let now = uptime()
        var nextDue: TimeInterval?
        for session in sessions.values where session.purpose == .link && session.isReady && session.peerID != nil {
            if let due = publish(to: session, current: current, now: now) { nextDue = min(nextDue ?? due, due) }
        }
        if let nextDue { schedulePublication(at: nextDue) }
    }

    @discardableResult
    private func publish(to session: Session, current: NearbyNowPlaying, now: TimeInterval) -> TimeInterval? {
        guard current != session.lastSent else { return nil }
        let semantic = session.lastSent.map { !current.hasSameSemantics(as: $0) } ?? true
        if !semantic, let sentAt = session.lastSentAt, now < sentAt + Self.positionPublicationInterval {
            return sentAt + Self.positionPublicationInterval
        }
        session.lastSent = current
        session.lastSentAt = now
        send(.snapshot(current), on: session)
        return nil
    }

    private func schedulePublication(at due: TimeInterval) {
        if let publicationDue, publicationDue <= due, publicationToken != nil { return }
        let token = UUID()
        publicationToken = token
        publicationDue = due
        let delay = max(0, due - uptime())
        Task { [weak self] in
            guard let self else { return }
            do { try await self.sleep(delay) } catch { return }
            guard self.publicationToken == token else { return }
            self.publicationToken = nil
            self.publicationDue = nil
            self.publishAll()
        }
    }

    // MARK: Helpers

    static func isReadOnly(_ action: CompanionAction) -> Bool {
        switch action {
        case .snapshot, .browse: true
        default: false
        }
    }

    static func actionName(_ action: CompanionAction) -> String {
        switch action {
        case .snapshot: "snapshot"
        case .browse: "browse"
        case .play: "play"
        case .pause: "pause"
        case .next: "next"
        case .previous: "previous"
        case .seek: "seek"
        case .setFavorite: "set_favorite"
        case .setSuperLiked: "set_super_liked"
        case .setShuffle: "set_shuffle"
        case .setRepeatMode: "set_repeat_mode"
        case .playItem: "play_item"
        }
    }

    static func durationBucket(_ seconds: TimeInterval) -> String {
        let milliseconds = max(0, seconds) * 1_000
        for limit in [250.0, 500, 1_000, 2_000, 5_000, 12_000] where milliseconds < limit { return "lt\(Int(limit))" }
        return "ge12000"
    }

    // MARK: Types

    private enum Purpose: Equatable { case link, pairingShower, pairingJoiner }

    @MainActor
    private final class Session {
        let connection: any NearbyLinkConnection
        let outbound: Bool
        let expectedPeer: UUID?
        let purpose: Purpose
        let startedAt: TimeInterval
        var isReady = false
        var peerID: UUID?
        var lastSent: NearbyNowPlaying?
        var lastSentAt: TimeInterval?
        var lastPingAt: TimeInterval?
        var joiner: NearbyPairing.Joiner?
        var joinID: UUID?

        var isJoiner: Bool { purpose == .pairingJoiner }

        init(connection: any NearbyLinkConnection, outbound: Bool, expectedPeer: UUID?, purpose: Purpose, startedAt: TimeInterval) {
            self.connection = connection
            self.outbound = outbound
            self.expectedPeer = expectedPeer
            self.purpose = purpose
            self.startedAt = startedAt
        }
    }

    private struct DialState {
        var failures = 0
        var nextAttemptAt: TimeInterval = 0
        var inFlight = false
    }

    private struct PeerControl {
        var lease: CompanionExecutionLease?
        var leaseReceivedAt: TimeInterval?
        var mutationInFlight = false
    }

    private struct PendingResponse {
        let session: ObjectIdentifier
        let continuation: CheckedContinuation<CompanionResponse?, Never>
    }

    private struct PullTransfer {
        enum Phase { case requested, applying, awaitingRelease }
        let id: UUID
        let peerID: UUID
        let startedAt: TimeInterval
        let requestSentAt: TimeInterval
        var phase: Phase = .requested
        var offer: NearbyTransferOffer?
        var roundTrip: TimeInterval = 0
        var applyingSince: TimeInterval = 0
        var applied = false
        var prior: PriorPlayback?
    }

    private struct PriorPlayback {
        let snapshot: PlaybackSnapshot
        let position: TimeInterval
    }

    private struct SourceTransfer {
        let id: UUID
        let peerID: UUID
        let startedAt: TimeInterval
        let offeredAt: TimeInterval
        let initiatedHere: Bool
    }

    private struct ReleasedTransfer {
        let id: UUID
        let peerID: UUID
        let wasPlaying: Bool
        let releasedAt: TimeInterval
        let initiatedHere: Bool
    }

    private struct PushTransfer {
        let id: UUID
        let peerID: UUID
        let startedAt: TimeInterval
    }

    private struct JoinAttempt {
        let id: UUID
        let code: String
        let startedAt: TimeInterval
        var tried: Set<UUID> = []
    }

    private enum Copy {
        static let unreachable = "The other device is no longer connected. Check that both devices are on the same Wi-Fi network."
        static let busy = "The last control is still being sent. Try again."
        static let rejected = "The other device couldn't complete that. Try again."
        static let staleTrack = "The song changed on the other device. Check it and try again."
        static let needsRefresh = "Refresh before trying this action."
        static let liveRadio = "Live Radio stays on the device that is playing it."
        static let nothingHere = "Choose a song on this device first."
        static let malformedCode = "Enter the 16-character code shown on the other device."
        static let pairingFailed = "That code didn't work. Check the code on the other device and try again."
        static let stayedHere = "Playback stayed on this device."
        static let restoredHere = "What was playing on this device is back, paused."
        static let loadedHere = "The other device's queue is loaded on this device, paused."

        static func noResponse(_ name: String) -> String {
            "\(name) didn't respond. Check it before trying again."
        }

        static func transfer(_ reason: NearbyTransferCancelReason) -> String {
            switch reason {
            case .liveRadio: "Live Radio stays on the device that is playing it."
            case .nothingSelected: "Nothing is selected on the other device."
            case .busy: "The other device is already moving playback. Try again."
            case .timeout: "The other device didn't respond in time."
            case .notReady: "The song couldn't be prepared in time."
            case .applyFailed: "Playback couldn't be moved to this device."
            case .queueTooLarge:
                "The queue has more than \(NearbyLinkWire.maximumQueueOccurrences.formatted()) songs, which is too many to move. Remove some songs and try again."
            case .disconnected: "The other device disconnected."
            case .cancelled: "Moving playback was cancelled."
            }
        }
    }
}

enum NearbyDeviceIdentity {
    /// Without the user-assigned-name entitlement iOS reports only the model, which is still a usable label.
    @MainActor static var current: (name: String, kind: NearbyDeviceKind) {
        #if targetEnvironment(macCatalyst)
        // Catalyst reports an iPad model name here; the Mac's own name needs AppKit.
        return ("Mac", .mac)
        #else
        if ProcessInfo.processInfo.isiOSAppOnMac { return (UIDevice.current.name, .mac) }
        let kind: NearbyDeviceKind = UIDevice.current.userInterfaceIdiom == .pad ? .iPad : .iPhone
        return (UIDevice.current.name, kind)
        #endif
    }
}

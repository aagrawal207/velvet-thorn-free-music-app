import Foundation
import Observation
import OSLog
import Synchronization

/// The system surface the publisher drives; tests substitute a recorder for NSUserActivity.
@MainActor
protocol PlaybackHandoffActivitySink: AnyObject {
    /// Called on semantic changes only; `duration` is the resolved length used to bound save-time refreshes.
    func update(_ payload: PlaybackHandoff, data: Data, title: String, duration: TimeInterval?)
    func becomeCurrent()
    func invalidate()
    var onContinuedElsewhere: (@MainActor () -> Void)? { get set }
}

/// Advertises the current music selection to the listener's other devices through Handoff.
@MainActor
final class PlaybackHandoffPublisher {
    /// Everything that warrants a new publication; position is deliberately absent so ticks never publish.
    struct SemanticState: Equatable {
        var entryID: UUID?
        var trackID: String?
        var queueSignature: Int
        var queueCount: Int
        var playing: Bool
        var shuffleEnabled: Bool
        var repeatMode: RepeatMode
        var isLiveRadio: Bool
        var controlRevision: UInt64
    }

    private let player: PlayerController
    private let savedSnapshot: @MainActor () -> PlaybackSnapshot?
    private let sink: any PlaybackHandoffActivitySink
    private let senderID: UUID
    private let now: @MainActor () -> Date
    private let hostAllowsHandoff: Bool
    private var isRunning = false
    private var isSceneActive = false
    private var isAdvertising = false
    /// Cleared while the scene is inactive, since another app may have taken over the current activity meanwhile.
    private var isCurrent = false
    private var observationGeneration: UInt64 = 0
    private var lastState: SemanticState?
    private(set) var publicationCount = 0
    private let log = Logger(subsystem: "com.agraabhi.ganabajana", category: "handoff")

    init(player: PlayerController, savedSnapshot: @escaping @MainActor () -> PlaybackSnapshot? = { nil },
         sink: (any PlaybackHandoffActivitySink)? = nil, senderID: UUID = PlaybackHandoffCodec.localSenderID,
         now: @escaping @MainActor () -> Date = { Date() }, hostAllowsHandoff: Bool = PlaybackHandoffPublisher.hostAllowsHandoff) {
        self.player = player
        self.savedSnapshot = savedSnapshot
        self.sink = sink ?? SystemPlaybackHandoffActivity()
        self.senderID = senderID
        self.now = now
        self.hostAllowsHandoff = hostAllowsHandoff
        self.sink.onContinuedElsewhere = { [weak self] in self?.continuedElsewhere() }
    }

    convenience init(model: MusicAppModel, sink: (any PlaybackHandoffActivitySink)? = nil) {
        self.init(player: model.player, savedSnapshot: { [weak model] in model?.library.playback }, sink: sink,
                  senderID: MusicAppModel.handoffSenderID)
    }

    /// Unit and fixture hosts must never advertise fixture queues to the developer's real devices.
    nonisolated static var hostAllowsHandoff: Bool {
        let process = ProcessInfo.processInfo
        return process.environment["XCTestConfigurationFilePath"] == nil && !process.arguments.contains("--uitesting")
    }

    func start() {
        guard !isRunning else { return }
        guard hostAllowsHandoff else {
            sink.invalidate()
            log.info("event=handoff_publisher outcome=disabled reason=test_host")
            return
        }
        isRunning = true
        lastState = nil
        observe()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        observationGeneration &+= 1
        lastState = nil
        withdraw(reason: "stopped")
    }

    func setSceneActive(_ active: Bool) {
        guard isSceneActive != active else { return }
        isSceneActive = active
        if !active { isCurrent = false }
        makeCurrentIfNeeded()
    }

    private func makeCurrentIfNeeded() {
        guard isRunning, isSceneActive, isAdvertising, !isCurrent else { return }
        isCurrent = true
        sink.becomeCurrent()
    }

    // MARK: Observation

    private func observe() {
        guard isRunning else { return }
        observationGeneration &+= 1
        let generation = observationGeneration
        let state = withObservationTracking {
            readState()
        } onChange: { [weak self] in
            // Observation fires before the write; one main-actor hop reads the completed mutation and re-arms tracking.
            Task { @MainActor [weak self] in
                guard let self, self.observationGeneration == generation else { return }
                self.observe()
            }
        }
        apply(state)
    }

    private func readState() -> SemanticState {
        let entries = player.queueEntries
        let index = player.currentIndex
        // Reading position subscribes to seeks; the control revision tells a seek from a playback tick.
        _ = player.position
        var hasher = Hasher()
        for entry in entries { hasher.combine(entry.id) }
        return SemanticState(
            entryID: entries.indices.contains(index) ? entries[index].id : nil,
            trackID: player.currentTrack?.id,
            queueSignature: hasher.finalize(),
            queueCount: entries.count,
            playing: player.isPlaying || player.isLoading,
            shuffleEnabled: player.shuffleEnabled,
            repeatMode: player.repeatMode,
            isLiveRadio: player.isLiveRadio,
            controlRevision: player.controlRevision)
    }

    private func apply(_ state: SemanticState) {
        guard state != lastState else { return }
        lastState = state
        if state.isLiveRadio { withdraw(reason: "live_radio"); return }
        guard state.trackID != nil, let track = player.currentTrack else { withdraw(reason: "no_track"); return }
        let handoff = PlaybackHandoff(senderID: senderID, sentAt: now(), wasPlaying: state.playing, snapshot: currentSnapshot())
        let encoded: (payload: PlaybackHandoff, data: Data)
        do { encoded = try PlaybackHandoffCodec.encodeBounded(handoff) } catch {
            let reason = (error as? PlaybackHandoffCodec.Failure)?.rawValue ?? "encoding"
            withdraw(reason: reason)
            return
        }
        sink.update(encoded.payload, data: encoded.data, title: "Listening to \(track.title)",
                    duration: PlaybackTiming.validDuration(player.duration))
        publicationCount += 1
        isAdvertising = true
        makeCurrentIfNeeded()
        log.debug("event=handoff_published playing=\(state.playing ? 1 : 0) queue_count=\(PlaybackHandoffCodec.countBucket(encoded.payload.snapshot.queue.count), privacy: .public) bytes=\(PlaybackHandoffCodec.bytesBucket(encoded.data.count), privacy: .public)")
    }

    /// The live player owns play order and position; the saved snapshot supplies the original order only when it agrees.
    private func currentSnapshot() -> PlaybackSnapshot {
        var snapshot = PlaybackSnapshot(queue: player.queue, currentIndex: player.currentIndex,
                                        position: PlaybackTiming.position(player.position),
                                        shuffleEnabled: player.shuffleEnabled, repeatMode: player.repeatMode)
        if snapshot.shuffleEnabled, let saved = savedSnapshot(), saved.shuffleEnabled,
           saved.currentIndex == snapshot.currentIndex, saved.queue.map(\.id) == snapshot.queue.map(\.id) {
            snapshot.originalQueue = saved.originalQueue
            snapshot.originalQueueIndices = saved.originalQueueIndices
        }
        return snapshot
    }

    private func withdraw(reason: String) {
        guard isAdvertising else { return }
        isAdvertising = false
        isCurrent = false
        sink.invalidate()
        log.debug("event=handoff_withdrawn reason=\(reason, privacy: .public)")
    }

    private func continuedElsewhere() {
        guard isRunning, isAdvertising else { return }
        log.info("event=handoff_continued_elsewhere playing=\(self.player.isPlaying ? 1 : 0)")
        if !player.isLiveRadio { player.pause() }
    }
}

// MARK: - System activity

/// Owns the single NSUserActivity; an invalidated activity cannot become current again, so withdrawal drops it.
@MainActor
final class SystemPlaybackHandoffActivity: PlaybackHandoffActivitySink {
    var onContinuedElsewhere: (@MainActor () -> Void)?
    private var activity: NSUserActivity?
    private lazy var delegate = PlaybackHandoffActivityDelegate { [weak self] in
        Task { @MainActor [weak self] in self?.onContinuedElsewhere?() }
    }

    func update(_ payload: PlaybackHandoff, data: Data, title: String, duration: TimeInterval?) {
        delegate.store(payload, duration: duration)
        let activity = self.activity ?? makeActivity()
        activity.title = title
        activity.addUserInfoEntries(from: [PlaybackHandoffCodec.payloadKey: data])
        // The save-time callback re-encodes the position, so a long-playing song is not offered stale.
        activity.needsSave = true
    }

    func becomeCurrent() { activity?.becomeCurrent() }

    func invalidate() {
        delegate.clear()
        activity?.invalidate()
        activity = nil
    }

    private func makeActivity() -> NSUserActivity {
        let activity = NSUserActivity(activityType: PlaybackHandoffCodec.activityType)
        activity.isEligibleForHandoff = true
        activity.isEligibleForSearch = false
        activity.isEligibleForPublicIndexing = false
        #if !targetEnvironment(macCatalyst)
        activity.isEligibleForPrediction = false
        #endif
        activity.requiredUserInfoKeys = [PlaybackHandoffCodec.payloadKey]
        activity.delegate = delegate
        self.activity = activity
        return activity
    }
}

/// Foundation may call these from any thread, so the state they need is held behind a lock rather than the main actor.
final class PlaybackHandoffActivityDelegate: NSObject, NSUserActivityDelegate, Sendable {
    private struct Basis: Sendable {
        var payload: PlaybackHandoff
        var duration: TimeInterval?
    }

    private let basis = Mutex<Basis?>(nil)
    private let continued: @Sendable () -> Void

    init(continued: @escaping @Sendable () -> Void) {
        self.continued = continued
    }

    func store(_ payload: PlaybackHandoff, duration: TimeInterval?) {
        basis.withLock { $0 = Basis(payload: payload, duration: duration) }
    }

    func clear() {
        basis.withLock { $0 = nil }
    }

    /// The payload as of `date`: a playing sender's position advances with the time since it was captured.
    func refreshedPayload(at date: Date) -> PlaybackHandoff? {
        guard let current = basis.withLock({ $0 }) else { return nil }
        var payload = current.payload
        if payload.wasPlaying {
            let elapsed = date.timeIntervalSince(payload.sentAt)
            var position = payload.snapshot.position + (elapsed.isFinite ? max(0, elapsed) : 0)
            // Unlike the receiver's 30-second transfer allowance, this is real elapsed playback, bounded by the song.
            if let duration = current.duration { position = min(position, max(0, duration - 1)) }
            payload.snapshot.position = PlaybackTiming.position(position)
        }
        payload.sentAt = date
        return payload
    }

    func userActivityWillSave(_ userActivity: NSUserActivity) {
        guard let payload = refreshedPayload(at: Date()),
              let data = try? PlaybackHandoffCodec.encodeBounded(payload).data else { return }
        userActivity.addUserInfoEntries(from: [PlaybackHandoffCodec.payloadKey: data])
    }

    func userActivityWasContinued(_ userActivity: NSUserActivity) {
        continued()
    }
}

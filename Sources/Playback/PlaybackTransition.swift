import AVFoundation
import Foundation
import OSLog

enum PlaybackNormalization {
    /// Source loudness is an offset from the provider's reference, not measured output LUFS.
    static func gainDb(loudnessDb: Double?, enabled: Bool) -> Double {
        guard enabled, let loudnessDb, loudnessDb.isFinite, abs(loudnessDb) <= 60 else { return 0 }
        return min(GainLimiter.maximumGainDb, -loudnessDb)
    }

    /// Requested total gain. The caller must split it between attenuation and the gain-up tap.
    static func gain(loudnessDb: Double?, enabled: Bool) -> Double {
        pow(10, gainDb(loudnessDb: loudnessDb, enabled: enabled) / 20)
    }

    static func attenuationGain(loudnessDb: Double?, enabled: Bool) -> Double {
        min(1, gain(loudnessDb: loudnessDb, enabled: enabled))
    }
}

enum PlaybackStreamLoading {
    static func makeItem(url: URL, duration: TimeInterval) -> AVPlayerItem {
        configure(AVPlayerItem(url: url), isFile: url.isFileURL, duration: duration)
    }

    /// A preloaded asset for this exact signed URL skips AVFoundation's opening metadata round trips; everything
    /// else is the ordinary URL item. `usesPreload` feeds the `playback_start` metric.
    @MainActor
    static func makeItem(stream: ResolvedStream, trackID: String?, duration: TimeInterval,
                         preloads: PlaybackPreloadStore = .shared) -> (item: AVPlayerItem, usesPreload: Bool) {
        let url = stream.url
        guard !url.isFileURL, let trackID, let asset = preloads.asset(trackID: trackID, url: url) else {
            return (makeItem(url: url, duration: duration), false)
        }
        return (configure(AVPlayerItem(asset: asset), isFile: false, duration: duration), true)
    }

    private static func configure(_ item: AVPlayerItem, isFile: Bool, duration: TimeInterval) -> AVPlayerItem {
        // Local files start instantly whatever the buffer; remote items keep a deeper buffer against network hiccups.
        item.preferredForwardBufferDuration = isFile ? 0 : 15
        if duration > 0 { item.forwardPlaybackEndTime = CMTime(seconds: duration, preferredTimescale: 44_100) }
        return item
    }

    static func loadMissingLocalDuration(in stream: ResolvedStream) async throws -> ResolvedStream {
        guard stream.url.isFileURL,
              PlaybackTiming.validDuration(PlaybackTiming.queryNumber("dur", in: stream.url)) == nil,
              PlaybackTiming.validDuration(stream.duration) == nil else { return stream }
        // Native duration is authoritative for local files; remote YouTube M4A duration can be doubled by AVFoundation.
        let seconds = try await PlaybackDeadline.run(seconds: 10) {
            let asset = AVURLAsset(url: stream.url)
            let duration = try await asset.load(.duration)
            guard let seconds = PlaybackTiming.validDuration(duration.seconds) else {
                throw MusicServiceError.unavailable("The local audio file’s duration could not be read.")
            }
            return seconds
        }
        var resolved = stream
        resolved.duration = seconds
        return resolved
    }
}

struct PlaybackCrossfadeState: Equatable, Sendable {
    var duration: TimeInterval
    var progress: Double
    var outgoingVolume: Float
    var incomingVolume: Float
}

/// Equal-power ramp scaled by each player's attenuation only; positive normalization lives in the item's tap.
@MainActor
final class PlaybackCrossfade {
    let outgoing: AVPlayer
    let incoming: AVPlayer
    let duration: TimeInterval
    let outgoingGain: Float
    let incomingGain: Float
    private(set) var progress: Double = 0
    private var task: Task<Void, Never>?

    init(outgoing: AVPlayer, incoming: AVPlayer, duration: TimeInterval, outgoingGain: Float, incomingGain: Float) {
        self.outgoing = outgoing
        self.incoming = incoming
        self.duration = max(0.05, duration)
        self.outgoingGain = outgoingGain.isFinite ? min(1, max(0, outgoingGain)) : 1
        self.incomingGain = incomingGain.isFinite ? min(1, max(0, incomingGain)) : 1
    }

    var state: PlaybackCrossfadeState {
        PlaybackCrossfadeState(duration: duration, progress: progress, outgoingVolume: outgoing.volume, incomingVolume: incoming.volume)
    }

    func start(onCompletion: @escaping @MainActor () -> Void) {
        apply(progress: 0)
        let started = ContinuousClock.now
        let duration = self.duration
        task = Task { @MainActor [weak self] in
            while true {
                do { try await Task.sleep(for: .milliseconds(40)) } catch { return }
                guard let self else { return }
                let elapsed = started.duration(to: .now)
                let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                let progress = min(1, seconds / duration)
                self.apply(progress: progress)
                if progress >= 1 {
                    self.task = nil
                    onCompletion()
                    return
                }
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    private func apply(progress: Double) {
        self.progress = progress
        let angle = progress * .pi / 2
        outgoing.volume = outgoingGain * Float(cos(angle))
        incoming.volume = incomingGain * Float(sin(angle))
    }
}

/// The paused second player that holds the real next queue entry so transitions never wait on extraction.
/// It never plays on its own, never touches the audio session, and reports nothing about listening.
@MainActor
final class StandbyDeck {
    typealias Preroll = @MainActor (AVPlayer, @escaping @MainActor @Sendable (Bool) -> Void) -> Void

    struct Prepared {
        let player: AVPlayer
        let item: AVPlayerItem
        let track: Track
        let stream: ResolvedStream
        let duration: TimeInterval
        let expiresAt: Date?
    }

    /// Nil while the player is lent to a transition as the outgoing side.
    private(set) var player: AVPlayer?
    private(set) var track: Track?
    private(set) var entryID: UUID?
    private(set) var isReady = false
    private(set) var didFail = false
    private(set) var refreshedForExpiry = false
    private var stream: ResolvedStream?
    private var item: AVPlayerItem?
    private var itemDuration: TimeInterval = 0
    private var token = UUID()
    private var resolution: Task<Void, Never>?
    private var statusObservation: NSKeyValueObservation?
    private var isPrerolling = false
    private let resolver: any StreamResolving
    private let preroll: Preroll
    private let log = Logger(subsystem: "com.agraabhi.ganabajana", category: "Standby")
    var onChange: (@MainActor () -> Void)?
    /// Separate from readiness notifications so DSP configuration cannot replace the owner's onChange callback.
    var onConfigureAudio: (@MainActor (AVPlayerItem, Double) -> Void)? {
        didSet { configureAudio() }
    }
    var normalizeVolume = true {
        didSet { if normalizeVolume != oldValue { configureAudio() } }
    }

    var normalizationGain: Double {
        PlaybackNormalization.gain(loudnessDb: stream?.loudnessDb, enabled: normalizeVolume)
    }

    private func configureAudio() {
        guard let item, stream != nil else { return }
        onConfigureAudio?(item, normalizationGain)
    }

    init(resolver: any StreamResolving, preroll: Preroll? = nil) {
        self.resolver = resolver
        self.preroll = preroll ?? { player, completion in
            player.preroll(atRate: 1) { @Sendable finished in
                Task { @MainActor in completion(finished) }
            }
        }
        player = Self.makePlayer()
    }

    isolated deinit {
        resolution?.cancel()
        statusObservation?.invalidate()
        player?.cancelPendingPrerolls()
        player?.replaceCurrentItem(with: nil)
    }

    var isResolved: Bool { stream != nil }

    var streamURL: URL? { stream?.url }

    var expiresAt: Date? {
        guard let stream else { return nil }
        return stream.expiresAt ?? PlaybackTiming.expiry(in: stream.url)
    }

    /// Swaps the prepared entry's media for another stream of the same recording, typically a finished download.
    /// Ignored while the player is lent to a transition or the deck already holds this URL.
    func adopt(_ stream: ResolvedStream, entryID: UUID) {
        guard self.entryID == entryID, track != nil, player != nil, self.stream?.url != stream.url else { return }
        resolution?.cancel()
        resolution = nil
        clearItem()
        token = UUID()
        self.stream = stream
        didFail = false
        refreshedForExpiry = false
        log.info("event=standby_adopted_cache")
        installIfPossible()
        onChange?()
    }

    func prepare(track: Track, entryID: UUID, forceRefresh: Bool, after configuration: Task<Void, Never>?) {
        resolution?.cancel()
        clearItem()
        self.track = track
        self.entryID = entryID
        stream = nil
        didFail = false
        refreshedForExpiry = forceRefresh
        let token = UUID()
        self.token = token
        resolution = Task { @MainActor [weak self, resolver] in
            do {
                await configuration?.value
                try Task.checkCancellation()
                var stream = try await PlaybackDeadline.run(seconds: 75) {
                    try await resolver.resolve(track: track, forceRefresh: forceRefresh)
                }
                stream = try await PlaybackStreamLoading.loadMissingLocalDuration(in: stream)
                try Task.checkCancellation()
                guard let self, self.token == token else { return }
                self.resolution = nil
                self.stream = stream
                self.installIfPossible()
                self.onChange?()
            } catch {
                guard !Task.isCancelled, let self, self.token == token else { return }
                self.resolution = nil
                self.didFail = true
                self.log.notice("event=standby_unavailable")
                self.onChange?()
            }
        }
    }

    func isUsable(entryID: UUID, transitionAt: Date) -> Bool {
        guard self.entryID == entryID, isReady, !didFail, let item,
              item.status == .readyToPlay, player?.currentItem === item else { return false }
        if let expiresAt, expiresAt.timeIntervalSince(transitionAt) < 60 { return false }
        return true
    }

    /// A resolved stream that would expire within a minute of the transition is re-resolved once, not used.
    func needsRefresh(transitionAt: Date) -> Bool {
        guard stream != nil, !refreshedForExpiry, let expiresAt else { return false }
        return expiresAt.timeIntervalSince(transitionAt) < 60
    }

    /// Detaches the ready player for a transition; the deck stays empty until reclaim(_:) returns a player.
    func take(entryID: UUID, transitionAt: Date) -> Prepared? {
        guard isUsable(entryID: entryID, transitionAt: transitionAt),
              let player, let item, let track, let stream else { return nil }
        let prepared = Prepared(player: player, item: item, track: track, stream: stream, duration: itemDuration, expiresAt: expiresAt)
        statusObservation?.invalidate()
        statusObservation = nil
        self.player = nil
        self.item = nil
        resetPreparation()
        return prepared
    }

    func reclaim(_ player: AVPlayer) {
        player.pause()
        player.cancelPendingPrerolls()
        player.replaceCurrentItem(with: nil)
        player.volume = 0
        guard self.player == nil else { return }
        self.player = player
        installIfPossible()
        if item != nil { onChange?() }
    }

    func invalidate() {
        clearItem()
        resetPreparation()
    }

    /// Media services resets leave every existing AVPlayer unusable.
    func reset() {
        invalidate()
        player = Self.makePlayer()
    }

    private func resetPreparation() {
        resolution?.cancel()
        resolution = nil
        isReady = false
        isPrerolling = false
        track = nil
        entryID = nil
        stream = nil
        didFail = false
        refreshedForExpiry = false
        token = UUID()
    }

    private func clearItem() {
        statusObservation?.invalidate()
        statusObservation = nil
        isReady = false
        isPrerolling = false
        player?.cancelPendingPrerolls()
        item = nil
        itemDuration = 0
        player?.replaceCurrentItem(with: nil)
    }

    private func installIfPossible() {
        guard let player, let stream, let track, item == nil, !didFail else { return }
        if let expiresAt, expiresAt.timeIntervalSinceNow <= 5 { didFail = true; return }
        itemDuration = PlaybackTiming.duration(stream: stream, track: track) ?? 0
        let item = PlaybackStreamLoading.makeItem(stream: stream, trackID: track.id, duration: itemDuration).item
        self.item = item
        configureAudio()
        player.volume = 0
        player.replaceCurrentItem(with: item)
        let token = self.token
        statusObservation = item.observe(\.status, options: [.initial, .new]) { @Sendable [weak self] _, _ in
            Task { @MainActor [weak self] in self?.itemStatusChanged(token: token) }
        }
    }

    private func itemStatusChanged(token: UUID) {
        guard self.token == token, let item, let player, player.currentItem === item else { return }
        switch item.status {
        case .readyToPlay:
            guard !isReady, !isPrerolling, !didFail else { return }
            isPrerolling = true
            let identity = ObjectIdentifier(item)
            preroll(player) { [weak self] finished in
                guard let self, self.token == token, self.isPrerolling, let item = self.item,
                      ObjectIdentifier(item) == identity, self.player?.currentItem === item else { return }
                self.isPrerolling = false
                self.isReady = finished && item.status == .readyToPlay
                if !self.isReady {
                    self.didFail = true
                    self.clearItem()
                }
                self.log.debug("event=standby_prerolled finished=\(finished)")
                self.onChange?()
            }
        case .failed:
            didFail = true
            clearItem()
            log.notice("event=standby_item_failed")
            onChange?()
        case .unknown: break
        @unknown default: break
        }
    }

    private static func makePlayer() -> AVPlayer {
        let player = PlaybackAudioRoute.makePlayer()
        player.automaticallyWaitsToMinimizeStalling = true
        player.volume = 0
        return player
    }
}

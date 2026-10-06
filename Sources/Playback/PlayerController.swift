import AVFoundation
import Foundation
import Observation
import OSLog

/// Constant-space startup accounting; automatic attempts share the original monotonic request time.
struct PlaybackStartupTiming {
    enum Stage { case setup, resolution, readyBuffer }
    let requestedAt: ContinuousClock.Instant
    private var stageStartedAt: ContinuousClock.Instant
    private var stage: Stage = .setup
    private(set) var attempts = 0
    private(set) var setup: Duration = .zero
    private(set) var resolution: Duration = .zero
    private(set) var readyBuffer: Duration = .zero
    private(set) var path: PlaybackStartTrace.Path?
    /// Whether the successful attempt's item reused a preloaded asset.
    var usedPreload = false
    init(at now: ContinuousClock.Instant = .now) {
        requestedAt = now
        stageStartedAt = now
    }

    mutating func beginAttempt(at now: ContinuousClock.Instant = .now) {
        advance(to: .setup, at: now)
        attempts = min(attempts + 1, 255)
        path = nil
    }

    mutating func beginResolution(at now: ContinuousClock.Instant = .now) {
        advance(to: .resolution, at: now)
    }

    mutating func resolved(path: PlaybackStartTrace.Path?, at now: ContinuousClock.Instant = .now) {
        self.path = path
        advance(to: .readyBuffer, at: now)
    }

    mutating func sample(at now: ContinuousClock.Instant = .now) -> Int {
        advance(to: stage, at: now)
        return Int(requestedAt.duration(to: now) / .milliseconds(1))
    }

    private mutating func advance(to next: Stage, at now: ContinuousClock.Instant) {
        let elapsed = stageStartedAt.duration(to: now)
        switch stage {
        case .setup: setup += elapsed
        case .resolution: resolution += elapsed
        case .readyBuffer: readyBuffer += elapsed
        }
        stage = next
        stageStartedAt = now
    }
}

@Observable
@MainActor
final class PlayerController {
    var currentTrack: Track? { isLiveRadio ? nil : ordering.current }
    private(set) var liveStation: LiveRadioStation?
    var isLiveRadio: Bool { liveStation != nil }
    var isWaitingForLiveRadioRetry: Bool { isLiveRadio && liveRetryTask != nil }
    var hasPlaybackSelection: Bool { isLiveRadio || currentTrack != nil }
    var displayTitle: String? { liveStation?.name ?? currentTrack?.title }
    var displaySubtitle: String? {
        liveStation.map { $0.subtitle.isEmpty ? "Live Radio" : "Live Radio · \($0.subtitle)" } ?? currentTrack?.artistName
    }
    // Live artwork uses the radio transport rather than the song artwork loader's provider rewrites.
    var displayArtworkURL: URL? { isLiveRadio ? nil : currentTrack?.artworkURL }
    var queue: [Track] { ordering.tracks }
    var queueEntries: [PlaybackQueue.Entry] { ordering.entries }
    var currentIndex: Int { ordering.index }
    var shuffleEnabled: Bool { ordering.shuffled }
    private(set) var shuffleStyle: ShuffleStyle = .random
    private(set) var position: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var isPlaying = false
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var repeatMode: RepeatMode = .off
    private(set) var sleepUntil: Date?
    private(set) var settings = PlaybackTransitionSettings()
    private(set) var normalizationGain: Double = 1
    /// Recording/upload views from the installed stream; separate from the catalog's aggregate song plays.
    private(set) var resolvedViewCount: Int64?
    /// Catalog song-count metadata; recording views cannot fill a missing total, even after fresh extraction.
    var currentPlayCount: Int64? {
        guard let count = currentTrack?.playCount, count >= 0 else { return nil }
        return count
    }
    private(set) var sourceAudioQuality: SourceAudioQuality?
    private(set) var playbackSource: MusicSource?
    @ObservationIgnored private var extractionPlaybackGeneration: UInt64?
    @ObservationIgnored var onFreshExtractionPlayed: (@MainActor (UInt64) -> Void)?
    private(set) var isNetworkOffline = false
    var canReloadAudioQuality: Bool {
        resolver is any PlaybackConfigurableResolving && currentTrack != nil && !isLoading
            && !isNetworkOffline && !isUpdatingAudioCacheLimit && !cachePipeline.isClearingStorage
    }
    /// True when the current track has a complete local copy: the playing item itself, or one recovery can switch to.
    private(set) var isCurrentTrackCached = false
    private(set) var isUpdatingAudioCacheLimit = false
    private(set) var audioCacheLimitError: String?
    private(set) var audioCacheLimitUsage: AudioCache.Usage?
    /// True once the next entry in play order has a complete local copy ready for the standby deck.
    var isNextTrackCached: Bool {
        guard let next = nextAutomaticOrder() else { return false }
        if cachedNextEntryID == next.entry { return true }
        guard deck.entryID == next.entry, let url = deck.streamURL else { return false }
        return cachePipeline.isCachedStream(ResolvedStream(url: url))
    }
    var nextAutomaticTrack: Track? { nextAutomaticOrder()?.order.current }
    /// Queue entries appended by Autoplay rather than the listener; the queue UI labels them.
    private(set) var autoplayTrackIDs: Set<String> = []
    /// An explicitly chosen radio keeps going independently of the general queue Autoplay preference.
    private(set) var isRadioSession = false
    @ObservationIgnored private var radioRefillAhead = 0
    private(set) var generatedRadioEntryIDs: Set<UUID> = []
    /// Pruned recording identities remain available to recommendation exclusions, oldest first.
    private(set) var radioRecentTracks: [Track] = []
    @ObservationIgnored private var selectedRadioEntryIDs: [UUID] = []
    private static let radioPreviousEntryLimit = 40
    private static let radioRecentTrackLimit = 128
    // Deferred external selections must not overtake a newer native or companion transport command.
    @ObservationIgnored private(set) var controlRevision: UInt64 = 0

    /// Acknowledges durable saves or intentionally disabled history; false keeps the delta queued for retry.
    var onListeningProgress: (@MainActor (Track, UUID, Date, TimeInterval) -> Bool)?
    @ObservationIgnored var onListeningCheckpoint: (@MainActor (PlaybackListeningCheckpoint) async -> Bool)?
    /// Recovery must see newer resume intent even before its asynchronous persistence task starts.
    @ObservationIgnored var onSnapshotIntentChanged: (@MainActor (PlaybackSnapshot) -> Void)?
    /// Nil history is disabled/unavailable; an empty array is enabled without saved sessions.
    @ObservationIgnored var shuffleHistoryProvider: (() -> [ListeningEvent]?)?
    var onSnapshotChanged: (@MainActor (PlaybackSnapshot) -> Void)?
    var onTrackStarted: (@MainActor (Track) -> Void)?
    /// One signal per music session that ends with credited audio; docs/LISTENING_DISCOVERY.md owns the rules.
    @ObservationIgnored var onListeningSignal: (@MainActor (ListeningSignal) -> Void)?
    /// Asked for continuation tracks when the last entry in play order starts and Autoplay is on.
    var onQueueExhausted: (@MainActor (Track) async -> [Track])?
    /// Asked once more when an ordinary queue has actually ended and the earlier answer added nothing. That earlier
    /// response is likely still cached, so implementations should ask for fresh results; nil falls back to `onQueueExhausted`.
    var onQueueEnded: (@MainActor (Track) async -> [Track])?
    var onSleepTimerFired: (@MainActor () -> Void)?

    var crossfadeState: PlaybackCrossfadeState? { transition?.state }
    var standbyTrack: Track? { deck.track }
    var isStandbyReady: Bool { deck.isReady }
    var hasStandbyPlayer: Bool { deck.player != nil }
    /// True only if a receiver took over the item URL, which `PlaybackAudioRoute.makePlayer()` forbids.
    var isExternalPlaybackActive: Bool { player.isExternalPlaybackActive }
    var activePlayerAllowsExternalPlayback: Bool { player.allowsExternalPlayback }
    var activePlayerIdentity: ObjectIdentifier { ObjectIdentifier(player) }
    var standbyPlayerAllowsExternalPlayback: Bool? { deck.player?.allowsExternalPlayback }
    var standbyStreamURL: URL? { deck.streamURL }
    /// The URL the playing item was created from, for diagnostics; nil while nothing is installed.
    private(set) var currentStreamURL: URL?
    var isPreparing: Bool { preparing }

    private var ordering = PlaybackQueue() {
        // A per-song equalizer follows the current recording; unchanged settings leave every tap alone.
        didSet { if oldValue.current?.id != ordering.current?.id { refreshEqualizer() } }
    }
    private var cachedNextEntryID: UUID?
    private var offlineAvailability: Set<String>?
    @ObservationIgnored private var inventoryEpoch = UUID()
    @ObservationIgnored private var inventoryRequest: UInt64 = 0
    @ObservationIgnored private var publishedInventoryRequest: UInt64 = 0
    @ObservationIgnored private var offlineAdvanceTask: Task<Void, Never>?
    @ObservationIgnored private var pendingOfflineAdvance: (id: UUID, generation: UInt64, entry: UUID?, automatic: Bool, resume: Bool)?
    @ObservationIgnored private var standbyNetworkGeneration: UUID?
    @ObservationIgnored let resolver: any StreamResolving
    @ObservationIgnored private var player = PlaybackAudioRoute.makePlayer()
    @ObservationIgnored private let liveRadioResolver: any LiveRadioResolving
    @ObservationIgnored private var savedMusicSnapshot: PlaybackSnapshot?
    @ObservationIgnored private var liveAsset: AVURLAsset?
    @ObservationIgnored private var liveRetryTask: Task<Void, Never>?
    @ObservationIgnored private var liveSamplePosition: TimeInterval?
    @ObservationIgnored private let deck: StandbyDeck
    @ObservationIgnored private let cachePipeline: PlaybackCachePipeline
    /// Ready-to-play assets for the queue's next songs and browsing candidates; see `PlaybackPreloader`.
    @ObservationIgnored let preloader: PlaybackPreloader
    /// The listener has stayed with the current song long enough that its successor earns a complete download.
    @ObservationIgnored private var nextDownloadSettled = false
    /// Playback position, capped at half the song, after which the next song downloads completely.
    @ObservationIgnored var nextDownloadSettleSeconds: TimeInterval = 30
    @ObservationIgnored private let equalizer = EqualizerTapInstaller()
    @ObservationIgnored private var cacheStorageTask: Task<AudioCache.Usage?, Error>?
    @ObservationIgnored private var cacheStorageGeneration = UUID()
    @ObservationIgnored private var cacheLimitGeneration = UUID()
    @ObservationIgnored private var cacheHistoryTask: Task<Void, Never>?
    @ObservationIgnored private var cacheHistoryGeneration = UUID()
    @ObservationIgnored private var transition: PlaybackCrossfade?
    @ObservationIgnored private var boundary: (player: AVPlayer, observer: Any)?
    @ObservationIgnored private var system: PlaybackSystemControls?
    @ObservationIgnored private var playerObservation: NSKeyValueObservation?
    @ObservationIgnored private var itemObservation: NSKeyValueObservation?
    @ObservationIgnored private var itemNotifications: [NSObjectProtocol] = []
    @ObservationIgnored private var resolutionTask: Task<Void, Never>?
    @ObservationIgnored private var settingsTask: Task<Void, Never>?
    @ObservationIgnored private var networkConfigurationTask: Task<Void, Never>?
    @ObservationIgnored private var offlineHandoffTask: Task<Void, Never>?
    @ObservationIgnored private var offlineRefreshGeneration = UUID()
    @ObservationIgnored private var networkGeneration = UUID()
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?
    @ObservationIgnored private var prefetchIDs: [String] = []
    @ObservationIgnored private var prefetchToken = UUID()
    @ObservationIgnored private var autoplayTask: Task<Void, Never>?
    @ObservationIgnored private var autoplayRequestedEntry: UUID?
    /// Entry whose early continuation added nothing; the end of the queue earns it one more request.
    @ObservationIgnored private var autoplayExhaustedEntry: UUID?
    @ObservationIgnored private var awaitingAutoplay: (generation: UInt64, entry: UUID)?
    @ObservationIgnored private var monitorTask: Task<Void, Never>?
    @ObservationIgnored private var readinessTask: Task<Void, Never>?
    @ObservationIgnored private var seekTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var sleepTask: Task<Void, Never>?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var seekGeneration: UInt64 = 0
    @ObservationIgnored private var wantsPlayback = false
    @ObservationIgnored private var seeking = false
    @ObservationIgnored private var preparing = false
    @ObservationIgnored private var ended = false
    @ObservationIgnored private var streamExpiresAt: Date?
    @ObservationIgnored private var streamLoudnessDb: Double?
    @ObservationIgnored private var pendingPosition: TimeInterval = 0
    @ObservationIgnored private var recoveryAttempts = 0
    /// When the current live connection became ready; a minute of playback refunds the retry budget, so one
    /// flaky stall per hour never ends a long session, while a stream that fails on every connect still stops.
    @ObservationIgnored private var liveReadyUptime: TimeInterval?
    static let liveRetryRefundSeconds: TimeInterval = 60
    @ObservationIgnored private var interruption = PlaybackInterruption()
    @ObservationIgnored private var listening = PlaybackListeningClock()
    @ObservationIgnored private var pendingListening: PlaybackListeningBuffer
    @ObservationIgnored private var isFlushingListening = false
    @ObservationIgnored private var listeningDeliveryTask: Task<Void, Never>?
    @ObservationIgnored private var listeningDeliveryGeneration = UUID()
    @ObservationIgnored private var checkpointIntentRevision: UInt64 = 0
    @ObservationIgnored private var savedCheckpointIntentRevision: UInt64 = 0
    @ObservationIgnored private var privacySnapshotDeliveryPending = false
    @ObservationIgnored private var pendingCheckpointRecent: RecentListen?
    @ObservationIgnored private var checkpointIntentPosition: TimeInterval?
    @ObservationIgnored private var checkpointIntentControlRevision: UInt64?
    @ObservationIgnored private var checkpointIntentSessionID: UUID?
    @ObservationIgnored private var sessionID = UUID()
    @ObservationIgnored private var sessionStartedAt: Date?
    @ObservationIgnored private var trackStartDelivered = false
    @ObservationIgnored private var standbyEligible = false
    @ObservationIgnored private var lastAdvanceUptime: TimeInterval = 0
    @ObservationIgnored private var lastCheckpointUptime: TimeInterval = 0
    @ObservationIgnored private var lastSeekUptime: TimeInterval = -1
    /// Only `seek(to:)`: SponsorBlock jumps and recovery seeks must not turn a natural end into a skip.
    @ObservationIgnored private var lastUserSeekUptime: TimeInterval = -.infinity
    @ObservationIgnored private var signalSession = ListeningSignalSession()
    @ObservationIgnored private var recentSkips = ListeningSignalSkipWindow()
    /// Occurrences a generated mix supplied; songs the listener adds later stay chosen.
    @ObservationIgnored private var generatedMixEntryIDs: Set<UUID> = []
    /// SponsorBlock jumps made during this play of the current song; the More sheet shows it when nonzero.
    private(set) var sponsorBlockSkipCount = 0
    var sponsorBlockSegments: [SponsorBlockSegment] { segmentSkipper.segments }
    /// Replaceable so fixtures and tests answer lookups locally; the live client is created on first use.
    @ObservationIgnored lazy var sponsorBlockProvider: any SponsorBlockSegmentProviding = SponsorBlockClient()
    @ObservationIgnored private var sponsorBlockEnabled = false
    @ObservationIgnored private var sponsorBlockPending = false
    @ObservationIgnored private var sponsorBlockTask: Task<Void, Never>?
    @ObservationIgnored private var sponsorBlockToken = UUID()
    @ObservationIgnored private var segmentSkipper = SegmentSkipper()
    @ObservationIgnored private var startupTiming: PlaybackStartupTiming?
    /// "path=<path> ms=<n>" of the latest `playback_start`; the fast-start fixture UI reads it.
    private(set) var lastPlaybackStart: String?
    private static var firstStartEmitted = false
    @ObservationIgnored private let log = Logger(subsystem: "com.agraabhi.ganabajana", category: "Playback")

    init(resolver: any StreamResolving = YouTubeStreamResolver(), standbyPreroll: StandbyDeck.Preroll? = nil,
         listeningCheckpointLimit: Int = PlaybackListeningBuffer.defaultMaximumSessions,
         liveRadioResolver: any LiveRadioResolving = LiveRadioStreamResolver(),
         preloader: PlaybackPreloader? = nil) {
        self.resolver = resolver
        self.liveRadioResolver = liveRadioResolver
        deck = StandbyDeck(resolver: resolver, preroll: standbyPreroll)
        cachePipeline = PlaybackCachePipeline(resolver: resolver)
        self.preloader = preloader ?? PlaybackPreloader(resolver: resolver)
        pendingListening = PlaybackListeningBuffer(maximumSessions: listeningCheckpointLimit)
        observeActivePlayer()
        system = PlaybackSystemControls(owner: self)
        deck.onChange = { [weak self] in self?.standbyChanged() }
        deck.onConfigureAudio = { [weak self] item, gain in
            self?.equalizer.setNormalizationGain(gain, for: item)
        }
        deck.normalizeVolume = settings.normalizeVolume
        cachePipeline.onNextCached = { [weak self] target, stream in self?.nextTrackCached(target, stream: stream) }
        cachePipeline.onCurrentCached = { [weak self] track, _ in self?.currentTrackCached(track) }
        cachePipeline.retainedTrackIDs = { [weak self] in self?.storageRetainedTrackIDs ?? [] }
        monitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard let self else { return }
                self.tick()
            }
        }
    }

    isolated deinit {
        liveRetryTask?.cancel()
        liveAsset?.cancelLoading()
        resolutionTask?.cancel()
        settingsTask?.cancel()
        networkConfigurationTask?.cancel()
        offlineHandoffTask?.cancel()
        offlineAdvanceTask?.cancel()
        cacheHistoryTask?.cancel()
        prefetchTask?.cancel()
        autoplayTask?.cancel()
        sponsorBlockTask?.cancel()
        monitorTask?.cancel()
        readinessTask?.cancel()
        seekTimeoutTask?.cancel()
        sleepTask?.cancel()
        listeningDeliveryTask?.cancel()
        cachePipeline.cancel()
        cacheStorageTask?.cancel()
        itemObservation?.invalidate()
        playerObservation?.invalidate()
        itemNotifications.forEach { NotificationCenter.default.removeObserver($0) }
        removeBoundary()
        transition?.cancel()
        transition?.outgoing.pause()
        deck.invalidate()
        player.pause()
        system?.tearDown()
    }

    func play(_ tracks: [Track], startingAt index: Int = 0, isRadio: Bool = false, shuffle: Bool? = nil,
              origin: ListeningSignal.Origin = .chosen) {
        controlRevision &+= 1
        let shuffled = shuffle ?? shuffleEnabled
        // Tapping the playing song again restarts it; only a different song replaces it.
        let replaces = !tracks.isEmpty && tracks[min(max(0, index), tracks.count - 1)].id != currentTrack?.id
        guard retireSelection(signal: replaces && wantsPlayback && !interruption.active ? .skipped : nil) else { return }
        autoplayTrackIDs = []
        isRadioSession = isRadio && !tracks.isEmpty
        resetSeedRadioRetention()
        var nextOrder = PlaybackQueue()
        nextOrder.replace(tracks, startingAt: index, shuffled: shuffled) { makeShuffleOrder($0) }
        ordering = nextOrder
        generatedMixEntryIDs = origin == .generated ? Set(nextOrder.entries.map(\.id)) : []
        if shuffle == false { logShuffleOrder() }
        selectCurrent(autoplay: true)
    }

    /// Starts a fresh retention session without replacing the installed player item or any queue occurrence.
    /// Existing entries are preserved; only subsequent radio appends acquire this session's provenance.
    @discardableResult
    func configureSeedRadio(keeping trackID: String) -> Bool {
        guard !isLiveRadio, currentTrack?.id == trackID else { return false }
        cancelAutoplayRequest()
        resetSeedRadioRetention()
        isRadioSession = true
        radioRefillAhead = 3
        repeatMode = .off
        publishSnapshot()
        return true
    }

    /// A tuning change retires old recommendations without changing playback or user queue entries.
    func refreshSeedRadioRequests() {
        guard isRadioSession, radioRefillAhead > 0 else { return }
        cancelAutoplayRequest()
    }

    /// Queue navigation reuses occurrences and radio provenance rather than starting a replacement session.
    @discardableResult
    func selectQueueTrack(at index: Int) -> Bool {
        guard !isLiveRadio, ordering.entries.indices.contains(index) else { return false }
        controlRevision &+= 1
        let skips = wantsPlayback && !interruption.active && ordering.entries[index].id != ordering.selectedID
        guard retireSelection(signal: skips ? .skipped : nil) else { return false }
        ordering.select(at: index)
        selectCurrent(autoplay: true)
        return true
    }

    func playShuffled(_ tracks: [Track], origin: ListeningSignal.Origin = .chosen) {
        controlRevision &+= 1
        guard retireSelection(signal: !tracks.isEmpty && wantsPlayback && !interruption.active ? .skipped : nil) else { return }
        autoplayTrackIDs = []
        isRadioSession = false
        resetSeedRadioRetention()
        var nextOrder = PlaybackQueue()
        nextOrder.replaceShuffled(tracks) { makeShuffleOrder($0) }
        ordering = nextOrder
        generatedMixEntryIDs = origin == .generated ? Set(nextOrder.entries.map(\.id)) : []
        selectCurrent(autoplay: true)
    }

    func restore(_ snapshot: PlaybackSnapshot) {
        controlRevision &+= 1
        guard retireSelection() else { return }
        autoplayTrackIDs = []
        generatedMixEntryIDs = []
        isRadioSession = false
        resetSeedRadioRetention()
        ordering.restore(snapshot)
        repeatMode = snapshot.repeatMode
        selectCurrent(autoplay: false, at: PlaybackTiming.position(snapshot.position))
    }

    // MARK: - Live public radio

    @discardableResult
    func playLiveRadio(_ station: LiveRadioStation) -> Bool {
        guard station.isValid, !isNetworkOffline else { return false }
        pause()
        let saved = musicResumeSnapshot
        guard retireSelection() else { return false }
        savedMusicSnapshot = saved
        liveStation = station
        controlRevision &+= 1
        cancelPrefetch()
        deck.invalidate()
        clearSponsorBlockSegments()
        isRadioSession = false
        autoplayTrackIDs = []
        resetSeedRadioRetention()
        standbyEligible = false
        trackStartDelivered = false
        sessionStartedAt = nil
        position = 0
        pendingPosition = 0
        duration = 0
        resolvedViewCount = nil
        sourceAudioQuality = nil
        playbackSource = nil
        extractionPlaybackGeneration = nil
        isCurrentTrackCached = false
        cachedNextEntryID = nil
        ended = false
        recoveryAttempts = 0
        wantsPlayback = true
        refreshEqualizer()
        log.info("event=live_radio_mode mode=live")
        beginLiveConnecting()
        return true
    }

    /// Returning to music reinstates its occurrence and position paused, never the station URL.
    func stopLiveRadio() {
        guard isLiveRadio else { return }
        let saved = musicResumeSnapshot
        restore(saved)
        log.info("event=live_radio_mode mode=music")
    }

    func stopPlayback() {
        if isLiveRadio { stopLiveRadio() } else { pause() }
    }

    private func beginLiveConnecting() {
        guard let station = liveStation, wantsPlayback, !interruption.active else { return }
        guard !isNetworkOffline else { fail(LiveRadioError.unavailable.localizedDescription); return }
        invalidatePipeline()
        let token = generation
        errorMessage = nil
        isLoading = true
        system?.beginTransition()
        publishNowPlaying()
        let resolver = liveRadioResolver
        resolutionTask = Task { @MainActor [weak self] in
            do {
                let resolved = try await PlaybackDeadline.run(seconds: 15) { try await resolver.resolve(station) }
                try Task.checkCancellation()
                guard let self, self.generation == token, self.liveStation?.id == station.id,
                      self.wantsPlayback, !self.interruption.active else { return }
                guard resolved.station.id == station.id, resolved.station.isValid,
                      LiveRadioURLPolicy.permits(resolved.streamingURL) else {
                    LiveRadioDiagnostics.record(.resolvedURL, .rejected)
                    throw LiveRadioError.invalidStation
                }
                LiveRadioDiagnostics.record(.resolvedURL, .passed)
                let asset = AVURLAsset(url: resolved.streamingURL, options: [AVURLAssetHTTPCookiesKey: [HTTPCookie]()])
                self.liveAsset = asset
                try await PlaybackDeadline.run(seconds: 15) {
                    try await withTaskCancellationHandler {
                        try await LiveRadioNativeValidation.validate(asset, connection: resolved)
                    } onCancel: { asset.cancelLoading() }
                }
                try Task.checkCancellation()
                guard self.generation == token, self.liveStation?.id == station.id,
                      self.wantsPlayback, !self.interruption.active else { return }
                self.resolutionTask = nil
                self.liveStation = resolved.station
                self.currentStreamURL = resolved.streamingURL
                let item = AVPlayerItem(asset: asset)
                item.preferredForwardBufferDuration = 5
                self.preparing = true
                self.player.replaceCurrentItem(with: item)
                self.itemObservation = item.observe(\.status, options: [.initial, .new]) { @Sendable [weak self] _, _ in
                    Task { @MainActor [weak self] in self?.itemStatusChanged(generation: token) }
                }
                self.observeItem(item, generation: token)
                self.readinessTask = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(20)) } catch { return }
                    guard let self, self.generation == token, self.preparing else { return }
                    self.recoverLivePlayback()
                }
            } catch {
                guard !Task.isCancelled, let self, self.generation == token, self.liveStation?.id == station.id else { return }
                self.resolutionTask = nil
                if case LiveRadioError.invalidStation = error { self.fail(LiveRadioError.invalidStation.localizedDescription) }
                else { self.recoverLivePlayback() }
            }
        }
    }

    private func liveItemStatusChanged(_ item: AVPlayerItem, generation token: UInt64) {
        guard generation == token, isLiveRadio else { return }
        switch item.status {
        case .readyToPlay:
            guard preparing else { return }
            preparing = false
            readinessTask?.cancel()
            readinessTask = nil
            guard wantsPlayback, !interruption.active else { return }
            do { try system?.activateSession() }
            catch { fail("Audio is unavailable right now. Please try again."); return }
            lastAdvanceUptime = ProcessInfo.processInfo.systemUptime
            liveReadyUptime = lastAdvanceUptime
            player.play()
            log.info("event=live_radio_connection outcome=ready attempt=\(self.recoveryAttempts + 1)")
        case .failed: recoverLivePlayback()
        case .unknown: break
        @unknown default: fail(LiveRadioError.invalidStation.localizedDescription)
        }
        refreshActivity()
    }

    private func recoverLivePlayback() {
        guard isLiveRadio, wantsPlayback, !interruption.active else { return }
        liveReadyUptime = nil
        guard recoveryAttempts < 2, !isNetworkOffline else {
            log.notice("event=live_radio_connection outcome=exhausted")
            fail(LiveRadioError.unavailable.localizedDescription)
            return
        }
        recoveryAttempts += 1
        invalidatePipeline()
        let token = generation
        let delay = recoveryAttempts
        isLoading = true
        system?.beginTransition()
        log.notice("event=live_radio_connection outcome=retry attempt=\(self.recoveryAttempts + 1)")
        liveRetryTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, self.generation == token, self.isLiveRadio, self.wantsPlayback, !self.interruption.active else { return }
            self.liveRetryTask = nil
            self.beginLiveConnecting()
        }
        publishNowPlaying()
    }

    /// Idempotent. A crossfade already in flight finishes with the values it started with.
    func apply(_ settings: PlaybackTransitionSettings) {
        var next = settings
        let range = UserPreferences.crossfadeRange
        next.crossfadeSeconds = next.crossfadeSeconds.isFinite
            ? min(max(next.crossfadeSeconds, range.lowerBound), range.upperBound) : range.lowerBound
        guard next != self.settings else { return }
        self.settings = next
        if !next.autoplay && !isRadioSession { cancelAutoplayRequest() }
        refreshNormalizationGain(applyToPlayer: transition == nil)
        refreshStandby()
    }

    func togglePlayback() {
        if wantsPlayback || isPlaying || awaitingAutoplay != nil { pause() } else { resumePlayback() }
    }

    func pause() {
        controlRevision &+= 1
        retireOfflineNavigation()
        flushListeningProgress()
        wantsPlayback = false
        startupTiming = nil
        interruption.cancelResume()
        cancelAutoplayRequest()
        endTransition()
        player.pause()
        if isLiveRadio || resolutionTask != nil || preparing {
            invalidatePipeline()
        }
        listening.discontinuity()
        isPlaying = false
        isLoading = false
        system?.endTransition()
        system?.deactivateSession()
        publishSnapshot()
        publishNowPlaying()
    }

    /// Pass false for a skip that already carries a stronger judgement, such as a dislike, so it is not counted twice.
    func next(recordsSignal: Bool = true) {
        controlRevision &+= 1
        guard currentTrack != nil else { return }
        let skip: ListeningSignal.Ending? = recordsSignal && wantsPlayback && !interruption.active ? .skipped : nil
        if isNetworkOffline { beginOfflineAdvance(automatic: false, signal: skip); return }
        retireOfflineNavigation()
        let autoplay = wantsPlayback
        var nextOrder = ordering
        guard nextOrder.advance(repeatMode: repeatMode, automatic: false) else { pause(); return }
        // The gapless deck already holds the next entry ready to play; taking it makes a skip as fast as a track end.
        if autoplay, transition == nil, !interruption.active,
           let entry = nextOrder.selectedID, entry != ordering.selectedID,
           let prepared = deck.take(entryID: entry, transitionAt: Date()) {
            log.debug("event=manual_next path=standby")
            activateStandby(prepared, order: nextOrder, blend: settings.crossfadeSeconds > 0 ? min(settings.crossfadeSeconds, 3) : 0,
                            signal: skip)
            return
        }
        guard retireSelection(signal: skip) else { return }
        ordering = nextOrder
        selectCurrent(autoplay: autoplay)
    }

    func previous() {
        controlRevision &+= 1
        guard currentTrack != nil else { return }
        if position > 3 { seek(to: 0); return }
        let autoplay = wantsPlayback
        var previousOrder = ordering
        previousOrder.previous(repeatMode: repeatMode)
        guard retireSelection() else { return }
        ordering = previousOrder
        selectCurrent(autoplay: autoplay)
    }

    func seek(to seconds: TimeInterval) {
        controlRevision &+= 1
        guard currentTrack != nil, seconds.isFinite else { return }
        retireOfflineNavigation()
        endTransition()
        flushListeningProgress()
        guard listening.pending == 0 else { return }
        if ended {
            cancelAutoplayRequest()
            startListeningSession()
            segmentSkipper.restart()
        }
        // A listener-chosen position is never skipped away from right after the seek.
        segmentSkipper.noteManualSeek(uptime: ProcessInfo.processInfo.systemUptime)
        lastUserSeekUptime = ProcessInfo.processInfo.systemUptime
        let target = PlaybackTiming.position(seconds, duration: player.currentItem == nil ? nil : duration)
        position = target
        pendingPosition = target
        ended = false
        listening.discontinuity()
        if let item = player.currentItem, item.status == .readyToPlay {
            performSeek(to: target, generation: generation)
        }
        publishSnapshot()
        publishNowPlaying()
    }

    func retry(preferBestAudio: Bool = false) {
        controlRevision &+= 1
        if isLiveRadio {
            guard !interruption.active else { return }
            recoveryAttempts = 0
            wantsPlayback = true
            beginLiveConnecting()
            return
        }
        guard currentTrack != nil else { return }
        let resumeAt = ended ? 0 : position
        if ended {
            flushListeningProgress()
            guard listening.pending == 0 else { return }
            startListeningSession()
            segmentSkipper.restart()
        }
        recoveryAttempts = 0
        wantsPlayback = true
        startupTiming = nil
        beginResolving(forceRefresh: true, at: resumeAt, preferBestAudio: preferBestAudio)
    }

    func toggleShuffle() {
        guard !isLiveRadio else { return }
        controlRevision &+= 1
        retireOfflineNavigation()
        var nextOrder = ordering
        nextOrder.toggleShuffle { makeShuffleOrder($0) }
        ordering = nextOrder
        pruneSeedRadioHistory()
        if !shuffleEnabled { logShuffleOrder() }
        publishSnapshot()
        publishNowPlaying()
        refreshQueuePreparation()
    }

    func setShuffleStyle(_ style: ShuffleStyle) {
        guard shuffleStyle != style else { return }
        shuffleStyle = style
    }

    private func makeShuffleOrder(_ entries: [PlaybackQueue.Entry]) -> [PlaybackQueue.Entry] {
        let history = entries.isEmpty ? nil : shuffleHistoryProvider?()
        let policy = PlaybackShufflePolicy(style: shuffleStyle, history: history, now: Date())
        var generator = SystemRandomNumberGenerator()
        let result = policy.order(entries, using: &generator)
        logShuffleOrder(result, history: entries.isEmpty ? .notRead : policy.historyAvailability)
        return result.entries
    }

    private func logShuffleOrder(_ result: PlaybackShufflePolicy.Order? = nil,
                                 history: PlaybackShufflePolicy.HistoryAvailability = .notRead) {
        let effective = result?.effectiveStyle.rawValue ?? "off"
        let historyAvailable = history == .available || history == .empty
        log.info("event=shuffle_order configured=\(self.shuffleStyle.rawValue, privacy: .public) effective=\(effective, privacy: .public) history=\(history.rawValue, privacy: .public) history_available=\(historyAvailable ? 1 : 0) weighted=\(result?.weighted == true ? 1 : 0) candidate_count=\(result?.entries.count ?? 0) recent_count=\(result?.recentCount ?? 0)")
    }

    func cycleRepeatMode() {
        guard !isLiveRadio else { return }
        controlRevision &+= 1
        retireOfflineNavigation()
        repeatMode = repeatMode.next
        if repeatMode != .off { cancelAutoplayRequest() }
        publishSnapshot()
        refreshQueuePreparation()
    }

    func enqueue(_ track: Track, next: Bool = false) {
        guard !isLiveRadio else { return }
        controlRevision &+= 1
        retireOfflineNavigation()
        let wasEmpty = queue.isEmpty
        ordering.enqueue(track, next: next)
        if wasEmpty { selectCurrent(autoplay: false) }
        publishSnapshot()
        publishNowPlaying()
        refreshQueuePreparation()
    }

    /// Appends Autoplay continuation tracks, skipping anything already queued. After the queue has ended, a manual
    /// continuation also moves on to the first new song: the listener asked for more music, not a replay of the last one.
    func appendAutoplay(_ tracks: [Track]) {
        guard !isLiveRadio else { return }
        defer { finishAutoplayWait() }
        let atEnd = ended && !wantsPlayback && awaitingAutoplay == nil && repeatMode == .off && nextAutomaticOrder() == nil
        guard insertAutoplay(tracks), atEnd, let next = nextAutomaticOrder() else { return }
        guard retireSelection() else { return }
        ordering = next.order
        // During an interruption the new song is selected but must not start; the listener resumes afterwards.
        selectCurrent(autoplay: !interruption.active)
        log.info("event=autoplay_resumed_after_end manual=1")
    }

    /// True when at least one track joined the queue.
    @discardableResult
    private func insertAutoplay(_ tracks: [Track]) -> Bool {
        guard !isLiveRadio else { return false }
        var known = Set(queue.map(\.id))
        if radioRefillAhead > 0 { known.formUnion(radioRecentTracks.map(\.id)) }
        let additions = tracks.filter { known.insert($0.id).inserted }
        let pruned = pruneSeedRadioHistory()
        guard !additions.isEmpty else {
            if pruned { publishSnapshot(); publishNowPlaying() }
            return false
        }
        retireOfflineNavigation()
        let wasEmpty = queue.isEmpty
        for track in additions {
            let entryID = ordering.enqueue(track, next: false)
            if radioRefillAhead > 0 { generatedRadioEntryIDs.insert(entryID) }
        }
        autoplayTrackIDs.formUnion(additions.map(\.id))
        if wasEmpty { selectCurrent(autoplay: false) }
        pruneSeedRadioHistory()
        log.info("event=autoplay_appended count=\(additions.count)")
        publishSnapshot()
        publishNowPlaying()
        refreshQueuePreparation()
        return true
    }

    func removeFromQueue(at index: Int) {
        guard !isLiveRadio else { return }
        controlRevision &+= 1
        guard queue.indices.contains(index) else { return }
        retireOfflineNavigation()
        let removesCurrent = index == currentIndex
        let autoplay = wantsPlayback
        if removesCurrent, !retireSelection() { return }
        ordering.remove(at: index)
        if removesCurrent { selectCurrent(autoplay: autoplay) }
        else { pruneSeedRadioHistory() }
        publishSnapshot()
        publishNowPlaying()
        refreshQueuePreparation()
    }

    func moveQueue(from offsets: IndexSet, to destination: Int) {
        guard !isLiveRadio else { return }
        controlRevision &+= 1
        retireOfflineNavigation()
        ordering.move(from: offsets, to: destination)
        pruneSeedRadioHistory()
        publishSnapshot()
        publishNowPlaying()
        refreshQueuePreparation()
    }

    func prefetch(_ tracks: [Track]) {
        guard !isLiveRadio, !isNetworkOffline, !cachePipeline.isClearingStorage else { return }
        var seen = Set<String>()
        let selected = Array(tracks.filter { $0.isAudioRecording != false && seen.insert($0.id).inserted }.prefix(2))
        let ids = selected.map(\.id)
        if prefetchTask != nil && prefetchIDs == ids { return }
        prefetchTask?.cancel()
        prefetchIDs = ids
        let token = UUID()
        prefetchToken = token
        let configuration = networkConfigurationTask
        prefetchTask = Task(priority: .utility) { @MainActor [weak self, resolver] in
            await configuration?.value
            await self?.waitForCacheStorageUpdates()
            await self?.waitForCacheHistoryUpdates()
            guard !Task.isCancelled, self?.prefetchToken == token else { return }
            await resolver.prefetch(selected)
            guard let self, self.prefetchToken == token else { return }
            self.prefetchTask = nil
        }
    }

    /// Songs a Next tap or the end of this one would start, in play order. Repeat One still lets Next move on.
    func upcomingTracks(limit: Int) -> [Track] {
        guard limit > 0, !isLiveRadio else { return [] }
        var probe = ordering
        var seen: Set<String> = currentTrack.map { [$0.id] } ?? []
        var result: [Track] = []
        var steps = 0
        while result.count < limit, steps < probe.entries.count,
              probe.advance(repeatMode: repeatMode == .one ? .off : repeatMode, automatic: false) {
            steps += 1
            guard let track = probe.current, seen.insert(track.id).inserted else { continue }
            result.append(track)
        }
        return result
    }

    /// New preload work waits for the selected song's first audio and for playing intent, so a restored paused queue
    /// spends nothing and a quick skip never competes with the song the listener just chose.
    private func refreshPreloads() {
        guard preloader.isAvailable else { return }
        guard !isLiveRadio, !isNetworkOffline, currentTrack != nil else {
            preloader.update(queue: [], queueAllowed: false, holding: false)
            return
        }
        let playing = wantsPlayback && !interruption.active
        preloader.update(queue: upcomingTracks(limit: PlaybackPreloader.queueDepth), queueAllowed: playing,
                         holding: playing && !trackStartDelivered)
    }

    func setSleepTimer(minutes: Int?) {
        sleepTask?.cancel()
        sleepTask = nil
        guard let minutes, minutes > 0 else { sleepUntil = nil; return }
        let deadline = Date().addingTimeInterval(Double(min(minutes, 1_440)) * 60)
        sleepUntil = deadline
        sleepTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow))) } catch { return }
            self?.expireSleepTimer(expected: deadline, now: Date())
        }
    }

    func flushListeningProgress() {
        guard !isFlushingListening else { return }
        isFlushingListening = true
        defer { isFlushingListening = false }
        samplePlayback()
        lastCheckpointUptime = ProcessInfo.processInfo.systemUptime
        var hasNewRecent = false
        if listening.pending > 0, !pendingListening.canRecord(sessionID: sessionID) {
            deliverListeningCheckpoints()
        }
        if listening.pending > 0, let track = currentTrack, let startedAt = sessionStartedAt {
            let checkpoint = ListeningEvent(id: sessionID, track: track, startedAt: startedAt, listenedSeconds: listening.pending)
            guard enqueueListeningCheckpoint(checkpoint) else {
                failListeningCapacity()
                return
            }
            _ = listening.drain()
            if onListeningCheckpoint != nil {
                pendingCheckpointRecent = RecentListen(track: track, playedAt: Date(), position: position)
                hasNewRecent = true
            }
        }
        deliverListeningCheckpoints()
        if onListeningCheckpoint == nil || hasNewRecent || checkpointIntentPosition != position
            || checkpointIntentControlRevision != controlRevision || checkpointIntentSessionID != sessionID {
            publishSnapshot()
        }
    }

    private func deliverListeningCheckpoints() {
        if onListeningCheckpoint != nil {
            startListeningCheckpointDelivery()
            return
        }
        while let checkpoint = pendingListening.checkpoints.first {
            guard onListeningProgress?(checkpoint.track, checkpoint.id, checkpoint.startedAt, checkpoint.listenedSeconds) == true else { break }
            pendingListening.acknowledge(checkpoint)
        }
    }

    func discardPendingListening() {
        listeningDeliveryGeneration = UUID()
        listeningDeliveryTask?.cancel()
        pendingCheckpointRecent = nil
        // Privacy retires listening, not an unsaved resume intent.
        privacySnapshotDeliveryPending = listeningDeliveryTask != nil || checkpointIntentRevision != savedCheckpointIntentRevision
        pendingListening.discard()
        listening = PlaybackListeningClock()
        sessionID = UUID()
        sessionStartedAt = nil
        // Seconds from before the boundary never reach a signal; the boundary itself records nothing.
        signalSession = ListeningSignalSession()
        lastCheckpointUptime = ProcessInfo.processInfo.systemUptime
        // History boundaries reset recording identity, not the audible track's once-only start notification.
        samplePlayback()
        if errorMessage == Self.listeningCapacityMessage { errorMessage = nil }
        if privacySnapshotDeliveryPending { startListeningCheckpointDelivery() }
    }

    @discardableResult
    func enqueueListeningCheckpoint(_ checkpoint: ListeningEvent) -> Bool {
        pendingListening.append(checkpoint)
    }

    var pendingListeningCheckpoints: [ListeningEvent] { pendingListening.checkpoints }
    var isDeliveringListeningCheckpoint: Bool { listeningDeliveryTask != nil }

    func isCurrentListeningCheckpointIntent(_ checkpoint: PlaybackListeningCheckpoint) -> Bool {
        isCurrentListeningCheckpointGeneration(checkpoint) && checkpoint.intentRevision == checkpointIntentRevision
            && checkpoint.controlRevision == controlRevision
    }

    func isCurrentListeningCheckpointGeneration(_ checkpoint: PlaybackListeningCheckpoint) -> Bool {
        checkpoint.deliveryGeneration == listeningDeliveryGeneration
    }

    /// Includes a privacy boundary's replacement snapshot save without sampling the clock or manufacturing another delta.
    func waitForListeningCheckpointDelivery() async {
        while let delivery = listeningDeliveryTask {
            await delivery.value
            if Task.isCancelled { return }
        }
    }

    func handleListeningCheckpointExpiration() {
        log.notice("event=listening_checkpoint_expired")
        listeningDeliveryTask?.cancel()
        system?.endListeningCheckpoint()
    }

    private func startListeningCheckpointDelivery() {
        guard listeningDeliveryTask == nil, onListeningCheckpoint != nil else { return }
        guard !pendingListening.checkpoints.isEmpty || pendingCheckpointRecent != nil
                || checkpointIntentRevision != savedCheckpointIntentRevision else {
            privacySnapshotDeliveryPending = false
            return
        }
        let startsWithSnapshotOnly = privacySnapshotDeliveryPending
        // A failed recovery waits for the ordinary retry path instead of starting another task from cleanup.
        privacySnapshotDeliveryPending = false
        let generation = listeningDeliveryGeneration
        system?.beginListeningCheckpoint()
        listeningDeliveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var snapshotOnly = startsWithSnapshotOnly
            defer {
                self.listeningDeliveryTask = nil
                self.system?.endListeningCheckpoint()
                if self.privacySnapshotDeliveryPending { self.startListeningCheckpointDelivery() }
            }
            // Repeated ticks coalesce into the latest intent; a failed drain waits for the next flush rather than spinning.
            for _ in 0..<3 {
                guard !Task.isCancelled, generation == self.listeningDeliveryGeneration,
                      let deliver = self.onListeningCheckpoint else { return }
                guard !self.pendingListening.checkpoints.isEmpty
                    || self.pendingCheckpointRecent != nil
                    || self.checkpointIntentRevision != self.savedCheckpointIntentRevision else { return }
                let checkpoint = PlaybackListeningCheckpoint(
                    events: snapshotOnly ? [] : Array(self.pendingListening.checkpoints.prefix(PlaybackListeningBuffer.defaultMaximumSessions)),
                    recent: snapshotOnly ? nil : self.pendingCheckpointRecent,
                    snapshot: self.musicResumeSnapshot,
                    intentRevision: self.checkpointIntentRevision, controlRevision: self.controlRevision, deliveryGeneration: generation)
                let began = ContinuousClock.now
                let acknowledged = await deliver(checkpoint)
                let outcome = acknowledged ? "acknowledged" : (Task.isCancelled ? "cancelled" : "rejected")
                self.log.info("event=listening_checkpoint_delivery outcome=\(outcome, privacy: .public) snapshot_only=\(snapshotOnly) sessions=\(checkpoint.events.count) duration_ms=\(began.duration(to: .now) / .milliseconds(1))")
                guard generation == self.listeningDeliveryGeneration else { return }
                // Cancellation can arrive after the disk commit; a durable acknowledgement must still consume its exact deltas.
                guard acknowledged else { return }
                for event in checkpoint.events { self.pendingListening.acknowledge(event) }
                if self.isCurrentListeningCheckpointIntent(checkpoint) {
                    self.savedCheckpointIntentRevision = checkpoint.intentRevision
                    if snapshotOnly { snapshotOnly = false }
                    else { self.pendingCheckpointRecent = nil }
                }
            }
        }
    }

    private static let listeningCapacityMessage = "Listening history couldn’t be saved. Playback is paused to keep unsaved listening time. Free some storage or turn off listening history, then try again."

    private func ensureListeningCapacity(for sessionID: UUID) -> Bool {
        if pendingListening.canRecord(sessionID: sessionID) { return true }
        flushListeningProgress()
        guard pendingListening.canRecord(sessionID: sessionID) else {
            failListeningCapacity()
            return false
        }
        return true
    }

    private func failListeningCapacity() {
        log.error("event=listening_checkpoint_limit sessions=\(self.pendingListening.checkpoints.count)")
        fail(Self.listeningCapacityMessage)
    }

    func setRemoteFallbackEnabled(_ enabled: Bool) {
        guard let youtube = resolver as? any PlaybackConfigurableResolving else { return }
        let previous = settingsTask
        settingsTask = Task {
            await previous?.value
            await youtube.setRemoteFallbackEnabled(enabled)
        }
        if resolutionTask != nil {
            beginResolving(forceRefresh: true, at: position)
        }
    }

    /// The current song keeps its stream; the ceiling applies from the next resolution on.
    func setAudioQualityPreference(_ preference: AudioQualityPreference) {
        guard let youtube = resolver as? any PlaybackConfigurableResolving else { return }
        preloader.reset()
        let previous = settingsTask
        settingsTask = Task {
            await previous?.value
            await youtube.setAudioQualityPreference(preference)
        }
    }

    /// Idempotent. Every installed tap, on the live and the standby item, ramps to the new curve; playback continues.
    /// `settings` is the global choice; a per-song override for the current recording wins while it plays.
    func setEqualizer(_ settings: EqualizerSettings) {
        globalEqualizer = settings
        refreshEqualizer()
    }

    /// Re-picks the current song's override or the global setting; the installer ignores an unchanged value.
    func refreshEqualizer() {
        let override = currentTrack.flatMap { equalizerSongOverride?($0.id) }
        isEqualizerSongOverrideActive = override != nil
        equalizer.update(override ?? globalEqualizer)
    }

    /// Looks up a per-song equalizer by recording id; nil for songs that follow the global setting.
    @ObservationIgnored var equalizerSongOverride: (@MainActor (String) -> EqualizerSettings?)?
    @ObservationIgnored private var globalEqualizer = EqualizerSettings()
    private(set) var isEqualizerSongOverrideActive = false

    var equalizerSettings: EqualizerSettings { equalizer.settings }
    var equalizerStatus: EqualizerTapInstaller.Status { equalizer.status }

    /// Level of whichever tapped item is rendering; read by the React to Music backdrop, never observed.
    var levelMeter: PlaybackLevelMeter { equalizer.levelMeter }

    /// Requested only while a visible player shows React to Music, so its taps and gapless priming cost
    /// exist only then. Active and standby items registered meanwhile take a tap unless known live.
    func setLevelMetering(_ requested: Bool) {
        equalizer.setMetering(requested)
    }

    /// Polled at the backdrop's frame rate; unavailable on HLS, live and unsupported PCM items.
    var levelMeterAvailability: EqualizerTapInstaller.MeterAvailability {
        player.currentItem.map(equalizer.meterAvailability(for:)) ?? .unavailable
    }

    /// Idempotent. Off forgets the current song's segments and skip count and cancels a pending lookup.
    func setSponsorBlockSkipping(_ enabled: Bool) {
        guard enabled != sponsorBlockEnabled else { return }
        sponsorBlockEnabled = enabled
        log.info("event=sponsorblock_setting enabled=\(enabled ? 1 : 0)")
        if enabled { refreshSponsorBlockSegments() } else { clearSponsorBlockSegments() }
    }

    func setNetworkOffline(_ offline: Bool) {
        guard offline != isNetworkOffline else { return }
        isNetworkOffline = offline
        if offline { cachePipeline.setNetworkOffline(true) }
        inventoryEpoch = UUID()
        offlineAvailability = nil
        let networkToken = UUID()
        networkGeneration = networkToken
        offlineHandoffTask?.cancel()
        offlineHandoffTask = nil
        let previous = networkConfigurationTask
        let configuration = Task { @MainActor [weak self, resolver] in
            await previous?.value
            if let youtube = resolver as? any PlaybackConfigurableResolving { await youtube.setNetworkOffline(offline) }
            guard !Task.isCancelled, let self, self.networkGeneration == networkToken else { return }
            self.cachePipeline.setNetworkOffline(offline)
            if !offline { self.resumeConnectivityWork() }
        }
        networkConfigurationTask = configuration
        if isLiveRadio {
            if offline { fail(LiveRadioError.unavailable.localizedDescription) }
            return
        }
        guard offline else { return }
        cancelPrefetch()
        cancelAutoplayRequest()
        refreshStandby()
        if resolutionTask != nil, currentStreamURL == nil, wantsPlayback, !interruption.active {
            beginResolving(forceRefresh: false, at: position)
            return
        }
        refreshOfflineAvailability()
    }

    private func resumeConnectivityWork() {
        if deck.didFail { deck.invalidate() }
        guard errorMessage == nil, !interruption.active else { return }
        if let pending = pendingOfflineAdvance {
            finishOfflineAdvance(pending.id)
            return
        }
        guard wantsPlayback, !ended else { return }
        log.debug("event=playback_reconnected cache_sync=1")
        refreshStandby()
    }

    private func refreshOfflineAvailability() {
        guard isNetworkOffline else { return }
        offlineHandoffTask?.cancel()
        let refresh = UUID()
        offlineRefreshGeneration = refresh
        let token = generation
        let entry = ordering.selectedID
        let epoch = inventoryEpoch
        let configuration = networkConfigurationTask
        offlineHandoffTask = Task { @MainActor [weak self] in
            await configuration?.value
            guard let self else { return }
            defer { if self.offlineRefreshGeneration == refresh { self.offlineHandoffTask = nil } }
            guard !Task.isCancelled, self.isNetworkOffline, self.generation == token, self.ordering.selectedID == entry,
                  self.inventoryEpoch == epoch else { return }
            _ = try? await self.cachedSongsSnapshot()
            guard !Task.isCancelled, self.isNetworkOffline, self.generation == token, self.ordering.selectedID == entry,
                  self.inventoryEpoch == epoch else { return }
            if let pending = self.pendingOfflineAdvance { self.finishOfflineAdvance(pending.id); return }
            guard self.wantsPlayback, !self.interruption.active, let track = self.currentTrack,
                  self.currentStreamURL != nil, !self.currentItemIsCachedFile,
                  self.offlineAvailability?.contains(track.id) == true else { return }
            self.samplePlayback()
            guard self.generation == token, self.ordering.selectedID == entry, self.wantsPlayback else { return }
            self.log.info("event=offline_cache_handoff attempted=1")
            self.beginResolving(forceRefresh: false, at: self.position)
        }
    }

    func resumePlayback() {
        controlRevision &+= 1
        if isLiveRadio {
            guard !interruption.active else { return }
            if wantsPlayback && (resolutionTask != nil || preparing || isPlaying || liveRetryTask != nil) { return }
            recoveryAttempts = 0
            wantsPlayback = true
            beginLiveConnecting()
            return
        }
        guard currentTrack != nil, !interruption.active else { return }
        if awaitingAutoplay != nil { return }
        retireOfflineNavigation()
        if !wantsPlayback { startupTiming = nil }
        wantsPlayback = true
        errorMessage = nil
        if ended {
            guard retireSelection() else { return }
            selectCurrent(autoplay: true)
        } else if player.currentItem == nil || player.currentItem?.status == .failed
                    || (isNetworkOffline && !currentItemIsCachedFile)
                    || (streamExpiresAt?.timeIntervalSinceNow ?? .infinity) <= 30 {
            beginResolving(forceRefresh: player.currentItem?.status == .failed || streamExpiresAt != nil, at: position)
        } else if !seeking && !preparing {
            startPlayer()
        }
        refreshActivity()
        refreshOfflineAvailability()
    }

    func handleInterruption(began: Bool, shouldResume: Bool = false) {
        if began {
            startupTiming = nil
            retireOfflineNavigation()
            flushListeningProgress()
            if isLiveRadio { invalidatePipeline() }
            interruption.begin(wantsPlayback: wantsPlayback, generation: generation)
            cancelAutoplayRequest()
            endTransition()
            player.pause()
            listening.discontinuity()
            isPlaying = false
            isLoading = false
            log.info("event=interruption_began")
        } else {
            guard interruption.active else { return }
            let resume = interruption.end(shouldResume: shouldResume, generation: generation)
            wantsPlayback = false
            if resume { resumePlayback() }
            log.info("event=interruption_ended resume=\(resume)")
        }
        publishNowPlaying()
    }

    func handleRouteDetached() {
        log.info("event=route_detached")
        pause()
    }

    func handleMediaServicesReset() {
        let resume = wantsPlayback && !interruption.active
        flushListeningProgress()
        let savedPosition = position
        invalidatePipeline()
        deck.reset()
        player = PlaybackAudioRoute.makePlayer()
        observeActivePlayer()
        system?.configureSession()
        log.notice("event=media_services_reset")
        wantsPlayback = resume
        if resume {
            if isLiveRadio { beginLiveConnecting() }
            else { beginResolving(forceRefresh: true, at: savedPosition) }
        }
        publishNowPlaying()
    }

    func handleLifecycleCheckpoint() {
        if let deadline = sleepUntil { expireSleepTimer(expected: deadline, now: Date()) }
        flushListeningProgress()
        publishNowPlaying()
    }

    func handleBackgroundTransitionExpired() {
        guard wantsPlayback || awaitingAutoplay != nil, isLoading else { return }
        fail("Audio could not finish loading in the background. Open Velvet Thorn and try again.")
    }

    func expireSleepTimer(expected: Date, now: Date) {
        guard sleepUntil == expected, now >= expected else { return }
        sleepUntil = nil
        sleepTask?.cancel()
        sleepTask = nil
        log.info("event=sleep_timer_expired")
        onSleepTimerFired?()
        pause()
    }

    func publishNowPlaying() {
        if let station = liveStation {
            system?.updateLive(station: station, playing: isPlaying)
            return
        }
        system?.update(track: currentTrack, position: position, duration: duration,
                       playing: isPlaying, index: currentIndex, count: queue.count)
    }

    private func publishSnapshot() {
        if onListeningCheckpoint != nil {
            checkpointIntentRevision &+= 1
            checkpointIntentPosition = position
            checkpointIntentControlRevision = controlRevision
            checkpointIntentSessionID = sessionID
            onSnapshotIntentChanged?(musicResumeSnapshot)
            startListeningCheckpointDelivery()
            return
        }
        onSnapshotChanged?(musicResumeSnapshot)
    }

    private var musicResumeSnapshot: PlaybackSnapshot {
        savedMusicSnapshot ?? ordering.snapshot(position: position, repeatMode: repeatMode)
    }

    /// The music session another device would continue, including original order the public queue hides.
    var handoffSnapshot: PlaybackSnapshot { musicResumeSnapshot }

    /// `position` moves on the 500 ms tick; a handover reads the item's clock so the next device starts on the beat.
    var handoffPosition: TimeInterval {
        guard !isLiveRadio, !seeking, player.currentItem?.status == .readyToPlay else { return position }
        let actual = player.currentTime().seconds
        guard actual.isFinite, actual >= 0 else { return position }
        return PlaybackTiming.position(actual, duration: duration)
    }

    private func retireSelection(signal: ListeningSignal.Ending? = nil) -> Bool {
        flushListeningProgress()
        guard listening.pending == 0 else { return false }
        if let signal { emitListeningSignal(signal) }
        startupTiming = nil
        invalidatePipeline()
        liveStation = nil
        savedMusicSnapshot = nil
        refreshEqualizer()
        cachePipeline.cancel()
        wantsPlayback = false
        interruption.cancelResume()
        listening = PlaybackListeningClock()
        return true
    }

    private func selectCurrent(autoplay: Bool, at position: TimeInterval = 0) {
        startupTiming = autoplay && currentTrack != nil ? PlaybackStartupTiming() : nil
        startListeningSession()
        recoveryAttempts = 0
        ended = false
        errorMessage = nil
        resolvedViewCount = nil
        sourceAudioQuality = nil
        playbackSource = nil
        extractionPlaybackGeneration = nil
        isCurrentTrackCached = false
        cachedNextEntryID = nil
        cachePipeline.cancel()
        self.position = currentTrack == nil ? 0 : position
        pendingPosition = self.position
        duration = PlaybackTiming.validDuration(currentTrack?.duration) ?? 0
        wantsPlayback = autoplay && currentTrack != nil
        publishSnapshot()
        publishNowPlaying()
        if wantsPlayback { beginResolving(forceRefresh: false, at: position) }
        else { system?.deactivateSession(); refreshOfflineAvailability() }
        refreshStandby()
        beginSponsorBlockPlay()
    }

    private func startListeningSession(id: UUID = UUID()) {
        if let entryID = ordering.selectedID, generatedRadioEntryIDs.contains(entryID) {
            selectedRadioEntryIDs.removeAll { $0 == entryID }
            selectedRadioEntryIDs.append(entryID)
        }
        pruneSeedRadioHistory()
        pendingCheckpointRecent = nil
        listening = PlaybackListeningClock()
        sessionID = id
        sessionStartedAt = nil
        signalSession = ListeningSignalSession()
        trackStartDelivered = false
        standbyEligible = false
        nextDownloadSettled = false
    }

    /// Callers flush first, so the session's credited seconds are final; the selection has not changed yet.
    private func emitListeningSignal(_ ending: ListeningSignal.Ending) {
        guard !isLiveRadio, let track = currentTrack, signalSession.close() else { return }
        // A skip before any audio still counts towards flicking through, even though it records no signal.
        let rapid = ending == .skipped && recentSkips.record(at: ProcessInfo.processInfo.systemUptime)
        guard signalSession.seconds > 0, let onListeningSignal else { return }
        let known = PlaybackTiming.validDuration(duration) ?? PlaybackTiming.validDuration(track.duration)
        onListeningSignal(ListeningSignal(trackID: track.id, title: track.title, artists: track.artists, endedAt: Date(),
                                          listenedSeconds: signalSession.seconds, duration: known, ending: ending,
                                          origin: listeningSignalOrigin, rapid: rapid))
    }

    /// A radio session is generated throughout; a mix keeps its provenance only on the occurrences it supplied.
    private var listeningSignalOrigin: ListeningSignal.Origin {
        guard let entry = ordering.selectedID, let track = ordering.current else { return .chosen }
        let generated = isRadioSession || generatedRadioEntryIDs.contains(entry) || generatedMixEntryIDs.contains(entry)
            || autoplayTrackIDs.contains(track.id)
        return generated ? .generated : .chosen
    }

    /// A scrub to the end is a skip unless half the song was heard, and records nothing while paused.
    private func naturalListeningEnding() -> ListeningSignal.Ending? {
        guard repeatMode != .one, ProcessInfo.processInfo.systemUptime - lastUserSeekUptime <= 2 else { return .completed }
        if let known = PlaybackTiming.validDuration(duration) ?? PlaybackTiming.validDuration(currentTrack?.duration),
           signalSession.seconds >= known / 2 { return .completed }
        return wantsPlayback && !interruption.active ? .skipped : nil
    }

    private func invalidatePipeline() {
        liveRetryTask?.cancel()
        liveRetryTask = nil
        liveAsset?.cancelLoading()
        liveAsset = nil
        liveSamplePosition = nil
        retireOfflineNavigation()
        system?.endTransition()
        cancelAutoplayRequest()
        generation &+= 1
        seekGeneration &+= 1
        endTransition()
        removeBoundary()
        resolutionTask?.cancel()
        resolutionTask = nil
        readinessTask?.cancel()
        readinessTask = nil
        seekTimeoutTask?.cancel()
        seekTimeoutTask = nil
        itemObservation?.invalidate()
        itemObservation = nil
        itemNotifications.forEach { NotificationCenter.default.removeObserver($0) }
        itemNotifications.removeAll()
        player.currentItem?.cancelPendingSeeks()
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentStreamURL = nil
        sourceAudioQuality = nil
        playbackSource = nil
        extractionPlaybackGeneration = nil
        streamExpiresAt = nil
        streamLoudnessDb = nil
        refreshNormalizationGain(applyToPlayer: true)
        preparing = false
        seeking = false
        isPlaying = false
        isLoading = false
        listening.discontinuity()
    }

    private func beginResolving(forceRefresh: Bool, at position: TimeInterval, discardingCachedFile discard: Bool = false,
                                preferBestAudio: Bool = false) {
        guard let track = currentTrack else { return }
        if wantsPlayback {
            if startupTiming == nil { startupTiming = PlaybackStartupTiming() }
            startupTiming?.beginAttempt()
        } else { startupTiming = nil }
        let discardedURL = discard ? currentStreamURL : nil
        flushListeningProgress()
        guard listening.pending == 0, ensureListeningCapacity(for: sessionID) else { return }
        invalidatePipeline()
        if discard { isCurrentTrackCached = false }
        let token = generation
        let entry = ordering.selectedID
        self.position = PlaybackTiming.position(position)
        pendingPosition = self.position
        ended = false
        errorMessage = nil
        isLoading = wantsPlayback && !interruption.active
        if isLoading { system?.beginTransition() }
        let configuration = settingsTask
        let networkConfiguration = networkConfigurationTask
        let pipeline = cachePipeline
        let retention = pipeline.retainPlaybackFiles()
        resolutionTask = Task { @MainActor [weak self, resolver] in
            do {
                await configuration?.value
                await networkConfiguration?.value
                await retention?.value
                if discard { await pipeline.discard(track, url: discardedURL) }
                try Task.checkCancellation()
                guard self?.generation == token, self?.ordering.selectedID == entry else { return }
                self?.startupTiming?.beginResolution()
                var stream = try await PlaybackDeadline.run(seconds: 75) {
                    if preferBestAudio, let youtube = resolver as? any PlaybackConfigurableResolving {
                        return try await youtube.refreshQuality(track: track)
                    }
                    return try await resolver.resolve(track: track, forceRefresh: forceRefresh)
                }
                try Task.checkCancellation()
                guard self?.generation == token, self?.ordering.selectedID == entry else { return }
                let path = PlaybackStartTrace.startPath(for: track.id)
                stream = try await PlaybackStreamLoading.loadMissingLocalDuration(in: stream)
                try Task.checkCancellation()
                guard let self, self.generation == token, self.ordering.selectedID == entry else { return }
                self.startupTiming?.resolved(path: path)
                self.resolutionTask = nil
                self.install(stream, track: track, generation: token)
            } catch {
                guard !Task.isCancelled, let self, self.generation == token, self.ordering.selectedID == entry else { return }
                self.resolutionTask = nil
                self.fail(self.isNetworkOffline && error is CancellationError ? YouTubeStreamResolver.offlineMessage : error.localizedDescription)
            }
        }
        publishNowPlaying()
        refreshOfflineAvailability()
    }

    private func install(_ stream: ResolvedStream, track: Track, generation token: UInt64) {
        let expiry = stream.expiresAt ?? PlaybackTiming.expiry(in: stream.url)
        if let expiry, expiry.timeIntervalSinceNow <= 5 { fail(PlaybackStreamError.expired.localizedDescription); return }
        duration = PlaybackTiming.duration(stream: stream, track: track) ?? 0
        streamExpiresAt = expiry
        streamLoudnessDb = stream.loudnessDb
        resolvedViewCount = stream.viewCount.flatMap { $0 >= 0 ? $0 : nil }
        sourceAudioQuality = stream.quality
        playbackSource = stream.playbackSource
        extractionPlaybackGeneration = stream.url.isFileURL ? nil : stream.extractionGeneration
        isCurrentTrackCached = cachePipeline.isCachedStream(stream)
        currentStreamURL = stream.url
        position = PlaybackTiming.position(pendingPosition, duration: duration)
        pendingPosition = position
        let (item, usesPreload) = PlaybackStreamLoading.makeItem(stream: stream, trackID: track.id, duration: duration)
        startupTiming?.usedPreload = usesPreload
        equalizer.setNormalizationGain(PlaybackNormalization.gain(loudnessDb: stream.loudnessDb,
            enabled: settings.normalizeVolume), for: item, allowsGainUp: !isLiveRadio)
        preparing = true
        lastAdvanceUptime = ProcessInfo.processInfo.systemUptime
        player.replaceCurrentItem(with: item)
        refreshNormalizationGain(applyToPlayer: true)
        itemObservation = item.observe(\.status, options: [.initial, .new]) { @Sendable [weak self] _, _ in
            Task { @MainActor [weak self] in self?.itemStatusChanged(generation: token) }
        }
        observeItem(item, generation: token)
        readinessTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(25)) } catch { return }
            guard let self, self.generation == token, self.preparing else { return }
            self.recoverPlayback(reason: "readiness_timeout")
        }
        scheduleBoundary()
        publishSnapshot()
        publishNowPlaying()
    }

    private func itemStatusChanged(generation token: UInt64) {
        guard generation == token, let item = player.currentItem else { return }
        if isLiveRadio { liveItemStatusChanged(item, generation: token); return }
        switch item.status {
        case .readyToPlay:
            guard preparing else { return }
            readinessTask?.cancel()
            readinessTask = nil
            preparing = false
            if pendingPosition > 0 { performSeek(to: pendingPosition, generation: token) }
            else if wantsPlayback && !interruption.active { startPlayer() }
        case .failed:
            recoverPlayback(reason: "item_failed")
        case .unknown: break
        @unknown default: fail("This audio format could not be played.")
        }
        refreshActivity()
    }

    /// Selection to the first playing sample, per resolution path, so slow starts can be attributed; `firstPlay` marks the
    /// process's first. A pause before audio drops the measurement rather than counting the paused time.
    private func logPlaybackStart() {
        guard var timing = startupTiming else { return }
        startupTiming = nil
        let ms = timing.sample()
        let path = timing.path?.rawValue ?? "unknown"
        let setupMS = Int(timing.setup / .milliseconds(1))
        let resolutionMS = Int(timing.resolution / .milliseconds(1))
        let readyBufferMS = Int(timing.readyBuffer / .milliseconds(1))
        lastPlaybackStart = "path=\(path) ms=\(ms)"
        log.info("event=playback_start path=\(path, privacy: .public) codec=\(self.sourceAudioQuality?.codec == .opus ? "opus" : "aac", privacy: .public) ms=\(ms) attempts=\(timing.attempts) setup_ms=\(setupMS) resolution_ms=\(resolutionMS) ready_buffer_ms=\(readyBufferMS) cached=\(self.isCurrentTrackCached ? 1 : 0) preload=\(timing.usedPreload ? 1 : 0) firstPlay=\(Self.firstStartEmitted ? 0 : 1)")
        Self.firstStartEmitted = true
    }

    private func logStartupAttempt(outcome: String) {
        guard var timing = startupTiming else { return }
        let ms = timing.sample()
        let setupMS = Int(timing.setup / .milliseconds(1))
        let resolutionMS = Int(timing.resolution / .milliseconds(1))
        let readyBufferMS = Int(timing.readyBuffer / .milliseconds(1))
        let path = timing.path?.rawValue ?? "unknown"
        log.info("event=playback_start_attempt outcome=\(outcome, privacy: .public) path=\(path, privacy: .public) ms=\(ms) attempts=\(timing.attempts) setup_ms=\(setupMS) resolution_ms=\(resolutionMS) ready_buffer_ms=\(readyBufferMS)")
    }

    private func performSeek(to target: TimeInterval, generation token: UInt64) {
        seekGeneration &+= 1
        let seekToken = seekGeneration
        seekTimeoutTask?.cancel()
        player.currentItem?.cancelPendingSeeks()
        listening.discontinuity()
        seeking = true
        isPlaying = false
        if wantsPlayback && !interruption.active { system?.beginTransition() }
        player.pause()
        player.seek(to: CMTime(seconds: target, preferredTimescale: 44_100), toleranceBefore: .zero, toleranceAfter: .zero) {
            @Sendable [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token, self.seekGeneration == seekToken else { return }
                self.seekTimeoutTask?.cancel()
                self.seekTimeoutTask = nil
                self.seeking = false
                self.listening.discontinuity()
                if finished {
                    self.lastSeekUptime = ProcessInfo.processInfo.systemUptime
                    self.position = PlaybackTiming.position(self.player.currentTime().seconds, duration: self.duration)
                    self.pendingPosition = self.position
                    // An exact-boundary seek can deliver its end notification before the seek completion.
                    if self.duration > 0 && target >= self.duration && self.position >= self.duration - 0.001 { self.finishedItem() }
                    else if self.wantsPlayback && !self.interruption.active { self.startPlayer() }
                } else { self.recoverPlayback(reason: "seek_failed") }
                self.publishSnapshot()
                self.refreshActivity()
            }
        }
        seekTimeoutTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            guard let self, self.generation == token, self.seekGeneration == seekToken, self.seeking else { return }
            self.recoverPlayback(reason: "seek_timeout")
        }
        refreshActivity()
    }

    private func startPlayer() {
        guard wantsPlayback, !interruption.active, !seeking, !preparing else { return }
        guard ensureListeningCapacity(for: sessionID) else { return }
        do { try system?.activateSession() }
        catch { fail("Audio is unavailable right now. Please try again."); return }
        lastAdvanceUptime = ProcessInfo.processInfo.systemUptime
        player.play()
        samplePlayback()
        refreshStandby()
        if sponsorBlockPending { refreshSponsorBlockSegments() }
    }

    private func observeActivePlayer() {
        playerObservation?.invalidate()
        player.automaticallyWaitsToMinimizeStalling = true
        let identity = ObjectIdentifier(player)
        playerObservation = player.observe(\.timeControlStatus, options: [.new]) { @Sendable [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, ObjectIdentifier(self.player) == identity else { return }
                self.samplePlayback()
                self.refreshActivity()
            }
        }
    }

    private func observeItem(_ item: AVPlayerItem, generation token: UInt64) {
        for name in [AVPlayerItem.didPlayToEndTimeNotification, AVPlayerItem.failedToPlayToEndTimeNotification,
                     AVPlayerItem.timeJumpedNotification] {
            let observer = NotificationCenter.default.addObserver(forName: name, object: item, queue: .main) {
                @Sendable [weak self] notification in
                let name = notification.name
                MainActor.assumeIsolated {
                    guard let self, self.generation == token else { return }
                    if name == AVPlayerItem.didPlayToEndTimeNotification { self.finishedItem() }
                    else if name == AVPlayerItem.failedToPlayToEndTimeNotification { self.recoverPlayback(reason: "transport_failed") }
                    else {
                        // Re-baseline right away so only the jump itself goes uncredited, not the rest of the tick.
                        self.listening.discontinuity()
                        self.samplePlayback()
                    }
                }
            }
            itemNotifications.append(observer)
        }
    }

    private func finishedItem() {
        if isLiveRadio { recoverLivePlayback(); return }
        guard !ended, !seeking, pendingOfflineAdvance == nil else { return }
        let continuePlaying = wantsPlayback && !interruption.active
        let signal = naturalListeningEnding()
        if continuePlaying, isNetworkOffline { beginOfflineAdvance(automatic: true, signal: signal); return }
        if continuePlaying, let next = nextAutomaticOrder(), let prepared = deck.take(entryID: next.entry, transitionAt: Date()) {
            activateStandby(prepared, order: next.order, blend: 0, signal: signal)
            return
        }
        ended = true
        flushListeningProgress()
        if let signal { emitListeningSignal(signal) }
        var nextOrder = ordering
        if continuePlaying && nextOrder.advance(repeatMode: repeatMode, automatic: true) {
            guard retireSelection() else { return }
            ordering = nextOrder
            selectCurrent(autoplay: true)
        } else {
            if continuePlaying, settings.autoplay || isRadioSession, repeatMode == .off, let entry = ordering.selectedID {
                if autoplayTask != nil, autoplayRequestedEntry == entry {
                    awaitingAutoplay = (generation, entry)
                } else if !isRadioSession, autoplayExhaustedEntry == entry, let track = currentTrack,
                          requestAutoplay(track, entry: entry, final: true) {
                    // The early answer was empty; the queue is now truly exhausted, so ask once more before pausing.
                    awaitingAutoplay = (generation, entry)
                }
            }
            wantsPlayback = false
            player.pause()
            listening.discontinuity()
            isPlaying = false
            isLoading = awaitingAutoplay != nil
            if duration > 0 { position = duration }
            publishSnapshot()
            publishNowPlaying()
            if awaitingAutoplay != nil { system?.beginTransition() }
            else { system?.deactivateSession() }
        }
    }

    private func recoverPlayback(reason: String) {
        if isLiveRadio { recoverLivePlayback(); return }
        guard currentTrack != nil else { return }
        flushListeningProgress()
        guard wantsPlayback, !interruption.active, recoveryAttempts < 2 else {
            fail("Playback couldn’t continue. Check your connection and try again.")
            return
        }
        recoveryAttempts += 1
        // A local copy that will not load or play is corrupt as far as the player is concerned; it must not be retried.
        let discardCachedFile = currentItemIsCachedFile && Self.fileFailureReasons.contains(reason)
        log.notice("event=stream_refresh reason=\(reason, privacy: .public) attempt=\(self.recoveryAttempts) discardCache=\(discardCachedFile)")
        logStartupAttempt(outcome: "retry")
        beginResolving(forceRefresh: true, at: seeking ? pendingPosition : position, discardingCachedFile: discardCachedFile)
    }

    private static let fileFailureReasons: Set<String> = ["item_failed", "transport_failed", "readiness_timeout"]

    private var currentItemIsCachedFile: Bool {
        guard let url = (player.currentItem?.asset as? AVURLAsset)?.url else { return false }
        return cachePipeline.isCachedStream(ResolvedStream(url: url))
    }

    private func fail(_ message: String) {
        logStartupAttempt(outcome: "failed")
        startupTiming = nil
        flushListeningProgress()
        invalidatePipeline()
        wantsPlayback = false
        interruption.cancelResume()
        errorMessage = message
        isPlaying = false
        isLoading = false
        log.error("event=playback_failed")
        publishNowPlaying()
        system?.deactivateSession()
    }

    private func samplePlayback() {
        if isLiveRadio {
            let advancing = wantsPlayback && !interruption.active && !preparing
                && player.timeControlStatus == .playing && player.rate > 0
            let sample = player.currentTime().seconds
            if advancing, sample.isFinite, liveSamplePosition == nil || sample > (liveSamplePosition ?? 0) {
                lastAdvanceUptime = ProcessInfo.processInfo.systemUptime
                liveSamplePosition = sample
                system?.endTransition()
            }
            isPlaying = advancing
            return
        }
        guard player.currentItem != nil, !seeking, !preparing else { return }
        let actualPosition = player.currentTime().seconds
        guard actualPosition.isFinite, actualPosition >= 0 else { return }
        let uptime = ProcessInfo.processInfo.systemUptime
        let advancing = wantsPlayback && !interruption.active && player.timeControlStatus == .playing && player.rate > 0
        if advancing, startupTiming != nil { logPlaybackStart() }
        let delta = listening.sample(position: actualPosition, uptime: uptime, advancing: advancing)
        position = PlaybackTiming.position(actualPosition, duration: duration)
        pendingPosition = position
        if delta > 0 {
            lastAdvanceUptime = uptime
            system?.endTransition()
            if sessionStartedAt == nil { sessionStartedAt = Date().addingTimeInterval(-delta) }
            signalSession.credit(delta)
        }
        isPlaying = advancing && (delta > 0 || (isPlaying && uptime - lastAdvanceUptime < 1))
        if delta > 0, !trackStartDelivered, let track = currentTrack {
            trackStartDelivered = true
            standbyEligible = true
            log.info("event=track_started")
            onTrackStarted?(track)
            if onListeningCheckpoint != nil {
                pendingCheckpointRecent = RecentListen(track: track, playedAt: Date(), position: position)
                publishSnapshot()
            }
            refreshStandby()
        }
    }

    private func refreshActivity() {
        isLoading = !interruption.active && errorMessage == nil
            && (awaitingAutoplay != nil || (wantsPlayback
                && (pendingOfflineAdvance != nil || liveRetryTask != nil || resolutionTask != nil || preparing || seeking || player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                    || (player.currentItem != nil && !isPlaying && !ended))))
        if !wantsPlayback || interruption.active || player.timeControlStatus != .playing { isPlaying = false }
        publishNowPlaying()
    }

    private func tick() {
        equalizer.reportMetrics()
        if let deadline = sleepUntil, Date() >= deadline { expireSleepTimer(expected: deadline, now: Date()) }
        if isLiveRadio {
            samplePlayback()
            refreshActivity()
            let uptime = ProcessInfo.processInfo.systemUptime
            if recoveryAttempts > 0, isPlaying, let ready = liveReadyUptime, uptime - ready >= Self.liveRetryRefundSeconds {
                recoveryAttempts = 0
                log.info("event=live_radio_connection outcome=retry_budget_refunded")
            }
            if wantsPlayback, !interruption.active, !preparing, resolutionTask == nil, liveRetryTask == nil,
               player.currentItem != nil, uptime - lastAdvanceUptime >= 20 { recoverLivePlayback() }
            if uptime - lastCheckpointUptime >= 5, !pendingListening.checkpoints.isEmpty
                || checkpointIntentRevision != savedCheckpointIntentRevision { flushListeningProgress() }
            return
        }
        if currentTrack != nil {
            let previousPosition = position
            samplePlayback()
            refreshActivity()
            if isPlaying, !seeking, position > previousPosition, let stamp = extractionPlaybackGeneration {
                extractionPlaybackGeneration = nil
                onFreshExtractionPlayed?(stamp)
            }
            settleNextDownloadIfNeeded()
            refreshPreloads()
        }
        let uptime = ProcessInfo.processInfo.systemUptime
        if uptime - lastCheckpointUptime >= 5 && (wantsPlayback || listening.pending > 0 || !pendingListening.checkpoints.isEmpty
            || (onListeningCheckpoint != nil && (checkpointIntentRevision != savedCheckpointIntentRevision || pendingCheckpointRecent != nil))) {
            flushListeningProgress()
        }
        guard currentTrack != nil else { return }
        if deck.needsRefresh(transitionAt: expectedTransitionDate) { standbyChanged() }
        guard wantsPlayback, !interruption.active, resolutionTask == nil, !preparing, !seeking, !ended,
              player.currentItem != nil else { return }
        if (streamExpiresAt?.timeIntervalSinceNow ?? .infinity) <= 5 {
            recoverPlayback(reason: "expired")
        } else if uptime - lastAdvanceUptime >= 20 {
            recoverPlayback(reason: "stalled")
        } else {
            applySegmentSkip(uptime: uptime)
        }
    }

    // MARK: - SponsorBlock

    /// A new play of the selected entry: fresh skip state, then a lookup for YouTube songs when the setting is on.
    private func beginSponsorBlockPlay() {
        segmentSkipper = SegmentSkipper()
        sponsorBlockSkipCount = 0
        refreshSponsorBlockSegments()
    }

    private func clearSponsorBlockSegments() {
        sponsorBlockTask?.cancel()
        sponsorBlockTask = nil
        sponsorBlockPending = false
        segmentSkipper = SegmentSkipper()
        sponsorBlockSkipCount = 0
    }

    /// Looks up the current song's segments without holding playback. A paused restore or a browsed queue sends
    /// nothing: the lookup waits until the song actually plays, and known-offline playback never asks.
    private func refreshSponsorBlockSegments() {
        sponsorBlockTask?.cancel()
        sponsorBlockTask = nil
        sponsorBlockPending = false
        guard sponsorBlockEnabled, let track = currentTrack, track.source == .youTubeMusic,
              let videoID = CatalogText.videoID(track.providerID) else { return }
        guard wantsPlayback, !isNetworkOffline else { sponsorBlockPending = true; return }
        let entry = ordering.selectedID
        let token = UUID()
        sponsorBlockToken = token
        let provider = sponsorBlockProvider
        let duration = PlaybackTiming.validDuration(track.duration)
        sponsorBlockTask = Task { @MainActor [weak self] in
            let segments = try? await provider.segments(forVideoID: videoID, duration: duration)
            guard !Task.isCancelled, let self, self.sponsorBlockToken == token, self.ordering.selectedID == entry else { return }
            self.sponsorBlockTask = nil
            self.segmentSkipper.install(segments ?? [])
            self.log.info("event=sponsorblock_segments status=\(segments == nil ? "failed" : "ok", privacy: .public) segments=\(segments?.count ?? 0)")
        }
    }

    /// Jumps the live item past a segment through the ordinary seek path, so the clock treats it as a seek and the
    /// generation checks still guard the callbacks. A blend in progress and the standby deck are left alone.
    private func applySegmentSkip(uptime: TimeInterval) {
        guard isPlaying, transition == nil, pendingOfflineAdvance == nil, player.currentItem?.status == .readyToPlay,
              let segment = segmentSkipper.skipTarget(at: position, uptime: uptime) else { return }
        sponsorBlockSkipCount = segmentSkipper.skippedCount
        log.info("event=sponsorblock_skip category=\(segment.category.logValue, privacy: .public) skipped=1")
        flushListeningProgress()
        guard listening.pending == 0 else { return }
        let target = PlaybackTiming.position(segment.end, duration: duration)
        position = target
        pendingPosition = target
        listening.discontinuity()
        performSeek(to: target, generation: generation)
        publishSnapshot()
        publishNowPlaying()
    }

    // MARK: - Transitions

    private func refreshNormalizationGain(applyToPlayer: Bool) {
        normalizationGain = PlaybackNormalization.gain(loudnessDb: streamLoudnessDb, enabled: settings.normalizeVolume)
        deck.normalizeVolume = settings.normalizeVolume
        if applyToPlayer {
            if let item = player.currentItem {
                equalizer.setNormalizationGain(normalizationGain, for: item, allowsGainUp: !isLiveRadio)
            }
            player.volume = Float(min(1, normalizationGain))
        }
    }

    /// Nil when the automatic advance stays on the current entry (repeat one) or the queue is exhausted.
    private func nextAutomaticOrder() -> (entry: UUID, order: PlaybackQueue)? {
        guard !isLiveRadio else { return nil }
        var order = ordering
        if isNetworkOffline {
            guard let available = offlineAvailability,
                  let cached = OfflineQueueNavigation.advancing(order, repeatMode: repeatMode, automatic: true, cachedTrackIDs: available) else { return nil }
            order = cached
        } else if !order.advance(repeatMode: repeatMode, automatic: true) { return nil }
        guard let entry = order.selectedID,
              entry != ordering.selectedID else { return nil }
        return (entry, order)
    }

    private func automaticBlendDuration() -> TimeInterval {
        if settings.crossfadeSeconds > 0 { return settings.crossfadeSeconds }
        if settings.automix, queue.count > 1 { return 4 }
        return 0
    }

    private var expectedTransitionDate: Date {
        Date().addingTimeInterval(max(0, duration - position - automaticBlendDuration()))
    }

    /// Keeps the standby deck equal to the real next entry: invalidates a stale one and prepares the current one
    /// once this track has started. Without any blending feature the older warmup path applies instead.
    private func refreshStandby() {
        refreshPreloads()
        guard !isLiveRadio else { deck.invalidate(); return }
        guard pendingOfflineAdvance == nil else { return }
        requestAutoplayIfNeeded()
        let next = nextAutomaticOrder()
        let retention = cachePipeline.retainPlaybackFiles()
        syncCacheDownloads(next: next)
        let wantsStandby = settings.gapless || settings.crossfadeSeconds > 0 || settings.automix
        if isNetworkOffline, offlineAvailability == nil {
            let retainsLocalDeck = wantsStandby && deck.entryID != ordering.selectedID
                && ordering.entries.contains { $0.id == deck.entryID }
                && (deck.streamURL.map { cachePipeline.isCachedStream(ResolvedStream(url: $0)) } ?? false)
            if !retainsLocalDeck { deck.invalidate() }
            scheduleBoundary()
            return
        }
        if let prepared = deck.entryID, !wantsStandby || prepared != next?.entry { deck.invalidate() }
        if isNetworkOffline, deck.entryID != nil,
           !(deck.streamURL.map { cachePipeline.isCachedStream(ResolvedStream(url: $0)) } ?? false) {
            deck.invalidate()
        }
        defer { scheduleBoundary() }
        guard wantsStandby else { return }
        guard let next, let track = next.order.current, deck.entryID == nil, standbyEligible,
              wantsPlayback, !interruption.active, errorMessage == nil else { return }
        let configuration = settingsTask
        let networkConfiguration = networkConfigurationTask
        let ready = Task {
            await configuration?.value
            await networkConfiguration?.value
            await retention?.value
        }
        standbyNetworkGeneration = networkGeneration
        deck.prepare(track: track, entryID: next.entry, forceRefresh: false, after: ready)
    }

    // MARK: - Audio cache

    func audioCacheUsage() async throws -> AudioCache.Usage? {
        try await cachePipeline.storageUsage()
    }

    func cachedSongsSnapshot() async throws -> AudioCacheSnapshot? {
        let epoch = inventoryEpoch
        inventoryRequest &+= 1
        let request = inventoryRequest
        do {
            let pipeline = cachePipeline
            let snapshot = try await PlaybackDeadline.run(seconds: 5) { try await pipeline.storageSnapshot() }
            if !Task.isCancelled, epoch == inventoryEpoch, request >= publishedInventoryRequest {
                publishedInventoryRequest = request
                updateOfflineAvailability(snapshot.map { Set($0.songs.filter(\.isPlayable).map(\.id)) })
            }
            return snapshot
        } catch {
            if !Task.isCancelled, epoch == inventoryEpoch, request >= publishedInventoryRequest {
                publishedInventoryRequest = request
                updateOfflineAvailability(nil)
            }
            throw error
        }
    }

    private func updateOfflineAvailability(_ available: Set<String>?) {
        let previous = offlineAvailability
        offlineAvailability = available
        guard isNetworkOffline, previous != available else { return }
        if deck.didFail, let id = deck.track?.id, available?.contains(id) == true, previous?.contains(id) != true {
            deck.invalidate()
        }
        _ = cachePipeline.retainPlaybackFiles()
        refreshStandby()
    }

    private func retireOfflineNavigation() {
        inventoryEpoch = UUID()
        offlineRefreshGeneration = UUID()
        offlineHandoffTask?.cancel()
        offlineHandoffTask = nil
        offlineAdvanceTask?.cancel()
        offlineAdvanceTask = nil
        pendingOfflineAdvance = nil
    }

    private func refreshQueuePreparation() {
        if isNetworkOffline, ended, wantsPlayback, !interruption.active, errorMessage == nil {
            beginOfflineAdvance(automatic: true)
        } else {
            refreshStandby()
            refreshOfflineAvailability()
        }
    }

    /// Explicit Next uses the same cached-only traversal while retaining its paused/playing intent.
    private func beginOfflineAdvance(automatic: Bool, signal: ListeningSignal.Ending? = nil) {
        guard currentTrack != nil else { return }
        guard !interruption.active else { pause(); return }
        let resume = wantsPlayback && !interruption.active
        let startedGeneration = generation
        let startedEntry = ordering.selectedID
        retireOfflineNavigation()
        endTransition()
        if automatic { ended = true }
        flushListeningProgress()
        guard listening.pending == 0, generation == startedGeneration, ordering.selectedID == startedEntry,
              wantsPlayback == resume else { return }
        errorMessage = nil
        player.pause()
        listening.discontinuity()
        isPlaying = false
        if automatic, duration > 0 { position = duration; pendingPosition = duration }
        var probe = ordering
        let advances = probe.advance(repeatMode: repeatMode, automatic: automatic)
        // Like the online path, a natural end always counts, while Next at the end of the queue only pauses.
        if let signal, advances || automatic { emitListeningSignal(signal) }
        guard advances else { pause(); return }
        let id = UUID()
        let token = generation
        let entry = ordering.selectedID
        let epoch = inventoryEpoch
        pendingOfflineAdvance = (id, token, entry, automatic, resume)
        isLoading = resume
        if resume { system?.beginTransition() }
        offlineAdvanceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            _ = try? await self.cachedSongsSnapshot()
            guard !Task.isCancelled, self.inventoryEpoch == epoch else { return }
            self.finishOfflineAdvance(id)
        }
        publishSnapshot()
        publishNowPlaying()
    }

    private func finishOfflineAdvance(_ id: UUID) {
        guard let pending = pendingOfflineAdvance, pending.id == id, pending.generation == generation,
              pending.entry == ordering.selectedID, pending.resume == wantsPlayback, !interruption.active else { return }
        var nextOrder = ordering
        if isNetworkOffline {
            guard let available = offlineAvailability else {
                log.notice("event=offline_queue_advance available=0 known=0")
                fail("Cached songs couldn’t be checked. Try again or connect to the internet.")
                return
            }
            guard let next = OfflineQueueNavigation.advancing(ordering, repeatMode: repeatMode,
                automatic: pending.automatic, cachedTrackIDs: available) else {
                log.notice("event=offline_queue_advance available=0 known=1")
                fail("You’re offline. There are no more cached songs in this queue.")
                return
            }
            nextOrder = next
            log.debug("event=offline_queue_advance available=1 known=1")
        } else if !nextOrder.advance(repeatMode: repeatMode, automatic: pending.automatic) { pause(); return }
        if pending.resume, let entry = nextOrder.selectedID, entry != ordering.selectedID,
           let prepared = deck.take(entryID: entry, transitionAt: Date()) {
            activateStandby(prepared, order: nextOrder, blend: 0)
        } else {
            guard retireSelection() else { return }
            ordering = nextOrder
            selectCurrent(autoplay: pending.resume)
        }
    }

    @discardableResult
    func updateCacheListeningHistory(_ events: [ListeningEvent], now: Date = Date()) -> Task<Void, Never>? {
        guard cachePipeline.canManageStorage else { return nil }
        let token = UUID()
        cacheHistoryGeneration = token
        let previous = cacheHistoryTask
        let pipeline = cachePipeline
        let work = Task { @MainActor [weak self] in
            defer { if self?.cacheHistoryGeneration == token { self?.cacheHistoryTask = nil } }
            await previous?.value
            guard !Task.isCancelled, self?.cacheHistoryGeneration == token else { return }
            await pipeline.updateListeningHistory(events, now: now)
        }
        cacheHistoryTask = work
        return work
    }

    private func waitForCacheHistoryUpdates() async {
        while let work = cacheHistoryTask {
            let token = cacheHistoryGeneration
            await work.value
            if Task.isCancelled || token == cacheHistoryGeneration { return }
        }
    }

    /// Registers the policy before returning so prefetches and queued downloads wait even during startup.
    @discardableResult
    func setAudioCacheLimit(_ limit: AudioCacheLimit) -> Task<AudioCache.Usage?, Error> {
        let token = UUID()
        cacheLimitGeneration = token
        audioCacheLimitError = nil
        audioCacheLimitUsage = nil
        guard cachePipeline.canManageStorage else { return Task<AudioCache.Usage?, Error> { nil } }
        isUpdatingAudioCacheLimit = true
        let pipeline = cachePipeline
        pipeline.suspendForPolicyUpdate(token)
        let previous = cacheStorageTask
        cacheStorageGeneration = token
        let work = Task<AudioCache.Usage?, Error> { @MainActor [weak self] in
            defer {
                pipeline.finishPolicyUpdate(token)
                if self?.cacheLimitGeneration == token { self?.isUpdatingAudioCacheLimit = false }
                if self?.cacheStorageGeneration == token { self?.cacheStorageTask = nil }
            }
            _ = try? await previous?.value
            await self?.waitForCacheHistoryUpdates()
            do {
                try Task.checkCancellation()
                guard let self, self.cacheLimitGeneration == token else { throw CancellationError() }
                let usage = try await pipeline.setAudioCacheLimit(limit) { [weak self] in
                    await self?.storageRetainedTrackIDs ?? []
                }
                guard !Task.isCancelled, self.cacheLimitGeneration == token else { throw CancellationError() }
                if let usage, usage.capacityBytes != limit.bytes || usage.maximumSongs != limit.maximumSongs {
                    throw AudioCache.ManagementError.limitNotApplied
                }
                self.audioCacheLimitUsage = usage
                return usage
            } catch {
                if self?.cacheLimitGeneration == token, !(error is CancellationError) {
                    self?.audioCacheLimitError = error.localizedDescription
                }
                throw error
            }
        }
        cacheStorageTask = work
        return work
    }

    func clearTemporaryAudioCache() async throws -> AudioCache.Usage? {
        guard cachePipeline.canManageStorage else { return nil }
        cancelPrefetch()
        let token = UUID()
        let previous = cacheStorageTask
        let pipeline = cachePipeline
        cacheStorageGeneration = token
        let work = Task<AudioCache.Usage?, Error> { @MainActor [weak self] in
            defer { if self?.cacheStorageGeneration == token { self?.cacheStorageTask = nil } }
            _ = try? await previous?.value
            try Task.checkCancellation()
            return try await pipeline.clearStorage { [weak self] in
                await self?.storageRetainedTrackIDs ?? []
            }
        }
        cacheStorageTask = work
        return try await work.value
    }

    private func cancelPrefetch() {
        preloader.update(queue: [], queueAllowed: false, holding: false)
        prefetchTask?.cancel()
        prefetchTask = nil
        prefetchIDs = []
        prefetchToken = UUID()
    }

    func removeCachedSong(id: String) async throws -> AudioCacheRemoval? {
        guard cachePipeline.canManageStorage else { return nil }
        cancelPrefetch()
        let token = UUID()
        let previous = cacheStorageTask
        let pipeline = cachePipeline
        cacheStorageGeneration = token
        let work = Task<AudioCacheRemoval?, Error> { @MainActor [weak self] in
            defer { if self?.cacheStorageGeneration == token { self?.cacheStorageTask = nil } }
            _ = try? await previous?.value
            try Task.checkCancellation()
            return try await pipeline.removeCachedSong(id: id) { [weak self] in
                await self?.storageRetainedTrackIDs ?? []
            }
        }
        cacheStorageTask = Task { try await work.value?.usage }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: { work.cancel() }
    }

    private func waitForCacheStorageUpdates() async {
        while let work = cacheStorageTask {
            let token = cacheStorageGeneration
            _ = try? await work.value
            if Task.isCancelled || token == cacheStorageGeneration { return }
        }
    }

    private var storageRetainedTrackIDs: Set<String> {
        var ids = Set([currentTrack?.id, standbyTrack?.id, nextAutomaticOrder()?.order.current?.id].compactMap { $0 })
        let activeURL = (player.currentItem?.asset as? AVURLAsset)?.url
        let outgoingURL = (transition?.outgoing.currentItem?.asset as? AVURLAsset)?.url
        for url in [currentStreamURL, standbyStreamURL, activeURL, outgoingURL].compactMap({ $0 }) {
            if cachePipeline.isCachedStream(ResolvedStream(url: url)) {
                if let id = AudioCache.logicalTrackID(for: url) { ids.insert(id) }
            }
        }
        return ids
    }

    private func syncCacheDownloads(next: (entry: UUID, order: PlaybackQueue)?) {
        guard cachePipeline.isAvailable, trackStartDelivered, wantsPlayback, !ended, errorMessage == nil, !interruption.active,
              let current = currentTrack else { return }
        // A quick skip should cost only the next song's preparation; its complete file waits until this one settles.
        let target = nextDownloadSettled
            ? next.flatMap { step in step.order.current.map { PlaybackCachePipeline.Target(track: $0, entryID: step.entry) } }
            : nil
        cachePipeline.sync(current: current, next: target)
    }

    /// `settleSeconds` (30 by default), or half of a shorter song.
    static func nextDownloadSettlePosition(duration: TimeInterval, settleSeconds: TimeInterval) -> TimeInterval {
        duration > 0 ? min(settleSeconds, duration / 2) : settleSeconds
    }

    private func settleNextDownloadIfNeeded() {
        guard !nextDownloadSettled, trackStartDelivered, isPlaying,
              position >= Self.nextDownloadSettlePosition(duration: duration, settleSeconds: nextDownloadSettleSeconds) else { return }
        nextDownloadSettled = true
        log.debug("event=next_download_settled")
        refreshStandby()
    }

    /// Short tracks would never qualify under a fixed 20 s rule, so the margin shrinks with the track.
    private var standbySwapMargin: TimeInterval { duration > 0 ? min(20, duration / 4) : 20 }

    private func nextTrackCached(_ target: PlaybackCachePipeline.Target, stream: ResolvedStream) {
        guard let next = nextAutomaticOrder(), next.entry == target.entryID else { return }
        cachedNextEntryID = target.entryID
        guard deck.entryID == target.entryID, transition == nil, deck.streamURL != stream.url,
              expectedTransitionDate.timeIntervalSinceNow > standbySwapMargin else { return }
        deck.adopt(stream, entryID: target.entryID)
    }

    private func currentTrackCached(_ track: Track) {
        guard currentTrack?.id == track.id else { return }
        isCurrentTrackCached = true
    }

    private func standbyChanged() {
        // The deck reports right after it installs an item, so the standby tap is in place before preroll.
        if let item = deck.player?.currentItem { equalizer.attach(to: item) }
        if deck.didFail, !isNetworkOffline, standbyNetworkGeneration != networkGeneration {
            deck.invalidate()
            refreshStandby()
            return
        }
        guard let track = deck.track, let entry = deck.entryID, deck.needsRefresh(transitionAt: expectedTransitionDate) else { return }
        guard !isNetworkOffline || offlineAvailability?.contains(track.id) == true else { deck.invalidate(); return }
        log.info("event=standby_refresh")
        let configuration = settingsTask
        let network = networkConfigurationTask
        let retention = cachePipeline.retainPlaybackFiles()
        let ready = Task { await configuration?.value; await network?.value; await retention?.value }
        standbyNetworkGeneration = networkGeneration
        deck.prepare(track: track, entryID: entry, forceRefresh: true, after: ready)
    }

    /// Re-armed on every queue or settings change because the blend length and the next entry both feed into it.
    private func scheduleBoundary() {
        removeBoundary()
        let blend = automaticBlendDuration()
        let token = generation
        guard player.currentItem != nil, blend > 0, duration > blend + 0.5, nextAutomaticOrder() != nil else { return }
        let time = CMTime(seconds: duration - blend, preferredTimescale: 44_100)
        let observer = player.addBoundaryTimeObserver(forTimes: [NSValue(time: time)], queue: .main) { @Sendable [weak self] in
            MainActor.assumeIsolated { self?.boundaryReached(generation: token) }
        }
        boundary = (player, observer)
    }

    private func removeBoundary() {
        if let boundary { boundary.player.removeTimeObserver(boundary.observer) }
        boundary = nil
    }

    private func boundaryReached(generation token: UInt64) {
        guard generation == token, transition == nil, wantsPlayback, !interruption.active, !seeking, !preparing, !ended,
              pendingOfflineAdvance == nil, resolutionTask == nil, player.currentItem != nil else { return }
        let blend = automaticBlendDuration()
        let remaining = duration - player.currentTime().seconds
        // A seek into or across the blend window is served by the end-of-item swap instead of a truncated ramp.
        guard blend > 0, remaining.isFinite, remaining > 0.25, remaining <= blend + 0.5,
              ProcessInfo.processInfo.systemUptime - lastSeekUptime >= 1,
              let next = nextAutomaticOrder(), let prepared = deck.take(entryID: next.entry, transitionAt: Date()) else { return }
        // The blend ends the session early, which still counts as hearing the song through.
        activateStandby(prepared, order: next.order, blend: min(blend, remaining), signal: naturalListeningEnding())
    }

    /// Makes the prepared standby the current track. The outgoing player keeps playing only for the blend;
    /// its item callbacks are rejected by the generation bump.
    private func activateStandby(_ prepared: StandbyDeck.Prepared, order: PlaybackQueue, blend: TimeInterval,
                                 signal: ListeningSignal.Ending? = nil) {
        retireOfflineNavigation()
        flushListeningProgress()
        let incomingSession = UUID()
        guard listening.pending == 0, ensureListeningCapacity(for: incomingSession) else {
            prepared.player.pause()
            deck.reclaim(prepared.player)
            return
        }
        if let signal { emitListeningSignal(signal) }
        startupTiming = nil
        endTransition()
        system?.endTransition()
        cancelAutoplayRequest()
        generation &+= 1
        seekGeneration &+= 1
        let token = generation
        resolutionTask?.cancel()
        resolutionTask = nil
        readinessTask?.cancel()
        readinessTask = nil
        seekTimeoutTask?.cancel()
        seekTimeoutTask = nil
        itemObservation?.invalidate()
        itemNotifications.forEach { NotificationCenter.default.removeObserver($0) }
        itemNotifications.removeAll()
        removeBoundary()
        let outgoing = player
        let outgoingGain = outgoing.volume
        ordering = order
        startListeningSession(id: incomingSession)
        standbyEligible = true
        recoveryAttempts = 0
        ended = false
        errorMessage = nil
        preparing = false
        seeking = false
        duration = prepared.duration
        streamExpiresAt = prepared.expiresAt
        streamLoudnessDb = prepared.stream.loudnessDb
        resolvedViewCount = prepared.stream.viewCount.flatMap { $0 >= 0 ? $0 : nil }
        sourceAudioQuality = prepared.stream.quality
        playbackSource = prepared.stream.playbackSource
        extractionPlaybackGeneration = prepared.stream.url.isFileURL ? nil : prepared.stream.extractionGeneration
        isCurrentTrackCached = cachePipeline.isCachedStream(prepared.stream)
        currentStreamURL = prepared.stream.url
        cachedNextEntryID = nil
        cachePipeline.cancel()
        position = 0
        pendingPosition = 0
        wantsPlayback = true
        player = prepared.player
        observeActivePlayer()
        itemObservation = prepared.item.observe(\.status, options: [.new]) { @Sendable [weak self] _, _ in
            Task { @MainActor [weak self] in self?.itemStatusChanged(generation: token) }
        }
        observeItem(prepared.item, generation: token)
        refreshNormalizationGain(applyToPlayer: blend <= 0)
        // timeControlStatus turns .playing asynchronously; seeding the clock keeps isPlaying and credit continuous.
        lastAdvanceUptime = ProcessInfo.processInfo.systemUptime
        listening.sample(position: 0, uptime: lastAdvanceUptime, advancing: true)
        isPlaying = true
        isLoading = false
        if blend > 0 {
            let crossfade = PlaybackCrossfade(outgoing: outgoing, incoming: player, duration: blend,
                                              outgoingGain: outgoingGain, incomingGain: Float(min(1, normalizationGain)))
            transition = crossfade
            player.playImmediately(atRate: 1)
            crossfade.start { [weak self] in self?.endTransition() }
            log.info("event=crossfade_started seconds=\(blend)")
        } else {
            player.playImmediately(atRate: 1)
            outgoing.pause()
            deck.reclaim(outgoing)
            log.info("event=gapless_swap")
        }
        publishSnapshot()
        publishNowPlaying()
        refreshStandby()
        beginSponsorBlockPlay()
    }

    private func endTransition() {
        guard let transition else { return }
        self.transition = nil
        transition.cancel()
        transition.outgoing.pause()
        deck.reclaim(transition.outgoing)
        refreshNormalizationGain(applyToPlayer: true)
        _ = cachePipeline.retainPlaybackFiles()
    }

    // MARK: - Autoplay

    private func resetSeedRadioRetention() {
        radioRefillAhead = 0
        generatedRadioEntryIDs.removeAll()
        selectedRadioEntryIDs.removeAll()
        radioRecentTracks.removeAll()
    }

    @discardableResult
    private func pruneSeedRadioHistory() -> Bool {
        guard radioRefillAhead > 0 else { return false }
        generatedRadioEntryIDs.formIntersection(ordering.entries.map(\.id))
        selectedRadioEntryIDs.removeAll { !generatedRadioEntryIDs.contains($0) }
        // Array position is not play history: shuffle and queue jumps can put unheard entries behind selection.
        let previousIDs = Set(ordering.entries.prefix(ordering.index).map(\.id))
        let previousSelected = selectedRadioEntryIDs.filter { previousIDs.contains($0) }
        let expired = Array(previousSelected.prefix(max(0, previousSelected.count - Self.radioPreviousEntryLimit)))
        guard !expired.isEmpty else { return false }
        var nextOrder = ordering
        let removed = nextOrder.removePreviousEntries(withIDs: Set(expired))
        let removedTracks = Dictionary(uniqueKeysWithValues: removed.map { ($0.id, $0.track) })
        for id in expired {
            guard let track = removedTracks[id] else { continue }
            radioRecentTracks.removeAll { $0.id == track.id }
            radioRecentTracks.append(track)
        }
        radioRecentTracks = Array(radioRecentTracks.suffix(Self.radioRecentTrackLimit))
        let removedIDs = Set(removed.map(\.id))
        generatedRadioEntryIDs.subtract(removedIDs)
        selectedRadioEntryIDs.removeAll { removedIDs.contains($0) }
        ordering = nextOrder
        autoplayTrackIDs.formIntersection(queue.map(\.id))
        log.info("event=seed_radio_pruned count=\(removed.count) recent_count=\(self.radioRecentTracks.count)")
        return !removed.isEmpty
    }

    private func requestAutoplayIfNeeded() {
        guard !isNetworkOffline, settings.autoplay || isRadioSession, repeatMode == .off, wantsPlayback, !interruption.active, standbyEligible,
              let track = currentTrack, let entry = ordering.selectedID, autoplayRequestedEntry != entry,
              onQueueExhausted != nil else { return }
        var probe = ordering
        var upcoming = 0
        while upcoming <= (isRadioSession ? radioRefillAhead : 0), probe.advance(repeatMode: .off, automatic: true) {
            upcoming += 1
        }
        guard upcoming <= (isRadioSession ? radioRefillAhead : 0) else { return }
        requestAutoplay(track, entry: entry, final: false)
    }

    /// One continuation request for `entry`. The final request follows an empty early result once an ordinary queue
    /// has ended and asks for fresh results; its own empty result ends Autoplay for this entry until the listener acts.
    @discardableResult
    private func requestAutoplay(_ track: Track, entry: UUID, final: Bool) -> Bool {
        guard !isNetworkOffline, let request = final ? (onQueueEnded ?? onQueueExhausted) : onQueueExhausted else { return false }
        autoplayRequestedEntry = entry
        autoplayExhaustedEntry = nil
        autoplayTask?.cancel()
        let token = generation
        log.info("event=autoplay_requested final=\(final)")
        autoplayTask = Task { @MainActor [weak self] in
            let tracks = await request(track)
            guard !Task.isCancelled, let self, self.settings.autoplay || self.isRadioSession,
                  self.generation == token, !self.interruption.active, self.repeatMode == .off,
                  self.ordering.selectedID == entry, self.autoplayRequestedEntry == entry else { return }
            self.autoplayTask = nil
            defer { self.finishAutoplayWait() }
            // Radio continuation has its own retry in the queue sheet, so only ordinary queues earn the final request.
            if !self.insertAutoplay(tracks), !final, !self.isRadioSession { self.autoplayExhaustedEntry = entry }
        }
        return true
    }

    private func finishAutoplayWait() {
        guard let waiting = awaitingAutoplay else { return }
        cancelAutoplayRequest()
        guard waiting.generation == generation, waiting.entry == ordering.selectedID, ended,
              !interruption.active, settings.autoplay || isRadioSession, repeatMode == .off else { return }
        if let next = nextAutomaticOrder() {
            guard retireSelection() else { return }
            ordering = next.order
            selectCurrent(autoplay: true)
            log.info("event=autoplay_resumed_after_end")
        } else {
            publishNowPlaying()
            system?.deactivateSession()
        }
    }

    private func cancelAutoplayRequest() {
        autoplayTask?.cancel()
        autoplayTask = nil
        autoplayRequestedEntry = nil
        autoplayExhaustedEntry = nil
        if awaitingAutoplay != nil {
            awaitingAutoplay = nil
            isLoading = false
            system?.endTransition()
        }
    }
}

enum OfflineQueueNavigation {
    static func advancing(_ queue: PlaybackQueue, repeatMode: RepeatMode, automatic: Bool,
                          cachedTrackIDs: Set<String>) -> PlaybackQueue? {
        var next = queue
        for _ in 0..<queue.entries.count {
            guard next.advance(repeatMode: repeatMode, automatic: automatic), let track = next.current else { return nil }
            if cachedTrackIDs.contains(track.id) { return next }
            if automatic, repeatMode == .one { return nil }
        }
        return nil
    }
}

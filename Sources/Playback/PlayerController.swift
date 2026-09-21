import AVFoundation
import Foundation
import Observation
import OSLog

@Observable
@MainActor
final class PlayerController {
    var currentTrack: Track? { ordering.current }
    var queue: [Track] { ordering.tracks }
    var currentIndex: Int { ordering.index }
    var shuffleEnabled: Bool { ordering.shuffled }
    private(set) var position: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var isPlaying = false
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var repeatMode: RepeatMode = .off
    private(set) var sleepUntil: Date?
    private(set) var settings = PlaybackTransitionSettings()
    private(set) var normalizationGain: Double = 1
    /// Worldwide play count reported by the stream provider for the current track; nil until a stream is installed.
    private(set) var resolvedViewCount: Int64?
    private(set) var sourceAudioQuality: SourceAudioQuality?
    var canReloadAudioQuality: Bool {
        resolver is YouTubeStreamResolver && currentTrack != nil && !isLoading
            && !isUpdatingAudioCacheLimit && !cachePipeline.isClearingStorage
    }
    /// True when the current track has a complete local copy: the playing item itself, or one recovery can switch to.
    private(set) var isCurrentTrackCached = false
    private(set) var isUpdatingAudioCacheLimit = false
    private(set) var audioCacheLimitError: String?
    private(set) var audioCacheLimitUsage: AudioCache.Usage?
    /// True once the next entry in play order has a complete local copy ready for the standby deck.
    var isNextTrackCached: Bool { cachedNextEntryID != nil && cachedNextEntryID == nextAutomaticOrder()?.entry }
    /// Queue entries appended by Autoplay rather than the listener; the queue UI labels them.
    private(set) var autoplayTrackIDs: Set<String> = []
    /// An explicitly chosen radio keeps going independently of the general queue Autoplay preference.
    private(set) var isRadioSession = false

    /// Acknowledges durable saves or intentionally disabled history; false keeps the delta queued for retry.
    var onListeningProgress: (@MainActor (Track, UUID, Date, TimeInterval) -> Bool)?
    var onSnapshotChanged: (@MainActor (PlaybackSnapshot) -> Void)?
    var onTrackStarted: (@MainActor (Track) -> Void)?
    /// Asked for continuation tracks when the last entry in play order starts and Autoplay is on.
    var onQueueExhausted: (@MainActor (Track) async -> [Track])?

    var crossfadeState: PlaybackCrossfadeState? { transition?.state }
    var standbyTrack: Track? { deck.track }
    var isStandbyReady: Bool { deck.isReady }
    var hasStandbyPlayer: Bool { deck.player != nil }
    var standbyStreamURL: URL? { deck.streamURL }
    /// The URL the playing item was created from, for diagnostics; nil while nothing is installed.
    private(set) var currentStreamURL: URL?
    var isPreparing: Bool { preparing }

    private var ordering = PlaybackQueue()
    private var cachedNextEntryID: UUID?
    @ObservationIgnored private let resolver: any StreamResolving
    @ObservationIgnored private var player = AVPlayer()
    @ObservationIgnored private let deck: StandbyDeck
    @ObservationIgnored private let cachePipeline: PlaybackCachePipeline
    @ObservationIgnored private var cacheStorageTask: Task<AudioCache.Usage?, Error>?
    @ObservationIgnored private var cacheStorageGeneration = UUID()
    @ObservationIgnored private var cacheLimitGeneration = UUID()
    @ObservationIgnored private var transition: PlaybackCrossfade?
    @ObservationIgnored private var boundary: (player: AVPlayer, observer: Any)?
    @ObservationIgnored private var system: PlaybackSystemControls?
    @ObservationIgnored private var playerObservation: NSKeyValueObservation?
    @ObservationIgnored private var itemObservation: NSKeyValueObservation?
    @ObservationIgnored private var itemNotifications: [NSObjectProtocol] = []
    @ObservationIgnored private var resolutionTask: Task<Void, Never>?
    @ObservationIgnored private var settingsTask: Task<Void, Never>?
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?
    @ObservationIgnored private var prefetchIDs: [String] = []
    @ObservationIgnored private var prefetchToken = UUID()
    @ObservationIgnored private var autoplayTask: Task<Void, Never>?
    @ObservationIgnored private var autoplayRequestedEntry: UUID?
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
    @ObservationIgnored private var interruption = PlaybackInterruption()
    @ObservationIgnored private var listening = PlaybackListeningClock()
    @ObservationIgnored private var pendingListening: PlaybackListeningBuffer
    @ObservationIgnored private var isFlushingListening = false
    @ObservationIgnored private var sessionID = UUID()
    @ObservationIgnored private var sessionStartedAt: Date?
    @ObservationIgnored private var trackStartDelivered = false
    @ObservationIgnored private var standbyEligible = false
    @ObservationIgnored private var lastAdvanceUptime: TimeInterval = 0
    @ObservationIgnored private var lastCheckpointUptime: TimeInterval = 0
    @ObservationIgnored private var lastSeekUptime: TimeInterval = -1
    @ObservationIgnored private let log = Logger(subsystem: "com.agraabhi.ganabajana", category: "Playback")

    init(resolver: any StreamResolving = YouTubeStreamResolver(), standbyPreroll: StandbyDeck.Preroll? = nil,
         listeningCheckpointLimit: Int = PlaybackListeningBuffer.defaultMaximumSessions) {
        self.resolver = resolver
        deck = StandbyDeck(resolver: resolver, preroll: standbyPreroll)
        cachePipeline = PlaybackCachePipeline(resolver: resolver)
        pendingListening = PlaybackListeningBuffer(maximumSessions: listeningCheckpointLimit)
        observeActivePlayer()
        system = PlaybackSystemControls(owner: self)
        deck.onChange = { [weak self] in self?.standbyChanged() }
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
        resolutionTask?.cancel()
        settingsTask?.cancel()
        prefetchTask?.cancel()
        autoplayTask?.cancel()
        monitorTask?.cancel()
        readinessTask?.cancel()
        seekTimeoutTask?.cancel()
        sleepTask?.cancel()
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

    func play(_ tracks: [Track], startingAt index: Int = 0, isRadio: Bool = false) {
        let shuffled = shuffleEnabled
        guard retireSelection() else { return }
        autoplayTrackIDs = []
        isRadioSession = isRadio && !tracks.isEmpty
        ordering.replace(tracks, startingAt: index, shuffled: shuffled)
        selectCurrent(autoplay: true)
    }

    func restore(_ snapshot: PlaybackSnapshot) {
        guard retireSelection() else { return }
        autoplayTrackIDs = []
        isRadioSession = false
        ordering.restore(snapshot)
        repeatMode = snapshot.repeatMode
        selectCurrent(autoplay: false, at: PlaybackTiming.position(snapshot.position))
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
        flushListeningProgress()
        wantsPlayback = false
        interruption.cancelResume()
        cancelAutoplayRequest()
        endTransition()
        player.pause()
        if resolutionTask != nil || preparing {
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

    func next() {
        guard currentTrack != nil else { return }
        let autoplay = wantsPlayback
        var nextOrder = ordering
        guard nextOrder.advance(repeatMode: repeatMode, automatic: false) else { pause(); return }
        if autoplay, settings.crossfadeSeconds > 0, transition == nil, !interruption.active,
           let entry = nextOrder.selectedID, entry != ordering.selectedID,
           let prepared = deck.take(entryID: entry, transitionAt: Date()) {
            activateStandby(prepared, order: nextOrder, blend: min(settings.crossfadeSeconds, 3))
            return
        }
        guard retireSelection() else { return }
        ordering = nextOrder
        selectCurrent(autoplay: autoplay)
    }

    func previous() {
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
        guard currentTrack != nil, seconds.isFinite else { return }
        endTransition()
        flushListeningProgress()
        guard listening.pending == 0 else { return }
        if ended {
            cancelAutoplayRequest()
            startListeningSession()
        }
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
        guard currentTrack != nil else { return }
        let resumeAt = ended ? 0 : position
        if ended {
            flushListeningProgress()
            guard listening.pending == 0 else { return }
            startListeningSession()
        }
        recoveryAttempts = 0
        wantsPlayback = true
        beginResolving(forceRefresh: true, at: resumeAt, preferBestAudio: preferBestAudio)
    }

    func toggleShuffle() {
        ordering.toggleShuffle()
        publishSnapshot()
        publishNowPlaying()
        refreshStandby()
    }

    func cycleRepeatMode() {
        repeatMode = repeatMode.next
        if repeatMode != .off { cancelAutoplayRequest() }
        publishSnapshot()
        refreshStandby()
    }

    func enqueue(_ track: Track, next: Bool = false) {
        let wasEmpty = queue.isEmpty
        ordering.enqueue(track, next: next)
        if wasEmpty { selectCurrent(autoplay: false) }
        publishSnapshot()
        publishNowPlaying()
        refreshStandby()
    }

    /// Appends Autoplay continuation tracks, skipping anything already queued.
    func appendAutoplay(_ tracks: [Track]) {
        defer { finishAutoplayWait() }
        var known = Set(queue.map(\.id))
        let additions = tracks.filter { known.insert($0.id).inserted }
        guard !additions.isEmpty else { return }
        let wasEmpty = queue.isEmpty
        for track in additions { ordering.enqueue(track, next: false) }
        autoplayTrackIDs.formUnion(additions.map(\.id))
        if wasEmpty { selectCurrent(autoplay: false) }
        log.info("event=autoplay_appended count=\(additions.count)")
        publishSnapshot()
        publishNowPlaying()
        refreshStandby()
    }

    func removeFromQueue(at index: Int) {
        guard queue.indices.contains(index) else { return }
        let removesCurrent = index == currentIndex
        let autoplay = wantsPlayback
        if removesCurrent, !retireSelection() { return }
        ordering.remove(at: index)
        if removesCurrent { selectCurrent(autoplay: autoplay) }
        publishSnapshot()
        publishNowPlaying()
        refreshStandby()
    }

    func moveQueue(from offsets: IndexSet, to destination: Int) {
        ordering.move(from: offsets, to: destination)
        publishSnapshot()
        publishNowPlaying()
        refreshStandby()
    }

    func prefetch(_ tracks: [Track]) {
        guard !cachePipeline.isClearingStorage else { return }
        var seen = Set<String>()
        let selected = Array(tracks.filter { $0.isAudioRecording != false && seen.insert($0.id).inserted }.prefix(2))
        let ids = selected.map(\.id)
        if prefetchTask != nil && prefetchIDs == ids { return }
        prefetchTask?.cancel()
        prefetchIDs = ids
        let token = UUID()
        prefetchToken = token
        prefetchTask = Task(priority: .utility) { @MainActor [weak self, resolver] in
            await self?.waitForCacheStorageUpdates()
            guard !Task.isCancelled, self?.prefetchToken == token else { return }
            await resolver.prefetch(selected)
            guard let self, self.prefetchToken == token else { return }
            self.prefetchTask = nil
        }
    }

    private func prefetchNextQueuedTrack() {
        guard isPlaying else { return }
        var upcoming = ordering
        if upcoming.advance(repeatMode: repeatMode, automatic: true), let track = upcoming.current,
           track.id != currentTrack?.id { prefetch([track]) }
        else { prefetch([]) }
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
        if listening.pending > 0, !pendingListening.canRecord(sessionID: sessionID) {
            deliverListeningCheckpoints()
        }
        if listening.pending > 0, let track = currentTrack, let startedAt = sessionStartedAt {
            let checkpoint = ListeningEvent(id: sessionID, track: track, startedAt: startedAt, listenedSeconds: listening.pending)
            guard pendingListening.append(checkpoint) else {
                failListeningCapacity()
                return
            }
            _ = listening.drain()
        }
        deliverListeningCheckpoints()
        publishSnapshot()
    }

    private func deliverListeningCheckpoints() {
        while let checkpoint = pendingListening.checkpoints.first {
            guard onListeningProgress?(checkpoint.track, checkpoint.id, checkpoint.startedAt, checkpoint.listenedSeconds) == true else { break }
            pendingListening.acknowledge(checkpoint)
        }
    }

    func discardPendingListening() {
        pendingListening.discard()
        listening = PlaybackListeningClock()
        sessionID = UUID()
        sessionStartedAt = nil
        lastCheckpointUptime = ProcessInfo.processInfo.systemUptime
        // History boundaries reset recording identity, not the audible track's once-only start notification.
        samplePlayback()
        if errorMessage == Self.listeningCapacityMessage { errorMessage = nil }
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
        guard let youtube = resolver as? YouTubeStreamResolver else { return }
        let previous = settingsTask
        settingsTask = Task {
            await previous?.value
            await youtube.setRemoteFallbackEnabled(enabled)
        }
        if resolutionTask != nil {
            beginResolving(forceRefresh: true, at: position)
        }
    }

    func resumePlayback() {
        guard currentTrack != nil, !interruption.active else { return }
        if awaitingAutoplay != nil { return }
        wantsPlayback = true
        errorMessage = nil
        if ended {
            guard retireSelection() else { return }
            selectCurrent(autoplay: true)
        } else if player.currentItem == nil || player.currentItem?.status == .failed
                    || (streamExpiresAt?.timeIntervalSinceNow ?? .infinity) <= 30 {
            beginResolving(forceRefresh: player.currentItem?.status == .failed || streamExpiresAt != nil, at: position)
        } else if !seeking && !preparing {
            startPlayer()
        }
        refreshActivity()
    }

    func handleInterruption(began: Bool, shouldResume: Bool = false) {
        if began {
            flushListeningProgress()
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
        player = AVPlayer()
        observeActivePlayer()
        system?.configureSession()
        log.notice("event=media_services_reset")
        wantsPlayback = resume
        if resume { beginResolving(forceRefresh: true, at: savedPosition) }
        publishNowPlaying()
    }

    func handleLifecycleCheckpoint() {
        if let deadline = sleepUntil { expireSleepTimer(expected: deadline, now: Date()) }
        flushListeningProgress()
        publishNowPlaying()
    }

    func handleBackgroundTransitionExpired() {
        guard wantsPlayback || awaitingAutoplay != nil, isLoading else { return }
        fail("Audio could not finish loading in the background. Open Breezy and try again.")
    }

    func expireSleepTimer(expected: Date, now: Date) {
        guard sleepUntil == expected, now >= expected else { return }
        sleepUntil = nil
        sleepTask?.cancel()
        sleepTask = nil
        log.info("event=sleep_timer_expired")
        pause()
    }

    func publishNowPlaying() {
        system?.update(track: currentTrack, position: position, duration: duration,
                       playing: isPlaying, index: currentIndex, count: queue.count)
    }

    private func publishSnapshot() {
        onSnapshotChanged?(ordering.snapshot(position: position, repeatMode: repeatMode))
    }

    private func retireSelection() -> Bool {
        flushListeningProgress()
        guard listening.pending == 0 else { return false }
        invalidatePipeline()
        cachePipeline.cancel()
        wantsPlayback = false
        interruption.cancelResume()
        listening = PlaybackListeningClock()
        return true
    }

    private func selectCurrent(autoplay: Bool, at position: TimeInterval = 0) {
        startListeningSession()
        recoveryAttempts = 0
        ended = false
        errorMessage = nil
        resolvedViewCount = nil
        sourceAudioQuality = nil
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
        else { system?.deactivateSession() }
        refreshStandby()
    }

    private func startListeningSession(id: UUID = UUID()) {
        listening = PlaybackListeningClock()
        sessionID = id
        sessionStartedAt = nil
        trackStartDelivered = false
        standbyEligible = false
    }

    private func invalidatePipeline() {
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
        let discardedURL = discard ? currentStreamURL : nil
        flushListeningProgress()
        guard listening.pending == 0, ensureListeningCapacity(for: sessionID) else { return }
        invalidatePipeline()
        let token = generation
        let entry = ordering.selectedID
        self.position = PlaybackTiming.position(position)
        pendingPosition = self.position
        ended = false
        errorMessage = nil
        isLoading = wantsPlayback && !interruption.active
        if isLoading { system?.beginTransition() }
        let configuration = settingsTask
        let pipeline = cachePipeline
        let retention = pipeline.retainPlaybackFiles()
        resolutionTask = Task { @MainActor [weak self, resolver] in
            do {
                await configuration?.value
                await retention?.value
                if discard { await pipeline.discard(track, url: discardedURL) }
                try Task.checkCancellation()
                var stream = try await PlaybackDeadline.run(seconds: 75) {
                    if preferBestAudio, let youtube = resolver as? YouTubeStreamResolver {
                        return try await youtube.refreshQuality(track: track)
                    }
                    return try await resolver.resolve(track: track, forceRefresh: forceRefresh)
                }
                stream = try await PlaybackStreamLoading.loadMissingLocalDuration(in: stream)
                try Task.checkCancellation()
                guard let self, self.generation == token, self.ordering.selectedID == entry else { return }
                self.resolutionTask = nil
                self.install(stream, track: track, generation: token)
            } catch {
                guard !Task.isCancelled, let self, self.generation == token, self.ordering.selectedID == entry else { return }
                self.resolutionTask = nil
                self.fail(error.localizedDescription)
            }
        }
        publishNowPlaying()
    }

    private func install(_ stream: ResolvedStream, track: Track, generation token: UInt64) {
        let expiry = stream.expiresAt ?? PlaybackTiming.expiry(in: stream.url)
        if let expiry, expiry.timeIntervalSinceNow <= 5 { fail(PlaybackStreamError.expired.localizedDescription); return }
        duration = PlaybackTiming.duration(stream: stream, track: track) ?? 0
        streamExpiresAt = expiry
        streamLoudnessDb = stream.loudnessDb
        resolvedViewCount = stream.viewCount ?? resolvedViewCount
        sourceAudioQuality = stream.quality
        isCurrentTrackCached = cachePipeline.isCachedStream(stream)
        currentStreamURL = stream.url
        refreshNormalizationGain(applyToPlayer: true)
        position = PlaybackTiming.position(pendingPosition, duration: duration)
        pendingPosition = position
        let item = PlaybackStreamLoading.makeItem(url: stream.url, duration: duration)
        preparing = true
        lastAdvanceUptime = ProcessInfo.processInfo.systemUptime
        player.replaceCurrentItem(with: item)
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
        guard !ended, !seeking else { return }
        let continuePlaying = wantsPlayback && !interruption.active
        if continuePlaying, let next = nextAutomaticOrder(), let prepared = deck.take(entryID: next.entry, transitionAt: Date()) {
            activateStandby(prepared, order: next.order, blend: 0)
            return
        }
        ended = true
        flushListeningProgress()
        var nextOrder = ordering
        if continuePlaying && nextOrder.advance(repeatMode: repeatMode, automatic: true) {
            guard retireSelection() else { return }
            ordering = nextOrder
            selectCurrent(autoplay: true)
        } else {
            if continuePlaying, settings.autoplay || isRadioSession, repeatMode == .off,
               autoplayTask != nil, let entry = ordering.selectedID, autoplayRequestedEntry == entry {
                awaitingAutoplay = (generation, entry)
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
        beginResolving(forceRefresh: true, at: seeking ? pendingPosition : position, discardingCachedFile: discardCachedFile)
    }

    private static let fileFailureReasons: Set<String> = ["item_failed", "transport_failed", "readiness_timeout"]

    private var currentItemIsCachedFile: Bool {
        guard let url = (player.currentItem?.asset as? AVURLAsset)?.url else { return false }
        return cachePipeline.isCachedStream(ResolvedStream(url: url))
    }

    private func fail(_ message: String) {
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
        guard player.currentItem != nil, !seeking, !preparing else { return }
        let actualPosition = player.currentTime().seconds
        guard actualPosition.isFinite, actualPosition >= 0 else { return }
        let uptime = ProcessInfo.processInfo.systemUptime
        let advancing = wantsPlayback && !interruption.active && player.timeControlStatus == .playing && player.rate > 0
        let delta = listening.sample(position: actualPosition, uptime: uptime, advancing: advancing)
        position = PlaybackTiming.position(actualPosition, duration: duration)
        pendingPosition = position
        if delta > 0 {
            lastAdvanceUptime = uptime
            system?.endTransition()
            if sessionStartedAt == nil { sessionStartedAt = Date().addingTimeInterval(-delta) }
        }
        isPlaying = advancing && (delta > 0 || (isPlaying && uptime - lastAdvanceUptime < 1))
        if delta > 0, !trackStartDelivered, let track = currentTrack {
            trackStartDelivered = true
            standbyEligible = true
            log.info("event=track_started")
            onTrackStarted?(track)
            refreshStandby()
        }
    }

    private func refreshActivity() {
        isLoading = !interruption.active && errorMessage == nil
            && (awaitingAutoplay != nil || (wantsPlayback
                && (resolutionTask != nil || preparing || seeking || player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                    || (player.currentItem != nil && !isPlaying && !ended))))
        if !wantsPlayback || interruption.active || player.timeControlStatus != .playing { isPlaying = false }
        publishNowPlaying()
    }

    private func tick() {
        if let deadline = sleepUntil, Date() >= deadline { expireSleepTimer(expected: deadline, now: Date()) }
        if currentTrack != nil {
            samplePlayback()
            refreshActivity()
        }
        let uptime = ProcessInfo.processInfo.systemUptime
        if uptime - lastCheckpointUptime >= 5 && (wantsPlayback || listening.pending > 0 || !pendingListening.checkpoints.isEmpty) {
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
        }
    }

    // MARK: - Transitions

    private func refreshNormalizationGain(applyToPlayer: Bool) {
        normalizationGain = PlaybackNormalization.gain(loudnessDb: streamLoudnessDb, enabled: settings.normalizeVolume)
        if applyToPlayer { player.volume = Float(normalizationGain) }
    }

    /// Nil when the automatic advance stays on the current entry (repeat one) or the queue is exhausted.
    private func nextAutomaticOrder() -> (entry: UUID, order: PlaybackQueue)? {
        var order = ordering
        guard order.advance(repeatMode: repeatMode, automatic: true), let entry = order.selectedID,
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
        requestAutoplayIfNeeded()
        let next = nextAutomaticOrder()
        let retention = cachePipeline.retainPlaybackFiles()
        syncCacheDownloads(next: next)
        let wantsStandby = settings.gapless || settings.crossfadeSeconds > 0 || settings.automix
        if let prepared = deck.entryID, !wantsStandby || prepared != next?.entry { deck.invalidate() }
        defer { scheduleBoundary() }
        guard wantsStandby else { prefetchNextQueuedTrack(); return }
        guard let next, let track = next.order.current, deck.entryID == nil, standbyEligible,
              wantsPlayback, !interruption.active, errorMessage == nil else { return }
        let configuration = settingsTask
        let ready = Task {
            await configuration?.value
            await retention?.value
        }
        deck.prepare(track: track, entryID: next.entry, forceRefresh: false, after: ready)
    }

    // MARK: - Audio cache

    func audioCacheUsage() async throws -> AudioCache.Usage? {
        try await cachePipeline.storageUsage()
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
        prefetchTask?.cancel()
        prefetchTask = nil
        prefetchIDs = []
        prefetchToken = UUID()
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
        guard cachePipeline.isAvailable, trackStartDelivered, wantsPlayback, !interruption.active,
              let current = currentTrack else { return }
        let target = next.flatMap { step in step.order.current.map { PlaybackCachePipeline.Target(track: $0, entryID: step.entry) } }
        cachePipeline.sync(current: current, next: target)
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
        guard let track = deck.track, let entry = deck.entryID, deck.needsRefresh(transitionAt: expectedTransitionDate) else { return }
        log.info("event=standby_refresh")
        deck.prepare(track: track, entryID: entry, forceRefresh: true, after: settingsTask)
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
              resolutionTask == nil, player.currentItem != nil else { return }
        let blend = automaticBlendDuration()
        let remaining = duration - player.currentTime().seconds
        // A seek into or across the blend window is served by the end-of-item swap instead of a truncated ramp.
        guard blend > 0, remaining.isFinite, remaining > 0.25, remaining <= blend + 0.5,
              ProcessInfo.processInfo.systemUptime - lastSeekUptime >= 1,
              let next = nextAutomaticOrder(), let prepared = deck.take(entryID: next.entry, transitionAt: Date()) else { return }
        activateStandby(prepared, order: next.order, blend: min(blend, remaining))
    }

    /// Makes the prepared standby the current track. The outgoing player keeps playing only for the blend;
    /// its item callbacks are rejected by the generation bump.
    private func activateStandby(_ prepared: StandbyDeck.Prepared, order: PlaybackQueue, blend: TimeInterval) {
        flushListeningProgress()
        let incomingSession = UUID()
        guard listening.pending == 0, ensureListeningCapacity(for: incomingSession) else {
            prepared.player.pause()
            deck.reclaim(prepared.player)
            return
        }
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
        resolvedViewCount = prepared.stream.viewCount
        sourceAudioQuality = prepared.stream.quality
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
                                              outgoingGain: outgoingGain, incomingGain: Float(normalizationGain))
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

    private func requestAutoplayIfNeeded() {
        guard settings.autoplay || isRadioSession, repeatMode == .off, wantsPlayback, !interruption.active, standbyEligible,
              let track = currentTrack, let entry = ordering.selectedID, autoplayRequestedEntry != entry,
              let request = onQueueExhausted else { return }
        var probe = ordering
        guard !probe.advance(repeatMode: .off, automatic: true) else { return }
        autoplayRequestedEntry = entry
        autoplayTask?.cancel()
        let token = generation
        log.info("event=autoplay_requested")
        autoplayTask = Task { @MainActor [weak self] in
            let tracks = await request(track)
            guard !Task.isCancelled, let self, self.settings.autoplay || self.isRadioSession,
                  self.generation == token, !self.interruption.active, self.repeatMode == .off,
                  self.ordering.selectedID == entry, self.autoplayRequestedEntry == entry else { return }
            self.autoplayTask = nil
            self.appendAutoplay(tracks)
        }
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
        if awaitingAutoplay != nil {
            awaitingAutoplay = nil
            isLoading = false
            system?.endTransition()
        }
    }
}

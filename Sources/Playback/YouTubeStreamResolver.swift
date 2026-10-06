import Foundation
import OSLog
import Synchronization
import YouTubeKit

/// A resolver that can also hold complete local copies of tracks. Test resolvers stay plain `StreamResolving`.
protocol StreamCaching: StreamResolving {
    /// Resolves `track` and downloads it completely, returning the file-backed stream.
    func download(_ track: Track) async throws -> ResolvedStream
    /// Drops a cached copy the player could not use, so the next resolution goes back to the network.
    func discardCached(_ track: Track) async
    func discardCached(_ track: Track, url: URL?) async
    /// Protects exactly these tracks from cache eviction.
    func retainCached(_ trackIDs: Set<String>) async
    /// Whether `stream` is one of this resolver's complete local copies.
    func isCachedStream(_ stream: ResolvedStream) -> Bool
}

extension StreamCaching {
    func discardCached(_ track: Track, url: URL?) async { await discardCached(track) }
}

/// Storage controls are optional so file fixtures and other resolvers never acquire a production disk cache.
protocol StreamCacheManaging: StreamCaching {
    func audioCacheUsage() async throws -> AudioCache.Usage?
    func audioCacheSnapshot() async throws -> AudioCacheSnapshot?
    func removeCachedSong(id: String, retaining: @escaping @Sendable () async -> Set<String>) async throws -> AudioCacheRemoval?
    func updateCacheListeningHistory(_ events: [ListeningEvent], now: Date) async
    func clearAudioCache(retaining: @escaping @Sendable () async -> Set<String>) async throws -> AudioCache.Usage?
    func setAudioCacheLimit(_ limit: AudioCacheLimit,
                           retaining: @escaping @Sendable () async -> Set<String>) async throws -> AudioCache.Usage?
}

extension StreamCacheManaging {
    func audioCacheSnapshot() async throws -> AudioCacheSnapshot? { nil }
    func removeCachedSong(id: String, retaining: @escaping @Sendable () async -> Set<String>) async throws -> AudioCacheRemoval? { nil }
    func updateCacheListeningHistory(_ events: [ListeningEvent], now: Date) async { }
    func setAudioCacheLimit(_ limit: AudioCacheLimit,
                           retaining: @escaping @Sendable () async -> Set<String>) async throws -> AudioCache.Usage? { nil }
}

/// Resolvers that can warm choices the listener has not made yet: signed URLs only, plus at most one speculative
/// complete download of the first track per event. `token` fences that download so only its own job can cancel it.
protocol StreamWarming: StreamResolving {
    func warm(_ tracks: [Track], download: Bool, token: UUID) async -> StreamWarmOutcome
    /// Cancels the speculative download a warm with this token started; a newer warm's download is left alone.
    func cancelWarm(token: UUID) async
}

extension StreamWarming {
    func cancelWarm(token: UUID) async { }
}

struct StreamWarmOutcome: Sendable, Equatable {
    var resolved = 0
    var skipped = 0
    var failed = 0
    var downloadScheduled = false
}

/// Which path produced a track's most recent stream; the player captures it when resolution returns.
/// Keyed by recording id in memory only; never persisted or logged.
enum PlaybackStartTrace {
    enum Path: String, Sendable {
        case local, urlCache, fastPath, extraction, remote, saavn, gaana, warmed
    }

    private struct Table {
        var paths: [String: Path] = [:]
        var warmed: [String] = []
    }

    private static let table = Mutex(Table())
    private static let capacity = 32

    static func record(_ path: Path, for trackID: String) {
        table.withLock { table in
            if table.paths.count >= capacity, table.paths[trackID] == nil, let victim = table.paths.keys.first {
                table.paths.removeValue(forKey: victim)
            }
            table.paths[trackID] = path
        }
    }

    static func path(for trackID: String) -> Path? {
        table.withLock { $0.paths[trackID] }
    }

    /// A warm prepared this song's URL or copy; the next start that reuses it reports `warmed`.
    static func markWarmed(_ trackID: String) {
        table.withLock { table in
            table.warmed.removeAll { $0 == trackID }
            table.warmed.append(trackID)
            if table.warmed.count > capacity { table.warmed.removeFirst() }
        }
    }

    /// The start path, consuming the warm mark: only a reused URL or copy counts, a fresh network path does not.
    static func startPath(for trackID: String) -> Path? {
        table.withLock { table in
            guard let path = table.paths[trackID] else { return nil }
            guard let index = table.warmed.firstIndex(of: trackID) else { return path }
            table.warmed.remove(at: index)
            return path == .urlCache || path == .local ? .warmed : path
        }
    }
}

actor YouTubeStreamResolver: StreamCacheManaging, StreamWarming, PlaybackPreloadResolving {
    nonisolated static let offlineMessage = "You’re offline and this song isn’t cached on this device. Connect to the internet and try again."
    typealias Extraction = @Sendable (_ videoID: String, _ remote: Bool) async throws -> [URL]
    typealias QualityExtraction = @Sendable (_ videoID: String, _ remote: Bool) async throws -> [ResolvedStream]
    typealias FastExtraction = @Sendable (_ videoID: String) async throws -> FastPathResult
    typealias CappedFastExtraction = @Sendable (_ videoID: String, _ maximumBitRate: Int?) async throws -> FastPathResult
    typealias Validation = @Sendable (URL) async throws -> Void

    private var allowRemoteFallback: Bool
    private let extract: QualityExtraction
    private let validate: Validation
    private let timeout: TimeInterval
    private let fastExtract: CappedFastExtraction?
    private let cacheCapacity: Int
    private let audioCache: AudioCache?
    private let opusEnabled: Bool
    private let opusTimeout: TimeInterval
    private let isOffline: @Sendable () -> Bool
    private var networkOffline = false
    private var networkStopTask: Task<Void, Never>?
    /// Production waits this long for the fast path before YouTubeKit starts alongside it; nil keeps them sequential.
    private let hedgeDelay: TimeInterval?
    private let hedgeSleep: @Sendable (TimeInterval) async throws -> Void
    /// Above the slowest fast path in the live baseline (1.6 s), so YouTubeKit only joins when the fast path is stuck.
    nonisolated static let productionHedgeDelay: TimeInterval = 2
    /// A background Opus upgrade is not on the listener's critical path, so it may take the whole extraction budget.
    private var upgradeTimeout: TimeInterval { min(timeout, opusTimeout * 3) }
    private var opusFailures: [String: Date] = [:]
    /// Signed URLs remember the ceiling they were chosen under so a preference change can retire the wrong ones.
    /// `upgrade` is the better Opus a fast start skipped; a complete download prepares it instead of the AAC pick.
    private struct URLEntry {
        let extractionGeneration: UInt64
        let stream: ResolvedStream
        let maximumBitRate: Int?
        let upgrade: ResolvedStream?
    }
    /// One resolution's outcome; `path` names the network or disk path that produced it for `playback_start`.
    struct Selection: Sendable {
        var stream: ResolvedStream
        var upgrade: ResolvedStream?
        var path: PlaybackStartTrace.Path
    }
    private struct Pick: Sendable {
        var stream: ResolvedStream
        var upgrade: ResolvedStream?
    }
    private var cache: [String: URLEntry] = [:]
    private var recency: [String] = []
    private(set) var audioQualityPreference: AudioQualityPreference = .best
    private var maximumBitRate: Int? { audioQualityPreference.maximumBitRate }
    private struct Waiter {
        let foreground: Bool
        let speculative: Bool
        /// A download wants a complete local copy; the listener and URL warms want the first playable stream.
        let complete: Bool
    }
    private struct Flight {
        let token: UUID
        let task: Task<Selection, Error>
        var waiters: [UUID: Waiter]
        var hedgeFeed: AsyncStream<HedgeOutcome>.Continuation?
        var hedgeElapsed = false
        var hedgePending = false
        var foreground: Bool { waiters.values.contains { $0.foreground } }
        var isSpeculative: Bool { waiters.values.allSatisfy { $0.speculative && !$0.foreground } }
        var wantsCompleteOnly: Bool { !waiters.isEmpty && waiters.values.allSatisfy(\.complete) }

        func cancel() {
            hedgeFeed?.finish()
            task.cancel()
        }
    }
    private struct ResolutionKey: Hashable, Sendable {
        let trackID: String
        let fresh: Bool
        let extractionGeneration: UInt64
    }
    private var flights: [ResolutionKey: Flight] = [:]
    /// `warmToken` is nil for the queue's own prefetch, which a warm never displaces.
    private var prefetchDownload: (trackID: String, token: UUID, warmToken: UUID?, task: Task<Void, Never>)?
    private var downloadGeneration = UUID()
    private var extractionGeneration = YouTubeKitHooks.extractionCompatibility.generation
    private var isManagingAudioCache = false
    var activeWaiterCount: Int { flights.values.reduce(0) { $0 + $1.waiters.count } }
    var activeHedgeEventCount: Int { flights.values.filter { $0.hedgeFeed != nil }.count }
    var elapsedHedgeCount: Int { flights.values.filter(\.hedgeElapsed).count }
    private(set) var activeDownloadCount = 0
    var prefetchDownloadTrackID: String? { prefetchDownload?.trackID }
    private let log = Logger(subsystem: "com.agraabhi.ganabajana", category: "StreamResolver")

    init(allowRemoteFallback: Bool = false, isOffline: @escaping @Sendable () -> Bool = { false }) {
        // The hooks must exist before YouTubeKit's first request, or a signed-in user's TV lookup goes out anonymous.
        YouTubeKitAuthBridge.install()
        self.allowRemoteFallback = allowRemoteFallback
        extract = { id, remote in try await YouTubeExtractionWorker.shared.extract(id: id, remote: remote) }
        validate = { try await StreamValidation.validate(url: $0) }
        timeout = 35
        fastExtract = { try await YouTubeAudioFastPath.extract(videoID: $0, maximumBitRate: $1) }
        cacheCapacity = 24
        audioCache = AudioCache()
        opusEnabled = OpusNativeAudio.isSupported
        opusTimeout = 12
        hedgeDelay = Self.productionHedgeDelay
        hedgeSleep = { try await Task.sleep(for: .seconds($0)) }
        self.isOffline = isOffline
    }

    /// Without an `audioCache` nothing is written to disk and `download` is unavailable; tests opt in explicitly.
    /// `hedgeDelay` stays nil here so fixtures that hold the fast path never see YouTubeKit start on its own.
    init(allowRemoteFallback: Bool = false, timeout: TimeInterval = 35, cacheCapacity: Int = 24,
         extract: @escaping Extraction, validate: @escaping Validation,
         fastExtract: FastExtraction? = nil, audioCache: AudioCache? = nil, qualityExtract: QualityExtraction? = nil,
         opusEnabled: Bool = false, opusTimeout: TimeInterval = 12, hedgeDelay: TimeInterval? = nil,
         hedgeSleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
         isOffline: @escaping @Sendable () -> Bool = { false }) {
        self.allowRemoteFallback = allowRemoteFallback
        self.hedgeDelay = hedgeDelay
        self.hedgeSleep = hedgeSleep
        self.extract = qualityExtract ?? { id, remote in
            try await extract(id, remote).map { ResolvedStream(url: $0) }
        }
        self.validate = validate
        self.timeout = timeout
        // Injected fast results are prebuilt, so the ceiling is applied once more during validation.
        if let fastExtract {
            self.fastExtract = { id, _ in try await fastExtract(id) }
        } else {
            self.fastExtract = nil
        }
        self.cacheCapacity = max(1, cacheCapacity)
        self.audioCache = audioCache
        self.opusEnabled = opusEnabled
        self.opusTimeout = opusTimeout
        self.isOffline = isOffline
    }

    func setRemoteFallbackEnabled(_ enabled: Bool) {
        allowRemoteFallback = enabled
    }

    /// Idempotent for the current registry generation, so a delayed callback cannot cancel newer work.
    func invalidateExtractionCompatibility() async {
        _ = synchronizeExtractionCompatibility()
        await YouTubeExtractionWorker.shared.invalidateExtractionCompatibility()
    }

    @discardableResult private func synchronizeExtractionCompatibility() -> UInt64 {
        let current = YouTubeKitHooks.extractionCompatibility.generation
        guard current != extractionGeneration else { return current }
        extractionGeneration = current
        cache.removeAll()
        recency.removeAll()
        opusFailures.removeAll()
        downloadGeneration = UUID()
        prefetchDownload?.task.cancel()
        prefetchDownload = nil
        let retired = Array(flights.values)
        flights.removeAll()
        retired.forEach { $0.cancel() }
        log.info("event=extractor_resolution outcome=invalidated")
        return current
    }

    nonisolated static func checkExtractionCompatibility(_ generation: UInt64) throws {
        try Task.checkCancellation()
        guard generation == YouTubeKitHooks.extractionCompatibility.generation else {
            Logger(subsystem: "com.agraabhi.ganabajana", category: "StreamResolver")
                .debug("event=extractor_resolution outcome=stale")
            throw CancellationError()
        }
    }

    /// Applies to the next resolution. Complete local copies keep playing whatever their bitrate; the bytes are on device.
    func setAudioQualityPreference(_ preference: AudioQualityPreference) {
        guard preference != audioQualityPreference else { return }
        audioQualityPreference = preference
        let cap = preference.maximumBitRate
        var dropped = 0
        for (id, entry) in cache where !Self.entryFits(entry, maximumBitRate: cap) {
            cache.removeValue(forKey: id)
            dropped += 1
        }
        recency.removeAll { cache[$0] == nil }
        // Speculative work was selected under the old preference; the listener's own resolution keeps going.
        prefetchDownload?.task.cancel()
        prefetchDownload = nil
        for (key, flight) in flights where flight.isSpeculative {
            flights.removeValue(forKey: key)
            flight.cancel()
        }
        log.info("event=audio_quality_preference preference=\(preference.rawValue, privacy: .public) dropped=\(dropped)")
    }

    /// Valid while the entry fits the ceiling and was not chosen under a tighter one that could have hidden a better format.
    /// The ceiling that produced an entry always accepts it, including a nothing-fits pick above it.
    private static func entryFits(_ entry: URLEntry, maximumBitRate cap: Int?) -> Bool {
        if entry.maximumBitRate == cap { return true }
        guard SourceAudioQuality.fits(entry.stream.quality, maximumBitRate: cap) else { return false }
        guard let selected = entry.maximumBitRate else { return true }
        guard let cap else { return false }
        return selected > cap
    }

    func setNetworkOffline(_ offline: Bool) {
        guard offline != networkOffline else { return }
        networkOffline = offline
        networkStopTask?.cancel()
        networkStopTask = nil
        guard offline else { return }
        downloadGeneration = UUID()
        prefetchDownload?.task.cancel()
        prefetchDownload = nil
        let pending = Array(flights.values)
        flights.removeAll()
        pending.forEach { $0.cancel() }
        if let audioCache { networkStopTask = Task { await audioCache.cancelDownloads() } }
    }

    private var networkIsOffline: Bool { networkOffline || isOffline() }

    private func requireNetwork() throws {
        try Task.checkCancellation()
        if networkIsOffline {
            throw MusicServiceError.network(Self.offlineMessage)
        }
    }

    private func cachedAudio(for track: Track) async throws -> CachedAudio? {
        guard let audioCache else { return nil }
        let allowOpus = opusEnabled
        let result = try await PlaybackDeadline.run(seconds: 10) {
            try await audioCache.preparedEntry(for: track.id, allowOpus: allowOpus)
        }
        let offlineMiss = result == nil && networkIsOffline
        log.debug("event=audio_cache_lookup hit=\(result == nil ? 0 : 1) miss=\(result == nil ? 1 : 0) offline_miss=\(offlineMiss ? 1 : 0)")
        return result
    }

    func resolve(track: Track, forceRefresh: Bool) async throws -> ResolvedStream {
        let compatibility = synchronizeExtractionCompatibility()
        let result = try await resolve(track: track, forceRefresh: forceRefresh, foreground: true)
        try Self.checkExtractionCompatibility(compatibility)
        return result
    }

    /// An explicit quality reload bypasses the saved copy without replacing a file an AVPlayer may still be reading.
    /// The fresh pick honours the quality ceiling, so a saved copy above it is kept rather than replaced by less.
    func refreshQuality(track: Track) async throws -> ResolvedStream {
        let compatibility = synchronizeExtractionCompatibility()
        if networkIsOffline {
            let result = try await resolve(track: track, forceRefresh: false)
            try Self.checkExtractionCompatibility(compatibility)
            return result
        }
        opusFailures.removeValue(forKey: track.id)
        do {
            // The listener asked for the best audio, so this reload still waits for an Opus preparation.
            let fresh = try await PlaybackDeadline.run(seconds: min(timeout * 2, 60)) { [self] in
                try await resolve(track: track, forceRefresh: true, foreground: true, useAudioCache: false, complete: true)
            }
            try Self.checkExtractionCompatibility(compatibility)
            let cached = try await cachedAudio(for: track)
            try Self.checkExtractionCompatibility(compatibility)
            if let cached, let savedRate = cached.quality?.bitRate, (fresh.quality?.bitRate ?? 0) <= savedRate {
                log.info("event=audio_quality_refresh outcome=cached_not_lower preference=\(self.audioQualityPreference.rawValue, privacy: .public)")
                PlaybackStartTrace.record(.local, for: track.id)
                return cached.stream
            }
            log.info("event=audio_quality_refresh outcome=fresh bitrate=\(fresh.quality?.bitRate ?? 0) preference=\(self.audioQualityPreference.rawValue, privacy: .public)")
            return fresh
        } catch {
            try Self.checkExtractionCompatibility(compatibility)
            if error is CancellationError { throw error }
            if case PlaybackStreamError.invalidID = error { throw error }
            if let cached = try await cachedAudio(for: track) {
                try Self.checkExtractionCompatibility(compatibility)
                log.notice("event=audio_quality_refresh outcome=cached_after_failure")
                PlaybackStartTrace.record(.local, for: track.id)
                return cached.stream
            }
            throw error
        }
    }

    func prefetch(_ tracks: [Track]) async {
        _ = await warm(tracks, download: true, limit: 2, warmToken: nil)
    }

    /// URL-only warm of choices the listener may make, bounded by the caller; `download` also starts the speculative
    /// complete download of the first track. Local copies and live signed URLs are skipped, not re-fetched.
    func warm(_ tracks: [Track], download: Bool, token: UUID) async -> StreamWarmOutcome {
        // A recent bot check without an account would fail every warm resolution the same way.
        guard !Self.signInWouldHelp() else { return StreamWarmOutcome(skipped: tracks.count) }
        return await warm(tracks, download: download, limit: tracks.count, warmToken: token)
    }

    func cancelWarm(token: UUID) async {
        guard let current = prefetchDownload, current.warmToken == token else { return }
        current.task.cancel()
        prefetchDownload = nil
    }

    /// A speculative URL resolution for preloading; never the listener's flight and never a complete download. Opus-only
    /// offers prepare a local file before play, so preloading skips them.
    func preloadStream(for track: Track) async throws -> ResolvedStream? {
        let compatibility = synchronizeExtractionCompatibility()
        guard !Self.signInWouldHelp(), !networkIsOffline, !isManagingAudioCache, fastExtract != nil,
              track.source == .youTubeMusic, AudioCache.isProviderTrackID(track.id) else { return nil }
        if let audioCache, await audioCache.hasCompleteCopy(of: track.id, allowOpus: opusEnabled) { return nil }
        try Self.checkExtractionCompatibility(compatibility)
        let stream = try await resolve(track: track, forceRefresh: false, foreground: false)
        try Self.checkExtractionCompatibility(compatibility)
        return stream.url.isFileURL || stream.quality?.codec == .opus ? nil : stream
    }

    /// The queue's prefetch (`warmToken` nil) retires other background work as it always has; a listener-facing warm
    /// retires nothing and leaves its own resolutions to the caller's task cancellation.
    private func warm(_ tracks: [Track], download: Bool, limit: Int, warmToken: UUID?) async -> StreamWarmOutcome {
        let compatibility = synchronizeExtractionCompatibility()
        var outcome = StreamWarmOutcome()
        guard !Task.isCancelled, !networkIsOffline, !isManagingAudioCache, fastExtract != nil,
              !flights.values.contains(where: \.foreground) else { return outcome }
        let generation = downloadGeneration
        var seen = Set<String>()
        let selected = Array(tracks.filter { $0.isAudioRecording != false && seen.insert($0.id).inserted }.prefix(limit))
        if warmToken == nil { cancelWarmups(except: Set(selected.map(\.id))) }
        var pending: [Track] = []
        var complete: Set<String> = []
        for track in selected {
            guard compatibility == YouTubeKitHooks.extractionCompatibility.generation, !Task.isCancelled else { return outcome }
            if let audioCache, await audioCache.hasCompleteCopy(of: track.id, allowOpus: opusEnabled) {
                complete.insert(track.id)
                outcome.skipped += 1
                continue
            }
            if let entry = cache[track.id], entry.extractionGeneration == compatibility,
               (entry.stream.expiresAt?.timeIntervalSinceNow ?? 0) > 90 { outcome.skipped += 1; continue }
            pending.append(track)
        }
        guard compatibility == YouTubeKitHooks.extractionCompatibility.generation, !Task.isCancelled else { return outcome }
        // A live URL still needs its bytes; only a complete local copy makes the first result's download pointless.
        if download, let first = selected.first, !complete.contains(first.id) {
            schedulePrefetchDownload(first, warmToken: warmToken)
            outcome.downloadScheduled = prefetchDownload?.trackID == first.id
            if outcome.downloadScheduled, warmToken != nil { PlaybackStartTrace.markWarmed(first.id) }
        }
        for track in pending {
            guard !Task.isCancelled, !networkIsOffline, generation == downloadGeneration,
                  compatibility == YouTubeKitHooks.extractionCompatibility.generation,
                  !flights.values.contains(where: \.foreground) else { return outcome }
            do {
                _ = try await resolve(track: track, forceRefresh: false, foreground: false)
                try Self.checkExtractionCompatibility(compatibility)
                outcome.resolved += 1
                if warmToken != nil { PlaybackStartTrace.markWarmed(track.id) }
            } catch is CancellationError { return outcome }
            catch {
                outcome.failed += 1
                log.debug("event=prefetch_unavailable")
            }
        }
        return outcome
    }

    func download(_ track: Track) async throws -> ResolvedStream {
        let compatibility = synchronizeExtractionCompatibility()
        let result = try await download(track, speculative: false)
        try Self.checkExtractionCompatibility(compatibility)
        return result
    }

    /// Resolves a single downloadable file without invoking the foreground download/remux pipeline.
    func backgroundDownloadPlan(for track: Track) async throws -> BackgroundDownloadPlan {
        let compatibility = synchronizeExtractionCompatibility()
        guard track.source == .youTubeMusic, AudioCache.isProviderTrackID(track.id) else { throw PlaybackStreamError.invalidID }
        try requireNetwork()
        let generation = downloadGeneration
        let ceiling = maximumBitRate
        // The song usually just started playing: its lookup is in flight or its validated link is cached. A second
        // simultaneous lookup for one video is what made instant downloads time out and fail.
        let joinDeadline = ContinuousClock.now.advanced(by: .seconds(timeout * 2 + 10))
        while flights.keys.contains(where: { $0.trackID == track.id && $0.extractionGeneration == compatibility }),
              ContinuousClock.now < joinDeadline {
            try await Task.sleep(for: .milliseconds(150))
            try Self.checkExtractionCompatibility(compatibility)
            try checkDownloadGeneration(generation)
            try requireNetwork()
        }
        if let entry = cache[track.id], entry.extractionGeneration == compatibility,
           let expiry = entry.stream.expiresAt, expiry.timeIntervalSinceNow > 90 {
            let known = [entry.upgrade, entry.stream].compactMap { $0 }
            if let plan = try? await downloadableCandidate(known, track: track, ceiling: ceiling, compatibility: compatibility) {
                try Self.checkExtractionCompatibility(compatibility)
                try checkDownloadGeneration(generation)
                log.info("event=download_plan source=player_link")
                return plan
            }
            try Task.checkCancellation()
        }
        if let fastExtract {
            do {
                let result = try await PlaybackDeadline.run(seconds: min(timeout, 6)) { try await fastExtract(track.id, ceiling) }
                try Self.checkExtractionCompatibility(compatibility)
                let plan = try await downloadableCandidate(result.streams + result.aacFallbacks, track: track, ceiling: ceiling,
                                                           compatibility: compatibility)
                try Self.checkExtractionCompatibility(compatibility)
                try checkDownloadGeneration(generation)
                return plan
            } catch {
                try Self.checkExtractionCompatibility(compatibility)
                try checkDownloadGeneration(generation)
                if error is CancellationError { throw error }
            }
        }
        // JS extraction still needs app runtime, but the selected YouTube media transfer belongs to URLSession's daemon.
        for remote in allowRemoteFallback ? [false, true] : [false] {
            do {
                let streams = try await PlaybackDeadline.run(seconds: timeout) { [extract] in try await extract(track.id, remote) }
                try Self.checkExtractionCompatibility(compatibility)
                let plan = try await downloadableCandidate(streams, track: track, ceiling: ceiling, compatibility: compatibility)
                try Self.checkExtractionCompatibility(compatibility)
                try checkDownloadGeneration(generation)
                return plan
            } catch {
                try Self.checkExtractionCompatibility(compatibility)
                try checkDownloadGeneration(generation)
                if error is CancellationError { throw error }
                if remote || !allowRemoteFallback { throw error }
            }
        }
        throw PlaybackStreamError.noAudio
    }

    private func downloadableCandidate(_ streams: [ResolvedStream], track: Track, ceiling: Int?, compatibility: UInt64) async throws -> BackgroundDownloadPlan {
        let ranked = SourceAudioQuality.ranked(streams, maximumBitRate: ceiling, quality: \.quality)
        let aac = ranked.filter { $0.quality?.codec != .opus }
        let opus = opusEnabled ? ranked.filter { $0.quality?.codec == .opus } : []
        var candidates = Array(aac.prefix(3)) + Array(opus.prefix(3))
        if let ceiling {
            let fitting = candidates.filter { ($0.quality?.bitRate ?? Int.max) <= ceiling }
            if fitting.isEmpty {
                candidates = SourceAudioQuality.ranked(candidates, maximumBitRate: ceiling, quality: \.quality)
            } else {
                candidates = fitting + candidates.filter { ($0.quality?.bitRate ?? Int.max) > ceiling }
            }
        }
        var seen = Set<URL>()
        for var stream in candidates where seen.insert(stream.url).inserted {
            do {
                try Self.checkExtractionCompatibility(compatibility)
                try requireNetwork()
                try StreamValidation.validateSourceURL(stream.url)
                if let stamp = stream.extractionGeneration, stamp != compatibility { throw CancellationError() }
                stream.duration = PlaybackTiming.duration(stream: stream, track: track)
                stream.playbackSource = .youTubeMusic
                stream.extractionGeneration = compatibility
                let plan = try BackgroundDownloadPlan(stream: stream)
                _ = try plan.request(allowCellular: false, now: Date())
                if stream.quality?.codec != .opus {
                    try await PlaybackDeadline.run(seconds: min(timeout, 10)) { [validate, url = stream.url] in try await validate(url) }
                }
                try Self.checkExtractionCompatibility(compatibility)
                return plan
            } catch is CancellationError { throw CancellationError() }
            catch { try Task.checkCancellation() }
        }
        throw PlaybackStreamError.noAudio
    }

    private func download(_ track: Track, speculative: Bool) async throws -> ResolvedStream {
        let compatibility = synchronizeExtractionCompatibility()
        guard let audioCache else { throw MusicServiceError.unavailable("Audio caching is not available.") }
        // Prefixed ids pass the cache's shape check but belong to another source's resolver.
        guard track.source == .youTubeMusic, AudioCache.isProviderTrackID(track.id) else { throw PlaybackStreamError.invalidID }
        let generation = downloadGeneration
        try Task.checkCancellation()
        activeDownloadCount += 1
        defer { activeDownloadCount -= 1 }
        if let cached = try await cachedAudio(for: track) {
            try Self.checkExtractionCompatibility(compatibility)
            return cached.stream
        }
        try requireNetwork()
        let permit = try await audioCache.writePermit()
        try Self.checkExtractionCompatibility(compatibility)
        try checkDownloadGeneration(generation)
        // A listener-initiated resolution owns the network until it finishes; downloads are never in its way.
        while flights.values.contains(where: \.foreground) {
            try await Task.sleep(for: .milliseconds(150))
            try Self.checkExtractionCompatibility(compatibility)
            try checkDownloadGeneration(generation)
            try requireNetwork()
        }
        let selection = try await select(track: track, forceRefresh: false, foreground: false, speculative: speculative,
                                         useAudioCache: true, complete: true)
        try Self.checkExtractionCompatibility(compatibility)
        try checkDownloadGeneration(generation)
        let stream = selection.stream
        if stream.url.isFileURL { return stream }
        try requireNetwork()
        if let upgrade = selection.upgrade,
           let prepared = try await prepareUpgrade(track, upgrade, permit: permit, speculative: speculative, generation: generation,
                                                   compatibility: compatibility) {
            try Self.checkExtractionCompatibility(compatibility)
            return prepared
        }
        try Self.checkExtractionCompatibility(compatibility)
        try requireNetwork()
        let cached = try await audioCache.store(trackID: track.id, from: stream.url, stream: stream, permit: permit,
                                               track: track, speculative: speculative)
        try Self.checkExtractionCompatibility(compatibility)
        try checkDownloadGeneration(generation)
        log.info("event=audio_cached bytes=\(cached.bytes)")
        if cached.duration != nil { return cached.stream }
        guard let prepared = try await cachedAudio(for: track) else { throw PlaybackStreamError.invalidMedia }
        try Self.checkExtractionCompatibility(compatibility)
        try checkDownloadGeneration(generation)
        return prepared.stream
    }

    /// The complete download prefers the Opus a fast start left behind; any failure falls back to storing the AAC pick.
    /// Nil means "store the AAC instead"; cancellation and maintenance propagate.
    private func prepareUpgrade(_ track: Track, _ upgrade: ResolvedStream, permit: AudioCache.WritePermit,
                                speculative: Bool, generation: UUID, compatibility: UInt64) async throws -> ResolvedStream? {
        try Self.checkExtractionCompatibility(compatibility)
        guard let audioCache, opusEnabled, (opusFailures[track.id]?.timeIntervalSinceNow ?? 0) <= 0 else { return nil }
        if let expiry = PlaybackTiming.expiry(in: upgrade.url), expiry.timeIntervalSinceNow <= 30 { return nil }
        let started = ContinuousClock.now
        do {
            try StreamValidation.validateSourceURL(upgrade.url)
            let cached = try await PlaybackDeadline.run(seconds: upgradeTimeout) {
                try await audioCache.storeOpus(trackID: track.id, stream: upgrade, permit: permit, foreground: false,
                                              track: track, speculative: speculative)
            }
            try Self.checkExtractionCompatibility(compatibility)
            try checkDownloadGeneration(generation)
            log.info("event=opus_upgrade outcome=prepared bytes=\(cached.bytes) ms=\(Int(started.duration(to: .now) / .milliseconds(1)))")
            return cached.stream
        } catch {
            try Self.checkExtractionCompatibility(compatibility)
            try checkDownloadGeneration(generation)
            if error is CancellationError { throw error }
            if case AudioCache.ManagementError.admissionDeferred = error {
                log.debug("event=opus_upgrade outcome=deferred")
                return nil
            }
            recordOpusFailure(track.id)
            log.notice("event=opus_upgrade outcome=failed reason=\(OpusPreparationError.diagnosticReason(error), privacy: .public) fallback=aac")
            return nil
        }
    }

    func audioCacheUsage() async throws -> AudioCache.Usage? {
        try await audioCache?.storageUsage()
    }

    func audioCacheSnapshot() async throws -> AudioCacheSnapshot? {
        try await audioCache?.snapshot(allowOpus: opusEnabled)
    }

    func updateCacheListeningHistory(_ events: [ListeningEvent], now: Date) async {
        await audioCache?.updateListeningHistory(events, now: now)
    }

    func removeCachedSong(id: String, retaining: @escaping @Sendable () async -> Set<String>) async throws -> AudioCacheRemoval? {
        guard let audioCache else { return nil }
        try await beginAudioCacheMaintenance()
        defer { isManagingAudioCache = false }
        let result = try await audioCache.removeSong(id: id, retaining: retaining)
        if result.outcome != .inUse {
            cache.removeValue(forKey: id)
            recency.removeAll { $0 == id }
        }
        return result
    }

    func clearAudioCache(retaining: @escaping @Sendable () async -> Set<String>) async throws -> AudioCache.Usage? {
        guard let audioCache else { return nil }
        try await beginAudioCacheMaintenance()
        defer { isManagingAudioCache = false }
        return try await audioCache.clearUnused(retaining: retaining)
    }

    func setAudioCacheLimit(_ limit: AudioCacheLimit,
                           retaining: @escaping @Sendable () async -> Set<String>) async throws -> AudioCache.Usage? {
        guard let audioCache else { return nil }
        try await beginAudioCacheMaintenance()
        defer { isManagingAudioCache = false }
        return try await audioCache.updatePolicy(capacityBytes: limit.bytes, maximumFiles: limit.maximumSongs,
                                                 retaining: retaining)
    }

    private func beginAudioCacheMaintenance() async throws {
        await networkStopTask?.value
        try Task.checkCancellation()
        guard !isManagingAudioCache else { throw AudioCache.ManagementError.clearing }
        isManagingAudioCache = true
        downloadGeneration = UUID()
        prefetchDownload?.task.cancel()
        prefetchDownload = nil
        cancelWarmups(except: [])
    }

    private func checkDownloadGeneration(_ generation: UUID) throws {
        try Task.checkCancellation()
        guard !isManagingAudioCache, generation == downloadGeneration else { throw CancellationError() }
    }

    func discardCached(_ track: Track) async {
        guard let audioCache else { return }
        await audioCache.remove(trackID: track.id)
        log.notice("event=audio_cache_discarded")
    }

    func discardCached(_ track: Track, url: URL?) async {
        guard let url else { await discardCached(track); return }
        await audioCache?.rejectPlaybackFile(url)
        if url.deletingPathExtension().lastPathComponent.contains(".opus-") { recordOpusFailure(track.id) }
        cache.removeValue(forKey: track.id)
    }

    func retainCached(_ trackIDs: Set<String>) async {
        await audioCache?.pin(only: trackIDs)
    }

    nonisolated func isCachedStream(_ stream: ResolvedStream) -> Bool {
        guard let audioCache, stream.url.isFileURL else { return false }
        let url = stream.url.standardizedFileURL
        return url.deletingLastPathComponent().path == audioCache.directory.path
            && AudioDownloader.mediaExtensions.contains(url.pathExtension)
            && AudioCache.logicalTrackID(for: url) != nil
    }

    /// Explicit prefetch downloads follow the first track; Opus resolutions also require complete prepared files.
    /// An empty prefetch leaves a running download alone: there is nothing newer to prefer over it.
    private func schedulePrefetchDownload(_ track: Track?, warmToken: UUID? = nil) {
        let compatibility = synchronizeExtractionCompatibility()
        guard !networkIsOffline, !isManagingAudioCache, audioCache != nil, let track else { return }
        if let current = prefetchDownload, current.trackID == track.id {
            // A newer warm or the queue adopts this download; the old warm token must no longer cancel it.
            if current.warmToken != nil { prefetchDownload?.warmToken = warmToken }
            return
        }
        // The upcoming queue song outranks a guess about the next tap.
        if warmToken != nil, prefetchDownload?.warmToken == nil, prefetchDownload != nil { return }
        prefetchDownload?.task.cancel()
        let token = UUID()
        let task = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            do {
                try Self.checkExtractionCompatibility(compatibility)
                _ = try await self.download(track, speculative: true)
            }
            catch is CancellationError { }
            catch { await self.logPrefetchDownloadFailure() }
            await self.prefetchDownloadFinished(token)
        }
        prefetchDownload = (track.id, token, warmToken, task)
    }

    private func prefetchDownloadFinished(_ token: UUID) {
        if prefetchDownload?.token == token { prefetchDownload = nil }
    }

    private func logPrefetchDownloadFailure() { log.debug("event=prefetch_download_unavailable") }

    private func resolve(track: Track, forceRefresh: Bool, foreground: Bool, speculative: Bool = true,
                         useAudioCache: Bool = true, complete: Bool = false) async throws -> ResolvedStream {
        try await select(track: track, forceRefresh: forceRefresh, foreground: foreground, speculative: speculative,
                         useAudioCache: useAudioCache, complete: complete).stream
    }

    /// `complete` waiters (downloads, the explicit quality reload) accept a wait for a prepared Opus file; everyone
    /// else gets the first playable stream and leaves the better Opus in the entry's `upgrade` for a later download.
    private func select(track: Track, forceRefresh: Bool, foreground: Bool, speculative: Bool,
                         useAudioCache: Bool, complete: Bool) async throws -> Selection {
        let compatibility = synchronizeExtractionCompatibility()
        try Task.checkCancellation()
        // Prefixed ids pass the cache's shape check but belong to another source's resolver.
        guard track.source == .youTubeMusic, AudioCache.isProviderTrackID(track.id) else { throw PlaybackStreamError.invalidID }
        if foreground {
            cancelWarmups(except: [track.id])
            if let warmup = prefetchDownload, warmup.trackID != track.id {
                warmup.task.cancel()
                prefetchDownload = nil
            }
        }
        // A complete local copy never expires, so even a forced refresh prefers it; a bad file is discarded explicitly.
        if useAudioCache, let cached = try await cachedAudio(for: track) {
            try Self.checkExtractionCompatibility(compatibility)
            log.debug("event=audio_cache_hit")
            PlaybackStartTrace.record(.local, for: track.id)
            return Selection(stream: cached.stream, upgrade: nil, path: .local)
        }
        try Self.checkExtractionCompatibility(compatibility)
        try requireNetwork()
        if !forceRefresh, let cached = cache[track.id], cached.extractionGeneration == compatibility,
           let expiry = cached.stream.expiresAt, expiry.timeIntervalSinceNow > 90 {
            touch(track.id)
            log.debug("event=cache_hit")
            PlaybackStartTrace.record(.urlCache, for: track.id)
            try Self.checkExtractionCompatibility(compatibility)
            return Selection(stream: cached.stream, upgrade: cached.upgrade, path: .urlCache)
        }
        cache.removeValue(forKey: track.id)
        recency.removeAll { $0 == track.id }
        let waiter = UUID()
        let key = ResolutionKey(trackID: track.id, fresh: !useAudioCache, extractionGeneration: compatibility)
        var flight: Flight
        if let existing = flights[key] {
            flight = existing
            log.debug("event=joined_extraction")
        } else {
            if !foreground && speculative && flights.values.filter({ !$0.foreground }).count >= 2 { throw CancellationError() }
            let token = UUID()
            // The ceiling is fixed per flight; a change during extraction applies to the next resolution.
            let ceiling = maximumBitRate
            let work = Task.detached(priority: foreground ? .userInitiated : .utility) { [self] in
                do {
                    try Self.checkExtractionCompatibility(compatibility)
                    let result = try await performExtraction(track: track, key: key, token: token, maximumBitRate: ceiling)
                    try Self.checkExtractionCompatibility(compatibility)
                    await finish(key: key, token: token, result: result, maximumBitRate: ceiling)
                    try Self.checkExtractionCompatibility(compatibility)
                    return result
                } catch {
                    await finish(key: key, token: token, result: nil, maximumBitRate: ceiling)
                    throw error
                }
            }
            flight = Flight(token: token, task: work, waiters: [:])
        }
        flight.waiters[waiter] = Waiter(foreground: foreground, speculative: speculative && !foreground, complete: complete)
        flights[key] = flight
        let token = flight.token
        signalHedge(key, token: token)
        let work = flight.task
        return try await withTaskCancellationHandler {
            defer { release(key: key, token: token, waiter: waiter) }
            let result = try await PlaybackDeadline.run(seconds: timeout * 2 + 10) { try await work.value }
            try Self.checkExtractionCompatibility(compatibility)
            if !result.stream.url.isFileURL { try requireNetwork() }
            PlaybackStartTrace.record(result.path, for: track.id)
            return result
        } onCancel: {
            Task { await self.release(key: key, token: token, waiter: waiter) }
        }
    }

    private func release(key: ResolutionKey, token: UUID, waiter: UUID) {
        guard var flight = flights[key], flight.token == token,
              flight.waiters.removeValue(forKey: waiter) != nil else { return }
        if flight.waiters.isEmpty {
            flights.removeValue(forKey: key)
            flight.cancel()
        } else { flights[key] = flight }
    }

    private func cancelWarmups(except ids: Set<String>) {
        for (key, flight) in flights where !ids.contains(key.trackID) && !flight.foreground {
            flights.removeValue(forKey: key)
            flight.cancel()
        }
    }

    private func touch(_ id: String) {
        recency.removeAll { $0 == id }
        recency.append(id)
    }

    private func finish(key: ResolutionKey, token: UUID, result: Selection?, maximumBitRate ceiling: Int?) {
        guard flights[key]?.token == token else { return }
        flights.removeValue(forKey: key)
        guard key.extractionGeneration == YouTubeKitHooks.extractionCompatibility.generation else { return }
        let trackID = key.trackID
        guard let result, (result.stream.expiresAt?.timeIntervalSinceNow ?? 0) > 90 else { return }
        for id in recency where (cache[id]?.stream.expiresAt?.timeIntervalSinceNow ?? 0) <= 90 {
            cache.removeValue(forKey: id)
        }
        recency.removeAll { cache[$0] == nil }
        // A flight that outlived a preference change still plays, but must not be reused under the new ceiling.
        let entry = URLEntry(extractionGeneration: key.extractionGeneration, stream: result.stream,
                             maximumBitRate: ceiling, upgrade: result.upgrade)
        guard Self.entryFits(entry, maximumBitRate: maximumBitRate) else { return }
        cache[trackID] = entry
        touch(trackID)
        while recency.count > cacheCapacity { cache.removeValue(forKey: recency.removeFirst()) }
    }

    private enum HedgeOutcome: Sendable {
        case fast(Result<Selection, any Error>, aacFallbacks: [ResolvedStream])
        case hedgeElapsed
        case extraction(Result<Selection, any Error>)
    }

    private func signalHedge(_ key: ResolutionKey, token: UUID, elapsed: Bool = false) {
        guard key.extractionGeneration == YouTubeKitHooks.extractionCompatibility.generation else { return }
        guard var flight = flights[key], flight.token == token else { return }
        flight.hedgeElapsed = flight.hedgeElapsed || elapsed
        let signal = flight.hedgeElapsed && flight.foreground && !flight.hedgePending && flight.hedgeFeed != nil
        if signal { flight.hedgePending = true }
        flights[key] = flight
        if signal { flight.hedgeFeed?.yield(.hedgeElapsed) }
    }

    private func clearHedgeFeed(_ key: ResolutionKey, token: UUID) {
        guard flights[key]?.token == token else { return }
        flights[key]?.hedgeFeed = nil
        flights[key]?.hedgePending = false
    }

    /// Foreground flights race the fast path against YouTubeKit: extraction starts when the fast path fails or, with a
    /// hedge delay, once it has been silent that long; the first validated stream wins and the loser is cancelled.
    private func performExtraction(track: Track, key: ResolutionKey, token: UUID, maximumBitRate ceiling: Int?) async throws -> Selection {
        try Self.checkExtractionCompatibility(key.extractionGeneration)
        try requireNetwork()
        guard let fastExtract else {
            // Speculation never enters YouTubeKit's serialized JS path; foreground waiters can promote a shared warmup.
            guard allowsExtraction(key, token: token) else { throw PlaybackStreamError.noAudio }
            do { return try await extractionResolution(track: track, key: key, token: token, maximumBitRate: ceiling) }
            catch {
                try Self.checkExtractionCompatibility(key.extractionGeneration)
                if error is CancellationError { throw error }
                return try await fallbackOrFail(error, track: track, key: key, aacFallbacks: [], maximumBitRate: ceiling)
            }
        }
        // One fast result, one extraction result and one coalesced eligibility event can be pending.
        let (outcomes, feed) = AsyncStream<HedgeOutcome>.makeStream(bufferingPolicy: .bufferingOldest(3))
        guard flights[key]?.token == token else { throw CancellationError() }
        flights[key]?.hedgeFeed = feed
        let priority = Task.currentPriority
        let fast = Task.detached(priority: priority) { [self] in
            feed.yield(await fastPathOutcome(track: track, key: key, maximumBitRate: ceiling, fastExtract: fastExtract))
        }
        var timer: Task<Void, Never>?
        if let hedgeDelay {
            timer = Task.detached(priority: priority) { [self, hedgeSleep] in
                do { try await hedgeSleep(hedgeDelay) } catch { return }
                if !Task.isCancelled { await signalHedge(key, token: token, elapsed: true) }
            }
        }
        var extraction: Task<Void, Never>?
        defer {
            fast.cancel()
            timer?.cancel()
            extraction?.cancel()
            clearHedgeFeed(key, token: token)
            feed.finish()
        }
        func startExtraction() {
            extraction = Task.detached(priority: priority) { [self] in
                let result: Result<Selection, any Error>
                do { result = .success(try await extractionResolution(track: track, key: key, token: token, maximumBitRate: ceiling)) }
                catch { result = .failure(error) }
                feed.yield(.extraction(result))
            }
        }
        var fastFinished = false
        var aacFallbacks: [ResolvedStream] = []
        var extractionFailure: (any Error)?
        for await outcome in outcomes {
            try Self.checkExtractionCompatibility(key.extractionGeneration)
            switch outcome {
            case .fast(.success(let selection), _):
                return selection
            case .fast(.failure(let error), let fallbacks):
                fastFinished = true
                aacFallbacks = fallbacks
                if error is CancellationError { throw error }
                try requireNetwork()
                if let extractionFailure {
                    return try await fallbackOrFail(extractionFailure, track: track, key: key, aacFallbacks: aacFallbacks, maximumBitRate: ceiling)
                }
                if extraction == nil {
                    guard allowsExtraction(key, token: token) else { throw PlaybackStreamError.noAudio }
                    startExtraction()
                }
            case .hedgeElapsed:
                if flights[key]?.token == token { flights[key]?.hedgePending = false }
                if extraction == nil, !fastFinished, allowsExtraction(key, token: token) {
                    log.info("event=extraction_hedge started=1")
                    startExtraction()
                }
            case .extraction(.success(let selection)):
                if !fastFinished { log.info("event=extraction_hedge outcome=extraction_won") }
                return selection
            case .extraction(.failure(let error)):
                if error is CancellationError { throw error }
                extractionFailure = error
                // The fast path may still answer; only after both failed does the clear AAC fallback get its turn.
                if fastFinished {
                    return try await fallbackOrFail(error, track: track, key: key, aacFallbacks: aacFallbacks, maximumBitRate: ceiling)
                }
            }
        }
        try Self.checkExtractionCompatibility(key.extractionGeneration)
        throw extractionFailure ?? PlaybackStreamError.noAudio
    }

    private func allowsExtraction(_ key: ResolutionKey, token: UUID) -> Bool {
        key.extractionGeneration == YouTubeKitHooks.extractionCompatibility.generation
            && flights[key]?.token == token && flights[key]?.foreground == true
    }

    private func fastPathOutcome(track: Track, key: ResolutionKey, maximumBitRate ceiling: Int?,
                                 fastExtract: @escaping CappedFastExtraction) async -> HedgeOutcome {
        var aacFallbacks: [ResolvedStream] = []
        do {
            try Self.checkExtractionCompatibility(key.extractionGeneration)
            let fast = try await PlaybackDeadline.run(seconds: min(timeout, 6)) { try await fastExtract(track.id, ceiling) }
            try Self.checkExtractionCompatibility(key.extractionGeneration)
            aacFallbacks = fast.aacFallbacks
            guard !fast.streams.isEmpty else { throw PlaybackStreamError.noAudio }
            let pick = try await validated(track: track, key: key, streams: fast.streams + aacFallbacks, maximumBitRate: ceiling)
            log.info("event=direct_audio_resolved bitrate=\(pick.stream.quality?.bitRate ?? 0)")
            return .fast(.success(Selection(stream: pick.stream, upgrade: pick.upgrade, path: .fastPath)), aacFallbacks: aacFallbacks)
        } catch {
            return .fast(.failure(error), aacFallbacks: aacFallbacks)
        }
    }

    private func extractionResolution(track: Track, key: ResolutionKey, token: UUID, maximumBitRate ceiling: Int?) async throws -> Selection {
        var remote = false
        while true {
            try Self.checkExtractionCompatibility(key.extractionGeneration)
            try requireNetwork()
            guard allowsExtraction(key, token: token) else { throw CancellationError() }
            let methodIsRemote = remote
            let start = ContinuousClock.now
            do {
                // YouTubeKit exposes no loudness or play-count metadata, so fallback streams play at unity gain.
                let streams = try await PlaybackDeadline.run(seconds: timeout) { [extract] in try await extract(track.id, methodIsRemote) }
                try Self.checkExtractionCompatibility(key.extractionGeneration)
                let pick = try await validated(track: track, key: key, streams: streams, maximumBitRate: ceiling)
                try Self.checkExtractionCompatibility(key.extractionGeneration)
                log.info("event=resolved remote=\(methodIsRemote) bitrate=\(pick.stream.quality?.bitRate ?? 0) elapsed=\(String(describing: start.duration(to: .now)), privacy: .public)")
                return Selection(stream: pick.stream, upgrade: pick.upgrade, path: methodIsRemote ? .remote : .extraction)
            } catch {
                try Self.checkExtractionCompatibility(key.extractionGeneration)
                if error is CancellationError { throw error }
                try requireNetwork()
                log.notice("event=resolution_failed remote=\(methodIsRemote)")
                guard !remote && allowRemoteFallback else { throw error }
                remote = true
                log.info("event=remote_fallback")
            }
        }
    }

    /// Every network path failed: the fast path's clear AAC is the last resort, then the failure names the listener's fix.
    private func fallbackOrFail(_ error: any Error, track: Track, key: ResolutionKey, aacFallbacks: [ResolvedStream],
                                maximumBitRate ceiling: Int?) async throws -> Selection {
        try Self.checkExtractionCompatibility(key.extractionGeneration)
        if !aacFallbacks.isEmpty {
            do {
                let pick = try await validated(track: track, key: key, streams: aacFallbacks, maximumBitRate: ceiling)
                return Selection(stream: pick.stream, upgrade: pick.upgrade, path: .fastPath)
            } catch is CancellationError { throw CancellationError() }
            catch { try Task.checkCancellation() }
        }
        // After a recent bot check, an empty or generic failure means the gate is still up; name the fix.
        if case PlaybackStreamError.noAudio = error, Self.signInWouldHelp() { throw PlaybackStreamError.signInRequired }
        if error is PlaybackStreamError || error is MusicServiceError { throw error }
        if let networkError = error as? URLError { throw MusicServiceError.network(networkError.localizedDescription) }
        if Self.signInWouldHelp() { throw PlaybackStreamError.signInRequired }
        throw MusicServiceError.unavailable("Audio couldn’t be loaded from YouTube. Please try again.")
    }

    /// YouTube's bot gate is dynamic, so only a check from the last 15 minutes without an account to answer it counts.
    private static func signInWouldHelp(now: Date = Date()) -> Bool {
        let registry = YouTubeSessionRegistry.shared
        guard registry.session == nil, let checkedAt = registry.lastBotCheckAt else { return false }
        return now.timeIntervalSince(checkedAt) < 15 * 60
    }

    /// Fast start: with a clear AAC on offer the listener hears it after one range probe and the better Opus becomes
    /// the pick's `upgrade`; only complete downloads and the explicit reload still wait for an Opus preparation.
    private func validated(track: Track, key: ResolutionKey, streams: [ResolvedStream],
                           maximumBitRate ceiling: Int?) async throws -> Pick {
        try Self.checkExtractionCompatibility(key.extractionGeneration)
        guard streams.allSatisfy({ $0.url.isFileURL || $0.extractionGeneration == nil || $0.extractionGeneration == key.extractionGeneration }) else {
            throw CancellationError()
        }
        let preparationGeneration = downloadGeneration
        var lastError: any Error = PlaybackStreamError.noAudio
        var seen = Set<URL>()
        let ordered = SourceAudioQuality.ranked(streams, maximumBitRate: ceiling, quality: \.quality)
            .filter { seen.insert($0.url).inserted }
            .map { candidate in
                var stream = candidate
                if !stream.url.isFileURL { stream.playbackSource = .youTubeMusic }
                stream.extractionGeneration = stream.url.isFileURL ? nil : key.extractionGeneration
                return stream
            }
        let opus = Array(ordered.filter { $0.quality?.codec == .opus }.prefix(3))
        let aac = Array(ordered.filter { $0.quality?.codec != .opus }.prefix(3))
        var candidates = SourceAudioQuality.ranked(opus + aac, maximumBitRate: ceiling, quality: \.quality)
        // An Opus that outranks every AAC is the upgrade a complete download prepares whenever an AAC is handed out.
        let upgrade = opusEnabled && candidates.first?.quality?.codec == .opus ? candidates.first : nil
        if flights[key]?.wantsCompleteOnly != true, !aac.isEmpty, upgrade != nil {
            // Opus moves behind every AAC so it is still the last resort when no AAC validates.
            candidates = candidates.filter { $0.quality?.codec != .opus } + candidates.filter { $0.quality?.codec == .opus }
            log.info("event=fast_start codec=aac upgrade=opus")
        }
        let bestOffered = streams.compactMap { $0.quality?.bitRate }.max() ?? 0
        for stream in candidates {
            let url = stream.url
            do {
                try Self.checkExtractionCompatibility(key.extractionGeneration)
                if !url.isFileURL { try requireNetwork() }
                if let expiry = PlaybackTiming.expiry(in: url), expiry.timeIntervalSinceNow <= 30 { throw PlaybackStreamError.expired }
                if stream.quality?.codec == .opus {
                    guard opusEnabled, (opusFailures[track.id]?.timeIntervalSinceNow ?? 0) <= 0, let audioCache else { continue }
                    try StreamValidation.validateSourceURL(url)
                    let started = ContinuousClock.now
                    do {
                        try checkDownloadGeneration(preparationGeneration)
                        let permit = try await audioCache.writePermit()
                        try Self.checkExtractionCompatibility(key.extractionGeneration)
                        try checkDownloadGeneration(preparationGeneration)
                        let foreground = flights[key]?.foreground == true
                        let speculative = flights[key]?.isSpeculative == true
                        let cached = try await PlaybackDeadline.run(seconds: min(timeout, opusTimeout)) {
                            try await audioCache.storeOpus(trackID: track.id, stream: stream, permit: permit, foreground: foreground,
                                                          track: track, speculative: speculative)
                        }
                        try Self.checkExtractionCompatibility(key.extractionGeneration)
                        try checkDownloadGeneration(preparationGeneration)
                        log.info("event=opus_prepared_for_playback bytes=\(cached.bytes) elapsed=\(String(describing: started.duration(to: .now)), privacy: .public)")
                        logSelection(stream.quality, ceiling: ceiling, bestOffered: bestOffered)
                        return Pick(stream: cached.stream, upgrade: nil)
                    } catch {
                        try Self.checkExtractionCompatibility(key.extractionGeneration)
                        // Maintenance retires disk writers; the current playback intent can still use AAC or retained audio.
                        if isManagingAudioCache || preparationGeneration != downloadGeneration {
                            lastError = AudioCache.ManagementError.clearing
                            log.notice("event=opus_preparation_deferred reason=cache_maintenance fallback=aac")
                            continue
                        }
                        if case AudioCache.ManagementError.admissionDeferred = error {
                            lastError = error
                            log.debug("event=opus_preparation_deferred admission=1")
                            continue
                        }
                        if error is CancellationError { throw error }
                        recordOpusFailure(track.id)
                        let reason = OpusPreparationError.diagnosticReason(error)
                        log.notice("event=opus_preparation_failed reason=\(reason, privacy: .public) fallback=aac")
                        lastError = error
                        continue
                    }
                }
                try await PlaybackDeadline.run(seconds: min(timeout, 10)) { [validate] in try await validate(url) }
                try Self.checkExtractionCompatibility(key.extractionGeneration)
                if !url.isFileURL { try requireNetwork() }
                logSelection(stream.quality, ceiling: ceiling, bestOffered: bestOffered)
                let stream = ResolvedStream(url: url,
                    duration: PlaybackTiming.validDuration(PlaybackTiming.queryNumber("dur", in: url))
                        ?? PlaybackTiming.validDuration(track.duration), expiresAt: PlaybackTiming.expiry(in: url),
                    loudnessDb: stream.loudnessDb, viewCount: stream.viewCount, quality: stream.quality,
                    playbackSource: stream.playbackSource, extractionGeneration: stream.extractionGeneration)
                return Pick(stream: stream, upgrade: upgrade)
            } catch {
                try Self.checkExtractionCompatibility(key.extractionGeneration)
                if error is CancellationError { throw error }
                if case PlaybackStreamError.httpStatus(403) = error { throw error }
                lastError = error
            }
        }
        throw lastError
    }

    /// `capped` records that the ceiling passed over a higher offered format; `fits` that the pick is within the ceiling.
    private func logSelection(_ quality: SourceAudioQuality?, ceiling: Int?, bestOffered: Int) {
        let bitRate = quality?.bitRate ?? 0
        let capped = ceiling != nil && bestOffered > bitRate
        let fits = SourceAudioQuality.fits(quality, maximumBitRate: ceiling)
        let preference = AudioQualityPreference.allCases.first { $0.maximumBitRate == ceiling } ?? .best
        log.info("event=audio_quality_selected preference=\(preference.rawValue, privacy: .public) codec=\(quality?.codec == .opus ? "opus" : "aac", privacy: .public) bitRate=\(bitRate) capped=\(capped ? 1 : 0) fits=\(fits ? 1 : 0)")
    }

    private func recordOpusFailure(_ id: String) {
        opusFailures = opusFailures.filter { $0.value.timeIntervalSinceNow > 0 }
        if opusFailures.count >= cacheCapacity, let oldest = opusFailures.min(by: { $0.value < $1.value })?.key {
            opusFailures.removeValue(forKey: oldest)
        }
        opusFailures[id] = Date().addingTimeInterval(60)
    }
}

actor YouTubeExtractionWorker {
    static let shared = YouTubeExtractionWorker()
    private var tail: Task<Void, Never>?
    private var generation = YouTubeKitHooks.extractionCompatibility.generation
    private var pending: [UUID: Task<[ResolvedStream], Error>] = [:]

    func invalidateExtractionCompatibility() {
        let current = YouTubeKitHooks.extractionCompatibility.generation
        guard current != generation else { return }
        generation = current
        pending.values.forEach { $0.cancel() }
        // A cancelled JavaScript call may still be unwinding; retain its tail as the serialization barrier.
    }

    func extract(id: String, remote: Bool) async throws -> [ResolvedStream] {
        invalidateExtractionCompatibility()
        let compatibility = generation
        try YouTubeStreamResolver.checkExtractionCompatibility(compatibility)
        guard pending.count < 32 else {
            Logger(subsystem: "com.agraabhi.ganabajana", category: "StreamResolver")
                .debug("event=extractor_resolution outcome=queue_full")
            throw CancellationError()
        }
        let token = UUID()
        let predecessor = remote ? nil : tail
        // YouTubeKit 0.4.9 has a process-wide, unsynchronized player-JS cache; extraction jobs must not overlap.
        let work = Task.detached(priority: .userInitiated) {
            await predecessor?.value
            try YouTubeStreamResolver.checkExtractionCompatibility(compatibility)
            let methods: [YouTube.ExtractionMethod] = remote ? [.remote] : [.local]
            let streams = try await YouTube(videoID: id, methods: methods).streams
            try YouTubeStreamResolver.checkExtractionCompatibility(compatibility)
            return streams.filterAudioOnly()
                .filter { ($0.fileExtension == .m4a && $0.audioCodec == .mp4a && $0.isNativelyPlayable)
                    || ($0.fileExtension == .webm && $0.audioCodec == AudioCodec.opus) }
                .sorted {
                    (SourceAudioQuality.preferredBitRate(average: $0.averageBitrate, advertised: $0.bitrate) ?? 0)
                        > (SourceAudioQuality.preferredBitRate(average: $1.averageBitrate, advertised: $1.bitrate) ?? 0)
                }
                .map { stream in
                    let quality: SourceAudioQuality?
                    if case .opus? = stream.audioCodec {
                        quality = SourceAudioQuality(codec: .opus,
                            bitRate: SourceAudioQuality.preferredBitRate(average: stream.averageBitrate, advertised: stream.bitrate))
                    } else if case .mp4a(let version)? = stream.audioCodec,
                       let codec = SourceAudioQuality.Codec(rawValue: "mp4a.\(version)") {
                        quality = SourceAudioQuality(codec: codec,
                            bitRate: SourceAudioQuality.preferredBitRate(average: stream.averageBitrate, advertised: stream.bitrate))
                    } else { quality = nil }
                    return ResolvedStream(url: stream.url, quality: quality, extractionGeneration: compatibility)
                }
        }
        pending[token] = work
        defer { pending.removeValue(forKey: token) }
        if !remote { tail = Task { _ = try? await work.value } }
        return try await withTaskCancellationHandler {
            let result = try await work.value
            try YouTubeStreamResolver.checkExtractionCompatibility(compatibility)
            return result
        } onCancel: { work.cancel() }
    }
}

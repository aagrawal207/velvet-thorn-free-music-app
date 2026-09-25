import Foundation
import OSLog
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

actor YouTubeStreamResolver: StreamCacheManaging {
    nonisolated static let offlineMessage = "You’re offline and this song isn’t cached on this device. Connect to the internet and try again."
    typealias Extraction = @Sendable (_ videoID: String, _ remote: Bool) async throws -> [URL]
    typealias QualityExtraction = @Sendable (_ videoID: String, _ remote: Bool) async throws -> [ResolvedStream]
    typealias FastExtraction = @Sendable (_ videoID: String) async throws -> FastPathResult
    typealias Validation = @Sendable (URL) async throws -> Void

    private var allowRemoteFallback: Bool
    private let extract: QualityExtraction
    private let validate: Validation
    private let timeout: TimeInterval
    private let fastExtract: FastExtraction?
    private let cacheCapacity: Int
    private let audioCache: AudioCache?
    private let opusEnabled: Bool
    private let opusTimeout: TimeInterval
    private let isOffline: @Sendable () -> Bool
    private var networkOffline = false
    private var networkStopTask: Task<Void, Never>?
    private var opusFailures: [String: Date] = [:]
    private var cache: [String: ResolvedStream] = [:]
    private var recency: [String] = []
    private struct Flight {
        let token: UUID
        let task: Task<ResolvedStream, Error>
        var waiters: [UUID: Bool]
        var nonSpeculativeWaiters: Set<UUID> = []
        var foreground: Bool { waiters.values.contains(true) }
        var isSpeculative: Bool { !foreground && nonSpeculativeWaiters.isEmpty }
    }
    private struct ResolutionKey: Hashable, Sendable {
        let trackID: String
        let fresh: Bool
    }
    private var flights: [ResolutionKey: Flight] = [:]
    private var prefetchDownload: (trackID: String, token: UUID, task: Task<Void, Never>)?
    private var downloadGeneration = UUID()
    private var isManagingAudioCache = false
    var activeWaiterCount: Int { flights.values.reduce(0) { $0 + $1.waiters.count } }
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
        fastExtract = { try await YouTubeAudioFastPath.extract(videoID: $0) }
        cacheCapacity = 24
        audioCache = AudioCache()
        opusEnabled = OpusNativeAudio.isSupported
        opusTimeout = 12
        self.isOffline = isOffline
    }

    /// Without an `audioCache` nothing is written to disk and `download` is unavailable; tests opt in explicitly.
    init(allowRemoteFallback: Bool = false, timeout: TimeInterval = 35, cacheCapacity: Int = 24,
         extract: @escaping Extraction, validate: @escaping Validation,
         fastExtract: FastExtraction? = nil, audioCache: AudioCache? = nil, qualityExtract: QualityExtraction? = nil,
         opusEnabled: Bool = false, opusTimeout: TimeInterval = 12, isOffline: @escaping @Sendable () -> Bool = { false }) {
        self.allowRemoteFallback = allowRemoteFallback
        self.extract = qualityExtract ?? { id, remote in
            try await extract(id, remote).map { ResolvedStream(url: $0) }
        }
        self.validate = validate
        self.timeout = timeout
        self.fastExtract = fastExtract
        self.cacheCapacity = max(1, cacheCapacity)
        self.audioCache = audioCache
        self.opusEnabled = opusEnabled
        self.opusTimeout = opusTimeout
        self.isOffline = isOffline
    }

    func setRemoteFallbackEnabled(_ enabled: Bool) {
        allowRemoteFallback = enabled
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
        pending.forEach { $0.task.cancel() }
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
        try await resolve(track: track, forceRefresh: forceRefresh, foreground: true)
    }

    /// An explicit quality reload bypasses the saved copy without replacing a file an AVPlayer may still be reading.
    func refreshQuality(track: Track) async throws -> ResolvedStream {
        if networkIsOffline { return try await resolve(track: track, forceRefresh: false) }
        opusFailures.removeValue(forKey: track.id)
        do {
            let fresh = try await PlaybackDeadline.run(seconds: min(timeout * 2, 60)) { [self] in
                try await resolve(track: track, forceRefresh: true, foreground: true, useAudioCache: false)
            }
            let cached = try await cachedAudio(for: track)
            try Task.checkCancellation()
            if let cached, let savedRate = cached.quality?.bitRate, (fresh.quality?.bitRate ?? 0) <= savedRate {
                log.info("event=audio_quality_refresh outcome=cached_not_lower")
                return cached.stream
            }
            log.info("event=audio_quality_refresh outcome=fresh bitrate=\(fresh.quality?.bitRate ?? 0)")
            return fresh
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            if case PlaybackStreamError.invalidID = error { throw error }
            if let cached = try await cachedAudio(for: track) {
                try Task.checkCancellation()
                log.notice("event=audio_quality_refresh outcome=cached_after_failure")
                return cached.stream
            }
            throw error
        }
    }

    func prefetch(_ tracks: [Track]) async {
        guard !Task.isCancelled, !networkIsOffline, !isManagingAudioCache, fastExtract != nil,
              !flights.values.contains(where: \.foreground) else { return }
        let generation = downloadGeneration
        var seen = Set<String>()
        let selected = Array(tracks.filter { $0.isAudioRecording != false && seen.insert($0.id).inserted }.prefix(2))
        cancelWarmups(except: Set(selected.map(\.id)))
        schedulePrefetchDownload(selected.first)
        for track in selected {
            guard !Task.isCancelled, !networkIsOffline, generation == downloadGeneration,
                  !flights.values.contains(where: \.foreground) else { return }
            do { _ = try await resolve(track: track, forceRefresh: false, foreground: false) }
            catch is CancellationError { return }
            catch { log.debug("event=prefetch_unavailable") }
        }
    }

    func download(_ track: Track) async throws -> ResolvedStream {
        try await download(track, speculative: false)
    }

    private func download(_ track: Track, speculative: Bool) async throws -> ResolvedStream {
        guard let audioCache else { throw MusicServiceError.unavailable("Audio caching is not available.") }
        guard AudioCache.isProviderTrackID(track.id) else { throw PlaybackStreamError.invalidID }
        let generation = downloadGeneration
        try Task.checkCancellation()
        activeDownloadCount += 1
        defer { activeDownloadCount -= 1 }
        if let cached = try await cachedAudio(for: track) {
            try Task.checkCancellation()
            return cached.stream
        }
        try requireNetwork()
        let permit = try await audioCache.writePermit()
        try checkDownloadGeneration(generation)
        // A listener-initiated resolution owns the network until it finishes; downloads are never in its way.
        while flights.values.contains(where: \.foreground) {
            try await Task.sleep(for: .milliseconds(150))
            try checkDownloadGeneration(generation)
            try requireNetwork()
        }
        let stream = try await resolve(track: track, forceRefresh: false, foreground: false, speculative: speculative)
        try checkDownloadGeneration(generation)
        if stream.url.isFileURL { return stream }
        try requireNetwork()
        let cached = try await audioCache.store(trackID: track.id, from: stream.url, stream: stream, permit: permit,
                                               track: track, speculative: speculative)
        try checkDownloadGeneration(generation)
        log.info("event=audio_cached bytes=\(cached.bytes)")
        if cached.duration != nil { return cached.stream }
        guard let prepared = try await cachedAudio(for: track) else { throw PlaybackStreamError.invalidMedia }
        try checkDownloadGeneration(generation)
        return prepared.stream
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
    private func schedulePrefetchDownload(_ track: Track?) {
        guard !networkIsOffline, !isManagingAudioCache, audioCache != nil, let track else { return }
        if let current = prefetchDownload, current.trackID == track.id { return }
        prefetchDownload?.task.cancel()
        let token = UUID()
        let task = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            do { _ = try await self.download(track, speculative: true) }
            catch is CancellationError { }
            catch { await self.logPrefetchDownloadFailure() }
            await self.prefetchDownloadFinished(token)
        }
        prefetchDownload = (track.id, token, task)
    }

    private func prefetchDownloadFinished(_ token: UUID) {
        if prefetchDownload?.token == token { prefetchDownload = nil }
    }

    private func logPrefetchDownloadFailure() { log.debug("event=prefetch_download_unavailable") }

    private func resolve(track: Track, forceRefresh: Bool, foreground: Bool, speculative: Bool = true,
                         useAudioCache: Bool = true) async throws -> ResolvedStream {
        try Task.checkCancellation()
        guard AudioCache.isProviderTrackID(track.id) else { throw PlaybackStreamError.invalidID }
        if foreground {
            cancelWarmups(except: [track.id])
            if let warmup = prefetchDownload, warmup.trackID != track.id {
                warmup.task.cancel()
                prefetchDownload = nil
            }
        }
        // A complete local copy never expires, so even a forced refresh prefers it; a bad file is discarded explicitly.
        if useAudioCache, let cached = try await cachedAudio(for: track) {
            try Task.checkCancellation()
            log.debug("event=audio_cache_hit")
            return cached.stream
        }
        try requireNetwork()
        if !forceRefresh, let cached = cache[track.id], let expiry = cached.expiresAt, expiry.timeIntervalSinceNow > 90 {
            touch(track.id)
            log.debug("event=cache_hit")
            return cached
        }
        cache.removeValue(forKey: track.id)
        recency.removeAll { $0 == track.id }
        let waiter = UUID()
        let key = ResolutionKey(trackID: track.id, fresh: !useAudioCache)
        var flight: Flight
        if let existing = flights[key] {
            flight = existing
            log.debug("event=joined_extraction")
        } else {
            if !foreground && speculative && flights.values.filter({ !$0.foreground }).count >= 2 { throw CancellationError() }
            let token = UUID()
            let work = Task.detached(priority: foreground ? .userInitiated : .utility) { [self] in
                do {
                    let result = try await performExtraction(track: track, key: key, token: token)
                    try Task.checkCancellation()
                    await finish(key: key, token: token, result: result)
                    return result
                } catch {
                    await finish(key: key, token: token, result: nil)
                    throw error
                }
            }
            flight = Flight(token: token, task: work, waiters: [:])
        }
        flight.waiters[waiter] = foreground
        if foreground || !speculative { flight.nonSpeculativeWaiters.insert(waiter) }
        flights[key] = flight
        let token = flight.token
        let work = flight.task
        return try await withTaskCancellationHandler {
            defer { release(key: key, token: token, waiter: waiter) }
            let result = try await PlaybackDeadline.run(seconds: timeout * 2 + 10) { try await work.value }
            try Task.checkCancellation()
            if !result.url.isFileURL { try requireNetwork() }
            return result
        } onCancel: {
            Task { await self.release(key: key, token: token, waiter: waiter) }
        }
    }

    private func release(key: ResolutionKey, token: UUID, waiter: UUID) {
        guard var flight = flights[key], flight.token == token,
              flight.waiters.removeValue(forKey: waiter) != nil else { return }
        flight.nonSpeculativeWaiters.remove(waiter)
        if flight.waiters.isEmpty {
            flights.removeValue(forKey: key)
            flight.task.cancel()
        } else { flights[key] = flight }
    }

    private func cancelWarmups(except ids: Set<String>) {
        for (key, flight) in flights where !ids.contains(key.trackID) && !flight.foreground {
            flights.removeValue(forKey: key)
            flight.task.cancel()
        }
    }

    private func touch(_ id: String) {
        recency.removeAll { $0 == id }
        recency.append(id)
    }

    private func finish(key: ResolutionKey, token: UUID, result: ResolvedStream?) {
        guard flights[key]?.token == token else { return }
        flights.removeValue(forKey: key)
        let trackID = key.trackID
        guard let result, (result.expiresAt?.timeIntervalSinceNow ?? 0) > 90 else { return }
        for id in recency where (cache[id]?.expiresAt?.timeIntervalSinceNow ?? 0) <= 90 {
            cache.removeValue(forKey: id)
        }
        recency.removeAll { cache[$0] == nil }
        cache[trackID] = result
        touch(trackID)
        while recency.count > cacheCapacity { cache.removeValue(forKey: recency.removeFirst()) }
    }

    private func performExtraction(track: Track, key: ResolutionKey, token: UUID) async throws -> ResolvedStream {
        try requireNetwork()
        var aacFallbacks: [ResolvedStream] = []
        if let fastExtract {
            do {
                let fast = try await PlaybackDeadline.run(seconds: min(timeout, 6)) { try await fastExtract(track.id) }
                aacFallbacks = fast.aacFallbacks
                guard !fast.streams.isEmpty else { throw PlaybackStreamError.noAudio }
                let result = try await validated(track: track, key: key, streams: fast.streams + aacFallbacks)
                log.info("event=direct_audio_resolved bitrate=\(result.quality?.bitRate ?? 0)")
                return result
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                try requireNetwork()
            }
        }
        // Speculation never enters YouTubeKit's serialized JS path; foreground waiters can promote a shared warmup.
        guard flights[key]?.token == token, flights[key]?.foreground == true else { throw PlaybackStreamError.noAudio }
        var remote = false
        while true {
            try requireNetwork()
            let methodIsRemote = remote
            let start = ContinuousClock.now
            do {
                // YouTubeKit exposes no loudness or play-count metadata, so fallback streams play at unity gain.
                let streams = try await PlaybackDeadline.run(seconds: timeout) { [extract] in try await extract(track.id, methodIsRemote) }
                let result = try await validated(track: track, key: key, streams: streams)
                try Task.checkCancellation()
                log.info("event=resolved remote=\(methodIsRemote) bitrate=\(result.quality?.bitRate ?? 0) elapsed=\(String(describing: start.duration(to: .now)), privacy: .public)")
                return result
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                try requireNetwork()
                log.notice("event=resolution_failed remote=\(methodIsRemote)")
                guard !remote && allowRemoteFallback else {
                    if !aacFallbacks.isEmpty {
                        do { return try await validated(track: track, key: key, streams: aacFallbacks) }
                        catch is CancellationError { throw CancellationError() }
                        catch { try Task.checkCancellation() }
                    }
                    // After a recent bot check, an empty or generic failure means the gate is still up; name the fix.
                    if case PlaybackStreamError.noAudio = error, Self.signInWouldHelp() { throw PlaybackStreamError.signInRequired }
                    if error is PlaybackStreamError || error is MusicServiceError { throw error }
                    if let networkError = error as? URLError { throw MusicServiceError.network(networkError.localizedDescription) }
                    if Self.signInWouldHelp() { throw PlaybackStreamError.signInRequired }
                    throw MusicServiceError.unavailable("Audio couldn’t be loaded from YouTube. Please try again.")
                }
                remote = true
                log.info("event=remote_fallback")
            }
        }
    }

    /// YouTube's bot gate is dynamic, so only a check from the last 15 minutes without an account to answer it counts.
    private static func signInWouldHelp(now: Date = Date()) -> Bool {
        let registry = YouTubeSessionRegistry.shared
        guard registry.session == nil, let checkedAt = registry.lastBotCheckAt else { return false }
        return now.timeIntervalSince(checkedAt) < 15 * 60
    }

    private func validated(track: Track, key: ResolutionKey, streams: [ResolvedStream]) async throws -> ResolvedStream {
        try Task.checkCancellation()
        let preparationGeneration = downloadGeneration
        var lastError: any Error = PlaybackStreamError.noAudio
        var seen = Set<URL>()
        let ordered = streams.sorted { SourceAudioQuality.prefers($0.quality, over: $1.quality) }
            .filter { seen.insert($0.url).inserted }
        let opus = Array(ordered.filter { $0.quality?.codec == .opus }.prefix(3))
        let aac = Array(ordered.filter { $0.quality?.codec != .opus }.prefix(3))
        let candidates = (opus + aac).sorted { SourceAudioQuality.prefers($0.quality, over: $1.quality) }
        for stream in candidates {
            let url = stream.url
            do {
                if !url.isFileURL { try requireNetwork() }
                if let expiry = PlaybackTiming.expiry(in: url), expiry.timeIntervalSinceNow <= 30 { throw PlaybackStreamError.expired }
                if stream.quality?.codec == .opus {
                    guard opusEnabled, (opusFailures[track.id]?.timeIntervalSinceNow ?? 0) <= 0, let audioCache else { continue }
                    try StreamValidation.validateSourceURL(url)
                    let started = ContinuousClock.now
                    do {
                        try checkDownloadGeneration(preparationGeneration)
                        let permit = try await audioCache.writePermit()
                        try checkDownloadGeneration(preparationGeneration)
                        let foreground = flights[key]?.foreground == true
                        let speculative = flights[key]?.isSpeculative == true
                        let cached = try await PlaybackDeadline.run(seconds: min(timeout, opusTimeout)) {
                            try await audioCache.storeOpus(trackID: track.id, stream: stream, permit: permit, foreground: foreground,
                                                          track: track, speculative: speculative)
                        }
                        try checkDownloadGeneration(preparationGeneration)
                        log.info("event=opus_prepared_for_playback bytes=\(cached.bytes) elapsed=\(String(describing: started.duration(to: .now)), privacy: .public)")
                        return cached.stream
                    } catch {
                        try Task.checkCancellation()
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
                try Task.checkCancellation()
                if !url.isFileURL { try requireNetwork() }
                return ResolvedStream(url: url,
                    duration: PlaybackTiming.validDuration(PlaybackTiming.queryNumber("dur", in: url))
                        ?? PlaybackTiming.validDuration(track.duration), expiresAt: PlaybackTiming.expiry(in: url),
                    loudnessDb: stream.loudnessDb, viewCount: stream.viewCount, quality: stream.quality)
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                if case PlaybackStreamError.httpStatus(403) = error { throw error }
                lastError = error
            }
        }
        throw lastError
    }

    private func recordOpusFailure(_ id: String) {
        opusFailures = opusFailures.filter { $0.value.timeIntervalSinceNow > 0 }
        if opusFailures.count >= cacheCapacity, let oldest = opusFailures.min(by: { $0.value < $1.value })?.key {
            opusFailures.removeValue(forKey: oldest)
        }
        opusFailures[id] = Date().addingTimeInterval(60)
    }
}

private actor YouTubeExtractionWorker {
    static let shared = YouTubeExtractionWorker()
    private var tail: Task<Void, Never>?

    func extract(id: String, remote: Bool) async throws -> [ResolvedStream] {
        let predecessor = remote ? nil : tail
        // YouTubeKit 0.4.9 has a process-wide, unsynchronized player-JS cache; extraction jobs must not overlap.
        let work = Task.detached(priority: .userInitiated) {
            await predecessor?.value
            try Task.checkCancellation()
            let methods: [YouTube.ExtractionMethod] = remote ? [.remote] : [.local]
            let streams = try await YouTube(videoID: id, methods: methods).streams
            try Task.checkCancellation()
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
                    return ResolvedStream(url: stream.url, quality: quality)
                }
        }
        if !remote { tail = Task { _ = try? await work.value } }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: { work.cancel() }
    }
}

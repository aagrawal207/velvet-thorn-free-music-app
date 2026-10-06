import Foundation
import OSLog
import Synchronization
import YouTubeKit

/// Playback settings the player pushes into whichever resolver it holds. The composite forwards them to every source.
protocol PlaybackConfigurableResolving: StreamResolving {
    func setNetworkOffline(_ offline: Bool) async
    func setRemoteFallbackEnabled(_ enabled: Bool) async
    /// Fresh selection that may bypass a saved copy; see `YouTubeStreamResolver.refreshQuality`.
    func refreshQuality(track: Track) async throws -> ResolvedStream
    func setAudioQualityPreference(_ preference: AudioQualityPreference) async
}

extension YouTubeStreamResolver: PlaybackConfigurableResolving { }

/// Routes `resolve` by id prefix: bare ids keep the YouTube resolver, `saavn:` ids use JioSaavn, `gaana:` ids use
/// Gaana. Cache, prefetch and storage management stay with the YouTube resolver's `AudioCache`, so inventory and
/// limits keep one owner; prefixed songs are stored in that same cache under `<source>~<id>` keys.
struct CompositeStreamResolver: StreamCacheManaging, PlaybackConfigurableResolving, StreamWarming, PlaybackPreloadResolving {
    private static let logger = Logger(subsystem: "com.agraabhi.ganabajana", category: "StreamResolver")

    let youTube: YouTubeStreamResolver
    let saavn: JioSaavnStreamResolver
    let gaana: GaanaStreamResolver?
    private let explicitCache: AudioCache?
    private let connectivityOffline: @Sendable () -> Bool
    private let networkState = NetworkState()
    private let extractionFlights = CompositeExtractionFlights()

    /// `audioCache` defaults to the app's installed cache, which the production YouTube resolver registers in its init;
    /// tests pass the fixture cache their YouTube resolver was built with.
    init(youTube: YouTubeStreamResolver, saavn: JioSaavnStreamResolver, gaana: GaanaStreamResolver? = nil,
         audioCache: AudioCache? = nil, isOffline: @escaping @Sendable () -> Bool = { false }) {
        self.youTube = youTube
        self.saavn = saavn
        self.gaana = gaana
        explicitCache = audioCache
        connectivityOffline = isOffline
    }

    private var audioCache: AudioCache? { explicitCache ?? AudioCache.installed }

    /// The player's known-offline flag, mirrored here because the YouTube resolver keeps its own copy private.
    private final class NetworkState: Sendable {
        private let offline = Mutex(false)
        var isOffline: Bool { offline.withLock { $0 } }
        func set(_ value: Bool) { offline.withLock { $0 = value } }
    }

    private func isOffline() -> Bool { networkState.isOffline || connectivityOffline() }

    // MARK: StreamResolving

    func resolve(track: Track, forceRefresh: Bool) async throws -> ResolvedStream {
        let generation = YouTubeKitHooks.extractionCompatibility.generation
        switch track.source {
        case .youTubeMusic:
            let result = try await youTube.resolve(track: track, forceRefresh: forceRefresh)
            try YouTubeStreamResolver.checkExtractionCompatibility(generation)
            return result
        case .jioSaavn, .gaana:
            // A complete local copy never expires, so even a forced refresh prefers it; a bad file is discarded explicitly.
            if let cached = try await cachedAudio(for: track) {
                PlaybackStartTrace.record(.local, for: track.id)
                return cached.stream
            }
            try requireNetwork()
            let live = track.source == .gaana ? await gaana?.hasLiveStream(for: track.id) ?? false : await saavn.hasLiveStream(for: track.id)
            let reused = !forceRefresh && live
            let selection = try await resolveSource(track, forceRefresh: forceRefresh, generation: generation)
            PlaybackStartTrace.record(reused && !selection.refreshedFallback ? .urlCache : track.source == .gaana ? .gaana : .saavn, for: track.id)
            return selection.stream
        }
    }

    func prefetch(_ tracks: [Track]) async {
        let generation = YouTubeKitHooks.extractionCompatibility.generation
        let grouped = Dictionary(grouping: tracks, by: \.source)
        await youTube.prefetch(grouped[.youTubeMusic] ?? [])
        await saavn.prefetch(await uncached(grouped[.jioSaavn] ?? []))
        guard generation == YouTubeKitHooks.extractionCompatibility.generation, !Task.isCancelled else { return }
        await gaana?.prefetch(await uncached(grouped[.gaana] ?? []))
    }

    /// Prefixed songs warm URLs only: JioSaavn files could be downloaded, but a warm never spends a whole file on a
    /// song the listener has not chosen, and Gaana's HLS streams cannot be stored at all.
    func warm(_ tracks: [Track], download: Bool, token: UUID) async -> StreamWarmOutcome {
        let generation = YouTubeKitHooks.extractionCompatibility.generation
        let grouped = Dictionary(grouping: tracks, by: \.source)
        var outcome = await youTube.warm(grouped[.youTubeMusic] ?? [], download: download && tracks.first?.source == .youTubeMusic,
                                         token: token)
        for source in [MusicSource.jioSaavn, .gaana] {
            guard generation == YouTubeKitHooks.extractionCompatibility.generation, !Task.isCancelled else { return outcome }
            let requested = grouped[source] ?? []
            guard !requested.isEmpty else { continue }
            guard !isOffline() else { outcome.skipped += requested.count; continue }
            let pending = await uncached(requested)
            outcome.skipped += requested.count - pending.count
            let warmed: StreamWarmOutcome
            switch source {
            case .jioSaavn: warmed = await saavn.warm(pending)
            case .gaana: warmed = await gaana?.warm(pending) ?? StreamWarmOutcome(skipped: pending.count)
            case .youTubeMusic: warmed = StreamWarmOutcome()
            }
            guard generation == YouTubeKitHooks.extractionCompatibility.generation, !Task.isCancelled else { return outcome }
            outcome.resolved += warmed.resolved
            outcome.skipped += warmed.skipped
            outcome.failed += warmed.failed
            for track in pending {
                let live = source == .gaana ? await gaana?.hasLiveStream(for: track.id) ?? false : await saavn.hasLiveStream(for: track.id)
                if live { PlaybackStartTrace.markWarmed(track.id) }
            }
        }
        return outcome
    }

    func cancelWarm(token: UUID) async { await youTube.cancelWarm(token: token) }

    /// Gaana is left to its URL warm: its fallback lookups are too costly to run for every preload candidate.
    func preloadStream(for track: Track) async throws -> ResolvedStream? {
        let generation = YouTubeKitHooks.extractionCompatibility.generation
        switch track.source {
        case .youTubeMusic:
            let stream = try await youTube.preloadStream(for: track)
            try YouTubeStreamResolver.checkExtractionCompatibility(generation)
            return stream
        case .jioSaavn:
            guard !isOffline(), AudioCache.isProviderTrackID(track.id) else { return nil }
            if try await cachedAudio(for: track) != nil { return nil }
            let stream = try await resolveSource(track, forceRefresh: false, generation: generation).stream
            return stream.url.isFileURL || !Self.isCacheable(stream) ? nil : stream
        case .gaana:
            return nil
        }
    }

    // MARK: PlaybackConfigurableResolving

    func setNetworkOffline(_ offline: Bool) async {
        networkState.set(offline)
        await youTube.setNetworkOffline(offline)
    }
    func setRemoteFallbackEnabled(_ enabled: Bool) async { await youTube.setRemoteFallbackEnabled(enabled) }

    func invalidateExtractionCompatibility() async {
        await extractionFlights.invalidateExtractionCompatibility()
        await youTube.invalidateExtractionCompatibility()
    }

    /// Prefixed sources follow the YouTube rule: a fresh pick never replaces a saved copy with a lower bitrate.
    func refreshQuality(track: Track) async throws -> ResolvedStream {
        let generation = YouTubeKitHooks.extractionCompatibility.generation
        switch track.source {
        case .youTubeMusic:
            let result = try await youTube.refreshQuality(track: track)
            try YouTubeStreamResolver.checkExtractionCompatibility(generation)
            return result
        case .jioSaavn, .gaana:
            if isOffline() { return try await resolve(track: track, forceRefresh: false) }
            let fresh = try await resolveSource(track, forceRefresh: true, generation: generation).stream
            let cached = try await cachedAudio(for: track)
            if track.source == .gaana { try YouTubeStreamResolver.checkExtractionCompatibility(generation) }
            if let cached, let savedRate = cached.quality?.bitRate, (fresh.quality?.bitRate ?? 0) <= savedRate {
                return cached.stream
            }
            return fresh
        }
    }

    func setAudioQualityPreference(_ preference: AudioQualityPreference) async {
        await youTube.setAudioQualityPreference(preference)
        await saavn.setAudioQualityPreference(preference)
        await gaana?.setAudioQualityPreference(preference)
    }

    // MARK: StreamCaching

    func backgroundDownloadPlan(for track: Track) async throws -> BackgroundDownloadPlan {
        let generation = YouTubeKitHooks.extractionCompatibility.generation
        guard AudioCache.isProviderTrackID(track.id) else { throw PlaybackStreamError.invalidID }
        try requireNetwork()
        if track.source == .youTubeMusic {
            let plan = try await youTube.backgroundDownloadPlan(for: track)
            try YouTubeStreamResolver.checkExtractionCompatibility(generation)
            return plan
        }
        // The player's link for a song it just started is reused first; a stale one is replaced by a fresh lookup.
        if let current = try? await resolveSource(track, forceRefresh: false, generation: generation).stream,
           let plan = try? BackgroundDownloadPlan(stream: current), plan.expiresAt.timeIntervalSinceNow > 90 {
            return plan
        }
        try Task.checkCancellation()
        let stream = try await resolveSource(track, forceRefresh: true, generation: generation).stream
        try Task.checkCancellation()
        // Gaana playlists remain streaming-only; file fallbacks retain the original track's cache identity.
        return try BackgroundDownloadPlan(stream: stream)
    }

    /// Prefixed songs go through the shared cache's own download path: plain AAC files with Range support are
    /// stored complete; an HLS playlist (Gaana's own streams) cannot be, so the song streams without caching.
    func download(_ track: Track) async throws -> ResolvedStream {
        let generation = YouTubeKitHooks.extractionCompatibility.generation
        switch track.source {
        case .youTubeMusic:
            let result = try await youTube.download(track)
            try YouTubeStreamResolver.checkExtractionCompatibility(generation)
            return result
        case .jioSaavn, .gaana:
            guard let audioCache else { throw MusicServiceError.unavailable("Audio caching is not available.") }
            guard AudioCache.isProviderTrackID(track.id) else { throw PlaybackStreamError.invalidID }
            if let cached = try await cachedAudio(for: track) { return cached.stream }
            try requireNetwork()
            let permit = try await audioCache.writePermit()
            let stream = try await resolveSource(track, forceRefresh: false, generation: generation).stream
            try Task.checkCancellation()
            if stream.url.isFileURL { return stream }
            guard Self.isCacheable(stream) else {
                Self.logger.debug("event=cache_skipped source=\(track.source.rawValue, privacy: .public) reason=hls")
                throw MusicServiceError.unavailable("Songs streamed from \(track.source.title) play without caching.")
            }
            try requireNetwork()
            let cached = try await audioCache.store(trackID: track.id, from: stream.url, stream: stream, permit: permit, track: track)
            if track.source == .gaana { try YouTubeStreamResolver.checkExtractionCompatibility(generation) }
            Self.logger.info("event=audio_cached source=\(track.source.rawValue, privacy: .public) bytes=\(cached.bytes)")
            return cached.stream
        }
    }

    /// The downloader stores single files only; playlists and segment streams stay with the player.
    static func isCacheable(_ stream: ResolvedStream) -> Bool {
        !["m3u8", "m3u", "mpd"].contains(stream.url.pathExtension.lowercased())
    }

    func discardCached(_ track: Track) async {
        switch track.source {
        case .youTubeMusic: await youTube.discardCached(track)
        case .jioSaavn, .gaana: await audioCache?.remove(trackID: track.id)
        }
    }

    func discardCached(_ track: Track, url: URL?) async {
        switch track.source {
        case .youTubeMusic: await youTube.discardCached(track, url: url)
        case .jioSaavn, .gaana:
            guard let url else { await discardCached(track); return }
            await audioCache?.rejectPlaybackFile(url)
        }
    }

    func retainCached(_ trackIDs: Set<String>) async { await youTube.retainCached(trackIDs) }

    /// Both resolvers share one directory in production; a fixture cache injected here is checked as well.
    func isCachedStream(_ stream: ResolvedStream) -> Bool {
        if youTube.isCachedStream(stream) { return true }
        guard let audioCache = explicitCache, stream.url.isFileURL else { return false }
        let url = stream.url.standardizedFileURL
        return url.deletingLastPathComponent().path == audioCache.directory.path
            && AudioDownloader.mediaExtensions.contains(url.pathExtension)
            && AudioCache.logicalTrackID(for: url) != nil
    }

    // MARK: StreamCacheManaging

    func audioCacheUsage() async throws -> AudioCache.Usage? { try await youTube.audioCacheUsage() }
    func audioCacheSnapshot() async throws -> AudioCacheSnapshot? { try await youTube.audioCacheSnapshot() }

    func removeCachedSong(id: String, retaining: @escaping @Sendable () async -> Set<String>) async throws -> AudioCacheRemoval? {
        try await youTube.removeCachedSong(id: id, retaining: retaining)
    }

    func updateCacheListeningHistory(_ events: [ListeningEvent], now: Date) async {
        await youTube.updateCacheListeningHistory(events, now: now)
    }

    func clearAudioCache(retaining: @escaping @Sendable () async -> Set<String>) async throws -> AudioCache.Usage? {
        try await youTube.clearAudioCache(retaining: retaining)
    }

    func setAudioCacheLimit(_ limit: AudioCacheLimit, retaining: @escaping @Sendable () async -> Set<String>) async throws -> AudioCache.Usage? {
        try await youTube.setAudioCacheLimit(limit, retaining: retaining)
    }

    // MARK: Helpers

    private func resolveSource(_ track: Track, forceRefresh: Bool, generation: UInt64) async throws -> CompositeExtractionFlights.Selection {
        let resolver = try sourceResolver(for: track)
        if track.source == .gaana {
            let result = try await extractionFlights.resolve(track: track, resolver: resolver,
                                                             forceRefresh: forceRefresh, generation: generation)
            try YouTubeStreamResolver.checkExtractionCompatibility(generation)
            return result
        }
        var result = try await resolver.resolve(track: track, forceRefresh: forceRefresh)
        result.extractionGeneration = nil
        return (result, false)
    }

    private func sourceResolver(for track: Track) throws -> any StreamResolving {
        switch track.source {
        case .youTubeMusic: return youTube
        case .jioSaavn: return saavn
        case .gaana:
            guard let gaana else { throw PlaybackStreamError.invalidID }
            return gaana
        }
    }

    private func cachedAudio(for track: Track) async throws -> CachedAudio? {
        guard let audioCache, AudioCache.isProviderTrackID(track.id) else { return nil }
        let result = try await PlaybackDeadline.run(seconds: 10) {
            try await audioCache.preparedEntry(for: track.id, allowOpus: false)
        }
        Self.logger.debug("event=audio_cache_lookup source=\(track.source.rawValue, privacy: .public) playback_source=\(result?.playbackSource?.rawValue ?? "unknown", privacy: .public) hit=\(result == nil ? 0 : 1)")
        return result
    }

    private func uncached(_ tracks: [Track]) async -> [Track] {
        guard let audioCache, !tracks.isEmpty else { return tracks }
        var pending: [Track] = []
        for track in tracks {
            if await audioCache.entry(for: track.id) == nil { pending.append(track) }
        }
        return pending
    }

    private func requireNetwork() throws {
        try Task.checkCancellation()
        if isOffline() { throw MusicServiceError.network(YouTubeStreamResolver.offlineMessage) }
    }
}

/// Gaana can retain a YouTube fallback URL in its own cache. Never relabel that old URL with the current generation.
private actor CompositeExtractionFlights {
    typealias Selection = (stream: ResolvedStream, refreshedFallback: Bool)
    private var generation = YouTubeKitHooks.extractionCompatibility.generation
    private var pending: [UUID: (generation: UInt64, task: Task<Selection, Error>)] = [:]

    func invalidateExtractionCompatibility() {
        generation = YouTubeKitHooks.extractionCompatibility.generation
        for work in pending.values where work.generation != generation { work.task.cancel() }
    }

    func resolve(track: Track, resolver: any StreamResolving, forceRefresh: Bool, generation expected: UInt64) async throws -> Selection {
        invalidateExtractionCompatibility()
        try YouTubeStreamResolver.checkExtractionCompatibility(expected)
        guard pending.count < 32 else {
            Logger(subsystem: "com.agraabhi.ganabajana", category: "StreamResolver")
                .debug("event=extractor_resolution outcome=queue_full")
            throw CancellationError()
        }
        let token = UUID()
        let task = Task {
            var refreshedFallback = false
            try YouTubeStreamResolver.checkExtractionCompatibility(expected)
            var stream = try await resolver.resolve(track: track, forceRefresh: forceRefresh)
            try YouTubeStreamResolver.checkExtractionCompatibility(expected)
            if !stream.url.isFileURL, let stamp = stream.extractionGeneration, stamp != expected {
                // One forced retry replaces a retained fallback URL; a still-retiring shared flight must fail closed.
                refreshedFallback = true
                stream = try await resolver.resolve(track: track, forceRefresh: true)
                try YouTubeStreamResolver.checkExtractionCompatibility(expected)
                if let stamp = stream.extractionGeneration, stamp != expected { throw CancellationError() }
            }
            if stream.url.isFileURL || stream.playbackSource != .youTubeMusic { stream.extractionGeneration = nil }
            return (stream: stream, refreshedFallback: refreshedFallback)
        }
        pending[token] = (expected, task)
        defer { pending.removeValue(forKey: token) }
        return try await withTaskCancellationHandler {
            let result = try await task.value
            try YouTubeStreamResolver.checkExtractionCompatibility(expected)
            return result
        } onCancel: { task.cancel() }
    }
}

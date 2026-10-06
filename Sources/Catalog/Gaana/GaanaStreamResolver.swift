import Foundation
import OSLog

/// Resolves `gaana:` tracks at play time: fresh song details, AES decryption of the HLS master URL, tier selection
/// under the listener's quality ceiling and a playlist probe. When Gaana itself hands out no stream (restricted,
/// missing or undecryptable), the same recording is looked up on the fallback sources in order. Nothing touches disk.
actor GaanaStreamResolver: StreamResolving {
    typealias Probe = @Sendable (URL) async throws -> Void
    typealias Selection = (stream: ResolvedStream, tier: GaanaMediaURL.Tier?, source: MusicSource)

    /// Provider URLs expire about four hours after the details call; the cache never trusts one longer than this.
    static let maximumLifetime: TimeInterval = 4 * 3_600
    static let probeTimeout: TimeInterval = 8
    /// YouTube's normalization reference; the provider's integrated LUFS is converted to the same "dB above reference".
    static let loudnessReference: Double = -14
    private static let logger = Logger(subsystem: "com.agraabhi.ganabajana", category: "Gaana")

    private struct Entry {
        let stream: ResolvedStream
        let tier: GaanaMediaURL.Tier?
        var access: UInt64
    }

    private struct Flight {
        let task: Task<Selection, any Error>
        var waiters: Set<UUID>
    }

    private let catalog: GaanaCatalogService
    private let fallbacks: [any CrossSourceStreamFallback]
    private let probe: Probe
    private let now: @Sendable () -> Date
    private let cacheCapacity: Int
    private var cache: [String: Entry] = [:]
    private var access: UInt64 = 0
    private var maximumBitRate: Int?
    private var flights: [String: Flight] = [:]

    init(catalog: GaanaCatalogService, fallbacks: [any CrossSourceStreamFallback] = [], quality: AudioQualityPreference = .best,
         probe: Probe? = nil, now: @escaping @Sendable () -> Date = { Date() }, cacheCapacity: Int = 24) {
        self.catalog = catalog
        self.fallbacks = fallbacks
        self.probe = probe ?? { try await Self.probePlaylist($0) }
        self.now = now
        self.cacheCapacity = max(1, cacheCapacity)
        maximumBitRate = quality.maximumBitRate
    }

    func setAudioQualityPreference(_ preference: AudioQualityPreference) {
        guard preference.maximumBitRate != maximumBitRate else { return }
        maximumBitRate = preference.maximumBitRate
        // Cached picks were made under the old ceiling; the next play re-selects instead of replaying them.
        cache.removeAll()
    }

    func resolve(track: Track, forceRefresh: Bool) async throws -> ResolvedStream {
        try Task.checkCancellation()
        guard track.source == .gaana, MusicSource.entityKind(of: track.id) == .track,
              let providerID = GaanaText.identifier(track.providerID) else { throw PlaybackStreamError.invalidID }
        if !forceRefresh, var entry = cache[track.id], let expiry = entry.stream.expiresAt, expiry.timeIntervalSince(now()) > 90 {
            access &+= 1
            entry.access = access
            cache[track.id] = entry
            Self.logger.debug("event=stream_cache_hit quality=\(entry.tier?.rawValue ?? "fallback", privacy: .public)")
            return entry.stream
        }
        cache.removeValue(forKey: track.id)
        let key = track.id
        let waiter = UUID()
        if var flight = flights[key] {
            flight.waiters.insert(waiter)
            flights[key] = flight
        } else {
            let ceiling = maximumBitRate
            let work = Task { [catalog, fallbacks, probe, now] in
                try await Self.select(track: track, providerID: providerID, forceRefresh: forceRefresh, maximumBitRate: ceiling,
                                      catalog: catalog, fallbacks: fallbacks, probe: probe, now: now)
            }
            flights[key] = Flight(task: work, waiters: [waiter])
        }
        guard let work = flights[key]?.task else { throw CancellationError() }
        let selection = try await withTaskCancellationHandler {
            defer { release(key, task: work, waiter: waiter) }
            return try await work.value
        } onCancel: {
            Task { await self.release(key, task: work, waiter: waiter) }
        }
        store(selection.stream, tier: selection.tier, for: key)
        return selection.stream
    }

    func prefetch(_ tracks: [Track]) async {
        _ = await warm(Array(tracks.filter { $0.source == .gaana }.prefix(2)))
    }

    /// URL-only warm for songs the listener may choose next; a live cached URL counts as skipped. Bounded by the caller.
    func warm(_ tracks: [Track]) async -> StreamWarmOutcome {
        var outcome = StreamWarmOutcome()
        for track in tracks where track.source == .gaana {
            guard !Task.isCancelled else { return outcome }
            if let entry = cache[track.id], let expiry = entry.stream.expiresAt, expiry.timeIntervalSince(now()) > 90 {
                outcome.skipped += 1
                continue
            }
            do {
                _ = try await resolve(track: track, forceRefresh: false)
                outcome.resolved += 1
            } catch is CancellationError { return outcome }
            catch {
                outcome.failed += 1
                Self.logger.debug("event=prefetch_unavailable")
            }
        }
        return outcome
    }

    /// Whether a tap now would reuse a signed URL instead of asking the provider, so the start is reported as reused.
    func hasLiveStream(for trackID: String) -> Bool {
        guard let expiry = cache[trackID]?.stream.expiresAt else { return false }
        return expiry.timeIntervalSince(now()) > 90
    }

    /// The last waiter leaving cancels the shared lookup; a finished task ignores the cancel.
    private func release(_ key: String, task: Task<Selection, any Error>, waiter: UUID) {
        guard var flight = flights[key], flight.task == task, flight.waiters.remove(waiter) != nil else { return }
        if flight.waiters.isEmpty {
            flights.removeValue(forKey: key)
            task.cancel()
        } else {
            flights[key] = flight
        }
    }

    private static func select(track: Track, providerID: String, forceRefresh: Bool, maximumBitRate: Int?,
                               catalog: GaanaCatalogService, fallbacks: [any CrossSourceStreamFallback], probe: @escaping Probe,
                               now: @escaping @Sendable () -> Date) async throws -> Selection {
        let song = try await catalog.songDetails(providerID: providerID, forceRefresh: forceRefresh)
        try Task.checkCancellation()
        var reason = "missing"
        if let song {
            if song.isRestricted {
                reason = "restricted"
            } else if song.urls.isEmpty {
                reason = "noMedia"
            } else if let selection = try await own(song: song, track: track, maximumBitRate: maximumBitRate, probe: probe, now: now) {
                return selection
            } else {
                reason = "noTier"
            }
        }
        logger.notice("event=resolve status=failed reason=\(reason, privacy: .public)")
        // The details row carries the duration the match needs; a search row alone never does.
        var wanted = song?.track ?? track
        if wanted.duration == nil { wanted.duration = track.duration }
        for fallback in fallbacks {
            try Task.checkCancellation()
            do {
                if let stream = try await fallback.resolve(matching: wanted, forceRefresh: forceRefresh) {
                    logger.info("event=fallback source=\(fallback.source.rawValue, privacy: .public) status=ok")
                    var adjusted = stream
                    // A fallback adapter can return legacy cached bytes whose acquisition provider is unknown.
                    if adjusted.playbackSource == nil, !adjusted.url.isFileURL { adjusted.playbackSource = fallback.source }
                    if adjusted.duration == nil { adjusted.duration = wanted.duration }
                    if adjusted.expiresAt == nil { adjusted.expiresAt = now().addingTimeInterval(maximumLifetime) }
                    return (adjusted, nil, fallback.source)
                }
                logger.debug("event=fallback source=\(fallback.source.rawValue, privacy: .public) status=miss")
            } catch {
                if error is CancellationError { throw error }
                logger.debug("event=fallback source=\(fallback.source.rawValue, privacy: .public) status=failed")
            }
        }
        throw PlaybackStreamError.noAudio
    }

    /// Gaana's own HLS stream: highest tier under the ceiling whose decrypted master playlist answers.
    private static func own(song: GaanaSong, track: Track, maximumBitRate: Int?, probe: @escaping Probe,
                            now: @escaping @Sendable () -> Date) async throws -> Selection? {
        let current = now()
        for tier in GaanaMediaURL.candidates(available: Set(song.urls.keys), maximumBitRate: maximumBitRate) {
            try Task.checkCancellation()
            guard let encrypted = song.urls[tier] else { continue }
            if let expiry = encrypted.expiresAt, expiry <= current {
                logger.debug("event=tier_unavailable quality=\(tier.rawValue, privacy: .public) reason=expired")
                continue
            }
            let url: URL
            do { url = try GaanaMediaURL.decrypt(encrypted.message) }
            catch {
                logger.notice("event=tier_unavailable quality=\(tier.rawValue, privacy: .public) reason=decrypt")
                continue
            }
            do {
                try await PlaybackDeadline.run(seconds: probeTimeout) { try await probe(url) }
                logger.info("event=resolve status=ok quality=\(tier.rawValue, privacy: .public)")
                let expiry = min(encrypted.expiresAt ?? .distantFuture, current.addingTimeInterval(maximumLifetime))
                let stream = ResolvedStream(url: url, duration: PlaybackTiming.validDuration(song.track.duration ?? track.duration),
                                            expiresAt: expiry, loudnessDb: song.integratedLoudness.map { $0 - loudnessReference },
                                            viewCount: song.track.playCount ?? track.playCount, quality: tier.quality, playbackSource: .gaana)
                return (stream, tier, .gaana)
            } catch {
                if error is CancellationError { throw error }
                logger.debug("event=tier_unavailable quality=\(tier.rawValue, privacy: .public) reason=probe")
            }
        }
        return nil
    }

    /// Masters are small text playlists; a 200 with the `#EXTM3U` prefix proves the token still opens the stream.
    static func probePlaylist(_ url: URL) async throws {
        guard GaanaMediaURL.isMediaHost(url) else { throw PlaybackStreamError.invalidMedia }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = probeTimeout
        configuration.timeoutIntervalForResource = probeTimeout
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let (data, response) = try await session.boundedData(for: request, maximumBytes: 64 * 1_024)
        guard let http = response as? HTTPURLResponse else { throw PlaybackStreamError.invalidMedia }
        guard http.statusCode == 200 else { throw PlaybackStreamError.httpStatus(http.statusCode) }
        guard String(data: data.prefix(7), encoding: .utf8) == "#EXTM3U" else { throw PlaybackStreamError.invalidMedia }
    }

    // MARK: Cache

    private func store(_ stream: ResolvedStream, tier: GaanaMediaURL.Tier?, for trackID: String) {
        access &+= 1
        cache[trackID] = Entry(stream: stream, tier: tier, access: access)
        while cache.count > cacheCapacity, let oldest = cache.min(by: { $0.value.access < $1.value.access })?.key {
            cache.removeValue(forKey: oldest)
        }
    }
}

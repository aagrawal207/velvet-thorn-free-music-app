import Foundation
import OSLog

/// Resolves `saavn:` tracks to CDN media at play time: fresh song details, DES decryption, tier selection under the
/// listener's quality ceiling and a Range probe before a URL is handed to the player. Nothing here touches disk.
actor JioSaavnStreamResolver: StreamResolving {
    typealias Probe = @Sendable (URL) async throws -> Void
    typealias Selection = (stream: ResolvedStream, tier: JioSaavnMediaURL.Tier)

    static let cacheLifetime: TimeInterval = 6 * 3_600
    static let probeTimeout: TimeInterval = 8
    private static let logger = Logger(subsystem: "com.agraabhi.ganabajana", category: "JioSaavn")

    private struct Entry {
        let stream: ResolvedStream
        let tier: JioSaavnMediaURL.Tier
        var access: UInt64
    }

    private struct Flight {
        let task: Task<Selection, any Error>
        var waiters: Set<UUID>
    }

    private let catalog: JioSaavnCatalogService
    private let probe: Probe
    private let now: @Sendable () -> Date
    private let cacheCapacity: Int
    private var cache: [String: Entry] = [:]
    private var access: UInt64 = 0
    private var maximumBitRate: Int?
    private var flights: [String: Flight] = [:]

    init(catalog: JioSaavnCatalogService, quality: AudioQualityPreference = .best,
         probe: Probe? = nil, now: @escaping @Sendable () -> Date = { Date() }, cacheCapacity: Int = 24) {
        self.catalog = catalog
        self.probe = probe ?? { try await Self.probeMedia($0) }
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
        guard track.source == .jioSaavn, MusicSource.entityKind(of: track.id) == .track,
              let providerID = JioSaavnText.identifier(track.providerID) else { throw PlaybackStreamError.invalidID }
        if !forceRefresh, var entry = cache[track.id], let expiry = entry.stream.expiresAt, expiry.timeIntervalSince(now()) > 90 {
            access &+= 1
            entry.access = access
            cache[track.id] = entry
            Self.logger.debug("event=stream_cache_hit quality=\(entry.tier.rawValue)")
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
            let work = Task { [catalog, probe, now] in
                try await Self.select(track: track, providerID: providerID, forceRefresh: forceRefresh, maximumBitRate: ceiling,
                                      catalog: catalog, probe: probe, now: now)
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
        _ = await warm(Array(tracks.filter { $0.source == .jioSaavn }.prefix(2)))
    }

    /// URL-only warm for songs the listener may choose next; a live cached URL counts as skipped. Bounded by the caller.
    func warm(_ tracks: [Track]) async -> StreamWarmOutcome {
        var outcome = StreamWarmOutcome()
        for track in tracks where track.source == .jioSaavn {
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
                               catalog: JioSaavnCatalogService, probe: @escaping Probe,
                               now: @escaping @Sendable () -> Date) async throws -> Selection {
        guard let song = try await catalog.songDetails(providerIDs: [providerID], forceRefresh: forceRefresh).first,
              song.track.id == track.id else {
            logger.notice("event=resolve status=failed reason=missing")
            throw PlaybackStreamError.noAudio
        }
        guard let encrypted = song.encryptedMediaURL else {
            logger.notice("event=resolve status=failed reason=noMedia")
            throw PlaybackStreamError.noAudio
        }
        let base: URL
        do { base = try JioSaavnMediaURL.decrypt(encrypted) }
        catch {
            logger.notice("event=resolve status=failed reason=decrypt")
            throw PlaybackStreamError.invalidMedia
        }
        var lastError: any Error = PlaybackStreamError.noAudio
        for tier in JioSaavnMediaURL.candidates(has320: song.has320, maximumBitRate: maximumBitRate) {
            try Task.checkCancellation()
            guard let url = JioSaavnMediaURL.url(base, tier: tier) else { continue }
            do {
                try await PlaybackDeadline.run(seconds: probeTimeout) { try await probe(url) }
                logger.info("event=resolve status=ok quality=\(tier.rawValue)")
                let stream = ResolvedStream(url: url, duration: PlaybackTiming.validDuration(song.track.duration ?? track.duration),
                                            expiresAt: now().addingTimeInterval(cacheLifetime), loudnessDb: nil,
                                            viewCount: song.track.playCount ?? track.playCount, quality: tier.quality, playbackSource: .jioSaavn)
                return (stream, tier)
            } catch {
                if error is CancellationError { throw error }
                logger.debug("event=tier_unavailable quality=\(tier.rawValue)")
                lastError = error
            }
        }
        logger.notice("event=resolve status=failed reason=noTier")
        throw lastError
    }

    /// The CDN answers 206 for a leading Range; the MP4 prefix check catches HTML error pages served with 200.
    static func probeMedia(_ url: URL) async throws {
        guard JioSaavnMediaURL.isMediaHost(url) else { throw PlaybackStreamError.invalidMedia }
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
        request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue(CatalogTransport.browserUserAgent, forHTTPHeaderField: "User-Agent")
        let (body, response) = try await session.chunkedBody(for: request)
        defer { body.cancel() }
        guard let http = response as? HTTPURLResponse else { throw PlaybackStreamError.invalidMedia }
        guard http.statusCode == 200 || http.statusCode == 206 else { throw PlaybackStreamError.httpStatus(http.statusCode) }
        var prefix = Data()
        for try await chunk in body {
            try Task.checkCancellation()
            prefix.append(chunk.prefix(1_024 - prefix.count))
            if prefix.count == 1_024 { break }
        }
        try StreamValidation.validate(response: http, prefix: prefix)
    }

    // MARK: Cache

    private func store(_ stream: ResolvedStream, tier: JioSaavnMediaURL.Tier, for trackID: String) {
        access &+= 1
        cache[trackID] = Entry(stream: stream, tier: tier, access: access)
        while cache.count > cacheCapacity, let oldest = cache.min(by: { $0.value.access < $1.value.access })?.key {
            cache.removeValue(forKey: oldest)
        }
    }
}

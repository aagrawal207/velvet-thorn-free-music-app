import Foundation

actor LRCLyricsService: LyricsVariantsProviding {
    struct CacheConfiguration: Sendable {
        var capacity = 64
        var maximumBytes = 4 * 1024 * 1024
        var positiveLifetime: TimeInterval = 12 * 60 * 60
        var negativeLifetime: TimeInterval = 2 * 60
        var maximumConcurrentLookups = 4
        var maximumWaitersPerLookup = 16
    }

    struct Activity: Sendable {
        let cachedRecordings: Int
        let cachedBytes: Int
        let activeLookups: Int
        let waitingCallers: Int
    }

    private struct CacheEntry {
        let document: LyricsDocument
        let expiresAt: Date
        let bytes: Int
        var access: UInt64
    }

    private struct Flight {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<LyricsDocument, any Error>]
    }

    private let client: LRCLIBClient
    private let configuration: CacheConfiguration
    private let now: @Sendable () -> Date
    private var cache: [LyricsMatcher.RecordingKey: CacheEntry] = [:]
    private var flights: [LyricsMatcher.RecordingKey: Flight] = [:]
    private var access: UInt64 = 0
    private var activeVariantLookups = 0

    var activity: Activity {
        Activity(cachedRecordings: cache.count, cachedBytes: cache.values.reduce(0) { $0 + $1.bytes },
                 activeLookups: flights.count, waitingCallers: flights.values.reduce(0) { $0 + $1.waiters.count })
    }

    init() {
        client = LRCLIBClient(transport: LRCURLSessionTransport())
        configuration = CacheConfiguration()
        now = { Date() }
    }

    init(transport: any LRCHTTPTransport, cacheConfiguration: CacheConfiguration = CacheConfiguration(),
         clientConfiguration: LRCLIBClient.Configuration = LRCLIBClient.Configuration(),
         now: @escaping @Sendable () -> Date = { Date() }) {
        client = LRCLIBClient(transport: transport, configuration: clientConfiguration, now: now)
        configuration = cacheConfiguration
        self.now = now
    }

    func lyrics(for track: Track) async throws -> LyricsDocument {
        try Task.checkCancellation()
        let key = LyricsMatcher.RecordingKey(track)
        cache = cache.filter { $0.value.expiresAt > now() }
        access &+= 1
        if var entry = cache[key] {
            entry.access = access
            cache[key] = entry
            var document = entry.document
            document.trackID = track.id
            LyricsDiagnostics.logger.debug("cacheHit=1 cacheMiss=0 coalesced=0")
            return document
        }
        let waiterID = UUID()
        let document: LyricsDocument = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<LyricsDocument, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if var flight = flights[key] {
                    guard flight.waiters.count < max(1, configuration.maximumWaitersPerLookup) else {
                        continuation.resume(throwing: MusicServiceError.unavailable("Lyrics are still loading. Please try again in a moment."))
                        return
                    }
                    flight.waiters[waiterID] = continuation
                    flights[key] = flight
                    LyricsDiagnostics.logger.debug("cacheHit=0 cacheMiss=0 coalesced=1")
                    return
                }
                guard flights.count < max(1, configuration.maximumConcurrentLookups) else {
                    continuation.resume(throwing: MusicServiceError.unavailable("Lyrics are still loading. Please try again in a moment."))
                    return
                }
                LyricsDiagnostics.logger.debug("cacheHit=0 cacheMiss=1 coalesced=0")
                let flightID = UUID()
                let task = Task<Void, Never> { [client] in
                    let result: Result<LyricsDocument, any Error>
                    do {
                        let document = try await client.lookup(track)
                        try Task.checkCancellation()
                        result = .success(document)
                    } catch { result = .failure(error) }
                    finish(key: key, flightID: flightID, result: result)
                }
                flights[key] = Flight(id: flightID, task: task, waiters: [waiterID: continuation])
            }
        } onCancel: {
            Task { await self.cancel(waiterID: waiterID, key: key) }
        }
        try Task.checkCancellation()
        var rebound = document
        rebound.trackID = track.id
        return rebound
    }

    func lyricVariants(for track: Track) async throws -> [LyricsDocument] {
        try Task.checkCancellation()
        guard activeVariantLookups < 2 else { throw LyricsLookupError.sourcesFailed }
        activeVariantLookups += 1
        defer { activeVariantLookups -= 1 }
        let documents = try await client.variants(track)
        try Task.checkCancellation()
        return documents
    }

    private func cancel(waiterID: UUID, key: LyricsMatcher.RecordingKey) {
        guard var flight = flights[key], let waiter = flight.waiters.removeValue(forKey: waiterID) else { return }
        waiter.resume(throwing: CancellationError())
        if flight.waiters.isEmpty {
            flights.removeValue(forKey: key)
            flight.task.cancel()
        } else { flights[key] = flight }
    }

    private func finish(key: LyricsMatcher.RecordingKey, flightID: UUID,
                        result: Result<LyricsDocument, any Error>) {
        guard let flight = flights[key], flight.id == flightID else { return }
        flights.removeValue(forKey: key)
        if case .success(let document) = result { insert(document, for: key) }
        for waiter in flight.waiters.values { waiter.resume(with: result) }
    }

    private func insert(_ document: LyricsDocument, for key: LyricsMatcher.RecordingKey) {
        let bytes = document.lines.reduce(0) { $0 + $1.text.utf8.count + 48 }
            + (document.plainText?.utf8.count ?? 0) + (document.matchedTitle?.utf8.count ?? 0)
            + (document.matchedArtist?.utf8.count ?? 0) + document.trackID.utf8.count
            + key.title.utf8.count + key.album.utf8.count + key.artists.reduce(0) { $0 + $1.utf8.count } + 512
        guard configuration.capacity > 0, bytes <= configuration.maximumBytes else { return }
        let lifetime = document.kind == .unavailable ? configuration.negativeLifetime : configuration.positiveLifetime
        guard lifetime > 0 else { return }
        access &+= 1
        cache[key] = CacheEntry(document: document, expiresAt: now().addingTimeInterval(lifetime),
                                bytes: bytes, access: access)
        var totalBytes = cache.values.reduce(0) { $0 + $1.bytes }
        while cache.count > configuration.capacity || totalBytes > configuration.maximumBytes {
            guard let oldest = cache.min(by: { $0.value.access < $1.value.access }) else { break }
            totalBytes -= oldest.value.bytes
            cache.removeValue(forKey: oldest.key)
        }
    }
}

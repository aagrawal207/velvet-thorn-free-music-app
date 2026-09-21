import Foundation
import OSLog

actor CompositeLyricsProvider: LyricsProviding {
    struct Configuration: Sendable {
        var primaryTimeout: TimeInterval = 2.5
        var fallbackTimeout: TimeInterval = 3
        var totalTimeout: TimeInterval = 6
        var capacity = 64
        var maximumBytes = 4 * 1024 * 1024
        var primaryLifetime: TimeInterval = 12 * 60 * 60
        var fallbackLifetime: TimeInterval = 15 * 60
        var missingLifetime: TimeInterval = 60
        var maximumConcurrentLookups = 4
        var maximumWaiters = 16
    }

    struct Activity: Sendable {
        let cachedRecordings: Int
        let activeLookups: Int
        let waitingCallers: Int
    }

    private struct Outcome: Sendable {
        let document: LyricsDocument
        let usedFallback: Bool
    }

    private struct Entry {
        let document: LyricsDocument
        let expires: Date
        let bytes: Int
        var access: UInt64
    }

    private struct Flight {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<LyricsDocument, any Error>]
    }

    private let primary: any LyricsProviding
    private let fallback: (any LyricsProviding)?
    private let configuration: Configuration
    private let now: @Sendable () -> Date
    private var cache: [LyricsRequestKey: Entry] = [:]
    private var flights: [LyricsRequestKey: Flight] = [:]
    private var access: UInt64 = 0

    init(primary: any LyricsProviding = LRCLyricsService(), fallback: (any LyricsProviding)?,
         configuration: Configuration = Configuration(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.primary = primary
        self.fallback = fallback
        self.configuration = configuration
        self.now = now
    }

    var activity: Activity {
        Activity(cachedRecordings: cache.count, activeLookups: flights.count,
                 waitingCallers: flights.values.reduce(0) { $0 + $1.waiters.count })
    }

    func lyrics(for track: Track) async throws -> LyricsDocument {
        try Task.checkCancellation()
        let key = LyricsRequestKey(track)
        cache = cache.filter { $0.value.expires > now() }
        access &+= 1
        if var entry = cache[key] {
            entry.access = access
            cache[key] = entry
            LyricsDiagnostics.logger.debug("compositeCacheHit=1 compositeCacheMiss=0 coalesced=0")
            return entry.document
        }
        let waiterID = UUID()
        let document = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<LyricsDocument, any Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                if var flight = flights[key] {
                    guard flight.waiters.count < max(1, configuration.maximumWaiters) else {
                        continuation.resume(throwing: LyricsLookupError.sourcesFailed)
                        return
                    }
                    flight.waiters[waiterID] = continuation
                    flights[key] = flight
                    LyricsDiagnostics.logger.debug("compositeCacheHit=0 compositeCacheMiss=0 coalesced=1")
                    return
                }
                guard flights.count < max(1, configuration.maximumConcurrentLookups) else {
                    continuation.resume(throwing: LyricsLookupError.sourcesFailed)
                    return
                }
                LyricsDiagnostics.logger.debug("compositeCacheHit=0 compositeCacheMiss=1 coalesced=0")
                let flightID = UUID()
                let task = Task<Void, Never> { [primary, fallback, configuration] in
                    let result: Result<Outcome, any Error>
                    do {
                        let value = try await Self.lookup(track, primary: primary, fallback: fallback, configuration: configuration)
                        try Task.checkCancellation()
                        result = .success(value)
                    } catch { result = .failure(error) }
                    finish(key: key, flightID: flightID, result: result)
                }
                flights[key] = Flight(id: flightID, task: task, waiters: [waiterID: continuation])
            }
        } onCancel: {
            Task { await self.cancel(key: key, waiterID: waiterID) }
        }
        try Task.checkCancellation()
        return document
    }

    private nonisolated static func lookup(_ track: Track, primary: any LyricsProviding, fallback: (any LyricsProviding)?,
                                          configuration: Configuration) async throws -> Outcome {
        let deadline = Date().addingTimeInterval(configuration.totalTimeout)
        let providers = [primary] + (fallback.map { [$0] } ?? [])
        var hadError = false
        for (index, provider) in providers.enumerated() {
            try Task.checkCancellation()
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw LyricsLookupError.sourcesFailed }
            let started = Date()
            do {
                let timeout = min(remaining, index == 0 ? configuration.primaryTimeout : configuration.fallbackTimeout)
                let document = try await PlaybackDeadline.run(seconds: timeout) { try await provider.lyrics(for: track) }
                try Task.checkCancellation()
                try validate(document, for: track)
                let missing = document.kind == .unavailable
                let milliseconds = Int(max(0, Date().timeIntervalSince(started)) * 1_000)
                LyricsDiagnostics.logger.info("compositeRequestSuccess=1 compositeRequestFailure=0 compositeTimedOut=0 fallbackUsed=\(index == 0 ? 0 : 1) missing=\(missing ? 1 : 0) latencyMs=\(milliseconds)")
                if !missing { return Outcome(document: document, usedFallback: index != 0) }
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                hadError = true
                let timedOut: Bool
                if let error = error as? PlaybackStreamError, case .timedOut = error { timedOut = true }
                else { timedOut = false }
                LyricsDiagnostics.logger.info("compositeRequestSuccess=0 compositeRequestFailure=1 compositeTimedOut=\(timedOut ? 1 : 0) fallbackUsed=\(index == 0 ? 0 : 1)")
            }
        }
        try Task.checkCancellation()
        // Missing is conclusive only when every source answered. Outages must remain retryable errors.
        guard !hadError else { throw LyricsLookupError.sourcesFailed }
        return Outcome(document: LyricsDocument(trackID: track.id, kind: .unavailable,
            source: fallback == nil ? LyricsSource.lrcLib.rawValue : "LRCLIB and YouTube Music"), usedFallback: fallback != nil)
    }

    private nonisolated static func validate(_ document: LyricsDocument, for track: Track) throws {
        guard document.trackID == track.id else { throw LyricsLookupError.recordingMismatch }
        guard (document.plainText?.utf8.count ?? 0) <= LRCParser.maximumSourceBytes,
              document.lines.count <= LRCParser.maximumLines else { throw MusicServiceError.invalidResponse }
        switch document.kind {
        case .plain:
            guard document.plainText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                throw MusicServiceError.invalidResponse
            }
        case .synced:
            guard document.lines.contains(where: { !$0.text.isEmpty }),
                  document.lines.allSatisfy({ $0.time.isFinite && $0.time >= 0 }) else { throw MusicServiceError.invalidResponse }
        case .instrumental, .unavailable: break
        }
    }

    private func cancel(key: LyricsRequestKey, waiterID: UUID) {
        guard var flight = flights[key], let waiter = flight.waiters.removeValue(forKey: waiterID) else { return }
        waiter.resume(throwing: CancellationError())
        if flight.waiters.isEmpty {
            flights.removeValue(forKey: key)
            flight.task.cancel()
        } else { flights[key] = flight }
    }

    private func finish(key: LyricsRequestKey, flightID: UUID, result: Result<Outcome, any Error>) {
        guard let flight = flights[key], flight.id == flightID else { return }
        flights.removeValue(forKey: key)
        switch result {
        case .success(let outcome):
            insert(outcome, key: key)
            flight.waiters.values.forEach { $0.resume(returning: outcome.document) }
        case .failure(let error): flight.waiters.values.forEach { $0.resume(throwing: error) }
        }
    }

    private func insert(_ outcome: Outcome, key: LyricsRequestKey) {
        let document = outcome.document
        let bytes = (document.plainText?.utf8.count ?? 0) + document.lines.reduce(0) { $0 + $1.text.utf8.count + 48 }
            + key.id.utf8.count + key.recording.title.utf8.count + key.recording.album.utf8.count
            + key.recording.artists.reduce(0) { $0 + $1.utf8.count } + 1_024
        let lifetime = document.kind == .unavailable ? configuration.missingLifetime
            : (outcome.usedFallback ? configuration.fallbackLifetime : configuration.primaryLifetime)
        guard configuration.capacity > 0, lifetime > 0, bytes <= configuration.maximumBytes else { return }
        access &+= 1
        cache[key] = Entry(document: document, expires: now().addingTimeInterval(lifetime), bytes: bytes, access: access)
        var total = cache.values.reduce(0) { $0 + $1.bytes }
        while cache.count > configuration.capacity || total > configuration.maximumBytes {
            guard let oldest = cache.min(by: { $0.value.access < $1.value.access }) else { break }
            total -= oldest.value.bytes
            cache.removeValue(forKey: oldest.key)
        }
    }
}

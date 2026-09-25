import Foundation
import OSLog

actor ArtistSpotlightLanguageService {
    typealias MetadataLookup = @Sendable (Track) async throws -> ArtistSongLanguageResult?

    struct Configuration: Sendable {
        var capacity = 256
        var positiveLifetime: TimeInterval = 12 * 60 * 60
        var negativeLifetime: TimeInterval = 5 * 60
        var lookupTimeout: TimeInterval = 6
        var sourceTimeout: TimeInterval = 5.5
        var maximumConcurrentLookups = 2
        var maximumWaitersPerLookup = 12
        var recordingMetadataTimeout: TimeInterval = 2
    }

    struct Activity: Sendable {
        let cachedRecordings: Int
        let activeLookups: Int
        let waitingCallers: Int
    }

    private struct Entry {
        let result: ArtistSongLanguageResult
        let expires: Date
        var access: UInt64
    }

    private struct Flight {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<ArtistSongLanguageResult, any Error>]
    }

    private let provider: any LyricsProviding
    private let configuration: Configuration
    private let hypotheses: ArtistSpotlightLanguageClassifier.Hypotheses
    private let metadataLookup: MetadataLookup?
    private let recordingMetadataLookup: MetadataLookup?
    private let now: @Sendable () -> Date
    private var cache: [LyricsRequestKey: Entry] = [:]
    private var flights: [LyricsRequestKey: Flight] = [:]
    private var access: UInt64 = 0

    init(provider: any LyricsProviding, configuration: Configuration = Configuration(),
         hypotheses: @escaping ArtistSpotlightLanguageClassifier.Hypotheses = ArtistSpotlightLanguageClassifier.recognize,
          now: @escaping @Sendable () -> Date = { Date() }, recordingMetadataLookup: MetadataLookup? = nil,
          metadataLookup: MetadataLookup? = nil) {
        self.provider = provider
        self.configuration = configuration
        self.hypotheses = hypotheses
        self.now = now
        self.metadataLookup = metadataLookup
        self.recordingMetadataLookup = recordingMetadataLookup
    }

    var activity: Activity {
        Activity(cachedRecordings: cache.count, activeLookups: flights.count,
                 waitingCallers: flights.values.reduce(0) { $0 + $1.waiters.count })
    }

    func classification(for track: Track) async throws -> ArtistSongLanguageResult {
        try Task.checkCancellation()
        if let metadata = ArtistSongLanguageResult.recordingMetadata(track) {
            ArtistSpotlightDiagnostics.logger.debug("metadataUsed=1 languageSuccess=1 languageFailure=0 languageRejected=0")
            return metadata
        }
        ArtistSpotlightDiagnostics.logger.debug("metadataUsed=0")
        let key = LyricsRequestKey(track)
        cache = cache.filter { $0.value.expires > now() }
        access &+= 1
        if var entry = cache[key] {
            entry.access = access
            cache[key] = entry
            ArtistSpotlightDiagnostics.logger.debug("cacheHit=1 cacheMiss=0 coalesced=0 languageRejected=0")
            return entry.result
        }
        let waiterID = UUID()
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ArtistSongLanguageResult, any Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                if var flight = flights[key] {
                    guard flight.waiters.count < max(1, configuration.maximumWaitersPerLookup) else {
                        ArtistSpotlightDiagnostics.logger.info("languageRejected=1 limit=waiters")
                        continuation.resume(throwing: MusicServiceError.unavailable("Song languages are still being checked."))
                        return
                    }
                    flight.waiters[waiterID] = continuation
                    flights[key] = flight
                    ArtistSpotlightDiagnostics.logger.debug("cacheHit=0 cacheMiss=0 coalesced=1 languageRejected=0")
                    return
                }
                guard flights.count < max(1, configuration.maximumConcurrentLookups) else {
                    ArtistSpotlightDiagnostics.logger.info("languageRejected=1 limit=lookups")
                    continuation.resume(throwing: MusicServiceError.unavailable("Song languages are still being checked."))
                    return
                }
                ArtistSpotlightDiagnostics.logger.debug("cacheHit=0 cacheMiss=1 coalesced=0 languageRejected=0")
                let flightID = UUID()
                let started = now()
                let task = Task<Void, Never> { [provider, configuration, hypotheses, metadataLookup, recordingMetadataLookup] in
                    let result: Result<ArtistSongLanguageResult, any Error>
                    do {
                        let classification = try await PlaybackDeadline.run(seconds: configuration.lookupTimeout) {
                            try await Self.resolve(track, provider: provider, metadataLookup: metadataLookup,
                                                   recordingMetadataLookup: recordingMetadataLookup,
                                                   hypotheses: hypotheses, sourceTimeout: configuration.sourceTimeout,
                                                   recordingMetadataTimeout: configuration.recordingMetadataTimeout)
                        }
                        try Task.checkCancellation()
                        result = .success(classification)
                    } catch { result = .failure(error) }
                    finish(key: key, flightID: flightID, result: result, started: started)
                }
                flights[key] = Flight(id: flightID, task: task, waiters: [waiterID: continuation])
            }
        } onCancel: {
            Task { await self.cancel(waiterID: waiterID, key: key) }
        }
        try Task.checkCancellation()
        return result
    }

    private nonisolated static func resolve(_ track: Track, provider: any LyricsProviding, metadataLookup: MetadataLookup?,
                                           recordingMetadataLookup: MetadataLookup?,
                                           hypotheses: ArtistSpotlightLanguageClassifier.Hypotheses,
                                           sourceTimeout: TimeInterval, recordingMetadataTimeout: TimeInterval) async throws -> ArtistSongLanguageResult {
        let (recording, recordingError) = try await fetchMetadata(track, lookup: recordingMetadataLookup,
            timeout: min(sourceTimeout, recordingMetadataTimeout))
        try Task.checkCancellation()
        if let recording, !recording.isLikely {
            ArtistSpotlightDiagnostics.logger.debug("providerLanguageUsed=1 classificationSkipped=1 providerLanguageFailure=0")
            return recording
        }
        ArtistSpotlightDiagnostics.logger.debug("providerLanguageUsed=0 classificationSkipped=0 providerLanguageFailure=\(recordingError == nil ? 0 : 1)")
        async let metadata = fetchMetadata(track, lookup: metadataLookup, timeout: sourceTimeout)
        var document: LyricsDocument?
        var lookupError: (any Error)?
        do {
            document = try await PlaybackDeadline.run(seconds: sourceTimeout) { try await provider.lyrics(for: track) }
        }
        catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            lookupError = error
        }
        try Task.checkCancellation()
        if document?.kind == .instrumental { return .unclassified(.noMatchedLyrics) }
        let (work, metadataError) = try await metadata
        let lyrics = document.map { ArtistSpotlightLanguageClassifier.classify($0, for: track, hypotheses: hypotheses) }
        let result = ArtistSpotlightLanguageSignals.combine(lyrics: lyrics, metadata: work, title: track.title)
        ArtistSpotlightDiagnostics.logger.debug("lyricsSourceFailure=\(lookupError == nil ? 0 : 1) metadataSourceFailure=\(metadataError == nil ? 0 : 1) languageConflict=\(result.hasConflictingEvidence ? 1 : 0)")
        if result.language == nil, !result.hasConflictingEvidence, work != .unclassified(.uncertainLanguage),
           let error = lookupError ?? metadataError { throw error }
        try Task.checkCancellation()
        return result
    }

    private nonisolated static func fetchMetadata(_ track: Track, lookup: MetadataLookup?, timeout: TimeInterval) async throws -> (ArtistSongLanguageResult?, (any Error)?) {
        guard let lookup else { return (nil, nil) }
        do {
            let result = try await PlaybackDeadline.run(seconds: timeout) { try await lookup(track) }
            return (result, nil)
        }
        catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            return (nil, error)
        }
    }

    private func cancel(waiterID: UUID, key: LyricsRequestKey) {
        guard var flight = flights[key], let waiter = flight.waiters.removeValue(forKey: waiterID) else { return }
        waiter.resume(throwing: CancellationError())
        if flight.waiters.isEmpty {
            flights.removeValue(forKey: key)
            flight.task.cancel()
        } else { flights[key] = flight }
        ArtistSpotlightDiagnostics.logger.debug("languageCancelled=1")
    }

    private func finish(key: LyricsRequestKey, flightID: UUID,
                        result: Result<ArtistSongLanguageResult, any Error>, started: Date) {
        guard let flight = flights[key], flight.id == flightID else { return }
        flights.removeValue(forKey: key)
        let milliseconds = Int(max(0, now().timeIntervalSince(started)) * 1_000)
        switch result {
        case .success(let classification):
            insert(classification, key: key)
            ArtistSpotlightDiagnostics.logger.info("languageSuccess=1 languageFailure=0 languageCancelled=0 timedOut=0 inferred=\(classification.isInferred ? 1 : 0) unclassified=\(classification.language == nil ? 1 : 0) latencyMs=\(milliseconds)")
        case .failure(let error):
            let cancelled = error is CancellationError
            let timedOut: Bool
            if let error = error as? PlaybackStreamError, case .timedOut = error { timedOut = true }
            else { timedOut = false }
            ArtistSpotlightDiagnostics.logger.info("languageSuccess=0 languageFailure=\(cancelled ? 0 : 1) languageCancelled=\(cancelled ? 1 : 0) timedOut=\(timedOut ? 1 : 0) inferred=0 unclassified=0 latencyMs=\(milliseconds)")
        }
        for waiter in flight.waiters.values { waiter.resume(with: result) }
    }

    private func insert(_ result: ArtistSongLanguageResult, key: LyricsRequestKey) {
        let lifetime = result.language == nil ? configuration.negativeLifetime : configuration.positiveLifetime
        guard configuration.capacity > 0, lifetime > 0 else { return }
        access &+= 1
        cache[key] = Entry(result: result, expires: now().addingTimeInterval(lifetime), access: access)
        while cache.count > configuration.capacity {
            guard let oldest = cache.min(by: { $0.value.access < $1.value.access })?.key else { break }
            cache.removeValue(forKey: oldest)
        }
    }
}

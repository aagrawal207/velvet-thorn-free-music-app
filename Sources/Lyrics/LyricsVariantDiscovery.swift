import Foundation
import OSLog

actor LyricsVariantDiscovery {
    struct Activity: Sendable {
        let cachedRecordings: Int
        let cachedBytes: Int
        let activeLookups: Int
        let waitingCallers: Int
    }

    struct Configuration: Sendable {
        var capacity = 32
        var maximumBytes = 4 * 1_024 * 1_024
        var lifetime: TimeInterval = 10 * 60
        var missingLifetime: TimeInterval = 60
        var totalTimeout: TimeInterval = 12
        var sourceTimeout: TimeInterval = 3
    }

    private struct Entry {
        let documents: [LyricsDocument]
        let expires: Date
        let bytes: Int
        var access: UInt64
    }

    private struct Flight {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<[LyricsDocument], any Error>]
    }

    private struct Key: Hashable {
        let recording: LyricsRequestKey
        let language: MusicLanguage?
    }

    private struct Outcome: Sendable {
        let documents: [LyricsDocument]
        let complete: Bool
    }

    private let configuration: Configuration
    private let now: @Sendable () -> Date
    private var cache: [Key: Entry] = [:]
    private var flights: [Key: Flight] = [:]
    private var access: UInt64 = 0

    init(configuration: Configuration = Configuration(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.configuration = configuration
        self.now = now
    }

    var activity: Activity {
        Activity(cachedRecordings: cache.count, cachedBytes: cache.values.reduce(0) { $0 + $1.bytes },
                 activeLookups: flights.count, waitingCallers: flights.values.reduce(0) { $0 + $1.waiters.count })
    }

    func documents(for track: Track, baseline: any LyricsProviding,
                   sources: [any LyricsProviding]) async throws -> [LyricsDocument] {
        try Task.checkCancellation()
        let key = Key(recording: LyricsRequestKey(track), language: track.language)
        cache = cache.filter { $0.value.expires > now() }
        access &+= 1
        if var entry = cache[key] {
            entry.access = access
            cache[key] = entry
            LyricsDiagnostics.logger.debug("variantCacheHit=1 variantCacheMiss=0")
            return entry.documents
        }
        LyricsDiagnostics.logger.debug("variantCacheHit=0 variantCacheMiss=1")
        let waiterID = UUID()
        let documents = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[LyricsDocument], any Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                if var flight = flights[key] {
                    guard flight.waiters.count < 16 else { continuation.resume(throwing: LyricsLookupError.sourcesFailed); return }
                    flight.waiters[waiterID] = continuation
                    flights[key] = flight
                    return
                }
                guard flights.count < 2 else { continuation.resume(throwing: LyricsLookupError.sourcesFailed); return }
                let id = UUID()
                let task = Task { [configuration] in
                    let result: Result<Outcome, any Error>
                    do {
                        let outcome = try await Self.lookup(track, baseline: baseline,
                                                            sources: Array(sources.prefix(3)), configuration: configuration)
                        try Task.checkCancellation()
                        result = .success(outcome)
                    } catch { result = .failure(error) }
                    finish(key: key, id: id, result: result)
                }
                flights[key] = Flight(id: id, task: task, waiters: [waiterID: continuation])
            }
        } onCancel: {
            Task { await self.cancel(key: key, waiterID: waiterID) }
        }
        try Task.checkCancellation()
        return documents
    }

    private nonisolated static func lookup(_ track: Track, baseline: any LyricsProviding,
                                          sources: [any LyricsProviding], configuration: Configuration) async throws -> Outcome {
        let deadline = Date().addingTimeInterval(configuration.totalTimeout)
        var documents: [LyricsDocument] = []
        var complete = true
        do {
            let document = try await PlaybackDeadline.run(seconds: min(6, configuration.totalTimeout)) {
                try await baseline.lyrics(for: track)
            }
            try Task.checkCancellation()
            try document.validateVariant(for: track)
            LyricsDiagnostics.logger.debug("variantBaselineSuccess=1 variantBaselineFailure=0 outcome=\(document.kind.rawValue, privacy: .public)")
            if document.kind == .instrumental { return Outcome(documents: [document], complete: true) }
            if document.kind != .unavailable { documents.append(document) }
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            complete = false
            LyricsDiagnostics.logger.debug("variantBaselineSuccess=0 variantBaselineFailure=1")
        }
        for source in sources {
            try Task.checkCancellation()
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { complete = false; break }
            let started = Date()
            do {
                let found = try await PlaybackDeadline.run(seconds: min(configuration.sourceTimeout, remaining)) {
                    if let variants = source as? any LyricsVariantsProviding {
                        return try await variants.lyricVariants(for: track)
                    }
                    return [try await source.lyrics(for: track)]
                }
                try Task.checkCancellation()
                guard found.count <= 8 else { throw MusicServiceError.invalidResponse }
                for document in found { try document.validateVariant(for: track) }
                for document in found where document.kind == .plain || document.kind == .synced {
                    if let index = documents.firstIndex(where: { $0.samePublishedContent(as: document) }) {
                        if document.attributionText != nil || documents[index].attributionText == nil {
                            documents[index] = document
                        }
                    } else if documents.count < 8 { documents.append(document) }
                }
                let count = found.filter { $0.kind == .plain || $0.kind == .synced }.count
                let milliseconds = Int(max(0, Date().timeIntervalSince(started)) * 1_000)
                LyricsDiagnostics.logger.debug("variantSourceSuccess=1 variantSourceFailure=0 variantSourceTimedOut=0 candidates=\(count) latencyMs=\(milliseconds)")
                if documents.isEmpty, let instrumental = found.first(where: { $0.kind == .instrumental }) {
                    return Outcome(documents: [instrumental], complete: complete)
                }
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                complete = false
                let timedOut: Bool
                if let streamError = error as? PlaybackStreamError, case .timedOut = streamError { timedOut = true }
                else { timedOut = false }
                let milliseconds = Int(max(0, Date().timeIntervalSince(started)) * 1_000)
                LyricsDiagnostics.logger.debug("variantSourceSuccess=0 variantSourceFailure=1 variantSourceTimedOut=\(timedOut ? 1 : 0) candidates=0 latencyMs=\(milliseconds)")
            }
        }
        try Task.checkCancellation()
        if documents.isEmpty {
            guard complete else { throw LyricsLookupError.sourcesFailed }
            documents = [LyricsDocument(trackID: track.id, kind: .unavailable, source: "Available lyrics sources")]
        }
        return Outcome(documents: documents, complete: complete)
    }

    private func cancel(key: Key, waiterID: UUID) {
        guard var flight = flights[key], let waiter = flight.waiters.removeValue(forKey: waiterID) else { return }
        waiter.resume(throwing: CancellationError())
        if flight.waiters.isEmpty {
            flights.removeValue(forKey: key)
            flight.task.cancel()
            LyricsDiagnostics.logger.debug("variantCancelled=1")
        } else { flights[key] = flight }
    }

    private func finish(key: Key, id: UUID, result: Result<Outcome, any Error>) {
        guard let flight = flights[key], flight.id == id else { return }
        flights.removeValue(forKey: key)
        switch result {
        case .success(let outcome):
            if outcome.complete { insert(outcome.documents, key: key) }
            flight.waiters.values.forEach { $0.resume(returning: outcome.documents) }
        case .failure(let error): flight.waiters.values.forEach { $0.resume(throwing: error) }
        }
    }

    private func insert(_ documents: [LyricsDocument], key: Key) {
        guard let bytes = try? JSONEncoder().encode(documents).count,
              configuration.capacity > 0, bytes <= configuration.maximumBytes else { return }
        let lifetime = documents.allSatisfy { $0.kind == .unavailable } ? configuration.missingLifetime : configuration.lifetime
        guard lifetime > 0 else { return }
        access &+= 1
        cache[key] = Entry(documents: documents, expires: now().addingTimeInterval(lifetime), bytes: bytes, access: access)
        var total = cache.values.reduce(0) { $0 + $1.bytes }
        while cache.count > configuration.capacity || total > configuration.maximumBytes {
            guard let oldest = cache.min(by: { $0.value.access < $1.value.access }) else { break }
            total -= oldest.value.bytes
            cache.removeValue(forKey: oldest.key)
        }
    }
}

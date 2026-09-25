import Foundation
import Observation
import OSLog

@MainActor @Observable
final class ListeningLanguageDiscovery {
    struct Configuration: Sendable {
        var batchSize = 12
        var maximumConcurrentChecks = 2
        var maximumPendingCandidates = 128
        var maximumCacheEntries = ListeningLanguageDiscoveryCache.maximumEntries
        var positiveLifetime = ListeningLanguageDiscoveryCache.positiveLifetime
        var negativeLifetime = ListeningLanguageDiscoveryCache.negativeLifetime
        var calendar = Calendar.current

        fileprivate var bounded: Self {
            var value = self
            value.batchSize = min(12, max(1, batchSize))
            value.maximumCacheEntries = min(ListeningLanguageDiscoveryCache.maximumEntries, max(1, maximumCacheEntries))
            value.maximumConcurrentChecks = min(2, value.maximumCacheEntries, max(1, maximumConcurrentChecks))
            value.maximumPendingCandidates = min(128, max(1, maximumPendingCandidates))
            value.positiveLifetime = positiveLifetime.isFinite
                ? min(ListeningLanguageDiscoveryCache.positiveLifetime, max(0.001, positiveLifetime))
                : ListeningLanguageDiscoveryCache.positiveLifetime
            value.negativeLifetime = negativeLifetime.isFinite
                ? min(ListeningLanguageDiscoveryCache.negativeLifetime, max(0.001, negativeLifetime))
                : ListeningLanguageDiscoveryCache.negativeLifetime
            return value
        }
    }

    // Corrections and verified metadata stay with their authoritative inputs, ahead of this derived evidence.
    private(set) var results: [LyricsRequestKey: ArtistSongLanguageResult] = [:]
    private(set) var isChecking = false
    private(set) var hasPendingChecks = false
    private(set) var hadFailures = false
    // This is the last disk outcome; a newer in-progress pass can still contain memory-only evidence.
    private(set) var cacheStatus: ListeningLanguageDiscoveryCache.Status
    @ObservationIgnored var onResultsChanged: (@MainActor () -> Void)?

    struct Activity: Sendable {
        let cachedRecordings: Int
        let snapshotRecordings: Int
        let pendingCandidates: Int
        let activeLookups: Int
    }

    var activity: Activity {
        Activity(cachedRecordings: entries.count, snapshotRecordings: snapshot.count,
                 pendingCandidates: pending.count, activeLookups: flights.count)
    }

    private struct Candidate {
        let key: LyricsRequestKey
        let track: Track
        let order: Int
    }

    private struct Pass {
        let id = UUID()
        var attempted = Set<LyricsRequestKey>()
        var completed = 0
        var failed = 0
        var cancelled = 0
    }

    private struct Flight {
        let id: UUID
        let passID: UUID
        let task: Task<Void, Never>
        var cancelled = false
    }

    @ObservationIgnored private let service: ArtistSpotlightLanguageService
    @ObservationIgnored private let configuration: Configuration
    @ObservationIgnored private let clock: @Sendable () -> Date
    @ObservationIgnored private let diskCache: ListeningLanguageDiscoveryCache?
    @ObservationIgnored private var entries: [LyricsRequestKey: ListeningLanguageDiscoveryCache.Entry] = [:]
    @ObservationIgnored private var snapshot: [Candidate] = []
    @ObservationIgnored private var allowedKeys = Set<LyricsRequestKey>()
    @ObservationIgnored private var pending: [Candidate] = []
    @ObservationIgnored private var flights: [LyricsRequestKey: Flight] = [:]
    @ObservationIgnored private var pass: Pass?
    @ObservationIgnored private var enabled = false
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var cacheLoaded: Bool
    @ObservationIgnored private var cacheDirty = false
    @ObservationIgnored private var loadID: UUID?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var storageRevision: UInt64 = 0
    @ObservationIgnored private var storageTask: Task<Void, Never>?
    @ObservationIgnored private var isNotifyingResults = false

    init(service: ArtistSpotlightLanguageService, cacheURL: URL? = nil,
         now: @escaping @Sendable () -> Date = { Date() }, configuration: Configuration = Configuration()) {
        self.service = service
        self.configuration = configuration.bounded
        clock = now
        diskCache = cacheURL.map { ListeningLanguageDiscoveryCache(url: $0) }
        cacheLoaded = cacheURL == nil
        cacheStatus = cacheURL == nil ? .memoryOnly : .notLoaded
    }

    isolated deinit {
        loadTask?.cancel()
        for flight in flights.values { flight.task.cancel() }
    }

    /// Each refresh authorizes one bounded pass; checkpoints replace eligibility without restarting useful work.
    func refresh(events: [ListeningEvent], overrides: [String: String], enabled: Bool, now: Date = Date()) {
        let previous = results
        if !enabled, self.enabled { stopChecks() }
        self.enabled = enabled
        snapshot = qualifiedSnapshot(events: events, overrides: overrides, now: now)
        allowedKeys = Set(snapshot.map(\.key))
        reconcile()
        if !cacheLoaded { startCacheLoad() }
        pump(startPass: enabled && !isNotifyingResults)
        if pass == nil { persistIfNeeded() }
        notifyResultsChanged(if: results != previous)
    }

    /// Backgrounding retires requests, while already accepted evidence remains available to saved-history stats.
    func pause() {
        stopChecks()
        persistIfNeeded()
    }

    func reset() {
        let changed = !results.isEmpty
        stopChecks()
        entries = [:]
        results = [:]
        hadFailures = false
        cacheDirty = false
        cacheLoaded = true
        if let diskCache {
            storageRevision &+= 1
            let revision = storageRevision
            // Reset commands outlive the coordinator. The actor's revision fence rejects every older save.
            storageTask = Task(priority: .utility) { [weak self] in
                let status = await diskCache.reset(revision: revision)
                self?.finishStorage(status, revision: revision)
            }
        }
        notifyResultsChanged(if: changed)
    }

    /// Drains scheduled checks and cache commands, without authorizing another pass.
    func waitForChecks() async {
        while !Task.isCancelled {
            guard let task = loadTask ?? flights.values.first?.task ?? storageTask else { return }
            await task.value
        }
    }

    private func qualifiedSnapshot(events: [ListeningEvent], overrides: [String: String], now: Date) -> [Candidate] {
        guard LibraryValidation.isValidDate(now),
              let cutoff = configuration.calendar.date(byAdding: .day, value: -ListeningWindow.month.days, to: now) else { return [] }
        var seenSessions = Set<UUID>()
        let valid = events.filter {
            LibraryValidation.isValidDate($0.startedAt) && $0.startedAt <= now
                && LibraryValidation.isValidListeningSeconds($0.listenedSeconds, now: now)
                && (try? LibraryValidation.validateTrack($0.track)) != nil
                && seenSessions.insert($0.id).inserted
                && $0.startedAt >= cutoff && $0.listenedSeconds >= ListeningAnalytics.qualifyingSeconds(for: $0.track)
        }.sorted {
            $0.startedAt == $1.startedAt ? $0.id.uuidString < $1.id.uuidString : $0.startedAt > $1.startedAt
        }
        let usefulFlights = Set(flights.filter { !$0.value.cancelled }.map(\.key))
        let usefulIDs = Set(usefulFlights.map(\.id))
        let previousKeys = Dictionary(uniqueKeysWithValues: snapshot.map { ($0.track, $0.key) })
        var currentKeys: [Track: LyricsRequestKey] = [:]
        var selected: [Candidate] = []
        var retained: [Candidate] = []
        var seenKeys = Set<LyricsRequestKey>()
        for (order, event) in valid.enumerated() {
            if selected.count == configuration.maximumCacheEntries, retained.count == usefulFlights.count { break }
            let track = event.track
            guard selected.count < configuration.maximumCacheEntries || usefulIDs.contains(track.id),
                  overrides[track.id] == nil, ArtistSongLanguageResult.recordingMetadata(track) == nil,
                  track.id.utf8.count <= 512, track.title.utf8.count <= 2_048,
                  (track.albumTitle?.utf8.count ?? 0) <= 2_048, track.credits.count <= 32,
                  track.credits.allSatisfy({ $0.name.utf8.count <= 512 }) else { continue }
            let key = currentKeys[track] ?? previousKeys[track] ?? LyricsRequestKey(track)
            if currentKeys.count < configuration.maximumCacheEntries { currentKeys[track] = key }
            guard ListeningLanguageDiscoveryCache.accepts(key), seenKeys.insert(key).inserted else { continue }
            let candidate = Candidate(key: key, track: track, order: order)
            if usefulFlights.contains(key) { retained.append(candidate) }
            if selected.count < configuration.maximumCacheEntries { selected.append(candidate) }
        }
        // A burst of newer history must not starve an unchanged request already using a service slot.
        for candidate in retained where !selected.contains(where: { $0.key == candidate.key }) {
            if let index = selected.lastIndex(where: { !usefulFlights.contains($0.key) }) { selected.remove(at: index) }
            selected.append(candidate)
        }
        return selected.sorted { $0.order < $1.order }
    }

    private func reconcile() {
        let current = clock()
        let kept = entries.filter { allowedKeys.contains($0.key) && $0.value.isReusable(at: current) }
        if kept != entries {
            entries = kept
            // Viewing preserved history while discovery is off does not authorize a cache rewrite.
            if enabled { cacheDirty = true }
        }
        for (key, var flight) in flights where !allowedKeys.contains(key) && !flight.cancelled {
            flight.cancelled = true
            flights[key] = flight
            flight.task.cancel()
        }
        results = entries.mapValues(\.result)
        hadFailures = results.values.contains(.unclassified(.lookupFailed))
        updatePending()
    }

    private func updatePending() {
        pending = Array(snapshot.lazy.filter {
            self.entries[$0.key] == nil && self.flights[$0.key]?.cancelled != false && self.pass?.attempted.contains($0.key) != true
        }.prefix(configuration.maximumPendingCandidates))
        hasPendingChecks = enabled && !pending.isEmpty
        isChecking = enabled && (loadTask != nil || pass != nil)
    }

    private func pump(startPass: Bool) {
        guard enabled, cacheLoaded else { updatePending(); return }
        if pass == nil, startPass, !pending.isEmpty { pass = Pass() }
        while let current = pass, current.attempted.count < configuration.batchSize,
              flights.count < configuration.maximumConcurrentChecks,
              let candidate = pending.first(where: { flights[$0.key] == nil }) {
            pass?.attempted.insert(candidate.key)
            start(candidate, passID: current.id)
            updatePending()
        }
        if let current = pass, !flights.values.contains(where: { $0.passID == current.id }),
           current.attempted.count >= configuration.batchSize || pending.isEmpty {
            record(current)
            pass = nil
            persistIfNeeded()
        }
        updatePending()
    }

    private func start(_ candidate: Candidate, passID: UUID) {
        let id = UUID()
        let request = generation
        let service = service
        let task = Task(priority: .utility) { [weak self] in
            let outcome: Result<ArtistSongLanguageResult, any Error>
            do {
                let result = try await service.classification(for: candidate.track)
                try Task.checkCancellation()
                outcome = .success(result)
            } catch { outcome = .failure(error) }
            self?.finish(outcome, key: candidate.key, id: id, generation: request)
        }
        flights[candidate.key] = Flight(id: id, passID: passID, task: task)
    }

    private func finish(_ outcome: Result<ArtistSongLanguageResult, any Error>, key: LyricsRequestKey,
                        id: UUID, generation request: UUID) {
        guard let flight = flights[key], flight.id == id else { return }
        flights.removeValue(forKey: key)
        let previous = results
        let cancelled = flight.cancelled || Task.isCancelled || request != generation || !enabled || !allowedKeys.contains(key)
        let result: ArtistSongLanguageResult?
        switch outcome {
        case .success(let value):
            result = cancelled ? nil : (ListeningLanguageDiscoveryCache.accepts(value) ? value : .unclassified(.lookupFailed))
        case .failure:
            result = cancelled ? nil : .unclassified(.lookupFailed)
        }
        if flight.passID == pass?.id {
            if let result {
                if result == .unclassified(.lookupFailed) { pass?.failed += 1 }
                else { pass?.completed += 1 }
            } else { pass?.cancelled += 1 }
        }
        if let result {
            let checked = clock()
            let lifetime = result.language == nil ? configuration.negativeLifetime : configuration.positiveLifetime
            let expiry = checked.addingTimeInterval(lifetime)
            if LibraryValidation.isValidDate(checked), LibraryValidation.isValidDate(expiry) {
                entries[key] = .init(key: key, result: result, checkedAt: checked, expiresAt: expiry)
                cacheDirty = true
            }
        }
        // Paused snapshots are retired, but their previously published results are still saved-history evidence.
        if enabled { reconcile() }
        pump(startPass: false)
        notifyResultsChanged(if: results != previous)
    }

    private func stopChecks() {
        generation = UUID()
        enabled = false
        loadTask?.cancel()
        loadTask = nil
        loadID = nil
        if var current = pass {
            current.cancelled += flights.values.filter { $0.passID == current.id }.count
            record(current)
        }
        pass = nil
        for (key, var flight) in flights {
            flight.cancelled = true
            flights[key] = flight
            flight.task.cancel()
        }
        snapshot = []
        allowedKeys = []
        pending = []
        isChecking = false
        hasPendingChecks = false
    }

    private func startCacheLoad() {
        guard loadTask == nil, let diskCache else { return }
        let id = UUID()
        let request = generation
        loadID = id
        loadTask = Task(priority: .utility) { [weak self] in
            let loaded = await diskCache.load()
            guard !Task.isCancelled else { return }
            self?.finishLoad(loaded, id: id, generation: request)
        }
    }

    private func finishLoad(_ loaded: ListeningLanguageDiscoveryCache.Load, id: UUID, generation request: UUID) {
        guard loadID == id, generation == request else { return }
        let previous = results
        loadTask = nil
        loadID = nil
        cacheLoaded = true
        cacheStatus = loaded.status
        for entry in loaded.entries where entries[entry.key] == nil { entries[entry.key] = entry }
        reconcile()
        pump(startPass: enabled)
        if pass == nil { persistIfNeeded() }
        notifyResultsChanged(if: results != previous)
    }

    private func persistIfNeeded() {
        guard cacheLoaded, cacheDirty else { return }
        cacheDirty = false
        guard let diskCache else { return }
        storageRevision &+= 1
        let revision = storageRevision
        let saved = snapshot.compactMap { entries[$0.key] }
        // A paused owner has released input tracks; accepted entries contain only keys, results and check expiry.
        let records = snapshot.isEmpty ? Array(entries.values) : saved
        storageTask = Task(priority: .utility) { [weak self] in
            let status = await diskCache.save(records, revision: revision)
            self?.finishStorage(status, revision: revision)
        }
    }

    private func finishStorage(_ status: ListeningLanguageDiscoveryCache.Status, revision: UInt64) {
        guard storageRevision == revision else { return }
        cacheStatus = status
        storageTask = nil
    }

    private func notifyResultsChanged(if changed: Bool) {
        guard changed, !isNotifyingResults else { return }
        // Recomputing a stats projection in the callback cannot authorize a second automatic pass.
        isNotifyingResults = true
        defer { isNotifyingResults = false }
        onResultsChanged?()
    }

    private func record(_ pass: Pass) {
        ArtistSpotlightDiagnostics.logger.info("listeningPassCompleted=\(pass.completed) listeningPassFailed=\(pass.failed) listeningPassCancelled=\(pass.cancelled) listeningPassStarted=\(pass.attempted.count)")
    }
}

import Foundation
import Observation
import OSLog

/// Pure decision logic for one recording: which evidence source wins and whether one more request is worth spending.
enum GenreClassifier {
    /// Search, recording lookup and one follow-up; the same cap the Song details fetch keeps.
    static let requestBudget = 3

    enum FollowUp: Equatable, Sendable {
        case artist(String), releaseGroup(String)
    }

    struct Outcome: Equatable, Sendable {
        var distribution: GenreDistribution
        /// Artist evidence worth caching, embedded or fetched, including negatives so a bare artist is asked once.
        var artists: [String: GenreDistribution]
        var requests: Int
    }

    enum Plan: Equatable, Sendable {
        case settled(Outcome)
        case followUp(FollowUp, partial: Outcome)
    }

    /// Recording genres win, then embedded release-group genres, then embedded or cached artist genres. Without any
    /// of those, one follow-up goes to an unknown credited artist (reused by every song of theirs) or else the release group.
    static func plan(_ lookup: MusicBrainzGenreLookup, cachedArtist: (String) -> GenreDistribution?) -> Plan {
        guard let genres = lookup.genres else {
            return .settled(Outcome(distribution: .unclassified, artists: [:], requests: lookup.requests))
        }
        var artists: [String: GenreDistribution] = [:]
        for (id, votes) in genres.artists {
            artists[id] = GenreTaxonomy.distribution(votes: votes, source: .artist) ?? .unclassified
        }
        var outcome = Outcome(distribution: .unclassified, artists: artists, requests: lookup.requests)
        if let recording = GenreTaxonomy.distribution(votes: genres.recording, source: .recording) {
            outcome.distribution = recording
            return .settled(outcome)
        }
        if let votes = genres.releaseGroup, let group = GenreTaxonomy.distribution(votes: votes, source: .releaseGroup) {
            outcome.distribution = group
            return .settled(outcome)
        }
        for id in genres.artistIDs {
            if let embedded = artists[id], embedded.isClassified {
                outcome.distribution = embedded
                return .settled(outcome)
            }
            if let cached = cachedArtist(id), cached.isClassified {
                outcome.distribution = cached
                return .settled(outcome)
            }
        }
        guard lookup.requests < requestBudget else { return .settled(outcome) }
        if let unknown = genres.artistIDs.first(where: { artists[$0] == nil && cachedArtist($0) == nil }) {
            return .followUp(.artist(unknown), partial: outcome)
        }
        if let group = genres.releaseGroupID, genres.releaseGroup == nil {
            return .followUp(.releaseGroup(group), partial: outcome)
        }
        return .settled(outcome)
    }

    static func finish(_ followUp: FollowUp, votes: [GenreVote], partial: Outcome) -> Outcome {
        var outcome = partial
        outcome.requests += 1
        switch followUp {
        case .artist(let id):
            let distribution = GenreTaxonomy.distribution(votes: votes, source: .artist) ?? .unclassified
            outcome.artists[id] = distribution
            if distribution.isClassified { outcome.distribution = distribution }
        case .releaseGroup:
            if let distribution = GenreTaxonomy.distribution(votes: votes, source: .releaseGroup) {
                outcome.distribution = distribution
            }
        }
        return outcome
    }
}

/// Classifies qualified recent plays one at a time within the session budget and records the answers in the store.
@MainActor @Observable
final class GenreEvidenceLoader {
    struct Configuration: Sendable {
        var sessionBudget = 60
        var launchDelay: TimeInterval = 10
        var calendar = Calendar.current

        fileprivate var bounded: Self {
            var value = self
            value.sessionBudget = min(60, max(0, sessionBudget))
            value.launchDelay = launchDelay.isFinite ? min(10, max(0, launchDelay)) : 10
            return value
        }
    }

    static let log = GenreEvidenceStore.log

    private(set) var isChecking = false
    private(set) var classifiedThisSession = 0
    private(set) var pendingCount = 0

    private struct Candidate {
        let key: LyricsRequestKey
        let track: Track
    }

    @ObservationIgnored let store: GenreEvidenceStore
    @ObservationIgnored private let provider: (any GenreMetadataProviding)?
    @ObservationIgnored private let configuration: Configuration
    @ObservationIgnored private let clock: @Sendable () -> Date
    @ObservationIgnored private let launchedAt: Date
    @ObservationIgnored private var enabled = false
    @ObservationIgnored private var pending: [Candidate] = []
    @ObservationIgnored private var attempted: Set<LyricsRequestKey> = []
    @ObservationIgnored private var pump: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()

    init(store: GenreEvidenceStore, provider: (any GenreMetadataProviding)?,
         configuration: Configuration = Configuration(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.provider = provider
        self.configuration = configuration.bounded
        clock = now
        launchedAt = now()
    }

    isolated deinit {
        pump?.cancel()
        loadTask?.cancel()
    }

    /// Replaces the eligible set from the last 30 days of qualified plays; each recording is attempted once per session.
    func refresh(events: [ListeningEvent], enabled: Bool, now: Date = Date()) {
        self.enabled = enabled
        // Saved evidence feeds Recap and Settings even while offline or with history off, so the read never waits for a pass.
        if !store.isLoaded, loadTask == nil {
            loadTask = Task { @MainActor [weak self] in
                await self?.store.load()
                self?.loadTask = nil
            }
        }
        let snapshot = Self.qualifiedRecordings(events: events, now: now, calendar: configuration.calendar)
        store.touch(snapshot.map(\.key))
        pending = snapshot.filter { store.needsClassification($0.key) && !attempted.contains($0.key) }
        pendingCount = pending.count
        guard enabled else { stop(); return }
        startPumpIfNeeded()
    }

    /// Backgrounding and known-offline stop the requests; recorded evidence stays.
    func pause() {
        enabled = false
        stop()
    }

    /// A history clear forgets which recordings were attempted; the session budget itself is not refunded.
    func reset() {
        stop()
        attempted = []
        pending = []
        pendingCount = 0
    }

    func waitForChecks() async {
        while let task = loadTask ?? pump, !Task.isCancelled { await task.value }
    }

    /// Distinct recordings with a qualified play in the last 30 days, most recent first, with the recap's validation.
    private static func qualifiedRecordings(events: [ListeningEvent], now: Date, calendar: Calendar) -> [Candidate] {
        guard LibraryValidation.isValidDate(now),
              let cutoff = calendar.date(byAdding: .day, value: -ListeningWindow.month.days, to: now) else { return [] }
        var sessions = Set<UUID>()
        let valid = events.filter {
            LibraryValidation.isValidDate($0.startedAt) && $0.startedAt <= now && $0.startedAt >= cutoff
                && LibraryValidation.isValidListeningSeconds($0.listenedSeconds, now: now)
                && (try? LibraryValidation.validateTrack($0.track)) != nil
                && $0.listenedSeconds >= ListeningAnalytics.qualifyingSeconds(for: $0.track)
                && sessions.insert($0.id).inserted
        }.sorted {
            $0.startedAt == $1.startedAt ? $0.id.uuidString < $1.id.uuidString : $0.startedAt > $1.startedAt
        }
        var seen = Set<LyricsRequestKey>()
        return valid.compactMap { event in
            let key = LyricsRequestKey(event.track)
            guard seen.insert(key).inserted else { return nil }
            return Candidate(key: key, track: event.track)
        }
    }

    private func startPumpIfNeeded() {
        guard enabled, pump == nil, provider != nil, !pending.isEmpty,
              classifiedThisSession < configuration.sessionBudget else { return }
        let generation = UUID()
        self.generation = generation
        isChecking = true
        pump = Task { @MainActor [weak self] in
            await self?.run(generation)
        }
    }

    private func stop() {
        generation = UUID()
        pump?.cancel()
        pump = nil
        isChecking = false
    }

    private func run(_ generation: UUID) async {
        defer {
            if self.generation == generation {
                pump = nil
                isChecking = false
            }
        }
        await store.load()
        guard self.generation == generation, !Task.isCancelled else { return }
        // Launch is busy with restore, Home and the language checks; genres wait their turn on the shared limiter.
        let sinceLaunch = clock().timeIntervalSince(launchedAt)
        if sinceLaunch < configuration.launchDelay {
            try? await Task.sleep(for: .seconds(configuration.launchDelay - sinceLaunch))
            guard self.generation == generation, !Task.isCancelled else { return }
        }
        var completed = 0
        var failed = 0
        while self.generation == generation, !Task.isCancelled, enabled,
              classifiedThisSession < configuration.sessionBudget,
              let candidate = pending.first(where: { store.needsClassification($0.key) && !attempted.contains($0.key) }) {
            pending.removeAll { $0.key == candidate.key }
            pendingCount = pending.count
            attempted.insert(candidate.key)
            classifiedThisSession += 1
            do {
                let outcome = try await classify(candidate.track)
                guard self.generation == generation, !Task.isCancelled else { return }
                store.record(outcome.distribution, for: candidate.key)
                for (id, distribution) in outcome.artists { store.recordArtist(distribution, id: id) }
                completed += 1
                Self.log.info("event=genre_classified source=\(outcome.distribution.source.rawValue, privacy: .public) families=\(outcome.distribution.shares.count) requests=\(outcome.requests)")
            } catch is CancellationError {
                return
            } catch {
                guard self.generation == generation, !Task.isCancelled else { return }
                // A transport failure is not negative evidence; the recording is retried in a later session.
                failed += 1
                Self.log.info("event=genre_classify_failed")
            }
        }
        Self.log.info("event=genre_pass completed=\(completed) failed=\(failed) pending=\(self.pending.count) session=\(self.classifiedThisSession)")
    }

    private func classify(_ track: Track) async throws -> GenreClassifier.Outcome {
        guard let provider else { throw CancellationError() }
        let lookup = try await provider.recordingGenres(for: track)
        try Task.checkCancellation()
        switch GenreClassifier.plan(lookup, cachedArtist: { store.artistDistribution(id: $0) }) {
        case .settled(let outcome):
            return outcome
        case .followUp(let followUp, let partial):
            let votes: [GenreVote]
            switch followUp {
            case .artist(let id): votes = try await provider.artistGenres(id: id)
            case .releaseGroup(let id): votes = try await provider.releaseGroupGenres(id: id)
            }
            try Task.checkCancellation()
            return GenreClassifier.finish(followUp, votes: votes, partial: partial)
        }
    }
}

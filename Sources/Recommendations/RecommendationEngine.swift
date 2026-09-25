import Foundation
import OSLog

/// On-device recommendations built from a `TasteProfile` and a bounded number of catalog calls.
struct RecommendationEngine: Sendable {
    static let providerCallBudget = 10
    static let seedTrackCount = 4
    static let seedArtistCount = 3
    static let relatedArtistsPerSeed = 2
    static let relatedArtistFetchCap = 4
    static let discoverWeeklyTarget = 30
    static let dailyMixTarget = 25
    static let dailyMixFamiliarShare = 0.4
    static let minimumPlaylistSize = 8
    static let discoverWeeklyArtistCap = 2
    static let dailyMixArtistCap = 3
    static let sectionTrackLimit = 12
    static let knownArtistPenalty = 0.55
    static let jitterRange = 0.15
    static let durationRange: ClosedRange<TimeInterval> = 30...900
    /// Mirrors CatalogDiscovery's private list; recommendations must never surface these variants.
    static let excludedVersions = ["karaoke", "slowed", "sped up", "sped-up", "8d audio", "reverb", "full movie", "podcast"]

    static let log = Logger(subsystem: "com.agraabhi.ganabajana", category: "Recommendations")

    let catalog: any MusicCatalogProviding
    let now: @Sendable () -> Date

    init(catalog: any MusicCatalogProviding, now: @escaping @Sendable () -> Date = { Date() }) {
        self.catalog = catalog
        self.now = now
    }

    // MARK: Period keys

    /// ISO-8601 week key such as "2026-W38"; weeks start on Monday regardless of the user's first weekday.
    static func weekKey(for date: Date, calendar: Calendar) -> String {
        var iso = Calendar(identifier: .iso8601)
        iso.timeZone = calendar.timeZone
        let components = iso.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return String(format: "%04d-W%02d", components.yearForWeekOfYear ?? 0, components.weekOfYear ?? 0)
    }

    static func dayKey(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    // MARK: Playlists

    func discoverWeekly(profile: TasteProfile, languages: Set<MusicLanguage>, periodKey: String,
                        languageProfile: ListeningLanguageProfile? = nil,
                        familiarity: DiscoveryFamiliarity = .balanced) async throws -> GeneratedPlaylist? {
        var balance = DiscoveryBalanceMetrics()
        defer { balance.emit(mode: familiarity, scope: .discoverWeekly) }
        do {
            try Task.checkCancellation()
            guard !profile.isColdStart else { return nil }
            let scope: Set<MusicLanguage> = languageProfile == nil ? languages : []
            let seeds = Seeds(profile: profile, languageProfile: languageProfile)
            let harvest = try await gather(seeds: seeds, languages: scope, profile: profile, languageProfile: languageProfile)
            let familiarArtists = Set(profile.topArtists(limit: 10).map { TasteProfile.normalizedArtistName($0.name) })
            // Weekly stays unheard; known-artist multipliers are 1.0 / 0.55 / 0.25, never a hard artist exclusion.
            let artistMultiplier: Double = switch familiarity {
            case .familiar: 1
            case .balanced: Self.knownArtistPenalty
            case .newMusic: 0.25
            }
            let ranked = harvest.candidates.values.filter { candidate in
                !profile.heardTrackIDs.contains(candidate.track.id) && !profile.dislikedTrackIDs.contains(candidate.track.id)
                    && Self.isRecommendable(candidate.track, languages: scope)
            }.map { candidate -> Candidate in
                var candidate = candidate.weighted(by: languageProfile)
                if candidate.track.artists.contains(where: { familiarArtists.contains(TasteProfile.normalizedArtistName($0)) }) {
                    candidate.score *= artistMultiplier
                }
                candidate.score += Self.jitter(periodKey: periodKey, id: candidate.track.id) * Self.jitterRange
                return candidate
            }.sorted(by: Candidate.ranks)
            let picks = Self.select(ranked.map(\.track), limit: Self.discoverWeeklyTarget, artistCap: Self.discoverWeeklyArtistCap)
            try Task.checkCancellation()
            guard picks.count >= Self.minimumPlaylistSize else { return nil }
            balance.record(picks, profile: profile)
            return GeneratedPlaylist(kind: .discoverWeekly, tracks: picks, generatedAt: now(), periodKey: periodKey,
                                     seedArtists: harvest.seedArtistNames)
        } catch {
            balance.record(error: error)
            throw error
        }
    }

    func dailyMix(profile: TasteProfile, languages: Set<MusicLanguage>, periodKey: String,
                  languageProfile: ListeningLanguageProfile? = nil,
                  familiarity: DiscoveryFamiliarity = .balanced) async throws -> GeneratedPlaylist? {
        var balance = DiscoveryBalanceMetrics()
        defer { balance.emit(mode: familiarity, scope: .dailyMix) }
        do {
            try Task.checkCancellation()
            guard !profile.isColdStart else { return nil }
            let scope: Set<MusicLanguage> = languageProfile == nil ? languages : []
            let seeds = Seeds(profile: profile, languageProfile: languageProfile)
            let harvest = try await gather(seeds: seeds, languages: scope, profile: profile, languageProfile: languageProfile)
            let familiarShare: Double = switch familiarity {
            case .familiar: 0.7
            case .balanced: Self.dailyMixFamiliarShare
            case .newMusic: 0.15
            }
            let familiarTarget = Int((Double(Self.dailyMixTarget) * familiarShare).rounded())

            let weights = Self.trackWeights(profile, languageProfile: languageProfile)
            var familiarPool = Self.weightedShuffle(weights, periodKey: periodKey).compactMap(profile.track(id:))
                .filter { !profile.dislikedTrackIDs.contains($0.id) && Self.isRecommendable($0, languages: scope) }
            let ranked = harvest.candidates.values.filter { candidate in
                !profile.dislikedTrackIDs.contains(candidate.track.id) && Self.isRecommendable(candidate.track, languages: scope)
            }.map { candidate -> Candidate in
                var candidate = candidate.weighted(by: languageProfile)
                candidate.score += Self.jitter(periodKey: periodKey, id: candidate.track.id) * Self.jitterRange
                return candidate
            }.sorted(by: Candidate.ranks).map(\.track)
            // Provider neighbors can be heard recents without affinity; their source does not make them new.
            var seen = Set(familiarPool.map(\.id))
            familiarPool += ranked.filter { profile.heardTrackIDs.contains($0.id) && seen.insert($0.id).inserted }
            // Unscored heard recordings remain a local fallback without inventing listening affinity.
            let remainingWeights = Dictionary(uniqueKeysWithValues: profile.heardTrackIDs.subtracting(seen).compactMap { id -> (String, Double)? in
                guard let track = profile.track(id: id), !profile.dislikedTrackIDs.contains(id),
                      Self.isRecommendable(track, languages: scope) else { return nil }
                return (id, languageProfile?.multiplier(for: track) ?? 1)
            })
            familiarPool += Self.weightedShuffle(remainingWeights, periodKey: periodKey).compactMap(profile.track(id:))
            let freshPool = ranked.filter { !profile.heardTrackIDs.contains($0.id) }

            // An early familiar pick must not consume artist slots needed for an achievable unheard quota.
            let freshArtistCapacity = Dictionary(grouping: freshPool, by: Self.primaryArtistKey)
                .mapValues { min($0.count, Self.dailyMixArtistCap) }
            var freshCapacity = freshArtistCapacity.values.reduce(0, +)
            let reservedFresh = min(Self.dailyMixTarget - familiarTarget, freshCapacity)
            var artistCounts: [String: Int] = [:]
            var familiar: [Track] = []
            for track in familiarPool where familiar.count < familiarTarget {
                let artist = Self.primaryArtistKey(track)
                let used = artistCounts[artist, default: 0]
                guard used < Self.dailyMixArtistCap else { continue }
                let displacedFresh = freshArtistCapacity[artist, default: 0] >= Self.dailyMixArtistCap - used ? 1 : 0
                guard freshCapacity - displacedFresh >= reservedFresh else { continue }
                familiar.append(track)
                artistCounts[artist] = used + 1
                freshCapacity -= displacedFresh
            }
            if familiar.count < familiarTarget {
                // When both quotas cannot fit, retain familiar ranking and let shortage top-ups fill available slots.
                artistCounts.removeAll()
                familiar = Self.select(familiarPool, limit: familiarTarget, artistCap: Self.dailyMixArtistCap, counts: &artistCounts)
            }
            let fresh = Self.select(freshPool, limit: Self.dailyMixTarget - familiar.count,
                                    artistCap: Self.dailyMixArtistCap, counts: &artistCounts)

            var mix = familiar
            if mix.count + fresh.count < Self.dailyMixTarget {
                // Thin provider results are topped up with more familiar songs rather than shipping a short mix.
                let taken = Set((mix + fresh).map(\.id))
                mix += Self.select(familiarPool.filter { !taken.contains($0.id) }, limit: Self.dailyMixTarget - mix.count - fresh.count,
                                   artistCap: Self.dailyMixArtistCap, counts: &artistCounts)
            }
            let tracks = Self.interleave(familiar: mix, fresh: fresh)
            try Task.checkCancellation()
            guard tracks.count >= Self.minimumPlaylistSize else { return nil }
            balance.record(tracks, profile: profile)
            return GeneratedPlaylist(kind: .dailyMix, tracks: tracks, generatedAt: now(), periodKey: periodKey,
                                     seedArtists: harvest.seedArtistNames)
        } catch {
            balance.record(error: error)
            throw error
        }
    }

    /// "Because you like …" rows for the strongest artists that have a channel id; nothing is gated on cold start.
    func becauseYouListen(profile: TasteProfile, languages: Set<MusicLanguage>, limit: Int = 2,
                          languageProfile: ListeningLanguageProfile? = nil,
                          familiarity: DiscoveryFamiliarity = .balanced) async throws -> [DiscoverySection] {
        var balance = DiscoveryBalanceMetrics()
        defer { balance.emit(mode: familiarity, scope: .becauseYouListen) }
        do {
            try Task.checkCancellation()
            let scope: Set<MusicLanguage> = languageProfile == nil ? languages : []
            let seeds = profile.topArtists(limit: 10).compactMap { artist -> (name: String, id: String)? in
                guard let id = artist.id else { return nil }
                return (artist.name, id)
            }.prefix(max(0, min(limit, 2)))
            guard !seeds.isEmpty else { return [] }

            let catalog = self.catalog
            let results = await withTaskGroup(of: (Int, Result<DiscoverySection?, any Error>).self) { group in
                for (index, seed) in seeds.enumerated() {
                    group.addTask {
                        do {
                            try Task.checkCancellation()
                            let page = try await catalog.artist(id: seed.id)
                            try Task.checkCancellation()
                            var candidates: [String: Candidate] = [:]
                            Self.accumulate(page.topSongs, seedWeight: 1, sourceWeight: Source.seedArtist.weight, into: &candidates)
                            if let related = page.relatedArtists.first(where: { !$0.id.isEmpty && $0.id != seed.id }) {
                                do {
                                    let relatedPage = try await catalog.artist(id: related.id)
                                    try Task.checkCancellation()
                                    Self.accumulate(relatedPage.topSongs, seedWeight: 1, sourceWeight: Source.relatedArtist.weight, into: &candidates)
                                } catch {
                                    if error is CancellationError { throw error }
                                    Self.log.notice("Related artist \(related.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                                }
                            }
                            let tracks = Self.select(candidates.values.filter {
                                !profile.dislikedTrackIDs.contains($0.track.id) && Self.isRecommendable($0.track, languages: scope) }
                                .map { $0.weighted(by: languageProfile).weighted(by: familiarity, heardTrackIDs: profile.heardTrackIDs) }
                                .sorted(by: Candidate.ranks).map(\.track), limit: Self.sectionTrackLimit, artistCap: Int.max)
                            guard !tracks.isEmpty else { return (index, .success(nil)) }
                            let name = seed.name.isEmpty ? page.name : seed.name
                            return (index, .success(DiscoverySection(id: "personal.\(seed.id)", title: "Because you like \(name)",
                                language: languageProfile == nil ? profile.language(forArtist: seed.name) : nil, tracks: tracks)))
                        } catch {
                            return (index, .failure(error))
                        }
                    }
                }
                var collected: [(Int, Result<DiscoverySection?, any Error>)] = []
                for await result in group { collected.append(result) }
                return collected.sorted { $0.0 < $1.0 }
            }

            var sections: [DiscoverySection] = []
            var lastError: (any Error)?
            for (_, result) in results {
                switch result {
                case .success(let section):
                    if let section { sections.append(section) }
                case .failure(let error):
                    if error is CancellationError { throw error }
                    lastError = error
                    Self.log.notice("Personal section failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            try Task.checkCancellation()
            let allFailed = results.allSatisfy { result in
                if case .failure = result.1 { return true }
                return false
            }
            if sections.isEmpty, allFailed, let lastError { throw lastError }
            balance.record(sections.flatMap(\.tracks), profile: profile)
            return sections
        } catch {
            balance.record(error: error)
            throw error
        }
    }

    // MARK: Candidate generation

    private enum Source {
        case trackRadio, seedArtist, relatedArtist
        var weight: Double {
            switch self {
            case .trackRadio: 1.0
            case .seedArtist: 0.9
            case .relatedArtist: 0.6
            }
        }
    }

    struct Candidate: Sendable {
        var track: Track
        var score: Double
        var order: Int

        func weighted(by profile: ListeningLanguageProfile?) -> Candidate {
            var candidate = self
            candidate.score *= profile?.multiplier(for: track) ?? 1
            return candidate
        }

        func weighted(by familiarity: DiscoveryFamiliarity, heardTrackIDs: Set<String>) -> Candidate {
            let heard = heardTrackIDs.contains(track.id)
            // A 1.5× boost keeps both pools eligible and composes with the independent language multiplier.
            let multiplier: Double = switch familiarity {
            case .familiar: heard ? 1.5 : 1
            case .balanced: 1
            case .newMusic: heard ? 1 : 1.5
            }
            var candidate = self
            candidate.score *= multiplier
            return candidate
        }

        static func ranks(_ left: Candidate, _ right: Candidate) -> Bool {
            if left.score != right.score { return left.score > right.score }
            if left.order != right.order { return left.order < right.order }
            return left.track.id < right.track.id
        }
    }

    private struct Seeds {
        struct Artist { var name: String; var id: String; var weight: Double }
        var tracks: [(track: Track, weight: Double)]
        var artists: [Artist]

        // Seed weights are normalized within each pool so the fixed jitter band stays meaningful.
        init(profile: TasteProfile, languageProfile: ListeningLanguageProfile?) {
            let weights = RecommendationEngine.trackWeights(profile, languageProfile: languageProfile)
            let topTracks = Self.selectTracks(profile: profile, languageProfile: languageProfile, weights: weights)
            let trackMax = topTracks.map { weights[$0.id] ?? 0 }.max() ?? 0
            tracks = topTracks.map { ($0, trackMax > 0 ? (weights[$0.id] ?? 0) / trackMax : 1) }
            let topArtists = profile.topArtists(limit: 10).compactMap { artist -> Artist? in
                guard let id = artist.id, !id.isEmpty else { return nil }
                return Artist(name: artist.name, id: id, weight: artist.weight)
            }.prefix(RecommendationEngine.seedArtistCount)
            let artistMax = topArtists.map(\.weight).max() ?? 0
            artists = topArtists.map { Artist(name: $0.name, id: $0.id, weight: artistMax > 0 ? $0.weight / artistMax : 1) }
        }

        private static func selectTracks(profile: TasteProfile, languageProfile: ListeningLanguageProfile?,
                                         weights: [String: Double]) -> [Track] {
            let limit = RecommendationEngine.seedTrackCount
            guard let languageProfile else { return profile.topTracks(limit: limit) }
            let ranked = profile.topTracks(limit: profile.trackAffinity.count).filter {
                !profile.dislikedTrackIDs.contains($0.id) && RecommendationEngine.isRecommendable($0, languages: [])
            }.sorted {
                let left = weights[$0.id] ?? 0
                let right = weights[$1.id] ?? 0
                return left == right ? $0.id < $1.id : left > right
            }
            var selected: [Track] = []
            var ids = Set<String>()
            for language in languageProfile.scheduledLanguages(count: limit).prefix(limit) {
                if let track = ranked.first(where: { !ids.contains($0.id) && languageProfile.language(for: $0) == language }) {
                    selected.append(track)
                    ids.insert(track.id)
                }
            }
            // A small seed budget still leaves one opening for a less frequent known language.
            let represented = Set(selected.compactMap { languageProfile.language(for: $0) })
            if let language = languageProfile.orderedLanguages.first(where: { language in
                !represented.contains(language) && ranked.contains { languageProfile.language(for: $0) == language }
            }), let track = ranked.first(where: { languageProfile.language(for: $0) == language }) {
                if selected.count == limit { ids.remove(selected.removeLast().id) }
                selected.append(track)
                ids.insert(track.id)
            }
            for track in ranked where selected.count < limit && ids.insert(track.id).inserted { selected.append(track) }
            return selected
        }
    }

    private struct Harvest {
        var candidates: [String: Candidate] = [:]
        var seedArtistNames: [String] = []
    }

    private enum Fetch: Sendable {
        case radio(seed: Track, weight: Double, tracks: [Track])
        case artist(seed: Seeds.Artist, page: ArtistPage)
        case related(seedWeight: Double, page: ArtistPage)
        case failure(any Error)
    }

    private func gather(seeds: Seeds, languages: Set<MusicLanguage>, profile: TasteProfile,
                        languageProfile: ListeningLanguageProfile?) async throws -> Harvest {
        try Task.checkCancellation()
        let catalog = self.catalog
        let fallbackLanguage = Self.preferredLanguage(languages, profile: profile)
        var harvest = Harvest()
        var usedArtists: [(name: String, weight: Double)] = []
        var fetchedArtistIDs = Set(seeds.artists.map(\.id))
        var pages: [(seed: Seeds.Artist, page: ArtistPage)] = []

        // Results are processed in seed order, not completion order, so tie-breaks and fan-out are reproducible.
        let first = await withTaskGroup(of: (Int, Fetch).self) { group in
            for (index, seed) in seeds.tracks.enumerated() {
                group.addTask {
                    do {
                        try Task.checkCancellation()
                        let tracks: [Track]
                        if languageProfile != nil { tracks = try await catalog.radio(seed: seed.track) }
                        else { tracks = try await catalog.recommendations(seed: seed.track, language: seed.track.language ?? fallbackLanguage) }
                        try Task.checkCancellation()
                        return (index, .radio(seed: seed.track, weight: seed.weight, tracks: tracks))
                    } catch { return (index, .failure(error)) }
                }
            }
            for (offset, seed) in seeds.artists.enumerated() {
                let index = seeds.tracks.count + offset
                group.addTask {
                    do {
                        try Task.checkCancellation()
                        return (index, .artist(seed: seed, page: try await catalog.artist(id: seed.id)))
                    } catch { return (index, .failure(error)) }
                }
            }
            return await Self.ordered(&group)
        }
        try Self.checkFailures(first)

        for result in first {
            switch result {
            case .radio(let seed, let weight, let tracks):
                Self.accumulate(tracks.filter { $0.id != seed.id }, seedWeight: weight, sourceWeight: Source.trackRadio.weight, into: &harvest.candidates)
                if let name = seed.artists.first {
                    usedArtists.append((name, profile.artistAffinity[TasteProfile.normalizedArtistName(name)] ?? 0))
                }
            case .artist(let seed, let page):
                Self.accumulate(page.topSongs, seedWeight: seed.weight, sourceWeight: Source.seedArtist.weight, into: &harvest.candidates)
                usedArtists.append((seed.name, profile.artistAffinity[TasteProfile.normalizedArtistName(seed.name)] ?? 0))
                pages.append((seed, page))
            case .related, .failure:
                break
            }
        }

        // Round-robin over each seed's related artists so one seed cannot consume the whole fan-out cap.
        var related: [(id: String, weight: Double)] = []
        let limit = min(Self.relatedArtistFetchCap, Self.providerCallBudget - seeds.tracks.count - seeds.artists.count)
        for rank in 0..<Self.relatedArtistsPerSeed {
            for (seed, page) in pages where related.count < limit {
                let options = page.relatedArtists.filter { !$0.id.isEmpty }
                guard options.indices.contains(rank), fetchedArtistIDs.insert(options[rank].id).inserted else { continue }
                related.append((options[rank].id, seed.weight))
            }
        }

        if !related.isEmpty {
            let second = await withTaskGroup(of: (Int, Fetch).self) { group in
                for (index, item) in related.enumerated() {
                    group.addTask {
                        do {
                            try Task.checkCancellation()
                            return (index, .related(seedWeight: item.weight, page: try await catalog.artist(id: item.id)))
                        } catch { return (index, .failure(error)) }
                    }
                }
                return await Self.ordered(&group)
            }
            for result in second {
                switch result {
                case .related(let weight, let page):
                    Self.accumulate(page.topSongs, seedWeight: weight, sourceWeight: Source.relatedArtist.weight, into: &harvest.candidates)
                case .failure(let error):
                    if error is CancellationError { throw error }
                    Self.log.notice("Related artist fetch failed: \(error.localizedDescription, privacy: .public)")
                case .radio, .artist:
                    break
                }
            }
        }
        try Task.checkCancellation()

        var seen = Set<String>()
        harvest.seedArtistNames = usedArtists.sorted { left, right in
            if left.weight != right.weight { return left.weight > right.weight }
            return left.name < right.name
        }.filter { seen.insert(TasteProfile.normalizedArtistName($0.name)).inserted }.prefix(3).map(\.name)
        return harvest
    }

    private static func ordered(_ group: inout TaskGroup<(Int, Fetch)>) async -> [Fetch] {
        var results: [(Int, Fetch)] = []
        for await result in group { results.append(result) }
        return results.sorted { $0.0 < $1.0 }.map(\.1)
    }

    private static func checkFailures(_ results: [Fetch]) throws {
        var lastError: (any Error)?
        var succeeded = false
        for result in results {
            if case .failure(let error) = result {
                if error is CancellationError { throw error }
                lastError = error
                log.notice("Seed fetch failed: \(error.localizedDescription, privacy: .public)")
            } else {
                succeeded = true
            }
        }
        try Task.checkCancellation()
        if !succeeded, let lastError { throw lastError }
    }

    private static func accumulate(_ tracks: [Track], seedWeight: Double, sourceWeight: Double, into candidates: inout [String: Candidate]) {
        var creditedHere = Set<String>()
        for track in tracks where !track.id.isEmpty && creditedHere.insert(track.id).inserted {
            let contribution = seedWeight * sourceWeight
            if var existing = candidates[track.id] {
                existing.score += contribution
                existing.track = merge(existing.track, with: track)
                candidates[track.id] = existing
            } else {
                candidates[track.id] = Candidate(track: track, score: contribution, order: candidates.count)
            }
        }
    }

    /// Fills metadata gaps from a second sighting of the same recording without changing its identity.
    private static func merge(_ base: Track, with other: Track) -> Track {
        var track = base
        track.duration = track.duration ?? other.duration
        track.language = track.language ?? other.language
        track.artworkURL = track.artworkURL ?? other.artworkURL
        track.isAudioRecording = track.isAudioRecording ?? other.isAudioRecording
        track.adoptMissingMetadata(from: other)
        return track
    }

    struct DiscoveryBalanceMetrics {
        enum Scope: String {
            case discoverWeekly = "discover_weekly"
            case dailyMix = "daily_mix"
            case becauseYouListen = "because_you_listen"
            case languageDiscovery = "language_discovery"
        }

        private enum Outcome { case success, empty, failure, cancelled }
        private var outcome = Outcome.empty
        private var familiarCount = 0
        private var newCount = 0
        var success: Int { outcome == .success ? 1 : 0 }
        var empty: Int { outcome == .empty ? 1 : 0 }
        var failure: Int { outcome == .failure ? 1 : 0 }
        var cancelled: Int { outcome == .cancelled ? 1 : 0 }

        mutating func record(_ tracks: [Track], profile: TasteProfile) {
            familiarCount = tracks.filter { profile.heardTrackIDs.contains($0.id) }.count
            newCount = tracks.count - familiarCount
            outcome = tracks.isEmpty ? .empty : .success
        }

        mutating func record(error: any Error) {
            outcome = error is CancellationError || Task.isCancelled ? .cancelled : .failure
        }

        func emit(mode: DiscoveryFamiliarity, scope: Scope) {
            let modeName = switch mode {
            case .familiar: "familiar"
            case .balanced: "balanced"
            case .newMusic: "newMusic"
            }
            RecommendationEngine.log.info("event=discovery_balance mode=\(modeName, privacy: .public) scope=\(scope.rawValue, privacy: .public) familiarCount=\(familiarCount) newCount=\(newCount) success=\(success) empty=\(empty) failure=\(failure) cancelled=\(cancelled)")
        }
    }

    // MARK: Filtering and ordering

    private static func trackWeights(_ profile: TasteProfile, languageProfile: ListeningLanguageProfile?) -> [String: Double] {
        guard let languageProfile else { return profile.trackAffinity }
        return Dictionary(uniqueKeysWithValues: profile.trackAffinity.map { id, weight in
            (id, weight * (profile.track(id: id).map { languageProfile.multiplier(for: $0) } ?? 1))
        })
    }

    static func isRecommendable(_ track: Track, languages: Set<MusicLanguage>) -> Bool {
        guard track.isAudioRecording != false, !track.id.isEmpty else { return false }
        if let duration = track.duration, !durationRange.contains(duration) { return false }
        if let language = track.language, !languages.isEmpty, !languages.contains(language) { return false }
        let title = track.title.lowercased()
        return !excludedVersions.contains(where: title.contains)
    }

    static func preferredLanguage(_ languages: Set<MusicLanguage>, profile: TasteProfile) -> MusicLanguage {
        let ordered = MusicLanguage.allCases.filter(languages.contains)
        if let dominant = profile.dominantLanguage, ordered.contains(dominant) { return dominant }
        return ordered.first ?? profile.dominantLanguage ?? .hindi
    }

    static func primaryArtistKey(_ track: Track) -> String {
        guard let name = track.artists.first, !TasteProfile.normalizedArtistName(name).isEmpty else { return "track:\(track.id)" }
        return TasteProfile.normalizedArtistName(name)
    }

    static func select(_ tracks: [Track], limit: Int, artistCap: Int) -> [Track] {
        var counts: [String: Int] = [:]
        return select(tracks, limit: limit, artistCap: artistCap, counts: &counts)
    }

    static func select(_ tracks: [Track], limit: Int, artistCap: Int, counts: inout [String: Int]) -> [Track] {
        var picks: [Track] = []
        var seen = Set<String>()
        for track in tracks where picks.count < limit {
            let key = primaryArtistKey(track)
            guard !seen.contains(track.id), counts[key, default: 0] < artistCap else { continue }
            seen.insert(track.id)
            counts[key, default: 0] += 1
            picks.append(track)
        }
        return picks
    }

    /// Spreads familiar songs evenly through the mix so the listener never gets a long run of either kind.
    static func interleave(familiar: [Track], fresh: [Track]) -> [Track] {
        let total = familiar.count + fresh.count
        guard total > 0 else { return [] }
        var result: [Track] = []
        var familiarIndex = 0
        var freshIndex = 0
        for position in 0..<total {
            let familiarDue = (position + 1) * familiar.count / total > position * familiar.count / total
            if (familiarDue && familiarIndex < familiar.count) || freshIndex >= fresh.count {
                result.append(familiar[familiarIndex])
                familiarIndex += 1
            } else {
                result.append(fresh[freshIndex])
                freshIndex += 1
            }
        }
        return result
    }

    /// Weighted sampling without replacement (Efraimidis–Spirakis), seeded by the period so a day's order is stable.
    static func weightedShuffle(_ weights: [String: Double], periodKey: String) -> [String] {
        let maximum = weights.values.max() ?? 0
        guard maximum > 0 else { return [] }
        return weights.compactMap { id, weight -> (id: String, key: Double)? in
            guard weight > 0 else { return nil }
            return (id, pow(jitter(periodKey: periodKey, id: id), maximum / weight))
        }.sorted {
            if $0.key != $1.key { return $0.key > $1.key }
            return $0.id < $1.id
        }.map(\.id)
    }

    /// Deterministic unit-interval value in (0, 1) from FNV-1a; Swift's Hasher is randomly seeded per launch.
    static func jitter(periodKey: String, id: String) -> Double {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in (periodKey + "|" + id).utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return (Double(hash >> 11) + 0.5) / Double(UInt64(1) << 53)
    }
}

import Foundation
import OSLog

/// One generated mix's slice of taste. Daily Mixes use one scope per `TasteCluster`; a moment mix (R14 item 21)
/// supplies its own filter and weighting and reuses the same seeding, budget and Daily Mix selection rules.
struct MixScope: Sendable {
    var kind: GeneratedPlaylistKind
    var focus: String?
    /// Normalized artist keys that own this scope; empty means the whole profile (an open scope).
    var artistKeys: [String] = []
    /// Heard recordings owned by this scope, strongest first; empty falls back to artist ownership.
    var trackIDs: [String] = []
    /// Hard filter applied to heard recordings and provider candidates.
    var includes: @Sendable (Track) -> Bool = { _ in true }
    /// Soft multiplier on familiar weights and candidate scores; non-positive values drop the recording.
    var weight: @Sendable (Track) -> Double = { _ in 1 }

    init(kind: GeneratedPlaylistKind, focus: String? = nil, artistKeys: [String] = [], trackIDs: [String] = [],
         includes: @escaping @Sendable (Track) -> Bool = { _ in true },
         weight: @escaping @Sendable (Track) -> Double = { _ in 1 }) {
        self.kind = kind
        self.focus = focus
        self.artistKeys = artistKeys
        self.trackIDs = trackIDs
        self.includes = includes
        self.weight = weight
    }

    init(kind: GeneratedPlaylistKind, cluster: TasteCluster) {
        self.init(kind: kind, focus: cluster.focus.isEmpty ? nil : cluster.focus,
                  artistKeys: cluster.artistKeys, trackIDs: cluster.trackIDs)
    }

    var isOpen: Bool { artistKeys.isEmpty && trackIDs.isEmpty }
}

extension RecommendationEngine {
    static let discoveryLog = Logger(subsystem: "com.agraabhi.ganabajana", category: "Discovery")

    // MARK: Daily Mixes

    /// Daily Mix 1 to 3 for one period, each from a distinct taste cluster and sharing the single-mix provider
    /// budget. Fewer than two clusters produce today's single Daily Mix as Daily Mix 1.
    func dailyMixes(profile: TasteProfile, periodKey: String,
                    languageProfile: ListeningLanguageProfile? = nil,
                    familiarity: DiscoveryFamiliarity = .balanced,
                    genreProfile: ListeningGenreProfile? = nil,
                    followedArtistKeys: Set<String> = []) async throws -> [GeneratedPlaylist] {
        try Task.checkCancellation()
        guard !profile.isColdStart else { return [] }
        let clusters = TasteClustering.clusters(.init(profile: profile, languageProfile: languageProfile,
                                                      genreProfile: genreProfile, followedArtistKeys: followedArtistKeys))
        guard clusters.count >= 2 else {
            let single = try await dailyMix(profile: profile, languages: [], periodKey: periodKey,
                                            languageProfile: languageProfile, familiarity: familiarity, genreProfile: genreProfile)
            Self.logDailyMixes(clusters: single == nil ? 0 : 1, mixes: single.map { [$0] } ?? [])
            return single.map { [$0] } ?? []
        }
        let scopes = zip(GeneratedPlaylistKind.dailyMixes, clusters).map { MixScope(kind: $0, cluster: $1) }
        var mixes = try await scopedMixes(profile: profile, scopes: scopes, periodKey: periodKey,
                                          languageProfile: languageProfile, familiarity: familiarity,
                                          genreProfile: genreProfile, fallbackKind: .dailyMix)
        // Kinds stay contiguous so a missing middle cluster never leaves a gap between Daily Mix 1 and 3.
        for index in mixes.indices { mixes[index].kind = GeneratedPlaylistKind.dailyMixes[index] }
        Self.logDailyMixes(clusters: mixes.count, mixes: mixes)
        return mixes
    }

    private static func logDailyMixes(clusters: Int, mixes: [GeneratedPlaylist]) {
        discoveryLog.info("event=daily_mixes clusters=\(clusters) tracks=\(mixes.reduce(0) { $0 + $1.tracks.count })")
    }

    /// Builds one mix per scope from a single shared harvest (at most `providerCallBudget` calls). A recording
    /// appears in at most one returned mix; earlier scopes pick first. When fewer than two scopes reach
    /// `minimumPlaylistSize` and `fallbackKind` is set, the result is one open-scope mix from the same harvest.
    func scopedMixes(profile: TasteProfile, scopes: [MixScope], periodKey: String,
                     languageProfile: ListeningLanguageProfile? = nil,
                     familiarity: DiscoveryFamiliarity = .balanced,
                     genreProfile: ListeningGenreProfile? = nil,
                     fallbackKind: GeneratedPlaylistKind? = nil) async throws -> [GeneratedPlaylist] {
        var balance = DiscoveryBalanceMetrics()
        defer { balance.emit(mode: familiarity, scope: .dailyMix) }
        do {
            try Task.checkCancellation()
            guard !profile.isColdStart, !scopes.isEmpty else { return [] }
            let ownership = MixOwnership(scopes: scopes)
            let seeds = Self.scopedSeeds(profile: profile, scopes: scopes, ownership: ownership, languageProfile: languageProfile,
                                         periodKey: periodKey)
            let harvest = try await gather(seeds: seeds, languages: [], profile: profile, languageProfile: languageProfile)
            SkipSignalMetrics.mix(candidates: Array(harvest.candidates.values), profile: profile, languages: []).emit(.dailyMix)
            let baseWeights = Self.trackWeights(profile, languageProfile: languageProfile)

            var attributed: [Int: [Candidate]] = [:]
            for candidate in harvest.candidates.values {
                let index = ownership.owner(of: candidate.track) ?? ownership.provenance(of: candidate.track.id, in: harvest)
                guard let index, scopes.indices.contains(index) else { continue }
                attributed[index, default: []].append(candidate)
            }

            var used = Set<String>()
            var mixes: [GeneratedPlaylist] = []
            for (index, scope) in scopes.enumerated() {
                let candidates = (attributed[index] ?? []).compactMap { candidate -> Candidate? in
                    guard !used.contains(candidate.track.id), scope.includes(candidate.track) else { return nil }
                    let multiplier = scope.weight(candidate.track)
                    guard multiplier.isFinite, multiplier > 0 else { return nil }
                    var candidate = candidate
                    candidate.score *= multiplier
                    return candidate
                }
                let ranked = Self.rankedMixCandidates(candidates, profile: profile, languages: [], languageProfile: languageProfile,
                                                      genreProfile: genreProfile, periodKey: periodKey)
                let belongs: (Track) -> Bool = { track in
                    ownership.ownsHeard(track, scope: index) && scope.includes(track)
                }
                let weights = baseWeights.compactMap { id, weight -> (String, Double)? in
                    guard !used.contains(id), let track = profile.track(id: id), belongs(track) else { return nil }
                    let multiplier = scope.weight(track)
                    guard multiplier.isFinite, multiplier > 0 else { return nil }
                    return (id, weight * multiplier)
                }
                let tracks = Self.composeDailyMix(ranked: ranked, familiarWeights: Dictionary(uniqueKeysWithValues: weights),
                                                  profile: profile, languages: [], languageProfile: languageProfile,
                                                  familiarity: familiarity, periodKey: periodKey,
                                                  belongs: belongs, excluded: used)
                guard tracks.count >= Self.minimumPlaylistSize else { continue }
                used.formUnion(tracks.map(\.id))
                mixes.append(GeneratedPlaylist(kind: scope.kind, tracks: tracks, generatedAt: now(), periodKey: periodKey,
                                               seedArtists: harvest.scopedSeedArtists[index] ?? [], focus: scope.focus))
            }
            try Task.checkCancellation()
            if mixes.count < 2, let fallbackKind, !(scopes.count == 1 && scopes[0].isOpen) {
                // Too little separation for distinct mixes: one mix over the whole profile, not near-duplicates.
                let ranked = Self.rankedMixCandidates(Array(harvest.candidates.values), profile: profile, languages: [],
                                                      languageProfile: languageProfile, genreProfile: genreProfile, periodKey: periodKey)
                let tracks = Self.composeDailyMix(ranked: ranked, familiarWeights: baseWeights, profile: profile, languages: [],
                                                  languageProfile: languageProfile, familiarity: familiarity, periodKey: periodKey)
                mixes = tracks.count >= Self.minimumPlaylistSize
                    ? [GeneratedPlaylist(kind: fallbackKind, tracks: tracks, generatedAt: now(), periodKey: periodKey,
                                         seedArtists: harvest.seedArtistNames)]
                    : []
            }
            balance.record(mixes.flatMap(\.tracks), profile: profile)
            return mixes
        } catch {
            balance.record(error: error)
            throw error
        }
    }

    /// Ownership of recordings and artists across scopes; closed scopes partition, an open scope takes the rest.
    struct MixOwnership: Sendable {
        private let heard: [String: Int]
        private let artists: [String: Int]
        private let open: Int?

        init(scopes: [MixScope]) {
            var heard: [String: Int] = [:]
            var artists: [String: Int] = [:]
            for (index, scope) in scopes.enumerated() {
                for id in scope.trackIDs where heard[id] == nil { heard[id] = index }
                for key in scope.artistKeys where artists[key] == nil { artists[key] = index }
            }
            self.heard = heard
            self.artists = artists
            open = scopes.firstIndex(where: \.isOpen)
        }

        func owner(of track: Track) -> Int? {
            if let index = heard[track.id] { return index }
            for name in track.artists {
                if let index = artists[TasteProfile.normalizedArtistName(name)] { return index }
            }
            return open
        }

        func ownsHeard(_ track: Track, scope: Int) -> Bool { owner(of: track) == scope }

        /// A candidate by an artist outside every scope goes to the scope whose seeds scored it highest.
        func provenance(of id: String, in harvest: Harvest) -> Int? {
            var best: (scope: Int, score: Double)?
            for (scope, candidates) in harvest.scoped {
                guard let score = candidates[id]?.score else { continue }
                if let current = best, current.score > score || (current.score == score && current.scope < scope) { continue }
                best = (scope, score)
            }
            return best?.scope
        }
    }

    /// Splits the single-mix seed budget (four recordings, three artists) across scopes, strongest scope first.
    /// The period's super like takes the weakest seed of the scope that owns it, so no other scope loses a seed.
    static func scopedSeeds(profile: TasteProfile, scopes: [MixScope], ownership: MixOwnership,
                            languageProfile: ListeningLanguageProfile?, periodKey: String) -> Seeds {
        let weights = trackWeights(profile, languageProfile: languageProfile)
        let ranked = profile.topTracks(limit: profile.trackAffinity.count).filter {
            !profile.dislikedTrackIDs.contains($0.id) && !profile.isResting($0) && isRecommendable($0, languages: [])
        }
        func scoped(_ track: Track, in index: Int) -> (Track, Double)? {
            guard ownership.ownsHeard(track, scope: index), scopes[index].includes(track) else { return nil }
            let multiplier = scopes[index].weight(track)
            guard multiplier.isFinite, multiplier > 0 else { return nil }
            return (track, (weights[track.id] ?? 0) * multiplier)
        }
        var trackPools: [[(Track, Double)]] = scopes.indices.map { index in
            ranked.compactMap { scoped($0, in: index) }.sorted { $0.1 == $1.1 ? $0.0.id < $1.0.id : $0.1 > $1.1 }
        }
        let artistsByKey = Dictionary(profile.topArtists(limit: profile.artistAffinity.count).compactMap { artist -> (String, Seeds.Artist)? in
            guard let id = artist.id, !id.isEmpty else { return nil }
            return (TasteProfile.normalizedArtistName(artist.name), Seeds.Artist(name: artist.name, id: id, weight: artist.weight))
        }, uniquingKeysWith: { first, _ in first })
        let topKeys = profile.topArtists(limit: 10).map { TasteProfile.normalizedArtistName($0.name) }
        var artistPools: [[Seeds.Artist]] = scopes.enumerated().map { index, scope in
            (scope.artistKeys.isEmpty ? topKeys : scope.artistKeys).compactMap { key in
                artistsByKey[key].map { var artist = $0; artist.scope = index; return artist }
            }
        }

        var pickedTracks = allocate(total: seedTrackCount, pools: &trackPools)
        let superLikes = eligibleSuperLikes(profile)
        let owned = superLikes.compactMap { track -> (scope: Int, item: (Track, Double))? in
            for index in scopes.indices {
                if let item = scoped(track, in: index) { return (index, item) }
            }
            return nil
        }
        let reserved = rotatingSuperLike(owned.map { $0.item.0 }, periodKey: periodKey)
        if let reserved, let seed = owned.first(where: { $0.item.0.id == reserved.id }),
           !pickedTracks.contains(where: { $0.item.0.id == reserved.id }) {
            let seedWeights = pickedTracks.map { $0.item.1 }
            if let slot = weakestSeed(pickedTracks.indices.filter { pickedTracks[$0].scope == seed.scope }, weight: { seedWeights[$0] }) {
                pickedTracks[slot] = seed
            } else {
                // A scope beyond the budget's reach still gets its super like without exceeding the seed count.
                if pickedTracks.count >= seedTrackCount, let slot = weakestSeed(pickedTracks.indices, weight: { seedWeights[$0] }) {
                    pickedTracks[slot] = seed
                } else {
                    pickedTracks.append(seed)
                }
                pickedTracks.sort { $0.scope < $1.scope }
            }
        }
        logSuperLike(scope: "seeds", reserved: reserved != nil, eligible: superLikes.count)
        let pickedArtists = allocate(total: seedArtistCount, pools: &artistPools)
        let trackMax = pickedTracks.map { $0.item.1 }.max() ?? 0
        let artistMax = pickedArtists.map { $0.item.weight }.max() ?? 0
        var seenArtistIDs = Set<String>()
        return Seeds(
            tracks: pickedTracks.map { ($0.item.0, trackMax > 0 ? $0.item.1 / trackMax : 1, $0.scope) },
            artists: pickedArtists.compactMap { picked in
                guard seenArtistIDs.insert(picked.item.id).inserted else { return nil }
                var artist = picked.item
                artist.weight = artistMax > 0 ? artist.weight / artistMax : 1
                return artist
            })
    }

    /// Even quota per scope with the remainder to the strongest; unused slots spill to later scopes in order.
    private static func allocate<Item>(total: Int, pools: inout [[Item]]) -> [(scope: Int, item: Item)] {
        guard !pools.isEmpty else { return [] }
        var picked: [(scope: Int, item: Item)] = []
        let base = total / pools.count
        let remainder = total % pools.count
        for index in pools.indices {
            let quota = base + (index < remainder ? 1 : 0)
            let taken = pools[index].prefix(quota)
            picked += taken.map { (index, $0) }
            pools[index].removeFirst(taken.count)
        }
        var index = 0
        while picked.count < total, pools.contains(where: { !$0.isEmpty }) {
            if !pools[index].isEmpty { picked.append((index, pools[index].removeFirst())) }
            index = (index + 1) % pools.count
        }
        return picked.sorted { $0.scope < $1.scope }
    }

    // MARK: Shared Daily Mix rules

    /// Dislikes, resting songs and unusable audio removed, skip discount, language and gated genre terms applied,
    /// period jitter added.
    static func rankedMixCandidates(_ candidates: [Candidate], profile: TasteProfile, languages: Set<MusicLanguage>,
                                    languageProfile: ListeningLanguageProfile?, genreProfile: ListeningGenreProfile?,
                                    periodKey: String) -> [Track] {
        applyingGenres(candidates.filter { candidate in
            !profile.dislikedTrackIDs.contains(candidate.track.id) && !profile.isResting(candidate.track)
                && isRecommendable(candidate.track, languages: languages)
        }.map { $0.weighted(by: languageProfile).weighted(bySkips: profile) }, profile: genreProfile, mix: true).map { candidate -> Candidate in
            var candidate = candidate
            candidate.score += jitter(periodKey: periodKey, id: candidate.track.id) * jitterRange
            return candidate
        }.sorted(by: Candidate.ranks).map(\.track)
    }

    /// The Daily Mix familiarity balance, heard/unheard split, artist caps and shortage top-ups over one pool.
    static func composeDailyMix(ranked: [Track], familiarWeights: [String: Double], profile: TasteProfile,
                                languages: Set<MusicLanguage>, languageProfile: ListeningLanguageProfile?,
                                familiarity: DiscoveryFamiliarity, periodKey: String,
                                belongs: (Track) -> Bool = { _ in true }, excluded: Set<String> = []) -> [Track] {
        let familiarShare: Double = switch familiarity {
        case .familiar: 0.7
        case .balanced: dailyMixFamiliarShare
        case .newMusic: 0.15
        }
        let familiarTarget = Int((Double(dailyMixTarget) * familiarShare).rounded())
        let ranked = ranked.filter { !excluded.contains($0.id) && !profile.isResting($0) }

        var familiarPool = weightedShuffle(familiarWeights, periodKey: periodKey).compactMap(profile.track(id:))
            .filter { !profile.dislikedTrackIDs.contains($0.id) && !profile.isResting($0) && isRecommendable($0, languages: languages)
                && !excluded.contains($0.id) && belongs($0) }
        // Provider neighbors can be heard recents without affinity; their source does not make them new.
        var seen = Set(familiarPool.map(\.id))
        familiarPool += ranked.filter { profile.heardTrackIDs.contains($0.id) && seen.insert($0.id).inserted }
        // Unscored heard recordings remain a local fallback without inventing listening affinity.
        let remainingWeights = Dictionary(uniqueKeysWithValues: profile.heardTrackIDs.subtracting(seen).subtracting(excluded)
            .compactMap { id -> (String, Double)? in
                guard let track = profile.track(id: id), !profile.dislikedTrackIDs.contains(id), !profile.isResting(track),
                      isRecommendable(track, languages: languages), belongs(track) else { return nil }
                return (id, languageProfile?.multiplier(for: track) ?? 1)
            })
        familiarPool += weightedShuffle(remainingWeights, periodKey: periodKey).compactMap(profile.track(id:))
        // The day's super like leads the pool but still competes for the familiar share under the artist cap.
        let superLikes = eligibleSuperLikes(profile)
        let leading = rotatingSuperLike(familiarPool.filter { profile.superLikedTrackIDs.contains($0.id) && belongs($0) },
                                        periodKey: periodKey)
        if let leading, let index = familiarPool.firstIndex(where: { $0.id == leading.id }) {
            let track = familiarPool.remove(at: index)
            familiarPool.insert(track, at: 0)
        }
        logSuperLike(scope: "daily", reserved: leading != nil, eligible: superLikes.count)
        let freshPool = ranked.filter { !profile.heardTrackIDs.contains($0.id) }

        // An early familiar pick must not consume artist slots needed for an achievable unheard quota.
        let freshArtistCapacity = Dictionary(grouping: freshPool, by: primaryArtistKey)
            .mapValues { min($0.count, dailyMixArtistCap) }
        var freshCapacity = freshArtistCapacity.values.reduce(0, +)
        let reservedFresh = min(dailyMixTarget - familiarTarget, freshCapacity)
        var artistCounts: [String: Int] = [:]
        var familiar: [Track] = []
        for track in familiarPool where familiar.count < familiarTarget {
            let artist = primaryArtistKey(track)
            let used = artistCounts[artist, default: 0]
            guard used < dailyMixArtistCap else { continue }
            let displacedFresh = freshArtistCapacity[artist, default: 0] >= dailyMixArtistCap - used ? 1 : 0
            guard freshCapacity - displacedFresh >= reservedFresh else { continue }
            familiar.append(track)
            artistCounts[artist] = used + 1
            freshCapacity -= displacedFresh
        }
        if familiar.count < familiarTarget {
            // When both quotas cannot fit, retain familiar ranking and let shortage top-ups fill available slots.
            artistCounts.removeAll()
            familiar = select(familiarPool, limit: familiarTarget, artistCap: dailyMixArtistCap, counts: &artistCounts)
        }
        let fresh = select(freshPool, limit: dailyMixTarget - familiar.count, artistCap: dailyMixArtistCap, counts: &artistCounts)

        var mix = familiar
        if mix.count + fresh.count < dailyMixTarget {
            // Thin provider results are topped up with more familiar songs rather than shipping a short mix.
            let taken = Set((mix + fresh).map(\.id))
            mix += select(familiarPool.filter { !taken.contains($0.id) }, limit: dailyMixTarget - mix.count - fresh.count,
                          artistCap: dailyMixArtistCap, counts: &artistCounts)
        }
        return interleave(familiar: mix, fresh: fresh)
    }
}

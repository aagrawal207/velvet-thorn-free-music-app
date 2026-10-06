import Foundation

/// A group of artists the listener plays in a similar way; one Daily Mix, or a later moment mix, draws from each.
struct TasteCluster: Equatable, Sendable {
    /// Normalized artist keys, strongest first.
    var artistKeys: [String]
    var displayNames: [String]
    var weight: Double
    /// Heard recordings whose strongest credited artist belongs here, strongest first.
    var trackIDs: [String]
    var dominantLanguage: String?
    var dominantFamily: GenreFamily?
    /// Share of the cluster's classified weight in `dominantFamily`, 0 without genre evidence.
    var familyShare: Double
    /// Share of the cluster's weight that carries genre evidence.
    var genreCoverage: Double
    var focus: String

    func containsArtist(_ key: String) -> Bool { artistKeys.contains(key) }
}

/// Pure clustering over a `TasteProfile`; bounded by `candidateArtistLimit` artists and `TasteProfile.maximumSessions`.
enum TasteClustering {
    static let maximumClusters = 3
    static let candidateArtistLimit = 24
    static let seedClusterLimit = 6
    static let joinThreshold = 0.5
    /// Two clusters whose shared recordings exceed half the smaller one's weight are one taste.
    static let mergeSharedWeight = 0.5
    static let minimumWeightShare = 0.15
    static let minimumClusterTracks = 4
    static let followBoost = 60.0
    static let genreFocusShare = 0.6
    static let genreFocusCoverage = 0.5
    static let genreFeatureWeight = 0.4
    static let languageFeatureWeight = 0.3
    static let sessionFeatureWeight = 0.3

    struct Input: Sendable {
        var profile: TasteProfile
        var languageProfile: ListeningLanguageProfile?
        var genreProfile: ListeningGenreProfile?
        var followedArtistKeys: Set<String> = []
        /// Context weight per heard recording (a later moment mix passes its context share); must be finite and >= 0.
        var trackWeight: @Sendable (Track) -> Double = { _ in 1 }
    }

    private struct Features {
        var weight = 0.0
        var languages: [String: Double] = [:]
        var genres: [GenreFamily: Double] = [:]
        var genreWeight = 0.0
        var sessions: Set<Int> = []

        mutating func absorb(_ other: Features) {
            weight += other.weight
            languages.merge(other.languages, uniquingKeysWith: +)
            genres.merge(other.genres, uniquingKeysWith: +)
            genreWeight += other.genreWeight
            sessions.formUnion(other.sessions)
        }
    }

    private struct Group {
        var members: [String]
        var features: Features
    }

    static func languageKey(for track: Track, languageProfile: ListeningLanguageProfile?) -> String? {
        if let language = languageProfile?.language(for: track) { return language.rawValue }
        return track.language.map { $0 == .hindi ? ArtistSongLanguage.hindi.rawValue : ArtistSongLanguage.english.rawValue }
    }

    /// Up to three distinct clusters, strongest first; fewer when the history cannot support separate mixes.
    static func clusters(_ input: Input) -> [TasteCluster] {
        let profile = input.profile
        var trackWeights: [String: Double] = [:]
        var trackKeys: [String: [String]] = [:]
        for (id, affinity) in profile.trackAffinity where !profile.dislikedTrackIDs.contains(id) {
            // A resting song cannot appear in any mix, so it must not shape the taste one is built around.
            guard let track = profile.track(id: id), !profile.isResting(track),
                  RecommendationEngine.isRecommendable(track, languages: []) else { continue }
            let context = input.trackWeight(track)
            let weight = affinity * (context.isFinite ? max(0, context) : 0)
            guard weight.isFinite, weight > 0 else { continue }
            var seen = Set<String>()
            let keys = track.artists.map(TasteProfile.normalizedArtistName).filter { !$0.isEmpty && seen.insert($0).inserted }
            guard !keys.isEmpty else { continue }
            trackWeights[id] = weight
            trackKeys[id] = keys
        }

        var features: [String: Features] = [:]
        for (id, weight) in trackWeights {
            guard let track = profile.track(id: id), let keys = trackKeys[id] else { continue }
            let language = languageKey(for: track, languageProfile: input.languageProfile)
            let distribution = input.genreProfile?.distribution(for: track)
            for key in keys {
                features[key, default: Features()].weight += weight
                if let language { features[key, default: Features()].languages[language, default: 0] += weight }
                if let distribution {
                    features[key, default: Features()].genreWeight += weight
                    for share in distribution.shares {
                        features[key, default: Features()].genres[share.family, default: 0] += weight * share.share
                    }
                }
            }
        }
        for (index, session) in profile.sessionArtists.enumerated() {
            for key in session where features[key] != nil { features[key]?.sessions.insert(index) }
        }
        for key in input.followedArtistKeys where (features[key]?.weight ?? 0) > 0 {
            features[key]?.weight += followBoost
        }

        let candidates = features.filter { $0.value.weight > 0 }.sorted {
            $0.value.weight == $1.value.weight ? $0.key < $1.key : $0.value.weight > $1.value.weight
        }.prefix(candidateArtistLimit)

        var groups: [Group] = []
        for (key, artist) in candidates {
            let scored = groups.indices.map { ($0, similarity(artist, groups[$0].features)) }
            let best = scored.max { $0.1 == $1.1 ? $0.0 > $1.0 : $0.1 < $1.1 }
            if let best, best.1 >= joinThreshold || (groups.count >= seedClusterLimit && best.1 > 0) {
                groups[best.0].members.append(key)
                groups[best.0].features.absorb(artist)
            } else if groups.count < seedClusterLimit {
                groups.append(Group(members: [key], features: artist))
            }
        }

        // Each recording belongs to the group of its strongest credited artist.
        var owner: [String: Int] = [:]
        func assignOwners() {
            owner.removeAll()
            let groupOf = Dictionary(uniqueKeysWithValues: groups.enumerated().flatMap { index, group in group.members.map { ($0, index) } })
            for (id, keys) in trackKeys {
                let ranked = keys.filter { groupOf[$0] != nil }.max {
                    let left = features[$0]?.weight ?? 0
                    let right = features[$1]?.weight ?? 0
                    return left == right ? $0 > $1 : left < right
                }
                if let key = ranked, let index = groupOf[key] { owner[id] = index }
            }
        }

        var merged = true
        while merged, groups.count > 1 {
            merged = false
            let groupOf = Dictionary(uniqueKeysWithValues: groups.enumerated().flatMap { index, group in group.members.map { ($0, index) } })
            var shared: [Int: [Int: Double]] = [:]
            for (id, keys) in trackKeys {
                let touched = Set(keys.compactMap { groupOf[$0] })
                guard touched.count > 1, let weight = trackWeights[id] else { continue }
                for a in touched { for b in touched where a < b { shared[a, default: [:]][b, default: 0] += weight } }
            }
            search: for a in groups.indices {
                for b in groups.indices where b > a {
                    let smaller = min(groups[a].features.weight, groups[b].features.weight)
                    let overlap = shared[a]?[b] ?? 0
                    if (smaller > 0 && overlap > mergeSharedWeight * smaller)
                        || similarity(groups[b].features, groups[a].features) >= joinThreshold {
                        let absorbed = groups.remove(at: b)
                        groups[a].members += absorbed.members
                        groups[a].features.absorb(absorbed.features)
                        merged = true
                        break search
                    }
                }
            }
        }
        assignOwners()

        let total = groups.reduce(0) { $0 + $1.features.weight }
        guard total > 0 else { return [] }
        var built: [TasteCluster] = []
        for (index, group) in groups.enumerated() {
            let ids = owner.filter { $0.value == index }.map(\.key).sorted {
                let left = trackWeights[$0] ?? 0
                let right = trackWeights[$1] ?? 0
                return left == right ? $0 < $1 : left > right
            }
            let members = group.members.sorted {
                let left = features[$0]?.weight ?? 0
                let right = features[$1]?.weight ?? 0
                return left == right ? $0 < $1 : left > right
            }
            let family = group.features.genres.max { $0.value == $1.value ? $0.key.order > $1.key.order : $0.value < $1.value }
            let language = group.features.languages.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }
            let classified = group.features.genres.values.reduce(0, +)
            built.append(TasteCluster(
                artistKeys: members,
                displayNames: members.map { profile.displayName(forArtist: $0) ?? $0 },
                weight: group.features.weight, trackIDs: ids,
                dominantLanguage: language?.key, dominantFamily: family?.key,
                familyShare: classified > 0 ? (family?.value ?? 0) / classified : 0,
                genreCoverage: group.features.weight > 0 ? group.features.genreWeight / group.features.weight : 0,
                focus: ""))
        }
        built.sort { $0.weight == $1.weight ? ($0.artistKeys.first ?? "") < ($1.artistKeys.first ?? "") : $0.weight > $1.weight }
        let qualified = built.filter { $0.trackIDs.count >= minimumClusterTracks && $0.weight >= minimumWeightShare * total }
        var kept = Array(qualified.prefix(maximumClusters))
        if kept.count < 2, let first = built.first(where: { !$0.trackIDs.isEmpty }) { kept = [first] }
        let families = kept.compactMap { cluster -> GenreFamily? in
            guard cluster.familyShare >= genreFocusShare, cluster.genreCoverage >= genreFocusCoverage else { return nil }
            return cluster.dominantFamily
        }
        for index in kept.indices {
            let cluster = kept[index]
            if kept.count > 1, let family = cluster.dominantFamily, cluster.familyShare >= genreFocusShare,
               cluster.genreCoverage >= genreFocusCoverage, families.filter({ $0 == family }).count == 1 {
                kept[index].focus = family.title
            } else {
                kept[index].focus = GeneratedPlaylist.artistSummary(cluster.displayNames) ?? ""
            }
            while kept[index].focus.utf8.count > GeneratedPlaylist.maximumFocusBytes { kept[index].focus.removeLast() }
        }
        return kept
    }

    /// Weighted mean of the available feature overlaps (genre 0.4, language 0.3, sessions 0.3); 0 without shared features.
    private static func similarity(_ artist: Features, _ group: Features) -> Double {
        var weighted = 0.0
        var available = 0.0
        if !artist.genres.isEmpty, !group.genres.isEmpty {
            weighted += genreFeatureWeight * overlap(artist.genres, group.genres)
            available += genreFeatureWeight
        }
        if !artist.languages.isEmpty, !group.languages.isEmpty {
            weighted += languageFeatureWeight * overlap(artist.languages, group.languages)
            available += languageFeatureWeight
        }
        if !artist.sessions.isEmpty, !group.sessions.isEmpty {
            let shared = Double(artist.sessions.intersection(group.sessions).count)
            weighted += sessionFeatureWeight * shared / Double(min(artist.sessions.count, group.sessions.count))
            available += sessionFeatureWeight
        }
        return available > 0 ? weighted / available : 0
    }

    private static func overlap<Key: Hashable>(_ left: [Key: Double], _ right: [Key: Double]) -> Double {
        let leftTotal = left.values.reduce(0, +)
        let rightTotal = right.values.reduce(0, +)
        guard leftTotal > 0, rightTotal > 0 else { return 0 }
        return left.reduce(0) { sum, entry in sum + min(entry.value / leftTotal, (right[entry.key] ?? 0) / rightTotal) }
    }
}

import Foundation

/// One song across uploads, providers and versions: title core plus primary artist. "Kesariya (From Brahmastra)",
/// "Kesariya - Remix" and a `saavn:` copy of Kesariya by Arijit Singh share a key.
enum SongIdentity {
    static func key(title: String, primaryArtist: String?) -> String? {
        let core = SongTitle.core(title)
        guard !core.isEmpty, let primaryArtist else { return nil }
        let artist = TasteProfile.normalizedArtistName(primaryArtist)
        guard !artist.isEmpty else { return nil }
        return core + "|" + artist
    }

    static func key(_ track: Track) -> String? { key(title: track.title, primaryArtist: track.artists.first) }

    /// Keys for everything the profile treats as heard or disliked. Built off the main actor, at mix time.
    static func heardKeys(_ profile: TasteProfile) -> Set<String> {
        var keys = Set<String>()
        for id in profile.heardTrackIDs {
            if let track = profile.track(id: id), let key = key(track) { keys.insert(key) }
        }
        for song in profile.dislikedSongs {
            if let key = key(title: song.title, primaryArtist: song.artists.first) { keys.insert(key) }
        }
        return keys
    }
}

/// How popular a Discover Weekly candidate looks within this week's harvest, from 0 (obscure) to 1 (a hit).
/// Provider play counts are compared only within their own source; a missing count is unknown, not unpopular.
struct WeeklyPopularity {
    /// Fewer known counts than this in a source make percentiles noise, so the harvest evidence decides instead.
    static let minimumKnownCounts = 5
    static let deepCutThreshold = 0.4

    private let counts: [MusicSource: [Int64]]

    init(_ candidates: [RecommendationEngine.Candidate]) {
        var counts: [MusicSource: [Int64]] = [:]
        for candidate in candidates {
            guard let plays = candidate.track.playCount, plays > 0 else { continue }
            counts[candidate.track.source, default: []].append(plays)
        }
        self.counts = counts.filter { $0.value.count >= Self.minimumKnownCounts }.mapValues { $0.sorted() }
    }

    /// Candidates whose popularity comes from a provider count rather than harvest evidence.
    var knownCount: Int { counts.values.reduce(0) { $0 + $1.count } }

    func estimate(_ candidate: RecommendationEngine.Candidate) -> Double {
        if let plays = candidate.track.playCount, plays > 0, let sorted = counts[candidate.track.source] {
            let below = sorted.prefix { $0 < plays }.count
            let equal = sorted.dropFirst(below).prefix { $0 == plays }.count
            return (Double(below) + 0.5 * Double(equal)) / Double(sorted.count)
        }
        // An artist's top songs are its hits; a song only one radio surfaced, deep in the list, is the long tail.
        var estimate: Double
        if let position = candidate.bestTopSongsPosition {
            estimate = position < 5 ? 0.85 : position < 10 ? 0.6 : 0.45
        } else if let position = candidate.bestRadioPosition {
            estimate = position < 10 ? 0.5 : 0.3
        } else {
            estimate = 0.5
        }
        estimate += 0.15 * Double(max(0, candidate.lists - 1))
        return min(1, estimate)
    }

    func isDeepCut(_ candidate: RecommendationEngine.Candidate) -> Bool {
        estimate(candidate) <= Self.deepCutThreshold
    }
}

import Foundation

/// A snapshot of what the listener likes, derived from local history only. Pure value; rebuild it when the library changes.
struct TasteProfile: Sendable {
    static let halfLifeDays: Double = 21
    static let favoriteBoost: Double = 180
    static let playlistBoost: Double = 60
    /// A dislike counts against its artists about as much as a skipped full song counts for them.
    static let dislikePenalty: Double = 120
    static let minimumQualifyingEvents = 3
    static let minimumDistinctArtists = 2

    /// Decayed listened seconds plus favorite/playlist boosts, keyed by `normalizedArtistName`.
    private(set) var artistAffinity: [String: Double] = [:]
    /// Same scale as `artistAffinity`, keyed by track id.
    private(set) var trackAffinity: [String: Double] = [:]
    private(set) var heardTrackIDs: Set<String> = []
    /// Never recommended, never autoplayed; also excluded from `heardTrackIDs`-based familiarity picks.
    private(set) var dislikedTrackIDs: Set<String> = []
    private(set) var languageMix: [MusicLanguage: Double] = [:]
    private(set) var isColdStart = true

    private var tracks: [String: Track] = [:]
    private var artistDisplayNames: [String: String] = [:]
    private var artistIDs: [String: String] = [:]
    private var artistLanguages: [String: MusicLanguage] = [:]

    static func normalizedArtistName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping.lowercased()
    }

    static func build(events: [ListeningEvent], favorites: [Track], playlists: [UserPlaylist],
                      recents: [RecentListen], disliked: [DislikedSong] = [], now: Date) -> TasteProfile {
        var builder = Builder(now: now)
        for event in events.sorted(by: { $0.startedAt < $1.startedAt }) {
            builder.record(event)
        }
        for recent in recents.sorted(by: { $0.playedAt < $1.playedAt }) where isUsable(recent.track) {
            builder.heard.insert(recent.track.id)
            builder.tracks[recent.track.id] = recent.track
        }
        for track in favorites where isUsable(track) {
            builder.heard.insert(track.id)
            builder.credit(track, weight: favoriteBoost, keepExisting: true)
        }
        for playlist in playlists {
            for track in playlist.tracks where isUsable(track) {
                builder.heard.insert(track.id)
                builder.credit(track, weight: playlistBoost, keepExisting: true)
            }
        }
        for song in disliked where !song.id.isEmpty {
            builder.disliked.insert(song.id)
            builder.heard.insert(song.id)
            builder.trackAffinity.removeValue(forKey: song.id)
            for name in song.artists {
                let key = normalizedArtistName(name)
                guard !key.isEmpty, let current = builder.artistAffinity[key] else { continue }
                builder.artistAffinity[key] = max(0, current - dislikePenalty)
            }
        }
        return builder.finish()
    }

    /// Strongest artists first; `name` is the most-listened spelling and `id` the most common channel id seen for it.
    func topArtists(limit: Int) -> [(name: String, id: String?, weight: Double)] {
        guard limit > 0 else { return [] }
        return artistAffinity.sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            return $0.key < $1.key
        }.prefix(limit).map { (name: artistDisplayNames[$0.key] ?? $0.key, id: artistIDs[$0.key], weight: $0.value) }
    }

    /// Strongest tracks first, each as its most recently seen `Track` value.
    func topTracks(limit: Int) -> [Track] {
        guard limit > 0 else { return [] }
        return trackAffinity.sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            return $0.key < $1.key
        }.prefix(limit).compactMap { tracks[$0.key] }
    }

    func track(id: String) -> Track? { tracks[id] }

    func displayName(forArtist name: String) -> String? { artistDisplayNames[Self.normalizedArtistName(name)] }

    /// The language most of this artist's known-language listening was in, if any of it carried a language.
    func language(forArtist name: String) -> MusicLanguage? { artistLanguages[Self.normalizedArtistName(name)] }

    var dominantLanguage: MusicLanguage? {
        languageMix.max { left, right in
            if left.value != right.value { return left.value < right.value }
            return left.key.rawValue > right.key.rawValue
        }?.key
    }

    private static func isUsable(_ track: Track) -> Bool {
        !track.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private struct Builder {
        let now: Date
        var artistAffinity: [String: Double] = [:]
        var trackAffinity: [String: Double] = [:]
        var heard: Set<String> = []
        var disliked: Set<String> = []
        var languageMix: [MusicLanguage: Double] = [:]
        var tracks: [String: Track] = [:]
        var spellings: [String: [String: Double]] = [:]
        var ids: [String: [String: Int]] = [:]
        var languages: [String: [MusicLanguage: Double]] = [:]
        var qualifyingEvents = 0
        var qualifyingArtists: Set<String> = []

        init(now: Date) { self.now = now }

        mutating func record(_ event: ListeningEvent) {
            guard TasteProfile.isUsable(event.track) else { return }
            heard.insert(event.track.id)
            tracks[event.track.id] = event.track
            guard event.listenedSeconds.isFinite, event.listenedSeconds > 0,
                  event.startedAt.timeIntervalSince1970.isFinite,
                  event.listenedSeconds >= ListeningAnalytics.qualifyingSeconds(for: event.track) else { return }
            qualifyingEvents += 1
            for name in event.track.artists {
                let key = TasteProfile.normalizedArtistName(name)
                if !key.isEmpty { qualifyingArtists.insert(key) }
            }
            let ageDays = max(0, now.timeIntervalSince(event.startedAt)) / 86_400
            credit(event.track, weight: event.listenedSeconds * pow(0.5, ageDays / TasteProfile.halfLifeDays), keepExisting: false)
        }

        mutating func credit(_ track: Track, weight: Double, keepExisting: Bool) {
            guard weight.isFinite, weight > 0 else { return }
            if !keepExisting || tracks[track.id] == nil { tracks[track.id] = track }
            trackAffinity[track.id, default: 0] += weight
            if let language = track.language { languageMix[language, default: 0] += weight }
            var credited = Set<String>()
            for credit in track.credits {
                let display = credit.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let key = TasteProfile.normalizedArtistName(display)
                guard !key.isEmpty, credited.insert(key).inserted else { continue }
                artistAffinity[key, default: 0] += weight
                spellings[key, default: [:]][display, default: 0] += weight
                if let language = track.language { languages[key, default: [:]][language, default: 0] += weight }
                if let id = credit.id, !id.isEmpty { ids[key, default: [:]][id, default: 0] += 1 }
            }
        }

        func finish() -> TasteProfile {
            var profile = TasteProfile()
            profile.artistAffinity = artistAffinity
            profile.trackAffinity = trackAffinity
            profile.heardTrackIDs = heard
            profile.dislikedTrackIDs = disliked
            profile.languageMix = languageMix
            profile.tracks = tracks
            profile.isColdStart = qualifyingEvents < TasteProfile.minimumQualifyingEvents
                || qualifyingArtists.count < TasteProfile.minimumDistinctArtists
            profile.artistDisplayNames = spellings.compactMapValues { options in
                options.max { left, right in
                    if left.value != right.value { return left.value < right.value }
                    return left.key > right.key
                }?.key
            }
            profile.artistIDs = ids.compactMapValues { options in
                options.max { left, right in
                    if left.value != right.value { return left.value < right.value }
                    return left.key > right.key
                }?.key
            }
            profile.artistLanguages = languages.compactMapValues { options in
                options.max { left, right in
                    if left.value != right.value { return left.value < right.value }
                    return left.key.rawValue > right.key.rawValue
                }?.key
            }
            return profile
        }
    }
}

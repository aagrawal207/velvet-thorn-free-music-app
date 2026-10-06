import Foundation

/// A snapshot of what the listener likes, derived from local history only. Pure value; rebuild it when the library changes.
struct TasteProfile: Sendable {
    static let halfLifeDays: Double = 21
    static let favoriteBoost: Double = 180
    /// Three likes' worth; a super like replaces the like credit rather than stacking on it.
    static let superLikeBoost: Double = 540
    static let playlistBoost: Double = 60
    /// A dislike counts against its artists about as much as a skipped full song counts for them.
    static let dislikePenalty: Double = 120
    static let minimumQualifyingEvents = 3
    static let minimumDistinctArtists = 2
    /// Hearing a song out says more than abandoning it; a quarter extra keeps that a nudge on the same scale.
    static let completionBonus = 0.25
    /// Finished means 90 percent of the song, or within 10 s of its end, so fade-outs and crossfades still count.
    static let completionShare = 0.9
    static let completionTailSeconds: TimeInterval = 10
    /// Replays inside a week show current enthusiasm; older repeats already live in the decayed seconds.
    static let replayWindowDays: Double = 7
    /// Seconds per doubling of weekly plays (2 add 60, 4 add 120, 8 add 180), so one obsession cannot take over.
    static let replayBonusSeconds: Double = 60

    /// Decayed listened seconds (finished plays and weekly replays earn extra) plus favorite/playlist boosts,
    /// less dislike and skip penalties; keyed by `normalizedArtistName`.
    private(set) var artistAffinity: [String: Double] = [:]
    /// Same scale as `artistAffinity`, keyed by track id.
    private(set) var trackAffinity: [String: Double] = [:]
    private(set) var heardTrackIDs: Set<String> = []
    /// Never recommended, never autoplayed; also excluded from `heardTrackIDs`-based familiarity picks.
    private(set) var dislikedTrackIDs: Set<String> = []
    /// Usable super liked favorites; mixes reserve one rotating seed and one familiar pick from this set.
    private(set) var superLikedTrackIDs: Set<String> = []
    /// Disliked songs' saved titles and credits, so a mix can also refuse other uploads of the same song.
    private(set) var dislikedSongs: [DislikedSong] = []
    private(set) var languageMix: [MusicLanguage: Double] = [:]
    private(set) var isColdStart = true
    /// Normalized artist keys per recent listening session (qualified plays, last 30 days, newest first).
    private(set) var sessionArtists: [Set<String>] = []
    /// Decayed skip weight per track id, counting only skips after the song's latest finished play.
    private(set) var skipScores: [String: Double] = [:]
    /// The same per `SongIdentity.key`, so other uploads and versions of a skipped song share its score.
    private(set) var songSkipScores: [String: Double] = [:]
    /// Songs skipped early often enough to sit out generated recommendations; explicit plays are unaffected.
    private(set) var restingSongs = RestingSongs()
    /// Artists whose affinity skips lowered, for bounded metrics.
    private(set) var skipPenalizedArtistCount = 0

    var restingTrackIDs: Set<String> { restingSongs.trackIDs }
    var restingSongKeys: Set<String> { restingSongs.songKeys }

    static let sessionWindowDays: Double = 30
    /// A pause longer than this between one play's end and the next start begins a new session.
    static let sessionGap: TimeInterval = 30 * 60
    static let maximumSessions = 300

    private var tracks: [String: Track] = [:]
    private var artistDisplayNames: [String: String] = [:]
    private var artistIDs: [String: String] = [:]
    private var artistLanguages: [String: MusicLanguage] = [:]
    private var songSkipArtists: Set<String> = []

    static func normalizedArtistName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping.lowercased()
    }

    static func build(events: [ListeningEvent], favorites: [Track], playlists: [UserPlaylist],
                      recents: [RecentListen], disliked: [DislikedSong] = [], superLikedIDs: Set<String> = [],
                      signals: [ListeningSignal] = [], now: Date) -> TasteProfile {
        var builder = Builder(now: now)
        for event in events.sorted(by: { $0.startedAt < $1.startedAt }) {
            builder.record(event)
        }
        builder.creditReplays()
        for recent in recents.sorted(by: { $0.playedAt < $1.playedAt }) where isUsable(recent.track) {
            builder.heard.insert(recent.track.id)
            builder.tracks[recent.track.id] = recent.track
        }
        for track in favorites where isUsable(track) {
            builder.heard.insert(track.id)
            let superLiked = superLikedIDs.contains(track.id)
            if superLiked { builder.superLiked.insert(track.id) }
            builder.credit(track, weight: superLiked ? superLikeBoost : favoriteBoost, keepExisting: true)
        }
        for playlist in playlists {
            for track in playlist.tracks where isUsable(track) {
                builder.heard.insert(track.id)
                builder.credit(track, weight: playlistBoost, keepExisting: true)
            }
        }
        for song in disliked where !song.id.isEmpty {
            builder.dislikedSongs.append(song)
            builder.disliked.insert(song.id)
            builder.superLiked.remove(song.id)
            builder.heard.insert(song.id)
            builder.trackAffinity.removeValue(forKey: song.id)
            for name in song.artists {
                let key = normalizedArtistName(name)
                guard !key.isEmpty, let current = builder.artistAffinity[key] else { continue }
                builder.artistAffinity[key] = max(0, current - dislikePenalty)
            }
        }
        // Skips subtract last so the zero floor never clips a credit that would have landed after them.
        builder.apply(SkipEvidence(signals: signals, liked: favorites.filter(isUsable), now: now))
        return builder.finish()
    }

    /// The recording's own score or its song's, whichever is stronger, so a re-upload cannot shed the evidence.
    func skipScore(for track: Track) -> Double {
        let own = skipScores[track.id] ?? 0
        guard let artist = track.artists.first, songSkipArtists.contains(Self.normalizedArtistName(artist)),
              let key = SongIdentity.key(track) else { return own }
        return max(own, songSkipScores[key] ?? 0)
    }

    func isResting(_ track: Track) -> Bool { restingSongs.contains(track) }

    /// Events carry no session ending, so a finished play is inferred from listened time against the song's length.
    static func isCompletedPlay(_ event: ListeningEvent) -> Bool {
        guard let duration = event.track.duration, duration.isFinite, duration > 0 else { return false }
        return event.listenedSeconds >= min(duration * completionShare, duration - completionTailSeconds)
    }

    static func replayBonus(plays: Int) -> Double {
        plays >= 2 ? replayBonusSeconds * log2(Double(plays)) : 0
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
        var superLiked: Set<String> = []
        var languageMix: [MusicLanguage: Double] = [:]
        var tracks: [String: Track] = [:]
        var spellings: [String: [String: Double]] = [:]
        var ids: [String: [String: Int]] = [:]
        var languages: [String: [MusicLanguage: Double]] = [:]
        var dislikedSongs: [DislikedSong] = []
        var qualifyingEvents = 0
        var qualifyingArtists: Set<String> = []
        var sessions: [Set<String>] = []
        var sessionEnd: Date?
        var replays: [String: (plays: Int, latest: Date)] = [:]
        var skips = SkipEvidence()
        var skipPenalizedArtists = 0

        init(now: Date) { self.now = now }

        mutating func record(_ event: ListeningEvent) {
            guard TasteProfile.isUsable(event.track) else { return }
            heard.insert(event.track.id)
            tracks[event.track.id] = event.track
            guard event.listenedSeconds.isFinite, event.listenedSeconds > 0,
                  event.startedAt.timeIntervalSince1970.isFinite,
                  event.listenedSeconds >= ListeningAnalytics.qualifyingSeconds(for: event.track) else { return }
            qualifyingEvents += 1
            var artists = Set<String>()
            for name in event.track.artists {
                let key = TasteProfile.normalizedArtistName(name)
                if !key.isEmpty { qualifyingArtists.insert(key); artists.insert(key) }
            }
            let ageDays = max(0, now.timeIntervalSince(event.startedAt)) / 86_400
            if ageDays <= TasteProfile.sessionWindowDays, event.startedAt <= now, !artists.isEmpty {
                let end = event.startedAt.addingTimeInterval(event.listenedSeconds)
                if let last = sessionEnd, event.startedAt.timeIntervalSince(last) <= TasteProfile.sessionGap, !sessions.isEmpty {
                    sessions[sessions.count - 1].formUnion(artists)
                } else {
                    sessions.append(artists)
                }
                sessionEnd = max(sessionEnd ?? end, end)
            }
            if ageDays <= TasteProfile.replayWindowDays, event.startedAt <= now {
                let previous = replays[event.track.id]
                replays[event.track.id] = (plays: (previous?.plays ?? 0) + 1,
                                           latest: max(previous?.latest ?? event.startedAt, event.startedAt))
            }
            let decayed = event.listenedSeconds * pow(0.5, ageDays / TasteProfile.halfLifeDays)
            credit(event.track, weight: TasteProfile.isCompletedPlay(event) ? decayed * (1 + TasteProfile.completionBonus) : decayed,
                   keepExisting: false)
        }

        /// The bonus decays from each song's latest play; ids are sorted so artist sums never depend on hash order.
        mutating func creditReplays() {
            for (id, replay) in replays.sorted(by: { $0.key < $1.key }) {
                let bonus = TasteProfile.replayBonus(plays: replay.plays)
                guard bonus > 0, let track = tracks[id] else { continue }
                let ageDays = max(0, now.timeIntervalSince(replay.latest)) / 86_400
                credit(track, weight: bonus * pow(0.5, ageDays / TasteProfile.halfLifeDays), keepExisting: true, countsChannel: false)
            }
        }

        /// `countsChannel` is false for bonuses: a bonus is not another sighting of a credit's channel id.
        mutating func credit(_ track: Track, weight: Double, keepExisting: Bool, countsChannel: Bool = true) {
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
                if countsChannel, let id = credit.id, !id.isEmpty { ids[key, default: [:]][id, default: 0] += 1 }
            }
        }

        /// The song pays its artists' per-skip rate too, so a skipped favorite stops leading seeds and the familiar pool.
        mutating func apply(_ evidence: SkipEvidence) {
            for (key, weight) in evidence.artistWeights {
                guard let current = artistAffinity[key], current > 0 else { continue }
                artistAffinity[key] = max(0, current - ListeningSignalWeights.artistPenaltySeconds * weight)
                skipPenalizedArtists += 1
            }
            for (id, weight) in evidence.trackScores {
                guard let current = trackAffinity[id] else { continue }
                trackAffinity[id] = max(0, current - ListeningSignalWeights.artistPenaltySeconds * weight)
            }
            skips = evidence
        }

        func finish() -> TasteProfile {
            var profile = TasteProfile()
            profile.artistAffinity = artistAffinity
            profile.trackAffinity = trackAffinity
            profile.heardTrackIDs = heard
            profile.dislikedTrackIDs = disliked
            profile.dislikedSongs = dislikedSongs
            profile.superLikedTrackIDs = superLiked
            profile.languageMix = languageMix
            profile.sessionArtists = Array(sessions.reversed().prefix(TasteProfile.maximumSessions))
            profile.skipScores = skips.trackScores
            profile.songSkipScores = skips.songScores
            profile.songSkipArtists = skips.songArtists
            profile.restingSongs = skips.resting
            profile.skipPenalizedArtistCount = skipPenalizedArtists
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

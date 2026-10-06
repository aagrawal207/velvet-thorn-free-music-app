import Foundation

enum SeedRadioError: LocalizedError, Sendable {
    case invalidSeed
    case noArtistRecordings
    case exhausted(language: ArtistSongLanguage?)

    var errorDescription: String? {
        switch self {
        case .invalidSeed:
            "This song can’t start radio. Choose an available audio recording that you haven’t excluded from recommendations."
        case .noArtistRecordings:
            "Couldn’t find available songs credited to this artist. Try another artist or start radio from one of their songs."
        case .exhausted(let language):
            if let language {
                "No more matching \(language.title) songs were found. Songs with unknown language are excluded. Choose Automatic Language in Tune or try again later."
            } else {
                "No more matching songs were found without repeating your queue. Try again later or start another radio."
            }
        }
    }
}

struct SeedRadioEngine: Sendable {
    let catalog: any MusicCatalogProviding

    private static let candidateLimit = 100
    private static let requestTimeout: TimeInterval = 8
    private static let refillTimeout: TimeInterval = 23

    /// `resting` applies only to an artist's popular songs: a song the listener picks starts radio whatever its skips.
    func anchors(for seed: RadioSeed, disliked: [DislikedSong], resting: RestingSongs = RestingSongs()) async throws -> [Track] {
        try Task.checkCancellation()
        guard seed.isValid else { throw SeedRadioError.invalidSeed }
        switch seed {
        case .song(let track):
            guard Self.isUsable(track), !Self.isDisliked(track, disliked: disliked) else {
                throw SeedRadioError.invalidSeed
            }
            return [track]
        case .artist(let artist):
            let linked: ArtistCredit
            if artist.id != nil {
                linked = artist
            } else {
                let page = try await PlaybackDeadline.run(seconds: Self.requestTimeout) {
                    try await catalog.search(query: artist.name, filter: .artists, continuation: nil)
                }
                try Task.checkCancellation()
                let matches = page.collections.prefix(Self.candidateLimit).filter {
                    $0.kind == .artist && !$0.id.isEmpty
                        && SearchRelevance.normalize($0.title) == SearchRelevance.normalize(artist.name)
                }
                guard let match = SearchRelevance.matchedArtist(in: matches, query: artist.name) else {
                    throw SeedRadioError.noArtistRecordings
                }
                linked = ArtistCredit(name: match.title, id: match.id)
            }
            guard RadioSeed.artist(linked).isValid, let id = linked.id else { throw SeedRadioError.noArtistRecordings }
            let page = try await PlaybackDeadline.run(seconds: Self.requestTimeout) {
                try await catalog.artist(id: id)
            }
            try Task.checkCancellation()
            guard page.id == id else { throw MusicServiceError.invalidResponse }
            var creditedArtist = page
            creditedArtist.name = linked.name
            let eligible = page.topSongs.prefix(Self.candidateLimit).filter {
                Self.isUsable($0) && !Self.isDisliked($0, disliked: disliked)
                    && ArtistSpotlight.credits(creditedArtist, on: $0)
            }
            // The listener asked for this artist, so radio still starts when every popular song rests.
            let awake = resting.excluding(eligible)
            var skips = SkipSignalMetrics()
            skips.restingExcluded = awake.isEmpty ? 0 : eligible.count - awake.count
            skips.emit(.seedRadio)
            let anchors = Array(ArtistSpotlight.displaySongs(awake.isEmpty ? eligible : awake, artist: creditedArtist).tracks.prefix(3))
            guard !anchors.isEmpty else { throw SeedRadioError.noArtistRecordings }
            return anchors
        }
    }

    /// Resting songs leave the additions but never the frozen anchors, so radio started from one keeps going.
    func refill(anchors: [Track], round: Int, excluding: [Track], disliked: [DislikedSong],
                tuning: RadioTuning, heardTrackIDs: Set<String>, languageProfile: ListeningLanguageProfile,
                resting: RestingSongs = RestingSongs(), forceRefresh: Bool = false) async throws -> [Track] {
        try Task.checkCancellation()
        let eligible = Array(anchors.prefix(3).filter { Self.isUsable($0) && !Self.isDisliked($0, disliked: disliked) })
        guard !eligible.isEmpty else { throw SeedRadioError.invalidSeed }
        let index = max(0, round) % eligible.count
        let first = eligible[index]
        // The caller owns the frozen anchors; queue additions never become a new recommendation seed.
        let second = eligible.count > 1 ? eligible[(index + 1) % eligible.count] : nil
        return try await PlaybackDeadline.run(seconds: Self.refillTimeout) {
            var skips = SkipSignalMetrics()
            defer { skips.emit(.seedRadio) }
            var requests: [(Track, Bool)] = [(first, forceRefresh)]
            if let second { requests.append((second, false)) }
            if !forceRefresh { requests.append((first, true)) }
            for (anchor, fresh) in requests {
                try Task.checkCancellation()
                let candidates = try await PlaybackDeadline.run(seconds: Self.requestTimeout) {
                    try await catalog.radio(seed: anchor, forceRefresh: fresh)
                }
                try Task.checkCancellation()
                skips.restingExcluded += Self.restingCount(candidates, excluding: anchors + excluding, resting: resting)
                let selected = Self.select(candidates, excluding: anchors + excluding, disliked: disliked,
                                           tuning: tuning, heardTrackIDs: heardTrackIDs, languageProfile: languageProfile,
                                           resting: resting)
                if !selected.isEmpty { return selected }
            }
            throw SeedRadioError.exhausted(language: tuning.language)
        }
    }

    static func select(_ candidates: [Track], excluding: [Track], disliked: [DislikedSong],
                       tuning: RadioTuning, heardTrackIDs: Set<String>, languageProfile: ListeningLanguageProfile,
                       resting: RestingSongs = RestingSongs(), limit: Int = 8) -> [Track] {
        guard limit > 0 else { return [] }
        let excludedIDs = Set(excluding.map(\.id))
        let excludedByTitle = Dictionary(grouping: excluding, by: { SongTitle.core($0.title) })
        let ranked = candidates.prefix(candidateLimit).enumerated().filter { _, track in
            isUsable(track) && !excludedIDs.contains(track.id) && !isDisliked(track, disliked: disliked) && !resting.contains(track)
                && (tuning.language == nil || languageProfile.language(for: track) == tuning.language)
                && !(excludedByTitle[SongTitle.core(track.title)] ?? []).contains {
                    sameRecording(track, $0, languageProfile: languageProfile)
                }
        }.sorted { left, right in
            let a = languageProfile.multiplier(for: left.element) / (1 + Double(left.offset) * 0.01)
            let b = languageProfile.multiplier(for: right.element) / (1 + Double(right.offset) * 0.01)
            return a == b ? left.offset < right.offset : a > b
        }.map(\.element)
        let familiar = ranked.filter { heardTrackIDs.contains($0.id) }
        let fresh = ranked.filter { !heardTrackIDs.contains($0.id) }
        let ordered: [Track]
        switch tuning.familiarity {
        case .familiar: ordered = familiar + fresh
        case .newMusic: ordered = fresh + familiar
        case .balanced: ordered = RecommendationEngine.interleave(familiar: familiar, fresh: fresh)
        }

        var distinct: [Track] = []
        var seen = Set<String>()
        var byTitle: [String: [Track]] = [:]
        for track in ordered {
            let title = SongTitle.core(track.title)
            guard seen.insert(track.id).inserted,
                  !(byTitle[title] ?? []).contains(where: { sameRecording(track, $0, languageProfile: languageProfile) }) else { continue }
            distinct.append(track)
            byTitle[title, default: []].append(track)
        }
        var remaining = RecommendationEngine.select(distinct, limit: candidateLimit, artistCap: 2)
        var result: [Track] = []
        var previousArtist = excluding.last.map(RecommendationEngine.primaryArtistKey)
        while !remaining.isEmpty, result.count < min(limit, candidateLimit) {
            let next = remaining.firstIndex { RecommendationEngine.primaryArtistKey($0) != previousArtist } ?? 0
            let track = remaining.remove(at: next)
            result.append(track)
            previousArtist = RecommendationEngine.primaryArtistKey(track)
        }
        return result
    }

    private static func restingCount(_ candidates: [Track], excluding: [Track], resting: RestingSongs) -> Int {
        guard !resting.isEmpty else { return 0 }
        let excludedIDs = Set(excluding.map(\.id))
        return candidates.prefix(candidateLimit).filter { !excludedIDs.contains($0.id) && resting.contains($0) }.count
    }

    private static func isUsable(_ track: Track) -> Bool {
        RadioSeed.song(track).isValid && track.isAudioRecording == true && !SongTitle.core(track.title).isEmpty
            && RecommendationEngine.isRecommendable(track, languages: [])
    }

    private static func isDisliked(_ track: Track, disliked: [DislikedSong]) -> Bool {
        let artists = Set(LyricsMatcher.artistParts(track.allCredits.map(\.name)).map(SearchRelevance.normalize))
        return disliked.contains { song in
            if song.id == track.id { return true }
            // Dislikes have no duration or linked credits; matching a title alone would exclude unrelated songs.
            return !artists.isEmpty && SongTitle.isVersion(track.title, of: song.title)
                && artists == Set(LyricsMatcher.artistParts(song.artists).map(SearchRelevance.normalize))
        }
    }

    private static func sameRecording(_ left: Track, _ right: Track,
                                      languageProfile: ListeningLanguageProfile) -> Bool {
        if left.id == right.id { return true }
        guard left.isAudioRecording != false, right.isAudioRecording != false else { return false }
        if let a = languageProfile.language(for: left), let b = languageProfile.language(for: right), a != b { return false }
        // Spotlight preserves performers, linked-ID conflicts, meaningful qualifiers and uncertain durations.
        // The page supplies ranking context only; neither representative replaces the caller's recording.
        let context = ArtistPage(id: left.credits.first?.id ?? "", name: left.artists.first ?? "", topSongs: [left, right])
        return ArtistSpotlight.displaySongs([left, right], artist: context).tracks.count == 1
    }
}

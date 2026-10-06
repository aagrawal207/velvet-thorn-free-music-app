import Foundation

/// Songs resting from generated recommendations after repeated early skips. Explicit plays are unaffected.
struct RestingSongs: Equatable, Sendable {
    private(set) var trackIDs: Set<String> = []
    /// `SongIdentity.key` values, so another upload or version of a resting song rests too.
    private(set) var songKeys: Set<String> = []
    /// Liked recordings never rest, even when their saved metadata no longer yields the liked song's key.
    private(set) var exemptTrackIDs: Set<String> = []
    /// Normalized primary artists of `songKeys`, so most tracks skip the title-core work of a song key.
    private var songArtists: Set<String> = []

    init() {}

    /// `songs` maps each resting song key to its normalized primary artist.
    init(trackIDs: Set<String>, songs: [String: String], exemptTrackIDs: Set<String>) {
        self.trackIDs = trackIDs
        songKeys = Set(songs.keys)
        songArtists = Set(songs.values)
        self.exemptTrackIDs = trackIDs.isEmpty && songs.isEmpty ? [] : exemptTrackIDs
    }

    var isEmpty: Bool { trackIDs.isEmpty && songKeys.isEmpty }

    func contains(_ track: Track) -> Bool {
        guard !isEmpty, !exemptTrackIDs.contains(track.id) else { return false }
        if trackIDs.contains(track.id) { return true }
        guard let artist = track.artists.first, songArtists.contains(TasteProfile.normalizedArtistName(artist)),
              let key = SongIdentity.key(track) else { return false }
        return songKeys.contains(key)
    }

    /// For generated lists only: a listener who picks a resting song still hears it.
    func excluding(_ tracks: [Track]) -> [Track] {
        isEmpty ? tracks : tracks.filter { !contains($0) }
    }
}

/// Skip scores from device-local listening signals, after finished plays and likes have had their say.
struct SkipEvidence: Sendable {
    private(set) var trackScores: [String: Double] = [:]
    private(set) var songScores: [String: Double] = [:]
    /// Normalized primary artists of `songScores`, so most tracks skip the title-core work of a song key.
    private(set) var songArtists: Set<String> = []
    /// Decayed skip weight per normalized artist key.
    private(set) var artistWeights: [String: Double] = [:]
    private(set) var resting = RestingSongs()

    init() {}

    init(signals: [ListeningSignal], liked: [Track], now: Date) {
        guard !signals.isEmpty else { return }
        // Sorted so the floating-point sums never depend on the order the store returns signals in.
        let entries: [(signal: ListeningSignal, key: String?)] = signals.sorted {
            ($0.endedAt, $0.trackID) < ($1.endedAt, $1.trackID)
        }.compactMap { signal in
            guard !signal.trackID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  signal.endedAt.timeIntervalSince1970.isFinite else { return nil }
            return (signal: signal, key: SongIdentity.key(title: signal.title, primaryArtist: signal.artists.first))
        }
        var finishedByID: [String: Date] = [:]
        var finishedByKey: [String: Date] = [:]
        // Completions only forgive skips here: with no session id they cannot be matched to their listening
        // events, so crediting them as plays could count one play twice.
        for (signal, key) in entries where signal.ending == .completed {
            finishedByID[signal.trackID] = max(finishedByID[signal.trackID] ?? .distantPast, signal.endedAt)
            if let key { finishedByKey[key] = max(finishedByKey[key] ?? .distantPast, signal.endedAt) }
        }
        var keyByID: [String: String] = [:]
        var artistByKey: [String: String] = [:]
        for (signal, key) in entries where signal.ending == .skipped {
            // Hearing the song out later shows the earlier skips were about the moment, not the song.
            let finished = max(finishedByID[signal.trackID] ?? .distantPast, key.flatMap { finishedByKey[$0] } ?? .distantPast)
            guard signal.endedAt > finished else { continue }
            let weight = ListeningSignalWeights.skipWeight(signal, now: now)
            guard weight.isFinite, weight > 0 else { continue }
            trackScores[signal.trackID, default: 0] += weight
            if let key, let primary = signal.artists.first {
                songScores[key, default: 0] += weight
                keyByID[signal.trackID] = key
                artistByKey[key] = TasteProfile.normalizedArtistName(primary)
            }
            var credited = Set<String>()
            for name in signal.artists {
                let artist = TasteProfile.normalizedArtistName(name)
                guard !artist.isEmpty, credited.insert(artist).inserted else { continue }
                artistWeights[artist, default: 0] += weight
            }
        }
        let threshold = ListeningSignalWeights.restThreshold
        songArtists = Set(artistByKey.values)
        let restingIDs = trackScores.compactMap { $0.value >= threshold ? $0.key : nil }
        let restingKeys = songScores.compactMap { $0.value >= threshold ? $0.key : nil }
        guard !restingIDs.isEmpty || !restingKeys.isEmpty else { return }
        // A like proves the opposite of a skip, so a liked song never rests; its skips still cost rank and affinity.
        let likedIDs = Set(liked.map(\.id))
        let artists = Set(restingKeys.compactMap { artistByKey[$0] } + restingIDs.compactMap { keyByID[$0].flatMap { artistByKey[$0] } })
        let likedKeys = Set(liked.compactMap { track -> String? in
            guard let artist = track.artists.first, artists.contains(TasteProfile.normalizedArtistName(artist)) else { return nil }
            return SongIdentity.key(track)
        })
        let ids = Set(restingIDs.filter { !likedIDs.contains($0) && !(keyByID[$0].map { likedKeys.contains($0) } ?? false) })
        var songs: [String: String] = [:]
        for key in restingKeys where !likedKeys.contains(key) { songs[key] = artistByKey[key] }
        resting = RestingSongs(trackIDs: ids, songs: songs, exemptTrackIDs: likedIDs)
    }
}

/// Bounded counts only: no ids, titles or artists.
struct SkipSignalMetrics {
    enum Scope: String {
        case discoverWeekly = "discover_weekly"
        case dailyMix = "daily_mix"
        case seedRadio = "seed_radio"
        case home
    }

    var restingExcluded = 0
    var downweighted = 0
    var artistsPenalized = 0

    init(profile: TasteProfile? = nil) {
        artistsPenalized = profile?.skipPenalizedArtistCount ?? 0
    }

    /// Distinct eligible recordings a mix dropped for resting, and provider candidates it kept at a lower rank.
    /// Heard recordings reach the familiar pool through affinity, which skips already lowered, so they only drop.
    static func mix(candidates: [RecommendationEngine.Candidate], profile: TasteProfile,
                    languages: Set<MusicLanguage>) -> SkipSignalMetrics {
        var metrics = SkipSignalMetrics(profile: profile)
        guard !profile.skipScores.isEmpty else { return metrics }
        var seen = Set<String>()
        func eligible(_ track: Track) -> Bool {
            seen.insert(track.id).inserted && !profile.dislikedTrackIDs.contains(track.id)
                && RecommendationEngine.isRecommendable(track, languages: languages)
        }
        for candidate in candidates where eligible(candidate.track) {
            if profile.isResting(candidate.track) { metrics.restingExcluded += 1 }
            else if profile.skipScore(for: candidate.track) > 0 { metrics.downweighted += 1 }
        }
        guard !profile.restingSongs.isEmpty else { return metrics }
        for id in profile.heardTrackIDs {
            guard let track = profile.track(id: id), eligible(track), profile.isResting(track) else { continue }
            metrics.restingExcluded += 1
        }
        return metrics
    }

    func emit(_ scope: Scope) {
        RecommendationEngine.log.info("event=skip_signals_applied scope=\(scope.rawValue, privacy: .public) resting_excluded=\(restingExcluded) downweighted=\(downweighted) artists_penalized=\(artistsPenalized)")
    }
}

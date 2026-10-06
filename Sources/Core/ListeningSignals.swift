import Foundation

/// How one listening session ended, as recommendations read it. Device-local and never synced.
struct ListeningSignal: Codable, Equatable, Sendable {
    enum Ending: String, Codable, Sendable {
        /// The listener moved on while the song was playing: Next, a queue jump or a new list.
        case skipped
        /// The song reached its end, blended into the next one, or Repeat One restarted it.
        case completed
    }

    enum Origin: String, Codable, Sendable {
        /// Radio, autoplay or a generated mix chose the song.
        case generated
        /// The listener picked the list: their playlist, likes, an album or a search result.
        case chosen
    }

    var trackID: String
    var title: String
    var artists: [String]
    var endedAt: Date
    /// Credited seconds in this session, excluding pauses and seek jumps.
    var listenedSeconds: Double
    var duration: Double?
    var ending: Ending
    var origin: Origin
    /// The third or later skip within `ListeningSignalWeights.rapidWindow`: flicking through, not judging.
    var rapid: Bool
}

/// The rules that turn signals into recommendation weights. Pure, so every threshold is unit-tested.
enum ListeningSignalWeights {
    /// Skipping this early is a clear "not this".
    static let strongSkipSeconds: Double = 10
    static let mildSkipSeconds: Double = 30
    static let strongSkip = 1.0
    static let mildSkip = 0.4
    /// Between 30 seconds and half the song: the listener gave it a fair try.
    static let lightSkip = 0.15
    /// Skipping through a list you chose yourself is often searching, not judging.
    static let chosenFactor = 0.5
    static let rapidFactor = 0.5
    static let rapidWindow: TimeInterval = 20
    static let rapidCount = 3
    /// Skips fade faster than listening affinity (21 days), so a mood is not held against a song for long.
    static let halfLifeDays: Double = 14
    /// About two early skips of songs Velvet Thorn chose, within two weeks: the song rests from recommendations.
    static let restThreshold = 1.5
    /// Seconds of listening affinity one full-strength skip removes from each credited artist.
    static let artistPenaltySeconds: Double = 45

    /// 0 for a completed song or a skip after half of it; otherwise the skip's strength before context.
    static func skipStrength(listenedSeconds: Double, duration: Double?) -> Double {
        let listened = listenedSeconds.isFinite ? max(0, listenedSeconds) : 0
        if listened < strongSkipSeconds { return strongSkip }
        if listened < mildSkipSeconds { return mildSkip }
        guard let duration, duration.isFinite, duration > 0 else { return lightSkip }
        return listened < duration / 2 ? lightSkip : 0
    }

    /// The decayed negative weight one signal contributes, 0 for completions.
    static func skipWeight(_ signal: ListeningSignal, now: Date) -> Double {
        guard signal.ending == .skipped else { return 0 }
        var weight = skipStrength(listenedSeconds: signal.listenedSeconds, duration: signal.duration)
        if signal.origin == .chosen { weight *= chosenFactor }
        if signal.rapid { weight *= rapidFactor }
        let ageDays = max(0, now.timeIntervalSince(signal.endedAt)) / 86_400
        return weight * pow(0.5, ageDays / halfLifeDays)
    }
}

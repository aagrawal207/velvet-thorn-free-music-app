import Foundation

enum MomentTime: String, Codable, CaseIterable, Sendable {
    case morning, afternoon, evening, night

    static func at(_ date: Date, calendar: Calendar) -> Self {
        switch calendar.component(.hour, from: date) {
        case 5..<11: .morning
        case 11..<17: .afternoon
        case 17..<22: .evening
        default: .night
        }
    }
}

enum MomentRoute: String, Codable, CaseIterable, Sendable {
    case general, headphones, car, active
}

struct MomentContext: Codable, Hashable, Identifiable, Sendable {
    var time: MomentTime
    var weekend: Bool
    var route: MomentRoute

    var id: String { "\(weekend ? "weekend" : "weekday").\(time.rawValue).\(route.rawValue)" }
    var title: String {
        let prefix = weekend ? "Weekend " : ""
        let suffix: String
        switch route {
        case .general: suffix = "Mix"
        case .headphones: suffix = "Headphones"
        case .car: suffix = "Car Mix"
        case .active: suffix = "Active Mix"
        }
        return "\(prefix)\(time.rawValue.capitalized) \(suffix)"
    }

    var symbol: String {
        switch route {
        case .general: time == .night ? "moon.stars" : "clock"
        case .headphones: "headphones"
        case .car: "car"
        case .active: "figure.walk"
        }
    }

    static func at(_ date: Date, route: MomentRoute = .general, calendar: Calendar) -> Self {
        Self(time: .at(date, calendar: calendar), weekend: calendar.isDateInWeekend(date), route: route)
    }

    static var all: [Self] {
        [false, true].flatMap { weekend in
            MomentTime.allCases.flatMap { time in
                MomentRoute.allCases.map { Self(time: time, weekend: weekend, route: $0) }
            }
        }
    }
}

struct MomentMixPreferences: Codable, Equatable, Sendable {
    var learningEnabled = true
    var motionEnabled = false
    var disabledMixIDs: Set<String> = []
}

/// Only device-local context and recording references; metadata continues to belong to the library.
struct MomentEvidence: Codable, Equatable, Sendable {
    var eventID: UUID
    var trackID: String
    var startedAt: Date
    var endedAt: Date
    var localDay: String
    var context: MomentContext
}

struct MomentMixSnapshot: Codable, Equatable, Sendable {
    var version = 1
    var preferences = MomentMixPreferences()
    var historyEpoch: UUID?
    var historyWasEnabled: Bool?
    var learningSince: Date
    var evidence: [MomentEvidence] = []
    var selectionDay: String?
    var selectedTrackIDs: [String: [String]] = [:]
}

struct MomentSummary: Identifiable, Sendable {
    var context: MomentContext
    var sessions: Int
    var days: Int
    var trackSessions: [String: Int]
    var id: String { context.id }
    var isRecurring: Bool { sessions >= 3 && days >= 3 }
}

enum MomentLearning {
    static let maximumEvents = 2_048
    static let retentionDays = 60
    static let maximumTracks = 25
    static let maximumCandidates = 5_000
    static let minimumTracks = 3

    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let values = calendar.dateComponents([.era, .year, .month, .day], from: date)
        return "\(values.era ?? 0)-\(values.year ?? 0)-\(values.month ?? 0)-\(values.day ?? 0)"
    }

    static func summaries(_ evidence: [MomentEvidence]) -> [MomentSummary] {
        Dictionary(grouping: evidence, by: \.context).map { context, entries in
            let ordered = entries.sorted {
                $0.startedAt == $1.startedAt ? $0.eventID.uuidString < $1.eventID.uuidString : $0.startedAt < $1.startedAt
            }
            var sessions: [Set<String>] = []
            var end: Date?
            var seen = Set<UUID>()
            for entry in ordered where seen.insert(entry.eventID).inserted {
                if let end, entry.startedAt.timeIntervalSince(end) <= TasteProfile.sessionGap, !sessions.isEmpty {
                    sessions[sessions.count - 1].insert(entry.trackID)
                } else {
                    sessions.append([entry.trackID])
                }
                end = max(end ?? entry.endedAt, entry.endedAt)
            }
            var counts: [String: Int] = [:]
            for session in sessions { for id in session { counts[id, default: 0] += 1 } }
            return MomentSummary(context: context, sessions: sessions.count,
                                 days: Set(ordered.map(\.localDay)).count, trackSessions: counts)
        }.sorted { $0.id < $1.id }
    }

    static func collection(for summary: MomentSummary, library: [Track], profile: TasteProfile,
                           preferences: MomentMixPreferences, periodKey: String) -> MusicCollection? {
        guard preferences.learningEnabled, summary.isRecurring,
              !preferences.disabledMixIDs.contains(summary.id) else { return nil }
        var tracks: [String: Track] = [:]
        for track in library where track.isAudioRecording != false && !track.id.isEmpty && track.id.utf8.count <= 512 {
            guard !profile.dislikedTrackIDs.contains(track.id) else { continue }
            guard tracks.count < maximumCandidates else { break }
            if tracks[track.id] == nil { tracks[track.id] = track }
        }
        let seeds = summary.trackSessions.keys.compactMap { tracks[$0] }
        guard !seeds.isEmpty else { return nil }
        let artists = Set(seeds.flatMap(\.artists).map(TasteProfile.normalizedArtistName).filter { !$0.isEmpty })
        let candidates = tracks.values.filter { track in
            summary.trackSessions[track.id] != nil
                || track.artists.contains { artists.contains(TasteProfile.normalizedArtistName($0)) }
        }
        let ranked = candidates.sorted { left, right in
            let l = score(left), r = score(right)
            if l != r { return l > r }
            let a = RecommendationEngine.jitter(periodKey: periodKey + summary.id, id: left.id)
            let b = RecommendationEngine.jitter(periodKey: periodKey + summary.id, id: right.id)
            return a == b ? left.id < right.id : a > b
        }
        let selected = Array(ranked.prefix(maximumTracks))
        guard selected.count >= minimumTracks else { return nil }
        return MusicCollection(id: "moment.\(summary.id)", title: summary.context.title,
                               subtitle: "From your recurring listening · Made on this device",
                               artworkURL: selected.first?.artworkURL, kind: .mix, tracks: selected)

        func score(_ track: Track) -> Double {
            Double(summary.trackSessions[track.id] ?? 0) * 10
                + min(5, log1p(max(0, profile.trackAffinity[track.id] ?? 0)))
        }
    }
}

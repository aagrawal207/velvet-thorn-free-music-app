import Foundation

enum LanguageRecommendationNudge: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic, more, less

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct LanguageRecommendationNudges: Codable, Equatable, Sendable {
    // Fixed scalar fields keep every per-language sync register addressable, including Automatic.
    var bengali: LanguageRecommendationNudge = .automatic
    var english: LanguageRecommendationNudge = .automatic
    var hindi: LanguageRecommendationNudge = .automatic
    var tamil: LanguageRecommendationNudge = .automatic
    var telugu: LanguageRecommendationNudge = .automatic

    init() { }

    subscript(_ language: ArtistSongLanguage) -> LanguageRecommendationNudge {
        get {
            switch language {
            case .bengali: bengali
            case .english: english
            case .hindi: hindi
            case .tamil: tamil
            case .telugu: telugu
            }
        }
        set {
            switch language {
            case .bengali: bengali = newValue
            case .english: english = newValue
            case .hindi: hindi = newValue
            case .tamil: tamil = newValue
            case .telugu: telugu = newValue
            }
        }
    }

    var isAutomatic: Bool { ArtistSongLanguage.allCases.allSatisfy { self[$0] == .automatic } }

    private enum CodingKeys: String, CodingKey { case bengali, english, hindi, tamil, telugu }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        bengali = try values.decodeIfPresent(LanguageRecommendationNudge.self, forKey: .bengali) ?? .automatic
        english = try values.decodeIfPresent(LanguageRecommendationNudge.self, forKey: .english) ?? .automatic
        hindi = try values.decodeIfPresent(LanguageRecommendationNudge.self, forKey: .hindi) ?? .automatic
        tamil = try values.decodeIfPresent(LanguageRecommendationNudge.self, forKey: .tamil) ?? .automatic
        telugu = try values.decodeIfPresent(LanguageRecommendationNudge.self, forKey: .telugu) ?? .automatic
    }
}

struct LanguageListeningStat: Equatable, Identifiable, Sendable {
    var language: ArtistSongLanguage
    var plays: Int
    var songs: Int
    var share: Double
    var id: String { language.rawValue }
}

struct ListeningLanguageSummary: Equatable, Sendable {
    var rows: [LanguageListeningStat] = []
    var unclassifiedPlays = 0
    var unclassifiedSongs = 0
    var totalPlays = 0
    var totalSongs = 0

    var identifiedPlays: Int { rows.reduce(0) { $0 + $1.plays } }
}

struct ListeningLanguageProfile: Equatable, Sendable {
    let summary: ListeningLanguageSummary
    let nudges: LanguageRecommendationNudges
    let weights: [ArtistSongLanguage: Double]
    let orderedLanguages: [ArtistSongLanguage]
    let isLearned: Bool
    let requestKey: String

    private let evidence: [LyricsRequestKey: ArtistSongLanguageResult]
    private let overrides: [String: String]

    init(summary: ListeningLanguageSummary = .init(), nudges: LanguageRecommendationNudges = .init(),
         evidence: [LyricsRequestKey: ArtistSongLanguageResult] = [:], overrides: [String: String] = [:],
         fallback: Set<MusicLanguage> = [.hindi, .english]) {
        self.summary = summary
        self.nudges = nudges
        self.evidence = evidence
        self.overrides = overrides

        var counts: [ArtistSongLanguage: Double] = [:]
        for row in summary.rows where row.plays > 0 { counts[row.language, default: 0] += Double(row.plays) }
        let languages = ArtistSongLanguage.allCases
        let observed = languages.filter { counts[$0, default: 0] > 0 }
        isLearned = !observed.isEmpty
        var effective: [ArtistSongLanguage: Double] = [:]
        if !observed.isEmpty {
            let total = observed.reduce(0) { $0 + counts[$1, default: 0] }
            // A small uniform share protects observed minority languages without inventing listening counts.
            for language in observed {
                effective[language] = 0.9 * counts[language, default: 0] / total + 0.1 / Double(observed.count)
            }
        } else {
            let fallback = fallback.isEmpty ? Set(MusicLanguage.allCases) : fallback
            let initial: [ArtistSongLanguage] = MusicLanguage.allCases.filter(fallback.contains).map {
                switch $0 {
                case .hindi: .hindi
                case .english: .english
                }
            }
            for language in initial { effective[language] = 1 / Double(initial.count) }
        }
        for language in languages {
            switch nudges[language] {
            case .automatic: break
            case .more: effective[language] = max(0.2, 2 * effective[language, default: 0])
            case .less:
                if let weight = effective[language] { effective[language] = weight * 0.25 }
            }
        }
        let total = languages.reduce(0) { $0 + effective[$1, default: 0] }
        let normalized = effective.mapValues { $0 / total }
        weights = normalized
        orderedLanguages = languages.filter { normalized[$0] != nil }.sorted {
            let a = normalized[$0, default: 0]
            let b = normalized[$1, default: 0]
            return a == b ? $0.rawValue < $1.rawValue : a > b
        }
        // Five-percent buckets avoid rebuilding discovery for small changes; zero denotes an inactive language.
        requestKey = "languages-v1|\(isLearned ? "learned" : "starting")|" + languages.map { language in
            let bucket = normalized[language].map { max(1, min(20, Int(($0 * 20).rounded()))) } ?? 0
            return "\(language.rawValue):\(bucket):\(nudges[language].rawValue)"
        }.joined(separator: "|")
    }

    func language(for track: Track) -> ArtistSongLanguage? {
        let automatic = evidence[LyricsRequestKey(track)].map { [track.id: $0] } ?? [:]
        return ArtistSpotlight.languageResult(for: track, in: automatic, overrides: overrides)?.language
    }

    func multiplier(for track: Track) -> Double {
        guard let language = language(for: track) else { return 1 }
        return 0.6 + 1.4 * weights[language, default: 0]
    }

    func scheduledLanguages(count: Int) -> [ArtistSongLanguage] {
        guard count > 0 else { return [] }
        let quotas = weights.mapValues { $0 * Double(count) }
        var allocations = quotas.mapValues { Int($0.rounded(.down)) }
        let remainders = orderedLanguages.sorted {
            let a = quotas[$0, default: 0] - Double(allocations[$0, default: 0])
            let b = quotas[$1, default: 0] - Double(allocations[$1, default: 0])
            return a == b ? $0.rawValue < $1.rawValue : a > b
        }
        let remaining = count - allocations.values.reduce(0, +)
        for language in remainders.prefix(max(0, remaining)) { allocations[language, default: 0] += 1 }
        // Diversity uses an existing slot, never an additional provider request.
        if count >= 3, orderedLanguages.count > 1, allocations[orderedLanguages[1], default: 0] == 0,
           let donor = orderedLanguages.first(where: { allocations[$0, default: 0] > 1 }) {
            allocations[donor, default: 0] -= 1
            allocations[orderedLanguages[1]] = 1
        }
        var result: [ArtistSongLanguage] = []
        result.reserveCapacity(count)
        while allocations.values.contains(where: { $0 > 0 }) {
            for language in orderedLanguages where allocations[language, default: 0] > 0 {
                result.append(language)
                allocations[language, default: 0] -= 1
            }
        }
        return result
    }
}

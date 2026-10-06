import Foundation

struct GenreListeningStat: Equatable, Identifiable, Sendable {
    var family: GenreFamily
    /// Play weight: a play split across three families contributes its shares, so these sum to the classified plays.
    var plays: Double
    var songs: Int
    /// Share of the classified plays, so the bars of a period sum to one.
    var share: Double
    var id: String { family.rawValue }
}

struct ListeningGenreSummary: Equatable, Sendable {
    var rows: [GenreListeningStat] = []
    var classifiedPlays = 0
    var classifiedSongs = 0
    var totalPlays = 0
    var totalSongs = 0

    var unclassifiedPlays: Int { totalPlays - classifiedPlays }
    /// Fraction of counted plays with genre evidence; the honest denominator includes unclassified plays.
    var coverage: Double { totalPlays > 0 ? Double(classifiedPlays) / Double(totalPlays) : 0 }
    var isEmpty: Bool { rows.isEmpty }

    func top(_ count: Int) -> [GenreListeningStat] { Array(rows.prefix(max(0, count))) }
}

/// Mirrors `ListeningLanguageProfile`: counts from the last 30 days of qualified plays, weights after nudges.
struct ListeningGenreProfile: Equatable, Sendable {
    /// A multiplier between 1.0 and 1.15 reorders near ties without beating the 1.5x familiarity tier or the
    /// 0.6 to 2.0 language range; a Less family sits at 0.85. Unclassified candidates stay at exactly 1.
    static let rankingWeight = 0.15
    /// Daily Mix and Discover Weekly only trust the profile once this share of recent plays is classified.
    static let mixCoverageGate = 0.4
    static let topFamilyCount = 3

    let summary: ListeningGenreSummary
    let nudges: GenreNudges
    let weights: [GenreFamily: Double]
    let orderedFamilies: [GenreFamily]
    let isLearned: Bool
    let requestKey: String

    private let evidence: [LyricsRequestKey: GenreDistribution]

    init(summary: ListeningGenreSummary = .init(), nudges: GenreNudges = .init(),
         evidence: [LyricsRequestKey: GenreDistribution] = [:]) {
        self.summary = summary
        self.nudges = nudges
        self.evidence = evidence

        let observed = summary.rows.filter { $0.plays > 0 }
        isLearned = !observed.isEmpty
        var effective: [GenreFamily: Double] = [:]
        if !observed.isEmpty {
            let total = observed.reduce(0) { $0 + $1.plays }
            // The same 90/10 split as languages: a small uniform share protects minority families without inventing plays.
            for row in observed {
                effective[row.family] = 0.9 * row.plays / total + 0.1 / Double(observed.count)
            }
        }
        for family in GenreFamily.allCases {
            switch nudges[family] {
            case .automatic: break
            case .more: effective[family] = max(0.2, 2 * effective[family, default: 0])
            case .less:
                if let weight = effective[family] { effective[family] = weight * 0.25 }
            }
        }
        let total = effective.values.reduce(0, +)
        let normalized = total > 0 ? effective.mapValues { $0 / total } : [:]
        weights = normalized
        orderedFamilies = GenreFamily.allCases.filter { normalized[$0] != nil }.sorted {
            let a = normalized[$0, default: 0]
            let b = normalized[$1, default: 0]
            return a == b ? $0.order < $1.order : a > b
        }
        // Coarse buckets keep Home from reloading after every classified song; only a changed picture counts.
        let coverageBucket = Int((summary.coverage * 10).rounded(.down))
        let top = orderedFamilies.prefix(Self.topFamilyCount).map { family in
            "\(family.rawValue):\(max(1, min(20, Int((normalized[family, default: 0] * 20).rounded()))))"
        }
        let adjusted = nudges.adjusted.map { "\($0.family.rawValue)=\($0.nudge.rawValue)" }
        requestKey = "genres-v1|\(isLearned ? "learned" : "unlearned")|coverage:\(coverageBucket)|" + (top + adjusted).joined(separator: "|")
    }

    var coverage: Double { summary.coverage }
    var topFamilies: [GenreFamily] { Array(orderedFamilies.prefix(Self.topFamilyCount)) }
    var topFamily: GenreFamily? { orderedFamilies.first }
    /// Mixes wait for real coverage; Home shelves use the softer term as soon as anything is classified.
    var qualifiesForMixBoost: Bool { isLearned && coverage >= Self.mixCoverageGate }

    func distribution(for track: Track) -> GenreDistribution? {
        guard let distribution = evidence[LyricsRequestKey(track)], distribution.isClassified else { return nil }
        return distribution
    }

    func dominantFamily(for track: Track) -> GenreFamily? {
        distribution(for: track)?.dominant
    }

    /// Weight of the candidate's dominant family relative to the strongest family; 0 without evidence.
    func affinity(for track: Track) -> Double {
        guard let family = dominantFamily(for: track), let top = weights.values.max(), top > 0 else { return 0 }
        return weights[family, default: 0] / top
    }

    func multiplier(for track: Track) -> Double {
        guard let family = dominantFamily(for: track) else { return 1 }
        if nudges[family] == .less { return 1 - Self.rankingWeight }
        return 1 + Self.rankingWeight * affinity(for: track)
    }

    /// Mix ranking: neutral until the coverage gate passes; then only top-three families (and Less) move.
    func mixMultiplier(for track: Track) -> Double {
        guard qualifiesForMixBoost, let family = dominantFamily(for: track) else { return 1 }
        guard topFamilies.contains(family) || nudges[family] == .less else { return 1 }
        return multiplier(for: track)
    }

    /// Station affinity: the strongest weight among the station's families, 0 when none is tagged or observed.
    func affinity(for families: [GenreFamily]) -> Double {
        families.map { weights[$0, default: 0] }.max() ?? 0
    }
}

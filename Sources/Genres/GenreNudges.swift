import Foundation

/// The three-way adjustment shared with the language tuner; genres reuse the same cases and titles.
typealias ListeningNudge = LanguageRecommendationNudge

/// Per-family More/Automatic/Less choices. Every family encodes as its own `genreNudges/<family>` leaf, so iCloud
/// sync treats each one as an independent register exactly like `languageNudges/hindi`.
struct GenreNudges: Equatable, Sendable {
    private var adjustments: [GenreFamily: ListeningNudge] = [:]

    init() { }

    init(_ adjustments: [GenreFamily: ListeningNudge]) {
        for (family, nudge) in adjustments { self[family] = nudge }
    }

    subscript(_ family: GenreFamily) -> ListeningNudge {
        get { adjustments[family] ?? .automatic }
        set {
            if newValue == .automatic { adjustments.removeValue(forKey: family) }
            else { adjustments[family] = newValue }
        }
    }

    var isAutomatic: Bool { adjustments.isEmpty }

    /// Families with a saved More or Less, in taxonomy order.
    var adjusted: [(family: GenreFamily, nudge: ListeningNudge)] {
        GenreFamily.allCases.compactMap { family in adjustments[family].map { (family, $0) } }
    }

    func families(with nudge: ListeningNudge) -> [GenreFamily] {
        GenreFamily.allCases.filter { self[$0] == nudge }
    }
}

extension GenreNudges: Codable {
    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: Key.self)
        // Unknown families and unreadable values fall back to Automatic; the sync layer's round trip refuses
        // remote values this decoder would rewrite, so leniency here cannot silently change another device's edit.
        for family in GenreFamily.allCases {
            guard let raw = try? values.decodeIfPresent(String.self, forKey: Key(stringValue: family.rawValue)),
                  let nudge = ListeningNudge(rawValue: raw) else { continue }
            self[family] = nudge
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        for family in GenreFamily.allCases {
            try container.encode(self[family].rawValue, forKey: Key(stringValue: family.rawValue))
        }
    }
}

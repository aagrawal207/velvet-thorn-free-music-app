import Foundation

enum RadioEra: String, CaseIterable, Hashable, Identifiable, Sendable {
    case anytime, older, newer

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var detail: String {
        switch self {
        case .anytime: "Starting songs from any year."
        case .older: "Starting songs released before 2000."
        case .newer: "Starting songs from releases dated 2015 or later."
        }
    }

    /// Appended to style queries. Wording narrows what a search returns; it never dates the songs it returns.
    var styleQuerySuffix: String {
        switch self {
        case .anytime: ""
        case .older: " before 2000"
        case .newer: " 2015 and later"
        }
    }

    func accepts(year: Int?, currentYear: Int = Calendar(identifier: .gregorian).component(.year, from: Date())) -> Bool {
        if self == .anytime { return true }
        guard currentYear >= 1900, let year, (1900...currentYear).contains(year) else { return false }
        return self == .older ? year < 2000 : year >= 2015
    }
}

/// An unsaved radio draft. Artist credits and recordings remain the catalog's shared models.
struct RadioConfiguration: Hashable, Sendable {
    static let maximumArtists = 4

    let id: UUID
    let station: RadioExperience
    var era: RadioEra
    var languages: Set<MusicLanguage>
    var artists: [ArtistCredit]

    init(station: RadioExperience, languages: Set<MusicLanguage> = Set(MusicLanguage.allCases), id: UUID = UUID()) {
        self.id = id
        self.station = station
        self.era = station.defaultEra
        self.languages = languages
        self.artists = []
    }

    static func artistKey(_ artist: ArtistCredit) -> String { SearchRelevance.normalize(artist.name) }

    static func defaultArtists(station: RadioExperience, languages: Set<MusicLanguage>) -> [ArtistCredit] {
        var seen = Set<String>()
        let scope = languages.isEmpty ? Set(MusicLanguage.allCases) : languages
        return (station.selection(for: scope)?.seeds ?? []).map(\.artist)
            .filter { !artistKey($0).isEmpty && seen.insert(artistKey($0)).inserted }
    }

    var validationMessage: String? {
        let count = Set(artists.map(Self.artistKey).filter { !$0.isEmpty }).count
        if count > Self.maximumArtists { return "Choose up to four artist hints." }
        return nil
    }

    func experience() -> RadioExperience {
        // Automatic drafts retain every cue; the radio engine applies the listening profile at startup.
        let automatic = languages.isEmpty || languages == Set(MusicLanguage.allCases)
        let variants = automatic ? station.variants : station.variants.filter { !$0.discoveryLanguages.isDisjoint(with: languages) }
        var seen = Set<String>()
        let chosen = Array(artists.filter { !Self.artistKey($0).isEmpty && seen.insert(Self.artistKey($0)).inserted }.prefix(Self.maximumArtists))
        return RadioExperience(id: "\(station.stationID).setup.\(id.uuidString)", title: station.title,
            description: station.description, symbol: station.symbol, group: station.group, variants: variants,
            queryTemplates: station.queryTemplates, tone: station.tone, discoveryRank: station.discoveryRank,
            defaultEra: era, sourceStationID: station.stationID, artistHints: chosen)
    }
}

struct RadioArtistResolution: Sendable {
    let artist: ArtistCredit
    let seeds: [RadioExperience.Seed]
    var error: String? = nil
}

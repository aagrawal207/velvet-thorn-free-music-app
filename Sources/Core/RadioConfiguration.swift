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

    init(station: RadioExperience, languages: Set<MusicLanguage>, id: UUID = UUID()) {
        self.id = id
        self.station = station
        self.era = station.defaultEra
        let matching = station.discoveryLanguages.intersection(languages)
        self.languages = matching.isEmpty ? languages : matching
        self.artists = []
    }

    static func artistKey(_ artist: ArtistCredit) -> String { SearchRelevance.normalize(artist.name) }

    static func defaultArtists(station: RadioExperience, languages: Set<MusicLanguage>) -> [ArtistCredit] {
        var seen = Set<String>()
        return (station.selection(for: languages)?.seeds ?? []).map(\.artist)
            .filter { !artistKey($0).isEmpty && seen.insert(artistKey($0)).inserted }
    }

    var validationMessage: String? {
        if languages.isEmpty { return "Choose at least one language." }
        if station.selection(for: languages) == nil {
            let supported = MusicLanguage.allCases.filter { station.selection(for: [$0]) != nil }.map(\.title).joined(separator: " or ")
            return supported.isEmpty ? "This station has no supported languages." : "Choose \(supported) for this station."
        }
        let count = Set(artists.map(Self.artistKey).filter { !$0.isEmpty }).count
        if count > Self.maximumArtists { return "Choose up to four artist hints." }
        return nil
    }

    func experience() -> RadioExperience {
        let audience = station.discoveryLanguages.intersection(languages)
        let variants = station.variants.filter { !$0.discoveryLanguages.isDisjoint(with: audience) }
        var seen = Set<String>()
        let chosen = Array(artists.filter { !Self.artistKey($0).isEmpty && seen.insert(Self.artistKey($0)).inserted }.prefix(Self.maximumArtists))
        return RadioExperience(id: "\(station.stationID).setup.\(id.uuidString)", title: station.title,
            description: station.description, symbol: station.symbol,
            discoveryLanguages: audience, variants: variants, tone: station.tone, discoveryRank: station.discoveryRank,
            defaultEra: era, sourceStationID: station.stationID, artistHints: chosen)
    }
}

struct RadioArtistResolution: Sendable {
    let artist: ArtistCredit
    let seeds: [RadioExperience.Seed]
    var error: String? = nil
}

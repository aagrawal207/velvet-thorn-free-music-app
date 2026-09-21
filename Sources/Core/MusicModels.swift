import Foundation

enum MusicLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case hindi, english
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var subtitle: String { self == .hindi ? "दिल से सुनो" : "Find your next favorite" }
}

/// One credited artist. Provider-linked credits carry the artist page id; artists parsed out of a title
/// ("feat. …") have none and are resolved by name when opened.
struct ArtistCredit: Codable, Hashable, Sendable {
    var name: String
    var id: String?

    init(name: String, id: String? = nil) {
        self.name = name
        self.id = id
    }

    var collection: MusicCollection? {
        guard let id, !id.isEmpty else { return nil }
        return MusicCollection(id: id, title: name, kind: .artist)
    }

    /// Artists named in a title's feature clause: "(feat. A & B)", "[ft. A]", "(with A)", or a trailing "feat. A".
    static func featured(inTitle title: String) -> [ArtistCredit] {
        let bracketed = #"[(\[]\s*(?:feat\.?|ft\.?|featuring|with)\s+([^)\]]+)[)\]]"#
        let trailing = #"\s(?:feat\.?|ft\.?|featuring)\s+([^()\[\]]+)$"#
        var clauses: [String] = []
        for pattern in [bracketed, trailing] {
            guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            let matches = expression.matches(in: title, range: NSRange(title.startIndex..., in: title))
            for match in matches {
                if let range = Range(match.range(at: 1), in: title) { clauses.append(String(title[range])) }
            }
            if !clauses.isEmpty { break }
        }
        var seen = Set<String>()
        return clauses.flatMap { clause -> [String] in
            let separated = clause.replacingOccurrences(of: #"\s+(?:and|x|X)\s+"#, with: ",", options: .regularExpression)
                .replacingOccurrences(of: "&", with: ",").replacingOccurrences(of: "/", with: ",")
            return separated.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        }.filter { name in
            !name.isEmpty && name.count <= 80 && name.contains(where: \.isLetter) && seen.insert(name.lowercased()).inserted
        }.map { ArtistCredit(name: $0) }
    }
}

struct Track: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var title: String
    /// Credited artists in provider order; the first is the primary artist.
    var credits: [ArtistCredit]
    var albumTitle: String?
    var albumID: String?
    var duration: TimeInterval?
    var artworkURL: URL?
    var language: MusicLanguage?
    var isExplicit: Bool
    var isAudioRecording: Bool?
    /// Worldwide plays as reported by the provider at parse time; nil when the row carried no count.
    var playCount: Int64?

    init(id: String, title: String, credits: [ArtistCredit], albumTitle: String? = nil,
         albumID: String? = nil, duration: TimeInterval? = nil,
         artworkURL: URL? = nil, language: MusicLanguage? = nil, isExplicit: Bool = false,
         isAudioRecording: Bool? = nil, playCount: Int64? = nil) {
        self.id = id
        self.title = title
        self.credits = credits
        self.albumTitle = albumTitle
        self.albumID = albumID
        self.duration = duration
        self.artworkURL = artworkURL
        self.language = language
        self.isExplicit = isExplicit
        self.isAudioRecording = isAudioRecording
        self.playCount = playCount
    }

    /// Name-only credits; `artistID` links the first name when the provider identified it.
    init(id: String, title: String, artists: [String] = [], albumTitle: String? = nil,
         albumID: String? = nil, artistID: String? = nil, duration: TimeInterval? = nil,
         artworkURL: URL? = nil, language: MusicLanguage? = nil, isExplicit: Bool = false,
         isAudioRecording: Bool? = nil, playCount: Int64? = nil) {
        self.init(id: id, title: title, credits: Self.credits(names: artists, primaryID: artistID),
                  albumTitle: albumTitle, albumID: albumID, duration: duration, artworkURL: artworkURL,
                  language: language, isExplicit: isExplicit, isAudioRecording: isAudioRecording, playCount: playCount)
    }

    /// Credited names in order. Assigning keeps the ids of names that stay.
    var artists: [String] {
        get { credits.map(\.name) }
        set {
            let known = credits
            credits = newValue.map { name in
                ArtistCredit(name: name, id: known.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.id)
            }
        }
    }

    /// The primary artist's page id: the first linked credit.
    var artistID: String? { credits.first { $0.id != nil }?.id }

    var artistName: String { credits.isEmpty ? "Unknown artist" : credits.map(\.name).joined(separator: ", ") }
    var shareURL: URL? { URL(string: "https://music.youtube.com/watch?v=\(id)") }
    /// Album page destination when the provider identified the release.
    var albumCollection: MusicCollection? {
        guard let albumID, !albumID.isEmpty else { return nil }
        return MusicCollection(id: albumID, title: albumTitle ?? "Album", subtitle: artistName, artworkURL: artworkURL, kind: .album)
    }
    /// The primary artist's page.
    var artistCollection: MusicCollection? {
        credits.first { $0.id != nil }?.collection
    }
    /// Everyone to offer under "Go to artist": provider credits plus artists a title names as features,
    /// so tracks stored before feature parsing still list them.
    var allCredits: [ArtistCredit] {
        var seen = Set(credits.map { $0.name.lowercased() })
        return credits + ArtistCredit.featured(inTitle: title).filter { seen.insert($0.name.lowercased()).inserted }
    }

    /// Fills credits, album, and ids this track lacks from another description of the same recording.
    mutating func adoptMissingMetadata(from other: Track) {
        if credits.isEmpty {
            credits = other.credits
        } else {
            credits = credits.map { credit in
                guard credit.id == nil else { return credit }
                var filled = credit
                filled.id = other.credits.first { $0.name.caseInsensitiveCompare(credit.name) == .orderedSame }?.id
                return filled
            }
        }
        albumTitle = albumTitle ?? other.albumTitle
        albumID = albumID ?? other.albumID
        duration = duration ?? other.duration
        playCount = playCount ?? other.playCount
    }

    private static func credits(names: [String], primaryID: String?) -> [ArtistCredit] {
        names.enumerated().map { ArtistCredit(name: $1, id: $0 == 0 ? primaryID : nil) }
    }

    // Stored tracks predate `credits`; they carry `artists` and `artistID` instead.
    private enum CodingKeys: String, CodingKey {
        case id, title, credits, artists, artistID, albumTitle, albumID, duration, artworkURL, language
        case isExplicit, isAudioRecording, playCount
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        if let stored = try container.decodeIfPresent([ArtistCredit].self, forKey: .credits) {
            credits = stored
        } else {
            credits = Self.credits(names: try container.decodeIfPresent([String].self, forKey: .artists) ?? [],
                                   primaryID: try container.decodeIfPresent(String.self, forKey: .artistID))
        }
        albumTitle = try container.decodeIfPresent(String.self, forKey: .albumTitle)
        albumID = try container.decodeIfPresent(String.self, forKey: .albumID)
        duration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration)
        artworkURL = try container.decodeIfPresent(URL.self, forKey: .artworkURL)
        language = try container.decodeIfPresent(MusicLanguage.self, forKey: .language)
        isExplicit = try container.decodeIfPresent(Bool.self, forKey: .isExplicit) ?? false
        isAudioRecording = try container.decodeIfPresent(Bool.self, forKey: .isAudioRecording)
        playCount = try container.decodeIfPresent(Int64.self, forKey: .playCount)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(credits, forKey: .credits)
        try container.encodeIfPresent(albumTitle, forKey: .albumTitle)
        try container.encodeIfPresent(albumID, forKey: .albumID)
        try container.encodeIfPresent(duration, forKey: .duration)
        try container.encodeIfPresent(artworkURL, forKey: .artworkURL)
        try container.encodeIfPresent(language, forKey: .language)
        try container.encode(isExplicit, forKey: .isExplicit)
        try container.encodeIfPresent(isAudioRecording, forKey: .isAudioRecording)
        try container.encodeIfPresent(playCount, forKey: .playCount)
    }
}

/// Title comparisons that treat remixes, edits, live takes, and feature clauses as versions of one song.
enum SongTitle {
    /// "Six Days (Remix) (feat. Mos Def)", "Six Days - Radio Edit", and "Six Days" all reduce to "six days".
    static func core(_ title: String) -> String {
        var text = title.replacingOccurrences(of: #"[(\[][^)\]]*[)\]]"#, with: " ", options: .regularExpression)
        if let dash = text.range(of: #"\s[-–—|]\s"#, options: .regularExpression) { text = String(text[..<dash.lowerBound]) }
        text = text.replacingOccurrences(of: #"(?i)\s(?:feat\.?|ft\.?|featuring)\s.*$"#, with: "", options: .regularExpression)
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                  locale: Locale(identifier: "en_US_POSIX"))
        let spaced = String(folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " })
        var tokens = spaced.split(separator: " ").map(String.init)
        while let last = tokens.last, tokens.count > 1, versionWords.contains(last) { tokens.removeLast() }
        return tokens.joined(separator: " ")
    }

    static func isVersion(_ title: String, of other: String) -> Bool {
        let left = core(title)
        return !left.isEmpty && left == core(other)
    }

    private static let versionWords: Set<String> = [
        "remix", "mix", "edit", "version", "live", "acoustic", "instrumental", "remaster", "remastered", "radio",
        "extended", "original", "unplugged", "reprise", "cover", "karaoke", "slowed", "reverb", "lofi", "sped", "up",
        "demo", "mono", "stereo", "single", "album", "explicit", "clean",
    ]
}

enum CollectionKind: String, Codable, Sendable { case album, playlist, artist, mix }

struct MusicCollection: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var title: String
    var subtitle: String
    var artworkURL: URL?
    var kind: CollectionKind
    var language: MusicLanguage?
    var tracks: [Track]

    init(id: String, title: String, subtitle: String = "", artworkURL: URL? = nil,
         kind: CollectionKind = .playlist, language: MusicLanguage? = nil, tracks: [Track] = []) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.artworkURL = artworkURL
        self.kind = kind
        self.language = language
        self.tracks = tracks
    }
}

enum SearchFilter: String, CaseIterable, Identifiable, Sendable {
    case songs, albums, artists, playlists
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct CatalogPage: Sendable {
    var tracks: [Track] = []
    var collections: [MusicCollection] = []
    var continuation: String?
    var title: String?
    /// Provider spelling correction that produced these results, shown as "Showing results for …".
    var correctedQuery: String?
    /// The artist a song search was resolved to when the query names an artist; its songs lead the results.
    var featuredArtist: MusicCollection?
    /// The artists credited on an album page header; empty for searches, playlists, and artist pages.
    var credits: [ArtistCredit] = []
}

struct ArtistPage: Sendable {
    struct MonthlyAudience: Equatable, Sendable {
        enum Kind: String, Sendable { case audience, listeners }
        enum Source: String, Sendable { case headerCount, headerDescription, pageDescription }

        let value: Int64
        let label: String
        let kind: Kind
        let source: Source
    }

    var id: String
    var name: String
    var artworkURL: URL?
    var topSongs: [Track]
    /// Albums, singles, and EPs as listed on the artist page, newest first when the provider orders them.
    var releases: [MusicCollection]
    var relatedArtists: [MusicCollection]
    /// Provider-labelled monthly audience is separate from subscribers and lifetime recording plays.
    var monthlyAudience: MonthlyAudience?

    init(id: String, name: String, artworkURL: URL? = nil, topSongs: [Track] = [],
         releases: [MusicCollection] = [], relatedArtists: [MusicCollection] = [], monthlyAudience: MonthlyAudience? = nil) {
        self.id = id
        self.name = name
        self.artworkURL = artworkURL
        self.topSongs = topSongs
        self.releases = releases
        self.relatedArtists = relatedArtists
        self.monthlyAudience = monthlyAudience
    }
}

struct DiscoverySection: Codable, Identifiable, Sendable {
    var id: String
    var title: String
    var subtitle: String
    var language: MusicLanguage?
    var tracks: [Track]
    var collections: [MusicCollection]

    init(id: String, title: String, subtitle: String = "", language: MusicLanguage? = nil,
         tracks: [Track] = [], collections: [MusicCollection] = []) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.language = language
        self.tracks = tracks
        self.collections = collections
    }
}

struct ChartEntry: Codable, Identifiable, Sendable {
    var rank: Int
    var track: Track
    var views: Int64?
    var previousRank: Int?
    var id: String { track.id }
}

struct ChartSnapshot: Codable, Identifiable, Sendable {
    var id: String
    var title: String
    var subtitle: String
    var source: String
    var language: MusicLanguage
    var periodStart: Date?
    var periodEnd: Date?
    var fetchedAt: Date
    var entries: [ChartEntry]
}

enum MusicServiceError: LocalizedError, Sendable {
    case invalidResponse
    case unavailable(String)
    case network(String)
    case rateLimited

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "The music service returned something we couldn’t read. Please try again."
        case .unavailable(let message): message
        case .network(let message): message
        case .rateLimited: "The music service is busy. Give it a moment and try again."
        }
    }
}

enum PlayCountText {
    /// "1.2B plays", "845K plays", "12 plays". Nil below 1 so unknown and zero never show as popularity.
    static func plays(_ count: Int64?) -> String? {
        guard let count, count >= 1 else { return nil }
        let number = count.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)).locale(Locale(identifier: "en_US")))
        return "\(number) plays"
    }

    /// Parses provider text such as "1.2B plays", "845K views", or "12,345 plays".
    static func parse(_ text: String) -> Int64? {
        let lowered = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard lowered.hasSuffix(" plays") || lowered.hasSuffix(" views") || lowered.hasSuffix(" play") || lowered.hasSuffix(" view") else { return nil }
        return parseNumber(lowered.components(separatedBy: " ").first ?? "")
    }

    static func parseNumber(_ text: String) -> Int64? {
        var number = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        var multiplier: Double = 1
        if let suffix = number.last, "kmbt".contains(suffix) {
            multiplier = ["k": 1e3, "m": 1e6, "b": 1e9, "t": 1e12][suffix] ?? 1
            number.removeLast()
        }
        number = number.replacingOccurrences(of: ",", with: "")
        guard let value = Double(number), value.isFinite, value >= 0 else { return nil }
        let total = value * multiplier
        guard total < Double(Int64.max) else { return nil }
        return Int64(total.rounded())
    }
}

enum TimeText {
    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let whole = Int(min(seconds, 359_999))
        if whole >= 3600 { return String(format: "%d:%02d:%02d", whole / 3600, (whole % 3600) / 60, whole % 60) }
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}

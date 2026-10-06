import Foundation

/// Credits, release facts and provider counters for one recording, merged from bounded sources.
/// Performers stay the track's own credits; nothing here replaces `Track`.
struct TrackDetails: Codable, Equatable, Sendable {
    enum CreditRole: Codable, Hashable, Sendable {
        case composer, lyricist, producer, arranger, musicPublisher, label
        case mixingEngineer, masteringEngineer, recordingEngineer, vocals
        case other(String)

        var title: String {
            switch self {
            case .composer: "Composer"
            case .lyricist: "Lyricist"
            case .producer: "Producer"
            case .arranger: "Arranger"
            case .musicPublisher: "Music publisher"
            case .label: "Label"
            case .mixingEngineer: "Mixing engineer"
            case .masteringEngineer: "Mastering engineer"
            case .recordingEngineer: "Recording engineer"
            case .vocals: "Vocals"
            case .other(let role): role
            }
        }

        /// Display order: writing credits first, then production, then everything else alphabetically.
        var sortRank: Int {
            switch self {
            case .composer: 0
            case .lyricist: 1
            case .arranger: 2
            case .producer: 3
            case .vocals: 4
            case .recordingEngineer: 5
            case .mixingEngineer: 6
            case .masteringEngineer: 7
            case .musicPublisher: 8
            case .label: 9
            case .other: 10
            }
        }

        /// Maps a provider role wording ("Composer  Lyricist", "Mixer", "writer") to a role; unknown wording is kept.
        static func from(providerRole raw: String) -> [CreditRole] {
            let role = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !role.isEmpty else { return [] }
            switch role.lowercased() {
            case "composer": return [.composer]
            case "lyricist": return [.lyricist]
            case "composer lyricist", "composer-lyricist", "composer/lyricist": return [.composer, .lyricist]
            case "producer": return [.producer]
            case "arranger": return [.arranger]
            case "music publisher", "publisher": return [.musicPublisher]
            case "label", "record label": return [.label]
            case "mixing engineer", "mixer", "mix engineer": return [.mixingEngineer]
            case "mastering engineer": return [.masteringEngineer]
            case "recording engineer": return [.recordingEngineer]
            case "vocals", "vocal", "vocalist", "lead vocalist", "lead vocals", "singer": return [.vocals]
            default: return [.other(Self.titleCased(role))]
            }
        }

        private static func titleCased(_ role: String) -> String {
            let words = role.split(separator: " ").map { word -> String in
                guard let first = word.first, first.isLowercase else { return String(word) }
                return first.uppercased() + word.dropFirst()
            }
            return String(words.joined(separator: " ").prefix(60))
        }
    }

    struct Credit: Codable, Equatable, Sendable {
        var role: CreditRole
        var names: [String]
    }

    enum Source: String, Codable, Hashable, Sendable {
        case youTubeDescription, youTubeDataAPI, youTubePlayer, musicBrainz
    }

    static let maximumDescriptionBytes = 16 * 1_024
    static let maximumNames = 40

    var recordingID: String
    var title: String
    var performers: [ArtistCredit]
    var credits: [Credit]
    var albumTitle: String?
    var releaseDate: Date?
    /// The provider's own wording ("2013-04-01"), kept because partial dates cannot become a `Date`.
    var releaseDateText: String?
    var phonogramLine: String?
    var copyrightLine: String?
    var channelTitle: String?
    var publishedAt: Date?
    var description: String?
    var viewCount: Int64?
    var isrc: String?
    var musicBrainzRecordingID: String?
    var sources: Set<Source>
    var fetchedAt: Date

    init(track: Track, fetchedAt: Date = Date()) {
        recordingID = track.id
        title = track.title
        performers = track.allCredits
        credits = []
        albumTitle = track.albumTitle
        sources = []
        self.fetchedAt = fetchedAt
    }

    /// Credits shown as rows; the label belongs to the release section.
    var displayCredits: [Credit] {
        credits.filter { $0.role != .label && !$0.names.isEmpty }
            .sorted { ($0.role.sortRank, $0.role.title) < ($1.role.sortRank, $1.role.title) }
    }

    var labelNames: [String] { credits.first { $0.role == .label }?.names ?? [] }

    /// True when at least one fact beyond the track's own metadata was found.
    var hasContent: Bool {
        !credits.isEmpty || releaseDate != nil || releaseDateText != nil || phonogramLine != nil || copyrightLine != nil
            || description != nil || viewCount != nil || isrc != nil || musicBrainzRecordingID != nil || channelTitle != nil
    }

    var creditSource: Source? {
        if sources.contains(.youTubeDescription), credits.contains(where: { $0.role != .label }) { return .youTubeDescription }
        if sources.contains(.musicBrainz), credits.contains(where: { $0.role != .label }) { return .musicBrainz }
        return nil
    }

    /// Adds names under a role, keeping order and dropping case-insensitive duplicates within the role.
    mutating func addCredit(_ role: CreditRole, names newNames: [String]) {
        Self.add(role, names: newNames, to: &credits)
    }

    static func add(_ role: CreditRole, names newNames: [String], to credits: inout [Credit]) {
        let cleaned = newNames.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= 120 }
        guard !cleaned.isEmpty else { return }
        if let index = credits.firstIndex(where: { $0.role == role }) {
            var seen = Set(credits[index].names.map { $0.lowercased() })
            let additions = cleaned.filter { seen.insert($0.lowercased()).inserted }
            credits[index].names = Array((credits[index].names + additions).prefix(maximumNames))
        } else {
            var seen = Set<String>()
            credits.append(Credit(role: role, names: Array(cleaned.filter { seen.insert($0.lowercased()).inserted }.prefix(maximumNames))))
        }
    }

    /// Fills only the gaps: existing credits, dates and identifiers win over the incoming ones.
    mutating func fillMissing(from other: TrackDetails) {
        for credit in other.credits where !credits.contains(where: { $0.role == credit.role }) {
            addCredit(credit.role, names: credit.names)
        }
        if albumTitle == nil { albumTitle = other.albumTitle }
        if releaseDate == nil, releaseDateText == nil {
            releaseDate = other.releaseDate
            releaseDateText = other.releaseDateText
        }
        phonogramLine = phonogramLine ?? other.phonogramLine
        copyrightLine = copyrightLine ?? other.copyrightLine
        channelTitle = channelTitle ?? other.channelTitle
        publishedAt = publishedAt ?? other.publishedAt
        description = description ?? other.description
        viewCount = viewCount ?? other.viewCount
        isrc = isrc ?? other.isrc
        musicBrainzRecordingID = musicBrainzRecordingID ?? other.musicBrainzRecordingID
        sources.formUnion(other.sources)
    }

    static func trimmedDescription(_ text: String?) -> String? {
        guard let text else { return nil }
        let normalised = text.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalised.isEmpty else { return nil }
        guard normalised.utf8.count > maximumDescriptionBytes else { return normalised }
        var bytes = 0
        var scalars = String.UnicodeScalarView()
        for scalar in normalised.unicodeScalars {
            bytes += scalar.utf8.count
            if bytes > maximumDescriptionBytes { break }
            scalars.append(scalar)
        }
        return String(scalars)
    }

    /// Provider dates arrive as "2013-04-01" or full ISO 8601 stamps; anything else stays text only.
    static func date(from text: String?) -> Date? {
        guard let text = CatalogText.clean(text), text.utf8.count <= 40 else { return nil }
        if text.count == 10 {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.date(from: text)
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: text) { return date }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: text)
    }
}

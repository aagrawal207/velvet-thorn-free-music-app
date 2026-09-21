import Foundation

struct LRCLIBRecord: Decodable, Sendable {
    var id: Int
    var trackName: String
    var artistName: String
    var albumName: String?
    var duration: TimeInterval?
    var instrumental: Bool
    var plainLyrics: String?
    var syncedLyrics: String?

    init(id: Int, trackName: String, artistName: String, albumName: String? = nil,
         duration: TimeInterval? = nil, instrumental: Bool = false,
         plainLyrics: String? = nil, syncedLyrics: String? = nil) {
        self.id = id
        self.trackName = trackName
        self.artistName = artistName
        self.albumName = albumName
        self.duration = duration
        self.instrumental = instrumental
        self.plainLyrics = plainLyrics
        self.syncedLyrics = syncedLyrics
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, trackName, artistName, albumName, duration, instrumental, plainLyrics, syncedLyrics
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(Int.self, forKey: .id)
        trackName = try values.decodeIfPresent(String.self, forKey: .trackName)
            ?? values.decode(String.self, forKey: .name)
        artistName = try values.decode(String.self, forKey: .artistName)
        albumName = try values.decodeIfPresent(String.self, forKey: .albumName)
        duration = try values.decodeIfPresent(Double.self, forKey: .duration)
        instrumental = try values.decodeIfPresent(Bool.self, forKey: .instrumental) ?? false
        plainLyrics = try values.decodeIfPresent(String.self, forKey: .plainLyrics)
        syncedLyrics = try values.decodeIfPresent(String.self, forKey: .syncedLyrics)
    }

    var hasContent: Bool {
        instrumental || !(plainLyrics?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            || !(syncedLyrics?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }
}

enum LyricsMatcher {
    struct Match: Sendable {
        let record: LRCLIBRecord
        let score: Double
        let durationDifference: TimeInterval?
        let isExact: Bool
        let allowsTiming: Bool
    }

    struct RecordingKey: Hashable, Sendable {
        let title: String
        let artists: [String]
        let allowsPartialArtistCredit: Bool
        let album: String
        let duration: TimeInterval?

        init(_ track: Track) {
            title = normalized(cleanTitle(track.title, artists: track.artists))
            artists = artistParts(track.artists).map(normalized).sorted()
            allowsPartialArtistCredit = track.artists.count > 1
            album = normalized(track.albumTitle ?? "")
            duration = validDuration(track.duration)
        }
    }

    static func bestMatch(in records: [LRCLIBRecord], for track: Track) -> Match? {
        var seen: Set<Int> = []
        let ranked = records.filter { seen.insert($0.id).inserted }
            .compactMap { evaluate($0, for: track) }
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.record.id < $1.record.id
            }
        guard let best = ranked.first else { return nil }
        for competitor in ranked.dropFirst() where best.score - competitor.score < 4 {
            if !equivalentLyrics(best.record, competitor.record) { return nil }
        }
        return best
    }

    static func evaluate(_ record: LRCLIBRecord, for track: Track) -> Match? {
        guard record.id > 0, record.hasContent else { return nil }
        let title = cleanTitle(track.title, artists: track.artists)
        let candidateTitle = cleanTitle(record.trackName, artists: [record.artistName])
        let requestedVersions = versions(title: title, album: track.albumTitle)
        let candidateVersions = versions(title: candidateTitle, album: record.albumName)
        guard requestedVersions == candidateVersions else { return nil }
        let titleScore = textAgreement(title, candidateTitle, allowRomanization: requestedVersions.isEmpty)
        guard titleScore >= 0.94 else { return nil }
        let artistScore = artistAgreement(track.artists, record.artistName)
        guard artistScore >= 0.85 else { return nil }

        let album = usefulAlbum(track.albumTitle)
        let candidateAlbum = usefulAlbum(record.albumName)
        let albumMatches = album.flatMap { expected in
            candidateAlbum.map { textAgreement(expected, $0, allowRomanization: true) >= 0.98 }
        } ?? false
        let duration = validDuration(track.duration)
        let candidateDuration = validDuration(record.duration)
        let difference: TimeInterval?
        let durationScore: Double

        if let duration, let candidateDuration {
            let delta = abs(duration - candidateDuration)
            guard delta <= searchTolerance(for: duration) else { return nil }
            if delta > 2 {
                guard albumMatches, titleScore >= 0.99, artistScore == 1 else { return nil }
            }
            if artistScore < 1 || titleScore < 0.98 {
                guard delta <= 2, albumMatches || titleScore >= 0.99 else { return nil }
            }
            difference = delta
            durationScore = delta <= 2 ? 20 - delta : 12 - delta
        } else {
            guard albumMatches, titleScore >= 0.99, artistScore == 1 else { return nil }
            difference = nil
            durationScore = 0
        }

        let albumScore: Double = albumMatches ? 5 : (album == nil ? 0 : -2)
        let badAlbumPenalty: Double = record.albumName != nil && candidateAlbum == nil ? 3 : 0
        let contentScore: Double = record.syncedLyrics?.isEmpty == false ? 0.5 : 0
        return Match(record: record,
                     score: titleScore * 50 + artistScore * 25 + durationScore + albumScore
                        - badAlbumPenalty + contentScore,
                     durationDifference: difference,
                     isExact: titleScore >= 0.99 && artistScore == 1 && (difference ?? .infinity) <= 2
                        && (album == nil || albumMatches),
                     allowsTiming: difference != nil)
    }

    static func searchTolerance(for duration: TimeInterval) -> TimeInterval {
        min(6, max(3, duration * 0.015))
    }

    static func validDuration(_ duration: TimeInterval?) -> TimeInterval? {
        guard let duration, duration.isFinite, duration > 0, duration <= 86_400 else { return nil }
        return duration
    }

    static func usefulAlbum(_ album: String?) -> String? {
        guard let album else { return nil }
        let value = album.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = normalized(value)
        guard !key.isEmpty, key != "unknown album",
              !matches(#"\d\s*[kmb]?\s*(plays|views)\b"#, value) else { return nil }
        return value
    }

    static func cleanTitle(_ title: String, artists: [String] = []) -> String {
        var value = replacing(#"(?i)[\(\[]\s*from\s+[\"“].*?[\"”]\s*[\)\]]"#, in: title, with: " ")
        let presentation = #"(?i)\b(?:official\s+(?:(?:4k|hd|hq|1080p|720p)\s+)?(?:(?:music|lyric|lyrics)\s+)?(?:video|audio|visuali[sz]er)|official\s+lyrics?|lyric(?:s)?\s+video|full\s+(?:music\s+)?(?:video|audio))\b(?:\s+(?:hd|hq|4k|1080p|720p))?(?=\s*(?:[\)\]\|]|$))"#
        value = replacing(presentation, in: value, with: " ")
        value = replacing(#"(?i)[\(\[]\s*(?:lyrics?|hd|hq|4k|1080p|720p|official)\s*[\)\]]"#, in: value, with: " ")
        value = replacing(#"[\(\[]\s*[\)\]]"#, in: value, with: " ")
        let separators = CharacterSet(charactersIn: " |–—-").union(.whitespacesAndNewlines)
        let artistKeys = Set((artists + [artists.joined(separator: ", ")]).map(normalized).filter { !$0.isEmpty })
        for separator in [" | ", " - ", " – ", " — "] {
            var parts = value.components(separatedBy: separator)
            if parts.count > 1, artistKeys.contains(normalized(parts[0])) { parts.removeFirst() }
            if parts.count > 1, artistKeys.contains(normalized(parts[parts.count - 1])) { parts.removeLast() }
            value = parts.joined(separator: separator)
        }
        value = replacing(presentation, in: value, with: " ")
        value = value.trimmingCharacters(in: separators)
        value = replacing(#"\s+"#, in: value, with: " ")
        return normalized(value).isEmpty ? title.trimmingCharacters(in: .whitespacesAndNewlines) : value
    }

    static func artistParts(_ artists: [String]) -> [String] {
        var seen: Set<String> = []
        return artists.flatMap {
            replacing(#"(?i)\s+(?:feat\.?|ft\.?|featuring|and)\s+|\s*[,;&]\s*"#, in: $0, with: "\u{001F}")
                .components(separatedBy: "\u{001F}")
        }.map {
            replacing(#"(?i)\s*-\s*topic$"#, in: $0, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter {
            let key = normalized($0)
            return !key.isEmpty && key != "unknown artist" && seen.insert(key).inserted
        }
    }

    static func normalized(_ text: String) -> String {
        let folded = text.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let allowed = CharacterSet.alphanumerics.union(.nonBaseCharacters)
        let scalars = folded.unicodeScalars.map { allowed.contains($0) ? String($0) : " " }.joined()
        let result = scalars.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if !result.isEmpty { return result }
        return folded.unicodeScalars.filter { CharacterSet.symbols.contains($0) }.map(String.init).joined()
    }

    static func romanized(_ text: String) -> String? {
        guard let latin = text.applyingTransform(.toLatin, reverse: false) else { return nil }
        let result = normalized(latin.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX")))
        return result.isEmpty ? nil : result
    }

    private static func artistAgreement(_ artists: [String], _ candidate: String) -> Double {
        let expected = artistParts(artists)
        let actual = artistParts([candidate])
        guard !expected.isEmpty, !actual.isEmpty else { return 0 }
        var matched: Set<Int> = []
        for name in actual {
            guard let index = expected.indices.first(where: {
                !matched.contains($0) && textAgreement(expected[$0], name, allowRomanization: true) >= 0.98
            }) else { return 0 }
            matched.insert(index)
        }
        if matched.count == expected.count { return 1 }
        // A structured collaboration may be credited to fewer singers; a band's name may not.
        return artists.count > 1 && matched.count * 2 >= expected.count ? 0.86 : 0
    }

    private static func textAgreement(_ lhs: String, _ rhs: String, allowRomanization: Bool) -> Double {
        let left = normalized(lhs)
        let right = normalized(rhs)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        if left == right { return 1 }
        let leftLatin = isLatin(left)
        let rightLatin = isLatin(right)
        guard leftLatin || rightLatin, let a = romanized(left), let b = romanized(right) else { return 0 }
        if a == b { return 0.99 }
        guard allowRomanization, leftLatin != rightLatin, a.count <= 160, b.count <= 160,
              a.split(separator: " ").count >= 2, b.split(separator: " ").count >= 2 else { return 0 }
        return editSimilarity(a, b) >= 0.88 ? 0.94 : 0
    }

    private static func isLatin(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy {
            !CharacterSet.letters.contains($0) || $0.value < 0x0250 || (0x1E00...0x1EFF).contains($0.value)
        }
    }

    private static func editSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let a = Array(lhs)
        let b = Array(rhs)
        var previous = Array(0...b.count)
        for (i, character) in a.enumerated() {
            var row = [i + 1] + Array(repeating: 0, count: b.count)
            for j in b.indices {
                row[j + 1] = min(row[j] + 1, previous[j + 1] + 1,
                                 previous[j] + (character == b[j] ? 0 : 1))
            }
            previous = row
        }
        return 1 - Double(previous[b.count]) / Double(max(a.count, b.count, 1))
    }

    private static func versions(title: String, album: String?) -> Set<String> {
        let value = normalized(title + " " + (usefulAlbum(album) ?? ""))
        let patterns: [(String, String)] = [
            ("live", #"\blive\b"#), ("remix", #"\b(?:remix|remixed|mix)\b"#),
            ("acoustic", #"\b(?:acoustic|unplugged)\b"#), ("slowed", #"\bslowed\b"#),
            ("sped-up", #"\b(?:sped|speed)\s+up\b"#), ("reverb", #"\breverb\b"#),
            ("instrumental", #"\binstrumental\b"#), ("karaoke", #"\bkaraoke\b"#),
            ("cover", #"\bcover\b"#), ("remaster", #"\bremaster(?:ed)?\b"#),
            ("edit", #"\bedit\b"#), ("extended", #"\bextended\b"#), ("demo", #"\bdemo\b"#),
            ("reprise", #"\breprise\b"#), ("mono", #"\bmono\b"#), ("stereo", #"\bstereo\b"#),
            ("nightcore", #"\bnightcore\b"#), ("version", #"\bversion\b"#),
            ("clean", #"\bclean\b"#), ("explicit", #"\bexplicit\b"#)
        ]
        return Set(patterns.compactMap { matches($0.1, value) ? $0.0 : nil })
    }

    private static func equivalentLyrics(_ lhs: LRCLIBRecord, _ rhs: LRCLIBRecord) -> Bool {
        if lhs.instrumental || rhs.instrumental { return lhs.instrumental && rhs.instrumental }
        func clean(_ value: String?) -> String? {
            guard let value else { return nil }
            let result = value.replacingOccurrences(of: "\r\n", with: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return result.isEmpty ? nil : result
        }
        if let left = clean(lhs.syncedLyrics), let right = clean(rhs.syncedLyrics) { return left == right }
        if let left = clean(lhs.plainLyrics), let right = clean(rhs.plainLyrics) { return left == right }
        return false
    }

    private static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func replacing(_ pattern: String, in text: String, with replacement: String) -> String {
        text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }
}

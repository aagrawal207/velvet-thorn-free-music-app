import Foundation

// Recording-language evidence is separate from MusicLanguage, which controls Home discovery preferences.
// Adding a lyrics language here does not widen discovery or label an artist's other recordings.
enum ArtistSongLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case bengali = "bn", english = "en", hindi = "hi", tamil = "ta", telugu = "te"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bengali: "Bengali"
        case .english: "English"
        case .hindi: "Hindi"
        case .tamil: "Tamil"
        case .telugu: "Telugu"
        }
    }
}

enum ArtistSongLanguageResult: Codable, Hashable, Sendable {
    enum Source: Codable, Hashable, Sendable {
        case recordingMetadata, youTubeAudioLanguage, matchedLyrics, linkedLyrics, lyricsScript, titleLabel, titleScript, userOverride
        case musicBrainzWork(recordingID: String, workID: String)

        var title: String {
            switch self {
            case .recordingMetadata: "Recording metadata"
            case .youTubeAudioLanguage: "YouTube audio language"
            case .matchedLyrics: "Inferred from matched LRCLIB lyrics"
            case .linkedLyrics: "Inferred from linked YouTube Music lyrics"
            case .lyricsScript: "Lyrics script suggestion"
            case .titleLabel: "Title label suggestion"
            case .titleScript: "Title script suggestion"
            case .userOverride: "Your correction"
            case .musicBrainzWork: "MusicBrainz work language"
            }
        }
    }
    enum UnknownReason: Codable, Hashable, Sendable {
        case noMatchedLyrics, insufficientText, uncertainLanguage, lookupFailed, conflictingEvidence, userOverride
    }

    case identified(ArtistSongLanguage, source: Source)
    case likely(ArtistSongLanguage, source: Source)
    case unclassified(UnknownReason)

    var language: ArtistSongLanguage? {
        if case .identified(let language, _) = self { return language }
        return nil
    }

    var isInferred: Bool {
        switch self {
        case .identified(_, .matchedLyrics), .identified(_, .linkedLyrics): true
        default: false
        }
    }

    var source: Source? {
        switch self {
        case .identified(_, let source), .likely(_, let source): source
        case .unclassified(.userOverride): .userOverride
        default: nil
        }
    }

    var isLikely: Bool {
        if case .likely = self { return true }
        return false
    }

    var hasConflictingEvidence: Bool { self == .unclassified(.conflictingEvidence) }

    var title: String {
        switch self {
        case .identified(let language, _): language.title
        case .likely(let language, _): "Likely \(language.title)"
        case .unclassified(.conflictingEvidence): "Mixed or conflicting evidence"
        case .unclassified: "Unclassified"
        }
    }

    var explanation: String {
        switch self {
        case .identified(_, .userOverride), .unclassified(.userOverride):
            "Your saved correction takes priority for this recording."
        case .identified(_, .musicBrainzWork):
            "MusicBrainz lists this language for the work linked to the matched recording. Community metadata can be incomplete or incorrect."
        case .identified(_, .youTubeAudioLanguage):
            "YouTube supplies this language for the recording's default audio track. Upload metadata can be incomplete or incorrect."
        case .identified(_, .matchedLyrics), .identified(_, .linkedLyrics):
            "Inferred on this device from lyrics matched or linked to this recording. This is a text estimate, not an audio check."
        case .identified:
            "Language supplied for this individual recording."
        case .likely:
            "This is a suggestion. The song stays in Unclassified until its language is confirmed."
        case .unclassified(.conflictingEvidence):
            "The evidence contains more than one language or disagrees. No single language has been assigned."
        case .unclassified(.lookupFailed):
            "A source could not finish the check. You can retry or set the language yourself."
        case .unclassified(.insufficientText):
            "The matched lyrics do not contain enough distinct text to identify a language."
        case .unclassified(.uncertainLanguage):
            "The available evidence does not reliably establish one supported language."
        case .unclassified(.noMatchedLyrics):
            "No usable recording-specific language evidence was found."
        }
    }

    static func userOverride(_ code: String?) -> Self? {
        guard let code else { return nil }
        guard let language = ArtistSongLanguage(rawValue: code) else { return .unclassified(.userOverride) }
        return .identified(language, source: .userOverride)
    }

    static func recordingMetadata(_ track: Track) -> Self? {
        // CatalogParser leaves this nil; the catalog only assigns it to verified individual recordings.
        // Never substitute a collection's discovery language or an artist-name heuristic here.
        switch track.language {
        case .hindi: .identified(.hindi, source: .recordingMetadata)
        case .english: .identified(.english, source: .recordingMetadata)
        case nil: nil
        }
    }

    static func youTubeAudioLanguage(_ value: String?) -> Self? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
              value.utf8.count <= 64,
              value.range(of: #"^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$"#, options: .regularExpression) != nil,
              let code = value.lowercased().split(separator: "-").first.map(String.init) else { return nil }
        let aliases = ["eng": "en", "hin": "hi", "ben": "bn", "tam": "ta", "tel": "te"]
        if let language = ArtistSongLanguage(rawValue: aliases[code] ?? code) {
            return .identified(language, source: .youTubeAudioLanguage)
        }
        if code == "mul" { return .unclassified(.conflictingEvidence) }
        if code == "zxx" { return .unclassified(.noMatchedLyrics) }
        return .unclassified(.uncertainLanguage)
    }
}

enum ArtistSpotlightFilter: Hashable, Sendable, Identifiable {
    case all, language(ArtistSongLanguage), unclassified

    var id: String {
        switch self {
        case .all: "all"
        case .language(let language): language.rawValue
        case .unclassified: "unclassified"
        }
    }

    var title: String {
        switch self {
        case .all: "All"
        case .language(let language): language.title
        case .unclassified: "Unclassified"
        }
    }
}

enum ArtistSpotlight {
    /// Positional credit role: the first-named credit is primary; later credits and title feature clauses are features.
    enum Role: Equatable, Sendable { case primary, featured }

    static let countProvenance = "Sorted by available play counts"
    static let lyricsProvenance = "Language inferred on device from matched or linked lyrics"

    static func collection(for artist: ArtistPage, tracks: [Track]) -> MusicCollection {
        MusicCollection(id: "artist-spotlight.\(artist.id)", title: "This is \(artist.name)",
                        subtitle: "Popular songs from YouTube Music", artworkURL: artist.artworkURL,
                        kind: .mix, tracks: sorted(tracks))
    }

    static func availableCount(_ track: Track) -> Int64? {
        guard let count = track.playCount, count >= 0 else { return nil }
        return count
    }

    // Counts belong to provider recording IDs. Only the artist display projection may fold release aliases;
    // exact-ID merges and queues must retain separate recordings and never add their counts together.
    static func mergedTracks(_ tracks: [Track]) -> [Track] {
        var order: [String] = []
        var byID: [String: Track] = [:]
        var conflictingLanguages = Set<String>()
        for var track in tracks where track.isAudioRecording != false {
            guard CatalogText.clean(track.id) != nil, CatalogText.clean(track.title) != nil else { continue }
            track.playCount = availableCount(track)
            if var previous = byID[track.id] {
                previous.adoptMissingMetadata(from: track)
                previous.artworkURL = previous.artworkURL ?? track.artworkURL
                previous.isAudioRecording = previous.isAudioRecording ?? track.isAudioRecording
                if let left = previous.language, let right = track.language, left != right {
                    conflictingLanguages.insert(track.id)
                }
                previous.language = previous.language ?? track.language
                byID[track.id] = previous
            } else {
                order.append(track.id)
                byID[track.id] = track
            }
        }
        return order.compactMap { id in
            guard var track = byID[id] else { return nil }
            if conflictingLanguages.contains(id) { track.language = nil }
            return track
        }
    }

    static func sorted(_ tracks: [Track]) -> [Track] {
        mergedTracks(tracks).sorted { left, right in
            switch (availableCount(left), availableCount(right)) {
            case (.some(let a), .some(let b)) where a != b: return a > b
            case (.some, .none): return true
            case (.none, .some): return false
            default: break
            }
            let a = SearchRelevance.normalize(left.title)
            let b = SearchRelevance.normalize(right.title)
            if a != b { return a < b }
            return left.id < right.id
        }
    }

    struct SongDisplay: Sendable {
        var tracks: [Track]
        let listedTracks: [Track]
        let featuredTracks: [Track]
        let aliasCount: Int
    }

    // Display representatives keep their recording IDs and metadata; they are never inputs to the next merge.
    static func distinctSongs(_ tracks: [Track], artist: ArtistPage) -> [Track] {
        displaySongs(tracks, artist: artist).tracks
    }

    static func displaySongs(_ tracks: [Track], artist: ArtistPage,
                             languages: [String: ArtistSongLanguageResult] = [:], overrides: [String: String] = [:],
                             maximumAdditionalTracks: Int = .max) -> SongDisplay {
        let recordings = mergedTracks(tracks)
        let listed = Dictionary(artist.topSongs.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { min($0, $1) })
        let releases = Dictionary(artist.releases.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let identities = recordings.map { RecordingIdentity($0, release: $0.albumID.flatMap { releases[$0] },
                                                            languages: languages, overrides: overrides) }
        let ranks = recordings.map { ReleaseRank($0, release: $0.albumID.flatMap { releases[$0] },
                                                isListed: listed[$0.id] != nil, isCorrected: overrides[$0.id] != nil) }
        // Stable grouping precedes representative ranking, so counts, pagination and input permutations cannot
        // turn a middle-duration winner or an unlinked credit into a bridge between incompatible recordings.
        let order = recordings.indices.sorted { left, right in
            let a = identities[left], b = identities[right]
            if (a.language != nil) != (b.language != nil) { return a.language != nil }
            if a.linkedCredits != b.linkedCredits { return a.linkedCredits > b.linkedCredits }
            let first = a.duration ?? .infinity, second = b.duration ?? .infinity
            if first != second { return first < second }
            return recordings[left].id < recordings[right].id
        }
        var groups: [[Int]] = []
        var groupsByKey: [SongKey: [Int]] = [:]
        for index in order {
            guard let key = identities[index].key, identities[index].duration != nil else {
                groups.append([index])
                continue
            }
            let compatible = (groupsByKey[key] ?? []).filter { group in
                groups[group].allSatisfy { identities[$0].sameRecording(as: identities[index]) }
            }
            if compatible.count == 1, let group = compatible.first {
                groups[group].append(index)
            } else {
                groupsByKey[key, default: []].append(groups.count)
                groups.append([index])
            }
        }
        var additional = 0
        let visible = groups.sorted { ($0.min() ?? 0) < ($1.min() ?? 0) }.filter { group in
            if group.contains(where: { listed[recordings[$0].id] != nil }) { return true }
            guard additional < max(0, maximumAdditionalTracks) else { return false }
            additional += 1
            return true
        }
        var representatives: [Track] = []
        var listedRepresentatives: [(Int, Track)] = []
        var featured: [Track] = []
        var aliases = 0
        for group in visible {
            guard let winner = group.min(by: { ranks[$0].beats(ranks[$1]) }) else { continue }
            let track = recordings[winner]
            representatives.append(track)
            aliases += group.count - 1
            if let position = group.compactMap({ listed[recordings[$0].id] }).min() {
                listedRepresentatives.append((position, track))
            } else if role(of: artist, on: track) == .featured {
                featured.append(track)
            }
        }
        return SongDisplay(tracks: representatives, listedTracks: listedRepresentatives.sorted { $0.0 < $1.0 }.map { $0.1 },
                           featuredTracks: sorted(featured), aliasCount: aliases)
    }

    private struct SongKey: Hashable {
        let title: String
        let primaryArtist: String
        let performers: [String]
        let releaseQualifiers: [String]
    }

    private enum LanguageIdentity: Equatable {
        case language(ArtistSongLanguage), correction(String), conflicting(String)
    }

    private struct RecordingIdentity {
        let key: SongKey?
        let credits: [ArtistCredit]
        let duration: TimeInterval?
        let language: LanguageIdentity?

        var linkedCredits: Int { credits.compactMap(\.id).count }

        init(_ track: Track, release: MusicCollection?, languages: [String: ArtistSongLanguageResult], overrides: [String: String]) {
            credits = track.allCredits.flatMap { credit in
                let names = credit.id == nil ? LyricsMatcher.artistParts([credit.name]) : [credit.name]
                return names.map { ArtistCredit(name: SearchRelevance.normalize($0), id: credit.id) }
            }.filter { !$0.name.isEmpty }
            let title = track.title.utf8.count <= 2_048 ? DisplayText.title(track.title) : ""
            let album = track.albumTitle ?? release?.title ?? ""
            let primary = track.credits.first.map { credit in
                SearchRelevance.normalize(credit.id == nil ? (LyricsMatcher.artistParts([credit.name]).first ?? "") : credit.name)
            } ?? ""
            if primary.isEmpty || credits.isEmpty || title.isEmpty || album.utf8.count > 2_048 {
                key = nil
            } else {
                key = SongKey(title: title, primaryArtist: primary, performers: Set(credits.map(\.name)).sorted(),
                              releaseQualifiers: DisplayText.releaseQualifiers(album))
            }
            duration = LyricsMatcher.validDuration(track.duration)
            if let code = overrides[track.id] {
                language = ArtistSongLanguage(rawValue: code).map(LanguageIdentity.language) ?? .correction(code)
            } else if languages[track.id]?.hasConflictingEvidence == true {
                language = .conflicting(track.id)
            } else if let catalogLanguage = ArtistSongLanguageResult.recordingMetadata(track)?.language,
                      let checkedLanguage = languages[track.id]?.language, catalogLanguage != checkedLanguage {
                language = .conflicting(track.id)
            } else {
                switch ArtistSpotlight.languageResult(for: track, in: languages) {
                case .identified(let value, _), .likely(let value, _): language = .language(value)
                case .unclassified(.conflictingEvidence): language = .conflicting(track.id)
                default: language = nil
                }
            }
        }

        func sameRecording(as other: Self) -> Bool {
            guard let a = duration, let b = other.duration, abs(a - b) <= 10 else { return false }
            if let a = language, let b = other.language, a != b { return false }
            if let language, case .conflicting = language { return false }
            if let language = other.language, case .conflicting = language { return false }
            for credit in credits {
                guard let id = credit.id else { continue }
                let otherIDs = other.credits.filter { $0.name == credit.name }.compactMap(\.id)
                if !otherIDs.isEmpty, !otherIDs.allSatisfy({ $0 == id }) { return false }
            }
            return true
        }
    }

    private enum ReleaseKind: Equatable { case album, single, compilation, unknown }

    private static func releaseKind(_ subtitle: String) -> ReleaseKind {
        let labels = subtitle.lowercased().components(separatedBy: CharacterSet(charactersIn: "•·"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if labels.contains("compilation") { return .compilation }
        if labels.contains("album") || labels.contains("ep") { return .album }
        if labels.contains("single") { return .single }
        return .unknown
    }

    private struct ReleaseRank {
        let isCorrected: Bool
        let isAlbum: Bool
        let isCompilation: Bool
        let isRemaster: Bool
        let isExplicit: Bool
        let hasCount: Bool
        let isListed: Bool
        let hasArtwork: Bool
        let titleLength: Int
        let id: String

        init(_ track: Track, release: MusicCollection?, isListed: Bool, isCorrected: Bool) {
            self.isCorrected = isCorrected
            let kind = release.map { releaseKind($0.subtitle) } ?? .unknown
            isAlbum = kind == .album
            isCompilation = kind == .compilation
            isRemaster = DisplayText.isRemaster(track.title) || DisplayText.isRemaster(track.albumTitle ?? release?.title ?? "")
            isExplicit = track.isExplicit
            hasCount = availableCount(track) != nil
            self.isListed = isListed
            hasArtwork = track.artworkURL != nil
            titleLength = track.title.count
            id = track.id
        }

        func beats(_ other: ReleaseRank) -> Bool {
            if isCorrected != other.isCorrected { return isCorrected }
            if isAlbum != other.isAlbum { return isAlbum }
            if isCompilation != other.isCompilation { return !isCompilation }
            if isRemaster != other.isRemaster { return !isRemaster }
            if isExplicit != other.isExplicit { return isExplicit }
            if hasCount != other.hasCount { return hasCount }
            if isListed != other.isListed { return isListed }
            if hasArtwork != other.hasArtwork { return hasArtwork }
            if titleLength != other.titleLength { return titleLength < other.titleLength }
            return id < other.id
        }
    }

    private enum DisplayText {
        private static let brackets = #"[(\[]([^()\[\]]*)[)\]]"#
        private static let separator = #"\s[-–—|]\s"#
        private static let remaster = #"^(?:(?:19|20)\d{2} )?remaster(?:ed)?(?: (?:19|20)\d{2})?(?: version)?$"#

        static func title(_ value: String) -> String {
            var text = value
            if let regex = try? NSRegularExpression(pattern: brackets) {
                for match in regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
                    let annotation = (value as NSString).substring(with: match.range(at: 1))
                    if isCosmetic(annotation) || isFeature(annotation), let range = Range(match.range, in: text) {
                        text.replaceSubrange(range, with: " ")
                    }
                }
            }
            text = parts(text).enumerated().filter { $0.offset == 0 || !(isCosmetic($0.element) || isFeature($0.element)) }
                .map { $0.element }.joined(separator: " ")
            if !ArtistCredit.featured(inTitle: text).isEmpty {
                text = text.replacingOccurrences(of: #"(?i)\s(?:feat\.?|ft\.?|featuring)\s+[^()\[\]]+$"#,
                                                with: "", options: .regularExpression)
            }
            return LyricsMatcher.normalized(text)
        }

        static func releaseQualifiers(_ value: String) -> [String] {
            var qualifiers = annotations(value).filter { !isCosmetic($0) }.map(LyricsMatcher.normalized)
            let base = value.replacingOccurrences(of: brackets, with: " ", options: .regularExpression)
            let sections = parts(base)
            qualifiers += sections.dropFirst().filter { !isCosmetic($0) }.map(LyricsMatcher.normalized)
            let name = LyricsMatcher.normalized(sections.first ?? "")
            // Ordinary album names such as Take Care and Live Through This do not identify a performance.
            let performance = #"\b(?:live (?:at|in|from|on)|recorded live|unplugged|acoustic|instrumental|karaoke|remix(?:ed|es)?|demos?|rehearsals?|(?:bbc|peel|studio) sessions?|alternate takes?|clean (?:version|edit)|radio edit)\b|^live$"#
            if name.range(of: performance, options: .regularExpression) != nil { qualifiers.append(name) }
            return Set(qualifiers.filter { !$0.isEmpty }).sorted()
        }

        static func isRemaster(_ value: String) -> Bool {
            (annotations(value) + Array(parts(value).dropFirst())).contains {
                LyricsMatcher.normalized($0).range(of: remaster, options: .regularExpression) != nil
            }
        }

        private static func isCosmetic(_ value: String) -> Bool {
            let text = LyricsMatcher.normalized(value)
            if text.range(of: remaster, options: .regularExpression) != nil { return true }
            // A missing explicit badge is not proof of a clean edit; actual clean/censored qualifiers survive.
            return ["album", "album version", "original version", "explicit", "explicit version",
                    "deluxe", "deluxe edition", "deluxe version", "expanded edition", "anniversary edition"].contains(text)
        }

        private static func isFeature(_ value: String) -> Bool {
            !ArtistCredit.featured(inTitle: "(\(value))").isEmpty
        }

        private static func annotations(_ value: String) -> [String] {
            guard let regex = try? NSRegularExpression(pattern: brackets) else { return [] }
            return regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).map {
                (value as NSString).substring(with: $0.range(at: 1))
            }
        }

        private static func parts(_ value: String) -> [String] {
            value.replacingOccurrences(of: separator, with: "\u{001F}", options: .regularExpression)
                .components(separatedBy: "\u{001F}")
        }
    }

    static func languageResult(for track: Track, in results: [String: ArtistSongLanguageResult],
                               overrides: [String: String] = [:]) -> ArtistSongLanguageResult? {
        ArtistSongLanguageResult.userOverride(overrides[track.id]) ?? ArtistSongLanguageResult.recordingMetadata(track) ?? results[track.id]
    }

    static func filtered(_ tracks: [Track], by filter: ArtistSpotlightFilter,
                         languages: [String: ArtistSongLanguageResult], overrides: [String: String] = [:]) -> [Track] {
        sorted(tracks).filter { matches($0, filter: filter, languages: languages, overrides: overrides) }
    }

    static func matches(_ track: Track, filter: ArtistSpotlightFilter,
                        languages: [String: ArtistSongLanguageResult], overrides: [String: String] = [:]) -> Bool {
        let language = languageResult(for: track, in: languages, overrides: overrides)?.language
        switch filter {
        case .all: return true
        case .language(let selected): return language == selected
        case .unclassified: return language == nil
        }
    }

    static func credits(_ artist: ArtistPage, on track: Track) -> Bool {
        role(of: artist, on: track) != nil
    }

    /// Linked credits match by id only, so a same-named artist with another page id never counts; unlinked
    /// credits match an exact normalized name part. A compound first credit ("A & B") names A as primary.
    static func role(of artist: ArtistPage, on track: Track) -> Role? {
        let name = SearchRelevance.normalize(artist.name)
        guard !name.isEmpty else { return nil }
        var isFirstNamed = true
        for (index, credit) in track.allCredits.enumerated() {
            // allCredits appends title feature clauses after the provider credits; a clause is never primary.
            let isFromTitle = index >= track.credits.count
            if let id = credit.id {
                if id == artist.id { return isFirstNamed && !isFromTitle ? .primary : .featured }
                isFirstNamed = false
                continue
            }
            for part in LyricsMatcher.artistParts([credit.name]) {
                if SearchRelevance.normalize(part) == name { return isFirstNamed && !isFromTitle ? .primary : .featured }
                isFirstNamed = false
            }
        }
        return nil
    }

    static func matchingCount(for track: Track, in candidates: [Track], artist: ArtistPage) -> Int64? {
        let title = SearchRelevance.normalize(LyricsMatcher.cleanTitle(track.title, artists: track.artists))
        return candidates.first { candidate in
            candidate.id == track.id && candidate.isAudioRecording != false && availableCount(candidate) != nil
                && credits(artist, on: candidate)
                && SearchRelevance.normalize(LyricsMatcher.cleanTitle(candidate.title, artists: candidate.artists)) == title
        }.flatMap(availableCount)
    }
}

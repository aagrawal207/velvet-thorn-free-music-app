import Foundation

// Recording-language evidence is separate from MusicLanguage, which controls Home discovery preferences.
// Adding a lyrics language here does not widen discovery or label an artist's other recordings.
enum ArtistSongLanguage: String, CaseIterable, Identifiable, Sendable {
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

enum ArtistSongLanguageResult: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case recordingMetadata, matchedLyrics, linkedLyrics, lyricsScript, titleLabel, titleScript, userOverride
        case musicBrainzWork(recordingID: String, workID: String)

        var title: String {
            switch self {
            case .recordingMetadata: "Recording metadata"
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
    enum UnknownReason: Equatable, Sendable {
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

    var title: String {
        switch self {
        case .identified(let language, _): language.title
        case .likely(let language, _): "Likely \(language.title)"
        case .unclassified(.conflictingEvidence): "Sources disagree"
        case .unclassified: "Unclassified"
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
    static let countProvenance = "Sorted by available play counts"
    static let lyricsProvenance = "Language inferred from matched lyrics"

    static func collection(for artist: ArtistPage, tracks: [Track]) -> MusicCollection {
        MusicCollection(id: "artist-spotlight.\(artist.id)", title: "This is \(artist.name)",
                        subtitle: "Popular songs from YouTube Music", artworkURL: artist.artworkURL,
                        kind: .mix, tracks: sorted(tracks))
    }

    static func availableCount(_ track: Track) -> Int64? {
        guard let count = track.playCount, count >= 0 else { return nil }
        return count
    }

    // Counts belong to provider recording IDs. Dubbed versions and separate releases must not be
    // collapsed by SongTitle.core, nor may their counts be added together.
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
        let name = SearchRelevance.normalize(artist.name)
        guard !name.isEmpty else { return false }
        return track.allCredits.contains { credit in
            if let id = credit.id { return id == artist.id }
            return LyricsMatcher.artistParts([credit.name]).contains { SearchRelevance.normalize($0) == name }
        }
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

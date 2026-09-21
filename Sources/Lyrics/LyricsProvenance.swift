import Foundation

enum LyricsSource: String, Sendable {
    case lrcLib = "LRCLIB"
    case youTubeMusic = "YouTube Music"
    case lyricFind = "LyricFind via YouTube Music"
    case musixmatch = "Musixmatch via YouTube Music"

    var isRecordingLinked: Bool { self != .lrcLib }

    static func youTubeAttribution(_ footer: String) -> Self {
        switch footer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "source: lyricfind": .lyricFind
        case "source: musixmatch": .musixmatch
        default: .youTubeMusic
        }
    }
}

extension LyricsDocument {
    var providerSource: LyricsSource? {
        LyricsSource(rawValue: source) ?? (source.hasPrefix("YouTube Music · ") ? .youTubeMusic : nil)
    }

    var sourceURL: URL? {
        guard let providerSource else { return nil }
        if providerSource == .lrcLib {
            guard let sourceID, sourceID > 0 else { return nil }
            return URL(string: "https://lrclib.net/api/get/\(sourceID)")
        }
        guard let id = CatalogText.videoID(trackID) else { return nil }
        return URL(string: "https://music.youtube.com/watch?v=\(id)")
    }
}

// A lyrics-tab link belongs to one provider ID, even when two dubbed recordings share metadata.
struct LyricsRequestKey: Hashable, Sendable {
    let id: String
    let recording: LyricsMatcher.RecordingKey

    init(_ track: Track) {
        id = track.id
        recording = LyricsMatcher.RecordingKey(track)
    }
}

enum LyricsRecordingIdentity {
    static func sameTitle(_ left: String, _ right: String, artists: [String]) -> Bool {
        let a = LyricsMatcher.normalized(LyricsMatcher.cleanTitle(left, artists: artists))
        let b = LyricsMatcher.normalized(LyricsMatcher.cleanTitle(right, artists: artists))
        return !a.isEmpty && a == b
    }

    static func sameArtists(_ expected: [String], _ actual: [String]) -> Bool {
        let left = Set(LyricsMatcher.artistParts(expected).map(SearchRelevance.normalize))
        let right = Set(LyricsMatcher.artistParts(actual).map(SearchRelevance.normalize))
        return !left.isEmpty && !right.isEmpty && right.isSubset(of: left)
    }
}

enum LyricsLookupError: LocalizedError, Sendable {
    case recordingMismatch, sourcesFailed

    var errorDescription: String? {
        switch self {
        case .recordingMismatch: "The lyrics response didn't match this recording. Please try again."
        case .sourcesFailed: "Lyrics services couldn't complete the lookup. Please try again."
        }
    }
}

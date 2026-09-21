import Foundation

struct LyricLine: Codable, Hashable, Identifiable, Sendable {
    var id: Int
    var time: TimeInterval
    var text: String
}

enum LyricsKind: String, Codable, Sendable { case synced, plain, instrumental, unavailable }

struct LyricsDocument: Codable, Sendable {
    var trackID: String
    var kind: LyricsKind
    var lines: [LyricLine]
    var plainText: String?
    var source: String
    var sourceID: Int?
    var matchedTitle: String?
    var matchedArtist: String?
    var fetchedAt: Date

    init(trackID: String, kind: LyricsKind, lines: [LyricLine] = [], plainText: String? = nil,
         source: String = "LRCLIB", sourceID: Int? = nil, matchedTitle: String? = nil,
         matchedArtist: String? = nil, fetchedAt: Date = Date()) {
        self.trackID = trackID
        self.kind = kind
        self.lines = lines
        self.plainText = plainText
        self.source = source
        self.sourceID = sourceID
        self.matchedTitle = matchedTitle
        self.matchedArtist = matchedArtist
        self.fetchedAt = fetchedAt
    }
}

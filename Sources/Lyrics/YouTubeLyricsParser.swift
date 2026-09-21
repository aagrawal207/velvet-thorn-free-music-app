import Foundation

enum YouTubeLyricsParser {
    struct Link: Sendable {
        let recording: Track
        let browseID: String
    }

    static func link(in next: CatalogJSON, for track: Track) throws -> Link? {
        guard let id = CatalogText.videoID(track.id),
              next["currentVideoEndpoint"]["watchEndpoint"]["videoId"].string == id else {
            throw LyricsLookupError.recordingMismatch
        }
        let tabbed = next["contents"]["singleColumnMusicWatchNextResultsRenderer"]["tabbedRenderer"]
        let tabs = tabbed["watchNextTabbedResultsRenderer"]["tabs"].array
        guard !tabs.isEmpty, next["error"] == .null else { throw MusicServiceError.invalidResponse }
        guard let recording = try CatalogParser.radio(next).first(where: { $0.id == id }),
              LyricsRecordingIdentity.sameTitle(track.title, recording.title, artists: track.artists),
              track.credits.isEmpty || LyricsRecordingIdentity.sameArtists(track.artists, recording.artists) else {
            throw LyricsLookupError.recordingMismatch
        }
        var ids = Set<String>()
        for wrapper in tabs {
            let tab = wrapper["tabRenderer"]
            guard tab["unselectable"].bool != true else { continue }
            let endpoint = tab["endpoint"]["browseEndpoint"]
            guard endpoint["browseEndpointContextSupportedConfigs"]["browseEndpointContextMusicConfig"]["pageType"].string
                    == "MUSIC_PAGE_TYPE_TRACK_LYRICS" else { continue }
            guard let browseID = CatalogText.identifier(endpoint["browseId"].string), browseID.hasPrefix("MPLY") else {
                throw MusicServiceError.invalidResponse
            }
            ids.insert(browseID)
        }
        guard ids.count <= 1 else { throw MusicServiceError.invalidResponse }
        return ids.first.map { Link(recording: recording, browseID: $0) }
    }

    static func document(_ root: CatalogJSON, linkedBy link: Link, for track: Track, fetchedAt: Date) throws -> LyricsDocument {
        guard link.recording.id == track.id else { throw LyricsLookupError.recordingMismatch }
        let section = root["contents"]["sectionListRenderer"]
        guard root["error"] == .null, section.isObject else { throw MusicServiceError.invalidResponse }
        let shelves = section["contents"].array.map { $0["musicDescriptionShelfRenderer"] }.filter(\.isObject)
        guard shelves.count <= 1 else { throw MusicServiceError.invalidResponse }
        guard let shelf = shelves.first else {
            let missing = section["contents"].array.contains {
                $0["messageRenderer"]["text"].text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "lyrics not available"
            }
            guard missing else { throw MusicServiceError.invalidResponse }
            return LyricsDocument(trackID: track.id, kind: .unavailable, source: LyricsSource.youTubeMusic.rawValue, fetchedAt: fetchedAt)
        }
        let text = shelf["description"].text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count <= LRCParser.maximumSourceBytes,
              text.components(separatedBy: .newlines).count <= LRCParser.maximumLines else { throw MusicServiceError.invalidResponse }
        let footer = shelf["footer"].text.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = LyricsSource.youTubeAttribution(footer)
        let attribution = source == .youTubeMusic && !footer.isEmpty && footer.utf8.count <= 512
            ? "YouTube Music · \(footer)" : source.rawValue
        // The MPLY endpoint is obtained only from this recording's Lyrics tab. Its text has no timing.
        return LyricsDocument(trackID: track.id, kind: text.isEmpty ? .unavailable : .plain,
            plainText: text.isEmpty ? nil : text, source: attribution,
            matchedTitle: link.recording.title, matchedArtist: link.recording.artistName, fetchedAt: fetchedAt)
    }
}

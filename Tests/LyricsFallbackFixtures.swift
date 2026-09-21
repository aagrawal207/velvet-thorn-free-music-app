import Foundation
@testable import GanaBajana

enum LyricsFallbackFixtures {
    static let track = Track(id: "fsiPzT50ZiM", title: "Paper Satellites", artists: ["Test Singer"],
                             albumTitle: "Synthetic Sky", duration: 200, isAudioRecording: true)

    static func plain(_ track: Track = LyricsFallbackFixtures.track, source: LyricsSource = .lyricFind,
                      text: String = ArtistSpotlightFixtures.englishText) -> LyricsDocument {
        LyricsDocument(trackID: track.id, kind: .plain, plainText: text, source: source.rawValue,
                       matchedTitle: track.title, matchedArtist: track.artistName)
    }

    static func next(_ track: Track = LyricsFallbackFixtures.track, currentID: String? = nil, disabled: Bool = false,
                     browseID: String = "MPLYfixture-1") throws -> CatalogJSON {
        let row = try CatalogFixtures.json(CatalogFixtures.radioTrack(id: track.id, title: track.title, artist: track.artistName))
        return ["currentVideoEndpoint": ["watchEndpoint": ["videoId": .string(currentID ?? track.id)]],
                "contents": ["singleColumnMusicWatchNextResultsRenderer": ["tabbedRenderer": ["watchNextTabbedResultsRenderer": ["tabs": [
                    ["tabRenderer": ["title": "Up next", "content": ["musicQueueRenderer": ["content": [
                        "playlistPanelRenderer": ["contents": [row]],
                    ]]]]],
                    ["tabRenderer": ["title": "Lyrics", "unselectable": .bool(disabled), "endpoint": ["browseEndpoint": [
                        "browseId": .string(browseID), "browseEndpointContextSupportedConfigs": [
                            "browseEndpointContextMusicConfig": ["pageType": "MUSIC_PAGE_TYPE_TRACK_LYRICS"]],
                    ]]]],
                ]]]]]]
    }

    static func lyrics(text: String = ArtistSpotlightFixtures.englishText, footer: String = "Source: LyricFind") -> CatalogJSON {
        ["contents": ["sectionListRenderer": ["contents": [["musicDescriptionShelfRenderer": [
            "description": ["runs": [["text": .string(text)]]], "footer": ["runs": [["text": .string(footer)]]],
        ]]]]]]
    }
}

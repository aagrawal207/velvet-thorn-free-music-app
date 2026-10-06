import Foundation
@testable import GanaBajana

/// Community playlist rows as WEB_REMIX serves them: the title run carries the watch endpoint with the entry's
/// `musicVideoType`, the byline links an artist or the uploader's channel, and a credits link is optional.
enum CatalogPlaylistFixtures {
    static let playlistID = "VLPLfixtureCommunityPlaylist"
    static let channelID = "UCFMk0ShNzNABiT8jJjqgi8Q"
    static let clipID = "NUo8CKI34o4"
    static let uploadID = "bt8V9TpH9FI"

    static func row(id: String, title: String, type: String = "MUSIC_VIDEO_TYPE_ATV",
                    byline: [[String: Any]] = CatalogFixtures.artistRuns([("Arijit Singh", CatalogFixtures.arijitID)]),
                    duration: String = "4:22", creditsLink: String? = nil, greyedOut: Bool = false) -> [String: Any] {
        var row: [String: Any] = [
            "playlistItemData": ["videoId": id],
            "flexColumns": [
                ["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [
                    ["text": title, "navigationEndpoint": ["watchEndpoint": CatalogFixtures.watch(id, type: type)]],
                ]]]],
                ["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": byline]]],
            ],
            "fixedColumns": [["musicResponsiveListItemFixedColumnRenderer": ["text": CatalogFixtures.text(duration)]]],
            "thumbnail": ["musicThumbnailRenderer": ["thumbnail": CatalogFixtures.artwork()]],
        ]
        if let creditsLink {
            row["menu"] = ["items": [["navigationEndpoint": CatalogFixtures.browseRun(
                "Credits", id: "MPTC" + creditsLink, type: "MUSIC_PAGE_TYPE_TRACK_CREDITS")["navigationEndpoint"]!]]]
        }
        if greyedOut { row["musicItemRendererDisplayPolicy"] = "MUSIC_ITEM_RENDERER_DISPLAY_POLICY_GREY_OUT" }
        return ["musicResponsiveListItemRenderer": row]
    }

    /// An uploader byline: a user channel, which the provider links like an artist.
    static func channelByline(_ name: String = "Bollywood Remix Songs - DJ") -> [[String: Any]] {
        [CatalogFixtures.browseRun(name, id: channelID, type: "MUSIC_PAGE_TYPE_USER_CHANNEL")]
    }

    /// The mixed page the live probe found: album audio, an official video, an upload, a video with a credits
    /// link to its album recording, a podcast-typed row and a greyed-out row.
    static func mixedRows() -> [[String: Any]] {
        [
            row(id: CatalogFixtures.hindiID, title: "Tum Hi Ho"),
            row(id: "ogBQ3VymYbk", title: "Kabhi Kabhi", type: "MUSIC_VIDEO_TYPE_OMV", duration: "3:51"),
            row(id: uploadID, title: "Nonstop party dj mix", type: "MUSIC_VIDEO_TYPE_UGC", byline: channelByline(), duration: "55:36"),
            row(id: clipID, title: "Kesariya", type: "MUSIC_VIDEO_TYPE_OMV", duration: "4:28", creditsLink: "NJAv_7lHUIU"),
            row(id: "6C34aCdjJtM", title: "Jhanjhariya", type: "MUSIC_VIDEO_TYPE_PODCAST_EPISODE"),
            row(id: "x_elT6zkqN0", title: "Removed video", type: "MUSIC_VIDEO_TYPE_OMV", greyedOut: true),
        ]
    }
}

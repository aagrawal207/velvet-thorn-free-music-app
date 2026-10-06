import Foundation

enum YouTubeAccountWriteParser {
    static func validateEnvelope(_ root: CatalogJSON) throws {
        guard root.isObject else { throw YouTubeAccountWriteError.couldNotConfirm }
        let error = root["error"]
        if [401, 403].contains(error["code"].int ?? 0) || error["status"].string == "UNAUTHENTICATED"
            || root["responseContext"]["mainAppWebResponseContext"]["loggedOut"].bool == true {
            throw YouTubeAccountWriteError.unauthorized
        }
        guard error == .null else { throw YouTubeAccountWriteError.rejected }
        guard root.values(for: "showEngagementPanelEndpoint").isEmpty else { throw YouTubeAccountWriteError.couldNotConfirm }
        if root["status"] != .null && root["status"].string != "STATUS_SUCCEEDED" {
            throw YouTubeAccountWriteError.couldNotConfirm
        }
    }

    static func ownedPlaylists(_ root: CatalogJSON) throws -> YouTubeLibraryPage<MusicCollection> {
        try validateEnvelope(root)
        let grids = root.values(for: "gridRenderer") + root.values(for: "gridContinuation")
        guard !grids.isEmpty else { throw YouTubeAccountWriteError.unreadable }
        for grid in grids where grid["continuations"] != .null {
            guard case .array(let continuations) = grid["continuations"] else { throw YouTubeAccountWriteError.unreadable }
            for continuation in continuations {
                guard let token = continuation["nextContinuationData"]["continuation"].string,
                      !token.isEmpty, token.utf8.count <= 65_536 else { throw YouTubeAccountWriteError.unreadable }
            }
        }
        let page = try CatalogParser.browse(root, id: YouTubeAccountLibraryClient.playlistsBrowseID)
        let ownedIDs = Set(grids.flatMap { grid in
            grid["items"].array.compactMap { item -> String? in
                let row = item["musicTwoRowItemRenderer"]
                guard let id = row["title"]["runs"].array.first?["navigationEndpoint"]["browseEndpoint"]["browseId"].string,
                      let rawID = YouTubeAccountWriteTarget.playlistID(id) else { return nil }
                let owns = row["menu"]["menuRenderer"]["items"].array.contains { menu in
                    menu["menuNavigationItemRenderer"]["navigationEndpoint"]["playlistEditorEndpoint"]["playlistId"].string == rawID
                }
                return owns ? id : nil
            }
        })
        let token = YouTubeAccountLibraryParser.gridContinuation(root) ?? CatalogParser.continuation(root)
        return .init(items: YouTubeAccountLibraryParser.playlists(page.collections).filter { ownedIDs.contains($0.id) }, continuation: token)
    }

    static func ownsPlaylist(_ root: CatalogJSON, browseID: String) -> Bool {
        guard let rawID = YouTubeAccountWriteTarget.playlistID(browseID) else { return false }
        let contents = root["contents"]["twoColumnBrowseResultsRenderer"]["tabs"].array
            .flatMap { $0["tabRenderer"]["content"]["sectionListRenderer"]["contents"].array }
        return contents.contains { section in
            section["musicEditablePlaylistDetailHeaderRenderer"]["playlistId"].string == rawID
        }
    }

    static func addAcknowledged(_ root: CatalogJSON, videoID: String) -> Bool {
        guard root["status"].string == "STATUS_SUCCEEDED" else { return false }
        let results = root["playlistEditResults"].array
        guard results.count == 1 else { return false }
        let added = results[0]["playlistEditVideoAddedResultData"]
        guard let setID = added["setVideoId"].string, !setID.isEmpty, setID.utf8.count <= 1_024 else { return false }
        return added["videoId"].string == videoID
    }

    static func subscriptionAcknowledged(_ root: CatalogJSON, channelID: String, subscribed: Bool) -> Bool {
        let updates = root["actions"].array.map { $0["updateSubscribeButtonAction"] }
            .filter { $0["channelId"].string == channelID }
        return !updates.isEmpty && updates.allSatisfy { $0["subscribed"].bool == subscribed }
    }

    static func likeState(_ root: CatalogJSON, videoID: String) -> Bool? {
        let context = root["responseContext"]
        let signedIn = context["mainAppWebResponseContext"]["loggedOut"].bool == false
            || context["serviceTrackingParams"].array.contains { service in
                service["service"].string == "GFEEDBACK" && service["params"].array.contains {
                    $0["key"].string == "logged_in" && $0["value"].string == "1"
                }
            }
        guard signedIn else { return nil }
        let rows = root["contents"]["singleColumnMusicWatchNextResultsRenderer"]["tabbedRenderer"]["watchNextTabbedResultsRenderer"]
            .values(for: "playlistPanelVideoRenderer").filter { $0["videoId"].string == videoID }
        var states = Set<Bool>()
        for row in rows {
            for item in row["menu"]["menuRenderer"]["items"].array {
                let endpoint = item["toggleMenuServiceItemRenderer"]["defaultServiceEndpoint"]["likeEndpoint"]
                guard endpoint["target"]["videoId"].string == videoID else { continue }
                switch endpoint["status"].string {
                case "INDIFFERENT": states.insert(true)
                case "LIKE": states.insert(false)
                default: return nil
                }
            }
        }
        return states.count == 1 ? states.first : nil
    }
}

import Foundation
import Synchronization
@testable import GanaBajana

enum YouTubeWriteFixtures {
    static let videoID = "abcdefghijk"
    static let channelID = "UCabcdefghijklmnopqrstuv"
    static let playlistID = "VLPLfixture_owned"
    static let now = Date(timeIntervalSince1970: 1_700_000_000)
    static let version = "1.20260915.14.00"
    static var track: Track { Track(id: videoID, title: "Fixture Song") }
    static var artist: ArtistCredit { ArtistCredit(name: "Fixture Artist", id: channelID) }
    static var playlist: MusicCollection { MusicCollection(id: playlistID, title: "Owned Playlist") }
    static var account: YouTubeAccountSession { YouTubeAccountSession(capturing: AccountFixtures.signedIn)! }
    static var access: YouTubeAccountWriteAccess { .init(session: account, generation: UUID()) }

    static func subscription(channelID: String = YouTubeWriteFixtures.channelID, subscribed: Bool = true) -> CatalogJSON {
        ["actions": [["updateSubscribeButtonAction": ["channelId": .string(channelID), "subscribed": .bool(subscribed)]]]]
    }

    static var added: CatalogJSON {
        ["status": "STATUS_SUCCEEDED", "playlistEditResults": [["playlistEditVideoAddedResultData": [
            "videoId": .string(videoID), "setVideoId": "fixture_set_id",
        ]]]]
    }

    static func ownedHeader(id: String = YouTubeWriteFixtures.playlistID) -> CatalogJSON {
        let header: CatalogJSON = ["musicEditablePlaylistDetailHeaderRenderer": ["playlistId": .string(String(id.dropFirst(2)))]]
        let tab: CatalogJSON = ["tabRenderer": ["content": ["sectionListRenderer": ["contents": [header]]]]]
        return ["contents": ["twoColumnBrowseResultsRenderer": ["tabs": [tab]]]]
    }

    static func playlistRow(id: String, owned: Bool) -> CatalogJSON {
        let endpoint: CatalogJSON = ["browseEndpoint": ["browseId": .string(id), "browseEndpointContextSupportedConfigs": [
            "browseEndpointContextMusicConfig": ["pageType": "MUSIC_PAGE_TYPE_PLAYLIST"],
        ]]]
        return ["musicTwoRowItemRenderer": [
            "title": ["runs": [["text": "Fixture Playlist", "navigationEndpoint": endpoint]]],
            "subtitle": ["runs": [["text": "Playlist"]]], "navigationEndpoint": endpoint,
            "menu": ["menuRenderer": ["items": owned ? [["menuNavigationItemRenderer": ["navigationEndpoint": [
                "playlistEditorEndpoint": ["playlistId": .string(String(id.dropFirst(2)))],
            ]]]] : []]],
        ]]
    }

    static func playlists(rows: [CatalogJSON], continuation: String? = nil, continued: Bool = false) -> CatalogJSON {
        var grid: [String: CatalogJSON] = ["items": .array(rows)]
        if let continuation { grid["continuations"] = [["nextContinuationData": ["continuation": .string(continuation)]]] }
        if continued { return ["continuationContents": ["gridContinuation": .object(grid)]] }
        let section: CatalogJSON = ["sectionListRenderer": ["contents": [["gridRenderer": .object(grid)]]]]
        let tab: CatalogJSON = ["tabRenderer": ["content": section]]
        return ["contents": ["singleColumnBrowseResultsRenderer": ["tabs": [tab]]]]
    }

    static func likeState(liked: Bool, videoID: String = YouTubeWriteFixtures.videoID, signedIn: Bool = true) -> CatalogJSON {
        let like: CatalogJSON = ["likeEndpoint": ["status": .string(liked ? "INDIFFERENT" : "LIKE"), "target": ["videoId": .string(videoID)]]]
        let menu: CatalogJSON = ["menuRenderer": ["items": [["toggleMenuServiceItemRenderer": ["defaultServiceEndpoint": like]]]]]
        let row: CatalogJSON = ["playlistPanelVideoRenderer": ["videoId": .string(videoID), "menu": menu]]
        let queue: CatalogJSON = ["musicQueueRenderer": ["content": ["playlistPanelRenderer": ["contents": [row]]]]]
        let tab: CatalogJSON = ["tabRenderer": ["content": queue]]
        return ["responseContext": ["mainAppWebResponseContext": ["loggedOut": .bool(!signedIn)]],
                "contents": ["singleColumnMusicWatchNextResultsRenderer": ["tabbedRenderer": ["watchNextTabbedResultsRenderer": ["tabs": [tab]]]]]]
    }
}

actor YouTubeWriteStubClient: YouTubeAccountWriteProviding {
    var calls = 0
    let held: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    init(held: Bool = false) { self.held = held }
    func ownedPlaylists(access: YouTubeAccountWriteAccess) async throws -> YouTubeAccountWritePlaylistListing {
        calls += 1
        return .init(items: [YouTubeWriteFixtures.playlist], isLimited: false)
    }
    func perform(_ action: YouTubeAccountWriteAction, targetID: String, playlistID: String?, access: YouTubeAccountWriteAccess) async throws {
        calls += 1
        if held { await withCheckedContinuation { continuation = $0 } }
    }
    func release() { continuation?.resume(); continuation = nil }
}

final class YouTubeWriteFailingSecrets: SecretStoring {
    private let values = MemorySecretStore()
    private let failure = Mutex(false)
    func failWrites() { failure.withLock { $0 = true } }
    func read(_ key: String) throws -> Data? { try values.read(key) }
    func write(_ data: Data, key: String) throws {
        if failure.withLock({ $0 }) { throw YouTubeAccountWriteError.permissionStorage }
        try values.write(data, key: key)
    }
    func delete(_ key: String) throws { try values.delete(key) }
}

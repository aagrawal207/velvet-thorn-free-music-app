import Foundation

struct YouTubeAccountWritePlaylistListing: Sendable {
    var items: [MusicCollection]
    var isLimited: Bool
}

protocol YouTubeAccountWriteProviding: Sendable {
    func ownedPlaylists(access: YouTubeAccountWriteAccess) async throws -> YouTubeAccountWritePlaylistListing
    func perform(_ action: YouTubeAccountWriteAction, targetID: String, playlistID: String?,
                 access: YouTubeAccountWriteAccess) async throws
}

actor YouTubeAccountWriteClient: YouTubeAccountWriteProviding {
    static let origin = "https://music.youtube.com"
    private static let endpoints = Set(YouTubeAccountWriteAction.allCases.map(\.endpoint) + ["browse", "next"])
    private let session: URLSession
    private let version: @Sendable () async throws -> String
    private let now: @Sendable () -> Date
    private var busy = false
    private var retryAfter: Date?

    init(session: URLSession = YouTubeAccountWriteClient.accountSession(),
         version: (@Sendable () async throws -> String)? = nil,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.session = session
        self.now = now
        let configuration = WebRemixConfiguration(transport: CatalogTransport(session: CatalogTransport.anonymousSession()), now: now)
        self.version = version ?? { try await configuration.version() }
    }

    static func accountSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        config.httpMaximumConnectionsPerHost = 1
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }

    static func isAllowedURL(_ url: URL?) -> Bool {
        guard let url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.host == "music.youtube.com", parts.port == nil,
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              parts.percentEncodedPath == parts.path, parts.percentEncodedQuery == "prettyPrint=false&alt=json" else { return false }
        return endpoints.contains(String(parts.path.dropFirst("/youtubei/v1/".count)))
            && parts.path.hasPrefix("/youtubei/v1/")
    }

    static func request(endpoint: String, body: [String: CatalogJSON], version: String,
                        account: YouTubeAccountSession, now: Date) throws -> URLRequest {
        guard endpoints.contains(endpoint), version.range(of: #"^1\.[0-9]{8}\.[0-9]{2}\.[0-9]{2}$"#, options: .regularExpression) != nil else {
            throw YouTubeAccountWriteError.invalidTarget
        }
        let url = URL(string: origin + "/youtubei/v1/" + endpoint + "?prettyPrint=false&alt=json")!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "POST"
        var body = body
        body["context"] = ["client": ["clientName": "WEB_REMIX", "clientVersion": .string(version), "hl": "en", "gl": "IN"], "user": [:]]
        request.httpBody = try CatalogJSON.object(body).encoded()
        request.setValue(CatalogTransport.browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("67", forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(version, forHTTPHeaderField: "X-YouTube-Client-Version")
        try account.applyMusicWriteAuth(to: &request, now: now)
        return request
    }

    func ownedPlaylists(access: YouTubeAccountWriteAccess) async throws -> YouTubeAccountWritePlaylistListing {
        guard !busy else { throw YouTubeAccountWriteError.busy }
        busy = true
        defer { busy = false }
        try access.check()
        let version = try await version()
        var items: [MusicCollection] = []
        var seen = Set<String>()
        var tokens = Set<String>()
        var token: String?
        let deadline = ContinuousClock.now.advanced(by: .seconds(90))
        for _ in 0..<10 {
            try access.check()
            guard ContinuousClock.now < deadline else { throw YouTubeAccountWriteError.unreadable }
            var body: [String: CatalogJSON] = ["browseId": .string(YouTubeAccountLibraryClient.playlistsBrowseID)]
            if let token { body = ["continuation": .string(token)] }
            let root = try await send(endpoint: "browse", body: body, version: version, access: access)
            let page = try YouTubeAccountWriteParser.ownedPlaylists(root)
            for item in page.items where seen.insert(item.id).inserted {
                if items.count == 200 { return .init(items: items, isLimited: true) }
                items.append(item)
            }
            guard let next = page.continuation else { return .init(items: items, isLimited: false) }
            guard tokens.insert(next).inserted else { throw YouTubeAccountWriteError.unreadable }
            token = next
        }
        return .init(items: items, isLimited: true)
    }

    func perform(_ action: YouTubeAccountWriteAction, targetID: String, playlistID: String?,
                 access: YouTubeAccountWriteAccess) async throws {
        guard !busy else { throw YouTubeAccountWriteError.busy }
        busy = true
        defer { busy = false }
        try access.check()
        let body = try Self.mutationBody(action, targetID: targetID, playlistID: playlistID)
        let version = try await version()
        if action == .addToPlaylist {
            guard let playlistID else { throw YouTubeAccountWriteError.notOwned }
            let root = try await send(endpoint: "browse", body: ["browseId": .string(playlistID)], version: version, access: access)
            guard YouTubeAccountWriteParser.ownsPlaylist(root, browseID: playlistID) else { throw YouTubeAccountWriteError.notOwned }
        }
        let root = try await send(endpoint: action.endpoint, body: body, version: version, access: access)
        try YouTubeAccountWriteParser.validateEnvelope(root)
        switch action {
        case .addToPlaylist:
            guard YouTubeAccountWriteParser.addAcknowledged(root, videoID: targetID) else { throw YouTubeAccountWriteError.couldNotConfirm }
        case .subscribe, .unsubscribe:
            guard YouTubeAccountWriteParser.subscriptionAcknowledged(root, channelID: targetID, subscribed: action == .subscribe) else {
                throw YouTubeAccountWriteError.couldNotConfirm
            }
        case .like, .removeLike:
            // Like responses lack a documented receipt; a fresh exact-recording account read supplies confirmation.
            guard !root["actions"].array.isEmpty else { throw YouTubeAccountWriteError.couldNotConfirm }
            let verification: CatalogJSON
            do {
                verification = try await send(endpoint: "next", body: [
                    "videoId": .string(targetID), "playlistId": .string("RDAMVM" + targetID),
                    "enablePersistentPlaylistPanel": true, "isAudioOnly": true, "tunerSettingValue": "AUTOMIX_SETTING_NORMAL",
                    "watchEndpointMusicSupportedConfigs": ["watchEndpointMusicConfig": ["hasPersistentPlaylistPanel": true, "musicVideoType": "MUSIC_VIDEO_TYPE_ATV"]],
                ], version: version, access: access)
            } catch { throw YouTubeAccountWriteError.couldNotConfirm }
            guard YouTubeAccountWriteParser.likeState(verification, videoID: targetID) == (action == .like) else {
                throw YouTubeAccountWriteError.couldNotConfirm
            }
        }
        try access.check()
    }

    static func mutationBody(_ action: YouTubeAccountWriteAction, targetID: String, playlistID: String?) throws -> [String: CatalogJSON] {
        switch action {
        case .like, .removeLike:
            guard CatalogText.videoID(targetID) != nil else { throw YouTubeAccountWriteError.invalidTarget }
            return ["target": ["videoId": .string(targetID)]]
        case .addToPlaylist:
            guard CatalogText.videoID(targetID) != nil, let playlistID,
                  let rawID = YouTubeAccountWriteTarget.playlistID(playlistID) else { throw YouTubeAccountWriteError.invalidTarget }
            return ["playlistId": .string(rawID), "actions": [["action": "ACTION_ADD_VIDEO", "addedVideoId": .string(targetID)]]]
        case .subscribe, .unsubscribe:
            guard CatalogText.artistID(targetID) == targetID else { throw YouTubeAccountWriteError.invalidTarget }
            return ["channelIds": [.string(targetID)]]
        }
    }

    private func send(endpoint: String, body: [String: CatalogJSON], version: String,
                      access: YouTubeAccountWriteAccess) async throws -> CatalogJSON {
        try access.check()
        if let retryAfter, retryAfter > now() { throw YouTubeAccountWriteError.rateLimited }
        let request = try Self.request(endpoint: endpoint, body: body, version: version, account: access.session, now: now())
        let transfer = YouTubeAccountWriteTransfer(expectedURL: request.url!)
        do {
            let (data, response) = try await transfer.data(for: request, session: session, access: access)
            try access.check()
            switch response.statusCode {
            case 200...299: break
            case 401, 403: throw YouTubeAccountWriteError.unauthorized
            case 429:
                retryAfter = now().addingTimeInterval(max(1, CatalogTransport.retryDelay(response, now: now()) ?? 30))
                throw YouTubeAccountWriteError.rateLimited
            case 400, 404: throw YouTubeAccountWriteError.rejected
            default: throw YouTubeAccountWriteError.couldNotConfirm
            }
            guard response.mimeType == "application/json" else { throw YouTubeAccountWriteError.couldNotConfirm }
            let json = try CatalogJSON.decode(data)
            try YouTubeAccountWriteParser.validateEnvelope(json)
            return json
        } catch let error as YouTubeAccountWriteError { throw error }
        catch { throw YouTubeAccountWriteError.couldNotConfirm }
    }
}

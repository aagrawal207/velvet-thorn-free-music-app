import Foundation
import OSLog

/// The saved sign-in was refused or is missing; the listener has to sign in again before importing.
enum YouTubeAccountLibraryError: LocalizedError, Equatable, Sendable {
    case unauthorized

    var errorDescription: String? {
        "YouTube did not accept the saved sign-in. Sign in again in Settings."
    }
}

/// One page of an account library listing; `continuation` is an opaque cursor for the next page.
struct YouTubeLibraryPage<Item: Sendable>: Sendable {
    var items: [Item]
    var continuation: String?

    init(items: [Item], continuation: String? = nil) {
        self.items = items
        self.continuation = continuation
    }
}

/// Read-only access to the signed-in account's library, page by page. Fixtures and tests substitute canned pages.
protocol YouTubeAccountLibraryProviding: Sendable {
    func likedSongs(continuation: String?) async throws -> YouTubeLibraryPage<Track>
    func playlists(continuation: String?) async throws -> YouTubeLibraryPage<MusicCollection>
    func playlistTracks(id: String, continuation: String?) async throws -> YouTubeLibraryPage<Track>
    func subscribedArtists(continuation: String?) async throws -> YouTubeLibraryPage<MusicCollection>
    func history(continuation: String?) async throws -> YouTubeLibraryPage<Track>
}

/// Authenticated WEB_REMIX `browse` calls for the account's own library pages. This is the only catalog-shaped
/// transport that carries the saved cookies; `CatalogTransport` stays anonymous. Nothing here writes to the account.
actor YouTubeAccountLibraryClient: YouTubeAccountLibraryProviding {
    static let origin = "https://music.youtube.com"
    static let likedSongsBrowseID = "FEmusic_liked_videos"
    static let playlistsBrowseID = "FEmusic_liked_playlists"
    static let subscriptionsBrowseID = "FEmusic_library_corpus_artists"
    static let historyBrowseID = "FEmusic_history"
    private static let maximumResponseBytes = 8 * 1_024 * 1_024
    private static let log = Logger(subsystem: "com.agraabhi.ganabajana", category: "Account")

    private let session: URLSession
    private let registry: YouTubeSessionRegistry
    private let configuration: WebRemixConfiguration
    private let now: @Sendable () -> Date
    private var retryAfter: Date?

    init(session: URLSession = YouTubeAccountLibraryClient.accountSession(), registry: YouTubeSessionRegistry = .shared,
         bootstrap: CatalogTransport? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.session = session
        self.registry = registry
        // Version discovery is the catalog's anonymous bootstrap; only the browse calls below carry the account.
        self.configuration = WebRemixConfiguration(
            transport: bootstrap ?? CatalogTransport(session: CatalogTransport.anonymousSession(), now: now), now: now)
        self.now = now
    }

    /// Two connections and no automatic cookie handling: the Cookie header is set per request from the Keychain session.
    static func accountSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 35
        configuration.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: configuration)
    }

    // MARK: Pages

    func likedSongs(continuation: String?) async throws -> YouTubeLibraryPage<Track> {
        let (response, cursor, scope) = try await browse(id: Self.likedSongsBrowseID, continuation: continuation, kind: .likes)
        let page = try CatalogParser.browse(response.json, context: CatalogParser.RowContext(keepsVideoRows: true))
        return try Self.tracks(page, response: response, previous: cursor, scope: scope)
    }

    func history(continuation: String?) async throws -> YouTubeLibraryPage<Track> {
        let (response, cursor, scope) = try await browse(id: Self.historyBrowseID, continuation: continuation, kind: .history)
        let page = try CatalogParser.browse(response.json, context: CatalogParser.RowContext(keepsVideoRows: true))
        return try Self.tracks(page, response: response, previous: cursor, scope: scope)
    }

    func playlistTracks(id: String, continuation: String?) async throws -> YouTubeLibraryPage<Track> {
        guard let id = CatalogText.identifier(id), id.hasPrefix("VL") else { throw MusicServiceError.invalidResponse }
        let (response, cursor, scope) = try await browse(id: id, continuation: continuation, kind: .playlists)
        let page = try CatalogParser.browse(response.json, id: id)
        return try Self.tracks(page, response: response, previous: cursor, scope: scope)
    }

    func playlists(continuation: String?) async throws -> YouTubeLibraryPage<MusicCollection> {
        let (response, cursor, scope) = try await browse(id: Self.playlistsBrowseID, continuation: continuation, kind: .playlists)
        var page = try CatalogParser.browse(response.json, id: Self.playlistsBrowseID)
        page.collections = YouTubeAccountLibraryParser.playlists(page.collections)
        page.continuation = page.continuation ?? YouTubeAccountLibraryParser.gridContinuation(response.json)
        let attached = try CatalogContinuation.attach(to: page, response: response, previous: cursor, scope: scope)
        return YouTubeLibraryPage(items: attached.collections, continuation: attached.continuation)
    }

    func subscribedArtists(continuation: String?) async throws -> YouTubeLibraryPage<MusicCollection> {
        let (response, cursor, scope) = try await browse(id: Self.subscriptionsBrowseID, continuation: continuation, kind: .subscriptions)
        var page = CatalogPage(collections: YouTubeAccountLibraryParser.artists(response.json))
        page.continuation = CatalogParser.continuation(response.json) ?? YouTubeAccountLibraryParser.gridContinuation(response.json)
        let attached = try CatalogContinuation.attach(to: page, response: response, previous: cursor, scope: scope)
        return YouTubeLibraryPage(items: attached.collections, continuation: attached.continuation)
    }

    private static func tracks(_ page: CatalogPage, response: CatalogResponse, previous: CatalogContinuation?,
                               scope: String) throws -> YouTubeLibraryPage<Track> {
        let attached = try CatalogContinuation.attach(to: page, response: response, previous: previous, scope: scope)
        return YouTubeLibraryPage(items: attached.tracks, continuation: attached.continuation)
    }

    // MARK: Transport

    /// The request shape, exposed so tests can check the account headers without a network round trip.
    static func request(browseID: String, cursor: CatalogContinuation?, version: String,
                        session: YouTubeAccountSession?, now: Date) throws -> URLRequest {
        var client: [String: CatalogJSON] = ["clientName": "WEB_REMIX", "clientVersion": .string(version), "hl": "en", "gl": "IN"]
        if let visitor = cursor?.visitorData { client["visitorData"] = .string(visitor) }
        var body: [String: CatalogJSON] = ["context": ["client": .object(client)]]
        if let cursor { body["continuation"] = .string(cursor.token) } else { body["browseId"] = .string(browseID) }
        let url = CatalogTransport.musicURL.appending(path: "youtubei/v1/browse")
            .appending(queryItems: [URLQueryItem(name: "prettyPrint", value: "false")])
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.httpBody = try CatalogJSON.object(body).encoded()
        request.httpShouldHandleCookies = false
        request.setValue(CatalogTransport.browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("67", forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(version, forHTTPHeaderField: "X-YouTube-Client-Version")
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.setValue(origin + "/", forHTTPHeaderField: "Referer")
        session?.apply(to: &request, origin: origin, now: now)
        return request
    }

    private func browse(id: String, continuation: String?, kind: YouTubeLibraryKind) async throws
        -> (CatalogResponse, CatalogContinuation?, String) {
        try Task.checkCancellation()
        guard let account = registry.session else {
            Self.log.notice("event=import_request kind=\(kind.rawValue, privacy: .public) status=unauthorized")
            throw YouTubeAccountLibraryError.unauthorized
        }
        let scope = "account|\(id)"
        let cursor = try continuation.map { try CatalogContinuation.decode($0, scope: scope) }
        let version = try await configuration.version()
        try Task.checkCancellation()
        let request = try Self.request(browseID: id, cursor: cursor, version: version, session: account, now: now())
        let (data, fetchedAt) = try await fetch(request, kind: kind)
        try Task.checkCancellation()
        let json = try CatalogJSON.decode(data)
        guard json.isObject else { throw MusicServiceError.invalidResponse }
        if json["error"].isObject {
            let code = json["error"]["code"].int ?? 0
            if code == 401 || code == 403 {
                Self.log.notice("event=import_request kind=\(kind.rawValue, privacy: .public) status=unauthorized")
                throw YouTubeAccountLibraryError.unauthorized
            }
            throw MusicServiceError.invalidResponse
        }
        Self.log.info("event=import_request kind=\(kind.rawValue, privacy: .public) status=ok")
        return (CatalogResponse(json: json, fetchedAt: fetchedAt), cursor, scope)
    }

    private func fetch(_ request: URLRequest, kind: YouTubeLibraryKind) async throws -> (Data, Date) {
        if let retryAfter, retryAfter > now() {
            Self.log.notice("event=import_request kind=\(kind.rawValue, privacy: .public) status=rateLimited")
            throw MusicServiceError.rateLimited
        }
        for attempt in 0...1 {
            try Task.checkCancellation()
            do {
                let (data, response) = try await session.boundedData(for: request, maximumBytes: Self.maximumResponseBytes)
                try Task.checkCancellation()
                guard let response = response as? HTTPURLResponse else { throw MusicServiceError.invalidResponse }
                let date = now()
                switch response.statusCode {
                case 200...299:
                    guard !data.isEmpty else { throw MusicServiceError.invalidResponse }
                    return (data, date)
                case 401, 403:
                    Self.log.notice("event=import_request kind=\(kind.rawValue, privacy: .public) status=unauthorized")
                    throw YouTubeAccountLibraryError.unauthorized
                case 429:
                    retryAfter = date.addingTimeInterval(CatalogTransport.retryDelay(response, now: date) ?? 30)
                    Self.log.notice("event=import_request kind=\(kind.rawValue, privacy: .public) status=rateLimited")
                    throw MusicServiceError.rateLimited
                case 500...599:
                    if let delay = CatalogTransport.retryDelay(response, now: date), delay > 2 {
                        retryAfter = date.addingTimeInterval(delay)
                        throw MusicServiceError.unavailable("YouTube is temporarily unavailable. Try again later.")
                    }
                    if attempt == 0 {
                        try await Task.sleep(for: .seconds(max(0.35, CatalogTransport.retryDelay(response, now: date) ?? 0.35)))
                        continue
                    }
                    throw MusicServiceError.unavailable("YouTube is temporarily unavailable. Try again later.")
                default:
                    throw MusicServiceError.invalidResponse
                }
            } catch is BoundedResponseError {
                Self.log.notice("event=import_request kind=\(kind.rawValue, privacy: .public) status=failed")
                throw MusicServiceError.invalidResponse
            } catch let error as URLError {
                if error.code == .cancelled || Task.isCancelled { throw CancellationError() }
                if attempt == 0, [.timedOut, .networkConnectionLost].contains(error.code) {
                    try await Task.sleep(for: .milliseconds(350))
                    continue
                }
                Self.log.notice("event=import_request kind=\(kind.rawValue, privacy: .public) status=failed")
                throw MusicServiceError.network(error.localizedDescription)
            } catch let error as MusicServiceError {
                if case .rateLimited = error {} else {
                    Self.log.notice("event=import_request kind=\(kind.rawValue, privacy: .public) status=failed")
                }
                throw error
            }
        }
        throw MusicServiceError.invalidResponse
    }
}

/// Row shapes the catalog parser does not cover: library artist rows and grid continuations.
enum YouTubeAccountLibraryParser {
    /// Liked Music is imported through likes and saved podcast episodes are not music.
    private static let excludedPlaylistIDs: Set<String> = ["VLLM", "VLSE"]

    static func playlists(_ collections: [MusicCollection]) -> [MusicCollection] {
        collections.filter { $0.kind == .playlist && $0.id.hasPrefix("VL") && !excludedPlaylistIDs.contains($0.id) }
    }

    /// Subscription rows link the channel (`UC...`); library artist rows link the in-library page (`MPLAUC...`),
    /// which wraps the same channel id.
    static func artists(_ root: CatalogJSON) -> [MusicCollection] {
        var seen = Set<String>()
        return root.values(for: "musicResponsiveListItemRenderer").compactMap { renderer -> MusicCollection? in
            let columns = renderer["flexColumns"].array.map { $0["musicResponsiveListItemFlexColumnRenderer"]["text"] }
            guard let id = artistID(renderer["navigationEndpoint"]["browseEndpoint"]["browseId"].string),
                  let name = CatalogText.clean(columns.first?.text), name.utf8.count <= 1_024,
                  seen.insert(id).inserted else { return nil }
            let subtitle = columns.dropFirst().compactMap { CatalogText.clean($0.text) }.first ?? ""
            return MusicCollection(id: id, title: name, subtitle: subtitle, artworkURL: CatalogText.artwork(renderer), kind: .artist)
        }
    }

    static func artistID(_ value: String?) -> String? {
        guard let id = CatalogText.identifier(value) else { return nil }
        return CatalogText.artistID(id.hasPrefix("MPLA") ? String(id.dropFirst(4)) : id)
    }

    static func gridContinuation(_ root: CatalogJSON) -> String? {
        for container in root.values(for: "gridRenderer") + root.values(for: "gridContinuation") {
            for data in container["continuations"].array {
                if let token = CatalogText.clean(data["nextContinuationData"]["continuation"].string), token.utf8.count <= 65_536 {
                    return token
                }
            }
        }
        return nil
    }
}

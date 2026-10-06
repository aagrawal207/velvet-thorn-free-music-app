import Foundation
import XCTest
@testable import GanaBajana

// MARK: - Fixtures and stubs

private enum ImportFixtures {
    static let now = Date(timeIntervalSince1970: 1_790_000_000)

    static func data(_ name: String) throws -> Data {
        let bundle = Bundle(for: YouTubeImportClientTests.self)
        let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "json")
            ?? bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    static func session() -> YouTubeAccountSession {
        YouTubeAccountSession(cookies: [
            StoredCookie(name: "SAPISID", value: "abc123", domain: ".youtube.com"),
            StoredCookie(name: "SID", value: "sid-value", domain: ".youtube.com"),
            StoredCookie(name: "NID", value: "google-only", domain: ".google.com"),
        ], signedInAt: now)
    }

    static func track(_ id: String, title: String? = nil, audio: Bool = true) -> Track {
        Track(id: id, title: title ?? "Song \(id)", artists: ["Artist \(id)"], duration: 200, isAudioRecording: audio)
    }

    static func artist(_ id: String, name: String) -> MusicCollection {
        MusicCollection(id: id, title: name, subtitle: "1M subscribers", kind: .artist)
    }

    static func playlist(_ id: String, title: String) -> MusicCollection {
        MusicCollection(id: id, title: title, subtitle: "Playlist", kind: .playlist)
    }
}

/// Routes mocked authenticated browse calls by browse id or continuation token; a body/status per key.
private struct ImportRouter: Sendable {
    var browse: [String: Data] = [:]
    var continuations: [String: Data] = [:]
    var statuses: [String: Int] = [:]
    var headers: [String: [String: String]] = [:]

    func stub(_ request: URLRequest) throws -> CatalogStub {
        if request.httpMethod == "GET" { return CatalogStub(data: CatalogFixtures.bootstrap) }
        guard request.url?.path.hasSuffix("/browse") == true else { throw URLError(.unsupportedURL) }
        let body = try CatalogJSON.decode(request.httpBody ?? Data())
        let key = body["continuation"].string ?? body["browseId"].string ?? ""
        let known = continuations[key] ?? browse[key]
        var stub = CatalogStub(status: statuses[key] ?? (known == nil ? 404 : 200), data: known ?? Data("{}".utf8))
        if let extra = headers[key] { stub.headers.merge(extra) { _, new in new } }
        return stub
    }
}

/// In-memory account library with per-kind pages and failure injection; records every page request.
private final class StubAccountLibrary: YouTubeAccountLibraryProviding, @unchecked Sendable {
    enum Failure: Error { case network }

    private let lock = NSLock()
    var likes: [YouTubeLibraryPage<Track>] = []
    var playlistList: [YouTubeLibraryPage<MusicCollection>] = []
    var playlistPages: [String: [YouTubeLibraryPage<Track>]] = [:]
    var artists: [YouTubeLibraryPage<MusicCollection>] = []
    var historyRows: [YouTubeLibraryPage<Track>] = []
    var failing: Set<YouTubeLibraryKind> = []
    var unauthorized: Set<YouTubeLibraryKind> = []
    var rateLimited: Set<YouTubeLibraryKind> = []
    /// Resumed by the test to release the second liked-songs page; nil means pages arrive at once.
    var likesGate: (@Sendable () async -> Void)?
    private(set) var requests: [String] = []

    private func record(_ key: String) { lock.withLock { requests.append(key) } }

    private func page<Item: Sendable>(_ pages: [YouTubeLibraryPage<Item>], continuation: String?) -> YouTubeLibraryPage<Item> {
        let index = continuation.flatMap { Int($0.split(separator: ":").last ?? "") } ?? 0
        guard pages.indices.contains(index) else { return YouTubeLibraryPage(items: []) }
        return pages[index]
    }

    func likedSongs(continuation: String?) async throws -> YouTubeLibraryPage<Track> {
        record("likes:\(continuation ?? "first")")
        if unauthorized.contains(.likes) { throw YouTubeAccountLibraryError.unauthorized }
        if rateLimited.contains(.likes) { throw MusicServiceError.rateLimited }
        if failing.contains(.likes) { throw Failure.network }
        if continuation != nil, let likesGate { await likesGate() }
        return page(likes, continuation: continuation)
    }

    func playlists(continuation: String?) async throws -> YouTubeLibraryPage<MusicCollection> {
        record("playlists:\(continuation ?? "first")")
        if unauthorized.contains(.playlists) { throw YouTubeAccountLibraryError.unauthorized }
        if rateLimited.contains(.playlists) { throw MusicServiceError.rateLimited }
        if failing.contains(.playlists) { throw Failure.network }
        return page(playlistList, continuation: continuation)
    }

    func playlistTracks(id: String, continuation: String?) async throws -> YouTubeLibraryPage<Track> {
        record("playlist:\(id):\(continuation ?? "first")")
        guard let pages = playlistPages[id] else { throw Failure.network }
        return page(pages, continuation: continuation)
    }

    func subscribedArtists(continuation: String?) async throws -> YouTubeLibraryPage<MusicCollection> {
        record("artists:\(continuation ?? "first")")
        if unauthorized.contains(.subscriptions) { throw YouTubeAccountLibraryError.unauthorized }
        if rateLimited.contains(.subscriptions) { throw MusicServiceError.rateLimited }
        if failing.contains(.subscriptions) { throw Failure.network }
        return page(artists, continuation: continuation)
    }

    func history(continuation: String?) async throws -> YouTubeLibraryPage<Track> {
        record("history:\(continuation ?? "first")")
        if unauthorized.contains(.history) { throw YouTubeAccountLibraryError.unauthorized }
        if failing.contains(.history) { throw Failure.network }
        return page(historyRows, continuation: continuation)
    }
}

// MARK: - Client

final class YouTubeImportClientTests: XCTestCase {
    private var mocks: [CatalogMockSession] = []

    override func tearDown() {
        mocks.forEach { $0.close() }
        mocks.removeAll()
        super.tearDown()
    }

    private func makeClient(_ router: ImportRouter, signedIn: Bool = true) -> (YouTubeAccountLibraryClient, CatalogMockState) {
        let mock = CatalogMockSession(handler: { try router.stub($0) })
        mocks.append(mock)
        let registry = YouTubeSessionRegistry()
        if signedIn { registry.update(session: ImportFixtures.session()) }
        let clock = ImportFixtures.now
        let client = YouTubeAccountLibraryClient(session: mock.session, registry: registry,
                                                 bootstrap: CatalogTransport(session: mock.session, now: { clock }), now: { clock })
        return (client, mock.state)
    }

    private func body(_ request: URLRequest) throws -> CatalogJSON {
        try CatalogJSON.decode(try XCTUnwrap(request.httpBody))
    }

    func testRequestCarriesTheAccountOnlyWithASession() throws {
        let signed = try YouTubeAccountLibraryClient.request(browseID: YouTubeAccountLibraryClient.likedSongsBrowseID, cursor: nil,
                                                             version: CatalogFixtures.version, session: ImportFixtures.session(),
                                                             now: ImportFixtures.now)
        XCTAssertEqual(signed.url?.absoluteString, "https://music.youtube.com/youtubei/v1/browse?prettyPrint=false")
        XCTAssertEqual(signed.httpMethod, "POST")
        let cookie = try XCTUnwrap(signed.value(forHTTPHeaderField: "Cookie"))
        XCTAssertTrue(cookie.contains("SAPISID=abc123") && cookie.contains("SID=sid-value"), cookie)
        XCTAssertFalse(cookie.contains("NID="), "Google-domain cookies never travel to YouTube Music")
        let authorization = try XCTUnwrap(signed.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(authorization, "SAPISIDHASH 1790000000_" + AccountFixtures.sha1Hex("1790000000 abc123 https://music.youtube.com"),
                       "The digest is bound to the music.youtube.com origin")
        XCTAssertEqual(signed.value(forHTTPHeaderField: "X-Origin"), "https://music.youtube.com")
        XCTAssertEqual(signed.value(forHTTPHeaderField: "X-Goog-AuthUser"), "0")
        XCTAssertEqual(signed.value(forHTTPHeaderField: "X-YouTube-Client-Name"), "67")
        XCTAssertEqual(signed.value(forHTTPHeaderField: "X-YouTube-Client-Version"), CatalogFixtures.version)
        XCTAssertEqual(signed.value(forHTTPHeaderField: "Origin"), "https://music.youtube.com")
        XCTAssertFalse(signed.httpShouldHandleCookies)
        let payload = try body(signed)
        XCTAssertEqual(payload["browseId"].string, "FEmusic_liked_videos")
        XCTAssertEqual(payload["context"]["client"]["clientName"].string, "WEB_REMIX")
        XCTAssertEqual(payload["context"]["client"]["clientVersion"].string, CatalogFixtures.version)
        XCTAssertEqual(payload["context"]["client"]["hl"].string, "en")
        XCTAssertEqual(payload["context"]["client"]["gl"].string, "IN")

        let anonymous = try YouTubeAccountLibraryClient.request(browseID: "FEmusic_history", cursor: nil, version: CatalogFixtures.version,
                                                                session: nil, now: ImportFixtures.now)
        for header in ["Cookie", "Authorization", "X-Origin", "X-Goog-AuthUser", "X-Youtube-Bootstrap-Logged-In"] {
            XCTAssertNil(anonymous.value(forHTTPHeaderField: header), "\(header) must be absent without a session")
        }

        let cursor = CatalogContinuation(token: "page-2", visitorData: "visitor", scope: "account|FEmusic_history")
        let continued = try YouTubeAccountLibraryClient.request(browseID: "FEmusic_history", cursor: cursor, version: CatalogFixtures.version,
                                                                session: ImportFixtures.session(), now: ImportFixtures.now)
        let continuedBody = try body(continued)
        XCTAssertEqual(continuedBody["continuation"].string, "page-2")
        XCTAssertEqual(continuedBody["browseId"], .null, "A continuation request carries the token instead of the browse id")
        XCTAssertEqual(continuedBody["context"]["client"]["visitorData"].string, "visitor")
    }

    func testNoSessionThrowsUnauthorizedBeforeAnyRequest() async throws {
        var router = ImportRouter()
        router.browse[YouTubeAccountLibraryClient.likedSongsBrowseID] = try ImportFixtures.data("youtube-account-liked-songs")
        let (client, state) = makeClient(router, signedIn: false)
        do {
            _ = try await client.likedSongs(continuation: nil)
            XCTFail("An anonymous client cannot read an account library")
        } catch let error as YouTubeAccountLibraryError {
            XCTAssertEqual(error, .unauthorized)
        }
        XCTAssertTrue(state.requests.isEmpty, "Nothing is sent without a session, not even the bootstrap")
    }

    func testLikedSongsKeepAudioAndVideoRowsAndFollowTheContinuation() async throws {
        var router = ImportRouter()
        router.browse[YouTubeAccountLibraryClient.likedSongsBrowseID] = try ImportFixtures.data("youtube-account-liked-songs")
        router.continuations["4qmFsgLikedPage2Token"] = try ImportFixtures.data("youtube-account-liked-songs-continuation")
        let (client, state) = makeClient(router)

        let first = try await client.likedSongs(continuation: nil)
        XCTAssertEqual(first.items.map(\.id), ["fsiPzT50ZiM", "J7p4bzqLvCw", "kJQP7kiw5Fk"],
                       "Podcast and greyed-out rows are dropped; the music video stays")
        XCTAssertEqual(first.items.map(\.isAudioRecording), [true, true, false])
        XCTAssertEqual(first.items.map(\.title), ["Tum Hi Ho", "Blinding Lights", "Despacito"])
        XCTAssertEqual(first.items[0].credits.map(\.name), ["Arijit Singh"])
        XCTAssertEqual(first.items[0].credits.first?.id, "UCDxKh1gFWeYsqePvgVzmPoQ")
        XCTAssertEqual(first.items[0].albumTitle, "Aashiqui 2")
        XCTAssertEqual(first.items[0].duration, 262)
        XCTAssertNotNil(first.items[2].artworkURL)
        let token = try XCTUnwrap(first.continuation)

        let second = try await client.likedSongs(continuation: token)
        XCTAssertEqual(second.items.map(\.id), ["NJAv_7lHUIU", "fsiPzT50ZiM"])
        XCTAssertNil(second.continuation)

        let posts = state.requests.filter { $0.httpMethod == "POST" }
        XCTAssertEqual(posts.count, 2)
        XCTAssertEqual(try body(posts[0])["browseId"].string, "FEmusic_liked_videos")
        let continued = try body(posts[1])
        XCTAssertEqual(continued["continuation"].string, "4qmFsgLikedPage2Token")
        XCTAssertEqual(continued["context"]["client"]["visitorData"].string, "CgtmaXh0dXJlLXZpc2l0b3I%3D",
                       "The first page's visitor travels with its continuation")
        for request in posts {
            XCTAssertNotNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("SAPISIDHASH ") == true)
        }
        XCTAssertEqual(state.requests.filter { $0.httpMethod == "GET" }.count, 1, "One anonymous bootstrap for the version")
        XCTAssertNil(state.requests.first { $0.httpMethod == "GET" }?.value(forHTTPHeaderField: "Cookie"),
                     "The version bootstrap stays account-cookie-free")
    }

    func testPlaylistListSkipsSystemEntriesAndFollowsTheGridContinuation() async throws {
        var router = ImportRouter()
        router.browse[YouTubeAccountLibraryClient.playlistsBrowseID] = try ImportFixtures.data("youtube-account-playlists")
        router.continuations["4qmFsgPlaylistsPage2Token"] = try ImportFixtures.data("youtube-account-playlists-continuation")
        let (client, _) = makeClient(router)

        let first = try await client.playlists(continuation: nil)
        XCTAssertEqual(first.items.map(\.id), ["VLPLfixtureLateNight0000000000001", "VLRDCLAK5uy_fixtureHitlist000000000000"],
                       "New playlist, Liked Music and Episodes for Later are not importable playlists")
        XCTAssertEqual(first.items.map(\.title), ["Late night favorites", "Bollywood Hitlist"])
        XCTAssertTrue(first.items.allSatisfy { $0.kind == .playlist && $0.artworkURL != nil })
        let second = try await client.playlists(continuation: try XCTUnwrap(first.continuation))
        XCTAssertEqual(second.items.map(\.title), ["Road trip"])
        XCTAssertNil(second.continuation)
    }

    func testSubscriptionsParseChannelAndLibraryArtistIDs() async throws {
        var router = ImportRouter()
        router.browse[YouTubeAccountLibraryClient.subscriptionsBrowseID] = try ImportFixtures.data("youtube-account-subscriptions")
        router.continuations["4qmFsgArtistsPage2Token"] = try ImportFixtures.data("youtube-account-subscriptions-continuation")
        let (client, _) = makeClient(router)

        let first = try await client.subscribedArtists(continuation: nil)
        XCTAssertEqual(first.items.map(\.id), ["UCDxKh1gFWeYsqePvgVzmPoQ", "UCCTN01plFzn4npREHKT2_9Q"],
                       "The MPLA library prefix is stripped; a user upload channel is not an artist")
        XCTAssertEqual(first.items.map(\.title), ["Arijit Singh", "Pritam"])
        XCTAssertEqual(first.items.map(\.subtitle), ["26.4M subscribers", "12 songs"])
        XCTAssertTrue(first.items.allSatisfy { $0.kind == .artist })
        XCTAssertNotNil(first.items[0].artworkURL)
        let second = try await client.subscribedArtists(continuation: try XCTUnwrap(first.continuation))
        XCTAssertEqual(second.items.map(\.id), ["UC0WP5P-ufpRfjbNrmOWwLBQ", "UCDxKh1gFWeYsqePvgVzmPoQ"])
        XCTAssertNil(second.continuation)
    }

    func testHistoryListsDayShelvesMostRecentFirstWithoutRepeats() async throws {
        var router = ImportRouter()
        router.browse[YouTubeAccountLibraryClient.historyBrowseID] = try ImportFixtures.data("youtube-account-history")
        let (client, _) = makeClient(router)
        let page = try await client.history(continuation: nil)
        XCTAssertEqual(page.items.map(\.id), ["NJAv_7lHUIU", "kJQP7kiw5Fk", "fsiPzT50ZiM"],
                       "Today's rows lead; yesterday's repeat of Kesariya is not listed twice")
        XCTAssertEqual(page.items.map(\.isAudioRecording), [true, false, true])
        XCTAssertEqual(page.items[0].duration, 269)
        XCTAssertNil(page.continuation)
    }

    func testPlaylistTracksUseTheRecordedPlaylistPageShape() async throws {
        var router = ImportRouter()
        let id = "VLPLCIh8-uf9gCfBR8HwjHjUWgp55gosCk5S"
        router.browse[id] = try ImportFixtures.data("youtube-playlist-browse-bollywood-party")
        let (client, state) = makeClient(router)
        let page = try await client.playlistTracks(id: id, continuation: nil)
        XCTAssertEqual(page.items.map(\.id), ["_wMsvhz8YSk", "ATS1d6E-ivs", "2wqXLa3vCk0", "pwKmLIPvEjI", "lshhwnuUUO8"])
        XCTAssertNil(page.continuation)
        XCTAssertEqual(try body(try XCTUnwrap(state.requests.last { $0.httpMethod == "POST" }))["browseId"].string, id)
        do {
            _ = try await client.playlistTracks(id: "PLnotPrefixed", continuation: nil)
            XCTFail("Only VL browse ids are playlists")
        } catch {}
    }

    func testHTTPErrorsMapToUnauthorizedAndRateLimited() async throws {
        var router = ImportRouter()
        router.browse[YouTubeAccountLibraryClient.likedSongsBrowseID] = Data("{}".utf8)
        router.statuses[YouTubeAccountLibraryClient.likedSongsBrowseID] = 403
        router.browse[YouTubeAccountLibraryClient.historyBrowseID] = Data("{}".utf8)
        router.statuses[YouTubeAccountLibraryClient.historyBrowseID] = 429
        router.headers[YouTubeAccountLibraryClient.historyBrowseID] = ["Retry-After": "120"]
        router.browse[YouTubeAccountLibraryClient.subscriptionsBrowseID] = Data(#"{"error":{"code":401,"message":"Request had invalid authentication credentials.","status":"UNAUTHENTICATED"}}"#.utf8)
        let (client, state) = makeClient(router)

        do {
            _ = try await client.likedSongs(continuation: nil)
            XCTFail("403 must surface as unauthorized")
        } catch let error as YouTubeAccountLibraryError { XCTAssertEqual(error, .unauthorized) }

        do {
            _ = try await client.subscribedArtists(continuation: nil)
            XCTFail("An UNAUTHENTICATED envelope must surface as unauthorized")
        } catch let error as YouTubeAccountLibraryError { XCTAssertEqual(error, .unauthorized) }

        do {
            _ = try await client.history(continuation: nil)
            XCTFail("429 must surface as rate limited")
        } catch let error as MusicServiceError {
            guard case .rateLimited = error else { return XCTFail("Unexpected \(error)") }
        }
        let before = state.requests.count
        do {
            _ = try await client.history(continuation: nil)
            XCTFail("Retry-After blocks further requests")
        } catch let error as MusicServiceError {
            guard case .rateLimited = error else { return XCTFail("Unexpected \(error)") }
        }
        XCTAssertEqual(state.requests.count, before, "The host stays blocked for the Retry-After window without a new request")
    }

    func testOversizedBodiesAreRejectedWhileReceiving() async throws {
        var router = ImportRouter()
        router.browse[YouTubeAccountLibraryClient.likedSongsBrowseID] = Data(repeating: 0x20, count: 8 * 1_024 * 1_024 + 1)
        let (client, _) = makeClient(router)
        do {
            _ = try await client.likedSongs(continuation: nil)
            XCTFail("Bodies above 8 MiB are refused")
        } catch let error as MusicServiceError {
            guard case .invalidResponse = error else { return XCTFail("Unexpected \(error)") }
        }
    }
}

// MARK: - Importer

@MainActor
final class YouTubeImporterTests: XCTestCase {
    // XCTest instantiates one case per test method, so each test gets its own directory.
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("GanaBajana-ImportTests-\(UUID().uuidString)", isDirectory: true)

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makeAccount(signedIn: Bool = true) -> YouTubeAccountStore {
        let secrets = MemorySecretStore(initial: signedIn ? [YouTubeAccountStore.secretKey: try! JSONEncoder().encode(ImportFixtures.session())] : [:])
        return YouTubeAccountStore(secrets: secrets, registry: YouTubeSessionRegistry(), now: { ImportFixtures.now })
    }

    private func makeImporter(_ client: StubAccountLibrary, library: LibraryStore, account: YouTubeAccountStore? = nil,
                              bounds: YouTubeImportBounds = YouTubeImportBounds(), now: Date = ImportFixtures.now) -> YouTubeLibraryImporter {
        YouTubeLibraryImporter(library: library, account: account ?? makeAccount(), client: client,
                               ledgerStore: YouTubeImportLedgerStore(url: directory.appendingPathComponent("youtube-import.json")),
                               bounds: bounds, now: { now })
    }

    private func fullStub() -> StubAccountLibrary {
        let client = StubAccountLibrary()
        client.likes = [YouTubeLibraryPage(items: [ImportFixtures.track("like-1"), ImportFixtures.track("like-2", audio: false)], continuation: "likes:1"),
                        YouTubeLibraryPage(items: [ImportFixtures.track("like-3"), ImportFixtures.track("like-1")])]
        client.playlistList = [YouTubeLibraryPage(items: [ImportFixtures.playlist("VLPLremote1", title: "Road trip"),
                                                          ImportFixtures.playlist("VLPLremote2", title: "Late night favorites")])]
        client.playlistPages = [
            "VLPLremote1": [YouTubeLibraryPage(items: [ImportFixtures.track("road-1"), ImportFixtures.track("road-2")])],
            "VLPLremote2": [YouTubeLibraryPage(items: [ImportFixtures.track("night-1")])],
        ]
        client.artists = [YouTubeLibraryPage(items: [ImportFixtures.artist("UCartist000000000000001", name: "Pritam"),
                                                     ImportFixtures.artist("UCartist000000000000002", name: "Dua Lipa")])]
        client.historyRows = [YouTubeLibraryPage(items: [ImportFixtures.track("hist-1"), ImportFixtures.track("like-1"),
                                                         ImportFixtures.track("hist-1"), ImportFixtures.track("hist-2")])]
        return client
    }

    private let everything = YouTubeImportSelection(kinds: Set(YouTubeLibraryKind.allCases))

    func testFirstImportAppliesEveryKindAndASecondRunChangesNothing() async throws {
        let library = LibraryStore(directory: directory, now: { ImportFixtures.now })
        library.toggleFavorite(ImportFixtures.track("local-like"))
        library.toggleDislike(ImportFixtures.track("like-3"))
        let existing = library.createPlaylist(name: "Late Night Favorites", tracks: [ImportFixtures.track("mine")])
        library.follow(FollowedArtist(id: "UCartist000000000000002", name: "Dua Lipa"))
        let client = fullStub()
        let importer = makeImporter(client, library: library)
        XCTAssertNil(importer.lastImportedAt)

        await importer.run(everything)

        XCTAssertEqual(importer.runStatus, .finished)
        XCTAssertEqual(library.favorites.map(\.id), ["like-1", "like-2", "local-like"],
                       "Remote likes join in remote order ahead of local ones; the disliked song and the repeat are skipped")
        XCTAssertEqual(library.favorites[1].isAudioRecording, false, "A liked music video keeps its video entry")
        XCTAssertTrue(library.isDisliked(ImportFixtures.track("like-3")))
        XCTAssertEqual(importer.progress[.likes]?.fetched, 4)
        XCTAssertEqual(importer.progress[.likes]?.applied, 2)
        XCTAssertEqual(client.requests.filter { $0.hasPrefix("likes:") }, ["likes:first", "likes:likes:1"])

        let names = library.playlists.map(\.name)
        XCTAssertEqual(Set(names), ["Late Night Favorites", "Road trip", "Late night favorites (YouTube)", YouTubeImportLedger.historyPlaylistName])
        XCTAssertEqual(library.playlists.first { $0.id == existing }?.tracks.map(\.id), ["mine"], "A same-named local playlist is left alone")
        XCTAssertEqual(library.playlists.first { $0.name == "Road trip" }?.tracks.map(\.id), ["road-1", "road-2"])
        XCTAssertEqual(importer.progress[.playlists]?.applied, 2)
        XCTAssertEqual(importer.progress[.playlists]?.updated, 0)

        XCTAssertEqual(Set(library.followedArtists.map(\.id)), ["UCartist000000000000001", "UCartist000000000000002"])
        XCTAssertEqual(importer.progress[.subscriptions]?.applied, 1, "An existing follow is not repeated")
        XCTAssertFalse(library.followedArtists.first { $0.id == "UCartist000000000000001" }!.hasEstablishedReleaseBaseline,
                       "The watcher establishes the release baseline later; nothing is announced for today's releases")

        let history = try XCTUnwrap(library.playlists.first { $0.name == YouTubeImportLedger.historyPlaylistName })
        XCTAssertEqual(history.tracks.map(\.id), ["hist-1", "like-1", "hist-2"], "Unique rows in recency order")
        XCTAssertEqual(importer.progress[.history]?.applied, 3)
        XCTAssertEqual(importer.summary, "Liked 2 songs, added 2 playlists, followed 1 artist, added 3 songs to YouTube Music history.")
        XCTAssertEqual(importer.lastImportedAt, ImportFixtures.now)
        XCTAssertEqual(importer.ledger.playlists["VLPLremote1"], library.playlists.first { $0.name == "Road trip" }?.id)
        XCTAssertEqual(importer.ledger.historyPlaylistID, history.id)
        XCTAssertEqual(importer.ledger.count(for: .likes), 2)

        let before = library.playlists
        let favorites = library.favorites
        let follows = library.followedArtists
        await importer.run(everything)
        XCTAssertEqual(library.playlists, before, "A second import creates nothing and reorders nothing")
        XCTAssertEqual(library.favorites, favorites)
        XCTAssertEqual(library.followedArtists, follows)
        XCTAssertEqual(importer.summary, "Nothing new to import.")
        XCTAssertEqual(importer.progress[.playlists]?.applied, 0)
        XCTAssertEqual(importer.progress[.playlists]?.updated, 0)
    }

    func testReimportIsAdditiveOnlyAndUpdatesMappedPlaylists() async throws {
        let library = LibraryStore(directory: directory, now: { ImportFixtures.now })
        let client = fullStub()
        let importer = makeImporter(client, library: library)
        await importer.run(everything)
        let roadTrip = try XCTUnwrap(library.playlists.first { $0.name == "Road trip" })
        library.toggleFavorite(ImportFixtures.track("like-1"))
        XCTAssertFalse(library.isFavorite(ImportFixtures.track("like-1")))

        // The account lost a like and a playlist song and gained one of each.
        client.likes = [YouTubeLibraryPage(items: [ImportFixtures.track("like-2"), ImportFixtures.track("like-4")])]
        client.playlistPages["VLPLremote1"] = [YouTubeLibraryPage(items: [ImportFixtures.track("road-2"), ImportFixtures.track("road-3")])]
        client.historyRows = [YouTubeLibraryPage(items: [ImportFixtures.track("hist-9"), ImportFixtures.track("hist-2")])]
        await importer.run(everything)

        XCTAssertEqual(library.favorites.map(\.id), ["like-4", "like-3", "like-2"], "Nothing is unliked; a locally removed like stays removed")
        let updated = try XCTUnwrap(library.playlists.first { $0.id == roadTrip.id })
        XCTAssertEqual(updated.tracks.map(\.id), ["road-1", "road-2", "road-3"], "Removed remote songs stay; the new one appends")
        XCTAssertEqual(library.playlists.filter { $0.name.hasPrefix("Road trip") }.count, 1, "The mapped playlist is updated, not duplicated")
        XCTAssertEqual(importer.progress[.playlists]?.applied, 0)
        XCTAssertEqual(importer.progress[.playlists]?.updated, 1)
        let history = try XCTUnwrap(library.playlists.first { $0.name == YouTubeImportLedger.historyPlaylistName })
        XCTAssertEqual(history.tracks.map(\.id), ["hist-9", "hist-2", "hist-1", "like-1"],
                       "Newest plays lead; earlier imported songs follow in their previous order")
        XCTAssertEqual(importer.summary, "Liked 1 song, updated 1 playlist, added 1 song to YouTube Music history.")
    }

    func testHistoryKeepsTheMostRecentTwoHundredUniqueSongsAndLikesStopAtTheirCap() async throws {
        let library = LibraryStore(directory: directory, now: { ImportFixtures.now })
        let client = StubAccountLibrary()
        client.historyRows = [
            YouTubeLibraryPage(items: (0..<150).map { ImportFixtures.track("h-\($0)") } + [ImportFixtures.track("h-0")], continuation: "history:1"),
            YouTubeLibraryPage(items: (150..<300).map { ImportFixtures.track("h-\($0)") }, continuation: "history:2"),
            YouTubeLibraryPage(items: (300..<450).map { ImportFixtures.track("h-\($0)") }, continuation: "history:3"),
            YouTubeLibraryPage(items: (450..<600).map { ImportFixtures.track("h-\($0)") }),
        ]
        client.likes = [
            YouTubeLibraryPage(items: (0..<3).map { ImportFixtures.track("l-\($0)") }, continuation: "likes:1"),
            YouTubeLibraryPage(items: (3..<6).map { ImportFixtures.track("l-\($0)") }, continuation: "likes:2"),
            YouTubeLibraryPage(items: (6..<9).map { ImportFixtures.track("l-\($0)") }),
        ]
        var bounds = YouTubeImportBounds()
        bounds.likes = 4
        let importer = makeImporter(client, library: library, bounds: bounds)
        await importer.run(YouTubeImportSelection(kinds: [.likes, .history]))

        let history = try XCTUnwrap(library.playlists.first { $0.name == YouTubeImportLedger.historyPlaylistName })
        XCTAssertEqual(history.tracks.count, 200)
        XCTAssertEqual(history.tracks.first?.id, "h-0")
        XCTAssertEqual(history.tracks.last?.id, "h-199")
        XCTAssertEqual(importer.progress[.history]?.fetched, 500, "History reading stops at 500 rows")
        XCTAssertEqual(client.requests.filter { $0.hasPrefix("history:") }.count, 4)
        XCTAssertEqual(library.favorites.count, 4, "The likes cap truncates the page that crosses it")
        XCTAssertEqual(client.requests.filter { $0.hasPrefix("likes:") }.count, 2, "No page is requested past the cap")
    }

    func testLedgerPersistsAcrossImporterInstancesAndSignOut() async throws {
        let library = LibraryStore(directory: directory, now: { ImportFixtures.now })
        let client = fullStub()
        let account = makeAccount()
        let first = makeImporter(client, library: library, account: account)
        await first.run(YouTubeImportSelection(kinds: [.playlists, .history]))
        let roadTrip = try XCTUnwrap(library.playlists.first { $0.name == "Road trip" })

        XCTAssertTrue(account.signOut())
        XCTAssertFalse(first.hasSession)
        XCTAssertEqual(library.playlists.count, 3, "Signing out keeps imported content")

        let later = ImportFixtures.now.addingTimeInterval(86_400)
        let second = makeImporter(client, library: library, account: makeAccount(), now: later)
        XCTAssertEqual(second.lastImportedAt, ImportFixtures.now, "The ledger is read back from disk")
        XCTAssertEqual(second.ledger.playlists["VLPLremote1"], roadTrip.id)
        client.playlistPages["VLPLremote1"] = [YouTubeLibraryPage(items: [ImportFixtures.track("road-1"), ImportFixtures.track("road-9")])]
        await second.run(YouTubeImportSelection(kinds: [.playlists]))
        XCTAssertEqual(library.playlists.count, 3)
        XCTAssertEqual(library.playlists.first { $0.id == roadTrip.id }?.tracks.map(\.id), ["road-1", "road-2", "road-9"])
        XCTAssertEqual(second.lastImportedAt, later)
        let saved = try YouTubeImportLedgerStore(url: directory.appendingPathComponent("youtube-import.json")).load()
        XCTAssertEqual(saved.lastImportedAt, later)
        XCTAssertEqual(saved.count(for: .history), 3, "Counts of kinds outside this run are kept")
    }

    func testDeletedLocalPlaylistIsRecreatedWhileOthersAreOnlySelected() async throws {
        let library = LibraryStore(directory: directory, now: { ImportFixtures.now })
        let client = fullStub()
        let importer = makeImporter(client, library: library)
        await importer.run(YouTubeImportSelection(kinds: [.playlists], playlistIDs: ["VLPLremote1"]))
        XCTAssertEqual(library.playlists.map(\.name), ["Road trip"], "Only the selected playlist is copied")
        XCTAssertEqual(importer.progress[.playlists]?.fetched, 1)
        library.deletePlaylist(id: try XCTUnwrap(library.playlists.first?.id))
        await importer.run(YouTubeImportSelection(kinds: [.playlists], playlistIDs: ["VLPLremote1"]))
        XCTAssertEqual(library.playlists.map(\.name), ["Road trip"], "A playlist deleted here comes back when it is selected again")
        XCTAssertEqual(importer.ledger.playlists["VLPLremote1"], library.playlists.first?.id)
    }

    func testAFailingKindDoesNotStopTheOthers() async throws {
        let library = LibraryStore(directory: directory, now: { ImportFixtures.now })
        let client = fullStub()
        client.failing = [.playlists]
        client.rateLimited = [.subscriptions]
        let importer = makeImporter(client, library: library)
        await importer.run(everything)
        XCTAssertEqual(importer.runStatus, .finished)
        XCTAssertEqual(library.favorites.count, 3)
        XCTAssertEqual(importer.progress[.likes]?.status, .done)
        guard case .failed(_)? = importer.progress[.playlists]?.status else { return XCTFail("Playlists must report their failure") }
        XCTAssertEqual(importer.progress[.subscriptions]?.status, .rateLimited)
        XCTAssertEqual(importer.progress[.history]?.status, .done)
        XCTAssertEqual(library.playlists.map(\.name), [YouTubeImportLedger.historyPlaylistName])
        XCTAssertEqual(importer.lastImportedAt, ImportFixtures.now, "Completed kinds still date the import")

        client.failing = []
        client.playlistPages["VLPLremote2"] = nil
        await importer.run(YouTubeImportSelection(kinds: [.playlists]))
        XCTAssertEqual(library.playlists.filter { $0.name == "Road trip" }.count, 1, "Readable playlists are copied around an unreadable one")
        XCTAssertEqual(importer.progress[.playlists]?.status, .failed("1 playlist couldn't be read."))
    }

    func testUnauthorizedStopsTheRemainingKindsAndAsksForSignIn() async throws {
        let library = LibraryStore(directory: directory, now: { ImportFixtures.now })
        let client = fullStub()
        client.unauthorized = [.playlists]
        let importer = makeImporter(client, library: library)
        await importer.run(everything)
        XCTAssertEqual(importer.progress[.likes]?.status, .done)
        XCTAssertEqual(importer.progress[.playlists]?.status, .unauthorized)
        XCTAssertEqual(importer.progress[.subscriptions]?.status, .unauthorized)
        XCTAssertEqual(importer.progress[.history]?.status, .unauthorized)
        XCTAssertTrue(importer.needsSignIn)
        XCTAssertFalse(client.requests.contains { $0.hasPrefix("artists:") || $0.hasPrefix("history:") },
                       "Refused cookies are not retried against the other listings")
        XCTAssertTrue(library.followedArtists.isEmpty)
    }

    func testCancellationStopsBetweenPagesAndKeepsWhatWasApplied() async throws {
        let library = LibraryStore(directory: directory, now: { ImportFixtures.now })
        let client = fullStub()
        let gate = AsyncStream<Void>.makeStream()
        client.likesGate = {
            for await _ in gate.stream { break }
        }
        let importer = makeImporter(client, library: library)
        importer.start(everything)
        let deadline = Date().addingTimeInterval(5)
        while importer.progress[.likes]?.fetched != 2, Date() < deadline { await Task.yield() }
        XCTAssertEqual(importer.progress[.likes]?.fetched, 2, "The first page was applied before the gate")
        XCTAssertTrue(importer.isRunning)
        importer.cancel()
        gate.continuation.yield()
        gate.continuation.finish()
        let finish = Date().addingTimeInterval(5)
        while importer.isRunning, Date() < finish { await Task.yield() }

        XCTAssertEqual(importer.runStatus, .cancelled)
        XCTAssertEqual(importer.progress[.likes]?.status, .cancelled)
        XCTAssertEqual(importer.progress[.playlists]?.status, .cancelled)
        XCTAssertEqual(library.favorites.map(\.id), ["like-1", "like-2"], "Applied pages stay; nothing is rolled back")
        XCTAssertTrue(library.playlists.isEmpty)
        XCTAssertFalse(client.requests.contains { $0.hasPrefix("playlists:") })
        XCTAssertNil(importer.lastImportedAt, "A cancelled run completes no kind and does not date the import")
    }

    func testStartRequiresASessionAndIgnoresOverlappingRuns() async throws {
        let library = LibraryStore(directory: directory, now: { ImportFixtures.now })
        let client = fullStub()
        let importer = makeImporter(client, library: library, account: makeAccount(signedIn: false))
        XCTAssertFalse(importer.hasSession)
        importer.start(everything)
        XCTAssertEqual(importer.runStatus, .idle)
        XCTAssertTrue(client.requests.isEmpty)
    }

    func testUniqueNamesAndSummaryWording() {
        XCTAssertEqual(YouTubeLibraryImporter.uniqueName("Road trip", among: ["Chill"]), "Road trip")
        XCTAssertEqual(YouTubeLibraryImporter.uniqueName("Road trip", among: ["road TRIP"]), "Road trip (YouTube)")
        XCTAssertEqual(YouTubeLibraryImporter.uniqueName("   ", among: []), "YouTube playlist")
        var progress: [YouTubeLibraryKind: YouTubeImportKindProgress] = [:]
        progress[.likes] = YouTubeImportKindProgress(fetched: 143, applied: 143, status: .done)
        progress[.playlists] = YouTubeImportKindProgress(fetched: 8, applied: 6, updated: 2, status: .done)
        progress[.subscriptions] = YouTubeImportKindProgress(fetched: 12, applied: 12, status: .done)
        XCTAssertEqual(YouTubeLibraryImporter.summary(progress), "Liked 143 songs, added 6 playlists, updated 2 playlists, followed 12 artists.")
        XCTAssertEqual(YouTubeLibraryImporter.summary([.playlists: YouTubeImportKindProgress(fetched: 1, applied: 1, status: .done)]), "Added 1 playlist.")
        XCTAssertEqual(YouTubeLibraryImporter.summary([.likes: YouTubeImportKindProgress(fetched: 3, applied: 0, status: .done)]), "Nothing new to import.")
        XCTAssertEqual(YouTubeImportView.progressText(.likes, YouTubeImportKindProgress(fetched: 10, applied: 4, status: .running)), "10 read, 4 liked")
        XCTAssertEqual(YouTubeImportView.progressText(.playlists, YouTubeImportKindProgress(status: .unauthorized)), "Sign in again")
        XCTAssertEqual(YouTubeImportView.progressText(.history, YouTubeImportKindProgress(status: .pending)), "Waiting")
        XCTAssertEqual(YouTubeImportView.lastImportText(nil), "Not imported")
    }

    func testLedgerStoreRoundTripsAndRefusesNewerVersions() throws {
        let store = YouTubeImportLedgerStore(url: directory.appendingPathComponent("youtube-import.json"))
        XCTAssertEqual(try store.load(), YouTubeImportLedger(), "A missing file is an empty ledger")
        var ledger = YouTubeImportLedger()
        ledger.lastImportedAt = ImportFixtures.now
        ledger.playlists["VLPLx"] = UUID()
        ledger.historyPlaylistID = UUID()
        ledger.setCount(7, for: .likes)
        try store.save(ledger)
        XCTAssertEqual(try store.load(), ledger)
        try Data(#"{"version":99,"playlists":{},"lastCounts":{}}"#.utf8).write(to: store.url)
        XCTAssertThrowsError(try store.load())
        let broken = makeImporter(StubAccountLibrary(), library: LibraryStore(directory: directory, now: { ImportFixtures.now }))
        XCTAssertNotNil(broken.errorMessage, "An unreadable ledger is reported, not silently replaced")
        XCTAssertNil(broken.lastImportedAt)
    }

    func testLibraryBulkHelpersSkipDuplicatesAndKeepDislikes() throws {
        let library = LibraryStore(directory: directory, now: { ImportFixtures.now })
        library.toggleDislike(ImportFixtures.track("no"))
        library.toggleFavorite(ImportFixtures.track("old"))
        XCTAssertEqual(library.addFavorites([ImportFixtures.track("a"), ImportFixtures.track("a"), ImportFixtures.track("no"), ImportFixtures.track("old"), ImportFixtures.track("b")]), 2)
        XCTAssertEqual(library.favorites.map(\.id), ["a", "b", "old"])
        XCTAssertTrue(library.isDisliked(ImportFixtures.track("no")))
        XCTAssertEqual(library.addFavorites([ImportFixtures.track("a")]), 0)
        let id = library.createPlaylist(name: "Mix", tracks: [ImportFixtures.track("1"), ImportFixtures.track("2")])
        XCTAssertEqual(library.merge([ImportFixtures.track("2"), ImportFixtures.track("3")], into: id), 1)
        XCTAssertEqual(library.playlists[0].tracks.map(\.id), ["1", "2", "3"])
        XCTAssertEqual(library.merge([ImportFixtures.track("9"), ImportFixtures.track("3")], into: id, leading: true), 1)
        XCTAssertEqual(library.playlists[0].tracks.map(\.id), ["9", "3", "1", "2"])
        XCTAssertEqual(library.merge([ImportFixtures.track("9"), ImportFixtures.track("3")], into: id, leading: true), 0, "Same order is a no-op")
        XCTAssertNil(library.errorMessage)
    }
}

import Foundation
import XCTest
@testable import GanaBajana

final class GaanaTests: XCTestCase {
    /// Recorded live on 26 September 2026 for `song_detail&track_id=944286` (`urls.high`); the master URL and its
    /// Akamai token are public catalog data that expired four hours after the call.
    private static let recordedHighMessage = "5DnCfo1HAJqk3iNJLe3SIEw0xyA2+2nJ/kdCen5oMgGdLSbFi6oCrQ+lQ1gWbUUmX8Mu9jRPBfgZQ8mQWx0DCEHcHWvC4yJvm+M0MGVgDJr0p5e4YZ5DuPmWzGsZ2c210PHq08BPaZSmubzXyZhKgdVt8Fnp8AgcbTsDR+DhpsuBp302ZZDyWeUhG21tukvjy+ZKvOl5xewIcZnkylS2YUkVO53OtrQLRznnxcyH/5L8Gc9bH0taAAMLBlBXWEDL1pvNFEAYNzWnQRP+XFmw2OyCjYFIcQNxIfv/stdzDzUU5hOUoAqUdjIbWdcDaF/4="
    private static let recordedHighURL = "https://vodhlsgaana-ebw.akamaized.net/hls/17/92317/944286/128.mp4.master.m3u8?hdnts=st=1790416383~exp=1790430783~acl=/hls/17/92317/944286/*~hmac=736e9b7de9e5e55b52ad24ef47d0216e2a3ed404c99886079a0c4676a0154bef"
    private static let tumHiHo = Track(id: "gaana:944286", title: "Tum Hi Ho", credits: [ArtistCredit(name: "Mithoon"), ArtistCredit(name: "Arijit Singh")],
                                       duration: 261, playCount: 7)
    /// Before the recorded `expiryTime` (1790431083) so the fixture's URLs are still valid.
    private static let recordingTime = Date(timeIntervalSince1970: 1_790_420_000)

    // MARK: Decryption and tiers

    func testAESRoundTripDecryptsAKnownURL() throws {
        let url = URL(string: "https://vodhlsgaana-ebw.akamaized.net/hls/17/1/2/128.mp4.master.m3u8?hdnts=st=1~exp=2~hmac=abc")!
        let message = try GaanaMediaURL.encrypt(url, iv: "asd!@#!@#@!12312", filler: "vT")
        XCTAssertTrue(message.hasPrefix("3vTasd!@#!@#@!12312"), "One digit names where the 16-byte IV starts")
        XCTAssertNotEqual(message, url.absoluteString)
        XCTAssertEqual(try GaanaMediaURL.decrypt(message), url)
        let longer = try GaanaMediaURL.encrypt(url, iv: "0123456789abcdef", filler: "abcdefg")
        XCTAssertTrue(longer.hasPrefix("8abcdefg0123456789abcdef"))
        XCTAssertEqual(try GaanaMediaURL.decrypt(longer), url)
    }

    func testRecordedMessageDecryptsToTheObservedHLSMaster() throws {
        XCTAssertEqual(try GaanaMediaURL.decrypt(Self.recordedHighMessage).absoluteString, Self.recordedHighURL)
        XCTAssertEqual(String(data: GaanaMediaURL.key, encoding: .utf8), "gy1t#b@jl(b$wtme")
    }

    func testDecryptionRejectsGarbageAndForeignHosts() throws {
        XCTAssertThrowsError(try GaanaMediaURL.decrypt("not a message")) { error in
            XCTAssertEqual(error as? GaanaMediaURL.DecryptionError, .invalidFormat)
        }
        XCTAssertThrowsError(try GaanaMediaURL.decrypt("3xy0123456789abcdef!!!!"))
        XCTAssertThrowsError(try GaanaMediaURL.decrypt("3xy0123456789abcdef" + Data([1, 2, 3]).base64EncodedString()))
        let foreign = try GaanaMediaURL.encrypt(URL(string: "https://example.com/128.mp4.master.m3u8")!)
        XCTAssertThrowsError(try GaanaMediaURL.decrypt(foreign)) { error in
            XCTAssertEqual(error as? GaanaMediaURL.DecryptionError, .invalidURL)
        }
        XCTAssertThrowsError(try GaanaMediaURL.encrypt(URL(string: "https://a.gaana.com/x")!, iv: "short"))
        XCTAssertTrue(GaanaMediaURL.isMediaHost(URL(string: "https://streams.gaana.com/preview/clip.mp4")!))
        XCTAssertFalse(GaanaMediaURL.isMediaHost(URL(string: "http://vodhlsgaana-ebw.akamaized.net/x.m3u8")!))
    }

    func testQualityCeilingSelectsTiers() {
        let both: Set<GaanaMediaURL.Tier> = [.high, .medium]
        XCTAssertEqual(GaanaMediaURL.candidates(available: both, maximumBitRate: AudioQualityPreference.best.maximumBitRate), [.high, .medium])
        XCTAssertEqual(GaanaMediaURL.candidates(available: both, maximumBitRate: AudioQualityPreference.balanced.maximumBitRate), [.high, .medium])
        XCTAssertEqual(GaanaMediaURL.candidates(available: both, maximumBitRate: AudioQualityPreference.dataSaver.maximumBitRate), [.medium])
        XCTAssertEqual(GaanaMediaURL.candidates(available: [.high], maximumBitRate: 64_000), [.high], "A ceiling under every tier keeps the lowest")
        XCTAssertEqual(GaanaMediaURL.candidates(available: [], maximumBitRate: nil), [])
        XCTAssertEqual(GaanaMediaURL.Tier.high.quality, SourceAudioQuality(codec: .aac, bitRate: 128_000, sampleRate: 44_100, channels: 2))
        XCTAssertEqual(GaanaMediaURL.Tier.medium.bitRate, 64_000)
    }

    // MARK: Text

    func testTextHelpersResizeArtworkAndParseCounts() {
        XCTAssertEqual(GaanaText.artwork("https://a10.gaanacdn.com/gn_img/albums/d41WjnWPLq/41Wjz1LOWP/size_m_1712905431.jpg")?.absoluteString,
                       "https://a10.gaanacdn.com/gn_img/albums/d41WjnWPLq/41Wjz1LOWP/size_l_1712905431.jpg")
        XCTAssertEqual(GaanaText.artwork("https://a10.gaanacdn.com/gn_img/albums/koMWQBbqLE/oMWQVq1bqL/size_s.jpg")?.lastPathComponent, "size_l.jpg")
        XCTAssertEqual(GaanaText.artwork("http://a10.gaanacdn.com/images/artists/27/27/crop_80x80_27.jpg")?.absoluteString,
                       "https://a10.gaanacdn.com/images/artists/27/27/crop_80x80_27.jpg", "Fixed crops keep their name and gain TLS")
        XCTAssertNil(GaanaText.artwork("https://example.com/size_m.jpg"))
        XCTAssertEqual(GaanaText.identifier("944286"), "944286")
        XCTAssertEqual(GaanaText.identifier(CatalogJSON.number(944_286)), "944286")
        XCTAssertNil(GaanaText.identifier("gaana:1"))
        XCTAssertNil(GaanaText.identifier(String(repeating: "a", count: 129)))
        XCTAssertEqual(GaanaText.playCount(.string("180685771~180685771")), 180_685_771)
        XCTAssertNil(GaanaText.playCount(.string("0~152701309")))
        XCTAssertNil(GaanaText.playCount(.string("180M+")))
        XCTAssertEqual(GaanaText.lufs(.string("-8.0 LUFS")), -8)
        XCTAssertNil(GaanaText.lufs(.string("+1.3 dBTP")))
        XCTAssertEqual(GaanaText.expiry(.number(1_790_431_083)), Date(timeIntervalSince1970: 1_790_431_083))
        XCTAssertEqual(GaanaText.language("Hindi"), .hindi)
        XCTAssertNil(GaanaText.language("Punjabi"))
        XCTAssertTrue(GaanaText.flag(.string("1")))
        XCTAssertFalse(GaanaText.flag(.number(0)))
    }

    // MARK: Parsers

    func testSongSearchRowsMapOntoTracks() throws {
        let page = GaanaParser.search(try Self.fixture("gaana-search-tracks"), filter: .songs)
        XCTAssertEqual(page.tracks.count, 3)
        let track = try XCTUnwrap(page.tracks.first)
        XCTAssertEqual(track.id, "gaana:944286")
        XCTAssertEqual(track.source, .gaana)
        XCTAssertEqual(track.providerID, "944286")
        XCTAssertEqual(track.title, "Tum Hi Ho")
        XCTAssertEqual(track.credits, [ArtistCredit(name: "Mithoon"), ArtistCredit(name: "Arijit Singh")], "Search rows name performers without ids")
        XCTAssertEqual(track.artworkURL?.absoluteString, "https://a10.gaanacdn.com/gn_img/albums/d41WjnWPLq/41Wjz1LOWP/size_l_1712905431.jpg")
        XCTAssertEqual(track.language, .hindi)
        XCTAssertNil(track.duration, "gsearch rows carry no duration; the details call fills it")
        XCTAssertEqual(track.isAudioRecording, true)
        XCTAssertEqual(track.shareURL?.absoluteString, "https://gaana.com/search/all?keyword=Tum%20Hi%20Ho")
        XCTAssertTrue(page.collections.isEmpty)
        XCTAssertTrue(GaanaParser.search(try Self.fixture("gaana-search-tracks"), filter: .albums).collections.isEmpty, "Track rows never become albums")
        let mixed = GaanaParser.search(try Self.fixture("gaana-search-all"), filter: .songs)
        XCTAssertEqual(mixed.tracks.map(\.id), ["gaana:944286", "gaana:40746", "gaana:20825652"], "Mixed groups keep only track rows, deduplicated")
    }

    func testAlbumArtistAndPlaylistSearchRowsMapOntoCollections() throws {
        let albums = GaanaParser.search(try Self.fixture("gaana-search-albums"), filter: .albums).collections
        XCTAssertEqual(albums.count, 3)
        XCTAssertEqual(albums.first?.id, "gaana:album:6066219")
        XCTAssertEqual(albums.first?.title, "Aashiqui 2 (Cine Audio)")
        XCTAssertEqual(albums.first?.kind, .album)
        XCTAssertEqual(albums.first?.subtitle, "Palak Muchhal, Shraddha Kapoor, Arijit Singh")
        XCTAssertEqual(albums.map(\.id).dropFirst().first, "gaana:album:92317")
        XCTAssertEqual(albums.first?.source, .gaana)

        let artists = GaanaParser.search(try Self.fixture("gaana-search-artists"), filter: .artists).collections
        XCTAssertEqual(artists.count, 3)
        XCTAssertEqual(artists.first?.id, "gaana:artist:52767")
        XCTAssertEqual(artists.first?.title, "Arijit Singh")
        XCTAssertEqual(artists.first?.kind, .artist)
        XCTAssertEqual(artists.first?.subtitle, "Artist")
        XCTAssertTrue(artists.first?.artworkURL?.absoluteString.contains("size_l") == true)

        let playlists = GaanaParser.search(try Self.fixture("gaana-search-playlists"), filter: .playlists).collections
        XCTAssertEqual(playlists.first?.id, "gaana:playlist:1075124")
        XCTAssertEqual(playlists.first?.title, "Best of Arijit Singh")
        XCTAssertEqual(playlists.first?.kind, .playlist)
        XCTAssertEqual(playlists.first?.language, .hindi)
    }

    func testSongDetailsKeepEncryptedURLsCreditsAndLoudness() throws {
        let songs = GaanaParser.songDetails(try Self.fixture("gaana-song-detail"))
        let song = try XCTUnwrap(songs.first)
        XCTAssertEqual(song.track.id, "gaana:944286")
        XCTAssertEqual(song.seokey, "tumhiho")
        XCTAssertEqual(song.track.credits, [ArtistCredit(name: "Mithoon", id: "gaana:artist:27"), ArtistCredit(name: "Arijit Singh", id: "gaana:artist:52767")])
        XCTAssertEqual(song.track.albumTitle, "Aashiqui 2")
        XCTAssertEqual(song.track.albumID, "gaana:album:92317")
        XCTAssertEqual(song.track.duration, 261)
        XCTAssertEqual(song.track.playCount, 180_685_771)
        XCTAssertFalse(song.track.isExplicit)
        XCTAssertEqual(song.track.artworkURL?.lastPathComponent, "size_l_1712905431.jpg")
        XCTAssertEqual(Set(song.urls.keys), [.high, .medium], "The adaptive `auto` ladder is not a selectable tier")
        XCTAssertEqual(song.urls[.high]?.message, Self.recordedHighMessage)
        XCTAssertEqual(song.urls[.high]?.expiresAt, Date(timeIntervalSince1970: 1_790_431_083))
        XCTAssertFalse(song.isRestricted)
        XCTAssertTrue(song.isPremium)
        XCTAssertEqual(song.integratedLoudness, -8)
        XCTAssertTrue(GaanaParser.songDetails(try Self.fixture("gaana-song-detail-missing")).isEmpty)
    }

    func testAlbumPageCarriesHeaderCreditsAndSongs() throws {
        let page = try XCTUnwrap(GaanaParser.albumPage(try Self.fixture("gaana-album")))
        XCTAssertEqual(page.title, "Aashiqui 2")
        XCTAssertEqual(page.credits.map(\.name), ["Mithoon", "Jeet Gannguli", "Ankit Tiwari"])
        XCTAssertEqual(page.credits.map(\.id), ["gaana:artist:27", "gaana:artist:111896", "gaana:artist:47564"])
        XCTAssertEqual(page.tracks.map(\.id), ["gaana:944286", "gaana:944306", "gaana:944447"])
        XCTAssertTrue(page.tracks.allSatisfy { $0.albumID == "gaana:album:92317" && $0.duration != nil })
        XCTAssertNil(GaanaParser.albumPage(try Self.fixture("gaana-album-missing")))
    }

    func testPlaylistPageListsTheProviderSelection() throws {
        let page = try XCTUnwrap(GaanaParser.playlistPage(try Self.fixture("gaana-playlist")))
        XCTAssertEqual(page.title, "Best of Arijit Singh")
        XCTAssertEqual(page.tracks.count, 3)
        XCTAssertEqual(page.tracks.first?.id, "gaana:80524747")
        XCTAssertEqual(page.tracks.first?.title, "Jai Jai Ram (From \"Ramayana\")")
        XCTAssertTrue(page.credits.isEmpty)
    }

    func testArtistPageCollectsTopSongsAlbumsAndSimilarArtists() throws {
        let page = try XCTUnwrap(GaanaParser.artistPage(try Self.fixture("gaana-artist"), albums: try Self.fixture("gaana-artist-albums"),
                                                        similar: try Self.fixture("gaana-similar-artists"), id: "gaana:artist:52767"))
        XCTAssertEqual(page.id, "gaana:artist:52767")
        XCTAssertEqual(page.name, "Arijit Singh")
        XCTAssertEqual(page.artworkURL?.absoluteString, "https://a10.gaanacdn.com/gn_img/artists/Dk9KNk23Bx/k9KNqJJbBx/size_l_1739172212.jpg")
        XCTAssertEqual(page.topSongs.count, 2)
        let top = try XCTUnwrap(page.topSongs.first)
        XCTAssertEqual(top.id, "gaana:26974811")
        XCTAssertEqual(top.title, "Tujhe Kitna Chahne Lage")
        XCTAssertEqual(top.credits.first, ArtistCredit(name: "Arijit Singh", id: "gaana:artist:52767"))
        XCTAssertEqual(top.albumTitle, "Kabir Singh")
        XCTAssertEqual(top.albumID, "gaana:album:2602904")
        XCTAssertEqual(page.releases.count, 3)
        XCTAssertEqual(page.releases.first?.id, "gaana:album:13879256")
        XCTAssertEqual(page.releases.first?.title, "Gehra Hua (From \"Dhurandhar\")")
        XCTAssertEqual(page.releases.first?.subtitle, "Shashwat Sachdev")
        XCTAssertEqual(page.relatedArtists.map(\.id), ["gaana:artist:11468", "gaana:artist:4"])
        XCTAssertEqual(page.relatedArtists.first?.title, "Pritam")
        XCTAssertNil(page.monthlyAudience)
        XCTAssertNil(GaanaParser.artistPage(try Self.fixture("gaana-artist-missing"), albums: .null, similar: .null, id: "gaana:artist:1"))
    }

    func testArtistTrackEntitiesMapForRadio() throws {
        let tracks = GaanaParser.entityTracks(try Self.fixture("gaana-artist-tracks")["entities"].array)
        XCTAssertEqual(tracks.count, 3)
        XCTAssertEqual(tracks.first?.id, "gaana:80884606")
        XCTAssertEqual(tracks.first?.title, "Dil Hi Toh Hai")
        XCTAssertEqual(tracks.first?.duration, 281)
        XCTAssertEqual(tracks.first?.credits.map(\.name).prefix(2), ["Pritam", "Arijit Singh"])
        XCTAssertEqual(tracks.first?.albumTitle, "With Love - Arijit Singh")
    }

    // MARK: Service through a mocked session

    func testSearchSendsTheWebPlayerHeadersAndCachesForAMinute() async throws {
        let clock = CatalogTestClock()
        let mock = Self.mock()
        defer { mock.close() }
        let service = GaanaCatalogService(session: mock.session, now: { clock.now })
        let first = try await service.search(query: "tum hi ho", filter: .songs, continuation: nil)
        XCTAssertEqual(first.tracks.map(\.id), ["gaana:944286", "gaana:1739997", "gaana:944317"])
        let request = try XCTUnwrap(mock.state.requests.first)
        let items = Self.items(request)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.host, "gsearch.gaana.com")
        XCTAssertTrue(request.url?.absoluteString.hasPrefix("https://gsearch.gaana.com/vichitih/go/v2/?") == true, "The trailing slash is part of the endpoint")
        XCTAssertEqual(items["query"], "tum hi ho")
        XCTAssertEqual(items["include"], "track")
        XCTAssertEqual(items["geoLocation"], "GLOBAL")
        XCTAssertEqual(items["startIndex"], "0")
        XCTAssertEqual(request.value(forHTTPHeaderField: "deviceType"), "GaanaWebsiteApp")
        XCTAssertEqual(request.value(forHTTPHeaderField: "appVersion"), "V6")
        XCTAssertEqual(request.value(forHTTPHeaderField: "gaanaAppVersion"), "gaanaAndroid-8.60.2")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), CatalogTransport.browserUserAgent)
        XCTAssertFalse(request.httpShouldHandleCookies)

        _ = try await service.search(query: "tum hi ho", filter: .songs, continuation: nil)
        XCTAssertEqual(mock.state.requests.count, 1, "A repeated search inside the lifetime is served from memory")
        clock.advance(61)
        _ = try await service.search(query: "tum hi ho", filter: .songs, continuation: nil)
        XCTAssertEqual(mock.state.requests.count, 2)
        let continued = try await service.search(query: "tum hi ho", filter: .songs, continuation: "anything")
        XCTAssertTrue(continued.tracks.isEmpty)
        XCTAssertEqual(mock.state.requests.count, 2, "Continuations belong to the primary catalog")
        let albums = try await service.search(query: "aashiqui 2", filter: .albums, continuation: nil)
        XCTAssertEqual(albums.collections.map(\.id).dropFirst().first, "gaana:album:92317")
        XCTAssertEqual(Self.items(mock.state.requests.last)["include"], "album")
    }

    func testBrowseArtistAndRadioRouteByPrefixedIdentity() async throws {
        let mock = Self.mock()
        defer { mock.close() }
        let service = GaanaCatalogService(session: mock.session)
        let album = try await service.browse(id: "gaana:album:92317")
        XCTAssertEqual(album.title, "Aashiqui 2")
        XCTAssertEqual(album.tracks.count, 3)
        XCTAssertEqual(mock.state.requests.last?.url?.host, "apiv2.gaana.com")
        XCTAssertEqual(mock.state.requests.last?.url?.path, "/album/detail")
        XCTAssertEqual(Self.items(mock.state.requests.last)["album_id"], "92317")
        XCTAssertEqual(Self.items(mock.state.requests.last)["st"], "hls")
        XCTAssertEqual(Self.items(mock.state.requests.last)["pkc"], "true")

        let playlist = try await service.browse(id: "gaana:playlist:1075124")
        XCTAssertEqual(playlist.title, "Best of Arijit Singh")
        XCTAssertEqual(playlist.tracks.count, 3)
        XCTAssertEqual(mock.state.requests.last?.url?.path, "/playlist/detail")
        XCTAssertEqual(Self.items(mock.state.requests.last)["playlist_id"], "1075124")

        let before = mock.state.requests.count
        let artist = try await service.artist(id: "gaana:artist:52767")
        XCTAssertEqual(artist.name, "Arijit Singh")
        XCTAssertEqual(artist.topSongs.count, 2)
        XCTAssertEqual(artist.releases.count, 3)
        XCTAssertEqual(artist.relatedArtists.count, 2)
        let artistPaths = mock.state.requests.dropFirst(before).compactMap { $0.url?.path }
        XCTAssertEqual(artistPaths, ["/artist/entity/detail/v1", "/home/artist/album/52767", "/player/similar-artists/52767"])
        let asPage = try await service.browse(id: "gaana:artist:52767")
        XCTAssertEqual(asPage.tracks.count, 2)
        XCTAssertEqual(asPage.collections.count, 5)
        XCTAssertEqual(mock.state.requests.count, before + 3, "Artist pages are served from the details cache")

        let song = try await service.browse(id: "gaana:944286")
        XCTAssertEqual(song.tracks.first?.duration, 261)
        XCTAssertEqual(Self.items(mock.state.requests.last)["track_id"], "944286")
        XCTAssertEqual(Self.items(mock.state.requests.last)["subtype"], "song_detail")

        let awaited1 = try await service.browse(id: "MPREb_notGaana").tracks.isEmpty
        XCTAssertTrue(awaited1)
        let awaited2 = try await service.browse(id: "saavn:album:1").tracks.isEmpty
        XCTAssertTrue(awaited2)
        do {
            _ = try await service.artist(id: "gaana:album:92317")
            XCTFail("An album id is not an artist")
        } catch { XCTAssertTrue(error is MusicServiceError) }
        do {
            _ = try await service.browse(id: "gaana:album:999999999999")
            XCTFail("A removed album answers a failure envelope")
        } catch let error as MusicServiceError {
            XCTAssertEqual(error.errorDescription, "This album is no longer available on Gaana.")
        }
        let missing = try await service.songDetails(providerID: "999999999999")
        XCTAssertNil(missing)
        let awaited3 = try await service.discovery(languages: [.hindi]).isEmpty
        XCTAssertTrue(awaited3)

        let radio = try await service.radio(seed: Self.tumHiHo)
        XCTAssertEqual(radio.map(\.id), ["gaana:80884606", "gaana:80884607", "gaana:26974811"])
        XCTAssertEqual(mock.state.requests.last?.url?.path, "/home/artist/tracks/27", "Radio is the first credited artist's popular songs")
        let foreign = try await service.radio(seed: Track(id: "fsiPzT50ZiM", title: "YouTube", credits: []))
        XCTAssertTrue(foreign.isEmpty)
        let related = try await service.recommendations(seed: Self.tumHiHo, language: .english)
        XCTAssertTrue(related.isEmpty, "Hindi neighbours are filtered out for an English request")
    }

    func testRateLimitingAndEmptyBodiesAreRefusedWithoutARetry() async throws {
        let clock = CatalogTestClock()
        let limited = CatalogMockSession { _ in
            CatalogStub(status: 429, headers: ["Retry-After": "120", "Content-Type": "application/json"], data: Data("{}".utf8))
        }
        defer { limited.close() }
        let service = GaanaCatalogService(session: limited.session, now: { clock.now })
        for _ in 0..<2 {
            do {
                _ = try await service.search(query: "tum", filter: .songs, continuation: nil)
                XCTFail("A 429 must surface as rate limiting")
            } catch let error as MusicServiceError {
                guard case .rateLimited = error else { return XCTFail("Unexpected error \(error)") }
            }
        }
        XCTAssertEqual(limited.state.requests.count, 1, "The Retry-After window blocks further requests")

        let empty = CatalogMockSession { _ in CatalogStub(headers: ["Content-Type": "application/json"], data: Data()) }
        defer { empty.close() }
        do {
            _ = try await GaanaCatalogService(session: empty.session).search(query: "tum", filter: .songs, continuation: nil)
            XCTFail("The search host answers an empty body when its headers are missing; that is not a page")
        } catch let error as MusicServiceError {
            guard case .invalidResponse = error else { return XCTFail("Unexpected error \(error)") }
        }
    }

    // MARK: Stream resolver

    func testResolverPicksTheTierUnderEachPreference() async throws {
        let cases: [(AudioQualityPreference, String, Int)] = [(.best, "128.mp4.master.m3u8", 128_000), (.balanced, "128.mp4.master.m3u8", 128_000),
                                                             (.dataSaver, "64.mp4.master.m3u8", 64_000)]
        for (preference, expected, bitRate) in cases {
            let mock = Self.mock()
            defer { mock.close() }
            let probed = CatalogTestRecorder<URL>()
            let resolver = GaanaStreamResolver(catalog: GaanaCatalogService(session: mock.session), quality: preference,
                                               probe: { probed.record($0) }, now: { Self.recordingTime })
            let stream = try await resolver.resolve(track: Self.tumHiHo, forceRefresh: false)
            XCTAssertEqual(stream.url.lastPathComponent, expected, preference.rawValue)
            XCTAssertEqual(stream.url.host, "vodhlsgaana-ebw.akamaized.net")
            XCTAssertEqual(stream.quality?.bitRate, bitRate)
            XCTAssertEqual(stream.quality?.codec, .aac)
            XCTAssertEqual(stream.duration, 261)
            XCTAssertEqual(stream.expiresAt, Date(timeIntervalSince1970: 1_790_431_083), "The payload's own expiry is earlier than four hours")
            XCTAssertEqual(stream.loudnessDb, 6, "-8 LUFS integrated is 6 dB above the -14 LUFS reference")
            XCTAssertEqual(stream.viewCount, 180_685_771, "The fresh provider count wins over the row's stale value")
            XCTAssertEqual(probed.values.count, 1)
            XCTAssertEqual(Self.items(mock.state.requests.last)["track_id"], "944286")
            let again = try await resolver.resolve(track: Self.tumHiHo, forceRefresh: false)
            XCTAssertEqual(again.url, stream.url)
            XCTAssertEqual(mock.state.requests.count, 1, "A cached stream needs no second details request")
        }
    }

    func testResolverFallsToTheLowerTierRefusesBareIdsAndDropsExpiredURLs() async throws {
        let mock = Self.mock()
        defer { mock.close() }
        let resolver = GaanaStreamResolver(catalog: GaanaCatalogService(session: mock.session), probe: { url in
            if url.lastPathComponent.hasPrefix("128.") { throw PlaybackStreamError.httpStatus(403) }
        }, now: { Self.recordingTime })
        let stream = try await resolver.resolve(track: Self.tumHiHo, forceRefresh: false)
        XCTAssertEqual(stream.quality?.bitRate, 64_000)
        await resolver.setAudioQualityPreference(.dataSaver)
        let capped = try await resolver.resolve(track: Self.tumHiHo, forceRefresh: false)
        XCTAssertEqual(capped.quality?.bitRate, 64_000)
        XCTAssertEqual(mock.state.requests.count, 1, "Details stay cached across a ceiling change")
        do {
            _ = try await resolver.resolve(track: Track(id: "fsiPzT50ZiM", title: "YouTube", credits: []), forceRefresh: false)
            XCTFail("Bare ids never reach the Gaana resolver")
        } catch let error as PlaybackStreamError {
            guard case .invalidID = error else { return XCTFail("Unexpected error \(error)") }
        }
        do {
            _ = try await resolver.resolve(track: Track(id: "saavn:aRZbUYD7", title: "JioSaavn", credits: []), forceRefresh: false)
            XCTFail("JioSaavn ids never reach the Gaana resolver")
        } catch let error as PlaybackStreamError {
            guard case .invalidID = error else { return XCTFail("Unexpected error \(error)") }
        }

        let late = GaanaStreamResolver(catalog: GaanaCatalogService(session: mock.session), probe: { _ in },
                                       now: { Date(timeIntervalSince1970: 1_790_431_084) })
        do {
            _ = try await late.resolve(track: Self.tumHiHo, forceRefresh: true)
            XCTFail("URLs past their expiryTime are never handed to the player")
        } catch let error as PlaybackStreamError {
            guard case .noAudio = error else { return XCTFail("Unexpected error \(error)") }
        }
    }

    func testResolverFallsBackToJioSaavnThenYouTubeInOrder() async throws {
        let calls = CatalogTestRecorder<String>()
        let saavnStream = ResolvedStream(url: URL(string: "https://aac.saavncdn.com/430/x_320.mp4")!, duration: 262,
                                         quality: SourceAudioQuality(codec: .aac, bitRate: 320_000, sampleRate: 44_100, channels: 2))
        let youTubeStream = ResolvedStream(url: URL(string: "https://rr1---sn.googlevideo.com/videoplayback?id=x")!, duration: 261)
        let miss = StubFallback(source: .jioSaavn, calls: calls) { _ in nil }
        let saavn = StubFallback(source: .jioSaavn, calls: calls) { _ in saavnStream }
        let youTube = StubFallback(source: .youTubeMusic, calls: calls) { _ in youTubeStream }
        let failing = StubFallback(source: .jioSaavn, calls: calls) { _ in throw MusicServiceError.rateLimited }

        // A removed song: the details call answers the failure envelope, so only the fallbacks can play it.
        let missing = Self.mock(details: "gaana-song-detail-missing")
        defer { missing.close() }
        let resolver = GaanaStreamResolver(catalog: GaanaCatalogService(session: missing.session), fallbacks: [miss, youTube],
                                           probe: { _ in XCTFail("Nothing to probe without a Gaana stream") }, now: { Self.recordingTime })
        let stream = try await resolver.resolve(track: Self.tumHiHo, forceRefresh: false)
        XCTAssertEqual(stream.url, youTubeStream.url)
        XCTAssertEqual(stream.duration, 261)
        XCTAssertNotNil(stream.expiresAt, "A fallback stream without an expiry is not cached forever")
        XCTAssertEqual(calls.values, ["saavn:Tum Hi Ho Mithoon:261", "youtube:Tum Hi Ho Mithoon:261"], "Sources are tried in order and carry the duration")

        // A restricted song has URLs the player must not use; the first source that matches wins.
        let restricted = Self.mock(details: "gaana-song-detail", transform: { $0.replacingOccurrences(of: "\"rest_lev\": \"0\"", with: "\"rest_lev\": \"2\"") })
        defer { restricted.close() }
        let ordered = GaanaStreamResolver(catalog: GaanaCatalogService(session: restricted.session), fallbacks: [failing, saavn, youTube],
                                          probe: { _ in XCTFail("Restricted streams are never probed") }, now: { Self.recordingTime })
        let viaSaavn = try await ordered.resolve(track: Self.tumHiHo, forceRefresh: false)
        XCTAssertEqual(viaSaavn.url, saavnStream.url)
        XCTAssertEqual(viaSaavn.quality?.bitRate, 320_000, "The More sheet shows the fallback's own quality")
        XCTAssertEqual(calls.values.count, 4, "A failing source is skipped, the match stops the chain")

        // Nothing matches anywhere.
        let empty = GaanaStreamResolver(catalog: GaanaCatalogService(session: missing.session), fallbacks: [miss],
                                        probe: { _ in }, now: { Self.recordingTime })
        do {
            _ = try await empty.resolve(track: Self.tumHiHo, forceRefresh: false)
            XCTFail("No source could play the song")
        } catch let error as PlaybackStreamError {
            guard case .noAudio = error else { return XCTFail("Unexpected error \(error)") }
        }
    }

    func testCrossSourceMatchRequiresTitleArtistAndDuration() {
        let wanted = Track(id: "gaana:1", title: "Tum Hi Ho", credits: [ArtistCredit(name: "Mithoon")], duration: 261)
        let exact = Track(id: "saavn:a", title: "Tum Hi Ho", credits: [ArtistCredit(name: "Mithoon"), ArtistCredit(name: "Arijit Singh")], duration: 262)
        let remix = Track(id: "saavn:b", title: "Tum Hi Ho (Remix)", credits: [ArtistCredit(name: "Mithoon")], duration: 262)
        let long = Track(id: "saavn:c", title: "Tum Hi Ho", credits: [ArtistCredit(name: "Mithoon")], duration: 300)
        let cover = Track(id: "saavn:d", title: "Tum Hi Ho", credits: [ArtistCredit(name: "Someone Else")], duration: 261)
        let video = Track(id: "abcdefghijk", title: "Tum Hi Ho", credits: [ArtistCredit(name: "Mithoon")], duration: 261, isAudioRecording: false)
        XCTAssertEqual(CrossSourceMatch.best([remix, long, cover, video, exact], for: wanted)?.id, "saavn:a")
        XCTAssertNil(CrossSourceMatch.best([exact], for: Track(id: "gaana:2", title: "Tum Hi Ho", credits: [])), "No duration, no match")
        XCTAssertEqual(CrossSourceMatch.best([cover], for: Track(id: "gaana:3", title: "tum hi ho", credits: [], duration: 263))?.id, "saavn:d",
                       "Without a credited artist the title and duration decide")
        XCTAssertEqual(CrossSourceMatch.query(for: wanted), "Tum Hi Ho Mithoon")
    }

    // MARK: Identity

    func testPrefixedIdentityHelpersForGaana() {
        XCTAssertEqual(MusicSource.gaana.collectionID(.album, providerID: "92317"), "gaana:album:92317")
        XCTAssertEqual(MusicSource.gaana.collectionID(.playlist, providerID: "1075124"), "gaana:playlist:1075124")
        XCTAssertEqual(MusicSource.gaana.collectionID(.mix, providerID: "3"), "gaana:playlist:3")
        XCTAssertEqual(MusicSource.gaana.collectionID(.artist, providerID: "52767"), "gaana:artist:52767")
        XCTAssertEqual(MusicSource.gaana.trackID(forProviderID: "944286"), "gaana:944286")
        XCTAssertEqual(MusicSource.entityKind(of: "gaana:album:92317"), .album)
        XCTAssertEqual(MusicSource.entityKind(of: "gaana:944286"), .track)
        XCTAssertEqual(MusicSource.entityProviderID(of: "gaana:artist:52767"), "52767")
        XCTAssertEqual(MusicSource.source(of: "gaana:944286"), .gaana)
        XCTAssertEqual(MusicSource.providerID(of: "gaana:944286"), "944286")
        XCTAssertEqual(MusicCollection(id: "gaana:playlist:1", title: "P").source, .gaana)
        XCTAssertTrue(AudioCache.isValidTrackID("gaana:944286"))
        XCTAssertTrue(AudioCache.isProviderTrackID("gaana:944286"))
        XCTAssertEqual(AudioCache.storageKey(for: "gaana:944286"), "gaana~944286")
        XCTAssertEqual(Track(id: "gaana:1", title: "Tom & Jerry", credits: []).shareURL?.absoluteString,
                       "https://gaana.com/search/all?keyword=Tom%20%26%20Jerry")
    }

    // MARK: Live (opt-in)

    func testLiveSearchResolvesAStreamOrFallback() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["GANABAJANA_GAANA_LIVE"] == "1", "Set GANABAJANA_GAANA_LIVE=1 to contact Gaana")
        let catalog = GaanaCatalogService()
        let page = try await catalog.search(query: "Tum Hi Ho", filter: .songs, continuation: nil)
        let track = try XCTUnwrap(page.tracks.first)
        XCTAssertEqual(track.source, .gaana)
        let saavn = JioSaavnCatalogService()
        let resolver = GaanaStreamResolver(catalog: catalog, fallbacks: [
            JioSaavnStreamFallback(catalog: saavn, resolver: JioSaavnStreamResolver(catalog: saavn)),
        ])
        let stream = try await resolver.resolve(track: track, forceRefresh: false)
        let (data, response) = try await URLSession.shared.data(from: stream.url)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        let kind = stream.url.pathExtension == "m3u8" ? "hls" : "file"
        if kind == "hls" { XCTAssertTrue(String(data: data.prefix(7), encoding: .utf8) == "#EXTM3U") }
        print("GANABAJANA_GAANA_LIVE kind=\(kind) host=\(stream.url.host ?? "") tier=\(stream.quality?.bitRate ?? 0) title=\(track.title)")
    }

    // MARK: Helpers

    /// A configurable cross-source stand-in; records "<source>:<query>:<duration>" per call.
    private struct StubFallback: CrossSourceStreamFallback {
        let source: MusicSource
        let calls: CatalogTestRecorder<String>
        let answer: @Sendable (Track) throws -> ResolvedStream?

        func resolve(matching track: Track, forceRefresh: Bool) async throws -> ResolvedStream? {
            calls.record("\(source.rawValue):\(CrossSourceMatch.query(for: track)):\(Int(track.duration ?? 0))")
            return try answer(track)
        }
    }

    private static func fixture(_ name: String) throws -> CatalogJSON {
        try GaanaTransport.decode(try data(name))
    }

    static func data(_ name: String) throws -> Data {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "json")
            ?? bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private static func items(_ request: URLRequest?) -> [String: String] {
        guard let url = request?.url, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return [:] }
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    /// Answers each documented call with its recorded fixture; unknown calls fail like an unsupported endpoint.
    static func mock(details: String = "gaana-song-detail", transform: (@Sendable (String) -> String)? = nil) -> CatalogMockSession {
        CatalogMockSession { request in
            guard let url = request.url else { throw URLError(.badURL) }
            let items = Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
                                   uniquingKeysWith: { first, _ in first })
            let file: String
            if url.host == "gsearch.gaana.com" {
                switch items["include"] {
                case "track": file = "gaana-search-tracks"
                case "album": file = "gaana-search-albums"
                case "artist": file = "gaana-search-artists"
                case "playlist": file = "gaana-search-playlists"
                default: file = "gaana-search-all"
                }
            } else {
                switch url.path {
                case "/", "":
                    guard items["subtype"] == "song_detail" else { throw URLError(.unsupportedURL) }
                    file = items["track_id"] == "944286" ? details : "gaana-song-detail-missing"
                case "/album/detail": file = items["album_id"] == "92317" ? "gaana-album" : "gaana-album-missing"
                case "/playlist/detail": file = "gaana-playlist"
                case "/artist/entity/detail/v1": file = items["artist_id"] == "52767" ? "gaana-artist" : "gaana-artist-missing"
                case "/home/artist/album/52767": file = "gaana-artist-albums"
                case "/player/similar-artists/52767": file = "gaana-similar-artists"
                case "/home/artist/tracks/27", "/home/artist/tracks/52767": file = "gaana-artist-tracks"
                default: throw URLError(.unsupportedURL)
                }
            }
            var payload = try data(file)
            if let transform, let text = String(data: payload, encoding: .utf8) { payload = Data(transform(text).utf8) }
            return CatalogStub(headers: ["Content-Type": "application/json"], data: payload)
        }
    }
}

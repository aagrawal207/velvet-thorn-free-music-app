import Foundation
import XCTest
@testable import GanaBajana

final class JioSaavnTests: XCTestCase {
    /// Recorded live on 25 September 2026 for `song.getDetails&pids=aRZbUYD7`; the CDN name is public catalog data.
    private static let recordedCipherText = "ID2ieOjCrwfgWvL5sXl4B1ImC5QfbsDyRofh8YQPTqjR2tIxTYXqGEQHgqnNfsetouo4rsD0s4RZKObWAyHrEhw7tS9a8Gtq"
    private static let recordedMediaURL = URL(string: "https://aac.saavncdn.com/430/5c5ea5cc00e3bff45616013226f376fe_96.mp4")!

    // MARK: Decryption and tiers

    func testDESRoundTripDecryptsAKnownURL() throws {
        let url = URL(string: "https://aac.saavncdn.com/123/abcdef0123456789_96.mp4")!
        let cipherText = try JioSaavnMediaURL.encrypt(url)
        XCTAssertNotEqual(cipherText, url.absoluteString)
        XCTAssertEqual(try JioSaavnMediaURL.decrypt(cipherText), url)
    }

    func testRecordedCipherTextDecryptsToTheObservedCDNURL() throws {
        XCTAssertEqual(try JioSaavnMediaURL.decrypt(Self.recordedCipherText), Self.recordedMediaURL)
    }

    func testDecryptionRejectsGarbageAndForeignHosts() throws {
        XCTAssertThrowsError(try JioSaavnMediaURL.decrypt("not base64!"))
        XCTAssertThrowsError(try JioSaavnMediaURL.decrypt(Data([1, 2, 3]).base64EncodedString()))
        let foreign = try JioSaavnMediaURL.encrypt(URL(string: "https://example.com/song_96.mp4")!)
        XCTAssertThrowsError(try JioSaavnMediaURL.decrypt(foreign)) { error in
            XCTAssertEqual(error as? JioSaavnMediaURL.DecryptionError, .invalidURL)
        }
    }

    func testTierURLsReplaceTheBitrateSuffix() throws {
        let base = Self.recordedMediaURL
        XCTAssertEqual(JioSaavnMediaURL.url(base, tier: .kbps320)?.absoluteString,
                       "https://aac.saavncdn.com/430/5c5ea5cc00e3bff45616013226f376fe_320.mp4")
        XCTAssertEqual(JioSaavnMediaURL.url(base, tier: .kbps48)?.lastPathComponent, "5c5ea5cc00e3bff45616013226f376fe_48.mp4")
        XCTAssertNil(JioSaavnMediaURL.url(URL(string: "https://aac.saavncdn.com/430/name.mp4")!, tier: .kbps160))
        XCTAssertNil(JioSaavnMediaURL.url(URL(string: "https://aac.saavncdn.com/430/name_96.webm")!, tier: .kbps160))
    }

    func testQualityCeilingSelectsTiers() {
        XCTAssertEqual(JioSaavnMediaURL.candidates(has320: true, maximumBitRate: AudioQualityPreference.best.maximumBitRate),
                       [.kbps320, .kbps160, .kbps96, .kbps48])
        XCTAssertEqual(JioSaavnMediaURL.candidates(has320: false, maximumBitRate: AudioQualityPreference.best.maximumBitRate),
                       [.kbps160, .kbps96, .kbps48])
        XCTAssertEqual(JioSaavnMediaURL.candidates(has320: true, maximumBitRate: AudioQualityPreference.balanced.maximumBitRate),
                       [.kbps160, .kbps96, .kbps48])
        XCTAssertEqual(JioSaavnMediaURL.candidates(has320: true, maximumBitRate: AudioQualityPreference.dataSaver.maximumBitRate), [.kbps48])
        XCTAssertEqual(JioSaavnMediaURL.Tier.kbps320.quality, SourceAudioQuality(codec: .aac, bitRate: 320_000, sampleRate: 44_100, channels: 2))
    }

    // MARK: Text

    func testHTMLEntitiesAreUnescaped() {
        XCTAssertEqual(JioSaavnText.unescape("Phir Mohabbat (From &quot;Murder 2&quot;)"), "Phir Mohabbat (From \"Murder 2\")")
        XCTAssertEqual(JioSaavnText.unescape("Tom &amp; Jerry &#039;s &#x27;day&#x27; &lt;3"), "Tom & Jerry 's 'day' <3")
        XCTAssertEqual(JioSaavnText.unescape("Rock & Roll; no entity"), "Rock & Roll; no entity")
        XCTAssertEqual(JioSaavnText.unescape("&unknownentity; stays"), "&unknownentity; stays")
        XCTAssertEqual(JioSaavnText.artwork("https://c.saavncdn.com/430/Aashiqui-2-Hindi-2013-150x150.jpg")?.absoluteString,
                       "https://c.saavncdn.com/430/Aashiqui-2-Hindi-2013-500x500.jpg")
        XCTAssertEqual(JioSaavnText.artwork("https://c.saavncdn.com/artists/Arijit_50x50.jpg?bch=1")?.absoluteString,
                       "https://c.saavncdn.com/artists/Arijit_500x500.jpg?bch=1")
        XCTAssertNil(JioSaavnText.artwork("http://c.saavncdn.com/x-150x150.jpg"))
        XCTAssertNil(JioSaavnText.artwork("https://example.com/x-150x150.jpg"))
        XCTAssertNil(JioSaavnText.identifier("saavn:abc"))
        XCTAssertEqual(JioSaavnText.identifier(" aRZbUYD7 "), "aRZbUYD7")
    }

    // MARK: Parsers

    func testSongSearchRowsMapOntoTracks() throws {
        let page = JioSaavnParser.search(try Self.fixture("saavn-search-songs"), filter: .songs)
        XCTAssertEqual(page.tracks.count, 3)
        let track = try XCTUnwrap(page.tracks.first)
        XCTAssertEqual(track.id, "saavn:aRZbUYD7")
        XCTAssertEqual(track.source, .jioSaavn)
        XCTAssertEqual(track.providerID, "aRZbUYD7")
        XCTAssertEqual(track.title, "Tum Hi Ho")
        XCTAssertEqual(track.credits, [ArtistCredit(name: "Mithoon", id: "saavn:artist:702592"),
                                       ArtistCredit(name: "Arijit Singh", id: "saavn:artist:459320")])
        XCTAssertEqual(track.albumTitle, "Aashiqui 2")
        XCTAssertEqual(track.albumID, "saavn:album:1139549")
        XCTAssertEqual(track.duration, 262)
        XCTAssertEqual(track.artworkURL?.absoluteString, "https://c.saavncdn.com/430/Aashiqui-2-Hindi-2013-500x500.jpg")
        XCTAssertEqual(track.language, .hindi)
        XCTAssertFalse(track.isExplicit)
        XCTAssertEqual(track.isAudioRecording, true)
        XCTAssertEqual(track.playCount, 372_864_820)
        XCTAssertEqual(track.shareURL?.absoluteString, "https://www.jiosaavn.com/search/song/Tum%20Hi%20Ho")
        XCTAssertEqual(page.collections.count, 0)
    }

    func testAlbumArtistAndPlaylistSearchRowsMapOntoCollections() throws {
        let albums = JioSaavnParser.search(try Self.fixture("saavn-search-albums"), filter: .albums).collections
        XCTAssertEqual(albums.first?.id, "saavn:album:1139549")
        XCTAssertEqual(albums.first?.title, "Aashiqui 2")
        XCTAssertEqual(albums.first?.kind, .album)
        XCTAssertEqual(albums.first?.subtitle, "Jeet Gannguli, Mithoon, Ankit Tiwari · 2013")
        XCTAssertEqual(albums.first?.language, .hindi)
        XCTAssertEqual(albums.first?.source, .jioSaavn)

        let artists = JioSaavnParser.search(try Self.fixture("saavn-search-artists"), filter: .artists).collections
        XCTAssertEqual(artists.count, 3)
        XCTAssertEqual(artists.first?.id, "saavn:artist:459320")
        XCTAssertEqual(artists.first?.title, "Arijit Singh")
        XCTAssertEqual(artists.first?.kind, .artist)
        XCTAssertEqual(artists.first?.artworkURL?.absoluteString, "https://c.saavncdn.com/artists/Arijit_Singh_004_20241118063717_500x500.jpg")

        let playlists = JioSaavnParser.search(try Self.fixture("saavn-search-playlists"), filter: .playlists).collections
        XCTAssertEqual(playlists.first?.id, "saavn:playlist:32049168")
        XCTAssertEqual(playlists.first?.title, "Bollywood Bappa")
        XCTAssertEqual(playlists.first?.subtitle, "21 songs")
        XCTAssertEqual(playlists.first?.kind, .playlist)
    }

    func testAlbumPageCarriesHeaderCreditsAndSongs() throws {
        let page = try XCTUnwrap(JioSaavnParser.albumPage(try Self.fixture("saavn-album")))
        XCTAssertEqual(page.title, "Aashiqui 2")
        XCTAssertEqual(page.credits.map(\.name), ["Jeet Gannguli", "Mithoon", "Ankit Tiwari"])
        XCTAssertEqual(page.credits.map(\.id), ["saavn:artist:464912", "saavn:artist:702592", "saavn:artist:484852"])
        XCTAssertEqual(page.tracks.count, 3)
        XCTAssertTrue(page.tracks.allSatisfy { $0.albumID == "saavn:album:1139549" })
    }

    func testPlaylistPageReportsTheProviderTotal() throws {
        let parsed = try XCTUnwrap(JioSaavnParser.playlistPage(try Self.fixture("saavn-playlist")))
        XCTAssertEqual(parsed.page.title, "Bollywood Bappa")
        XCTAssertEqual(parsed.page.tracks.count, 3)
        XCTAssertEqual(parsed.total, 20)
        XCTAssertEqual(parsed.page.tracks.first?.id, "saavn:GGMI3kq4")
    }

    func testArtistPageCollectsSongsReleasesAndUnescapesTitles() throws {
        let page = try XCTUnwrap(JioSaavnParser.artistPage(try Self.fixture("saavn-artist"), id: "saavn:artist:459320"))
        XCTAssertEqual(page.id, "saavn:artist:459320")
        XCTAssertEqual(page.name, "Arijit Singh")
        XCTAssertEqual(page.artworkURL?.absoluteString, "https://c.saavncdn.com/artists/Arijit_Singh_004_20241118063717_500x500.jpg")
        XCTAssertEqual(page.topSongs.count, 2)
        XCTAssertEqual(page.topSongs.first?.title, "Gehra Hua (From \"Dhurandhar\")")
        XCTAssertEqual(page.topSongs.first?.albumTitle, "Gehra Hua (From \"Dhurandhar\")")
        XCTAssertEqual(page.releases.count, 4)
        XCTAssertTrue(page.releases.allSatisfy { $0.kind == .album && $0.id.hasPrefix("saavn:album:") })
        XCTAssertTrue(page.relatedArtists.isEmpty)
        XCTAssertNil(page.monthlyAudience)
    }

    func testRecommendationsExcludeTheSeedAndAcceptTheAndroidShape() throws {
        let tracks = JioSaavnParser.recommendations(try Self.fixture("saavn-reco"), seedProviderID: "aRZbUYD7")
        XCTAssertEqual(tracks.count, 2)
        XCTAssertEqual(tracks.first?.id, "saavn:Bcy2xpAw")
        XCTAssertEqual(tracks.first?.title, "Phir Mohabbat (From \"Murder 2\")")
        XCTAssertTrue(JioSaavnParser.recommendations(try JioSaavnTransport.decode(Data("[]".utf8)), seedProviderID: "aRZbUYD7").isEmpty)
    }

    func testSongDetailsKeepTheEncryptedMediaFields() throws {
        let songs = JioSaavnParser.songDetails(try Self.fixture("saavn-song-details"))
        let song = try XCTUnwrap(songs.first)
        XCTAssertEqual(song.track.id, "saavn:aRZbUYD7")
        XCTAssertEqual(song.encryptedMediaURL, Self.recordedCipherText)
        XCTAssertTrue(song.has320)
        // The details call reported no lyrics for a song whose search row and lyrics call had them; the flag is advisory.
        XCTAssertFalse(song.hasLyrics)
    }

    func testLyricsConvertLineBreaksAndDetectFailures() throws {
        let text = try XCTUnwrap(JioSaavnParser.lyrics(try Self.fixture("saavn-lyrics")))
        XCTAssertEqual(text.split(separator: "\n").count, 5)
        XCTAssertTrue(text.hasPrefix("Hum Tere Bin Ab Reh Nahi Sakte\nTere Bina Kya Wajood Mera"))
        XCTAssertNil(JioSaavnParser.lyrics(try Self.fixture("saavn-lyrics-failure")))
        XCTAssertEqual(try JioSaavnTransport.decode(Data("callback({\"lyrics\":\"a<br>b\"});".utf8))["lyrics"].string, "a<br>b")
        XCTAssertThrowsError(try JioSaavnTransport.decode(Data("\"just a string\"".utf8)))
    }

    // MARK: Service through a mocked session

    func testSearchSendsTheDocumentedParametersAndCachesForAMinute() async throws {
        let clock = CatalogTestClock()
        let mock = Self.mock()
        defer { mock.close() }
        let service = JioSaavnCatalogService(session: mock.session, now: { clock.now })
        let first = try await service.search(query: "tum hi ho", filter: .songs, continuation: nil)
        XCTAssertEqual(first.tracks.map(\.id), ["saavn:aRZbUYD7", "saavn:Bt07_OpM", "saavn:yXCLyL-9"])
        let request = try XCTUnwrap(mock.state.requests.first)
        let items = Dictionary(uniqueKeysWithValues: URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.host, "www.jiosaavn.com")
        XCTAssertEqual(request.url?.path, "/api.php")
        XCTAssertEqual(items["__call"], "search.getResults")
        XCTAssertEqual(items["q"], "tum hi ho")
        XCTAssertEqual(items["p"], "1")
        XCTAssertEqual(items["n"], "20")
        XCTAssertEqual(items["_format"], "json")
        XCTAssertEqual(items["_marker"], "0")
        XCTAssertEqual(items["api_version"], "4")
        XCTAssertEqual(items["ctx"], "web6dot0")
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
    }

    func testBrowseAndArtistRouteByPrefixedIdentity() async throws {
        let mock = Self.mock()
        defer { mock.close() }
        let service = JioSaavnCatalogService(session: mock.session)
        let album = try await service.browse(id: "saavn:album:1139549")
        XCTAssertEqual(album.title, "Aashiqui 2")
        XCTAssertEqual(album.tracks.count, 3)
        XCTAssertEqual(Self.call(mock.state.requests.last), "content.getAlbumDetails")
        XCTAssertEqual(Self.query(mock.state.requests.last, "albumid"), "1139549")

        let playlist = try await service.browse(id: "saavn:playlist:32049168")
        XCTAssertEqual(playlist.title, "Bollywood Bappa")
        XCTAssertEqual(playlist.tracks.count, 3)
        let playlistRequests = mock.state.requests.filter { Self.call($0) == "playlist.getDetails" }
        XCTAssertEqual(playlistRequests.count, 2, "A repeated page ends pagination before the page budget")
        XCTAssertEqual(Self.query(playlistRequests.first, "n"), "100")

        let artist = try await service.artist(id: "saavn:artist:459320")
        XCTAssertEqual(artist.name, "Arijit Singh")
        XCTAssertEqual(Self.query(mock.state.requests.last, "artistId"), "459320")
        let asPage = try await service.browse(id: "saavn:artist:459320")
        XCTAssertEqual(asPage.tracks.count, 2)
        XCTAssertEqual(asPage.collections.count, 4)

        let awaited1 = try await service.browse(id: "MPREb_notSaavn").tracks.isEmpty
        XCTAssertTrue(awaited1)
        do {
            _ = try await service.artist(id: "saavn:album:1139549")
            XCTFail("An album id is not an artist")
        } catch { XCTAssertTrue(error is MusicServiceError) }
        let awaited2 = try await service.discovery(languages: [.hindi]).isEmpty
        XCTAssertTrue(awaited2)
    }

    func testRadioUsesTheAndroidContextAndLyricsTreatFailureAsAbsence() async throws {
        let mock = Self.mock()
        defer { mock.close() }
        let service = JioSaavnCatalogService(session: mock.session)
        let seed = Track(id: "saavn:aRZbUYD7", title: "Tum Hi Ho", credits: [])
        let radio = try await service.radio(seed: seed)
        XCTAssertEqual(radio.map(\.id), ["saavn:Bcy2xpAw", "saavn:5GuGvCWv"])
        XCTAssertEqual(Self.query(mock.state.requests.last, "ctx"), "android")
        XCTAssertEqual(Self.query(mock.state.requests.last, "pid"), "aRZbUYD7")
        let foreignRadio = try await service.radio(seed: Track(id: "fsiPzT50ZiM", title: "YouTube", credits: []))
        XCTAssertTrue(foreignRadio.isEmpty)

        let lyrics = try await service.lyrics(for: seed)
        XCTAssertEqual(lyrics.kind, .plain)
        XCTAssertEqual(lyrics.source, "JioSaavn")
        XCTAssertEqual(lyrics.trackID, seed.id)
        XCTAssertTrue(lyrics.plainText?.hasPrefix("Hum Tere Bin") == true)
        let missing = try await service.lyrics(for: Track(id: "saavn:Bcy2xpAw", title: "Phir Mohabbat", credits: []))
        XCTAssertEqual(missing.kind, .unavailable)
        let foreignLyrics = try await service.lyrics(for: Track(id: "fsiPzT50ZiM", title: "YouTube", credits: []))
        XCTAssertEqual(foreignLyrics.kind, .unavailable)
    }

    func testRateLimitingHonoursRetryAfterWithoutASecondRequest() async throws {
        let clock = CatalogTestClock()
        let mock = CatalogMockSession { _ in
            CatalogStub(status: 429, headers: ["Retry-After": "120", "Content-Type": "application/json"], data: Data("{}".utf8))
        }
        defer { mock.close() }
        let service = JioSaavnCatalogService(session: mock.session, now: { clock.now })
        for _ in 0..<2 {
            do {
                _ = try await service.search(query: "tum", filter: .songs, continuation: nil)
                XCTFail("A 429 must surface as rate limiting")
            } catch let error as MusicServiceError {
                guard case .rateLimited = error else { return XCTFail("Unexpected error \(error)") }
            }
        }
        XCTAssertEqual(mock.state.requests.count, 1, "The Retry-After window blocks further requests")
        clock.advance(121)
        _ = try? await service.search(query: "tum", filter: .songs, continuation: nil)
        XCTAssertEqual(mock.state.requests.count, 2)
    }

    func testOversizedBodiesAreRejected() async throws {
        let mock = CatalogMockSession { _ in
            CatalogStub(headers: ["Content-Type": "application/json", "Content-Length": String(5 * 1_024 * 1_024)],
                        data: Data(repeating: 0x20, count: 16))
        }
        defer { mock.close() }
        let service = JioSaavnCatalogService(session: mock.session)
        do {
            _ = try await service.search(query: "tum", filter: .songs, continuation: nil)
            XCTFail("A declared 5 MiB body exceeds the 4 MiB cap")
        } catch let error as MusicServiceError {
            guard case .invalidResponse = error else { return XCTFail("Unexpected error \(error)") }
        }
    }

    // MARK: Stream resolver

    func testResolverPicksTheHighestProbedTierUnderEachPreference() async throws {
        let cases: [(AudioQualityPreference, Int)] = [(.best, 320), (.balanced, 160), (.dataSaver, 48)]
        for (preference, expected) in cases {
            let mock = Self.mock()
            defer { mock.close() }
            let probed = CatalogTestRecorder<URL>()
            let resolver = JioSaavnStreamResolver(catalog: JioSaavnCatalogService(session: mock.session), quality: preference,
                                                  probe: { probed.record($0) }, now: { Date(timeIntervalSince1970: 1_000_000) })
            let track = Track(id: "saavn:aRZbUYD7", title: "Tum Hi Ho", credits: [], duration: 262, playCount: 5)
            let stream = try await resolver.resolve(track: track, forceRefresh: false)
            XCTAssertEqual(stream.url.lastPathComponent, "5c5ea5cc00e3bff45616013226f376fe_\(expected).mp4", preference.rawValue)
            XCTAssertEqual(stream.quality?.bitRate, expected * 1_000)
            XCTAssertEqual(stream.quality?.codec, .aac)
            XCTAssertEqual(stream.expiresAt, Date(timeIntervalSince1970: 1_000_000 + 6 * 3_600))
            XCTAssertNil(stream.loudnessDb)
            XCTAssertEqual(stream.viewCount, 372_864_574, "The fresh provider count wins over the row's stale value")
            XCTAssertEqual(stream.duration, 262)
            XCTAssertEqual(probed.values.count, 1)
            XCTAssertEqual(Self.call(mock.state.requests.last), "song.getDetails")
        }
    }

    func testResolverFallsToTheNextTierAndCachesTheResult() async throws {
        let mock = Self.mock()
        defer { mock.close() }
        let resolver = JioSaavnStreamResolver(catalog: JioSaavnCatalogService(session: mock.session), quality: .best, probe: { url in
            if url.lastPathComponent.hasSuffix("_320.mp4") { throw PlaybackStreamError.httpStatus(404) }
        })
        let track = Track(id: "saavn:aRZbUYD7", title: "Tum Hi Ho", credits: [])
        let first = try await resolver.resolve(track: track, forceRefresh: false)
        XCTAssertEqual(first.quality?.bitRate, 160_000)
        let second = try await resolver.resolve(track: track, forceRefresh: false)
        XCTAssertEqual(second.url, first.url)
        XCTAssertEqual(mock.state.requests.count, 1, "A cached stream needs no second details request")
        await resolver.setAudioQualityPreference(.dataSaver)
        let capped = try await resolver.resolve(track: track, forceRefresh: false)
        XCTAssertEqual(capped.quality?.bitRate, 48_000, "A new ceiling re-selects instead of replaying the cached pick")
        do {
            _ = try await resolver.resolve(track: Track(id: "fsiPzT50ZiM", title: "YouTube", credits: []), forceRefresh: false)
            XCTFail("Bare ids never reach the JioSaavn resolver")
        } catch let error as PlaybackStreamError {
            guard case .invalidID = error else { return XCTFail("Unexpected error \(error)") }
        }
    }

    // MARK: Identity

    func testPrefixedIdentityHelpers() {
        XCTAssertEqual(MusicSource.jioSaavn.collectionID(.album, providerID: "1"), "saavn:album:1")
        XCTAssertEqual(MusicSource.jioSaavn.collectionID(.playlist, providerID: "2"), "saavn:playlist:2")
        XCTAssertEqual(MusicSource.jioSaavn.collectionID(.mix, providerID: "3"), "saavn:playlist:3")
        XCTAssertEqual(MusicSource.jioSaavn.collectionID(.artist, providerID: "4"), "saavn:artist:4")
        XCTAssertEqual(MusicSource.youTubeMusic.collectionID(.album, providerID: "MPREb_1"), "MPREb_1")
        XCTAssertEqual(MusicSource.entityKind(of: "saavn:album:1"), .album)
        XCTAssertEqual(MusicSource.entityKind(of: "saavn:playlist:2"), .playlist)
        XCTAssertEqual(MusicSource.entityKind(of: "saavn:artist:4"), .artist)
        XCTAssertEqual(MusicSource.entityKind(of: "saavn:aRZbUYD7"), .track)
        XCTAssertNil(MusicSource.entityKind(of: "fsiPzT50ZiM"))
        XCTAssertNil(MusicSource.entityKind(of: "saavn:bogus:1"))
        XCTAssertEqual(MusicSource.entityProviderID(of: "saavn:album:1"), "1")
        XCTAssertEqual(MusicSource.entityProviderID(of: "saavn:aRZbUYD7"), "aRZbUYD7")
        XCTAssertEqual(MusicSource.entityProviderID(of: "fsiPzT50ZiM"), "fsiPzT50ZiM")
        XCTAssertEqual(MusicSource.source(of: "saavn:album:1"), .jioSaavn)
        XCTAssertEqual(MusicSource.source(of: "gaana:1"), .gaana)
        XCTAssertEqual(MusicCollection(id: "saavn:album:1", title: "A").source, .jioSaavn)
        XCTAssertEqual(MusicCollection(id: "MPREb_1", title: "A").source, .youTubeMusic)
    }

    func testShareURLsFollowTheSource() {
        XCTAssertEqual(Track(id: "fsiPzT50ZiM", title: "Tum Hi Ho", credits: []).shareURL?.absoluteString,
                       "https://music.youtube.com/watch?v=fsiPzT50ZiM")
        XCTAssertEqual(Track(id: "saavn:aRZbUYD7", title: "Tum Hi Ho", credits: []).shareURL?.absoluteString,
                       "https://www.jiosaavn.com/search/song/Tum%20Hi%20Ho")
        XCTAssertEqual(Track(id: "gaana:1", title: "Song", credits: []).shareURL?.absoluteString, "https://gaana.com/search/all?keyword=Song")
    }

    // MARK: Live (opt-in)

    func testLiveSearchResolvesAPlayableStream() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["GANABAJANA_SAAVN_LIVE"] == "1", "Set GANABAJANA_SAAVN_LIVE=1 to contact JioSaavn")
        let catalog = JioSaavnCatalogService()
        let page = try await catalog.search(query: "Tum Hi Ho", filter: .songs, continuation: nil)
        let track = try XCTUnwrap(page.tracks.first)
        XCTAssertEqual(track.source, .jioSaavn)
        let resolver = JioSaavnStreamResolver(catalog: catalog, quality: .best)
        let stream = try await resolver.resolve(track: track, forceRefresh: false)
        var request = URLRequest(url: stream.url)
        request.httpMethod = "HEAD"
        let (_, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertTrue(http.mimeType?.hasPrefix("audio/") == true, http.mimeType ?? "no content type")
        print("GANABAJANA_SAAVN_LIVE tier=\(stream.quality?.bitRate ?? 0) title=\(track.title)")
    }

    // MARK: Helpers

    private static func fixture(_ name: String) throws -> CatalogJSON {
        try JioSaavnTransport.decode(try data(name))
    }

    private static func data(_ name: String) throws -> Data {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "json")
            ?? bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private static func call(_ request: URLRequest?) -> String? { query(request, "__call") }

    private static func query(_ request: URLRequest?, _ name: String) -> String? {
        guard let url = request?.url else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }

    /// Answers each documented call with its recorded fixture; unknown calls fail like an unsupported endpoint.
    private static func mock() -> CatalogMockSession {
        CatalogMockSession { request in
            let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                .map { ($0.name, $0.value ?? "") })
            let file: String
            switch items["__call"] {
            case "search.getResults": file = "saavn-search-songs"
            case "search.getAlbumResults": file = "saavn-search-albums"
            case "search.getArtistResults": file = "saavn-search-artists"
            case "search.getPlaylistResults": file = "saavn-search-playlists"
            case "content.getAlbumDetails": file = "saavn-album"
            case "playlist.getDetails": file = "saavn-playlist"
            case "artist.getArtistPageDetails": file = "saavn-artist"
            case "reco.getreco": return CatalogStub(data: items["ctx"] == "android" ? try data("saavn-reco") : Data("[]".utf8))
            case "song.getDetails": file = "saavn-song-details"
            case "lyrics.getLyrics": file = items["lyrics_id"] == "aRZbUYD7" ? "saavn-lyrics" : "saavn-lyrics-failure"
            default: throw URLError(.unsupportedURL)
            }
            return CatalogStub(headers: ["Content-Type": "text/html; charset=UTF-8"], data: try data(file))
        }
    }
}

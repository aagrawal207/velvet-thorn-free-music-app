import Foundation
import XCTest
@testable import GanaBajana

/// A catalog stub that records calls and answers with configurable pages, delays or failures.
private actor StubCatalog: MusicCatalogProviding, LyricsProviding, AlbumDescriptionProviding {
    let name: String
    var tracks: [Track]
    var collections: [MusicCollection] = []
    var delay: Duration = .zero
    var error: (any Error)?
    private(set) var calls: [String] = []

    init(name: String, tracks: [Track] = []) {
        self.name = name
        self.tracks = tracks
    }

    func configure(delay: Duration = .zero, error: (any Error)? = nil, collections: [MusicCollection] = []) {
        self.delay = delay
        self.error = error
        self.collections = collections
    }

    private func record(_ call: String) async throws {
        calls.append(call)
        if delay > .zero { try await Task.sleep(for: delay) }
        if let error { throw error }
    }

    func search(query: String, filter: SearchFilter, continuation: String?) async throws -> CatalogPage {
        try await record("search:\(query):\(filter.rawValue):\(continuation ?? "-")")
        return CatalogPage(tracks: filter == .songs ? tracks : [], collections: filter == .songs ? [] : collections,
                           continuation: name == "youtube" ? "yt-page-2" : nil)
    }

    func browse(id: String) async throws -> CatalogPage {
        try await record("browse:\(id)")
        return CatalogPage(tracks: tracks, title: name)
    }

    func artist(id: String) async throws -> ArtistPage {
        try await record("artist:\(id)")
        return ArtistPage(id: id, name: name, topSongs: tracks)
    }

    func recommendations(seed: Track, language: MusicLanguage) async throws -> [Track] {
        try await record("recommendations:\(seed.id)")
        return tracks
    }

    func radio(seed: Track) async throws -> [Track] {
        try await record("radio:\(seed.id)")
        return tracks
    }

    func radio(seed: Track, forceRefresh: Bool) async throws -> [Track] {
        try await record("radio:\(seed.id):\(forceRefresh)")
        return tracks
    }

    func discovery(languages: Set<MusicLanguage>) async throws -> [DiscoverySection] {
        try await record("discovery")
        return [DiscoverySection(id: name, title: name)]
    }

    func lyrics(for track: Track) async throws -> LyricsDocument {
        try await record("lyrics:\(track.id)")
        return LyricsDocument(trackID: track.id, kind: .plain, plainText: name, source: name)
    }

    func albumDescription(id: String) async throws -> AlbumDescription? {
        try await record("description:\(id)")
        return nil
    }
}

final class CompositeCatalogTests: XCTestCase {
    private let youTubeTracks = [Track(id: "fsiPzT50ZiM", title: "Tum Hi Ho", credits: [ArtistCredit(name: "Arijit Singh")]),
                                 Track(id: "NJAv_7lHUIU", title: "Kesariya", credits: [ArtistCredit(name: "Arijit Singh")])]
    private let saavnTracks = [Track(id: "saavn:aRZbUYD7", title: "Tum Hi Ho", credits: [ArtistCredit(name: "Arijit Singh")]),
                               Track(id: "saavn:Bt07_OpM", title: "Tum Se Hi", credits: [ArtistCredit(name: "Mohit Chauhan")])]
    private let gaanaTracks = [Track(id: "gaana:944286", title: "Tum Hi Ho", credits: [ArtistCredit(name: "Mithoon")]),
                               Track(id: "gaana:944317", title: "Meri Aashiqui", credits: [ArtistCredit(name: "Arijit Singh")])]

    private func makeComposite(enabled: [MusicSource] = MusicSource.allCases, deadline: TimeInterval = 6)
        -> (CompositeCatalog, StubCatalog, StubCatalog) {
        let youTube = StubCatalog(name: "youtube", tracks: youTubeTracks)
        let saavn = StubCatalog(name: "saavn", tracks: saavnTracks)
        let composite = CompositeCatalog(youTube: youTube, secondary: [.jioSaavn: saavn], enabledSources: enabled, secondarySearchDeadline: deadline)
        return (composite, youTube, saavn)
    }

    private func makeThreeSourceComposite(enabled: [MusicSource] = MusicSource.allCases)
        -> (CompositeCatalog, StubCatalog, StubCatalog, StubCatalog) {
        let youTube = StubCatalog(name: "youtube", tracks: youTubeTracks)
        let saavn = StubCatalog(name: "saavn", tracks: saavnTracks)
        let gaana = StubCatalog(name: "gaana", tracks: gaanaTracks)
        let composite = CompositeCatalog(youTube: youTube, secondary: [.jioSaavn: saavn, .gaana: gaana], enabledSources: enabled,
                                         secondarySearchDeadline: 0.5)
        return (composite, youTube, saavn, gaana)
    }

    func testSearchFansOutAndListsYouTubeFirst() async throws {
        let (composite, youTube, saavn) = makeComposite()
        let page = try await CompositeCatalog.searchingAllSources { try await composite.search(query: "tum", filter: .songs, continuation: nil) }
        XCTAssertEqual(page.tracks.map(\.id), ["fsiPzT50ZiM", "NJAv_7lHUIU", "saavn:aRZbUYD7", "saavn:Bt07_OpM"])
        XCTAssertEqual(page.continuation, "yt-page-2", "Pagination follows the primary catalog")
        let awaited1 = await youTube.calls
        XCTAssertEqual(awaited1, ["search:tum:songs:-"])
        let awaited2 = await saavn.calls
        XCTAssertEqual(awaited2, ["search:tum:songs:-"])
        let albums = try await CompositeCatalog.searchingAllSources { try await composite.search(query: "tum", filter: .albums, continuation: nil) }
        XCTAssertTrue(albums.tracks.isEmpty)
        let awaited3 = await saavn.calls.last
        XCTAssertEqual(awaited3, "search:tum:albums:-", "Filters apply per source")
    }

    func testUnscopedSearchesStayWithThePrimaryCatalog() async throws {
        let (composite, youTube, saavn) = makeComposite()
        let page = try await composite.search(query: "arijit", filter: .artists, continuation: nil)
        XCTAssertTrue(page.tracks.isEmpty)
        let youTubeCalls = await youTube.calls
        XCTAssertEqual(youTubeCalls, ["search:arijit:artists:-"])
        let saavnCalls = await saavn.calls
        XCTAssertTrue(saavnCalls.isEmpty, "Artist matching, radio seeds and spotlights never mix providers")
    }

    func testAFailingSecondarySourceStillReturnsTheHealthyOne() async throws {
        let (composite, _, saavn) = makeComposite()
        await saavn.configure(error: MusicServiceError.rateLimited)
        let page = try await CompositeCatalog.searchingAllSources { try await composite.search(query: "tum", filter: .songs, continuation: nil) }
        XCTAssertEqual(page.tracks.map(\.id), ["fsiPzT50ZiM", "NJAv_7lHUIU"])
    }

    func testAFailingPrimaryStillReturnsTheSecondarySource() async throws {
        let (composite, youTube, _) = makeComposite()
        await youTube.configure(error: MusicServiceError.network("down"))
        let page = try await CompositeCatalog.searchingAllSources { try await composite.search(query: "tum", filter: .songs, continuation: nil) }
        XCTAssertEqual(page.tracks.map(\.id), ["saavn:aRZbUYD7", "saavn:Bt07_OpM"])
        XCTAssertNil(page.continuation)
    }

    func testWhenEverySourceFailsThePrimaryErrorSurfaces() async throws {
        let (composite, youTube, saavn) = makeComposite()
        await youTube.configure(error: MusicServiceError.network("primary down"))
        await saavn.configure(error: MusicServiceError.rateLimited)
        do {
            _ = try await CompositeCatalog.searchingAllSources { try await composite.search(query: "tum", filter: .songs, continuation: nil) }
            XCTFail("No source answered")
        } catch let error as MusicServiceError {
            guard case .network(let message) = error else { return XCTFail("Unexpected error \(error)") }
            XCTAssertEqual(message, "primary down")
        }
    }

    func testATimingOutSecondarySourceIsDroppedAtTheDeadline() async throws {
        let (composite, _, saavn) = makeComposite(deadline: 0.3)
        await saavn.configure(delay: .seconds(5))
        let started = Date()
        let page = try await CompositeCatalog.searchingAllSources { try await composite.search(query: "tum", filter: .songs, continuation: nil) }
        XCTAssertEqual(page.tracks.map(\.id), ["fsiPzT50ZiM", "NJAv_7lHUIU"])
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "The secondary deadline bounds the extra wait")
    }

    func testDisabledSourcesAreNotSearchedAndContinuationsStayWithYouTube() async throws {
        let (composite, youTube, saavn) = makeComposite(enabled: [.youTubeMusic])
        let page = try await CompositeCatalog.searchingAllSources { try await composite.search(query: "tum", filter: .songs, continuation: nil) }
        XCTAssertEqual(page.tracks.map(\.id), ["fsiPzT50ZiM", "NJAv_7lHUIU"])
        let awaited4 = await saavn.calls.isEmpty
        XCTAssertTrue(awaited4)
        await composite.setEnabledSources([.youTubeMusic, .jioSaavn])
        _ = try await CompositeCatalog.searchingAllSources { try await composite.search(query: "tum", filter: .songs, continuation: "yt-page-2") }
        let awaited5 = await saavn.calls.isEmpty
        XCTAssertTrue(awaited5, "A continuation never fans out")
        let awaited6 = await youTube.calls.last
        XCTAssertEqual(awaited6, "search:tum:songs:yt-page-2")
        let merged = try await CompositeCatalog.searchingAllSources { try await composite.search(query: "tum", filter: .songs, continuation: nil) }
        XCTAssertEqual(merged.tracks.count, 4)
        await composite.setEnabledSources([])
        let awaited7 = await composite.activeSources
        XCTAssertEqual(awaited7, [.youTubeMusic], "YouTube cannot be switched off")
    }

    func testRoutingFollowsTheIdPrefix() async throws {
        let (composite, youTube, saavn) = makeComposite()
        _ = try await composite.browse(id: "saavn:album:1139549")
        _ = try await composite.browse(id: "MPREb_album")
        _ = try await composite.artist(id: "saavn:artist:459320")
        _ = try await composite.artist(id: "UCartist000000000000000")
        _ = try await composite.radio(seed: saavnTracks[0])
        _ = try await composite.radio(seed: youTubeTracks[0], forceRefresh: true)
        _ = try await composite.recommendations(seed: saavnTracks[1], language: .hindi)
        _ = try await composite.lyrics(for: saavnTracks[0])
        _ = try await composite.lyrics(for: youTubeTracks[1])
        _ = try await composite.albumDescription(id: "saavn:album:1")
        _ = try await composite.albumDescription(id: "MPREb_album")
        _ = try await composite.discovery(languages: [.hindi])
        let saavnCalls = await saavn.calls
        XCTAssertEqual(saavnCalls, ["browse:saavn:album:1139549", "artist:saavn:artist:459320", "radio:saavn:aRZbUYD7",
                                    "recommendations:saavn:Bt07_OpM", "lyrics:saavn:aRZbUYD7", "description:saavn:album:1"])
        let youTubeCalls = await youTube.calls
        XCTAssertEqual(youTubeCalls, ["browse:MPREb_album", "artist:UCartist000000000000000", "radio:fsiPzT50ZiM:true",
                                      "lyrics:NJAv_7lHUIU", "description:MPREb_album", "discovery"])
    }

    func testAnUninstalledSourceAnswersEmptyOrUnavailable() async throws {
        let youTube = StubCatalog(name: "youtube", tracks: youTubeTracks)
        let composite = CompositeCatalog(youTube: youTube, secondary: [:])
        let awaited8 = try await composite.radio(seed: Track(id: "gaana:1", title: "Song", credits: [])).isEmpty
        XCTAssertTrue(awaited8)
        let lyrics = try await composite.lyrics(for: Track(id: "gaana:1", title: "Song", credits: []))
        XCTAssertEqual(lyrics.kind, .unavailable)
        do {
            _ = try await composite.browse(id: "gaana:album:1")
            XCTFail("Browsing an uninstalled source cannot succeed")
        } catch { XCTAssertTrue(error is MusicServiceError) }
        let page = try await CompositeCatalog.searchingAllSources { try await composite.search(query: "tum", filter: .songs, continuation: nil) }
        XCTAssertEqual(page.tracks.count, 2, "A composite without extra sources is a pass-through")
        let awaited9 = await youTube.calls
        XCTAssertEqual(awaited9, ["search:tum:songs:-"])
    }

    func testThreeSourcesFanOutInMusicSourceOrderAndAFailingOneIsDropped() async throws {
        let (composite, youTube, saavn, gaana) = makeThreeSourceComposite()
        let awaited1 = await composite.activeSources
        XCTAssertEqual(awaited1, [.youTubeMusic, .jioSaavn, .gaana])
        let page = try await CompositeCatalog.searchingAllSources { try await composite.search(query: "tum", filter: .songs, continuation: nil) }
        XCTAssertEqual(page.tracks.map(\.id), ["fsiPzT50ZiM", "NJAv_7lHUIU", "saavn:aRZbUYD7", "saavn:Bt07_OpM", "gaana:944286", "gaana:944317"])
        XCTAssertEqual(page.continuation, "yt-page-2")
        let gaanaCalls = await gaana.calls
        XCTAssertEqual(gaanaCalls, ["search:tum:songs:-"])

        await saavn.configure(error: MusicServiceError.rateLimited)
        let withoutSaavn = try await CompositeCatalog.searchingAllSources { try await composite.search(query: "tum", filter: .songs, continuation: nil) }
        XCTAssertEqual(withoutSaavn.tracks.map(\.id), ["fsiPzT50ZiM", "NJAv_7lHUIU", "gaana:944286", "gaana:944317"], "A failing source drops out alone")
        await saavn.configure()
        await gaana.configure(delay: .seconds(3))
        let withoutGaana = try await CompositeCatalog.searchingAllSources { try await composite.search(query: "tum", filter: .songs, continuation: nil) }
        XCTAssertEqual(withoutGaana.tracks.map(\.id), ["fsiPzT50ZiM", "NJAv_7lHUIU", "saavn:aRZbUYD7", "saavn:Bt07_OpM"], "A slow source is dropped at the deadline")

        await composite.setEnabledSources([.youTubeMusic, .gaana])
        let awaited2 = await composite.activeSources
        XCTAssertEqual(awaited2, [.youTubeMusic, .gaana])
        let youTubeCalls = await youTube.calls.count
        XCTAssertEqual(youTubeCalls, 3)
    }

    func testGaanaIdsRouteToTheGaanaCatalog() async throws {
        let (composite, youTube, saavn, gaana) = makeThreeSourceComposite()
        _ = try await composite.browse(id: "gaana:album:92317")
        _ = try await composite.browse(id: "gaana:playlist:1075124")
        _ = try await composite.artist(id: "gaana:artist:52767")
        _ = try await composite.radio(seed: gaanaTracks[0])
        _ = try await composite.radio(seed: gaanaTracks[1], forceRefresh: true)
        _ = try await composite.recommendations(seed: gaanaTracks[0], language: .hindi)
        _ = try await composite.lyrics(for: gaanaTracks[0])
        _ = try await composite.albumDescription(id: "gaana:album:92317")
        let gaanaCalls = await gaana.calls
        XCTAssertEqual(gaanaCalls, ["browse:gaana:album:92317", "browse:gaana:playlist:1075124", "artist:gaana:artist:52767", "radio:gaana:944286",
                                    "radio:gaana:944317:true", "recommendations:gaana:944286", "lyrics:gaana:944286", "description:gaana:album:92317"])
        let saavnCalls = await saavn.calls
        XCTAssertTrue(saavnCalls.isEmpty)
        let youTubeCalls = await youTube.calls
        XCTAssertTrue(youTubeCalls.isEmpty, "A gaana id never reaches YouTube Music")
        // The real Gaana service has no lyrics hook, so the composite answers unavailable and LRCLIB's result stands.
        let gaanaMock = GaanaTests.mock()
        defer { gaanaMock.close() }
        let plain = CompositeCatalog(youTube: youTube, secondary: [.gaana: GaanaCatalogService(session: gaanaMock.session)])
        let lyrics = try await plain.lyrics(for: gaanaTracks[0])
        XCTAssertEqual(lyrics.kind, .unavailable)
        XCTAssertEqual(lyrics.source, "Gaana")
    }

    // MARK: Stream resolver routing

    func testCompositeResolverRoutesByPrefixAndKeepsCacheWithYouTube() async throws {
        let extracted = CatalogTestRecorder<String>()
        let youTube = YouTubeStreamResolver(timeout: 5, extract: { id, _ in
            extracted.record(id)
            return [URL(string: "https://rr1---sn.googlevideo.com/videoplayback?expire=\(Int(Date().timeIntervalSince1970) + 3_600)&id=\(id)")!]
        }, validate: { _ in })
        let mock = CatalogMockSession { request in
            let call = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "__call" }?.value
            guard call == "song.getDetails" else { throw URLError(.unsupportedURL) }
            let bundle = Bundle(for: CompositeCatalogTests.self)
            let url = try XCTUnwrap(bundle.url(forResource: "saavn-song-details", withExtension: "json")
                ?? bundle.url(forResource: "saavn-song-details", withExtension: "json", subdirectory: "Fixtures"))
            return CatalogStub(data: try Data(contentsOf: url))
        }
        defer { mock.close() }
        let saavn = JioSaavnStreamResolver(catalog: JioSaavnCatalogService(session: mock.session), probe: { _ in })
        let composite = CompositeStreamResolver(youTube: youTube, saavn: saavn)

        let saavnStream = try await composite.resolve(track: Track(id: "saavn:aRZbUYD7", title: "Tum Hi Ho", credits: []), forceRefresh: false)
        XCTAssertEqual(saavnStream.url.host, "aac.saavncdn.com")
        XCTAssertEqual(saavnStream.quality?.bitRate, 320_000)
        XCTAssertTrue(extracted.values.isEmpty, "A saavn id never reaches YouTube extraction")

        let youTubeStream = try await composite.resolve(track: Track(id: "fsiPzT50ZiM", title: "Tum Hi Ho", credits: []), forceRefresh: false)
        XCTAssertEqual(youTubeStream.url.host, "rr1---sn.googlevideo.com")
        XCTAssertEqual(extracted.values, ["fsiPzT50ZiM"])

        let refreshed = try await composite.refreshQuality(track: Track(id: "saavn:aRZbUYD7", title: "Tum Hi Ho", credits: []))
        XCTAssertEqual(refreshed.quality?.bitRate, 320_000)
        XCTAssertEqual(mock.state.requests.count, 2, "A quality refresh asks for fresh song details")

        XCTAssertFalse(composite.isCachedStream(saavnStream))
        XCTAssertTrue(composite is any PlaybackConfigurableResolving)
        XCTAssertTrue(composite is any StreamCacheManaging)
        await composite.setAudioQualityPreference(.dataSaver)
        let capped = try await composite.resolve(track: Track(id: "saavn:aRZbUYD7", title: "Tum Hi Ho", credits: []), forceRefresh: false)
        XCTAssertEqual(capped.quality?.bitRate, 48_000)
        let awaited10 = await youTube.audioQualityPreference
        XCTAssertEqual(awaited10, .dataSaver)

        do {
            _ = try await composite.resolve(track: Track(id: "gaana:944286", title: "Tum Hi Ho", credits: []), forceRefresh: false)
            XCTFail("A composite without a Gaana resolver cannot play gaana ids")
        } catch let error as PlaybackStreamError {
            guard case .invalidID = error else { return XCTFail("Unexpected error \(error)") }
        }
        let gaanaMock = GaanaTests.mock()
        defer { gaanaMock.close() }
        let gaana = GaanaStreamResolver(catalog: GaanaCatalogService(session: gaanaMock.session), probe: { _ in },
                                        now: { Date(timeIntervalSince1970: 1_790_420_000) })
        let full = CompositeStreamResolver(youTube: youTube, saavn: saavn, gaana: gaana)
        let gaanaStream = try await full.resolve(track: Track(id: "gaana:944286", title: "Tum Hi Ho", credits: []), forceRefresh: false)
        XCTAssertEqual(gaanaStream.url.pathExtension, "m3u8")
        XCTAssertEqual(gaanaStream.quality?.bitRate, 128_000)
        XCTAssertFalse(CompositeStreamResolver.isCacheable(gaanaStream), "An HLS playlist is never handed to the file downloader")
        XCTAssertTrue(CompositeStreamResolver.isCacheable(saavnStream))
        await full.setAudioQualityPreference(.dataSaver)
        let cappedGaana = try await full.refreshQuality(track: Track(id: "gaana:944286", title: "Tum Hi Ho", credits: []))
        XCTAssertEqual(cappedGaana.quality?.bitRate, 64_000)
        XCTAssertEqual(extracted.values, ["fsiPzT50ZiM"], "Prefixed ids never reach YouTube extraction")
    }

    /// R12 follow-up: prefixed songs use the shared cache, so a JioSaavn download lands in the inventory and plays offline.
    @MainActor
    func testJioSaavnDownloadsLandInTheSharedCacheAndPlayOffline() async throws {
        let fixture = try CacheManagementFixture()
        addTeardownBlock { try await fixture.close() }
        let connectivity = ConnectivityMonitor(initialStatus: .online, monitorsSystem: false)
        let calls = CatalogTestRecorder<String>()
        let youTube = YouTubeStreamResolver(extract: { _, _ in calls.record("extract"); throw URLError(.notConnectedToInternet) },
                                            validate: { _ in calls.record("validate") }, audioCache: fixture.cache,
                                            isOffline: { connectivity.isOffline })
        let saavnMock = CatalogMockSession { request in
            let call = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "__call" }?.value
            guard call == "song.getDetails" else { throw URLError(.unsupportedURL) }
            let bundle = Bundle(for: CompositeCatalogTests.self)
            let url = try XCTUnwrap(bundle.url(forResource: "saavn-song-details", withExtension: "json")
                ?? bundle.url(forResource: "saavn-song-details", withExtension: "json", subdirectory: "Fixtures"))
            return CatalogStub(data: try Data(contentsOf: url))
        }
        defer { saavnMock.close() }
        let saavn = JioSaavnStreamResolver(catalog: JioSaavnCatalogService(session: saavnMock.session), probe: { _ in calls.record("probe") })
        let composite = CompositeStreamResolver(youTube: youTube, saavn: saavn, audioCache: fixture.cache, isOffline: { connectivity.isOffline })
        let track = Track(id: "saavn:aRZbUYD7", title: "Tum Hi Ho", credits: [ArtistCredit(name: "Arijit Singh")], duration: 262)

        let downloaded = try await composite.download(track)
        XCTAssertTrue(downloaded.url.isFileURL)
        XCTAssertEqual(downloaded.url.deletingLastPathComponent().path, fixture.cache.directory.path)
        XCTAssertEqual(downloaded.url.deletingPathExtension().lastPathComponent, "saavn~aRZbUYD7", "The colon becomes a tilde on disk")
        XCTAssertEqual(AudioCache.logicalTrackID(for: downloaded.url), "saavn:aRZbUYD7")
        XCTAssertTrue(composite.isCachedStream(downloaded))
        XCTAssertEqual(downloaded.quality?.bitRate, 320_000, "The sidecar keeps the tier the download was made from")
        XCTAssertEqual(fixture.mock.state.requests.map { $0.url?.lastPathComponent }, ["5c5ea5cc00e3bff45616013226f376fe_320.mp4"])
        XCTAssertEqual(calls.values, ["probe"], "No YouTube extraction or validation for a saavn id")
        let inventory = try await composite.audioCacheSnapshot()
        let snapshot = try XCTUnwrap(inventory)
        let song = try XCTUnwrap(snapshot.songs.first { $0.id == "saavn:aRZbUYD7" })
        XCTAssertTrue(song.isPlayable)
        XCTAssertEqual(song.track?.title, "Tum Hi Ho")
        let again = try await composite.download(track)
        XCTAssertEqual(again.url, downloaded.url)
        XCTAssertEqual(fixture.mock.state.requests.count, 1, "A second download returns the stored copy")

        connectivity.setStatus(.offline)
        await composite.setNetworkOffline(true)
        let offline = try await composite.resolve(track: track, forceRefresh: true)
        XCTAssertEqual(offline.url, downloaded.url)
        XCTAssertNil(offline.expiresAt)
        XCTAssertEqual(saavnMock.state.requests.count, 1, "Offline playback needs no details call")
        do {
            _ = try await composite.resolve(track: Track(id: "saavn:Bt07_OpM", title: "Tum Se Hi", credits: []), forceRefresh: false)
            XCTFail("An uncached saavn song cannot play offline")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("isn’t cached"))
        }
        let player = PlayerController(resolver: composite)
        defer { player.pause() }
        player.setNetworkOffline(true)
        player.play([track])
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.currentStreamURL == downloaded.url }
        XCTAssertTrue(player.isCurrentTrackCached)
        XCTAssertNil(player.errorMessage)

        do {
            _ = try await youTube.download(track)
            XCTFail("A direct call with a prefixed id belongs to another resolver")
        } catch let error as PlaybackStreamError {
            guard case .invalidID = error else { return XCTFail("Unexpected error \(error)") }
        }
        do {
            _ = try await youTube.resolve(track: Track(id: "gaana:944286", title: "Tum Hi Ho", credits: []), forceRefresh: false)
            XCTFail("A direct call with a prefixed id belongs to another resolver")
        } catch let error as PlaybackStreamError {
            guard case .invalidID = error else { return XCTFail("Unexpected error \(error)") }
        }
    }

    @MainActor
    func testGaanaHLSStreamsSkipTheCacheWhileFallbackFilesAreStored() async throws {
        let fixture = try CacheManagementFixture()
        addTeardownBlock { try await fixture.close() }
        let youTube = YouTubeStreamResolver(extract: { _, _ in throw URLError(.notConnectedToInternet) }, validate: { _ in }, audioCache: fixture.cache)
        let saavnMock = CatalogMockSession { _ in throw URLError(.unsupportedURL) }
        defer { saavnMock.close() }
        let saavn = JioSaavnStreamResolver(catalog: JioSaavnCatalogService(session: saavnMock.session), probe: { _ in })
        let gaanaMock = GaanaTests.mock()
        defer { gaanaMock.close() }
        let own = GaanaStreamResolver(catalog: GaanaCatalogService(session: gaanaMock.session), probe: { _ in },
                                      now: { Date(timeIntervalSince1970: 1_790_420_000) })
        let composite = CompositeStreamResolver(youTube: youTube, saavn: saavn, gaana: own, audioCache: fixture.cache)
        let track = Track(id: "gaana:944286", title: "Tum Hi Ho", credits: [ArtistCredit(name: "Mithoon")], duration: 261)
        do {
            _ = try await composite.download(track)
            XCTFail("An HLS stream cannot be stored as one file")
        } catch let error as MusicServiceError {
            guard case .unavailable = error else { return XCTFail("Unexpected error \(error)") }
        }
        XCTAssertTrue(fixture.mock.state.requests.isEmpty, "No transfer was attempted for the playlist")

        // When Gaana has no stream, the JioSaavn copy is a plain file and is stored under the gaana id.
        let missing = GaanaTests.mock(details: "gaana-song-detail-missing")
        defer { missing.close() }
        let file = ResolvedStream(url: URL(string: "https://aac.saavncdn.com/430/5c5ea5cc00e3bff45616013226f376fe_320.mp4")!, duration: 262,
                                  quality: SourceAudioQuality(codec: .aac, bitRate: 320_000, sampleRate: 44_100, channels: 2))
        let fallback = GaanaStreamResolver(catalog: GaanaCatalogService(session: missing.session),
                                           fallbacks: [FixedFallback(source: .jioSaavn, stream: file)], probe: { _ in })
        let viaSaavn = CompositeStreamResolver(youTube: youTube, saavn: saavn, gaana: fallback, audioCache: fixture.cache)
        let stored = try await viaSaavn.download(track)
        XCTAssertTrue(stored.url.isFileURL)
        XCTAssertEqual(stored.url.deletingPathExtension().lastPathComponent, "gaana~944286")
        XCTAssertEqual(stored.quality?.bitRate, 320_000)
        let inventory = try await viaSaavn.audioCacheSnapshot()
        let snapshot = try XCTUnwrap(inventory)
        XCTAssertTrue(snapshot.songs.contains { $0.id == "gaana:944286" && $0.isPlayable })
    }

    @MainActor
    func testPreferenceChangesReachTheInstalledComposite() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("composite-catalog-tests-\(UUID().uuidString)", isDirectory: true)
        let library = LibraryStore(directory: directory)
        library.preferences.useEncryptedDNS = false
        let (composite, _, saavn) = makeComposite()
        let player = PlayerController(resolver: AppModelStreamResolver())
        defer { player.pause() }
        let model = MusicAppModel(library: library, player: player, catalog: composite, charts: AppModelChartsProvider(),
                                  lyrics: AppModelLyricsProvider(),
                                  account: YouTubeAccountStore(secrets: MemorySecretStore(), registry: YouTubeSessionRegistry()),
                                  connectivity: ConnectivityMonitor(initialStatus: .online, monitorsSystem: false), generatesMixes: false)
        let awaited11 = await composite.activeSources
        XCTAssertEqual(awaited11, [.youTubeMusic, .jioSaavn])
        model.updatePreferences { $0.enabledCatalogSources = [.youTubeMusic] }
        for _ in 0..<50 {
            let active = await composite.activeSources
            guard active.count > 1 else { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let awaited12 = await composite.activeSources
        XCTAssertEqual(awaited12, [.youTubeMusic])
        _ = try await CompositeCatalog.searchingAllSources { try await model.catalog.search(query: "tum", filter: .songs, continuation: nil) }
        let awaited13 = await saavn.calls.isEmpty
        XCTAssertTrue(awaited13, "A switched-off source is not searched")
        model.updatePreferences { $0.enabledCatalogSources = MusicSource.allCases }
        for _ in 0..<50 {
            let active = await composite.activeSources
            guard active.count < 2 else { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let awaited14 = await composite.activeSources
        XCTAssertEqual(awaited14, [.youTubeMusic, .jioSaavn])
    }
}

/// A cross-source stand-in that always answers the same stream.
private struct FixedFallback: CrossSourceStreamFallback {
    let source: MusicSource
    let stream: ResolvedStream
    func resolve(matching track: Track, forceRefresh: Bool) async throws -> ResolvedStream? { stream }
}

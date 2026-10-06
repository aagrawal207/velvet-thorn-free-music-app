import XCTest
@testable import GanaBajana

@MainActor
final class CatalogLiveTests: XCTestCase {
    private func requireLiveTests() throws {
        guard ProcessInfo.processInfo.environment["GANABAJANA_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Set GANABAJANA_LIVE_TESTS=1 to call public YouTube endpoints.")
        }
    }

    func testLiveSearchAllFiltersPaginationAndCollectionBrowse() async throws {
        try requireLiveTests()
        let catalog = YouTubeMusicService()
        for (query, filter) in [("तुम ही हो", SearchFilter.songs), ("Aashiqui 2", .albums),
                                ("Arijit Singh", .artists), ("Bollywood", .playlists)] {
            let page = try await catalog.search(query: query, filter: filter, continuation: nil)
            XCTAssertFalse(filter == .songs ? page.tracks.isEmpty : page.collections.isEmpty, "Empty \(filter.rawValue) response")
            XCTAssertTrue(page.tracks.allSatisfy { $0.isAudioRecording == true })
            if filter == .albums || filter == .artists {
                let collection = try XCTUnwrap(page.collections.first)
                let detail = try await catalog.browse(id: collection.id)
                XCTAssertFalse(detail.tracks.isEmpty && detail.collections.isEmpty)
                XCTAssertTrue(detail.tracks.allSatisfy { CatalogText.videoID($0.id) != nil && $0.artworkURL != nil })
                print("CATALOG LIVE browse \(collection.id): \(detail.tracks.count) tracks, \(detail.collections.count) collections")
            }
            print("CATALOG LIVE search \(filter.rawValue): \(page.tracks.count) tracks, \(page.collections.count) collections")
        }
        let initial = try await catalog.search(query: "Arijit Singh", filter: .songs, continuation: nil)
        let token = try XCTUnwrap(initial.continuation)
        let next = try await catalog.search(query: "Arijit Singh", filter: .songs, continuation: token)
        XCTAssertFalse(next.tracks.isEmpty)
        XCTAssertEqual(Set(next.tracks.map(\.id)).count, next.tracks.count)
        XCTAssertFalse(Set(next.tracks.map(\.id)).subtracting(initial.tracks.map(\.id)).isEmpty)
        let playlist = try await catalog.browse(id: CatalogDiscovery.englishPlaylist)
        XCTAssertFalse(playlist.tracks.isEmpty)
        // Playlist pages list video entries as `false`; Home's editorial selection must still take album audio only.
        XCTAssertTrue(playlist.tracks.allSatisfy { $0.isAudioRecording != nil }, "Every playlist entry is classified")
        XCTAssertTrue(playlist.tracks.contains { $0.isAudioRecording == true })
        XCTAssertTrue(CatalogDiscovery.select(playlist.tracks, language: .english).allSatisfy { $0.isAudioRecording == true })
        print("CATALOG LIVE pagination: \(initial.tracks.count) + \(next.tracks.count); editorial browse: \(playlist.tracks.count) (\(playlist.tracks.filter { $0.isAudioRecording == false }.count) video entries)")
    }

    /// R13 item 9: playlists found through Search must open with their songs. Browses the first three results the
    /// way `CollectionDetailView` does and records each raw page when a browse comes back empty.
    func testLivePlaylistSearchResultsOpenWithTheirSongs() async throws {
        try requireLiveTests()
        let catalog = YouTubeMusicService()
        let page = try await catalog.search(query: "bollywood party", filter: .playlists, continuation: nil)
        XCTAssertGreaterThanOrEqual(page.collections.count, 3, "The playlists filter must return a full first page")
        XCTAssertTrue(page.collections.allSatisfy { $0.kind == .playlist && $0.id.hasPrefix("VL") && $0.tracks.isEmpty },
                      page.collections.map(\.id).description)
        print("CATALOG LIVE 'bollywood party' playlists: \(page.collections.count); \(page.collections.prefix(6).map { "\($0.title) [\($0.id)]" })")
        var empty: [MusicCollection] = []
        for collection in page.collections.prefix(3) {
            let detail = try await catalog.browse(id: collection.id)
            let audio = detail.tracks.filter { $0.isAudioRecording == true }.count
            let video = detail.tracks.filter { $0.isAudioRecording == false }.count
            print("CATALOG LIVE playlist browse \(collection.id) '\(collection.title)': \(detail.tracks.count) tracks (\(audio) audio, \(video) video entries), \(detail.collections.count) collections, title=\(detail.title ?? "-"), continuation=\(detail.continuation == nil ? 0 : 1); \(detail.tracks.prefix(3).map { "\($0.title) by \($0.artistName) [\($0.id)]" })")
            XCTAssertTrue(detail.tracks.allSatisfy { CatalogText.videoID($0.id) != nil && $0.isAudioRecording != nil && $0.artworkURL != nil },
                          "Every listed entry is a classified YouTube recording with artwork")
            XCTAssertEqual(audio + video, detail.tracks.count)
            XCTAssertEqual(Set(detail.tracks.map(\.id)).count, detail.tracks.count)
            if detail.tracks.isEmpty { empty.append(collection) }
        }
        guard !empty.isEmpty else { return }
        // Keep the provider's own words for the regression fixture: the raw page shows which renderer was missed.
        let session = CatalogTransport.anonymousSession()
        defer { session.invalidateAndCancel() }
        let transport = CatalogTransport(session: session, maxCacheBytes: 0, maxCacheEntries: 0)
        let version = try await WebRemixConfiguration(transport: transport).version()
        let directory = FileManager.default.temporaryDirectory.appending(path: "ganabajana-live-playlists", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for collection in empty {
            let response = try await transport.post(baseURL: CatalogTransport.musicURL, endpoint: "browse", body: [
                "browseId": .string(collection.id),
                "context": ["client": ["clientName": "WEB_REMIX", "clientVersion": .string(version), "hl": "en", "gl": "IN"]],
            ], ttl: 0)
            let url = directory.appending(path: "\(collection.id).json")
            try response.json.encoded().write(to: url)
            let shelves = ["musicPlaylistShelfRenderer", "musicShelfRenderer", "musicResponsiveListItemRenderer", "musicTwoRowItemRenderer"]
                .map { "\($0)=\(response.json.values(for: $0).count)" }
            print("CATALOG LIVE playlist raw \(collection.id): \(url.path); contents=\(response.json["contents"].object.keys.sorted()); \(shelves.joined(separator: " "))")
            XCTFail("\(collection.title) [\(collection.id)] opened with no songs; raw page at \(url.path)")
        }
    }

    func testLiveSeedRadioAndHindiEnglishDiscovery() async throws {
        try requireLiveTests()
        let catalog = YouTubeMusicService()
        for language in MusicLanguage.allCases {
            let tracks = try await catalog.recommendations(seed: CatalogDiscovery.starters(for: language)[0], language: language)
            XCTAssertFalse(tracks.isEmpty)
            XCTAssertEqual(Set(tracks.map(\.id)).count, tracks.count)
            XCTAssertTrue(tracks.allSatisfy { $0.language == nil || $0.language == language })
            XCTAssertTrue(tracks.allSatisfy { $0.isAudioRecording == true })
            print("CATALOG LIVE \(language.rawValue) radio: \(tracks.count); \(tracks.prefix(3).map(\.title))")
        }
        let sections = try await catalog.discovery(languages: [.hindi, .english])
        XCTAssertEqual(Set(sections.compactMap(\.language)), [.hindi, .english])
        XCTAssertTrue(sections.allSatisfy { !$0.tracks.isEmpty || !$0.collections.isEmpty })
        XCTAssertFalse(sections.contains { $0.id.hasPrefix("starter-") }, "Live discovery unexpectedly needed the editorial fallback")
        print("CATALOG LIVE discovery: \(sections.map { "\($0.id)=\($0.tracks.count)" })")
    }

    func testLiveArtistInitialsSearchLeadsWithTheArtistNotQuranRecitations() async throws {
        try requireLiveTests()
        let page = try await YouTubeMusicService().search(query: "A. R. RAHMAN", filter: .songs, continuation: nil)
        let leading = Array(page.tracks.prefix(8))
        XCTAssertEqual(leading.count, 8)
        for track in leading {
            XCTAssertTrue(track.artists.contains { $0.localizedCaseInsensitiveContains("Rahman") }, "\(track.title) by \(track.artistName)")
            XCTAssertFalse(["al rahman", "surah ar rahman", "sura ar rahman"].contains(SearchRelevance.normalize(track.title)), track.title)
            XCTAssertEqual(track.isAudioRecording, true)
        }
        XCTAssertEqual(page.featuredArtist?.id, "UCtJe0RYzgPddQXKtWduxz_w")
        XCTAssertTrue(page.tracks.allSatisfy { $0.artworkURL?.host?.hasSuffix("googleusercontent.com") == true
            ? $0.artworkURL?.absoluteString.contains("=w544-h544") == true : $0.artworkURL != nil })
        print("CATALOG LIVE 'A. R. RAHMAN': featured=\(page.featuredArtist?.title ?? "none") [\(page.featuredArtist?.id ?? "-")], \(page.tracks.count) tracks")
        for (index, track) in leading.enumerated() {
            print("CATALOG LIVE 'A. R. RAHMAN' #\(index + 1): \(track.title) — \(track.artistName) [\(track.id)]")
        }
    }

    func testLiveMisspelledArtistSearchStillReturnsSongsAndResolvesTheArtist() async throws {
        try requireLiveTests()
        let catalog = YouTubeMusicService()
        let page = try await catalog.search(query: "Arjit Singh", filter: .songs, continuation: nil)
        XCTAssertFalse(page.tracks.isEmpty)
        XCTAssertEqual(page.featuredArtist?.title, "Arijit Singh")
        XCTAssertEqual(page.featuredArtist?.id, CatalogFixtures.arijitID)
        XCTAssertEqual(page.correctedQuery?.lowercased(), "arijit singh")
        XCTAssertTrue(page.tracks.allSatisfy { $0.isAudioRecording == true })
        XCTAssertTrue(page.tracks.prefix(8).allSatisfy { $0.artistID == CatalogFixtures.arijitID || $0.artists.contains("Arijit Singh") })
        print("CATALOG LIVE 'Arjit Singh': \(page.tracks.count) tracks, featured=\(page.featuredArtist?.title ?? "none"), corrected=\(page.correctedQuery ?? "none"); \(page.tracks.prefix(5).map { "\($0.title) — \($0.artistName)" })")
        let token = try XCTUnwrap(page.continuation)
        let next = try await catalog.search(query: "Arjit Singh", filter: .songs, continuation: token)
        XCTAssertEqual(next.featuredArtist?.id, CatalogFixtures.arijitID)
        XCTAssertFalse(Set(next.tracks.map(\.id)).subtracting(page.tracks.map(\.id)).isEmpty)
        print("CATALOG LIVE 'Arjit Singh' page 2: \(next.tracks.count) tracks")
    }

    func testLiveSongTitleSearchKeepsTheStudioRecordingUpFront() async throws {
        try requireLiveTests()
        let page = try await YouTubeMusicService().search(query: "Tum Hi Ho", filter: .songs, continuation: nil)
        XCTAssertTrue(page.tracks.prefix(3).contains { $0.id == CatalogFixtures.hindiID }, page.tracks.prefix(3).map(\.id).description)
        XCTAssertNil(page.featuredArtist, "A song title must not resolve to an artist")
        print("CATALOG LIVE 'Tum Hi Ho': \(page.tracks.prefix(3).map { "\($0.title) — \($0.artistName) [\($0.id)]" })")
    }

    func testLiveSongSearchRowsCarryPlayCounts() async throws {
        try requireLiveTests()
        let page = try await YouTubeMusicService().search(query: "Tum Hi Ho", filter: .songs, continuation: nil)
        XCTAssertFalse(page.tracks.isEmpty)
        for track in page.tracks.prefix(3) {
            let raw = track.playCount.map { String($0) } ?? "nil"
            let shown = PlayCountText.plays(track.playCount) ?? "-"
            print("CATALOG LIVE 'Tum Hi Ho' plays: \(track.title) — \(track.artistName) [\(track.id)] playCount=\(raw) shown=\(shown)")
        }
        let counted = page.tracks.filter { $0.playCount != nil }
        guard !counted.isEmpty else {
            throw XCTSkip("YouTube Music sent no play counts in \(page.tracks.count) song rows for 'Tum Hi Ho'; the parser has nothing to read.")
        }
        XCTAssertTrue(counted.allSatisfy { ($0.playCount ?? 0) > 0 }, "Parsed counts are positive")
        XCTAssertTrue(page.tracks.prefix(3).contains { $0.playCount != nil }, "The leading results carry counts")
    }

    func testLiveArtistPageHasHeaderIdentityReleasesAndRelatedArtists() async throws {
        try requireLiveTests()
        let artist = try await YouTubeMusicService().artist(id: CatalogFixtures.arijitID)
        XCTAssertEqual(artist.name, "Arijit Singh")
        XCTAssertEqual(artist.artworkURL?.absoluteString.contains("=w544-h544"), true)
        XCTAssertFalse(artist.topSongs.isEmpty)
        XCTAssertTrue(artist.topSongs.allSatisfy { $0.isAudioRecording == true && $0.duration != nil })
        XCTAssertFalse(artist.releases.isEmpty)
        XCTAssertTrue(artist.releases.allSatisfy { $0.kind == .album })
        XCTAssertFalse(artist.relatedArtists.isEmpty)
        XCTAssertTrue(artist.relatedArtists.allSatisfy { $0.kind == .artist })
        print("CATALOG LIVE artist: \(artist.name); \(artist.topSongs.count) top songs, \(artist.releases.count) releases (\(artist.releases.prefix(2).map(\.subtitle))), \(artist.relatedArtists.count) related; art=\(artist.artworkURL?.absoluteString ?? "-")")
        print("CATALOG MONTHLY LIVE service: \(artist.name); label=\(artist.monthlyAudience?.label ?? "unavailable"); source=\(artist.monthlyAudience?.source.rawValue ?? "unavailable"); lifetimeSongCounts=\(artist.topSongs.compactMap(\.playCount).count)")
    }

    func testLiveArtistMonthlyAudienceMatchesProviderHeader() async throws {
        try requireLiveTests()
        let session = CatalogTransport.anonymousSession()
        defer { session.invalidateAndCancel() }
        let transport = CatalogTransport(session: session, maxCacheBytes: 0, maxCacheEntries: 0)
        let configuration = WebRemixConfiguration(transport: transport)
        let version = try await configuration.version()
        var observed = 0
        for id in [ArtistSpotlightMonthlyAudienceFixtures.artistID, CatalogFixtures.arijitID] {
            let response = try await transport.post(baseURL: CatalogTransport.musicURL, endpoint: "browse", body: [
                "browseId": .string(id),
                "context": ["client": ["clientName": "WEB_REMIX", "clientVersion": .string(version), "hl": "en", "gl": "IN"]],
            ], ttl: 0)
            let header = CatalogParser.artistHeaderRenderer(response.json)
            let raw = header["monthlyListenerCount"].text
            let description = response.json["microformat"]["microformatDataRenderer"]["description"].text
            let subscriberText = header["subscriptionButton"]["subscribeButtonRenderer"]["longSubscriberCountText"].text
            let parsed = CatalogParser.artistHeader(response.json)
            print("CATALOG MONTHLY LIVE probe: id=\(id); client=\(version); fetchedAt=\(response.fetchedAt); rootHeaderRenderers=\(response.json["header"].object.keys.sorted()); headerKeys=\(header.object.keys.sorted()); monthlyListenerCount=\(raw); pageDescription=\(description); subscribers=\(subscriberText); parsed=\(parsed.monthlyAudience?.label ?? "unavailable")")
            XCTAssertNotNil(parsed.name)
            if raw.localizedCaseInsensitiveContains("monthly") {
                let audience = try XCTUnwrap(parsed.monthlyAudience, "A labelled provider statistic must not silently disappear")
                XCTAssertEqual(audience.label, raw.trimmingCharacters(in: .whitespacesAndNewlines))
                XCTAssertEqual(audience.source, .headerCount)
                XCTAssertGreaterThanOrEqual(audience.value, 0)
                XCTAssertEqual(audience.kind, raw.localizedCaseInsensitiveContains("audience") ? .audience : .listeners)
                observed += 1
            } else if let audience = parsed.monthlyAudience {
                XCTAssertNotEqual(audience.source, .headerCount)
                XCTAssertTrue(audience.label.localizedCaseInsensitiveContains("monthly"))
                XCTAssertFalse(audience.label.localizedCaseInsensitiveContains("subscrib"))
                observed += 1
            } else {
                XCTAssertFalse(description.localizedCaseInsensitiveContains("monthly"), "Inspect the probe metadata for a changed description contract")
            }
        }
        if observed == 0 { throw XCTSkip("The provider omitted monthly audience labels for both probe artists; missing values remain unavailable.") }
    }

    func testLiveAlbumHeaderAndSongRowsCarryLinkedCredits() async throws {
        try requireLiveTests()
        let catalog = YouTubeMusicService()
        let album = try await catalog.browse(id: CatalogFixtures.graduationID)
        XCTAssertEqual(album.title, "Graduation")
        XCTAssertTrue(album.credits.contains { $0.name == "Kanye West" && $0.id != nil }, "Album credits: \(album.credits)")
        XCTAssertFalse(album.tracks.isEmpty)
        for track in album.tracks {
            XCTAssertFalse(track.credits.isEmpty, "\(track.title) [\(track.id)] has no credit")
            XCTAssertNotEqual(track.artistName, "Unknown artist", track.title)
        }
        print("CATALOG LIVE album \(CatalogFixtures.graduationID): credits=\(album.credits.map { "\($0.name) [\($0.id ?? "-")]" }); \(album.tracks.prefix(3).map { "\($0.title) — \($0.artistName)" })")

        let search = try await catalog.search(query: "Kesariya", filter: .songs, continuation: nil)
        let first = try XCTUnwrap(search.tracks.first)
        XCTAssertTrue(first.credits.contains { $0.id != nil }, "\(first.title): \(first.credits)")
        print("CATALOG LIVE 'Kesariya' #1: \(first.title) — \(first.credits.map { "\($0.name) [\($0.id ?? "-")]" })")
    }

    func testLiveRadioFollowsTheSeedsNeighborsAndSkipsItsOwnVersions() async throws {
        try requireLiveTests()
        let seed = Track(id: "W3_c4-4OMbM", title: "Six Days (Remix) (feat. Mos Def)", credits: [ArtistCredit(name: "DJ Shadow")], language: .english)
        let tracks = try await YouTubeMusicService().radio(seed: seed)
        XCTAssertGreaterThanOrEqual(tracks.count, 10)
        XCTAssertFalse(tracks.contains { $0.id == seed.id })
        XCTAssertEqual(Set(tracks.map(\.id)).count, tracks.count)
        XCTAssertTrue(tracks.allSatisfy { $0.isAudioRecording == true })
        XCTAssertFalse(tracks.contains { CatalogDiscovery.isUnwantedVersion($0.title) })
        for track in tracks {
            XCTAssertNotEqual(SongTitle.core(track.title), "six days", "\(track.title) by \(track.artistName) is a version of the seed")
        }
        print("CATALOG LIVE radio 'Six Days (Remix)': \(tracks.count) tracks; \(tracks.prefix(6).map { "\($0.title) — \($0.artistName)" })")
    }

    func testLiveHindiAndEnglishWeeklySongPicksHaveATVsDatesRanksAndAlbumArtwork() async throws {
        try requireLiveTests()
        let service = YouTubeChartsService()
        for language in MusicLanguage.allCases {
        let started = Date()
        let chart = try await service.weeklyChart(language: language)
        XCTAssertFalse(chart.entries.isEmpty)
        XCTAssertEqual(chart.language, language)
        XCTAssertNotNil(chart.periodStart)
        XCTAssertNotNil(chart.periodEnd)
        XCTAssertEqual(chart.entries.map(\.rank), chart.entries.map(\.rank).sorted())
        XCTAssertEqual(Set(chart.entries.map(\.id)).count, chart.entries.count)
        XCTAssertTrue(chart.entries.allSatisfy { CatalogText.videoID($0.track.id) != nil && $0.track.artworkURL != nil })
        XCTAssertTrue(chart.entries.allSatisfy { $0.track.isAudioRecording == true })
        XCTAssertEqual(chart.source, "YouTube Charts · Weekly songs · selected for you")
        XCTAssertTrue(chart.entries.contains { ($0.views ?? 0) > 0 })
        let entry = try XCTUnwrap(chart.entries.first)
        var request = URLRequest(url: try XCTUnwrap(entry.track.artworkURL))
        request.httpMethod = "HEAD"
        request.httpShouldHandleCookies = false
        let (_, response) = try await CatalogTransport.anonymousSession().data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        print("CATALOG LIVE \(language.rawValue) weekly song picks: \(chart.entries.count), \(String(format: "%.2f", Date().timeIntervalSince(started)))s; \(chart.subtitle); \(chart.entries.prefix(3).map { "#\($0.rank) \($0.track.title) [\($0.track.id)]" }); artwork HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
    }
}

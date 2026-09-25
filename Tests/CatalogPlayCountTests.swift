import XCTest
@testable import GanaBajana

final class CatalogPlayCountTests: XCTestCase {
    func testCountFieldsJoinRunsAndReadSimpleTextLiteralAndAccessibilityLabels() throws {
        let labels: [Any] = [
            ["runs": [["text": "1.2"], ["text": " billion "], ["text": "plays"]]],
            ["simpleText": "1.2 billion plays"], "1.2B plays",
            ["accessibility": ["accessibilityData": ["label": "1.2 billion plays"]]],
        ]
        for label in labels {
            var row = CatalogFixtures.song(plays: nil)["musicResponsiveListItemRenderer"] as! [String: Any]
            var columns = row["flexColumns"] as! [[String: Any]]
            columns.append(["musicResponsiveListItemFlexColumnRenderer": ["text": label]])
            row["flexColumns"] = columns
            let root = try CatalogFixtures.json(CatalogFixtures.search([["musicResponsiveListItemRenderer": row]]))
            XCTAssertEqual(try CatalogParser.search(root, filter: .songs).tracks.first?.playCount, 1_200_000_000)
        }
    }

    func testLinkedNamesAndReportingPeriodsCannotBecomeSongTotals() throws {
        let root = try CatalogFixtures.json(CatalogFixtures.search([
            CatalogFixtures.song(artist: "2 plays", album: "3 plays", plays: "173 million plays"),
        ]))
        XCTAssertEqual(try CatalogParser.search(root, filter: .songs).tracks.first?.playCount, 173_000_000)
        for label in ["200,574,245 views", "16,321,798 weekly plays", "665M monthly audience", "12M monthly listeners"] {
            let row = try CatalogFixtures.json(CatalogFixtures.search([CatalogFixtures.song(plays: label)]))
            XCTAssertNil(try CatalogParser.search(row, filter: .songs).tracks.first?.playCount, label)
        }
    }

    func testValidatedAlbumCreditsRecoverTheProviderSongTotal() throws {
        let root = try CatalogFixtures.json(CatalogFixtures.browse([CatalogPlayCountFixtures.linkedRow()]))
        XCTAssertTrue(try CatalogParser.browse(root, id: CatalogFixtures.albumID).tracks.isEmpty,
                      "A count must not make an unvalidated video playable")
        let audio = try CatalogParser.queue(CatalogFixtures.json(CatalogPlayCountFixtures.queue()))
        XCTAssertNil(audio.first?.playCount, "The real get_queue byline has no count")
        let recovered = CatalogParser.enrichPlayCounts(audio, from: root)
        XCTAssertEqual(recovered.first?.id, CatalogFixtures.hindiID)
        XCTAssertEqual(recovered.first?.playCount, 1_200_000_000)
        XCTAssertEqual(recovered.first?.duration, 262)
        XCTAssertEqual(recovered.first?.credits, audio.first?.credits)
    }

    func testLinkedCountRequiresConfirmedIdentityTitleAndArtist() throws {
        let root = try CatalogFixtures.json(CatalogFixtures.browse([CatalogPlayCountFixtures.linkedRow()]))
        let audio = try XCTUnwrap(CatalogParser.queue(CatalogFixtures.json(CatalogPlayCountFixtures.queue())).first)
        var otherID = audio
        otherID.id = "BjL7AuPsmEk"
        var unconfirmed = audio
        unconfirmed.isAudioRecording = nil
        var live = audio
        live.title = "Tum Hi Ho (Live)"
        var wrongArtist = audio
        wrongArtist.credits = [ArtistCredit(name: "Arijit Singh", id: "UCdifferent")]
        for candidate in [otherID, unconfirmed, live, wrongArtist] {
            XCTAssertNil(CatalogParser.enrichPlayCounts([candidate], from: root).first?.playCount)
        }
        for row in [CatalogPlayCountFixtures.linkedRow(label: "200,574,245 views"),
                    CatalogPlayCountFixtures.linkedRow(creditIDs: []),
                    CatalogPlayCountFixtures.linkedRow(creditIDs: [CatalogFixtures.hindiID, "BjL7AuPsmEk"])] {
            let source = try CatalogFixtures.json(CatalogFixtures.browse([row]))
            XCTAssertNil(CatalogParser.enrichPlayCounts([audio], from: source).first?.playCount)
        }
    }

    func testProviderTotalsAreNeitherSummedNorCopiedToUnlinkedReleases() throws {
        let source = try CatalogFixtures.json(CatalogFixtures.search([CatalogFixtures.song()]))
        var other = Track(id: "BjL7AuPsmEk", title: "Tum Hi Ho", artists: ["Arijit Singh"], isAudioRecording: true)
        XCTAssertNil(CatalogParser.enrichPlayCounts([other], from: source).first?.playCount)
        other.playCount = 1_200_000_000
        let original = try XCTUnwrap(CatalogParser.search(source, filter: .songs).tracks.first)
        let artist = ArtistPage(id: CatalogFixtures.arijitID, name: "Arijit Singh")
        XCTAssertNil(ArtistSpotlight.matchingCount(for: original, in: [other], artist: artist))
        XCTAssertEqual(ArtistSpotlight.sorted([original, original, other]).map(\.playCount), [1_200_000_000, 1_200_000_000])
    }

    func testWeeklyChartViewsStayInTheReportingPeriod() throws {
        let root = try CatalogFixtures.json(CatalogFixtures.chart([CatalogFixtures.chartRow()]))
        let chart = try CatalogChartParser.parseSongChart(root, language: .hindi, region: "in", fetchedAt: Date())
        XCTAssertEqual(chart.entries.first?.views, 16_321_798)
        XCTAssertNil(chart.entries.first?.track.playCount)
        XCTAssertEqual(chart.periodEnd, CatalogChartParser.date("2026-09-10"))
    }
}

@MainActor
final class CatalogPlayCountServiceTests: XCTestCase {
    func testAlbumAndArtistRescueCarryTotalsThroughOneExistingAudioBatch() async throws {
        for isArtist in [false, true] {
            let row = CatalogPlayCountFixtures.linkedRow()
            let source = isArtist ? CatalogFixtures.artistPage(songs: [row]) : CatalogFixtures.browse([row])
            let browse = try CatalogFixtures.data(source)
            let queue = try CatalogFixtures.data(CatalogPlayCountFixtures.queue())
            let mock = CatalogMockSession { request in
                if request.httpMethod == "GET" { return CatalogStub(data: CatalogFixtures.bootstrap) }
                return CatalogStub(data: request.url?.path.hasSuffix("/music/get_queue") == true ? queue : browse)
            }
            defer { mock.close() }
            let service = YouTubeMusicService(session: mock.session)
            let tracks: [Track]
            if isArtist { tracks = try await service.artist(id: CatalogFixtures.arijitID).topSongs }
            else { tracks = try await service.browse(id: CatalogFixtures.albumID).tracks }
            XCTAssertEqual(tracks.map(\.id), [CatalogFixtures.hindiID])
            XCTAssertEqual(tracks.map(\.playCount), [1_200_000_000])
            let requests = mock.state.requests.filter { $0.url?.path.hasSuffix("/music/get_queue") == true }
            XCTAssertEqual(requests.count, 1)
            let body = try CatalogJSON.decode(XCTUnwrap(requests.first?.httpBody))
            XCTAssertEqual(body["videoIds"].array.compactMap(\.string), [CatalogFixtures.hindiID])
        }
    }

    func testSearchRescueKeepsItsOwnCountInsteadOfCachedQueueMetadata() async throws {
        var router = CatalogMockRouter()
        router.songs["Tum Hi Ho"] = try CatalogFixtures.data(CatalogFixtures.search([CatalogFixtures.song(confirmed: false)]))
        router.queue = { _ in try CatalogFixtures.data(CatalogPlayCountFixtures.queue(label: "845K plays")) }
        let mock = CatalogMockSession { [router] request in try router.stub(request) }
        defer { mock.close() }
        let page = try await YouTubeMusicService(session: mock.session).search(query: "Tum Hi Ho", filter: .songs, continuation: nil)
        XCTAssertEqual(page.tracks.first?.playCount, 1_200_000_000)
        XCTAssertEqual(mock.state.requests.filter { $0.url?.path.hasSuffix("/music/get_queue") == true }.count, 1)
    }

    func testBrowseCountRefreshUsesPageExpiryAndReusesTheAudioMetadataBatch() async throws {
        let clock = CatalogTestClock()
        let browseCount = CatalogTestCounter()
        let first = try CatalogFixtures.data(CatalogFixtures.browse([CatalogPlayCountFixtures.linkedRow()]))
        let refreshed = try CatalogFixtures.data(CatalogFixtures.browse([CatalogPlayCountFixtures.linkedRow(label: "1.3B plays")]))
        let queue = try CatalogFixtures.data(CatalogPlayCountFixtures.queue())
        let mock = CatalogMockSession { request in
            if request.httpMethod == "GET" { return CatalogStub(data: CatalogFixtures.bootstrap) }
            if request.url?.path.hasSuffix("/music/get_queue") == true { return CatalogStub(data: queue) }
            return CatalogStub(data: browseCount.increment() == 1 ? first : refreshed)
        }
        defer { mock.close() }
        let service = YouTubeMusicService(session: mock.session, now: { clock.now })
        let initial = try await service.browse(id: CatalogFixtures.albumID)
        XCTAssertEqual(initial.tracks.first?.playCount, 1_200_000_000)
        clock.advance(599)
        let cached = try await service.browse(id: CatalogFixtures.albumID)
        XCTAssertEqual(cached.tracks.first?.playCount, 1_200_000_000)
        clock.advance(2)
        let fresh = try await service.browse(id: CatalogFixtures.albumID)
        XCTAssertEqual(fresh.tracks.first?.playCount, 1_300_000_000)
        XCTAssertEqual(mock.state.requests.filter { $0.url?.path.hasSuffix("/browse") == true }.count, 2)
        XCTAssertEqual(mock.state.requests.filter { $0.url?.path.hasSuffix("/music/get_queue") == true }.count, 1)
    }

    func testQueueViewsCannotFillMissingSongTotals() async throws {
        var router = CatalogMockRouter()
        router.browse[CatalogFixtures.albumID] = try CatalogFixtures.data(CatalogFixtures.browse([
            CatalogFixtures.albumSong(duration: nil, plays: nil),
        ]))
        router.queue = { _ in try CatalogFixtures.data(CatalogPlayCountFixtures.queue(label: "200,574,245 views")) }
        let mock = CatalogMockSession { [router] request in try router.stub(request) }
        defer { mock.close() }
        let page = try await YouTubeMusicService(session: mock.session).browse(id: CatalogFixtures.albumID)
        XCTAssertNil(page.tracks.first?.playCount)
        XCTAssertEqual(page.tracks.first?.duration, 262)
    }
}

private enum CatalogPlayCountFixtures {
    // The album row and linked queue metadata preserve the provider's distinct song and recording identities.
    static func linkedRow(label: String = "1.2B plays", creditIDs: [String] = [CatalogFixtures.hindiID]) -> [String: Any] {
        let clipID = "NUo8CKI34o4"
        return ["musicResponsiveListItemRenderer": [
            "playlistItemData": ["videoId": clipID],
            "flexColumns": [
                ["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [[
                    "text": "Tum Hi Ho", "navigationEndpoint": ["watchEndpoint": CatalogFixtures.watch(clipID, type: "MUSIC_VIDEO_TYPE_OMV")],
                ]]]]],
                ["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": CatalogFixtures.artistRuns([("Arijit Singh", CatalogFixtures.arijitID)])]]],
                ["musicResponsiveListItemFlexColumnRenderer": ["text": CatalogFixtures.text(label)]],
            ],
            "fixedColumns": [["musicResponsiveListItemFixedColumnRenderer": ["text": CatalogFixtures.text("4:22")]]],
            "menu": ["items": creditIDs.map { id in
                ["navigationEndpoint": CatalogFixtures.browseRun("Credits", id: "MPTC" + id, type: "MUSIC_PAGE_TYPE_TRACK_CREDITS")["navigationEndpoint"]!]
            }],
        ]]
    }

    static func queue(label: String? = nil) -> [String: Any] {
        CatalogFixtures.queue([CatalogFixtures.radioTrack(id: CatalogFixtures.hindiID, title: "Tum Hi Ho",
            artist: "Arijit Singh", album: "Aashiqui 2", views: label, duration: "4:22")])
    }
}

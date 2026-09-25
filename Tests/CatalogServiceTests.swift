import XCTest
@testable import GanaBajana

@MainActor
final class CatalogServiceTests: XCTestCase {
    private let songsParams = YouTubeMusicService.searchParameters(.songs)
    private let artistsParams = YouTubeMusicService.searchParameters(.artists)
    private let correction = CatalogFixtures.showingResultsFor(original: "Arjit Singh", corrected: "Arijit Singh")

    private func requests(_ mock: CatalogMockSession, path: String, containing marker: String? = nil) -> [CatalogJSON] {
        mock.state.requests.filter { $0.httpMethod == "POST" && $0.url?.path.hasSuffix(path) == true }
            .compactMap { try? CatalogJSON.decode($0.httpBody ?? Data()) }
            .filter { body in marker == nil || body["params"].string == marker }
    }

    private nonisolated static func queueStub(_ ids: [String], audio: @escaping @Sendable (String) -> Bool = { _ in true }) throws -> Data {
        try CatalogFixtures.data(CatalogFixtures.queue(ids.map { id in
            CatalogFixtures.radioTrack(id: id, title: "Queue \(id)", artist: "Arijit Singh",
                                       type: audio(id) ? "MUSIC_VIDEO_TYPE_ATV" : "MUSIC_VIDEO_TYPE_OMV",
                                       album: "Aashiqui 2", thumbnail: CatalogFixtures.googleArtwork(id))
        }))
    }

    func testUnconfirmedSongRowsAreRestoredThroughOneGetQueueBatchInProviderOrder() async throws {
        var router = CatalogMockRouter()
        router.songs["Arjit Singh"] = try CatalogFixtures.data(CatalogFixtures.search([
            CatalogFixtures.song(id: "FOA9iyxsW_A", title: "Agar Tum Saath Ho", confirmed: false),
            CatalogFixtures.song(confirmed: false),
            CatalogFixtures.song(id: CatalogFixtures.englishID, title: "Blinding Lights", artist: "The Weeknd", confirmed: false),
        ], continuation: "songs-page-2", correction: correction))
        router.continuations["songs-page-2"] = try CatalogFixtures.data(CatalogFixtures.search([
            CatalogFixtures.song(id: "wx89ZdkwtS8", title: "Ae Dil Hai Mushkil", confirmed: false),
        ], continued: true))
        router.queue = { ids in try Self.queueStub(ids, audio: { $0 != CatalogFixtures.englishID }) }
        let mock = CatalogMockSession { [router] request in try router.stub(request) }
        defer { mock.close() }
        let service = YouTubeMusicService(session: mock.session)

        let page = try await service.search(query: "Arjit Singh", filter: .songs, continuation: nil)
        XCTAssertEqual(page.tracks.map(\.id), ["FOA9iyxsW_A", CatalogFixtures.hindiID], "Only rows get_queue confirms as album audio return, in provider order")
        XCTAssertTrue(page.tracks.allSatisfy { $0.isAudioRecording == true })
        XCTAssertEqual(page.tracks.first?.artworkURL?.absoluteString, "https://yt3.googleusercontent.com/FOA9iyxsW_A=w544-h544-l90-rj")
        XCTAssertEqual(page.tracks.first?.albumTitle, "Aashiqui 2")
        XCTAssertEqual(page.correctedQuery, "Arijit Singh")
        XCTAssertNil(page.featuredArtist)
        let queues = requests(mock, path: "/music/get_queue")
        XCTAssertEqual(queues.count, 1)
        XCTAssertEqual(queues.first?["videoIds"].array.compactMap(\.string), ["FOA9iyxsW_A", CatalogFixtures.hindiID, CatalogFixtures.englishID])

        let next = try await service.search(query: "Arjit Singh", filter: .songs, continuation: try XCTUnwrap(page.continuation))
        XCTAssertEqual(next.tracks.map(\.id), ["wx89ZdkwtS8"])
        XCTAssertEqual(next.correctedQuery, "Arijit Singh", "The first page's correction rides along in the cursor")
        XCTAssertEqual(requests(mock, path: "/music/get_queue").count, 2)
        XCTAssertEqual(requests(mock, path: "/search", containing: artistsParams).count, 1, "Continuation pages do not repeat the artist lookup")
    }

    func testArtistNamedQueryFeaturesTheArtistAndLeadsWithItsTopSongs() async throws {
        var router = CatalogMockRouter()
        router.songs["Arjit Singh"] = try CatalogFixtures.data(CatalogFixtures.search([
            CatalogFixtures.song(id: "B0p-iL_WbcA", title: "Phir Le Aya Dil"),
            CatalogFixtures.song(id: "OaiOf0-kISM", title: "Al Rahman", artist: "Abdel Rahman el Ousi", artistID: "UC1CwoEojJpBZw8gnaZUhMVQ"),
            CatalogFixtures.song(id: "NJAv_7lHUIU", title: "Kesariya"),
            CatalogFixtures.song(id: "Z0VbANbyH2o", title: "Tere Hawaale", artist: "Pritam", artistID: "UCCTN01plFzn4npREHKT2_9Q"),
        ], continuation: "arijit-page-2", correction: correction))
        router.continuations["arijit-page-2"] = try CatalogFixtures.data(CatalogFixtures.search([
            CatalogFixtures.song(id: "q1uPPBJ2tcI", title: "Phir Bhi Tumko Chaahunga"),
            CatalogFixtures.song(id: "3XU3mFXMuZU", title: "Kehna Hi Kya", artist: "Chitra", artistID: "UCh0zJwEvcK-T-SZXJUQbDGg"),
        ], continued: true))
        router.artists["Arjit Singh"] = try CatalogFixtures.data(CatalogFixtures.search([
            CatalogFixtures.artistRow(id: "UCVGomUS__PL0c4jDXa0QwXA", name: "Atif Aslam"), CatalogFixtures.artistRow(),
        ], correction: correction))
        router.browse[CatalogFixtures.arijitID] = try CatalogFixtures.data(CatalogFixtures.artistPage(songs: [
            CatalogFixtures.song(id: "i1o1p_DD6TU", title: "Gehra Hua"), CatalogFixtures.song(id: "NJAv_7lHUIU", title: "Kesariya"),
        ]))
        let mock = CatalogMockSession { [router] request in try router.stub(request) }
        defer { mock.close() }
        let service = YouTubeMusicService(session: mock.session)

        let page = try await service.search(query: "Arjit Singh", filter: .songs, continuation: nil)
        XCTAssertEqual(page.featuredArtist?.id, CatalogFixtures.arijitID)
        XCTAssertEqual(page.featuredArtist?.title, "Arijit Singh")
        XCTAssertEqual(page.featuredArtist?.artworkURL?.absoluteString, "https://yt3.googleusercontent.com/ArtistmPoQ=w544-h544-p-l90-rj")
        XCTAssertEqual(page.tracks.map(\.id), ["i1o1p_DD6TU", "NJAv_7lHUIU", "B0p-iL_WbcA"],
                       "Top songs lead once, then the artist's own search rows; rows sharing nothing with the query are gone")
        XCTAssertEqual(page.correctedQuery, "Arijit Singh")
        XCTAssertEqual(requests(mock, path: "/browse").count, 1)
        XCTAssertEqual(requests(mock, path: "/search", containing: artistsParams).map { $0["query"].string }, ["Arjit Singh"])
        XCTAssertTrue(requests(mock, path: "/music/get_queue").isEmpty, "Confirmed rows need no validation")

        let next = try await service.search(query: "Arjit Singh", filter: .songs, continuation: try XCTUnwrap(page.continuation))
        XCTAssertEqual(next.tracks.map(\.id), ["q1uPPBJ2tcI"], "Continuation pages apply the same artist filter")
        XCTAssertEqual(next.featuredArtist?.id, CatalogFixtures.arijitID)
        XCTAssertEqual(requests(mock, path: "/browse").count, 1)
        XCTAssertEqual(requests(mock, path: "/search", containing: artistsParams).count, 1)
    }

    func testSongTitledQueryIsNotHijackedByAnArtistSharingItsName() async throws {
        var router = CatalogMockRouter()
        router.songs["Tum Hi Ho"] = try CatalogFixtures.data(CatalogFixtures.search([
            CatalogFixtures.song(),
            CatalogFixtures.song(id: "Des4vM1U7MA", title: "Meri Aashiqui", artist: "Palak Muchhal", artistID: "UCE2Nm1Ep8Dz4vwnOc6xXqBQ"),
            CatalogFixtures.song(id: "BjL7AuPsmEk", title: "Tum Hi Ho", album: "Greatest Hits 3"),
            CatalogFixtures.song(id: "j4WUfUDn5hc", title: "Bakhuda Tumhi Ho", artist: "Atif Aslam", artistID: "UCVGomUS__PL0c4jDXa0QwXA"),
        ]))
        router.artists["Tum Hi Ho"] = try CatalogFixtures.data(CatalogFixtures.search([
            CatalogFixtures.artistRow(id: "UCTumHiHoBand00000000000", name: "Tum Hi Ho", audience: "12 subscribers"), CatalogFixtures.artistRow(),
        ]))
        let mock = CatalogMockSession { [router] request in try router.stub(request) }
        defer { mock.close() }

        let page = try await YouTubeMusicService(session: mock.session).search(query: "Tum Hi Ho", filter: .songs, continuation: nil)
        XCTAssertNil(page.featuredArtist, "A same-named artist without two of its own tracks on the page is not featured")
        XCTAssertEqual(page.tracks.map(\.id), [CatalogFixtures.hindiID, "BjL7AuPsmEk", "j4WUfUDn5hc", "Des4vM1U7MA"],
                       "Full title matches lead, partial ones follow, nothing is dropped")
        XCTAssertNil(page.correctedQuery)
    }

    func testArtistLookupFailuresDegradeToRankedResultsWithoutFailingTheSearch() async throws {
        let songs = try CatalogFixtures.data(CatalogFixtures.search([
            CatalogFixtures.song(id: "OaiOf0-kISM", title: "Al Rahman", artist: "Abdel Rahman el Ousi", artistID: "UC1CwoEojJpBZw8gnaZUhMVQ"),
            CatalogFixtures.song(), CatalogFixtures.song(id: "NJAv_7lHUIU", title: "Kesariya"),
        ]))
        var unavailable = CatalogMockRouter()
        unavailable.songs["Arijit Singh"] = songs
        unavailable.artistsStatus = 503
        let first = CatalogMockSession { [unavailable] request in try unavailable.stub(request) }
        defer { first.close() }
        let ranked = try await YouTubeMusicService(session: first.session).search(query: "Arijit Singh", filter: .songs, continuation: nil)
        XCTAssertNil(ranked.featuredArtist)
        XCTAssertEqual(ranked.tracks.map(\.id), [CatalogFixtures.hindiID, "NJAv_7lHUIU", "OaiOf0-kISM"], "Ranked, nothing dropped, search still succeeds")

        var noPage = CatalogMockRouter()
        noPage.songs["Arijit Singh"] = songs
        noPage.artists["Arijit Singh"] = try CatalogFixtures.data(CatalogFixtures.search([CatalogFixtures.artistRow()]))
        let second = CatalogMockSession { [noPage] request in try noPage.stub(request) }
        defer { second.close() }
        let featured = try await YouTubeMusicService(session: second.session).search(query: "Arijit Singh", filter: .songs, continuation: nil)
        XCTAssertEqual(featured.featuredArtist?.id, CatalogFixtures.arijitID, "A missing artist page still features the matched artist")
        XCTAssertEqual(featured.tracks.map(\.id), [CatalogFixtures.hindiID, "NJAv_7lHUIU"], "Without top songs the artist's rows lead and unrelated rows are dropped")
        XCTAssertEqual(requests(second, path: "/browse").count, 1)

        var brokenQueue = CatalogMockRouter()
        brokenQueue.songs["Arijit Singh"] = try CatalogFixtures.data(CatalogFixtures.search([
            CatalogFixtures.song(), CatalogFixtures.song(id: "NJAv_7lHUIU", title: "Kesariya", confirmed: false),
        ]))
        brokenQueue.queueStatus = 404
        let third = CatalogMockSession { [brokenQueue] request in try brokenQueue.stub(request) }
        defer { third.close() }
        let strict = try await YouTubeMusicService(session: third.session).search(query: "Arijit Singh", filter: .songs, continuation: nil)
        XCTAssertEqual(strict.tracks.map(\.id), [CatalogFixtures.hindiID], "Unverifiable rows stay excluded rather than failing the page")
    }

    func testSuccessfulSongsReturnWhileOptionalArtistSearchOrPageRemainsGated() async throws {
        for gateArtistPage in [false, true] {
            let gate = AppModelRequestGate<String, Void>()
            addTeardownBlock { await gate.close() }
            var router = CatalogMockRouter()
            router.songs["Arijit Singh"] = try CatalogFixtures.data(CatalogFixtures.search([
                CatalogFixtures.song(), CatalogFixtures.song(id: "NJAv_7lHUIU", title: "Kesariya"),
            ]))
            router.artists["Arijit Singh"] = try CatalogFixtures.data(CatalogFixtures.search([CatalogFixtures.artistRow()]))
            router.browse[CatalogFixtures.arijitID] = try CatalogFixtures.data(CatalogFixtures.artistPage(songs: [
                CatalogFixtures.song(id: "i1o1p_DD6TU", title: "Gehra Hua"),
            ]))
            let artistParams = artistsParams
            let mock = CatalogMockSession { [router] request in
                var stub = try router.stub(request)
                guard request.httpMethod == "POST" else { return stub }
                let body = try CatalogJSON.decode(request.httpBody ?? Data())
                let shouldGate = gateArtistPage ? body["browseId"].string == CatalogFixtures.arijitID
                    : body["params"].string == artistParams
                if shouldGate { stub.beforeDelivery = { try await gate.receive(gateArtistPage ? "artist-page" : "artist-search") } }
                return stub
            }
            defer { mock.close() }
            let service = YouTubeMusicService(session: mock.session)
            let pending = Task { try await service.search(query: "Arijit Singh", filter: .songs, continuation: nil) }
            defer { pending.cancel() }
            let blocked = try await gate.request(at: 0)

            let page = try await PlaybackDeadline.run(seconds: 4) { try await pending.value }

            XCTAssertEqual(page.tracks.map(\.id), [CatalogFixtures.hindiID, "NJAv_7lHUIU"])
            XCTAssertTrue(page.tracks.allSatisfy { $0.isAudioRecording == true })
            XCTAssertNil(page.featuredArtist)
            try await AppModelFixtures.eventually {
                let cancelled = await gate.cancellations
                return cancelled.contains(blocked.id) && mock.state.cancellations > 0
            }
            try await gate.complete(blocked, with: .success(()))
            XCTAssertEqual(requests(mock, path: "/search", containing: songsParams).count, 1)
            XCTAssertEqual(requests(mock, path: "/browse").count, gateArtistPage ? 1 : 0)
        }
    }

    func testExperienceRadioUsesActualServiceSongsDespiteGatedArtistEnrichment() async throws {
        let gate = AppModelRequestGate<String, Void>()
        addTeardownBlock { await gate.close() }
        let station = RadioExperience(id: "service-radio", title: "Service radio", description: "Fixture", symbol: "radio",
            discoveryLanguages: [.hindi], contentLabel: "Hindi", seeds: [.init("Tum Hi Ho", by: "Arijit Singh")])
        var router = CatalogMockRouter()
        router.songs[station.seeds[0].query] = try CatalogFixtures.data(CatalogFixtures.search([CatalogFixtures.song()]))
        router.next[CatalogFixtures.hindiID] = try CatalogFixtures.data(CatalogFixtures.radio([
            CatalogFixtures.radioTrack(id: "NJAv_7lHUIU", title: "Kesariya", artist: "Arijit Singh"),
            CatalogFixtures.radioTrack(id: "FOA9iyxsW_A", title: "Agar Tum Saath Ho", artist: "Alka Yagnik"),
            CatalogFixtures.radioTrack(id: "wx89ZdkwtS8", title: "Ae Dil Hai Mushkil", artist: "Pritam"),
        ]))
        let artistParams = artistsParams
        let mock = CatalogMockSession { [router] request in
            var stub = try router.stub(request)
            if request.httpMethod == "POST",
               try CatalogJSON.decode(request.httpBody ?? Data())["params"].string == artistParams {
                stub.beforeDelivery = { try await gate.receive("artist-search") }
            }
            return stub
        }
        defer { mock.close() }
        let service = YouTubeMusicService(session: mock.session)
        let pending = Task { try await ExperienceRadioEngine(catalog: service).start(station, disliked: [], languages: [.hindi]) }
        defer { pending.cancel() }
        let blocked = try await gate.request(at: 0)

        let batch = try await PlaybackDeadline.run(seconds: 5) { try await pending.value }

        XCTAssertEqual(batch.tracks.map(\.id), [CatalogFixtures.hindiID, "NJAv_7lHUIU", "FOA9iyxsW_A", "wx89ZdkwtS8"])
        XCTAssertEqual(batch.buckets.map(\.anchor.id), [CatalogFixtures.hindiID])
        XCTAssertTrue(batch.tracks.allSatisfy { $0.language == nil })
        XCTAssertEqual(requests(mock, path: "/search", containing: songsParams).count, 1)
        XCTAssertEqual(requests(mock, path: "/next").count, 1)
        try await AppModelFixtures.eventually { await gate.cancellations.contains(blocked.id) }
        try await gate.complete(blocked, with: .success(()))
    }

    func testEmptySongsPageRetriesOnceWithTheProviderCorrection() async throws {
        var router = CatalogMockRouter()
        router.songs["Arjit Singh"] = try CatalogFixtures.data(CatalogFixtures.search([], correction: CatalogFixtures.didYouMean(corrected: "Arijit Singh")))
        router.songs["Arijit Singh"] = try CatalogFixtures.data(CatalogFixtures.search([CatalogFixtures.song()], continuation: "corrected-page-2"))
        let mock = CatalogMockSession { [router] request in try router.stub(request) }
        defer { mock.close() }
        let service = YouTubeMusicService(session: mock.session)

        let page = try await service.search(query: "Arjit Singh", filter: .songs, continuation: nil)
        XCTAssertEqual(page.tracks.map(\.id), [CatalogFixtures.hindiID])
        XCTAssertEqual(page.correctedQuery, "Arijit Singh")
        XCTAssertEqual(requests(mock, path: "/search", containing: songsParams).map { $0["query"].string }, ["Arjit Singh", "Arijit Singh"])
        let next = try await service.search(query: "Arjit Singh", filter: .songs, continuation: try XCTUnwrap(page.continuation))
        XCTAssertEqual(requests(mock, path: "/search").last?["continuation"].string, "corrected-page-2", "The corrected page's cursor still belongs to the typed query")
        XCTAssertTrue(next.tracks.isEmpty)

        var noRetry = CatalogMockRouter()
        noRetry.songs["Tum Hi Ho"] = try CatalogFixtures.data(CatalogFixtures.search([]))
        let plain = CatalogMockSession { [noRetry] request in try noRetry.stub(request) }
        defer { plain.close() }
        let empty = try await YouTubeMusicService(session: plain.session).search(query: "Tum Hi Ho", filter: .songs, continuation: nil)
        XCTAssertTrue(empty.tracks.isEmpty)
        XCTAssertEqual(requests(plain, path: "/search", containing: songsParams).count, 1, "No correction, no retry")
    }

    func testArtistPageUsesTheHeaderIdentityAndSplitsReleasesFromRelatedArtists() async throws {
        var router = CatalogMockRouter()
        router.browse[CatalogFixtures.arijitID] = try CatalogFixtures.data(CatalogFixtures.artistPage(songs: [
            CatalogFixtures.song(id: "i1o1p_DD6TU", title: "Gehra Hua"), CatalogFixtures.song(),
        ], albums: [
            CatalogFixtures.collection(id: "MPREb_LFp4PGrIxoH", title: "Romance Reloaded", type: "MUSIC_PAGE_TYPE_ALBUM", subtitle: "Album • 2026"),
            CatalogFixtures.collection(id: "MPREb_rV5VAlzAHFb", title: "Ramayana", type: "MUSIC_PAGE_TYPE_ALBUM", subtitle: "Single • 2026"),
        ], related: [
            CatalogFixtures.collection(id: "UCzJRkr4MuVD7sEGHR_zRSEQ", title: "Tulsi Kumar", type: "MUSIC_PAGE_TYPE_ARTIST", subtitle: "257M monthly audience"),
        ]))
        let mock = CatalogMockSession { [router] request in try router.stub(request) }
        defer { mock.close() }
        let service = YouTubeMusicService(session: mock.session)

        let artist = try await service.artist(id: CatalogFixtures.arijitID)
        XCTAssertEqual(artist.id, CatalogFixtures.arijitID)
        XCTAssertEqual(artist.name, "Arijit Singh")
        XCTAssertEqual(artist.artworkURL?.absoluteString, "https://lh3.googleusercontent.com/\(CatalogFixtures.artistBannerHash)=w544-h544-p-l90-rj")
        XCTAssertEqual(artist.topSongs.map(\.id), ["i1o1p_DD6TU", CatalogFixtures.hindiID])
        XCTAssertEqual(artist.releases.map(\.title), ["Romance Reloaded", "Ramayana"])
        XCTAssertEqual(artist.releases.map(\.subtitle), ["Album • 2026", "Single • 2026"])
        XCTAssertEqual(artist.relatedArtists.map(\.id), ["UCzJRkr4MuVD7sEGHR_zRSEQ"])
        XCTAssertEqual(requests(mock, path: "/browse").count, 1)
        do { _ = try await service.artist(id: CatalogFixtures.albumID); XCTFail("Albums are not artists") }
        catch MusicServiceError.unavailable { }
    }

    func testCollectionEnrichmentAndRescueFillMissingPlayCountsButKeepParsedOnes() async throws {
        var router = CatalogMockRouter()
        router.browse[CatalogFixtures.albumID] = try CatalogFixtures.data(CatalogFixtures.browse([
            CatalogFixtures.albumSong(duration: nil, plays: "1.2B plays"),
            CatalogFixtures.albumSong(id: CatalogFixtures.englishID, title: "Sunn Raha Hai", duration: nil, plays: nil),
        ]))
        router.songs["Tum Hi Ho"] = try CatalogFixtures.data(CatalogFixtures.search([
            CatalogFixtures.song(plays: "1.2B plays"),
            CatalogFixtures.song(id: CatalogFixtures.englishID, title: "Sunn Raha Hai", confirmed: false, plays: nil),
        ]))
        router.queue = { ids in
            try CatalogFixtures.data(CatalogFixtures.queue(ids.map { id in
                CatalogFixtures.radioTrack(id: id, title: "Queue \(id)", artist: "Arijit Singh", album: "Aashiqui 2", views: "845K views")
            }))
        }
        let mock = CatalogMockSession { [router] request in try router.stub(request) }
        defer { mock.close() }
        let service = YouTubeMusicService(session: mock.session)

        let album = try await service.browse(id: CatalogFixtures.albumID)
        XCTAssertEqual(album.tracks.map(\.id), [CatalogFixtures.hindiID, CatalogFixtures.englishID])
        XCTAssertEqual(album.tracks.map(\.playCount), [1_200_000_000, nil], "Upload views cannot fill a missing song total")
        XCTAssertEqual(album.tracks.map(\.duration), [202, 202], "Durations still come from get_queue")

        let search = try await service.search(query: "Tum Hi Ho", filter: .songs, continuation: nil)
        XCTAssertEqual(search.tracks.map(\.id), [CatalogFixtures.hindiID, CatalogFixtures.englishID])
        XCTAssertEqual(search.tracks.map(\.playCount), [1_200_000_000, nil], "Rescuing a row must not relabel queue views as song plays")
    }

    func testHeaderlessAlbumContinuationInheritsCreditsTitleAndArtworkWithoutADurationLookup() async throws {
        var header = CatalogFixtures.albumHeader()
        header["thumbnail"] = ["musicThumbnailRenderer": ["thumbnail": CatalogFixtures.googleArtwork("AlbumCover")]]
        var first = CatalogFixtures.browse([
            CatalogFixtures.albumSong(id: "PsO6ZnUZI0g", title: "Good Morning", duration: "3:15", confirmed: true),
        ], continuation: "album-page-2", header: header)
        first["responseContext"] = ["visitorData": "album-visitor"]
        let second: [String: Any] = ["onResponseReceivedActions": [["appendContinuationItemsAction": ["continuationItems": [
            CatalogFixtures.albumSong(id: "FEKEjpTzB0Q", title: "Good Life (feat. T-Pain)", duration: "3:27", confirmed: true),
            CatalogFixtures.song(thumbnail: CatalogFixtures.googleArtwork("RowCover")),
        ]]]]]
        var router = CatalogMockRouter()
        router.browse[CatalogFixtures.graduationID] = try CatalogFixtures.data(first)
        router.continuations["album-page-2"] = try CatalogFixtures.data(second)
        let mock = CatalogMockSession { [router] request in try router.stub(request) }
        defer { mock.close() }

        let page = try await YouTubeMusicService(session: mock.session).browse(id: CatalogFixtures.graduationID)

        let kanye = ArtistCredit(name: "Kanye West", id: CatalogFixtures.kanyeID)
        XCTAssertEqual(page.title, "Graduation")
        XCTAssertEqual(page.credits, [kanye])
        XCTAssertEqual(page.tracks.map(\.id), ["PsO6ZnUZI0g", "FEKEjpTzB0Q", CatalogFixtures.hindiID])
        XCTAssertEqual(page.tracks[1].credits, [kanye, ArtistCredit(name: "T-Pain")])
        XCTAssertEqual(page.tracks[1].albumTitle, "Graduation")
        XCTAssertEqual(page.tracks[1].albumID, CatalogFixtures.graduationID)
        XCTAssertEqual(page.tracks[1].artworkURL?.absoluteString, "https://yt3.googleusercontent.com/AlbumCover=w544-h544-l90-rj")
        XCTAssertEqual(page.tracks[1].duration, 207)
        XCTAssertEqual(page.tracks[2].credits, [ArtistCredit(name: "Arijit Singh", id: CatalogFixtures.arijitID)])
        XCTAssertEqual(page.tracks[2].albumTitle, "Aashiqui 2")
        XCTAssertEqual(page.tracks[2].albumID, CatalogFixtures.albumID)
        XCTAssertEqual(page.tracks[2].artworkURL?.absoluteString, "https://yt3.googleusercontent.com/RowCover=w544-h544-l90-rj")
        XCTAssertTrue(requests(mock, path: "/music/get_queue").isEmpty, "Known durations must not suppress header inheritance")
        let browses = requests(mock, path: "/browse")
        XCTAssertEqual(browses.count, 2)
        XCTAssertEqual(browses.last?["continuation"].string, "album-page-2")
        XCTAssertEqual(browses.last?["context"]["client"]["visitorData"].string, "album-visitor")
    }

    func testRadioKeepsTheSeedsOwnNeighborsInProviderOrderWithoutLanguageTargeting() async throws {
        let seed = Track(id: "W3_c4-4OMbM", title: "Six Days (Remix) (feat. Mos Def)", credits: [ArtistCredit(name: "DJ Shadow")], language: .english)
        var router = CatalogMockRouter()
        router.next[seed.id] = try CatalogFixtures.data(CatalogFixtures.radio([
            CatalogFixtures.radioTrack(id: seed.id, title: seed.title, artist: "DJ Shadow"),
            CatalogFixtures.radioTrack(id: "gKYcXVLpEqI", title: "Hey Baby", artist: "Stephen Marley"),
            CatalogFixtures.radioTrack(id: "ic8j13piAhQ", title: "Mos Def - Auditorium [Bass Boosted + 432 Hz]", artist: "Mos Def", type: "MUSIC_VIDEO_TYPE_UGC"),
            CatalogFixtures.radioTrack(id: "Yn8s2bAkoKE", title: "Nobody Speak (Karaoke Version)", artist: "DJ Shadow"),
            CatalogFixtures.radioTrack(id: "Zw3XbF5o0kY", title: "Lose Yourself (Slowed + Reverb)", artist: "Eminem"),
            CatalogFixtures.radioTrack(id: "Nz1sDkHqvSQ", title: "Teardrop", artist: "Massive Attack"),
            CatalogFixtures.radioTrack(id: "gKYcXVLpEqI", title: "Hey Baby", artist: "Stephen Marley"),
            CatalogFixtures.radioTrack(id: "Ilv3jSt3l0k", title: "Clint Eastwood", artist: "Gorillaz"),
        ]))
        let mock = CatalogMockSession { [router] request in try router.stub(request) }
        defer { mock.close() }
        let service = YouTubeMusicService(session: mock.session)

        let tracks = try await service.radio(seed: seed)
        XCTAssertEqual(tracks.map(\.id), ["gKYcXVLpEqI", "Nz1sDkHqvSQ", "Ilv3jSt3l0k"],
                       "The seed, the UGC upload, karaoke and slowed takes, and the repeat are gone; the rest keep provider order")
        XCTAssertEqual(tracks.map(\.artistName), ["Stephen Marley", "Massive Attack", "Gorillaz"], "No artist allow-list prunes the neighbors")
        XCTAssertTrue(tracks.allSatisfy { $0.isAudioRecording == true })
        XCTAssertTrue(tracks.allSatisfy { $0.language == nil }, "Autoplay does not guess a language")
        let body = try XCTUnwrap(requests(mock, path: "/next").first)
        XCTAssertEqual(body["videoId"].string, seed.id)
        XCTAssertEqual(body["playlistId"].string, "RDAMVM" + seed.id)
        XCTAssertEqual(body["isAudioOnly"].bool, true)
        XCTAssertEqual(body["tunerSettingValue"].string, "AUTOMIX_SETTING_NORMAL")

        let targeted = try await service.recommendations(seed: seed, language: .english)
        XCTAssertTrue(targeted.isEmpty, "Home's language-targeted mix still applies its artist affinity filter to the same response")
        XCTAssertEqual(requests(mock, path: "/next").count, 1, "Both readings share one cached next response")
    }

    func testEmptyAndFilteredOutRadioResponsesRefetchBeforeTTLWhileHealthyRadioStaysCached() async throws {
        let seed = CatalogDiscovery.starters(for: .hindi)[0]
        let filtered = [
            CatalogFixtures.radioTrack(id: seed.id, title: seed.title, artist: "Arijit Singh"),
            CatalogFixtures.radioTrack(id: "NUo8CKI34o4", title: "Music video", artist: "Arijit Singh", type: "MUSIC_VIDEO_TYPE_OMV"),
            CatalogFixtures.radioTrack(id: "wx89ZdkwtS8", title: "A Song (Karaoke Version)", artist: "Arijit Singh"),
        ]
        let healthy = try CatalogFixtures.data(CatalogFixtures.radio([
            CatalogFixtures.radioTrack(id: "NJAv_7lHUIU", title: "Kesariya", artist: "Arijit Singh"),
        ]))
        for rows in [[], filtered] {
            let empty = try CatalogFixtures.data(CatalogFixtures.radio(rows))
            let counter = CatalogTestCounter()
            let clock = CatalogTestClock()
            let mock = CatalogMockSession { request in
                if request.httpMethod == "GET" { return CatalogStub(data: CatalogFixtures.bootstrap) }
                return CatalogStub(data: counter.increment() == 1 ? empty : healthy)
            }
            defer { mock.close() }
            let service = YouTubeMusicService(session: mock.session, now: { clock.now })

            let first = try await service.radio(seed: seed)
            let recovered = try await service.radio(seed: seed)
            let cached = try await service.radio(seed: seed)

            XCTAssertTrue(first.isEmpty)
            XCTAssertEqual(recovered.map(\.id), ["NJAv_7lHUIU"])
            XCTAssertEqual(cached, recovered)
            XCTAssertEqual(requests(mock, path: "/next").count, 2, "Recovery must refetch without advancing the cache clock")
        }
    }

    func testActualServiceRadioRecoversOnBoundedRetryAndOnANewStartBeforeTTL() async throws {
        let seed = CatalogDiscovery.starters(for: .hindi)[0]
        let station = RadioExperience(id: "retry-radio", title: "Retry radio", description: "Fixture", symbol: "radio",
            discoveryLanguages: [.hindi], contentLabel: "Hindi", seeds: [.init(recording: seed, artist: seed.credits[0])])
        let empty = try CatalogFixtures.data(CatalogFixtures.radio([]))
        let tooShort = try CatalogFixtures.data(CatalogFixtures.radio([
            CatalogFixtures.radioTrack(id: "NUo8CKI34o4", title: "Brief interlude", artist: "Arijit Singh", duration: "0:10"),
        ]))
        let healthy = try CatalogFixtures.data(CatalogFixtures.radio([
            CatalogFixtures.radioTrack(id: "NJAv_7lHUIU", title: "Kesariya", artist: "Arijit Singh"),
            CatalogFixtures.radioTrack(id: "FOA9iyxsW_A", title: "Agar Tum Saath Ho", artist: "Alka Yagnik"),
            CatalogFixtures.radioTrack(id: "wx89ZdkwtS8", title: "Ae Dil Hai Mushkil", artist: "Pritam"),
        ]))
        for (unusable, primeCache) in [(empty, false), (tooShort, true)] {
            for unusableResponses in [1, 2] {
                let counter = CatalogTestCounter()
                let clock = CatalogTestClock()
                let initialTime = clock.now
                let mock = CatalogMockSession { request in
                    if request.httpMethod == "GET" { return CatalogStub(data: CatalogFixtures.bootstrap) }
                    return CatalogStub(data: counter.increment() <= unusableResponses ? unusable : healthy)
                }
                defer { mock.close() }
                let service = YouTubeMusicService(session: mock.session, now: { clock.now })
                let engine = ExperienceRadioEngine(catalog: service)
                if primeCache {
                    let first = try await service.radio(seed: seed)
                    let cached = try await service.radio(seed: seed)
                    XCTAssertEqual(first.map(\.duration), [10])
                    XCTAssertTrue(first.allSatisfy { $0.isAudioRecording == true })
                    XCTAssertEqual(cached, first)
                    XCTAssertEqual(requests(mock, path: "/next").count, 1, "Normal radio reads must retain their cache")
                }
                if unusableResponses == 2 {
                    do {
                        _ = try await engine.start(station, disliked: [], languages: [.hindi])
                        XCTFail("An attempt whose initial radio and retry are both unusable must fail")
                    } catch { XCTAssertEqual(error as? ExperienceRadioError, .unavailable) }
                    XCTAssertEqual(requests(mock, path: "/next").count, 2, "Even an unsuccessful bounded retry must refetch")
                }
                let recovered = try await engine.start(station, disliked: [], languages: [.hindi])
                XCTAssertEqual(recovered.tracks.map(\.id), [seed.id, "NJAv_7lHUIU", "FOA9iyxsW_A", "wx89ZdkwtS8"])
                XCTAssertEqual(recovered.tracks.dropFirst().map(\.duration), [202, 202, 202])
                XCTAssertEqual(requests(mock, path: "/next").count, unusableResponses + 1,
                               "Recovery must reach the actual next endpoint rather than reuse the short ATV response")
                XCTAssertEqual(clock.now, initialTime, "Startup must recover without waiting for the five-minute cache expiry")
                let cachedRecovery = try await service.radio(seed: seed)
                XCTAssertEqual(cachedRecovery.map(\.id), ["NJAv_7lHUIU", "FOA9iyxsW_A", "wx89ZdkwtS8"])
                XCTAssertEqual(requests(mock, path: "/next").count, unusableResponses + 1, "Recovery refreshes the normal cache")
            }
        }
    }

    func testManualContinuationRetryRefetchesCachedShortAnchorAndFrontierBeforeTTL() async throws {
        let anchor = CatalogDiscovery.starters(for: .hindi)[0]
        let frontier = CatalogDiscovery.starters(for: .hindi)[1]
        let tooShort = try CatalogFixtures.data(CatalogFixtures.radio([
            CatalogFixtures.radioTrack(id: "NUo8CKI34o4", title: "Brief interlude", artist: "Arijit Singh", duration: "0:10"),
        ]))
        let healthy = try CatalogFixtures.data(CatalogFixtures.radio([
            CatalogFixtures.radioTrack(id: "FOA9iyxsW_A", title: "Agar Tum Saath Ho", artist: "Alka Yagnik"),
            CatalogFixtures.radioTrack(id: "wx89ZdkwtS8", title: "Ae Dil Hai Mushkil", artist: "Pritam"),
            CatalogFixtures.radioTrack(id: "B0p-iL_WbcA", title: "Phir Le Aya Dil", artist: "Arijit Singh"),
        ]))
        for usesFrontier in [false, true] {
            let recoverableSeed = usesFrontier ? frontier : anchor
            let buckets = [ExperienceRadioEngine.Bucket(anchor: anchor, frontier: recoverableSeed)]
            let queue = usesFrontier ? [anchor, frontier] : [anchor]
            let requestIDs = usesFrontier ? [anchor.id, frontier.id] : [anchor.id]
            let counter = CatalogTestCounter()
            let clock = CatalogTestClock()
            let initialTime = clock.now
            let mock = CatalogMockSession { request in
                if request.httpMethod == "GET" { return CatalogStub(data: CatalogFixtures.bootstrap) }
                let body = try CatalogJSON.decode(request.httpBody ?? Data())
                guard let id = body["videoId"].string, requestIDs.contains(id),
                      request.url?.path.hasSuffix("/next") == true else { throw URLError(.unsupportedURL) }
                let recovered = id == recoverableSeed.id && counter.increment() > 1
                return CatalogStub(data: recovered ? healthy : tooShort)
            }
            defer { mock.close() }
            let service = YouTubeMusicService(session: mock.session, now: { clock.now })
            let engine = ExperienceRadioEngine(catalog: service)
            for _ in 0..<2 {
                do {
                    _ = try await engine.continueRadio(buckets: buckets, round: 4, queue: queue, disliked: [], languages: [.hindi])
                    XCTFail("Ten-second ATV recordings are not usable continuation songs")
                } catch { XCTAssertEqual(error as? ExperienceRadioError, .unavailable) }
            }
            XCTAssertEqual(requests(mock, path: "/next").compactMap { $0["videoId"].string }, requestIDs,
                           "Automatic continuation must keep normal caching for its unchanged buckets and round")

            let recovered = try await engine.continueRadio(buckets: buckets, round: 4, queue: queue, disliked: [],
                languages: [.hindi], forceRefresh: true)

            XCTAssertEqual(recovered.tracks.map(\.id), ["FOA9iyxsW_A", "wx89ZdkwtS8", "B0p-iL_WbcA"])
            XCTAssertEqual(recovered.tracks.map(\.duration), [202, 202, 202])
            XCTAssertEqual(recovered.buckets.map(\.anchor.id), [anchor.id])
            XCTAssertEqual(recovered.buckets.first?.frontier.id, "B0p-iL_WbcA")
            XCTAssertEqual(requests(mock, path: "/next").compactMap { $0["videoId"].string }, requestIDs + requestIDs,
                           "An explicit retry must refetch both the anchor and its fallback frontier when needed")
            XCTAssertEqual(clock.now, initialTime, "The cached short response must not survive retry until TTL expiry")
            let cached = try await service.radio(seed: recoverableSeed)
            XCTAssertEqual(cached, recovered.tracks)
            XCTAssertEqual(requests(mock, path: "/next").count, requestIDs.count * 2)
        }
    }

    func testRadioRefreshBypassesCachedPayloadsButHonorsProviderCooldowns() async throws {
        let seed = CatalogDiscovery.starters(for: .hindi)[0]
        let healthy = try CatalogFixtures.data(CatalogFixtures.radio([
            CatalogFixtures.radioTrack(id: "NJAv_7lHUIU", title: "Kesariya", artist: "Arijit Singh"),
        ]))
        for status in [429, 503] {
            let counter = CatalogTestCounter()
            let clock = CatalogTestClock()
            let mock = CatalogMockSession { request in
                if request.httpMethod == "GET" { return CatalogStub(data: CatalogFixtures.bootstrap) }
                if counter.increment() == 2 { return CatalogStub(status: status, headers: ["Retry-After": "60"], data: Data("{}".utf8)) }
                return CatalogStub(data: healthy)
            }
            defer { mock.close() }
            let service = YouTubeMusicService(session: mock.session, now: { clock.now })
            let original = try await service.radio(seed: seed)
            do {
                _ = try await service.radio(seed: seed, forceRefresh: true)
                XCTFail("The fresh request must observe the provider's cooldown response")
            } catch MusicServiceError.rateLimited {
                XCTAssertEqual(status, 429)
            } catch MusicServiceError.unavailable {
                XCTAssertEqual(status, 503)
            }
            for _ in 0..<2 {
                do {
                    _ = try await service.radio(seed: seed, forceRefresh: true)
                    XCTFail("Cache bypass must not bypass Retry-After")
                } catch MusicServiceError.rateLimited { }
            }
            XCTAssertEqual(requests(mock, path: "/next").count, 2)
            let cached = try await service.radio(seed: seed)
            XCTAssertEqual(cached, original)
            XCTAssertEqual(requests(mock, path: "/next").count, 2, "A failed refresh does not discard a usable cached response")
            clock.advance(61)
            let recovered = try await service.radio(seed: seed, forceRefresh: true)
            XCTAssertEqual(recovered, original)
            XCTAssertEqual(requests(mock, path: "/next").count, 3)
        }
    }

    func testCancellingRadioRecoveryStopsTheFreshRequestWithoutReplacingTheCache() async throws {
        let seed = CatalogDiscovery.starters(for: .hindi)[0]
        let station = RadioExperience(id: "cancel-recovery", title: "Recovery radio", description: "Fixture", symbol: "radio",
            discoveryLanguages: [.hindi], contentLabel: "Hindi", seeds: [.init(recording: seed, artist: seed.credits[0])])
        let tooShort = try CatalogFixtures.data(CatalogFixtures.radio([
            CatalogFixtures.radioTrack(id: "NUo8CKI34o4", title: "Brief interlude", artist: "Arijit Singh", duration: "0:10"),
        ]))
        let healthy = try CatalogFixtures.data(CatalogFixtures.radio([
            CatalogFixtures.radioTrack(id: "NJAv_7lHUIU", title: "Kesariya", artist: "Arijit Singh"),
            CatalogFixtures.radioTrack(id: "FOA9iyxsW_A", title: "Agar Tum Saath Ho", artist: "Alka Yagnik"),
            CatalogFixtures.radioTrack(id: "wx89ZdkwtS8", title: "Ae Dil Hai Mushkil", artist: "Pritam"),
        ]))
        let gate = AppModelRequestGate<String, Void>()
        addTeardownBlock { await gate.close() }
        let counter = CatalogTestCounter()
        let mock = CatalogMockSession { request in
            if request.httpMethod == "GET" { return CatalogStub(data: CatalogFixtures.bootstrap) }
            if counter.increment() == 1 { return CatalogStub(data: tooShort) }
            return CatalogStub(data: healthy, beforeDelivery: { try await gate.receive("fresh-radio") })
        }
        defer { mock.close() }
        let service = YouTubeMusicService(session: mock.session)
        let pending = Task { try await ExperienceRadioEngine(catalog: service).start(station, disliked: [], languages: [.hindi]) }
        defer { pending.cancel() }
        let recovery = try await gate.request(at: 0)
        XCTAssertEqual(requests(mock, path: "/next").count, 2)
        pending.cancel()
        do { _ = try await pending.value; XCTFail("Cancelled recovery must not finish a station") }
        catch { XCTAssertTrue(error is CancellationError) }
        try await AppModelFixtures.eventually {
            let cancelled = await gate.cancellations
            return cancelled.contains(recovery.id) && mock.state.cancellations > 0
        }
        try await gate.complete(recovery, with: .success(()))
        let cached = try await service.radio(seed: seed)
        XCTAssertEqual(cached.map(\.duration), [10], "A cancelled response must not replace the cache after arriving late")
        XCTAssertEqual(requests(mock, path: "/next").count, 2)
    }

    func testChartEntriesGainSquareAlbumArtButKeepTheChartsIdentity() async throws {
        let chart = try CatalogFixtures.data(CatalogFixtures.chart([
            CatalogFixtures.chartRow(rank: 1), CatalogFixtures.chartRow(id: "FyS5dAywkEo", title: "Ae Dil Hai Mushkil", rank: 2, audioID: "wx89ZdkwtS8"),
        ]))
        let mock = CatalogMockSession { _ in CatalogStub(data: chart) }
        defer { mock.close() }
        let batches = CatalogTestRecorder<[String]>()
        let square = URL(string: "https://yt3.googleusercontent.com/Cover=w544-h544-l90-rj")
        let service = YouTubeChartsService(session: mock.session, metadata: { ids in
            batches.record(ids)
            return [Track(id: CatalogFixtures.hindiID, title: "Tum Hi Ho (Remastered)", artists: ["Arijit Singh"], albumTitle: "Aashiqui 2",
                          albumID: CatalogFixtures.albumID, artistID: CatalogFixtures.arijitID, duration: 262, artworkURL: square, isAudioRecording: true),
                    Track(id: "wx89ZdkwtS8", title: "Video", artists: ["Arijit Singh"], artworkURL: square, isAudioRecording: false)]
        })

        let snapshot = try await service.weeklyChart(language: .hindi)
        XCTAssertEqual(batches.values, [[CatalogFixtures.hindiID, "wx89ZdkwtS8"]], "One batch for the whole chart")
        XCTAssertEqual(snapshot.entries.map(\.rank), [1, 2])
        let first = try XCTUnwrap(snapshot.entries.first)
        XCTAssertEqual(first.track.title, "Parvati", "The chart's own title and credits stay")
        XCTAssertEqual(first.track.artworkURL, square)
        XCTAssertEqual(first.track.albumTitle, "Aashiqui 2")
        XCTAssertEqual(first.track.duration, 262)
        XCTAssertEqual(first.track.artistID, CatalogFixtures.arijitID)
        XCTAssertEqual(first.views, 16_321_798)
        XCTAssertEqual(first.previousRank, 2)
        let second = try XCTUnwrap(snapshot.entries.last)
        XCTAssertEqual(second.track.artworkURL?.absoluteString, "https://i.ytimg.com/vi/wx89ZdkwtS8/hqdefault.jpg", "Non-audio metadata is ignored")
        XCTAssertNil(second.track.duration)
        XCTAssertTrue(snapshot.entries.allSatisfy { $0.track.isAudioRecording == true })
        XCTAssertEqual(mock.state.requests.count, 1, "The injected loader replaces the default YouTube Music round trip")

        let failing = YouTubeChartsService(session: mock.session, metadata: { _ in throw MusicServiceError.rateLimited })
        let frames = try await failing.weeklyChart(language: .hindi)
        XCTAssertEqual(frames.entries.map { $0.track.artworkURL?.lastPathComponent }, ["hqdefault.jpg", "hqdefault.jpg"], "Metadata failures keep the video frames")
    }
}

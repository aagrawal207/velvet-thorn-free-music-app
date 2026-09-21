import XCTest
@testable import GanaBajana

@MainActor
final class CatalogRequestTests: XCTestCase {
    func testRequestsUseDynamicConfigurationAndUnrestrictedUnicodeQueriesWithoutCredentials() async throws {
        let response = try CatalogFixtures.data(CatalogFixtures.search([CatalogFixtures.song()]))
        let mock = CatalogMockSession { request in CatalogStub(data: request.httpMethod == "GET" ? CatalogFixtures.bootstrap : response) }
        defer { mock.close() }
        let service = YouTubeMusicService(session: mock.session)
        _ = try await service.search(query: "  宇多田ヒカル  ", filter: .songs, continuation: nil)
        _ = try await service.search(query: "तुम ही हो", filter: .songs, continuation: nil)
        XCTAssertEqual(mock.state.requests.filter { $0.httpMethod == "GET" }.count, 1)
        // A first songs page also runs the artists search that resolves artist-named queries.
        let posts = try mock.state.requests.filter { $0.httpMethod == "POST" }.map { try CatalogJSON.decode(XCTUnwrap($0.httpBody)) }
        XCTAssertEqual(posts.count, 4)
        XCTAssertEqual(posts.filter { $0["params"].string == "EgWKAQIIAWoMEA4QChADEAQQCRAF" }.map { $0["query"].string }, ["宇多田ヒカル", "तुम ही हो"])
        XCTAssertEqual(posts.filter { $0["params"].string == "EgWKAQIgAWoMEA4QChADEAQQCRAF" }.count, 2)
        XCTAssertTrue(posts.allSatisfy { $0["context"]["client"]["clientVersion"].string == CatalogFixtures.version })
        let first = try XCTUnwrap(mock.state.requests.first { $0.httpMethod == "POST" })
        XCTAssertEqual(first.url?.path, "/youtubei/v1/search")
        XCTAssertEqual(first.value(forHTTPHeaderField: "X-YouTube-Client-Name"), "67")
        XCTAssertTrue(mock.state.requests.allSatisfy { !$0.httpShouldHandleCookies })
        XCTAssertTrue(mock.state.requests.allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == nil && $0.value(forHTTPHeaderField: "Authorization") == nil })
        XCTAssertTrue(mock.state.requests.allSatisfy { !($0.url?.query?.contains("key=") ?? false) })
    }

    func testAllSearchFiltersAndOpaqueContinuationsHaveTheCorrectWireShape() async throws {
        let first = try CatalogFixtures.data(CatalogFixtures.search([CatalogFixtures.song()], continuation: "opaque+/%3D="))
        let next = try CatalogFixtures.data(CatalogFixtures.search([
            CatalogFixtures.song(id: "FOA9iyxsW_A", title: "Agar Tum Saath Ho"), CatalogFixtures.song(id: "FOA9iyxsW_A"),
        ], continued: true))
        let mock = CatalogMockSession { request in
            if request.httpMethod == "GET" { return CatalogStub(data: CatalogFixtures.bootstrap) }
            let body = try CatalogJSON.decode(request.httpBody ?? Data())
            return CatalogStub(data: body["continuation"].string == nil ? first : next)
        }
        defer { mock.close() }
        let service = YouTubeMusicService(session: mock.session)
        let cases: [(SearchFilter, String)] = [
            (.songs, "EgWKAQIIAWoMEA4QChADEAQQCRAF"), (.albums, "EgWKAQIYAWoMEA4QChADEAQQCRAF"),
            (.artists, "EgWKAQIgAWoMEA4QChADEAQQCRAF"), (.playlists, "Eg-KAQwIABAAGAAgACgBMABqChAEEAMQCRAFEAo%3D"),
        ]
        for (filter, _) in cases {
            _ = try await service.search(query: "Arijit Singh", filter: filter, continuation: nil)
        }
        // The songs search already issued (and cached) the artists lookup, so the explicit artists filter hits the cache.
        let bodies = try mock.state.requests.filter { $0.httpMethod == "POST" }.map { try CatalogJSON.decode(XCTUnwrap($0.httpBody)) }
        XCTAssertEqual(bodies.count, cases.count)
        for (filter, params) in cases {
            XCTAssertEqual(bodies.filter { $0["params"].string == params && $0["query"].string == "Arijit Singh" }.count, 1, filter.rawValue)
        }
        let before = mock.state.requests.count
        let page = try await service.search(query: "Arijit Singh", filter: .songs, continuation: "opaque+/%3D=")
        XCTAssertEqual(page.tracks.map(\.id), ["FOA9iyxsW_A"])
        XCTAssertEqual(mock.state.requests.count, before + 1, "Continuation pages do not repeat the artist lookup")
        let body = try CatalogJSON.decode(XCTUnwrap(mock.state.requests.last?.httpBody))
        XCTAssertEqual(body["continuation"].string, "opaque+/%3D=")
        XCTAssertNil(body["query"].string)
    }

    func testConfigurationAndSearchCachesExpireRatherThanUsingStaleVersionsForever() async throws {
        let data = try CatalogFixtures.data(CatalogFixtures.search([CatalogFixtures.song()]))
        let clock = CatalogTestClock()
        let mock = CatalogMockSession { request in CatalogStub(data: request.httpMethod == "GET" ? CatalogFixtures.bootstrap : data) }
        defer { mock.close() }
        let service = YouTubeMusicService(session: mock.session, now: { clock.now })
        _ = try await service.search(query: "Tum Hi Ho", filter: .songs, continuation: nil)
        _ = try await service.search(query: "Tum Hi Ho", filter: .songs, continuation: nil)
        XCTAssertEqual(mock.state.requests.count, 3, "One bootstrap plus the songs and artists searches, then cache hits")
        clock.advance(121)
        _ = try await service.search(query: "Tum Hi Ho", filter: .songs, continuation: nil)
        XCTAssertEqual(mock.state.requests.count, 5)
        clock.advance(6 * 3_600)
        _ = try await service.search(query: "Tum Hi Ho", filter: .songs, continuation: nil)
        XCTAssertEqual(mock.state.requests.filter { $0.httpMethod == "GET" }.count, 2)
    }

    func testBootstrapFailureUsesShortLivedVerifiedFallbackAndNeverPrivateCookies() async throws {
        let data = try CatalogFixtures.data(CatalogFixtures.search([CatalogFixtures.song()]))
        let clock = CatalogTestClock()
        let mock = CatalogMockSession { request in
            CatalogStub(data: request.httpMethod == "GET" ? Data("<html>Consent interstitial</html>".utf8) : data)
        }
        defer { mock.close() }
        let service = YouTubeMusicService(session: mock.session, now: { clock.now })
        _ = try await service.search(query: "First", filter: .songs, continuation: nil)
        let body = try CatalogJSON.decode(XCTUnwrap(mock.state.requests.last?.httpBody))
        XCTAssertEqual(body["context"]["client"]["clientVersion"].string, "1.20260915.14.00")
        clock.advance(301)
        _ = try await service.search(query: "Second", filter: .songs, continuation: nil)
        XCTAssertEqual(mock.state.requests.filter { $0.httpMethod == "GET" }.count, 2)
        XCTAssertNil(WebRemixConfiguration.parse(Data("{\"INNERTUBE_CLIENT_VERSION\":\"arbitrary\"}".utf8)))
    }

    func testBrowseFollowsTrackContinuationAndDeduplicatesAcrossPages() async throws {
        let first = try CatalogFixtures.data(CatalogFixtures.browse([CatalogFixtures.song()], continuation: "next-playlist"))
        let next = try CatalogFixtures.data(["onResponseReceivedActions": [["appendContinuationItemsAction": ["continuationItems": [
            CatalogFixtures.song(), CatalogFixtures.song(id: "FOA9iyxsW_A", title: "Agar Tum Saath Ho"),
        ]]]]])
        let mock = CatalogMockSession { request in
            if request.httpMethod == "GET" { return CatalogStub(data: CatalogFixtures.bootstrap) }
            let body = try CatalogJSON.decode(request.httpBody ?? Data())
            return CatalogStub(data: body["continuation"].string == nil ? first : next)
        }
        defer { mock.close() }
        let page = try await YouTubeMusicService(session: mock.session).browse(id: "PL4fGSI1pDJn5RgLW0Sb_zECecWdH_4zOX")
        XCTAssertEqual(page.tracks.map(\.id), [CatalogFixtures.hindiID, "FOA9iyxsW_A"])
        XCTAssertNil(page.continuation)
        let posts = mock.state.requests.filter { $0.httpMethod == "POST" }
        XCTAssertEqual(posts.count, 2)
        XCTAssertEqual(try CatalogJSON.decode(XCTUnwrap(posts.first?.httpBody))["browseId"].string, "VLPL4fGSI1pDJn5RgLW0Sb_zECecWdH_4zOX")
    }

    func testAnonymousVisitorIsCarriedInsideOpaqueBrowseContinuation() async throws {
        var initial = CatalogFixtures.browse([CatalogFixtures.song()], continuation: "playlist-token")
        initial["responseContext"] = ["visitorData": "public-anonymous-visitor"]
        let first = try CatalogFixtures.data(initial)
        let next = try CatalogFixtures.data(["onResponseReceivedActions": [["appendContinuationItemsAction": ["continuationItems": [
            CatalogFixtures.song(id: "FOA9iyxsW_A", title: "Agar Tum Saath Ho"),
        ]]]]])
        let mock = CatalogMockSession { request in
            if request.httpMethod == "GET" { return CatalogStub(data: CatalogFixtures.bootstrap) }
            let body = try CatalogJSON.decode(request.httpBody ?? Data())
            let validContinuation = body["continuation"].string == "playlist-token"
                && body["context"]["client"]["visitorData"].string == "public-anonymous-visitor"
            return CatalogStub(data: validContinuation ? next : first)
        }
        defer { mock.close() }
        let page = try await YouTubeMusicService(session: mock.session).browse(id: CatalogDiscovery.englishPlaylist)
        XCTAssertEqual(page.tracks.map(\.id), [CatalogFixtures.hindiID, "FOA9iyxsW_A"])
        XCTAssertEqual(mock.state.requests.filter { $0.httpMethod == "POST" }.count, 2)
        XCTAssertTrue(mock.state.requests.allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == nil })
    }

    func testSearchContinuationRetainsVisitorAcrossServiceInstancesAndRejectsDifferentQueries() async throws {
        var initial = CatalogFixtures.search([CatalogFixtures.song()], continuation: "search-token")
        initial["responseContext"] = ["visitorData": "public-search-visitor"]
        let first = try CatalogFixtures.data(initial)
        let next = try CatalogFixtures.data(CatalogFixtures.search([CatalogFixtures.song(id: "FOA9iyxsW_A")], continued: true))
        let mock = CatalogMockSession { request in
            if request.httpMethod == "GET" { return CatalogStub(data: CatalogFixtures.bootstrap) }
            let body = try CatalogJSON.decode(request.httpBody ?? Data())
            return CatalogStub(data: body["continuation"].string == nil ? first : next)
        }
        defer { mock.close() }
        let firstService = YouTubeMusicService(session: mock.session)
        let initialPage = try await firstService.search(query: "Arijit", filter: .songs, continuation: nil)
        let continuation = try XCTUnwrap(initialPage.continuation)
        let secondService = YouTubeMusicService(session: mock.session)
        _ = try await secondService.search(query: "Arijit", filter: .songs, continuation: continuation)
        let body = try CatalogJSON.decode(XCTUnwrap(mock.state.requests.last?.httpBody))
        XCTAssertEqual(body["continuation"].string, "search-token")
        XCTAssertEqual(body["context"]["client"]["visitorData"].string, "public-search-visitor")
        let requestCount = mock.state.requests.count
        do { _ = try await secondService.search(query: "Different", filter: .songs, continuation: continuation); XCTFail("Expected scope rejection") }
        catch MusicServiceError.unavailable { }
        XCTAssertEqual(mock.state.requests.count, requestCount)
    }

    func testRadioRequestsUseRealSeedIdentityAndTargetLanguageWithoutInventingTrackLanguage() async throws {
        let data = try CatalogFixtures.data(CatalogFixtures.radio([
            CatalogFixtures.radioTrack(id: CatalogFixtures.hindiID, title: "Tum Hi Ho", artist: "Arijit Singh"),
            CatalogFixtures.radioTrack(id: "wx89ZdkwtS8", title: "Ae Dil Hai Mushkil", artist: "Arijit Singh"),
            CatalogFixtures.radioTrack(id: CatalogFixtures.englishID, title: "Blinding Lights", artist: "The Weeknd"),
        ]))
        let mock = CatalogMockSession { request in CatalogStub(data: request.httpMethod == "GET" ? CatalogFixtures.bootstrap : data) }
        defer { mock.close() }
        let seed = CatalogDiscovery.starters(for: .hindi)[0]
        let tracks = try await YouTubeMusicService(session: mock.session).recommendations(seed: seed, language: .hindi)
        XCTAssertEqual(tracks.map(\.id), ["wx89ZdkwtS8"])
        XCTAssertNil(tracks.first?.language)
        let body = try CatalogJSON.decode(XCTUnwrap(mock.state.requests.last?.httpBody))
        XCTAssertEqual(body["playlistId"].string, "RDAMVMfsiPzT50ZiM")
        XCTAssertEqual(body["isAudioOnly"].bool, true)
    }

    func testAlbumClipCreditsAreOnlyUsedAfterBatchedATVValidation() async throws {
        let clip: [String: Any] = ["musicResponsiveListItemRenderer": [
            "playlistItemData": ["videoId": "NUo8CKI34o4"],
            "flexColumns": [["musicResponsiveListItemFlexColumnRenderer": ["text": CatalogFixtures.text("Tum Hi Ho clip")]]],
            "navigationEndpoint": ["watchEndpoint": CatalogFixtures.watch("NUo8CKI34o4", type: "MUSIC_VIDEO_TYPE_OMV")],
            "menu": ["items": [["navigationEndpoint": CatalogFixtures.browseRun("Credits", id: "MPTCfsiPzT50ZiM", type: "MUSIC_PAGE_TYPE_TRACK_CREDITS")["navigationEndpoint"]!]]],
        ]]
        let browse = try CatalogFixtures.data(CatalogFixtures.browse([clip]))
        for audio in [true, false] {
            let metadata = try CatalogFixtures.data(["queueDatas": [["content": CatalogFixtures.radioTrack(
                id: CatalogFixtures.hindiID, title: "Tum Hi Ho", artist: "Arijit Singh", type: audio ? "MUSIC_VIDEO_TYPE_ATV" : "MUSIC_VIDEO_TYPE_OMV")]]])
            let mock = CatalogMockSession { request in
                if request.httpMethod == "GET" { return CatalogStub(data: CatalogFixtures.bootstrap) }
                return CatalogStub(data: request.url?.path.hasSuffix("/music/get_queue") == true ? metadata : browse)
            }
            defer { mock.close() }
            let page = try await YouTubeMusicService(session: mock.session).browse(id: CatalogFixtures.albumID)
            XCTAssertEqual(page.tracks.map(\.id), audio ? [CatalogFixtures.hindiID] : [])
            XCTAssertTrue(page.tracks.allSatisfy { $0.isAudioRecording == true })
            XCTAssertEqual(mock.state.requests.filter { $0.url?.path.hasSuffix("/music/get_queue") == true }.count, 1)
        }
    }

    func testRateLimitsHonorRetryAfterAndFailedResponsesAreNotCached() async throws {
        let mock = CatalogMockSession { request in
            request.httpMethod == "GET" ? CatalogStub(data: CatalogFixtures.bootstrap)
                : CatalogStub(status: 429, headers: ["Retry-After": "60"], data: Data("{}".utf8))
        }
        defer { mock.close() }
        let clock = CatalogTestClock()
        let service = YouTubeMusicService(session: mock.session, now: { clock.now })
        let songSearches = {
            mock.state.requests.filter { $0.httpMethod == "POST" && String(data: $0.httpBody ?? Data(), encoding: .utf8)?.contains(YouTubeMusicService.searchParameters(.songs)) == true }.count
        }
        for query in ["First", "Second"] {
            do { _ = try await service.search(query: query, filter: .songs, continuation: nil); XCTFail("Expected rate limit") }
            catch MusicServiceError.rateLimited { }
        }
        XCTAssertEqual(songSearches(), 1)
        clock.advance(61)
        do { _ = try await service.search(query: "First", filter: .songs, continuation: nil); XCTFail("Expected rate limit") }
        catch MusicServiceError.rateLimited { }
        XCTAssertEqual(songSearches(), 2)
    }

    func testTransientFailureRetriesOnceButMalformedJSONDoesNotBecomeAnEmptyCatalog() async throws {
        let counter = CatalogTestCounter()
        let good = try CatalogFixtures.data(CatalogFixtures.search([CatalogFixtures.song()]))
        let mock = CatalogMockSession { request in
            if request.httpMethod == "GET" { return CatalogStub(data: CatalogFixtures.bootstrap) }
            return counter.increment() == 1 ? CatalogStub(status: 503, data: Data("{}".utf8)) : CatalogStub(data: good)
        }
        defer { mock.close() }
        let page = try await YouTubeMusicService(session: mock.session).search(query: "Retry", filter: .songs, continuation: nil)
        XCTAssertEqual(page.tracks.count, 1)
        XCTAssertEqual(mock.state.requests.filter { $0.httpMethod == "POST" }.count, 3, "Songs and artists searches, one of them retried once")
        let broken = CatalogMockSession { request in
            CatalogStub(data: request.httpMethod == "GET" ? CatalogFixtures.bootstrap : Data("not JSON".utf8))
        }
        defer { broken.close() }
        let service = YouTubeMusicService(session: broken.session)
        for _ in 0..<2 {
            do { _ = try await service.search(query: "Broken", filter: .songs, continuation: nil); XCTFail("Expected parse error") }
            catch MusicServiceError.invalidResponse { }
        }
        let songSearches = broken.state.requests.filter {
            $0.httpMethod == "POST" && String(data: $0.httpBody ?? Data(), encoding: .utf8)?.contains(YouTubeMusicService.searchParameters(.songs)) == true
        }
        XCTAssertEqual(songSearches.count, 2)
    }

    func testCancellationStopsURLSessionWorkAndDoesNotReturnEditorialFallback() async throws {
        let data = try CatalogFixtures.data(CatalogFixtures.search([CatalogFixtures.song()]))
        let mock = CatalogMockSession { request in
            CatalogStub(data: request.httpMethod == "GET" ? CatalogFixtures.bootstrap : data, delay: request.httpMethod == "GET" ? 0 : 10)
        }
        defer { mock.close() }
        let service = YouTubeMusicService(session: mock.session)
        let task = Task { try await service.search(query: "Cancel", filter: .songs, continuation: nil) }
        for _ in 0..<100 {
            if mock.state.requests.contains(where: { $0.httpMethod == "POST" }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(mock.state.requests.contains(where: { $0.httpMethod == "POST" }))
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        // URLSession delivers stopLoading on its own queue shortly after the task is cancelled.
        for _ in 0..<100 where mock.state.cancellations == 0 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertGreaterThan(mock.state.cancellations, 0)
    }

    func testBoundedLRUCacheEvictsOldResponses() async throws {
        let data = try CatalogFixtures.data(["contents": [:]])
        let mock = CatalogMockSession { _ in CatalogStub(data: data) }
        defer { mock.close() }
        let transport = CatalogTransport(session: mock.session, maxCacheBytes: 1_024, maxCacheEntries: 2)
        for query in ["a", "b", "a", "c", "b"] {
            _ = try await transport.post(baseURL: CatalogTransport.musicURL, endpoint: "search", body: ["query": .string(query)], ttl: 120)
        }
        XCTAssertEqual(mock.state.requests.count, 4)
    }

    func testHindiChartUsesAnalyticsWireQueryAndPreservesOriginalFetchDateInCache() async throws {
        let data = try CatalogFixtures.data(CatalogFixtures.chart([CatalogFixtures.chartRow()]))
        let mock = CatalogMockSession { request in CatalogStub(data: try CatalogFixtures.audioResponse(request) ?? data) }
        defer { mock.close() }
        let clock = CatalogTestClock()
        let service = YouTubeChartsService(session: mock.session, now: { clock.now })
        let first = try await service.weeklyChart(language: .hindi)
        clock.advance(60)
        let second = try await service.weeklyChart(language: .hindi)
        XCTAssertEqual(first.fetchedAt, second.fetchedAt)
        XCTAssertEqual(mock.state.requests.filter { $0.url?.host == "charts.youtube.com" }.count, 1)
        XCTAssertEqual(mock.state.requests.count, 3)
        let request = try XCTUnwrap(mock.state.requests.first)
        let body = try CatalogJSON.decode(XCTUnwrap(request.httpBody))
        XCTAssertEqual(request.url?.host, "charts.youtube.com")
        XCTAssertEqual(body["browseId"].string, "FEmusic_analytics_charts_home")
        XCTAssertEqual(body["context"]["client"]["clientVersion"].string, "2.0")
        XCTAssertEqual(body["query"].string, "perspective=CHART_DETAILS&chart_params_country_code=in&chart_params_chart_type=TRACKS&chart_params_period_type=WEEKLY")
        XCTAssertEqual(first.entries.first?.track.isAudioRecording, true)
    }

    func testEnglishWeeklyPicksUsesUSRegionalSongsWithoutLanguageClaim() async throws {
        let data = try CatalogFixtures.data(CatalogFixtures.chart([
            CatalogFixtures.chartRow(rank: 7, audioID: "XfEMj-z3TtA", artist: "Justin Bieber"),
        ], region: "us"))
        let mock = CatalogMockSession { request in CatalogStub(data: try CatalogFixtures.audioResponse(request) ?? data) }
        defer { mock.close() }
        let chart = try await YouTubeChartsService(session: mock.session).weeklyChart(language: .english)
        XCTAssertEqual(chart.entries.map(\.rank), [7])
        XCTAssertNil(chart.entries.first?.track.language)
        XCTAssertEqual(chart.title, "Weekly picks")
        XCTAssertTrue(chart.subtitle.contains("United States"))
        for request in mock.state.requests where request.httpMethod == "POST" && request.url?.host == "charts.youtube.com" {
            let body = try CatalogJSON.decode(XCTUnwrap(request.httpBody))
            XCTAssertTrue(body["query"].text.contains("chart_params_country_code=us"))
            XCTAssertTrue(body["query"].text.contains("chart_params_chart_type=TRACKS"))
            XCTAssertFalse(body["query"].text.contains("VIDEO"))
            XCTAssertFalse(body["query"].text.contains("chart_params_chart_attribute"))
        }
    }

    func testEnglishPicksFallsBackOnlyToGlobalSongsWhenUSHasNoMatchingAudio() async throws {
        let empty = try CatalogFixtures.data(CatalogFixtures.chart([CatalogFixtures.chartRow(audioID: nil)], region: "us"))
        let global = try CatalogFixtures.data(CatalogFixtures.chart([CatalogFixtures.chartRow(audioID: "XfEMj-z3TtA", artist: "Justin Bieber")], region: "global"))
        let mock = CatalogMockSession { request in
            if let audio = try CatalogFixtures.audioResponse(request) { return CatalogStub(data: audio) }
            let body = try CatalogJSON.decode(request.httpBody ?? Data())
            return CatalogStub(data: body["query"].text.contains("chart_params_country_code=us") ? empty : global)
        }
        defer { mock.close() }
        let chart = try await YouTubeChartsService(session: mock.session).weeklyChart(language: .english)
        XCTAssertEqual(chart.language, .english)
        XCTAssertTrue(chart.subtitle.contains("Global"))
        XCTAssertEqual(mock.state.requests.filter { $0.url?.host == "charts.youtube.com" }.count, 2)
    }
}

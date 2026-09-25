import XCTest
@testable import GanaBajana

@MainActor
final class AlbumDescriptionProviderTests: XCTestCase {
    func testDescriptionOnlyLookupUsesOneHeaderWithoutPaginationOrRecordingEnrichment() async throws {
        var page = try AlbumDescriptionFixtures.page(continuation: "unused-page").object
        page["contents"] = try CatalogFixtures.json(CatalogFixtures.browse(
            [CatalogFixtures.albumSong(duration: nil)], continuation: "unused-page", header: AlbumDescriptionFixtures.header()))["contents"]
        let data = try CatalogJSON.object(page).encoded()
        let mock = CatalogMockSession { request in
            CatalogStub(data: request.httpMethod == "GET" ? CatalogFixtures.bootstrap : data)
        }
        defer { mock.close() }
        let provider = YouTubeMusicService(session: mock.session)
        let description = try await provider.albumDescription(id: AlbumDescriptionFixtures.id)
        XCTAssertEqual(description?.text, AlbumDescriptionFixtures.text)
        let cached = try await provider.albumDescription(id: AlbumDescriptionFixtures.id)
        XCTAssertEqual(description, cached)
        XCTAssertEqual(mock.state.requests.count, 2, "One bootstrap and one browse response; repeated reads use memory")
        let request = try XCTUnwrap(mock.state.requests.first { $0.httpMethod == "POST" })
        let payload = try CatalogJSON.decode(try XCTUnwrap(request.httpBody))
        XCTAssertEqual(payload["browseId"].string, AlbumDescriptionFixtures.id)
        XCTAssertEqual(payload["continuation"], .null)
        XCTAssertEqual(request.url?.path, "/youtubei/v1/browse")
        XCTAssertEqual(request.url?.host, "music.youtube.com")
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.url?.query?.range(of: "key="))
    }

    func testOrdinaryBrowseCarriesTheDescriptionAndWarmsTheOptionalLookupCache() async throws {
        let data = try AlbumDescriptionFixtures.page().encoded()
        let mock = CatalogMockSession { request in
            CatalogStub(data: request.httpMethod == "GET" ? CatalogFixtures.bootstrap : data)
        }
        defer { mock.close() }
        let provider = YouTubeMusicService(session: mock.session)
        let catalog: any MusicCatalogProviding = provider
        let page = try await catalog.browse(id: AlbumDescriptionFixtures.id)
        XCTAssertEqual(page.tracks.count, 1)
        XCTAssertEqual(page.albumDescription?.text, AlbumDescriptionFixtures.text)
        let optional = try await provider.albumDescription(id: AlbumDescriptionFixtures.id)
        XCTAssertEqual(optional, page.albumDescription)
        XCTAssertEqual(mock.state.requests.count, 2)
    }

    func testMissingDescriptionIsNegativeCachedUntilTheBrowseResponseExpires() async throws {
        let clock = CatalogTestClock()
        let data = try AlbumDescriptionFixtures.page(header: CatalogFixtures.albumHeader()).encoded()
        let mock = CatalogMockSession { request in
            CatalogStub(data: request.httpMethod == "GET" ? CatalogFixtures.bootstrap : data)
        }
        defer { mock.close() }
        let provider = YouTubeMusicService(session: mock.session, now: { clock.now })
        for _ in 0..<2 {
            let missing = try await provider.albumDescription(id: AlbumDescriptionFixtures.id)
            XCTAssertNil(missing)
        }
        XCTAssertEqual(mock.state.requests.count, 2)
        clock.advance(601)
        let missing = try await provider.albumDescription(id: AlbumDescriptionFixtures.id)
        XCTAssertNil(missing)
        XCTAssertEqual(mock.state.requests.count, 3, "Expired metadata is read again without another client bootstrap")
    }

    func testRateLimitIsRetryableAndItsCooldownIsSharedWithCatalogReads() async throws {
        let clock = CatalogTestClock()
        let posts = CatalogTestCounter()
        let data = try AlbumDescriptionFixtures.page().encoded()
        let mock = CatalogMockSession { request in
            if request.httpMethod == "GET" { return CatalogStub(data: CatalogFixtures.bootstrap) }
            if posts.increment() == 1 { return CatalogStub(status: 429, headers: ["Retry-After": "30"], data: Data("{}".utf8)) }
            return CatalogStub(data: data)
        }
        defer { mock.close() }
        let provider = YouTubeMusicService(session: mock.session, now: { clock.now })
        do { _ = try await provider.albumDescription(id: AlbumDescriptionFixtures.id); XCTFail("Expected a retryable failure") }
        catch { guard case MusicServiceError.rateLimited = error else { return XCTFail("Unexpected error: \(error)") } }
        do { _ = try await provider.browse(id: AlbumDescriptionFixtures.id); XCTFail("Catalog must honor the same cooldown") }
        catch { guard case MusicServiceError.rateLimited = error else { return XCTFail("Unexpected error: \(error)") } }
        XCTAssertEqual(mock.state.requests.filter { $0.httpMethod == "POST" }.count, 1)
        clock.advance(31)
        let recovered = try await provider.albumDescription(id: AlbumDescriptionFixtures.id)
        XCTAssertNotNil(recovered)
        XCTAssertEqual(mock.state.requests.filter { $0.httpMethod == "POST" }.count, 2)
    }

    func testMalformedAndOversizedResponsesDoNotBecomeCachedAbsence() async throws {
        let data = try AlbumDescriptionFixtures.page().encoded()
        let invalid = [CatalogStub(data: Data("not json".utf8)), CatalogStub(data: Data("{}".utf8)),
                       CatalogStub(data: Data(#"{"contents":{}}"#.utf8)),
                       CatalogStub(headers: ["Content-Length": String(8 * 1_024 * 1_024 + 1)], data: data)]
        for stub in invalid {
            let posts = CatalogTestCounter()
            let mock = CatalogMockSession { request in
                if request.httpMethod == "GET" { return CatalogStub(data: CatalogFixtures.bootstrap) }
                return posts.increment() == 1 ? stub : CatalogStub(data: data)
            }
            defer { mock.close() }
            let provider = YouTubeMusicService(session: mock.session)
            do { _ = try await provider.albumDescription(id: AlbumDescriptionFixtures.id); XCTFail("Expected response rejection") }
            catch { guard case MusicServiceError.invalidResponse = error else { return XCTFail("Unexpected error: \(error)") } }
            let recovered = try await provider.albumDescription(id: AlbumDescriptionFixtures.id)
            XCTAssertNotNil(recovered)
            XCTAssertEqual(mock.state.requests.filter { $0.httpMethod == "POST" }.count, 2)
        }
    }

    func testTotalDescriptionDeadlineCancelsThePendingRequest() async throws {
        let data = try AlbumDescriptionFixtures.page().encoded()
        let mock = CatalogMockSession { request in
            CatalogStub(data: request.httpMethod == "GET" ? CatalogFixtures.bootstrap : data,
                        delay: request.httpMethod == "GET" ? 0 : 3)
        }
        defer { mock.close() }
        let provider = YouTubeMusicService(session: mock.session, albumDescriptionTimeout: 0.3)
        let started = Date()
        do { _ = try await provider.albumDescription(id: AlbumDescriptionFixtures.id); XCTFail("Expected a deadline") }
        catch { guard case PlaybackStreamError.timedOut = error else { return XCTFail("Unexpected error: \(error)") } }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        try await PlaybackTestSupport.eventually(timeout: 2) { mock.state.cancellations >= 1 }
    }

    func testCancellationDoesNotCancelAnotherAlbumsRequestOrPublishAResult() async throws {
        let data = try AlbumDescriptionFixtures.page().encoded()
        let mock = CatalogMockSession { request in
            if request.httpMethod == "GET" { return CatalogStub(data: CatalogFixtures.bootstrap) }
            let id = try CatalogJSON.decode(request.httpBody ?? Data())["browseId"].string
            return CatalogStub(data: data, delay: id == AlbumDescriptionFixtures.id ? 3 : 0)
        }
        defer { mock.close() }
        let provider = YouTubeMusicService(session: mock.session)
        let first = Task { try await provider.albumDescription(id: AlbumDescriptionFixtures.id) }
        defer { first.cancel() }
        try await PlaybackTestSupport.eventually(timeout: 2) { mock.state.requests.contains { $0.httpMethod == "POST" } }
        let second = Task { try await provider.albumDescription(id: AlbumDescriptionFixtures.otherID) }
        first.cancel()
        do { _ = try await first.value; XCTFail("Cancelled descriptions must not return data") }
        catch { XCTAssertTrue(error is CancellationError) }
        let description = try await second.value
        XCTAssertEqual(description?.albumID, AlbumDescriptionFixtures.otherID)
        try await PlaybackTestSupport.eventually(timeout: 2) { mock.state.cancellations >= 1 }
    }

    func testUnsupportedIDsAndAlreadyCancelledCallersStartNoNetworkWork() async throws {
        let mock = CatalogMockSession { _ in throw URLError(.unsupportedURL) }
        defer { mock.close() }
        let provider = YouTubeMusicService(session: mock.session)
        for id in ["", "VLplaylist", CatalogFixtures.arijitID, "MPREbad/album", String(repeating: "x", count: 300)] {
            let result = try await provider.albumDescription(id: id)
            XCTAssertNil(result)
        }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await provider.albumDescription(id: AlbumDescriptionFixtures.id)
        }
        do { _ = try await cancelled.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(mock.state.requests.isEmpty)
    }
}

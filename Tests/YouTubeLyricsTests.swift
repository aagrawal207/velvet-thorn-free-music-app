import XCTest
@testable import GanaBajana

@MainActor
final class YouTubeLyricsTests: XCTestCase {
    func testRecordingLinkedLyricsStayPlainAndPreserveTypedAttributionAndSourceLink() async throws {
        let track = LyricsFallbackFixtures.track
        for (footer, source) in [("Source: LyricFind", LyricsSource.lyricFind), ("Source: Musixmatch", .musixmatch), ("", .youTubeMusic)] {
            let next = try LyricsFallbackFixtures.next().encoded()
            let lyrics = try LyricsFallbackFixtures.lyrics(footer: footer).encoded()
            let mock = CatalogMockSession { request in
                if request.httpMethod == "GET" { return CatalogStub(data: CatalogFixtures.bootstrap) }
                return CatalogStub(data: request.url?.path.hasSuffix("/next") == true ? next : lyrics)
            }
            defer { mock.close() }
            let result = try await YouTubeMusicService(session: mock.session).lyrics(for: track)
            XCTAssertEqual(result.kind, .plain)
            XCTAssertEqual(result.providerSource, source)
            XCTAssertEqual(result.sourceURL, track.shareURL)
            XCTAssertNil(result.sourceID)
            XCTAssertTrue(result.lines.isEmpty)
            XCTAssertEqual(result.matchedTitle, track.title)
            let requests = mock.state.requests.filter { $0.httpMethod == "POST" }
            XCTAssertEqual(requests.count, 2)
            let body = try CatalogJSON.decode(try XCTUnwrap(requests.last?.httpBody))
            XCTAssertEqual(body["browseId"].string, "MPLYfixture-1")
            XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == nil && $0.value(forHTTPHeaderField: "Authorization") == nil })
            let rebound = try JSONDecoder().decode(LyricsDocument.self, from: JSONEncoder().encode(result))
            XCTAssertEqual(rebound.sourceURL, result.sourceURL)
            XCTAssertEqual(rebound.providerSource, source)
        }
    }

    func testDisabledLyricsTabIsUnavailableWithoutAnotherRequest() async throws {
        let next = try LyricsFallbackFixtures.next(disabled: true).encoded()
        let mock = CatalogMockSession { request in
            CatalogStub(data: request.httpMethod == "GET" ? CatalogFixtures.bootstrap : next)
        }
        defer { mock.close() }
        let document = try await YouTubeMusicService(session: mock.session).lyrics(for: LyricsFallbackFixtures.track)
        XCTAssertEqual(document.kind, .unavailable)
        XCTAssertEqual(mock.state.requests.filter { $0.httpMethod == "POST" }.count, 1)
    }

    func testCurrentRecordingMismatchAndUnrelatedBrowseEndpointAreRejected() throws {
        XCTAssertThrowsError(try YouTubeLyricsParser.link(in: LyricsFallbackFixtures.next(currentID: "J7p4bzqLvCw"), for: LyricsFallbackFixtures.track))
        XCTAssertThrowsError(try YouTubeLyricsParser.link(in: LyricsFallbackFixtures.next(browseID: "MPREalbum"), for: LyricsFallbackFixtures.track))
        var wrong = LyricsFallbackFixtures.track
        wrong.title = "A different song"
        XCTAssertThrowsError(try YouTubeLyricsParser.link(in: LyricsFallbackFixtures.next(), for: wrong))
        let link = try XCTUnwrap(YouTubeLyricsParser.link(in: LyricsFallbackFixtures.next(), for: LyricsFallbackFixtures.track))
        wrong.id = "J7p4bzqLvCw"
        XCTAssertThrowsError(try YouTubeLyricsParser.document(LyricsFallbackFixtures.lyrics(), linkedBy: link, for: wrong, fetchedAt: Date()))
    }

    func testEmptyLyricsAreMissingButMalformedOrNestedLyricsAreNotAccepted() throws {
        let track = LyricsFallbackFixtures.track
        let link = try XCTUnwrap(YouTubeLyricsParser.link(in: LyricsFallbackFixtures.next(), for: track))
        let empty = try YouTubeLyricsParser.document(LyricsFallbackFixtures.lyrics(text: " "), linkedBy: link, for: track, fetchedAt: Date())
        XCTAssertEqual(empty.kind, .unavailable)
        XCTAssertThrowsError(try YouTubeLyricsParser.document(["error": ["code": 500]], linkedBy: link, for: track, fetchedAt: Date()))
        let nested: CatalogJSON = ["contents": ["sectionListRenderer": ["contents": [["musicCarouselShelfRenderer": [
            "contents": [LyricsFallbackFixtures.lyrics()],
        ]]]]]]
        XCTAssertThrowsError(try YouTubeLyricsParser.document(nested, linkedBy: link, for: track, fetchedAt: Date()))
    }

    func testCancellingTheNextRequestNeverStartsTheLyricsBrowse() async throws {
        let next = try LyricsFallbackFixtures.next().encoded()
        let mock = CatalogMockSession { request in
            if request.httpMethod == "GET" { return CatalogStub(data: CatalogFixtures.bootstrap) }
            return CatalogStub(data: next, delay: 2)
        }
        defer { mock.close() }
        let service = YouTubeMusicService(session: mock.session)
        let task = Task { try await service.lyrics(for: LyricsFallbackFixtures.track) }
        try await AppModelFixtures.eventually { mock.state.requests.contains { $0.url?.path.hasSuffix("/next") == true } }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        XCTAssertFalse(mock.state.requests.contains { $0.url?.path.hasSuffix("/browse") == true })
    }
}

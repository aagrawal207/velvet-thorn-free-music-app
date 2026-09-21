import XCTest
@testable import GanaBajana

@MainActor
final class ArtistSpotlightMonthlyAudienceTests: XCTestCase {
    func testServicePropagatesMonthlyAudienceIndependentlyOfSongPlays() async throws {
        var router = CatalogMockRouter()
        router.browse[ArtistSpotlightMonthlyAudienceFixtures.artistID] = try ArtistSpotlightMonthlyAudienceFixtures.response().encoded()
        let mock = CatalogMockSession { [router] request in try router.stub(request) }
        defer { mock.close() }
        let artist = try await YouTubeMusicService(session: mock.session).artist(id: ArtistSpotlightMonthlyAudienceFixtures.artistID)
        XCTAssertEqual(artist.name, ArtistSpotlightMonthlyAudienceFixtures.name)
        XCTAssertEqual(artist.monthlyAudience?.value, 12_300_000)
        XCTAssertEqual(artist.monthlyAudience?.label, "12.3M monthly audience")
        XCTAssertEqual(artist.monthlyAudience?.kind, .audience)
        XCTAssertEqual(artist.monthlyAudience?.source, .headerCount)
        XCTAssertEqual(artist.topSongs.first?.playCount, 1_200_000_000)
        XCTAssertEqual(artist.relatedArtists.first?.subtitle, "999M monthly audience")
    }

    func testHeaderCacheExpiryClearsAnOmittedMonthlyCountRatherThanKeepingItOrUsingLifetimePlays() async throws {
        let clock = CatalogTestClock()
        let counter = CatalogTestCounter()
        let present = try ArtistSpotlightMonthlyAudienceFixtures.response().encoded()
        let absent = try ArtistSpotlightMonthlyAudienceFixtures.response(monthlyLabel: nil).encoded()
        let mock = CatalogMockSession { request in
            if request.httpMethod == "GET" { return CatalogStub(data: CatalogFixtures.bootstrap) }
            return CatalogStub(data: counter.increment() == 1 ? present : absent)
        }
        defer { mock.close() }
        let service = YouTubeMusicService(session: mock.session, now: { clock.now })
        let initial = try await service.artist(id: ArtistSpotlightMonthlyAudienceFixtures.artistID)
        XCTAssertEqual(initial.monthlyAudience?.value, 12_300_000)
        let cached = try await service.artist(id: ArtistSpotlightMonthlyAudienceFixtures.artistID)
        XCTAssertEqual(cached.monthlyAudience, initial.monthlyAudience)
        XCTAssertEqual(mock.state.requests.filter { $0.httpMethod == "POST" }.count, 1)
        clock.advance(601)
        let refreshed = try await service.artist(id: ArtistSpotlightMonthlyAudienceFixtures.artistID)
        XCTAssertNil(refreshed.monthlyAudience)
        XCTAssertEqual(refreshed.topSongs.first?.playCount, 1_200_000_000)
        XCTAssertEqual(mock.state.requests.filter { $0.httpMethod == "POST" }.count, 2)
    }

    func testMonthlyAudienceAlwaysUsesTheInitialArtistHeaderRatherThanAContinuation() async throws {
        var first = try ArtistSpotlightMonthlyAudienceFixtures.response().object
        first["contents"] = ["singleColumnBrowseResultsRenderer": ["tabs": [["tabRenderer": ["content": ["sectionListRenderer": [
            "contents": [["musicShelfRenderer": [
                "contents": [], "continuations": [["nextContinuationData": ["continuation": "more-songs"]]],
            ]]],
        ]]]]]]]
        let initial = try CatalogJSON.object(first).encoded()
        let continuation: CatalogJSON = [
            "header": ["musicImmersiveHeaderRenderer": ArtistSpotlightMonthlyAudienceFixtures.header(monthlyLabel: "999M monthly listeners")],
            "continuationContents": ["musicShelfContinuation": ["contents": []]],
        ]
        let next = try continuation.encoded()
        let mock = CatalogMockSession { request in
            if request.httpMethod == "GET" { return CatalogStub(data: CatalogFixtures.bootstrap) }
            let body = try CatalogJSON.decode(request.httpBody ?? Data())
            return CatalogStub(data: body["continuation"].string == nil ? initial : next)
        }
        defer { mock.close() }
        let artist = try await YouTubeMusicService(session: mock.session).artist(id: ArtistSpotlightMonthlyAudienceFixtures.artistID)
        XCTAssertEqual(artist.monthlyAudience?.value, 12_300_000)
        XCTAssertEqual(artist.monthlyAudience?.kind, .audience)
        XCTAssertEqual(mock.state.requests.filter { $0.httpMethod == "POST" }.count, 2)
    }
}

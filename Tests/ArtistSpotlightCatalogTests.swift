import XCTest
@testable import GanaBajana

@MainActor
final class ArtistSpotlightCatalogTests: XCTestCase {
    func testEveryAvailableTopSongSurvivesAndCompleteListingNeedsNoEnrichment() async throws {
        let catalog = ArtistSpotlightCatalogFixture()
        addTeardownBlock { await catalog.close() }
        let songs = (0..<35).map { ArtistSpotlightTestSupport.track("song-\($0)", count: Int64($0)) }
        let service = ArtistSpotlightCatalogService(catalog: catalog)
        let outcome = try await service.load(ArtistSpotlightTestSupport.page(songs))
        XCTAssertEqual(outcome.tracks.count, 35)
        XCTAssertEqual(outcome.tracks.first?.playCount, 34)
        XCTAssertEqual(outcome.tracks.last?.playCount, 0)
        XCTAssertFalse(outcome.hadFailures)
        let searches = await catalog.searches.requests
        let albums = await catalog.albums.requests
        XCTAssertTrue(searches.isEmpty)
        XCTAssertTrue(albums.isEmpty)
    }

    func testSparseListingUsesBoundedProviderPagesAndListedAlbumsWithAllArtistCredits() async throws {
        let catalog = ArtistSpotlightCatalogFixture()
        addTeardownBlock { await catalog.close() }
        let seed = ArtistSpotlightTestSupport.track("top", count: 1_000)
        var collaboration = ArtistSpotlightTestSupport.track("collaboration", count: 800)
        collaboration.credits.insert(ArtistCredit(name: "Another Singer", id: "UCsinger"), at: 0)
        var unrelated = ArtistSpotlightTestSupport.track("unrelated", count: 10_000)
        unrelated.credits = [ArtistCredit(name: "Other Artist")]
        let releases = (0..<5).map { MusicCollection(id: "provider-album-\($0)", title: "Release \($0)", kind: .album) }
        var configuration = ArtistSpotlightTestSupport.catalogConfiguration(minimum: 20)
        configuration.maximumAlbumRequests = 2
        let service = ArtistSpotlightCatalogService(catalog: catalog, configuration: configuration)
        let page = ArtistSpotlightTestSupport.page([seed], releases: releases)
        let task = Task { try await service.load(page) }
        let first = try await catalog.searches.request(at: 0)
        XCTAssertEqual(first.input, AppModelSearchRequest(query: page.name, filter: .songs, continuation: nil))
        try await catalog.searches.complete(first, with: .success(CatalogPage(tracks: [collaboration, unrelated], continuation: "next-page")))
        let second = try await catalog.searches.request(at: 1)
        XCTAssertEqual(second.input.continuation, "next-page")
        try await catalog.searches.complete(second, with: .success(CatalogPage(tracks: [seed], continuation: "unused-page")))
        let albumA = try await catalog.albums.request(at: 0)
        let albumB = try await catalog.albums.request(at: 1)
        XCTAssertEqual(Set([albumA.input, albumB.input]), Set(releases.prefix(2).map(\.id)))
        try await catalog.albums.complete(albumB, with: .success(CatalogPage(tracks: [ArtistSpotlightTestSupport.track("album-b", count: 400), unrelated])))
        try await catalog.albums.complete(albumA, with: .success(CatalogPage(tracks: [ArtistSpotlightTestSupport.track("album-a", count: 600), seed])))
        let outcome = try await task.value
        XCTAssertEqual(outcome.tracks.map(\.id), ["top", "collaboration", "album-a", "album-b"])
        let searchCount = await catalog.searches.requests.count
        let albumCount = await catalog.albums.requests.count
        let concurrency = await catalog.maximumActiveRequests
        XCTAssertEqual(searchCount, 2)
        XCTAssertEqual(albumCount, 2)
        XCTAssertLessThanOrEqual(concurrency, 3)
    }

    func testCountEnrichmentIsBoundedAndUpdatesBeforeAllRequestsFinish() async throws {
        let catalog = ArtistSpotlightCatalogFixture()
        let progress = ArtistSpotlightProgress()
        addTeardownBlock { await catalog.close() }
        let songs = (0..<6).map { ArtistSpotlightTestSupport.track("missing-\($0)") }
        var configuration = ArtistSpotlightTestSupport.catalogConfiguration(countSearches: 3)
        configuration.maximumConcurrentRequests = 2
        let service = ArtistSpotlightCatalogService(catalog: catalog, configuration: configuration)
        let task = Task { try await service.load(ArtistSpotlightTestSupport.page(songs)) { await progress.append($0) } }
        let first = try await catalog.searches.request(at: 0)
        let second = try await catalog.searches.request(at: 1)
        XCTAssertEqual(first.input.filter, .songs)
        XCTAssertTrue(first.input.query.hasSuffix("A. R. Rahman"))
        let secondSong = try XCTUnwrap(songs.first { second.input.query.hasPrefix($0.title + " ") })
        var counted = secondSong
        counted.playCount = 900
        try await catalog.searches.complete(second, with: .success(CatalogPage(tracks: [counted])))
        try await AppModelFixtures.eventually { progress.updates.last?.first?.playCount == 900 }
        let third = try await catalog.searches.request(at: 2)
        let firstSong = try XCTUnwrap(songs.first { first.input.query.hasPrefix($0.title + " ") })
        let otherRecording = ArtistSpotlightTestSupport.track("different-recording", title: firstSong.title, count: 50_000)
        try await catalog.searches.complete(first, with: .success(CatalogPage(tracks: [otherRecording])))
        try await catalog.searches.complete(third, with: .failure(MusicServiceError.network("Synthetic failure")))
        let outcome = try await task.value
        XCTAssertEqual(outcome.tracks.first?.id, secondSong.id)
        XCTAssertEqual(outcome.tracks.filter { $0.playCount != nil }.count, 1)
        XCTAssertEqual(outcome.tracks.count, 6)
        XCTAssertTrue(outcome.hadFailures)
        let requests = await catalog.searches.requests
        let concurrency = await catalog.maximumActiveRequests
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(concurrency, 2)
    }

    func testCancellingDropsLateSupplementAndDoesNotFollowItsContinuation() async throws {
        let catalog = ArtistSpotlightCatalogFixture()
        let progress = ArtistSpotlightProgress()
        addTeardownBlock { await catalog.close() }
        let seed = ArtistSpotlightTestSupport.track("seed", count: 100)
        let service = ArtistSpotlightCatalogService(catalog: catalog)
        let task = Task { try await service.load(ArtistSpotlightTestSupport.page([seed])) { await progress.append($0) } }
        let request = try await catalog.searches.request(at: 0)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled enrichment completed") }
        catch is CancellationError { }
        try await catalog.searches.complete(request, with: .success(CatalogPage(
            tracks: [ArtistSpotlightTestSupport.track("stale", count: 10_000)], continuation: "must-not-follow")))
        let requests = await catalog.searches.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(progress.updates.last?.map(\.id), ["seed"])
    }

    func testDeadlinePreservesSongsWhenAProviderIgnoresCancellation() async throws {
        let catalog = ArtistSpotlightCatalogFixture()
        addTeardownBlock { await catalog.close() }
        var configuration = ArtistSpotlightTestSupport.catalogConfiguration(countSearches: 1)
        configuration.requestTimeout = 0.03
        configuration.totalTimeout = 0.1
        let seed = ArtistSpotlightTestSupport.track("seed")
        let service = ArtistSpotlightCatalogService(catalog: catalog, configuration: configuration)
        let task = Task { try await service.load(ArtistSpotlightTestSupport.page([seed])) }
        let request = try await catalog.searches.request(at: 0)
        let outcome = try await task.value
        XCTAssertEqual(outcome.tracks.map(\.id), ["seed"])
        XCTAssertNil(outcome.tracks.first?.playCount)
        XCTAssertTrue(outcome.hadFailures)
        var late = seed
        late.playCount = 90_000
        try await catalog.searches.complete(request, with: .success(CatalogPage(tracks: [late])))
    }
}

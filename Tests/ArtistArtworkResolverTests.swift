import UIKit
import XCTest
@testable import GanaBajana

@MainActor
final class ArtistArtworkResolverTests: XCTestCase {
    func testLinkedCreditUsesItsArtistIDAndHeaderPhotoWithoutSearching() async {
        let fixture = makeFixture()
        let credit = ArtistCredit(name: "Credited alias", id: "UCprimary")
        let photo = url("primary")
        await fixture.catalog.artists.enqueue(.success(ArtistPage(id: "UCprimary", name: "Canonical name", artworkURL: photo)))

        let image = await fixture.resolver.image(for: credit, maxPixels: 64)

        XCTAssertEqual(image?.cgImage?.width, 64)
        let requests = await fixture.catalog.artists.requests
        let searches = await fixture.catalog.searches.requests
        XCTAssertEqual(requests.map(\.input), ["UCprimary"])
        XCTAssertTrue(searches.isEmpty)
        XCTAssertEqual(fixture.images.state.requests.map(\.url), [photo])
    }

    func testNameOnlyCreditSelectsNormalizedExactArtistRatherThanEarlierSimilarNamesOrAlbums() async {
        let fixture = makeFixture()
        let photo = url("rahman")
        let page = CatalogPage(collections: [
            MusicCollection(id: "UCensemble", title: "A. R. Rahman Ensemble", artworkURL: url("ensemble"), kind: .artist),
            MusicCollection(id: "UCrehman", title: "AR Rehman", artworkURL: url("rehman"), kind: .artist),
            MusicCollection(id: "album", title: "AR Rahman", artworkURL: url("album"), kind: .album),
            MusicCollection(id: "UCrahman", title: "A.R. Rahman", artworkURL: photo, kind: .artist)
        ], continuation: "unused-next-page", correctedQuery: "AR Rehman")
        await fixture.catalog.searches.enqueue(.success(page))

        let image = await fixture.resolver.image(for: ArtistCredit(name: "  A. R. Rahman  "), maxPixels: 64)

        XCTAssertNotNil(image)
        let searches = await fixture.catalog.searches.requests
        XCTAssertEqual(searches.map(\.input), [AppModelSearchRequest(query: "A. R. Rahman", filter: .artists, continuation: nil)])
        let artists = await fixture.catalog.artists.requests
        XCTAssertTrue(artists.isEmpty, "A matched search thumbnail needs no artist-page or song-page fanout")
        XCTAssertEqual(fixture.images.state.requests.map(\.url), [photo])
    }

    func testFuzzyNamesAndProviderSpellingCorrectionsCannotSupplySomeoneElsesPhoto() async {
        let fixture = makeFixture()
        await fixture.catalog.searches.enqueue(.success(CatalogPage(collections: [
            MusicCollection(id: "UCrehman", title: "AR Rehman", artworkURL: url("rehman"), kind: .artist),
            MusicCollection(id: "UCensemble", title: "AR Rahman Ensemble", artworkURL: url("ensemble"), kind: .artist)
        ], correctedQuery: "AR Rehman")))

        let image = await fixture.resolver.image(for: ArtistCredit(name: "A. R. Rahman"), maxPixels: 64)

        XCTAssertNil(image)
        XCTAssertTrue(fixture.images.state.requests.isEmpty)
        let artists = await fixture.catalog.artists.requests
        XCTAssertTrue(artists.isEmpty)
    }

    func testMismatchedArtistPageIDDoesNotSupplyArtworkOrFallBackToSearch() async {
        let fixture = makeFixture()
        await fixture.catalog.artists.enqueue(.success(ArtistPage(id: "UCwrong", name: "Same name", artworkURL: url("wrong"))))

        let image = await fixture.resolver.image(for: ArtistCredit(name: "Same name", id: "UCrequested"), maxPixels: 64)

        XCTAssertNil(image)
        XCTAssertTrue(fixture.images.state.requests.isEmpty)
        let searches = await fixture.catalog.searches.requests
        XCTAssertTrue(searches.isEmpty)
    }

    func testMissingHeaderPhotoNeverSubstitutesSongReleaseOrRelatedArtistArtwork() async {
        let fixture = makeFixture()
        let credit = ArtistCredit(name: "No portrait", id: "UCmissing")
        let page = ArtistPage(id: "UCmissing", name: credit.name,
                              topSongs: [Track(id: "song", title: "Song", credits: [credit], artworkURL: url("song"))],
                              releases: [MusicCollection(id: "album", title: "Album", artworkURL: url("album"), kind: .album)],
                              relatedArtists: [MusicCollection(id: "UCother", title: "Other", artworkURL: url("other"), kind: .artist)])
        await fixture.catalog.artists.enqueue(.success(page))

        let image = await fixture.resolver.image(for: credit, maxPixels: 64)
        let cached = await fixture.resolver.image(for: credit, maxPixels: 64)

        XCTAssertNil(image)
        XCTAssertNil(cached)
        XCTAssertTrue(fixture.images.state.requests.isEmpty)
        let requests = await fixture.catalog.artists.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testExactNameWithoutArtworkDoesNotStartAnotherLookup() async {
        let fixture = makeFixture()
        await fixture.catalog.searches.enqueue(.success(CatalogPage(collections: [
            MusicCollection(id: "UCmissing", title: "No portrait", kind: .artist)
        ], continuation: "more-artists")))

        let image = await fixture.resolver.image(for: ArtistCredit(name: "No portrait"), maxPixels: 64)

        XCTAssertNil(image)
        let searches = await fixture.catalog.searches.requests
        let artists = await fixture.catalog.artists.requests
        XCTAssertEqual(searches.count, 1)
        XCTAssertTrue(artists.isEmpty)
        XCTAssertTrue(fixture.images.state.requests.isEmpty)
    }

    func testEmptyCreditsAndAlreadyCancelledCallersDoNotStartWork() async {
        let fixture = makeFixture()
        for name in ["", " \n ", "..."] {
            let image = await fixture.resolver.image(for: ArtistCredit(name: name, id: " "), maxPixels: 64)
            XCTAssertNil(image)
        }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await fixture.resolver.image(for: ArtistCredit(name: "Artist", id: "UCartist"), maxPixels: 64)
        }
        let image = await cancelled.value
        XCTAssertNil(image)
        let artists = await fixture.catalog.artists.requests
        let searches = await fixture.catalog.searches.requests
        XCTAssertTrue(artists.isEmpty)
        XCTAssertTrue(searches.isEmpty)
        XCTAssertTrue(fixture.images.state.requests.isEmpty)
    }

    func testRepeatedLinkedCreditReusesCatalogAndDecodedArtworkCachesAcrossNameChanges() async {
        let fixture = makeFixture()
        await fixture.catalog.artists.enqueue(.success(ArtistPage(id: "UCartist", name: "Artist", artworkURL: url("artist"))))

        let first = await fixture.resolver.image(for: ArtistCredit(name: "Artist", id: "UCartist"), maxPixels: 64)
        let second = await fixture.resolver.image(for: ArtistCredit(name: "Credited alias", id: "UCartist"), maxPixels: 64)

        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertTrue(first === second, "The resolver should reuse ArtworkLoader's decoded bitmap")
        let artists = await fixture.catalog.artists.requests
        XCTAssertEqual(artists.count, 1)
        XCTAssertEqual(fixture.images.state.requests.count, 1)

        _ = await fixture.artworkLoader.clearCache()
        let reloaded = await fixture.resolver.image(for: ArtistCredit(name: "Artist", id: "UCartist"), maxPixels: 64)
        XCTAssertNotNil(reloaded)
        let afterClear = await fixture.catalog.artists.requests
        XCTAssertEqual(afterClear.count, 1, "Clearing decoded images does not require finding the artist again")
        XCTAssertEqual(fixture.images.state.requests.count, 2)
    }

    func testNormalizedNameCacheDoesNotAliasAnIDBearingCreditWithTheSameName() async {
        let fixture = makeFixture()
        await fixture.catalog.searches.enqueue(.success(CatalogPage(collections: [
            MusicCollection(id: "UCname", title: "A.R. Rahman", artworkURL: url("name-result"), kind: .artist)
        ])))
        await fixture.catalog.artists.enqueue(.success(ArtistPage(id: "UCknown", name: "A.R. Rahman", artworkURL: url("known-id"))))

        let named = await fixture.resolver.image(for: ArtistCredit(name: "A. R. Rahman"), maxPixels: 64)
        let normalized = await fixture.resolver.image(for: ArtistCredit(name: "ar rahman"), maxPixels: 64)
        let linked = await fixture.resolver.image(for: ArtistCredit(name: "AR Rahman", id: "UCknown"), maxPixels: 64)

        XCTAssertNotNil(named)
        XCTAssertTrue(named === normalized)
        XCTAssertNotNil(linked)
        let searches = await fixture.catalog.searches.requests
        let artists = await fixture.catalog.artists.requests
        XCTAssertEqual(searches.count, 1)
        XCTAssertEqual(artists.map(\.input), ["UCknown"])
        XCTAssertEqual(fixture.images.state.requests.map(\.url), [url("name-result"), url("known-id")])
    }

    func testMissingAndFailedCatalogResultsExpireWithoutExtendingTheNegativeTTLOnReuse() async {
        for fails in [false, true] {
            let fixture = makeFixture()
            let credit = ArtistCredit(name: "Retry artist", id: "UCretry")
            await fixture.catalog.artists.enqueue(fails ? .failure(URLError(.notConnectedToInternet))
                : .success(ArtistPage(id: "UCretry", name: credit.name)))
            await fixture.catalog.artists.enqueue(.success(ArtistPage(id: "UCretry", name: credit.name, artworkURL: url("recovered"))))

            let first = await fixture.resolver.image(for: credit, maxPixels: 64)
            fixture.clock.advance(29)
            let repeated = await fixture.resolver.image(for: credit, maxPixels: 64)
            XCTAssertNil(first)
            XCTAssertNil(repeated)
            let beforeExpiry = await fixture.catalog.artists.requests
            XCTAssertEqual(beforeExpiry.count, 1)

            fixture.clock.advance(2)
            let recovered = await fixture.resolver.image(for: credit, maxPixels: 64)
            XCTAssertNotNil(recovered)
            let afterExpiry = await fixture.catalog.artists.requests
            XCTAssertEqual(afterExpiry.count, 2)
            XCTAssertEqual(fixture.images.state.requests.count, 1)
        }
    }

    func testFailedOrUndecodableImageGetsAShortNegativeCacheAndCanRecover() async {
        for invalidBody in [false, true] {
            let count = CatalogTestCounter()
            let png = imageData()
            let fixture = makeFixture { _ in
                if count.increment() == 1 {
                    return CatalogStub(status: invalidBody ? 200 : 404, headers: ["Content-Type": "image/png"], data: Data("not an image".utf8))
                }
                return CatalogStub(headers: ["Content-Type": "image/png"], data: png)
            }
            let credit = ArtistCredit(name: "Artist", id: "UCartist")
            let page = ArtistPage(id: "UCartist", name: credit.name, artworkURL: url("retry-image"))
            await fixture.catalog.artists.enqueue(.success(page))
            await fixture.catalog.artists.enqueue(.success(page))

            let first = await fixture.resolver.image(for: credit, maxPixels: 64)
            let repeated = await fixture.resolver.image(for: credit, maxPixels: 64)
            XCTAssertNil(first)
            XCTAssertNil(repeated)
            XCTAssertEqual(fixture.images.state.requests.count, 1)
            let beforeExpiry = await fixture.catalog.artists.requests
            XCTAssertEqual(beforeExpiry.count, 1)

            fixture.clock.advance(31)
            let recovered = await fixture.resolver.image(for: credit, maxPixels: 64)
            XCTAssertNotNil(recovered)
            XCTAssertEqual(fixture.images.state.requests.count, 2)
            let afterExpiry = await fixture.catalog.artists.requests
            XCTAssertEqual(afterExpiry.count, 2)
        }
    }

    func testResolverInstancesCannotShareArtistIdentitiesOrNegativeEntries() async {
        let first = makeFixture()
        let second = makeFixture()
        let credit = ArtistCredit(name: "Same fixture identity", id: "UCsame")
        await first.catalog.artists.enqueue(.success(ArtistPage(id: "UCsame", name: credit.name)))
        await second.catalog.artists.enqueue(.success(ArtistPage(id: "UCsame", name: credit.name, artworkURL: url("second-catalog"))))

        let missing = await first.resolver.image(for: credit, maxPixels: 64)
        let available = await second.resolver.image(for: credit, maxPixels: 64)
        let stillMissing = await first.resolver.image(for: credit, maxPixels: 64)

        XCTAssertNil(missing)
        XCTAssertNotNil(available)
        XCTAssertNil(stillMissing)
        let firstRequests = await first.catalog.artists.requests
        let secondRequests = await second.catalog.artists.requests
        XCTAssertEqual(firstRequests.count, 1)
        XCTAssertEqual(secondRequests.count, 1)
        XCTAssertTrue(first.images.state.requests.isEmpty)
        XCTAssertEqual(second.images.state.requests.map(\.url), [url("second-catalog")])
    }

    func testURLCacheEvictsLeastRecentlyUsedEntries() async {
        let fixture = makeFixture(maximumCacheEntries: 2)
        for id in ["A", "B", "C", "B"] {
            await fixture.catalog.artists.enqueue(.success(ArtistPage(id: id, name: id, artworkURL: url(id))))
        }
        for id in ["A", "B", "A", "C", "B"] {
            let image = await fixture.resolver.image(for: ArtistCredit(name: id, id: id), maxPixels: 64)
            XCTAssertNotNil(image)
        }

        let requests = await fixture.catalog.artists.requests
        XCTAssertEqual(requests.map(\.input), ["A", "B", "C", "B"])
        XCTAssertEqual(fixture.images.state.requests.count, 3, "Bitmap reuse remains ArtworkLoader's responsibility after URL eviction")
    }

    func testOnlyTwoCompleteLookupsRunEvenWhenMetadataIsFastAndImagesArePending() async throws {
        let gate = AppModelRequestGate<URL, Bool>()
        addTeardownBlock { await gate.close() }
        let png = imageData()
        let fixture = makeFixture { request in
            let url = try XCTUnwrap(request.url)
            return CatalogStub(headers: ["Content-Type": "image/png"], data: png,
                               beforeDelivery: { _ = try await gate.receive(url) })
        }
        for id in ["A", "B", "C"] {
            await fixture.catalog.artists.enqueue(.success(ArtistPage(id: id, name: id, artworkURL: url(id))))
        }
        let first = start(fixture, id: "A")
        let firstImage = try await gate.request(at: 0)
        let second = start(fixture, id: "B")
        let secondImage = try await gate.request(at: 1)
        let third = start(fixture, id: "C")
        try await Task.sleep(for: .milliseconds(50))

        let pending = await fixture.catalog.artists.requests
        XCTAssertEqual(pending.map(\.input), ["A", "B"])
        XCTAssertEqual(fixture.images.state.requests.count, 2)
        try await gate.complete(firstImage, with: .success(true))
        let thirdImage = try await gate.request(at: 2)
        let afterRelease = await fixture.catalog.artists.requests
        XCTAssertEqual(afterRelease.map(\.input), ["A", "B", "C"])
        try await gate.complete(secondImage, with: .success(true))
        try await gate.complete(thirdImage, with: .success(true))
        for task in [first, second, third] {
            let image = await task.value
            XCTAssertNotNil(image)
        }
    }

    func testCancellingAQueuedLookupDoesNotCallTheProviderOrPoisonAReopenedRow() async throws {
        let fixture = makeFixture()
        let first = start(fixture, id: "A")
        let firstRequest = try await fixture.catalog.artists.request(at: 0)
        let second = start(fixture, id: "B")
        let secondRequest = try await fixture.catalog.artists.request(at: 1)
        let queued = start(fixture, id: "C")
        try await Task.sleep(for: .milliseconds(50))
        queued.cancel()
        let cancelled = await queued.value
        XCTAssertNil(cancelled)
        let pending = await fixture.catalog.artists.requests
        XCTAssertEqual(pending.map(\.input), ["A", "B"])

        try await fixture.catalog.artists.complete(firstRequest, with: .success(ArtistPage(id: "A", name: "A")))
        _ = await first.value
        let reopened = start(fixture, id: "C")
        let fresh = try await fixture.catalog.artists.request(at: 2)
        XCTAssertEqual(fresh.input, "C")
        try await fixture.catalog.artists.complete(fresh, with: .success(ArtistPage(id: "C", name: "C", artworkURL: url("C"))))
        let image = await reopened.value
        XCTAssertNotNil(image)
        try await fixture.catalog.artists.complete(secondRequest, with: .success(ArtistPage(id: "B", name: "B")))
        _ = await second.value
    }

    func testCancelledCatalogResponseCannotLoadOrCacheStaleArtworkAfterReopen() async throws {
        let fixture = makeFixture()
        let first = start(fixture, id: "same")
        let old = try await fixture.catalog.artists.request(at: 0)
        first.cancel()
        let cancelled = await first.value
        XCTAssertNil(cancelled)

        let reopened = start(fixture, id: "same")
        let fresh = try await fixture.catalog.artists.request(at: 1)
        try await fixture.catalog.artists.complete(old, with: .success(ArtistPage(id: "same", name: "Same", artworkURL: url("stale"))))
        try await fixture.catalog.artists.complete(fresh, with: .success(ArtistPage(id: "same", name: "Same", artworkURL: url("fresh"))))
        let image = await reopened.value
        let cached = await fixture.resolver.image(for: ArtistCredit(name: "Same", id: "same"), maxPixels: 64)

        XCTAssertNotNil(image)
        XCTAssertTrue(image === cached)
        XCTAssertEqual(fixture.images.state.requests.map(\.url), [url("fresh")])
        let requests = await fixture.catalog.artists.requests
        XCTAssertEqual(requests.count, 2)
    }

    func testCancellationDuringImageTransferStopsItAndAllowsImmediateRetry() async throws {
        let gate = AppModelRequestGate<URL, Bool>()
        addTeardownBlock { await gate.close() }
        let png = imageData()
        let fixture = makeFixture { request in
            let url = try XCTUnwrap(request.url)
            return CatalogStub(headers: ["Content-Type": "image/png"], data: png,
                               beforeDelivery: { _ = try await gate.receive(url) })
        }
        let page = ArtistPage(id: "same", name: "Same", artworkURL: url("same"))
        await fixture.catalog.artists.enqueue(.success(page))
        await fixture.catalog.artists.enqueue(.success(page))
        let first = start(fixture, id: "same")
        let oldImage = try await gate.request(at: 0)
        first.cancel()
        let cancelled = await first.value
        XCTAssertNil(cancelled)
        try await AppModelFixtures.eventually { fixture.images.state.cancellations == 1 }

        let retry = start(fixture, id: "same")
        let freshImage = try await gate.request(at: 1)
        try await gate.complete(oldImage, with: .success(true))
        try await gate.complete(freshImage, with: .success(true))
        let image = await retry.value
        XCTAssertNotNil(image)
        let requests = await fixture.catalog.artists.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(fixture.images.state.requests.count, 2)
    }

    func testDeadlineReturnsWithoutAnUncooperativeProviderAndLateResultsCannotReplaceTheNegativeEntry() async throws {
        let fixture = makeFixture(lookupTimeout: 0.5)
        let started = ContinuousClock.now
        let work = start(fixture, id: "slow")
        let old = try await fixture.catalog.artists.request(at: 0)
        let missing = await work.value
        XCTAssertNil(missing)
        XCTAssertLessThan(started.duration(to: .now), .seconds(2))

        try await fixture.catalog.artists.complete(old, with: .success(ArtistPage(id: "slow", name: "Slow", artworkURL: url("too-late"))))
        let cached = await fixture.resolver.image(for: ArtistCredit(name: "Slow", id: "slow"), maxPixels: 64)
        XCTAssertNil(cached)
        XCTAssertTrue(fixture.images.state.requests.isEmpty)
        let beforeExpiry = await fixture.catalog.artists.requests
        XCTAssertEqual(beforeExpiry.count, 1)

        fixture.clock.advance(31)
        await fixture.catalog.artists.enqueue(.success(ArtistPage(id: "slow", name: "Slow", artworkURL: url("on-retry"))))
        let recovered = await fixture.resolver.image(for: ArtistCredit(name: "Slow", id: "slow"), maxPixels: 64)
        XCTAssertNotNil(recovered)
        XCTAssertEqual(fixture.images.state.requests.map(\.url), [url("on-retry")])
    }

    func testQueueTimeCountsAgainstDeadlineAndCancelledProvidersKeepTheirConcurrencySlots() async throws {
        let fixture = makeFixture(lookupTimeout: 0.5)
        let first = start(fixture, id: "A")
        let firstRequest = try await fixture.catalog.artists.request(at: 0)
        let second = start(fixture, id: "B")
        let secondRequest = try await fixture.catalog.artists.request(at: 1)
        let third = start(fixture, id: "C")
        for task in [first, second, third] {
            let image = await task.value
            XCTAssertNil(image)
        }
        let requests = await fixture.catalog.artists.requests
        XCTAssertEqual(requests.map(\.input), ["A", "B"], "A timed-out provider must not be replaced by unbounded background work")
        try await fixture.catalog.artists.complete(firstRequest, with: .success(ArtistPage(id: "A", name: "A")))
        try await fixture.catalog.artists.complete(secondRequest, with: .success(ArtistPage(id: "B", name: "B")))
        XCTAssertTrue(fixture.images.state.requests.isEmpty)
    }

    func testImageTransferDeadlineCancelsTheLoaderAndNegativeCachesItsFailure() async throws {
        let count = CatalogTestCounter()
        let png = imageData()
        let fixture = makeFixture(lookupTimeout: 0.5) { _ in
            CatalogStub(headers: ["Content-Type": "image/png"], data: png, delay: count.increment() == 1 ? 5 : 0)
        }
        let credit = ArtistCredit(name: "Image timeout", id: "UCimage")
        let page = ArtistPage(id: "UCimage", name: credit.name, artworkURL: url("image-timeout"))
        await fixture.catalog.artists.enqueue(.success(page))
        await fixture.catalog.artists.enqueue(.success(page))
        let started = ContinuousClock.now

        let missing = await fixture.resolver.image(for: credit, maxPixels: 64)

        XCTAssertNil(missing)
        XCTAssertLessThan(started.duration(to: .now), .seconds(2))
        try await AppModelFixtures.eventually { fixture.images.state.cancellations == 1 }
        let cached = await fixture.resolver.image(for: credit, maxPixels: 64)
        XCTAssertNil(cached)
        XCTAssertEqual(fixture.images.state.requests.count, 1)

        fixture.clock.advance(31)
        let recovered = await fixture.resolver.image(for: credit, maxPixels: 64)
        XCTAssertNotNil(recovered)
        XCTAssertEqual(fixture.images.state.requests.count, 2)
    }

    private struct Fixture {
        let catalog: AppModelCatalogProvider
        let images: CatalogMockSession
        let artworkLoader: ArtworkLoader
        let clock: CatalogTestClock
        let resolver: ArtistArtworkResolver
    }

    private func makeFixture(lookupTimeout: TimeInterval = 5, maximumCacheEntries: Int = 128,
                             imageResponse: CatalogMockState.Handler? = nil) -> Fixture {
        let catalog = AppModelCatalogProvider()
        let png = imageData()
        let images = CatalogMockSession(handler: imageResponse ?? { _ in
            CatalogStub(headers: ["Content-Type": "image/png"], data: png)
        })
        let artworkLoader = ArtworkLoader(session: images.session)
        let clock = CatalogTestClock()
        let resolver = ArtistArtworkResolver(catalog: catalog, artworkLoader: artworkLoader, lookupTimeout: lookupTimeout,
                                             maximumCacheEntries: maximumCacheEntries, now: { clock.now })
        addTeardownBlock {
            await catalog.close()
            _ = await artworkLoader.clearCache()
            images.close()
        }
        return Fixture(catalog: catalog, images: images, artworkLoader: artworkLoader, clock: clock, resolver: resolver)
    }

    private func start(_ fixture: Fixture, id: String) -> Task<UIImage?, Never> {
        let task = Task { await fixture.resolver.image(for: ArtistCredit(name: id, id: id), maxPixels: 64) }
        addTeardownBlock { task.cancel() }
        return task
    }

    private func url(_ name: String) -> URL { URL(string: "https://artist-artwork.test/\(name).png")! }

    private func imageData() -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64), format: format).pngData { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
    }
}

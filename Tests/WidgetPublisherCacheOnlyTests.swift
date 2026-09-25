import UIKit
import XCTest
@testable import GanaBajana

@MainActor
final class WidgetPublisherCacheOnlyTests: XCTestCase {
    func testCacheMissAndMissingResponseCacheNeverStartARequest() async throws {
        for cache in [nil, URLCache(memoryCapacity: 4 << 20, diskCapacity: 0, diskPath: nil)] as [URLCache?] {
            let (loader, state) = makeLoader(cache: cache)
            let result = await loader.cachedThumbnail(for: URL(string: "https://i.ytimg.com/vi/never-request/default.jpg")!)
            XCTAssertNil(result)
            XCTAssertTrue(state.requests.isEmpty)
            let usage = await loader.storageUsage()
            XCTAssertEqual(usage.pendingImages, 0)
            XCTAssertEqual(usage.decodedImages, 0)
        }
    }

    func testCachedThumbnailStandardLargeAndOriginalResponsesAreReencodedWithoutNetwork() async throws {
        let source = URL(string: "https://lh3.googleusercontent.com/widget-cover=w60-h60-l90-rj")!
        let cachedURLs = [ArtworkURL.Tier.thumbnail, .standard, .large].map { ArtworkURL.preferred(source, tier: $0) } + [source]
        let png = try XCTUnwrap(UIImage(data: WidgetSnapshotTestData.jpeg(width: 900, height: 600))?.pngData())
        for cachedURL in cachedURLs {
            let responses = URLCache(memoryCapacity: 4 << 20, diskCapacity: 0, diskPath: nil)
            let (loader, state) = makeLoader(cache: responses)
            seed(responses, url: cachedURL, data: png)

            let data = await loader.cachedThumbnail(for: source)

            let jpeg = try XCTUnwrap(data)
            XCTAssertTrue(WidgetLibrarySnapshot.isValidArtwork(jpeg))
            XCTAssertNotEqual(jpeg, png)
            XCTAssertEqual(Array(jpeg.prefix(2)), [0xFF, 0xD8])
            XCTAssertLessThanOrEqual(jpeg.count, 24 * 1024)
            let image = try XCTUnwrap(UIImage(data: jpeg)?.cgImage)
            XCTAssertEqual(image.width, 240)
            XCTAssertEqual(image.height, 160)
            XCTAssertTrue(state.requests.isEmpty)
            let usage = await loader.storageUsage()
            XCTAssertEqual(usage.pendingImages, 0)
            XCTAssertEqual(usage.decodedImages, 0, "Widget work does not populate the browsing bitmap cache")
        }
    }

    func testCachedFailuresCorruptionAndOversizedResponsesAreRejectedWithoutNetwork() async throws {
        let source = URL(string: "https://widget-artwork.invalid/invalid.png")!
        let image = WidgetSnapshotTestData.jpeg()
        let samples: [(data: Data, status: Int, length: Int?)] = [
            (image, 404, nil),
            (Data("not an image".utf8), 200, nil),
            (Data(), 200, nil),
            (image, 200, (12 << 20) + 1),
            (image + Data(count: (12 << 20) + 1 - image.count), 200, nil),
        ]
        for sample in samples {
            let responses = URLCache(memoryCapacity: 256 << 20, diskCapacity: 0, diskPath: nil)
            let (loader, state) = makeLoader(cache: responses)
            seed(responses, url: source, data: sample.data, status: sample.status, declaredLength: sample.length)
            let thumbnail = await loader.cachedThumbnail(for: source)
            XCTAssertNil(thumbnail)
            XCTAssertTrue(state.requests.isEmpty)
        }
    }

    func testInvalidFirstCachedCandidateFallsBackOnlyToAnotherCachedCandidate() async throws {
        let source = URL(string: "https://i.ytimg.com/vi/cached-candidates/default.jpg")!
        let responses = URLCache(memoryCapacity: 4 << 20, diskCapacity: 0, diskPath: nil)
        let (loader, state) = makeLoader(cache: responses)
        seed(responses, url: ArtworkURL.preferred(source, tier: .thumbnail), data: Data("bad image".utf8))
        seed(responses, url: ArtworkURL.preferred(source, tier: .standard), data: WidgetSnapshotTestData.jpeg(width: 300))
        let thumbnail = await loader.cachedThumbnail(for: source, maxPixels: 96)
        let image = try XCTUnwrap(UIImage(data: XCTUnwrap(thumbnail))?.cgImage)
        XCTAssertEqual(image.width, 96)
        XCTAssertTrue(state.requests.isEmpty)
    }

    func testCallerLimitsCannotExceedWidgetBoundsAndInvalidOrTinyBudgetsReturnNil() async throws {
        let source = URL(string: "https://widget-artwork.invalid/bounded.jpg")!
        let responses = URLCache(memoryCapacity: 4 << 20, diskCapacity: 0, diskPath: nil)
        let (loader, state) = makeLoader(cache: responses)
        seed(responses, url: source, data: WidgetSnapshotTestData.jpeg(width: 600, height: 400))
        let oversizedRequest = await loader.cachedThumbnail(for: source, maxPixels: Int.max, maximumBytes: Int.max)
        let jpeg = try XCTUnwrap(oversizedRequest)
        XCTAssertLessThanOrEqual(jpeg.count, 24 * 1024)
        XCTAssertLessThanOrEqual(try XCTUnwrap(UIImage(data: jpeg)?.cgImage).width, 240)
        let noPixels = await loader.cachedThumbnail(for: source, maxPixels: 0)
        let noBytes = await loader.cachedThumbnail(for: source, maximumBytes: 0)
        let tooFewBytes = await loader.cachedThumbnail(for: source, maximumBytes: 1)
        XCTAssertNil(noPixels)
        XCTAssertNil(noBytes)
        XCTAssertNil(tooFewBytes)
        XCTAssertTrue(state.requests.isEmpty)
    }

    func testClearedResponseCacheDoesNotRefillOnCacheOnlyRefresh() async throws {
        let source = URL(string: "https://widget-artwork.invalid/cleared.jpg")!
        let responses = URLCache(memoryCapacity: 4 << 20, diskCapacity: 0, diskPath: nil)
        let (loader, state) = makeLoader(cache: responses)
        seed(responses, url: source, data: WidgetSnapshotTestData.jpeg())
        let first = await loader.cachedThumbnail(for: source)
        XCTAssertNotNil(first)
        _ = await loader.clearCache()
        let afterClear = await loader.cachedThumbnail(for: source)
        XCTAssertNil(afterClear)
        XCTAssertNil(responses.cachedResponse(for: URLRequest(url: source)))
        XCTAssertTrue(state.requests.isEmpty)
    }

    private func makeLoader(cache: URLCache?) -> (ArtworkLoader, CatalogMockState) {
        let mock = CatalogMockSession { _ in CatalogStub(data: Data()) }
        let configuration = mock.session.configuration
        configuration.urlCache = cache
        let session = URLSession(configuration: configuration)
        let loader = ArtworkLoader(session: session)
        addTeardownBlock {
            _ = await loader.clearCache()
            session.invalidateAndCancel()
            mock.close()
        }
        return (loader, mock.state)
    }

    private func seed(_ cache: URLCache, url: URL, data: Data, status: Int = 200, declaredLength: Int? = nil) {
        var headers = ["Content-Type": "image/png", "Cache-Control": "max-age=3600"]
        if let declaredLength { headers["Content-Length"] = String(declaredLength) }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
        let request = URLRequest(url: url)
        cache.storeCachedResponse(CachedURLResponse(response: response, data: data, userInfo: nil,
                                                    storagePolicy: .allowedInMemoryOnly), for: request)
        XCTAssertNotNil(cache.cachedResponse(for: request))
    }
}

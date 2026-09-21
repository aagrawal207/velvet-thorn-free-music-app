import UIKit
import XCTest
@testable import GanaBajana

@MainActor
final class ArtworkStorageTests: XCTestCase {
    func testUsageAndClearCoverBothHTTPResponsesAndDecodedImagesWithoutInvalidatingDisplayedArt() async throws {
        let png = imageData()
        let mock = CatalogMockSession { _ in CatalogStub(headers: ["Content-Type": "image/png"], data: png) }
        let responses = URLCache(memoryCapacity: 4 << 20, diskCapacity: 0, diskPath: nil)
        let configuration = mock.session.configuration
        configuration.urlCache = responses
        let session = URLSession(configuration: configuration)
        let loader = ArtworkLoader(session: session)
        addTeardownBlock {
            _ = await loader.clearCache()
            session.invalidateAndCancel()
            mock.close()
        }
        let url = URL(string: "https://artwork-cache-test.invalid/cover.png")!
        let request = URLRequest(url: url)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"])!
        responses.storeCachedResponse(CachedURLResponse(response: response, data: png, userInfo: nil,
                                                        storagePolicy: .allowedInMemoryOnly), for: request)
        let loaded = await loader.image(for: url, tier: .thumbnail, maxPixels: 64)
        let displayed = try XCTUnwrap(loaded)
        let requestCount = mock.state.requests.count
        let repeated = await loader.image(for: url, tier: .thumbnail, maxPixels: 64)
        XCTAssertNotNil(repeated)
        XCTAssertEqual(mock.state.requests.count, requestCount, "The decoded image is reused")
        let usage = await loader.storageUsage()
        XCTAssertEqual(usage.decodedImages, 1)
        XCTAssertGreaterThan(usage.decodedBytes, 0)
        XCTAssertEqual(usage.responseMemoryBytes, Int64(responses.currentMemoryUsage))
        XCTAssertNotNil(responses.cachedResponse(for: request))
        XCTAssertEqual(usage.diskBytes, 0)
        XCTAssertEqual(usage.diskCapacity, 0)
        XCTAssertEqual(usage.responseMemoryCapacity, 4 << 20)
        XCTAssertEqual(usage.decodedCapacity, 96 << 20)

        let cleared = await loader.clearCache()

        XCTAssertEqual(cleared.decodedImages, 0)
        XCTAssertEqual(cleared.decodedBytes, 0)
        XCTAssertEqual(cleared.responseMemoryBytes, 0)
        XCTAssertEqual(cleared.diskBytes, 0)
        XCTAssertNil(responses.cachedResponse(for: request))
        XCTAssertEqual(displayed.cgImage?.width, 64, "A view's already loaded artwork stays usable")
    }

    func testClearCancelsPendingArtworkAndItCannotRefillTheCacheWithALateResult() async throws {
        let png = imageData()
        let counter = CatalogTestCounter()
        let mock = CatalogMockSession { _ in
            CatalogStub(headers: ["Content-Type": "image/png"], data: png, delay: counter.increment() == 1 ? 10 : 0)
        }
        let loader = ArtworkLoader(session: mock.session)
        addTeardownBlock {
            _ = await loader.clearCache()
            mock.close()
        }
        let url = URL(string: "https://artwork-cache-test.invalid/delayed.png")!
        let pending = Task { await loader.image(for: url, tier: .thumbnail, maxPixels: 64) }
        try await PlaybackTestSupport.eventually { mock.state.requests.count == 1 }
        let before = await loader.storageUsage()
        XCTAssertEqual(before.pendingImages, 1)

        let cleared = await loader.clearCache()
        let lateImage = await pending.value

        XCTAssertNil(lateImage)
        XCTAssertEqual(cleared.pendingImages, 0)
        XCTAssertEqual(cleared.decodedImages, 0)
        try await PlaybackTestSupport.eventually { mock.state.cancellations == 1 }
        let after = await loader.storageUsage()
        XCTAssertEqual(after.decodedBytes, 0)
        XCTAssertEqual(after.decodedImages, 0)
        let fresh = await loader.image(for: url, tier: .thumbnail, maxPixels: 64)
        XCTAssertNotNil(fresh, "New browsing still loads artwork after a clear")
        XCTAssertEqual(mock.state.requests.count, 2)
        let populated = await loader.storageUsage()
        XCTAssertEqual(populated.decodedImages, 1)
        XCTAssertGreaterThan(populated.decodedBytes, 0)
    }

    private func imageData() -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64), format: format).pngData { context in
            UIColor.systemPink.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
    }
}

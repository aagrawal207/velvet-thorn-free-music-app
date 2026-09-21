import UIKit
import XCTest
@testable import GanaBajana

@MainActor
final class ArtworkLoadingLimitTests: XCTestCase {
    func testOversizedDeclaredArtworkIsRejectedBeforeDecodingAndAFreshRequestCanRecover() async throws {
        let png = imageData()
        let requests = CatalogTestCounter()
        let mock = CatalogMockSession { _ in
            let length = requests.increment() == 1 ? (12 << 20) + 1 : png.count
            return CatalogStub(headers: ["Content-Type": "image/png", "Content-Length": String(length)], data: png)
        }
        let loader = ArtworkLoader(session: mock.session)
        addTeardownBlock {
            _ = await loader.clearCache()
            mock.close()
        }
        let url = URL(string: "https://artwork-limit-test.invalid/declared.png")!

        let rejected = await loader.image(for: url, tier: .thumbnail, maxPixels: 64)
        XCTAssertNil(rejected, "A valid image must still be rejected when its declared body exceeds 12 MiB")
        let empty = await loader.storageUsage()
        XCTAssertEqual(empty.decodedImages, 0)
        XCTAssertEqual(empty.decodedBytes, 0)
        XCTAssertEqual(empty.pendingImages, 0)

        let recovered = await loader.image(for: url, tier: .thumbnail, maxPixels: 64)
        XCTAssertEqual(recovered?.cgImage?.width, 64)
        XCTAssertEqual(mock.state.requests.count, 2, "Rejected artwork must not poison the decoded cache")
    }

    func testOversizedArtworkWithoutContentLengthIsRejectedBeforeDecoding() async throws {
        var body = imageData()
        body.append(Data(count: (12 << 20) + 1 - body.count))
        XCTAssertNotNil(UIImage(data: body), "The payload is decodable; this test must exercise the byte cap")
        let oversized = body
        let mock = CatalogMockSession { _ in CatalogStub(headers: ["Content-Type": "image/png"], data: oversized) }
        let loader = ArtworkLoader(session: mock.session)
        addTeardownBlock {
            _ = await loader.clearCache()
            mock.close()
        }

        let rejected = await loader.image(for: URL(string: "https://artwork-limit-test.invalid/unannounced.png")!,
                                          tier: .large, maxPixels: 1_080)

        XCTAssertNil(rejected, "Absent Content-Length must not bypass the received-body cap")
        XCTAssertEqual(mock.state.requests.count, 1)
        let usage = await loader.storageUsage()
        XCTAssertEqual(usage.decodedImages, 0)
        XCTAssertEqual(usage.decodedBytes, 0)
        XCTAssertEqual(usage.pendingImages, 0)
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

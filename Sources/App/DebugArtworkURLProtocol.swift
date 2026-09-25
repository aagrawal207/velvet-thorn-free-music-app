#if DEBUG
import Foundation
import UIKit

final class DebugArtworkURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var images: [String: Data] = [:]

    static var isEnabled: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--uitesting") && arguments.contains("--seed-ui")
            && arguments.contains("--artwork-fixture")
    }

    @MainActor
    static func install() {
        guard isEnabled else { return }
        let images = ["album": UIImage(named: "IconPreview-Thorn")?.pngData(),
                      "artist": UIImage(named: "IconPreview-Sonnet")?.pngData()]
            .compactMapValues { $0 }
        lock.withLock { Self.images = images }
    }

    static func url(_ kind: String) -> URL? {
        isEnabled ? URL(string: "https://breezy-artwork.invalid/\(kind)") : nil
    }

    override class func canInit(with request: URLRequest) -> Bool {
        isEnabled && request.url?.host == "breezy-artwork.invalid"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let data = Self.lock.withLock({ Self.images[url.lastPathComponent] }),
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": "image/png", "Content-Length": String(data.count)]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { }
}
#endif

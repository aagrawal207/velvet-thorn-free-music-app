import XCTest
@testable import GanaBajana

// This opt-in suite changes process-wide DNS policy; run it in a dedicated live-test process.
@MainActor
final class LyricsDNSLiveTests: XCTestCase {
    func testProductionServiceMatchesAllFiveRecordingsWithNativeEncryptedDNS() async throws {
        let resolver = try enableExplicitlySelectedResolver()
        let service = LRCLyricsService()
        for (track, sourceID) in LyricsTestFixtures.liveReferenceRecordings {
            let document = try await service.lyrics(for: track)
            XCTAssertEqual(document.kind, .synced, track.title)
            XCTAssertEqual(document.sourceID, sourceID, track.title)
            XCTAssertFalse(document.lines.isEmpty, track.title)
            XCTAssertTrue(document.lines.allSatisfy { $0.time >= 0 && $0.time <= (track.duration ?? 0) })
            print("Native \(resolver.rawValue): \(track.title), LRCLIB \(document.sourceID ?? 0), \(document.lines.count) synced lines")
        }
    }

    func testURLSessionKeepsProviderHostnameEncryptedDNSAndTLSWithoutAProxy() async throws {
        let resolver = try enableExplicitlySelectedResolver()
        let observer = LyricsDNSMetricsObserver()
        let session = URLSession(configuration: ephemeralConfiguration(), delegate: observer, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let url = try XCTUnwrap(URL(string: "https://lrclib.net/api/get/9910251"))
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("GanaBajana/1.0 (iOS; native LRCLIB client)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(response.url?.host, "lrclib.net")
        XCTAssertEqual(response.url?.scheme, "https")
        XCTAssertEqual(try JSONDecoder().decode(LRCLIBRecord.self, from: data).id, 9_910_251)
        for _ in 0..<100 where observer.transactions.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        let transactions = observer.transactions
        XCTAssertFalse(transactions.isEmpty)
        for transaction in transactions {
            XCTAssertEqual(transaction.host, "lrclib.net")
            XCTAssertTrue(transaction.hasTLS)
            XCTAssertFalse(transaction.isProxy)
            XCTAssertNotEqual(transaction.dns, .udp)
            XCTAssertNotEqual(transaction.dns, .tcp)
            print("Native \(resolver.rawValue): DNS protocol=\(transaction.dns.rawValue), TLS=\(transaction.hasTLS), proxy=\(transaction.isProxy)")
        }
    }

    func testEncryptedDNSDoesNotBypassTLSHostnameValidation() async throws {
        _ = try enableExplicitlySelectedResolver()
        let session = URLSession(configuration: ephemeralConfiguration())
        defer { session.invalidateAndCancel() }
        let url = try XCTUnwrap(URL(string: "https://wrong.host.badssl.com/"))
        do {
            _ = try await session.data(for: URLRequest(url: url, timeoutInterval: 12))
            XCTFail("A certificate for another hostname must not be accepted")
        } catch let error as URLError {
            XCTAssertTrue([URLError.Code.serverCertificateUntrusted, .secureConnectionFailed].contains(error.code),
                          "The request must fail TLS validation, not merely time out: \(error)")
        }
    }

    private func enableExplicitlySelectedResolver() throws -> LyricsDNSConfiguration.Resolver {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["GANABAJANA_LIVE_TESTS"] == "1",
                          "Set GANABAJANA_LIVE_TESTS=1 to contact the public APIs.")
        guard let name = ProcessInfo.processInfo.environment["GANABAJANA_LYRICS_DNS_RESOLVER"] else {
            throw XCTSkip("Explicitly set GANABAJANA_LYRICS_DNS_RESOLVER=cloudflare or google; this changes process-wide DNS.")
        }
        let resolver = try XCTUnwrap(LyricsDNSConfiguration.Resolver(rawValue: name), "Unsupported DNS resolver")
        LyricsDNSConfiguration.enableForCurrentProcess(using: resolver)
        return resolver
    }

    private func ephemeralConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 15
        return configuration
    }
}

private final class LyricsDNSMetricsObserver: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    struct Transaction: Sendable {
        let host: String?
        let dns: URLSessionTaskMetrics.DomainResolutionProtocol
        let hasTLS: Bool
        let isProxy: Bool
    }

    private let lock = NSLock()
    private var collected: [Transaction] = []

    var transactions: [Transaction] { lock.withLock { collected } }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        let transactions = metrics.transactionMetrics.map {
            Transaction(host: $0.request.url?.host, dns: $0.domainResolutionProtocol,
                        hasTLS: $0.negotiatedTLSProtocolVersion != nil, isProxy: $0.isProxyConnection)
        }
        lock.withLock { collected.append(contentsOf: transactions) }
    }
}

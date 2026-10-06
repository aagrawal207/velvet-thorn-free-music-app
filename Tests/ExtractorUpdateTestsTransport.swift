import CryptoKit
import XCTest
@testable import GanaBajana

final class ExtractorUpdateTestsTransport: XCTestCase {
    private func feed() throws -> ExtractorUpdateFeed {
        try ExtractorUpdateFeed(url: XCTUnwrap(URL(string: "https://example.invalid/compatibility.json")),
                               trustedKeys: ["test": Curve25519.Signing.PrivateKey().publicKey.rawRepresentation])
    }

    func testFeedSendsOnlyCookieFreeBodylessGETAndBoundsUnknownLength() async throws {
        let body = try ExtractorUpdateFixtures.package()
        let mock = CatalogMockSession { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.httpBody)
            XCTAssertNil(request.url?.query)
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Referer"))
            XCTAssertFalse(request.httpShouldHandleCookies)
            return CatalogStub(data: body)
        }
        defer { mock.close() }
        let result = try await feed().fetch(using: mock.session)
        XCTAssertEqual(result, body)
        let oversized = CatalogMockSession { _ in CatalogStub(data: Data(repeating: 32, count: 65_537)) }
        defer { oversized.close() }
        do { _ = try await feed().fetch(using: oversized.session); XCTFail("Expected receipt limit") }
        catch { XCTAssertEqual(error as? ExtractorUpdateFailure, .tooLarge) }
    }

    func testStatusAndTransportFailuresDoNotExposeProviderText() async throws {
        let mock = CatalogMockSession { _ in CatalogStub(status: 403, data: Data("sensitive-provider-sentinel".utf8)) }
        defer { mock.close() }
        do { _ = try await feed().fetch(using: mock.session); XCTFail("Expected status rejection") }
        catch {
            XCTAssertEqual(error as? ExtractorUpdateFailure, .network)
            XCTAssertFalse(String(describing: error).contains("sensitive-provider-sentinel"))
        }
    }

    func testRedirectPolicyRejectsEvenSameOriginAndHTTPSDestinations() throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let url = try XCTUnwrap(URL(string: "https://example.invalid/compatibility.json"))
        let task = session.dataTask(with: url)
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: nil))
        let policy = ExtractorFeedRedirectPolicy()
        for destination in ["https://example.invalid/other", "https://other.invalid/file", "http://example.invalid/file"] {
            policy.urlSession(session, task: task, willPerformHTTPRedirection: response,
                              newRequest: URLRequest(url: try XCTUnwrap(URL(string: destination)))) { redirected in
                XCTAssertNil(redirected)
            }
        }
    }

    func testManualReaderRejectsDirectorySymlinkAndOversizedFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("package.json")
        let bytes = try ExtractorUpdateFixtures.package()
        try bytes.write(to: file)
        XCTAssertEqual(try ExtractorUpdateFile.read(file, maximumBytes: bytes.count), bytes)
        XCTAssertThrowsError(try ExtractorUpdateFile.read(root, maximumBytes: 65_536))
        XCTAssertThrowsError(try ExtractorUpdateFile.read(file, maximumBytes: bytes.count - 1))
        let link = root.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try ExtractorUpdateFile.read(link, maximumBytes: 65_536))
    }
}

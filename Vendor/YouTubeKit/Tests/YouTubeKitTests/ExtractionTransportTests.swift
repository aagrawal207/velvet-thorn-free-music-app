import Foundation
import XCTest
@testable import YouTubeKit

private final class ExtractionFixtureState: @unchecked Sendable {
    let sentinelName = "YouTubeKitTransport-\(UUID().uuidString)"
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private var signedIn = true

    var requests: [URLRequest] { lock.withLock { recorded } }
    func record(_ request: URLRequest) { lock.withLock { recorded.append(request) } }
    func signOut() { lock.withLock { signedIn = false } }
    func decorate(_ request: inout URLRequest) {
        guard lock.withLock({ signedIn }) else { return }
        request.setValue("SID=manual-fixture-session", forHTTPHeaderField: "Cookie")
        request.setValue("SAPISIDHASH fixture", forHTTPHeaderField: "Authorization")
    }
}

private final class ExtractionFixtureRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [String: ExtractionFixtureState] = [:]
    func add(_ state: ExtractionFixtureState, id: String) { lock.withLock { states[id] = state } }
    func remove(_ id: String) { _ = lock.withLock { states.removeValue(forKey: id) } }
    func state(for request: URLRequest) -> ExtractionFixtureState? {
        guard let id = request.value(forHTTPHeaderField: "X-Extraction-Test") else { return nil }
        return lock.withLock { states[id] }
    }
}

private final class ExtractionFixtureProtocol: URLProtocol, @unchecked Sendable {
    static let registry = ExtractionFixtureRegistry()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let state = Self.registry.state(for: request), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        state.record(request)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": "application/json",
            "Set-Cookie": "\(state.sentinelName)=response-fixture-session; Domain=.youtube.com; Path=/; Secure"
        ])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { }
}

@available(iOS 15.0, watchOS 8.0, tvOS 15.0, macOS 12.0, *)
final class ExtractionTransportTests: XCTestCase {
    func testProductionTransportHasNoCookieCredentialOrResponseStorage() {
        let configuration = ExtractionTransport.session.configuration
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertNil(configuration.urlCache)
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 15)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 45)
        XCTAssertFalse(ExtractionTransport.session === URLSession.shared)
    }

    func testTVSetCookieCannotAuthenticateOtherClientsOrRequestsAfterSignOut() async throws {
        for attachLegacyJar in [false, true] {
            let state = ExtractionFixtureState()
            let id = UUID().uuidString
            ExtractionFixtureProtocol.registry.add(state, id: id)
            let configuration = ExtractionTransport.configuration()
            let legacyJar = try XCTUnwrap(URLSessionConfiguration.ephemeral.httpCookieStorage)
            let legacyCookie = try XCTUnwrap(HTTPCookie(properties: [
                .name: "SID", .value: "legacy-fixture-session", .domain: ".youtube.com", .path: "/", .secure: "TRUE"
            ]))
            legacyJar.setCookie(legacyCookie)
            if attachLegacyJar { configuration.httpCookieStorage = legacyJar }
            configuration.protocolClasses = [ExtractionFixtureProtocol.self]
            configuration.httpAdditionalHeaders = ["X-Extraction-Test": id]
            let session = URLSession(configuration: configuration)
            defer {
                session.invalidateAndCancel()
                ExtractionFixtureProtocol.registry.remove(id)
                for cookie in HTTPCookieStorage.shared.cookies ?? [] where cookie.name == state.sentinelName {
                    HTTPCookieStorage.shared.deleteCookie(cookie)
                }
            }
            let configurationData = try JSONDecoder().decode(Extraction.YtCfg.self, from: Data("{}".utf8))
            func innerTube(_ client: InnerTube.ClientType) -> InnerTube {
                InnerTube(client: client, signatureTimestamp: nil, ytcfg: configurationData, session: session,
                          requestDecorator: { request, _ in state.decorate(&request) })
            }

            _ = try await innerTube(.tv).player(videoID: "unit-fixture")
            _ = try await innerTube(.web).player(videoID: "unit-fixture")
            _ = try await innerTube(.visionOS).player(videoID: "unit-fixture")
            _ = try await innerTube(.tv).search(query: "unit fixture")
            state.signOut()
            _ = try await innerTube(.tv).player(videoID: "unit-fixture")
            _ = try await innerTube(.web).player(videoID: "unit-fixture")
            _ = try await innerTube(.visionOS).player(videoID: "unit-fixture")

            XCTAssertEqual(state.requests.count, 7)
            XCTAssertEqual(state.requests.first?.value(forHTTPHeaderField: "Cookie"), "SID=manual-fixture-session")
            XCTAssertNotNil(state.requests.first?.value(forHTTPHeaderField: "Authorization"))
            for request in state.requests.dropFirst() {
                XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            }
            XCTAssertTrue(state.requests.allSatisfy { !$0.httpShouldHandleCookies })
            XCTAssertFalse((legacyJar.cookies ?? []).contains { $0.name == state.sentinelName })
            XCTAssertFalse((HTTPCookieStorage.shared.cookies ?? []).contains { $0.name == state.sentinelName })
            XCTAssertEqual(legacyJar.cookies?.count, 1, "Responses cannot modify even an accidentally supplied legacy jar")
        }
    }
}

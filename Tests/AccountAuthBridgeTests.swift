import XCTest
@testable import GanaBajana

@MainActor
final class AccountAuthBridgeTests: XCTestCase {
    private let playerURL = URL(string: "https://www.youtube.com/youtubei/v1/player")!
    private let authHeaders = ["Cookie", "Authorization", "X-Origin", "X-Goog-AuthUser", "X-Youtube-Bootstrap-Logged-In"]

    func testOnlyTVPlayerReceivesManualAccountHeadersAndSignOutClearsReusedRequests() {
        let registry = YouTubeSessionRegistry()
        let account = YouTubeAccountStore(secrets: MemorySecretStore(), registry: registry)
        XCTAssertTrue(account.signIn(cookies: AccountFixtures.signedIn))
        var request = URLRequest(url: playerURL)
        YouTubeKitAuthBridge.decorate(&request, client: "TVHTML5", registry: registry)
        XCTAssertNotNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNotNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertFalse(request.httpShouldHandleCookies)

        for client in ["WEB", "VISIONOS", "TVHTML5_SIMPLY_EMBEDDED_PLAYER", "ANDROID", "IOS"] {
            var nonTV = request
            YouTubeKitAuthBridge.decorate(&nonTV, client: client, registry: registry)
            XCTAssertTrue(authHeaders.allSatisfy { nonTV.value(forHTTPHeaderField: $0) == nil })
            XCTAssertFalse(nonTV.httpShouldHandleCookies)
        }

        XCTAssertTrue(account.signOut())
        for client in ["TVHTML5", "WEB", "VISIONOS"] {
            var afterSignOut = request
            YouTubeKitAuthBridge.decorate(&afterSignOut, client: client, registry: registry)
            XCTAssertTrue(authHeaders.allSatisfy { afterSignOut.value(forHTTPHeaderField: $0) == nil })
            XCTAssertFalse(afterSignOut.httpShouldHandleCookies)
        }
    }

    func testTVHeadersCannotBeAttachedToAnotherHostSchemeOrEndpoint() {
        let registry = YouTubeSessionRegistry()
        registry.update(session: YouTubeAccountSession(capturing: AccountFixtures.signedIn))
        for destination in ["https://www.youtube.com/youtubei/v1/search", "https://music.youtube.com/youtubei/v1/player",
                            "https://www.youtube.com.example.org/youtubei/v1/player", "http://www.youtube.com/youtubei/v1/player"] {
            var request = URLRequest(url: URL(string: destination)!)
            request.setValue("stale-fixture-session", forHTTPHeaderField: "Cookie")
            YouTubeKitAuthBridge.decorate(&request, client: "TVHTML5", registry: registry)
            XCTAssertTrue(authHeaders.allSatisfy { request.value(forHTTPHeaderField: $0) == nil })
            XCTAssertFalse(request.httpShouldHandleCookies)
        }
    }
}

import CryptoKit
import XCTest
@testable import GanaBajana

enum AccountFixtures {
    static let now = Date(timeIntervalSince1970: 1_700_000_000)
    /// sha1("1700000000 abc123 https://www.youtube.com"), computed outside the app.
    static let expectedHash = "SAPISIDHASH 1700000000_9e5071f149fc514366f78b22d1a169786d40ed32"

    static func cookie(_ name: String, _ value: String, domain: String = ".youtube.com", expires: Date? = nil) -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: "/", .secure: "TRUE"]
        if let expires { properties[.expires] = expires }
        return HTTPCookie(properties: properties)!
    }

    static var signedIn: [HTTPCookie] {
        [cookie("SAPISID", "abc123"), cookie("SID", "sid-value"), cookie("HSID", "hsid-value")]
    }

    static func sha1Hex(_ text: String) -> String {
        Insecure.SHA1.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

final class AccountSessionTests: XCTestCase {
    private let now = AccountFixtures.now
    private func cookie(_ name: String, _ value: String, domain: String = ".youtube.com", expires: Date? = nil) -> HTTPCookie {
        AccountFixtures.cookie(name, value, domain: domain, expires: expires)
    }

    func testAuthorizationIsSAPISIDHASHOverSecondsSAPISIDAndOrigin() throws {
        let session = try XCTUnwrap(YouTubeAccountSession(capturing: AccountFixtures.signedIn, signedInAt: now))
        XCTAssertEqual(session.authorization(origin: "https://www.youtube.com", now: now), AccountFixtures.expectedHash)
        XCTAssertNotEqual(session.authorization(origin: "https://music.youtube.com", now: now),
                          session.authorization(origin: "https://www.youtube.com", now: now), "The origin is part of the digest")
        XCTAssertEqual(session.authorization(origin: "https://www.youtube.com", now: now.addingTimeInterval(0.9)),
                       AccountFixtures.expectedHash, "Whole seconds only")
        XCTAssertNil(YouTubeAccountSession(cookies: [StoredCookie(name: "SID", value: "x", domain: ".youtube.com")])
            .authorization(origin: "https://www.youtube.com", now: now))
    }

    func testApplyAddsCookiesSignatureOriginAndAccountHeaders() throws {
        let session = try XCTUnwrap(YouTubeAccountSession(capturing: AccountFixtures.signedIn, signedInAt: now))
        var request = URLRequest(url: URL(string: "https://www.youtube.com/youtubei/v1/player")!)
        session.apply(to: &request, origin: "https://www.youtube.com", now: now)
        let cookieHeader = try XCTUnwrap(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertTrue(cookieHeader.contains("SAPISID=abc123"), cookieHeader)
        XCTAssertTrue(cookieHeader.contains("SID=sid-value"), cookieHeader)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), AccountFixtures.expectedHash)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Origin"), "https://www.youtube.com")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Goog-AuthUser"), "0")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Youtube-Bootstrap-Logged-In"), "true")
    }

    func testCaptureRequiresSAPISIDAndSIDAndKeepsOnlyYouTubeCookies() {
        XCTAssertNil(YouTubeAccountSession(capturing: [cookie("SID", "sid-value")]))
        XCTAssertNil(YouTubeAccountSession(capturing: [cookie("SAPISID", "abc123")]))
        XCTAssertNil(YouTubeAccountSession(capturing: []))
        XCTAssertNil(YouTubeAccountSession(capturing: [cookie("SAPISID", "abc123", domain: ".google.com"), cookie("SID", "x", domain: ".google.com")]),
                     "Google-domain cookies are not a YouTube session")

        let session = YouTubeAccountSession(capturing: AccountFixtures.signedIn + [
            cookie("SAPISID", "google-copy", domain: ".google.com"),
            cookie("NID", "tracking", domain: "accounts.google.com"),
            cookie("VISITOR_INFO1_LIVE", "v", domain: "music.youtube.com"),
            cookie("PREF", "p", domain: "youtube.com"),
            cookie("EVIL", "e", domain: "notyoutube.com")
        ])
        let domains = Set(session?.cookies.map(\.domain) ?? [])
        XCTAssertEqual(domains, [".youtube.com", "music.youtube.com", "youtube.com"])
        XCTAssertEqual(session?.sapisid, "abc123", "The .google.com copy never replaces the YouTube cookie")
        XCTAssertFalse(session?.cookieHeader.contains("NID=") ?? true)
    }

    func testSecure3PAPISIDIsAnAcceptedSignatureSource() throws {
        let session = try XCTUnwrap(YouTubeAccountSession(capturing: [cookie("__Secure-3PAPISID", "third"), cookie("__Secure-3PSID", "sid")]))
        XCTAssertEqual(session.sapisid, "third")
        XCTAssertEqual(session.authorization(origin: "https://www.youtube.com", now: now),
                       "SAPISIDHASH 1700000000_" + AccountFixtures.sha1Hex("1700000000 third https://www.youtube.com"))
        let preferred = try XCTUnwrap(YouTubeAccountSession(capturing: [cookie("__Secure-3PAPISID", "third"), cookie("SAPISID", "first"), cookie("SID", "sid")]))
        XCTAssertEqual(preferred.sapisid, "first", "SAPISID wins when both are present")
    }

    func testExpiryIsTheEarliestRequiredCookieExpiryAndNilForSessionCookies() throws {
        let soon = now.addingTimeInterval(3600)
        let later = now.addingTimeInterval(86_400 * 30)
        let session = try XCTUnwrap(YouTubeAccountSession(capturing: [
            cookie("SAPISID", "abc123", expires: later), cookie("SID", "sid", expires: soon),
            cookie("PREF", "p", expires: now.addingTimeInterval(60)), cookie("LOGIN_INFO", "l", expires: now.addingTimeInterval(1))
        ]))
        XCTAssertEqual(session.expiresAt, soon, "Only the account cookies decide when the sign-in stops working")
        XCTAssertNil(YouTubeAccountSession(capturing: AccountFixtures.signedIn)?.expiresAt)
        let partial = try XCTUnwrap(YouTubeAccountSession(capturing: [cookie("SAPISID", "abc123"), cookie("SID", "sid", expires: soon)]))
        XCTAssertEqual(partial.expiresAt, soon)
    }

    func testStoredSessionSurvivesJSONRoundTrip() throws {
        let session = try XCTUnwrap(YouTubeAccountSession(capturing: AccountFixtures.signedIn, signedInAt: now))
        let decoded = try JSONDecoder().decode(YouTubeAccountSession.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(decoded, session)
        XCTAssertEqual(decoded.authorization(origin: "https://www.youtube.com", now: now), AccountFixtures.expectedHash)
    }
}

@MainActor
final class AccountStoreTests: XCTestCase {
    private let now = AccountFixtures.now
    private func cookie(_ name: String, _ value: String, domain: String = ".youtube.com", expires: Date? = nil) -> HTTPCookie {
        AccountFixtures.cookie(name, value, domain: domain, expires: expires)
    }

    private func makeStore(secrets: MemorySecretStore, registry: YouTubeSessionRegistry, now: Date? = nil) -> YouTubeAccountStore {
        let clock = now ?? self.now
        return YouTubeAccountStore(secrets: secrets, registry: registry, now: { clock })
    }

    func testSignInPersistsPublishesToTheRegistryAndClearsTheBotCheck() {
        let secrets = MemorySecretStore()
        let registry = YouTubeSessionRegistry()
        registry.recordBotCheck(at: now.addingTimeInterval(-60))
        let store = makeStore(secrets: secrets, registry: registry)
        XCTAssertFalse(store.isSignedIn)
        XCTAssertEqual(store.lastBotCheckAt, now.addingTimeInterval(-60), "Loading mirrors the registry's reminder")

        XCTAssertTrue(store.signIn(cookies: AccountFixtures.signedIn))
        XCTAssertTrue(store.isSignedIn)
        XCTAssertEqual(store.session?.signedInAt, now)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(registry.session, store.session)
        XCTAssertNil(registry.lastBotCheckAt)
        XCTAssertNil(store.lastBotCheckAt)

        let reloaded = makeStore(secrets: secrets, registry: YouTubeSessionRegistry())
        XCTAssertTrue(reloaded.isSignedIn)
        XCTAssertEqual(reloaded.session, store.session)
    }

    func testSignOutDeletesTheSecretAndClearsTheRegistry() {
        let secrets = MemorySecretStore()
        let registry = YouTubeSessionRegistry()
        let store = makeStore(secrets: secrets, registry: registry)
        XCTAssertTrue(store.signIn(cookies: AccountFixtures.signedIn))
        XCTAssertNotNil(try secrets.read(YouTubeAccountStore.secretKey))

        XCTAssertTrue(store.signOut())
        XCTAssertFalse(store.isSignedIn)
        XCTAssertNil(store.session)
        XCTAssertNil(registry.session)
        XCTAssertNil(try secrets.read(YouTubeAccountStore.secretKey))
        XCTAssertNil(store.errorMessage)
        XCTAssertFalse(makeStore(secrets: secrets, registry: YouTubeSessionRegistry()).isSignedIn)
    }

    func testJunkCookiesAreRejectedWithAMessageAndLeaveTheRegistryAlone() {
        let registry = YouTubeSessionRegistry()
        let store = makeStore(secrets: MemorySecretStore(), registry: registry)
        XCTAssertFalse(store.signIn(cookies: [cookie("NID", "tracking", domain: ".google.com"), cookie("PREF", "p")]))
        XCTAssertFalse(store.isSignedIn)
        XCTAssertNil(registry.session)
        XCTAssertEqual(store.errorMessage, "That sign-in did not finish. Try again.")

        XCTAssertTrue(store.signIn(cookies: AccountFixtures.signedIn), "A later complete capture recovers")
        XCTAssertNil(store.errorMessage)
    }

    func testCorruptStoredDataLoadsSignedOutWithAnError() {
        let secrets = MemorySecretStore(initial: [YouTubeAccountStore.secretKey: Data("not json".utf8)])
        let registry = YouTubeSessionRegistry()
        let store = makeStore(secrets: secrets, registry: registry)
        XCTAssertFalse(store.isSignedIn)
        XCTAssertNil(registry.session)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertNotNil(try secrets.read(YouTubeAccountStore.secretKey), "Unreadable data is left for the user to replace, not silently dropped")
    }

    func testStoredSessionWithoutAccountCookiesIsDiscardedOnLoad() throws {
        let stale = YouTubeAccountSession(cookies: [StoredCookie(name: "PREF", value: "p", domain: ".youtube.com")], signedInAt: now)
        let secrets = MemorySecretStore(initial: [YouTubeAccountStore.secretKey: try JSONEncoder().encode(stale)])
        let store = makeStore(secrets: secrets, registry: YouTubeSessionRegistry())
        XCTAssertFalse(store.isSignedIn)
        XCTAssertNil(store.errorMessage)
        XCTAssertNil(try secrets.read(YouTubeAccountStore.secretKey))
    }

    func testExpiryFollowsTheInjectedClock() {
        let secrets = MemorySecretStore()
        let expiring = [cookie("SAPISID", "abc123", expires: now.addingTimeInterval(3600)), cookie("SID", "sid", expires: now.addingTimeInterval(7200))]
        let fresh = makeStore(secrets: secrets, registry: YouTubeSessionRegistry())
        XCTAssertTrue(fresh.signIn(cookies: expiring))
        XCTAssertFalse(fresh.isExpired)

        let later = makeStore(secrets: secrets, registry: YouTubeSessionRegistry(), now: now.addingTimeInterval(3600))
        XCTAssertTrue(later.isSignedIn, "An expired session stays visible so Settings can ask for a new sign-in")
        XCTAssertTrue(later.isExpired)

        let sessionCookies = makeStore(secrets: MemorySecretStore(), registry: YouTubeSessionRegistry(), now: .distantFuture)
        XCTAssertTrue(sessionCookies.signIn(cookies: AccountFixtures.signedIn))
        XCTAssertFalse(sessionCookies.isExpired, "Cookies without an expiry never count as expired")
    }

    func testRefreshDiagnosticsMirrorsTheRegistry() {
        let registry = YouTubeSessionRegistry()
        let store = makeStore(secrets: MemorySecretStore(), registry: registry)
        XCTAssertNil(store.lastBotCheckAt)
        registry.recordBotCheck(at: now)
        XCTAssertNil(store.lastBotCheckAt, "The store reads the registry on demand, not continuously")
        store.refreshDiagnostics()
        XCTAssertEqual(store.lastBotCheckAt, now)
        registry.clearBotCheck()
        store.refreshDiagnostics()
        XCTAssertNil(store.lastBotCheckAt)
    }
}

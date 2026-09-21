import WebKit
import XCTest
@testable import GanaBajana

@MainActor
private final class RecordingSignInWebView: WKWebView {
    var requests: [URLRequest] = []
    var stopCount = 0
    var currentURL: URL?

    override var url: URL? { currentURL }
    override func load(_ request: URLRequest) -> WKNavigation? {
        requests.append(request)
        currentURL = request.url
        return nil
    }
    override func stopLoading() { stopCount += 1 }
}

@MainActor
final class AccountSignInTests: XCTestCase {
    private typealias CookieGate = AppModelRequestGate<Int, [StoredCookie]>
    private let youtubeURL = URL(string: "https://music.youtube.com/")!
    private let startURL = URL(string: "https://accounts.google.com/ServiceLogin?service=youtube")!

    private func makeWebView() -> RecordingSignInWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        return RecordingSignInWebView(frame: .zero, configuration: configuration)
    }

    private func withCookieGate(_ body: @MainActor (CookieGate) async throws -> Void) async throws {
        let gate = CookieGate()
        do {
            try await body(gate)
            await gate.close()
        } catch {
            await gate.close()
            throw error
        }
    }

    private func capture(_ coordinator: YouTubeSignInCoordinator, gate: CookieGate, id: Int = 0) throws -> Task<Void, Never> {
        try XCTUnwrap(coordinator.captureCookies(at: youtubeURL) {
            let cookies = (try? await gate.receive(id)) ?? []
            return cookies.compactMap(\.httpCookie)
        })
    }

    func testCancelRejectsDeferredCookiesEvenWhenTheCoordinatorIsRetained() async throws {
        try await withCookieGate { gate in
            let secrets = MemorySecretStore()
            let account = YouTubeAccountStore(secrets: secrets, registry: YouTubeSessionRegistry())
            var captureCount = 0
            let coordinator = YouTubeSignInCoordinator(onCookies: {
                captureCount += 1
                account.signIn(cookies: $0)
            })
            let webView = makeWebView()
            coordinator.observe(webView)
            let task = try capture(coordinator, gate: gate)
            let request = try await gate.request(at: 0)

            coordinator.retire()
            XCTAssertTrue(coordinator.isRetired)
            XCTAssertNil(webView.navigationDelegate)
            XCTAssertEqual(webView.stopCount, 1)
            try await gate.complete(request, with: .success(AccountFixtures.signedIn.map(StoredCookie.init)))
            await task.value

            XCTAssertEqual(captureCount, 0)
            XCTAssertFalse(account.isSignedIn)
            XCTAssertNil(try secrets.read(YouTubeAccountStore.secretKey))
            XCTAssertNil(coordinator.captureCookies(at: youtubeURL) {
                XCTFail("A retired coordinator must not start another cookie read")
                return AccountFixtures.signedIn
            })
        }
    }

    func testCurrentCookieCaptureCanCompleteSignInAndRetireTheFlow() async throws {
        try await withCookieGate { gate in
            let account = YouTubeAccountStore(secrets: MemorySecretStore(), registry: YouTubeSessionRegistry())
            let coordinator = YouTubeSignInCoordinator()
            var captures = 0
            coordinator.onCookies = { [weak coordinator] cookies in
                if account.signIn(cookies: cookies) {
                    captures += 1
                    coordinator?.retire()
                }
            }
            let task = try capture(coordinator, gate: gate)
            let request = try await gate.request(at: 0)
            try await gate.complete(request, with: .success(AccountFixtures.signedIn.map(StoredCookie.init)))
            await task.value

            XCTAssertTrue(account.isSignedIn)
            XCTAssertTrue(coordinator.isRetired)
            XCTAssertEqual(captures, 1)
        }
    }

    func testNewCookieReadRejectsTheOlderGenerationAfterItCompletesLate() async throws {
        try await withCookieGate { gate in
            let account = YouTubeAccountStore(secrets: MemorySecretStore(), registry: YouTubeSessionRegistry())
            var captures = 0
            let coordinator = YouTubeSignInCoordinator(onCookies: {
                captures += 1
                account.signIn(cookies: $0)
            })
            defer { coordinator.retire() }
            let oldTask = try capture(coordinator, gate: gate)
            let oldRequest = try await gate.request(at: 0)
            let newTask = try capture(coordinator, gate: gate, id: 1)
            let newRequest = try await gate.request(at: 1)
            let newCookies = [AccountFixtures.cookie("SAPISID", "new-fixture-session"), AccountFixtures.cookie("SID", "new-fixture-sid")]
            try await gate.complete(newRequest, with: .success(newCookies.map(StoredCookie.init)))
            await newTask.value
            try await gate.complete(oldRequest, with: .success(AccountFixtures.signedIn.map(StoredCookie.init)))
            await oldTask.value

            XCTAssertEqual(captures, 1)
            XCTAssertEqual(account.session?.sapisid, "new-fixture-session")
        }
    }

    func testNavigationAwayInvalidatesADeferredYouTubeCookieRead() async throws {
        try await withCookieGate { gate in
            var captures = 0
            let coordinator = YouTubeSignInCoordinator(onCookies: { _ in captures += 1 })
            defer { coordinator.retire() }
            let webView = makeWebView()
            coordinator.observe(webView)
            let task = try capture(coordinator, gate: gate)
            let request = try await gate.request(at: 0)
            coordinator.webView(webView, didStartProvisionalNavigation: nil)
            try await gate.complete(request, with: .success(AccountFixtures.signedIn.map(StoredCookie.init)))
            await task.value
            XCTAssertEqual(captures, 0)
        }
    }

    func testNavigationFailureBlocksDeferredCaptureUntilRetry() async throws {
        try await withCookieGate { gate in
            var captures = 0
            var message: String?
            let coordinator = YouTubeSignInCoordinator(onCookies: { _ in captures += 1 }, onFailure: { message = $0 })
            defer { coordinator.retire() }
            let webView = makeWebView()
            coordinator.observe(webView)
            coordinator.load(URLRequest(url: startURL))
            let task = try capture(coordinator, gate: gate)
            let request = try await gate.request(at: 0)
            coordinator.webView(webView, didFailProvisionalNavigation: nil, withError: URLError(.notConnectedToInternet))
            try await gate.complete(request, with: .success(AccountFixtures.signedIn.map(StoredCookie.init)))
            await task.value

            XCTAssertEqual(captures, 0)
            XCTAssertNotNil(message)
            XCTAssertNil(coordinator.captureCookies(at: youtubeURL) { AccountFixtures.signedIn })
            coordinator.retry()
            XCTAssertNil(message)
            let retried = try XCTUnwrap(coordinator.captureCookies(at: youtubeURL) { AccountFixtures.signedIn })
            await retried.value
            XCTAssertEqual(captures, 1)
        }
    }

    func testNonYouTubePagesCannotReadOrPublishCookies() {
        let coordinator = YouTubeSignInCoordinator()
        defer { coordinator.retire() }
        for address in ["https://accounts.google.com", "https://notyoutube.com", "https://youtube.com.example.org"] {
            XCTAssertNil(coordinator.captureCookies(at: URL(string: address)) {
                XCTFail("Unrelated pages must not read the cookie store")
                return AccountFixtures.signedIn
            })
        }
    }

    func testOfflineCallbackProvidesRetryCopyAndPreservesTheThrowawayWebStore() {
        var message: String?
        var loading = true
        let coordinator = YouTubeSignInCoordinator(onProgress: { _, value in loading = value }, onFailure: { message = $0 })
        defer { coordinator.retire() }
        let webView = makeWebView()
        let dataStore = webView.configuration.websiteDataStore
        coordinator.observe(webView)
        coordinator.load(URLRequest(url: startURL))

        coordinator.webView(webView, didFailProvisionalNavigation: nil, withError: URLError(.notConnectedToInternet))
        XCTAssertEqual(message, "You're offline. Check your connection, then retry sign-in.")
        XCTAssertFalse(loading)
        coordinator.retry()
        XCTAssertNil(message)
        XCTAssertTrue(loading)
        XCTAssertEqual(webView.requests.map(\.url), [startURL, startURL])
        XCTAssertTrue(webView.configuration.websiteDataStore === dataStore)
        XCTAssertFalse(dataStore.isPersistent)
        XCTAssertTrue(webView.navigationDelegate === coordinator)
    }

    func testCommittedRedirectFailureIsVisibleAndRetryUsesTheRedirectPage() {
        var message: String?
        let coordinator = YouTubeSignInCoordinator(onFailure: { message = $0 })
        defer { coordinator.retire() }
        let webView = makeWebView()
        coordinator.observe(webView)
        coordinator.load(URLRequest(url: startURL))
        webView.currentURL = youtubeURL
        coordinator.webView(webView, didReceiveServerRedirectForProvisionalNavigation: nil)
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorHTTPTooManyRedirects,
                            userInfo: [NSLocalizedDescriptionKey: "private-redirect-sentinel"])

        coordinator.webView(webView, didFail: nil, withError: error)
        XCTAssertEqual(message, "The sign-in page couldn't load. Retry to continue.")
        XCTAssertFalse(message?.contains("private-redirect-sentinel") ?? true)
        coordinator.retry()
        XCTAssertEqual(webView.requests.last?.url, youtubeURL)
        XCTAssertNil(message)
    }

    func testCancelledNavigationDoesNotShowAnErrorOrDisableTheFlow() async throws {
        var failures = 0
        var captures = 0
        let coordinator = YouTubeSignInCoordinator(onCookies: { _ in captures += 1 }, onFailure: { if $0 != nil { failures += 1 } })
        defer { coordinator.retire() }
        let webView = makeWebView()
        coordinator.observe(webView)
        coordinator.webView(webView, didFailProvisionalNavigation: nil, withError: URLError(.cancelled))
        coordinator.webView(webView, didFail: nil, withError: CancellationError())
        let task = try XCTUnwrap(coordinator.captureCookies(at: youtubeURL) { AccountFixtures.signedIn })
        await task.value
        XCTAssertEqual(failures, 0)
        XCTAssertEqual(captures, 1)
    }

    func testRetiredCoordinatorIgnoresFailuresAndRetry() {
        let coordinator = YouTubeSignInCoordinator()
        let webView = makeWebView()
        coordinator.observe(webView)
        coordinator.load(URLRequest(url: startURL))
        coordinator.retire()
        coordinator.onFailure = { _ in XCTFail("Retired callbacks must not update a dismissed screen") }
        coordinator.webView(webView, didFail: nil, withError: URLError(.timedOut))
        coordinator.webViewWebContentProcessDidTerminate(webView)
        coordinator.retry()
        XCTAssertEqual(webView.requests.count, 1)
        XCTAssertNil(webView.navigationDelegate)
    }

    func testNavigationPolicyIsRegisteredWithWebKit() {
        let coordinator = YouTubeSignInCoordinator()
        defer { coordinator.retire() }
        XCTAssertTrue(coordinator.responds(to: NSSelectorFromString("webView:decidePolicyForNavigationAction:decisionHandler:")))
    }
}

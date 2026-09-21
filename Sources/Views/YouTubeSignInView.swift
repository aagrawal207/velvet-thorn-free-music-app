import SwiftUI
import WebKit

/// Google sign-in in a throwaway web view. Only the youtube.com cookies it ends with are kept, and only for
/// stream lookups; the web view's own storage is discarded with the sheet.
@MainActor
struct YouTubeSignInView: View {
    @Environment(MusicAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var progress = 0.0
    @State private var isLoading = true
    @State private var isFinished = false
    @State private var errorMessage: String?
    @State private var coordinator = YouTubeSignInCoordinator()
    @AccessibilityFocusState private var isErrorFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text("Sign in with your Google account. The sign-in stays on this iPhone and is used only to load songs.")
                    .appFont(.footnote)
                    .foregroundStyle(AppTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(AppTheme.accent)
                    .opacity(isLoading ? 1 : 0)
                    .accessibilityLabel("Loading sign-in page")
                    .accessibilityHidden(!isLoading)
                if let errorMessage {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(errorMessage)
                            .appFont(.subheadline)
                            .foregroundStyle(AppTheme.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityFocused($isErrorFocused)
                            .accessibilityIdentifier("signin.error")
                        Button("Retry") { coordinator.retry() }
                            .appFont(.body, weight: .semibold)
                            .frame(minHeight: 44)
                            .accessibilityLabel("Retry YouTube sign-in")
                            .accessibilityIdentifier("signin.retry")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                }
                YouTubeSignInWebView(coordinator: coordinator, onProgress: { value, loading in
                    progress = value
                    isLoading = loading
                }, onCookies: capture, onFailure: { errorMessage = $0 })
                .ignoresSafeArea(edges: .bottom)
                .accessibilityIdentifier("signin.web")
            }
            .background(AppTheme.background)
            .navigationTitle("Sign in to YouTube")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        AppNavigationIntent.perform(in: model) {
                            isFinished = true
                            coordinator.retire()
                            dismiss()
                        }
                    }
                    .appFont(.body)
                    .accessibilityIdentifier("signin.cancel")
                }
            }
        }
        .tint(AppTheme.accent)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("signin.screen")
        .onChange(of: errorMessage) { _, message in isErrorFocused = message != nil }
        .onDisappear {
            isFinished = true
            coordinator.retire()
        }
    }

    /// Runs on every youtube.com page load; pages before the account cookies arrive are ignored quietly.
    private func capture(_ cookies: [HTTPCookie]) {
        guard !isFinished, !coordinator.isRetired, YouTubeAccountSession(capturing: cookies) != nil else { return }
        guard model.account.signIn(cookies: cookies) else {
            errorMessage = model.account.errorMessage
            return
        }
        isFinished = true
        coordinator.retire()
        model.showToast("Signed in to YouTube")
        dismiss()
    }
}

@MainActor
private struct YouTubeSignInWebView: UIViewRepresentable {
    static let startURL = URL(string: "https://accounts.google.com/ServiceLogin?service=youtube&continue=https%3A%2F%2Fmusic.youtube.com%2F&hl=en")!
    // Google refuses sign-in from user agents it recognizes as embedded web views; a Safari UA is what other
    // third-party YouTube clients use.
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    let coordinator: YouTubeSignInCoordinator
    let onProgress: (_ progress: Double, _ isLoading: Bool) -> Void
    let onCookies: ([HTTPCookie]) -> Void
    let onFailure: (String?) -> Void

    func makeCoordinator() -> YouTubeSignInCoordinator {
        coordinator
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.customUserAgent = Self.userAgent
        view.isOpaque = false
        view.backgroundColor = UIColor(AppTheme.background)
        updateUIView(view, context: context)
        context.coordinator.observe(view)
        context.coordinator.load(URLRequest(url: Self.startURL))
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        guard !context.coordinator.isRetired else { return }
        context.coordinator.onProgress = onProgress
        context.coordinator.onCookies = onCookies
        context.coordinator.onFailure = onFailure
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: YouTubeSignInCoordinator) {
        coordinator.retire()
        uiView.navigationDelegate = nil
        uiView.stopLoading()
    }
}

@MainActor
final class YouTubeSignInCoordinator: NSObject, WKNavigationDelegate {
    var onProgress: (Double, Bool) -> Void
    var onCookies: ([HTTPCookie]) -> Void
    var onFailure: (String?) -> Void
    private(set) var isRetired = false
    private var progressObservation: NSKeyValueObservation?
    private var cookieRead: Task<Void, Never>?
    private var captureGeneration = UUID()
    private var hasNavigationFailure = false
    private weak var webView: WKWebView?
    private var activeNavigation: WKNavigation?
    private var retryRequest: URLRequest?

    init(onProgress: @escaping (Double, Bool) -> Void = { _, _ in },
         onCookies: @escaping ([HTTPCookie]) -> Void = { _ in },
         onFailure: @escaping (String?) -> Void = { _ in }) {
        self.onProgress = onProgress
        self.onCookies = onCookies
        self.onFailure = onFailure
    }

    func observe(_ webView: WKWebView) {
        guard !isRetired else { return }
        self.webView = webView
        webView.navigationDelegate = self
        progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { @Sendable [weak self] view, _ in
            MainActor.assumeIsolated {
                guard let self, !self.isRetired, !self.hasNavigationFailure else { return }
                self.onProgress(view.estimatedProgress, view.isLoading)
            }
        }
    }

    func load(_ request: URLRequest) {
        guard !isRetired, let webView else { return }
        invalidateCookieRead()
        retryRequest = request
        webView.stopLoading()
        hasNavigationFailure = false
        onFailure(nil)
        onProgress(0, true)
        activeNavigation = webView.load(request)
    }

    func retry() {
        guard let retryRequest else { return }
        load(retryRequest)
    }

    func retire() {
        guard !isRetired else { return }
        isRetired = true
        invalidateCookieRead()
        progressObservation?.invalidate()
        progressObservation = nil
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        webView = nil
        activeNavigation = nil
        retryRequest = nil
        onProgress = { _, _ in }
        onCookies = { _ in }
        onFailure = { _ in }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard !isRetired else { decisionHandler(.cancel); return }
        if navigationAction.targetFrame?.isMainFrame == true { retryRequest = navigationAction.request }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard !isRetired else { return }
        activeNavigation = navigation
        invalidateCookieRead()
        hasNavigationFailure = false
        onFailure(nil)
        onProgress(webView.estimatedProgress, true)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard isCurrent(navigation), !hasNavigationFailure else { return }
        readCookiesIfOnYouTube(webView)
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        guard isCurrent(navigation), let url = webView.url else { return }
        retryRequest = URLRequest(url: url)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard isCurrent(navigation), !hasNavigationFailure else { return }
        onProgress(1, false)
        readCookiesIfOnYouTube(webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        guard isCurrent(navigation) else { return }
        reportFailure(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        guard isCurrent(navigation) else { return }
        reportFailure(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        reportFailure(WKError(.webContentProcessTerminated))
    }

    private func isCurrent(_ navigation: WKNavigation?) -> Bool {
        guard !isRetired else { return false }
        guard let activeNavigation, let navigation else { return true }
        return activeNavigation === navigation
    }

    private func reportFailure(_ error: any Error) {
        guard !isRetired, let message = Self.failureMessage(for: error) else { return }
        hasNavigationFailure = true
        invalidateCookieRead()
        onProgress(0, false)
        onFailure(message)
    }

    static func failureMessage(for error: any Error) -> String? {
        if error is CancellationError { return nil }
        let error = error as NSError
        if error.domain == NSURLErrorDomain {
            switch error.code {
            case NSURLErrorCancelled: return nil
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
                return "You're offline. Check your connection, then retry sign-in."
            default: break
            }
        }
        return "The sign-in page couldn't load. Retry to continue."
    }

    private func invalidateCookieRead() {
        captureGeneration = UUID()
        cookieRead?.cancel()
        cookieRead = nil
    }

    /// Google finishes sign-in by redirecting to youtube.com; pages before that carry only partial cookies.
    private func readCookiesIfOnYouTube(_ webView: WKWebView) {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        captureCookies(at: webView.url) { await store.allCookies() }
    }

    @discardableResult
    func captureCookies(at url: URL?, read: @escaping @MainActor () async -> [HTTPCookie]) -> Task<Void, Never>? {
        guard !isRetired, !hasNavigationFailure, let host = url?.host?.lowercased(),
              host == "youtube.com" || host.hasSuffix(".youtube.com") else { return nil }
        invalidateCookieRead()
        let generation = captureGeneration
        let task = Task { @MainActor [weak self] in
            guard !Task.isCancelled else { return }
            let cookies = await read()
            guard !Task.isCancelled, let self, !self.isRetired, !self.hasNavigationFailure,
                  self.captureGeneration == generation else { return }
            self.cookieRead = nil
            self.onCookies(cookies)
        }
        cookieRead = task
        return task
    }
}

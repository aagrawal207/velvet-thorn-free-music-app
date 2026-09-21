import Foundation
import Synchronization
import YouTubeKit

/// Connects the signed-in session to the vendored YouTubeKit so its player lookups can carry the account.
/// The hooks read the registry live so sign-in and sign-out take effect on the next lookup.
enum YouTubeKitAuthBridge {
    private static let installed = Mutex(false)

    static func install() {
        installed.withLock { done in
            guard !done else { return }
            done = true
            YouTubeKitHooks.includesTVClient = { YouTubeSessionRegistry.shared.session != nil }
            YouTubeKitHooks.requestDecorator = { request, client in
                decorate(&request, client: client)
            }
        }
    }

    static func decorate(_ request: inout URLRequest, client: String, registry: YouTubeSessionRegistry = .shared) {
        request.httpShouldHandleCookies = false
        for header in ["Cookie", "Authorization", "X-Origin", "X-Goog-AuthUser", "X-Youtube-Bootstrap-Logged-In"] {
            request.setValue(nil, forHTTPHeaderField: header)
        }
        // Non-TV clients reject cookies or return SABR-only formats; only the player endpoint needs the account.
        guard client == "TVHTML5", request.url?.scheme == "https", request.url?.host == "www.youtube.com",
              request.url?.path == "/youtubei/v1/player", let session = registry.session else { return }
        session.apply(to: &request, origin: "https://www.youtube.com")
    }
}

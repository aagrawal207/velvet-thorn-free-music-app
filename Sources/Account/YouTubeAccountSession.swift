import CryptoKit
import Foundation
import Synchronization

/// A browser cookie captured at sign-in, in a form that survives the Keychain round trip.
struct StoredCookie: Codable, Hashable, Sendable {
    var name: String
    var value: String
    var domain: String
    var path: String
    var expires: Date?
    var isSecure: Bool
    var isHTTPOnly: Bool

    init(name: String, value: String, domain: String, path: String = "/", expires: Date? = nil,
         isSecure: Bool = true, isHTTPOnly: Bool = false) {
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
        self.expires = expires
        self.isSecure = isSecure
        self.isHTTPOnly = isHTTPOnly
    }

    init(_ cookie: HTTPCookie) {
        self.init(name: cookie.name, value: cookie.value, domain: cookie.domain, path: cookie.path,
                  expires: cookie.expiresDate, isSecure: cookie.isSecure, isHTTPOnly: cookie.isHTTPOnly)
    }

    var httpCookie: HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path]
        if let expires { properties[.expires] = expires }
        if isSecure { properties[.secure] = "TRUE" }
        return HTTPCookie(properties: properties)
    }

    /// Cookies scoped to `youtube.com` or one of its hosts; Google's own domains carry nothing YouTube reads.
    var appliesToYouTube: Bool {
        let host = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return host == "youtube.com" || host.hasSuffix(".youtube.com")
    }
}

/// The signed-in YouTube session: account cookies plus the request signing YouTube expects with them.
/// Sent only with stream lookups; the catalog stays anonymous.
struct YouTubeAccountSession: Codable, Hashable, Sendable {
    static let cookieNames = ["SAPISID", "__Secure-3PAPISID", "__Secure-1PAPISID"]

    var cookies: [StoredCookie]
    var signedInAt: Date

    init(cookies: [StoredCookie], signedInAt: Date = Date()) {
        self.cookies = cookies.filter(\.appliesToYouTube)
        self.signedInAt = signedInAt
    }

    /// Nil when the cookies do not describe a signed-in account.
    init?(capturing cookies: [HTTPCookie], signedInAt: Date = Date()) {
        let stored = cookies.map(StoredCookie.init)
        let session = YouTubeAccountSession(cookies: stored, signedInAt: signedInAt)
        guard session.isAuthenticated else { return nil }
        self = session
    }

    /// The cookie YouTube's request signature is derived from.
    var sapisid: String? {
        for name in Self.cookieNames {
            if let value = cookies.first(where: { $0.name == name })?.value, !value.isEmpty { return value }
        }
        return nil
    }

    var isAuthenticated: Bool { sapisid != nil && cookies.contains { $0.name == "SID" || $0.name == "__Secure-3PSID" } }

    /// The earliest expiry among the session cookies YouTube requires; nil when they are session cookies.
    var expiresAt: Date? {
        cookies.filter { Self.cookieNames.contains($0.name) || $0.name == "SID" || $0.name == "__Secure-3PSID" }
            .compactMap(\.expires).min()
    }

    var cookieHeader: String {
        cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    /// `SAPISIDHASH <unix seconds>_<sha1("<seconds> <SAPISID> <origin>")>`, the signature YouTube's web
    /// clients send alongside account cookies. Nil without a SAPISID cookie.
    func authorization(origin: String, now: Date = Date()) -> String? {
        guard let sapisid else { return nil }
        let seconds = Int(now.timeIntervalSince1970)
        let digest = Insecure.SHA1.hash(data: Data("\(seconds) \(sapisid) \(origin)".utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "SAPISIDHASH \(seconds)_\(hex)"
    }

    /// Adds the cookies and signature for a request to `origin` (for example `https://www.youtube.com`).
    func apply(to request: inout URLRequest, origin: String, now: Date = Date()) {
        guard let authorization = authorization(origin: origin, now: now) else { return }
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue(origin, forHTTPHeaderField: "X-Origin")
        request.setValue("0", forHTTPHeaderField: "X-Goog-AuthUser")
        request.setValue("true", forHTTPHeaderField: "X-Youtube-Bootstrap-Logged-In")
    }
}

/// Process-wide view of the signed-in session for code that runs off the main actor, such as stream
/// extraction callbacks. `YouTubeAccountStore` is the only writer.
final class YouTubeSessionRegistry: Sendable {
    static let shared = YouTubeSessionRegistry()

    private struct State: Sendable {
        var session: YouTubeAccountSession?
        var lastBotCheckAt: Date?
    }

    private let state = Mutex(State())

    var session: YouTubeAccountSession? { state.withLock { $0.session } }
    /// When a stream lookup last hit YouTube's "confirm you're not a bot" gate; nil if it never has.
    var lastBotCheckAt: Date? { state.withLock { $0.lastBotCheckAt } }

    func update(session: YouTubeAccountSession?) {
        state.withLock { $0.session = session }
    }

    func recordBotCheck(at date: Date = Date()) {
        state.withLock { $0.lastBotCheckAt = date }
    }

    func clearBotCheck() {
        state.withLock { $0.lastBotCheckAt = nil }
    }
}

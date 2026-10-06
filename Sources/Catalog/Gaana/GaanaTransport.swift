import Foundation
import OSLog

/// One decoded Gaana API response; `fetchedAt` lets callers reason about cached age.
struct GaanaResponse: Sendable {
    let json: CatalogJSON
    let fetchedAt: Date
}

/// GET transport for Gaana's two unofficial web hosts: `gsearch.gaana.com` (search) and `apiv2.gaana.com` (details).
/// Bounded bodies, a small response cache, Retry-After handling and a soft request rate mirror `JioSaavnTransport`.
actor GaanaTransport {
    static let searchURL = URL(string: "https://gsearch.gaana.com/vichitih/go/v2/")!
    static let apiURL = URL(string: "https://apiv2.gaana.com/")!
    static let maximumResponseBytes = 4 * 1_024 * 1_024
    static let requestTimeout: TimeInterval = 8
    static let searchLifetime: TimeInterval = 60
    static let detailsLifetime: TimeInterval = 10 * 60
    /// Soft ceiling on requests per second; the actor sleeps instead of dropping a request.
    static let requestsPerSecond = 8
    /// The web player's identity; without `deviceType` and `appVersion` the API answers an empty envelope.
    static let clientHeaders: [(String, String)] = [
        ("deviceType", "GaanaWebsiteApp"), ("appVersion", "V6"), ("gaanaAppVersion", "gaanaAndroid-8.60.2"), ("deviceId", "website"),
    ]

    /// The provider's `{"status":0,"msg":...}` or `{"status":0,"error":...}` envelope: the request reached it and was refused.
    struct APIFailure: LocalizedError, Equatable, Sendable {
        let message: String
        var errorDescription: String? { "Gaana could not answer this request. Please try again." }
    }

    private struct CacheEntry {
        let data: Data
        let fetchedAt: Date
        let expiresAt: Date
        var access: UInt64
    }

    private static let logger = Logger(subsystem: "com.agraabhi.ganabajana", category: "Gaana")
    private let session: URLSession
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let maxCacheBytes: Int
    private let maxCacheEntries: Int
    private var cache: [URL: CacheEntry] = [:]
    private var cacheBytes = 0
    private var access: UInt64 = 0
    private var retryAfter: Date?
    private var recentRequests: [Date] = []

    init(session: URLSession = GaanaTransport.anonymousSession(), now: @escaping @Sendable () -> Date = { Date() },
         sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
         maxCacheBytes: Int = 6 * 1_024 * 1_024, maxCacheEntries: Int = 32) {
        self.session = session
        self.now = now
        self.sleep = sleep
        self.maxCacheBytes = max(0, maxCacheBytes)
        self.maxCacheEntries = max(0, maxCacheEntries)
    }

    static func anonymousSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout * 2
        configuration.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: configuration)
    }

    /// `gsearch` search URL; `include` is the entity filter (`track`, `album`, `artist`, `playlist` or `allItems`).
    static func searchURL(query: String, include: String, startIndex: Int = 0) -> URL {
        var components = URLComponents(url: searchURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "geoLocation", value: "GLOBAL"), URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "content_filter", value: "2"), URLQueryItem(name: "include", value: include),
            URLQueryItem(name: "isRegSrch", value: "0"), URLQueryItem(name: "webVersion", value: "mix"),
            URLQueryItem(name: "rType", value: "web"), URLQueryItem(name: "autocomplete", value: "0"),
            URLQueryItem(name: "startIndex", value: String(max(0, startIndex))),
        ]
        return components.url!
    }

    /// `apiv2` URL for `path` (empty for the legacy `/?type=...` calls) with `st=hls&pkc=true&request_type=web`
    /// added, the combination whose media messages the web player decrypts.
    static func apiURL(path: String, parameters: [(String, String)], streamFields: Bool = true) -> URL {
        let base = path.isEmpty ? apiURL : apiURL.appendingPathComponent(path)
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        var items = parameters.map { URLQueryItem(name: $0.0, value: $0.1) }
        if streamFields {
            items += [URLQueryItem(name: "st", value: "hls"), URLQueryItem(name: "pkc", value: "true")]
        }
        items.append(URLQueryItem(name: "request_type", value: "web"))
        components.queryItems = items
        return components.url!
    }

    func get(_ url: URL, ttl: TimeInterval, forceRefresh: Bool = false,
             cacheIf: @Sendable (CatalogJSON) -> Bool = { _ in true }) async throws -> GaanaResponse {
        try Task.checkCancellation()
        pruneExpired()
        if !forceRefresh, var entry = cache[url] {
            let json = try Self.decode(entry.data)
            if cacheIf(json) {
                access &+= 1
                entry.access = access
                cache[url] = entry
                return GaanaResponse(json: json, fetchedAt: entry.fetchedAt)
            }
            cache.removeValue(forKey: url)
            cacheBytes -= entry.data.count
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.requestTimeout)
        request.httpShouldHandleCookies = false
        request.setValue(CatalogTransport.browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        for (name, value) in Self.clientHeaders { request.setValue(value, forHTTPHeaderField: name) }
        let (data, fetchedAt) = try await fetch(request)
        try Task.checkCancellation()
        let json = try Self.decode(data)
        if let message = Self.failureMessage(json) {
            Self.logger.debug("event=api_failure path=\(url.path, privacy: .public) length=\(message.utf8.count)")
            throw APIFailure(message: message)
        }
        if ttl > 0, cacheIf(json) { insert(data, url: url, fetchedAt: fetchedAt, ttl: ttl) }
        return GaanaResponse(json: json, fetchedAt: fetchedAt)
    }

    /// Only objects are answers; an empty body (the search host without its headers) is an unreadable response.
    static func decode(_ data: Data) throws -> CatalogJSON {
        guard !data.isEmpty, let json = try? CatalogJSON.decode(data), json.isObject else { throw MusicServiceError.invalidResponse }
        return json
    }

    /// Details answer `status: 0` with `msg` ("This song is inactive") or `error` ("Artist not found") for missing ids.
    static func failureMessage(_ json: CatalogJSON) -> String? {
        guard json["status"].int == 0 || json["status"].bool == false else { return nil }
        return json["msg"].string ?? json["error"].string ?? "refused"
    }

    private func fetch(_ request: URLRequest) async throws -> (Data, Date) {
        if let retryAfter, retryAfter > now() { throw MusicServiceError.rateLimited }
        try await throttle()
        for attempt in 0...1 {
            try Task.checkCancellation()
            do {
                let (data, response) = try await session.boundedData(for: request, maximumBytes: Self.maximumResponseBytes)
                try Task.checkCancellation()
                guard let response = response as? HTTPURLResponse else { throw MusicServiceError.invalidResponse }
                let date = now()
                switch response.statusCode {
                case 200...299:
                    guard !data.isEmpty else { throw MusicServiceError.invalidResponse }
                    Self.logger.debug("event=request status=ok bytes=\(data.count)")
                    return (data, date)
                case 429:
                    retryAfter = date.addingTimeInterval(CatalogTransport.retryDelay(response, now: date) ?? 30)
                    Self.logger.notice("event=request status=rateLimited")
                    throw MusicServiceError.rateLimited
                case 500...599:
                    if let delay = CatalogTransport.retryDelay(response, now: date), delay > 2 {
                        retryAfter = date.addingTimeInterval(delay)
                        throw MusicServiceError.unavailable("Gaana is temporarily unavailable. Please try again later.")
                    }
                    if attempt == 0 {
                        try await sleep(max(0.35, CatalogTransport.retryDelay(response, now: date) ?? 0.35))
                        continue
                    }
                    Self.logger.notice("event=request status=failed code=\(response.statusCode)")
                    throw MusicServiceError.unavailable("Gaana is temporarily unavailable. Please try again later.")
                case 401, 403:
                    Self.logger.notice("event=request status=failed code=\(response.statusCode)")
                    throw MusicServiceError.unavailable("Gaana could not serve this public request. Please try again later.")
                case 404, 410:
                    throw MusicServiceError.unavailable("This music is no longer available on Gaana.")
                default:
                    Self.logger.notice("event=request status=failed code=\(response.statusCode)")
                    throw MusicServiceError.invalidResponse
                }
            } catch is BoundedResponseError {
                Self.logger.notice("event=request status=failed reason=tooLarge")
                throw MusicServiceError.invalidResponse
            } catch let error as URLError {
                if error.code == .cancelled || Task.isCancelled { throw CancellationError() }
                if attempt == 0 && [.timedOut, .networkConnectionLost].contains(error.code) {
                    try await sleep(0.35)
                    continue
                }
                Self.logger.notice("event=request status=failed reason=network")
                throw MusicServiceError.network(error.localizedDescription)
            }
        }
        throw MusicServiceError.invalidResponse
    }

    /// Sliding one-second window; waiting keeps bursts of concurrent searches under the soft ceiling.
    private func throttle() async throws {
        while true {
            let current = now()
            recentRequests.removeAll { current.timeIntervalSince($0) >= 1 }
            if recentRequests.count < Self.requestsPerSecond {
                recentRequests.append(current)
                return
            }
            guard let oldest = recentRequests.first else { return }
            try await sleep(max(0.01, 1 - current.timeIntervalSince(oldest)))
            try Task.checkCancellation()
        }
    }

    private func insert(_ data: Data, url: URL, fetchedAt: Date, ttl: TimeInterval) {
        guard maxCacheEntries > 0, data.count <= maxCacheBytes else { return }
        if let old = cache.removeValue(forKey: url) { cacheBytes -= old.data.count }
        while cache.count >= maxCacheEntries || cacheBytes + data.count > maxCacheBytes {
            guard let oldest = cache.min(by: { $0.value.access < $1.value.access })?.key,
                  let removed = cache.removeValue(forKey: oldest) else { break }
            cacheBytes -= removed.data.count
        }
        access &+= 1
        cache[url] = CacheEntry(data: data, fetchedAt: fetchedAt, expiresAt: fetchedAt.addingTimeInterval(ttl), access: access)
        cacheBytes += data.count
    }

    private func pruneExpired() {
        let current = now()
        for (key, entry) in cache where entry.expiresAt <= current {
            cache.removeValue(forKey: key)
            cacheBytes -= entry.data.count
        }
    }
}

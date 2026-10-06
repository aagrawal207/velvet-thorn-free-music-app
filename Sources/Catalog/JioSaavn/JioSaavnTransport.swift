import Foundation
import OSLog

/// One decoded JioSaavn API response; `fetchedAt` lets callers reason about cached age.
struct JioSaavnResponse: Sendable {
    let json: CatalogJSON
    let fetchedAt: Date
}

/// GET transport for the unofficial `www.jiosaavn.com/api.php` surface: bounded bodies, a small response cache,
/// Retry-After handling and a soft request rate, mirroring `CatalogTransport` for YouTube Music.
actor JioSaavnTransport {
    static let apiURL = URL(string: "https://www.jiosaavn.com/api.php")!
    static let maximumResponseBytes = 4 * 1_024 * 1_024
    static let requestTimeout: TimeInterval = 8
    static let searchLifetime: TimeInterval = 60
    static let detailsLifetime: TimeInterval = 10 * 60
    /// Soft ceiling on requests per second; the actor sleeps instead of dropping a request.
    static let requestsPerSecond = 8

    /// Extra client contexts; `reco.getreco` answers only for the Android context.
    enum Context: String, Sendable { case web = "web6dot0", android }

    /// The provider's own `{"status":"failure","error":{"msg":...}}` envelope: the request reached it and was refused.
    struct APIFailure: LocalizedError, Equatable, Sendable {
        var errorDescription: String? { "JioSaavn could not answer this request. Please try again." }
    }

    private struct CacheEntry {
        let data: Data
        let fetchedAt: Date
        let expiresAt: Date
        var access: UInt64
    }

    private static let logger = Logger(subsystem: "com.agraabhi.ganabajana", category: "JioSaavn")
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

    init(session: URLSession = JioSaavnTransport.anonymousSession(), now: @escaping @Sendable () -> Date = { Date() },
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

    /// Builds the request URL for `call`; exposed so tests and the resolver can key their expectations on it.
    static func url(call: String, parameters: [(String, String)], context: Context = .web) -> URL {
        var items = [URLQueryItem(name: "__call", value: call)]
        items += parameters.map { URLQueryItem(name: $0.0, value: $0.1) }
        items += [URLQueryItem(name: "_format", value: "json"), URLQueryItem(name: "_marker", value: "0"),
                  URLQueryItem(name: "api_version", value: "4"), URLQueryItem(name: "ctx", value: context.rawValue)]
        var components = URLComponents(url: apiURL, resolvingAgainstBaseURL: false)!
        components.queryItems = items
        return components.url!
    }

    func get(call: String, parameters: [(String, String)], context: Context = .web, ttl: TimeInterval,
             forceRefresh: Bool = false, cacheIf: @Sendable (CatalogJSON) -> Bool = { _ in true }) async throws -> JioSaavnResponse {
        try Task.checkCancellation()
        let url = Self.url(call: call, parameters: parameters, context: context)
        pruneExpired()
        if !forceRefresh, var entry = cache[url] {
            let json = try Self.decode(entry.data)
            if cacheIf(json) {
                access &+= 1
                entry.access = access
                cache[url] = entry
                return JioSaavnResponse(json: json, fetchedAt: entry.fetchedAt)
            }
            cache.removeValue(forKey: url)
            cacheBytes -= entry.data.count
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.requestTimeout)
        request.httpShouldHandleCookies = false
        request.setValue(CatalogTransport.browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        let (data, fetchedAt) = try await fetch(request)
        try Task.checkCancellation()
        let json = try Self.decode(data)
        if let message = json["error"]["msg"].string, json["status"].string == "failure" {
            Self.logger.debug("event=api_failure call=\(call, privacy: .public) length=\(message.utf8.count)")
            throw APIFailure()
        }
        if ttl > 0, cacheIf(json) { insert(data, url: url, fetchedAt: fetchedAt, ttl: ttl) }
        return JioSaavnResponse(json: json, fetchedAt: fetchedAt)
    }

    /// Quick calls can wrap JSON in a JSONP callback; the payload itself must still be an object or array.
    static func decode(_ data: Data) throws -> CatalogJSON {
        if let json = try? CatalogJSON.decode(data), isContainer(json) { return json }
        guard let text = String(data: data, encoding: .utf8) else { throw MusicServiceError.invalidResponse }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let open = trimmed.firstIndex(where: { $0 == "{" || $0 == "[" }),
              let close = trimmed.lastIndex(where: { $0 == "}" || $0 == "]" }), open < close else {
            throw MusicServiceError.invalidResponse
        }
        let json = try CatalogJSON.decode(Data(trimmed[open...close].utf8))
        guard isContainer(json) else { throw MusicServiceError.invalidResponse }
        return json
    }

    private static func isContainer(_ json: CatalogJSON) -> Bool {
        if case .array = json { return true }
        return json.isObject
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
                        throw MusicServiceError.unavailable("JioSaavn is temporarily unavailable. Please try again later.")
                    }
                    if attempt == 0 {
                        try await sleep(max(0.35, CatalogTransport.retryDelay(response, now: date) ?? 0.35))
                        continue
                    }
                    Self.logger.notice("event=request status=failed code=\(response.statusCode)")
                    throw MusicServiceError.unavailable("JioSaavn is temporarily unavailable. Please try again later.")
                case 401, 403:
                    Self.logger.notice("event=request status=failed code=\(response.statusCode)")
                    throw MusicServiceError.unavailable("JioSaavn could not serve this public request. Please try again later.")
                case 404:
                    throw MusicServiceError.unavailable("This music is no longer available on JioSaavn.")
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

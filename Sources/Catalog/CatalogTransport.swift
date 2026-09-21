import Foundation
import OSLog

struct CatalogResponse: Sendable {
    let json: CatalogJSON
    let fetchedAt: Date
}

actor CatalogTransport {
    static let browserUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"
    static let musicURL = URL(string: "https://music.youtube.com")!
    static let chartsURL = URL(string: "https://charts.youtube.com")!

    private struct CacheKey: Hashable { let url: URL; let body: Data }
    private struct CacheEntry {
        let data: Data
        let fetchedAt: Date
        let expiresAt: Date
        var access: UInt64
    }

    private let session: URLSession
    private let now: @Sendable () -> Date
    private let maxCacheBytes: Int
    private let maxCacheEntries: Int
    private let maximumResponseBytes = 8 * 1_024 * 1_024
    private var cache: [CacheKey: CacheEntry] = [:]
    private var cacheBytes = 0
    private var access: UInt64 = 0
    private var retryAfter: [String: Date] = [:]

    init(session: URLSession, now: @escaping @Sendable () -> Date = { Date() },
         maxCacheBytes: Int = 12 * 1_024 * 1_024, maxCacheEntries: Int = 24) {
        self.session = session
        self.now = now
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
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 35
        configuration.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: configuration)
    }

    func bootstrap() async throws -> Data {
        let request = Self.request(url: Self.musicURL, body: nil)
        return try await fetch(request).0
    }

    func post(baseURL: URL, endpoint: String, body: CatalogJSON, ttl: TimeInterval, forceRefresh: Bool = false,
              cacheIf: @Sendable (CatalogJSON) -> Bool = { _ in true }) async throws -> CatalogResponse {
        try Task.checkCancellation()
        guard baseURL == Self.musicURL || baseURL == Self.chartsURL else { throw MusicServiceError.invalidResponse }
        let url = baseURL.appending(path: "youtubei/v1/\(endpoint)")
            .appending(queryItems: [URLQueryItem(name: "prettyPrint", value: "false")])
        let data = try body.encoded()
        let key = CacheKey(url: url, body: data)
        pruneExpired()
        if !forceRefresh, var entry = cache[key] {
            let json = try CatalogJSON.decode(entry.data)
            if cacheIf(json) {
                access &+= 1
                entry.access = access
                cache[key] = entry
                return CatalogResponse(json: json, fetchedAt: entry.fetchedAt)
            }
            cache.removeValue(forKey: key)
            cacheBytes -= entry.data.count
        }

        var request = Self.request(url: url, body: data)
        let client = body["context"]["client"]
        let name = client["clientName"].string == "WEB_REMIX" ? "67" : "31"
        request.setValue(name, forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(client["clientVersion"].string, forHTTPHeaderField: "X-YouTube-Client-Version")
        request.setValue(baseURL.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue(baseURL.absoluteString + "/", forHTTPHeaderField: "Referer")
        let (responseData, fetchedAt) = try await fetch(request)
        try Task.checkCancellation()
        let json = try CatalogJSON.decode(responseData)
        guard json.isObject else { throw MusicServiceError.invalidResponse }
        if json["error"].isObject { throw MusicServiceError.invalidResponse }
        if ttl > 0, cacheIf(json) { insert(responseData, key: key, fetchedAt: fetchedAt, ttl: ttl) }
        return CatalogResponse(json: json, fetchedAt: fetchedAt)
    }

    private static func request(url: URL, body: Data?) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body
        request.httpShouldHandleCookies = false
        request.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return request
    }

    private func fetch(_ request: URLRequest) async throws -> (Data, Date) {
        let host = request.url?.host ?? ""
        if let deadline = retryAfter[host], deadline > now() { throw MusicServiceError.rateLimited }
        for attempt in 0...1 {
            try Task.checkCancellation()
            do {
                let (data, response) = try await session.boundedData(for: request, maximumBytes: maximumResponseBytes)
                try Task.checkCancellation()
                guard let response = response as? HTTPURLResponse else { throw MusicServiceError.invalidResponse }
                let date = now()
                switch response.statusCode {
                case 200...299:
                    guard !data.isEmpty, data.count <= maximumResponseBytes else { throw MusicServiceError.invalidResponse }
                    return (data, date)
                case 429:
                    retryAfter[host] = date.addingTimeInterval(Self.retryDelay(response, now: date) ?? 30)
                    throw MusicServiceError.rateLimited
                case 500...599:
                    if let delay = Self.retryDelay(response, now: date), delay > 2 {
                        retryAfter[host] = date.addingTimeInterval(delay)
                        throw MusicServiceError.unavailable("YouTube is temporarily unavailable. Please try again later.")
                    }
                    if attempt == 0 {
                        let delay = max(0.35, Self.retryDelay(response, now: date) ?? 0.35)
                        try await Task.sleep(for: .seconds(delay))
                        continue
                    }
                    throw MusicServiceError.unavailable("YouTube is temporarily unavailable. Please try again later.")
                case 401, 403:
                    throw MusicServiceError.unavailable("YouTube could not serve this public request. Please try again later.")
                case 404:
                    throw MusicServiceError.unavailable("This music collection is no longer available on YouTube.")
                default: throw MusicServiceError.invalidResponse
                }
            } catch is BoundedResponseError {
                throw MusicServiceError.invalidResponse
            } catch let error as URLError {
                if error.code == .cancelled || Task.isCancelled { throw CancellationError() }
                if attempt == 0 && [.timedOut, .networkConnectionLost].contains(error.code) {
                    try await Task.sleep(for: .milliseconds(350))
                    continue
                }
                throw MusicServiceError.network(error.localizedDescription)
            }
        }
        throw MusicServiceError.invalidResponse
    }

    private static func retryDelay(_ response: HTTPURLResponse, now: Date) -> TimeInterval? {
        guard let header = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = Double(header), seconds.isFinite, seconds >= 0 { return min(seconds, 86_400 * 365) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: header).map { max(0, $0.timeIntervalSince(now)) }
    }

    private func insert(_ data: Data, key: CacheKey, fetchedAt: Date, ttl: TimeInterval) {
        guard maxCacheEntries > 0, data.count <= maxCacheBytes else { return }
        if let old = cache.removeValue(forKey: key) { cacheBytes -= old.data.count }
        while cache.count >= maxCacheEntries || cacheBytes + data.count > maxCacheBytes {
            guard let oldest = cache.min(by: { $0.value.access < $1.value.access })?.key,
                  let removed = cache.removeValue(forKey: oldest) else { break }
            cacheBytes -= removed.data.count
        }
        access &+= 1
        cache[key] = CacheEntry(data: data, fetchedAt: fetchedAt, expiresAt: fetchedAt.addingTimeInterval(ttl), access: access)
        cacheBytes += data.count
    }

    private func pruneExpired() {
        let expired = cache.filter { $0.value.expiresAt <= now() }.map(\.key)
        for key in expired {
            if let removed = cache.removeValue(forKey: key) { cacheBytes -= removed.data.count }
        }
    }
}

actor WebRemixConfiguration {
    static let fallbackVersion = "1.20260915.14.00"
    private static let logger = Logger(subsystem: "com.agraabhi.ganabajana", category: "Catalog")
    private let transport: CatalogTransport
    private let now: @Sendable () -> Date
    private var cached: (version: String, expiry: Date)?

    init(transport: CatalogTransport, now: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport
        self.now = now
    }

    func version() async throws -> String {
        try Task.checkCancellation()
        if let cached, cached.expiry > now() { return cached.version }
        do {
            let data = try await transport.bootstrap()
            try Task.checkCancellation()
            guard let version = Self.parse(data) else { throw MusicServiceError.invalidResponse }
            cached = (version, now().addingTimeInterval(6 * 3_600))
            return version
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            Self.logger.warning("Public WEB_REMIX bootstrap failed; using a short-lived verified fallback.")
            let fallback = cached?.version ?? Self.fallbackVersion
            cached = (fallback, now().addingTimeInterval(5 * 60))
            return fallback
        }
    }

    static func parse(_ data: Data) -> String? {
        guard let html = String(data: data, encoding: .utf8),
              let regex = try? NSRegularExpression(pattern: #""INNERTUBE_(?:CONTEXT_)?CLIENT_VERSION"\s*:\s*"(1\.\d{8}\.\d{2}\.\d{2})""#),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else { return nil }
        return String(html[range])
    }
}

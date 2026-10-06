import CryptoKit
import Foundation
import OSLog

/// Supplies the skippable stretches of a YouTube upload; the player decides when they apply.
protocol SponsorBlockSegmentProviding: Sendable {
    /// Usable segments for `videoID`, empty when the community knows none. `duration` bounds the coverage rule.
    func segments(forVideoID videoID: String, duration: TimeInterval?) async throws -> [SponsorBlockSegment]
}

/// Anonymous SponsorBlock lookups by SHA-256 prefix: the service receives four hex characters and answers for
/// every video sharing them, so it never learns which recording is playing.
actor SponsorBlockClient: SponsorBlockSegmentProviding {
    struct Configuration: Sendable {
        var timeout: TimeInterval = 6
        var maximumBytes = 256 * 1_024
        var maximumConcurrentRequests = 2
        var cacheCapacity = 256
        var positiveLifetime: TimeInterval = 24 * 60 * 60
        var negativeLifetime: TimeInterval = 60 * 60
        var categories = SponsorBlockCategory.allCases
    }

    enum RequestError: Error, Equatable, Sendable {
        case invalidVideoID, invalidResponse, unavailable, rateLimited, busy
    }

    private struct Entry {
        let submissions: [SponsorBlockSubmission]
        let expiresAt: Date
        var access: UInt64
    }

    static let endpoint = URL(string: "https://sponsor.ajay.app/api/skipSegments/")!
    /// Submissions kept per video before filtering; the API rarely lists more than a handful.
    static let maximumSubmissions = 256
    private static let logger = Logger(subsystem: "com.agraabhi.ganabajana", category: "SponsorBlock")
    private let session: URLSession
    private let configuration: Configuration
    private let userAgent: String
    private let now: @Sendable () -> Date
    private var cache: [String: Entry] = [:]
    private var flights: [String: Task<[SponsorBlockSubmission], any Error>] = [:]
    private var access: UInt64 = 0
    private var deferredUntil = Date.distantPast
    private var deferredError = RequestError.unavailable

    init(session: URLSession? = nil, configuration: Configuration = Configuration(),
         contactURL: URL? = SponsorBlockClient.bundledContactURL,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.session = session ?? Self.anonymousSession(timeout: configuration.timeout)
        self.configuration = configuration
        self.now = now
        userAgent = Self.userAgent(contactURL: contactURL)
    }

    /// The same published contact the MusicBrainz client identifies with, so both services reach one owner.
    static var bundledContactURL: URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "MusicBrainzContactURL") as? String,
              let url = URL(string: value), url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else { return nil }
        return url
    }

    static func userAgent(contactURL: URL?) -> String {
        contactURL.map { "Breezy/1.0 (\($0.absoluteString))" } ?? "Breezy/1.0"
    }

    static func anonymousSession(timeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        configuration.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: configuration)
    }

    var cachedCount: Int { cache.count }

    func segments(forVideoID videoID: String, duration: TimeInterval?) async throws -> [SponsorBlockSegment] {
        try Task.checkCancellation()
        guard CatalogText.videoID(videoID) != nil else { throw RequestError.invalidVideoID }
        let date = now()
        cache = cache.filter { $0.value.expiresAt > date }
        if var entry = cache[videoID] {
            access &+= 1
            entry.access = access
            cache[videoID] = entry
            Self.logger.debug("event=sponsorblock_cache hit=1")
            return SponsorBlockSegments.usable(entry.submissions, duration: duration)
        }
        Self.logger.debug("event=sponsorblock_cache hit=0")
        if let flight = flights[videoID] {
            let shared = try await flight.value
            try Task.checkCancellation()
            return SponsorBlockSegments.usable(shared, duration: duration)
        }
        guard deferredUntil <= date else { throw deferredError }
        guard flights.count < max(1, configuration.maximumConcurrentRequests) else { throw RequestError.busy }
        let task = Task<[SponsorBlockSubmission], any Error> {
            defer { flights.removeValue(forKey: videoID) }
            let submissions = try await fetch(videoID)
            store(submissions, for: videoID)
            return submissions
        }
        flights[videoID] = task
        let submissions = try await task.value
        try Task.checkCancellation()
        return SponsorBlockSegments.usable(submissions, duration: duration)
    }

    /// The first two digest bytes as lowercase hex, the k-anonymity prefix the API keys on.
    static func hashPrefix(for videoID: String) -> String {
        SHA256.hash(data: Data(videoID.utf8)).prefix(2).map { String(format: "%02x", $0) }.joined()
    }

    static func request(videoID: String, categories: [SponsorBlockCategory], userAgent: String, timeout: TimeInterval) throws -> URLRequest {
        guard var components = URLComponents(url: endpoint.appendingPathComponent(hashPrefix(for: videoID)),
                                             resolvingAgainstBaseURL: false) else { throw RequestError.invalidVideoID }
        let list = "[" + categories.map { "\"\($0.rawValue)\"" }.joined(separator: ",") + "]"
        components.queryItems = [URLQueryItem(name: "categories", value: list),
                                 URLQueryItem(name: "actionTypes", value: "[\"skip\"]")]
        guard let url = components.url else { throw RequestError.invalidVideoID }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    /// Submissions for `videoID` out of the prefix batch; the other videos in the response are never read.
    static func parse(_ data: Data, videoID: String) throws -> [SponsorBlockSubmission] {
        guard let json = try? CatalogJSON.decode(data), case .array(let videos) = json else { throw RequestError.invalidResponse }
        guard let video = videos.first(where: { $0["videoID"].string == videoID }) else { return [] }
        return video["segments"].array.prefix(maximumSubmissions).compactMap { item -> SponsorBlockSubmission? in
            let bounds = item["segment"].array
            guard bounds.count == 2, let start = bounds[0].double, let end = bounds[1].double,
                  let category = item["category"].string, let actionType = item["actionType"].string else { return nil }
            let locked = item["locked"].int.map { $0 != 0 } ?? item["locked"].bool ?? false
            return SponsorBlockSubmission(category: category, actionType: actionType, start: start, end: end,
                                          votes: item["votes"].int ?? 0, locked: locked,
                                          videoDuration: item["videoDuration"].double)
        }
    }

    private func store(_ submissions: [SponsorBlockSubmission], for videoID: String) {
        let lifetime = submissions.isEmpty ? configuration.negativeLifetime : configuration.positiveLifetime
        guard configuration.cacheCapacity > 0, lifetime > 0 else { return }
        access &+= 1
        cache[videoID] = Entry(submissions: submissions, expiresAt: now().addingTimeInterval(lifetime), access: access)
        while cache.count > configuration.cacheCapacity {
            guard let oldest = cache.min(by: { $0.value.access < $1.value.access })?.key else { break }
            cache.removeValue(forKey: oldest)
        }
    }

    private func fetch(_ videoID: String) async throws -> [SponsorBlockSubmission] {
        let started = now()
        do {
            let request = try Self.request(videoID: videoID, categories: configuration.categories,
                                           userAgent: userAgent, timeout: configuration.timeout)
            let limit = max(1_024, min(configuration.maximumBytes, 8 * 1_024 * 1_024))
            let (data, response) = try await PlaybackDeadline.run(seconds: configuration.timeout) { [session, request] in
                try await session.boundedData(for: request, maximumBytes: limit)
            }
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else { throw RequestError.invalidResponse }
            switch response.statusCode {
            case 200:
                let submissions = try Self.parse(data, videoID: videoID)
                Self.logger.info("event=sponsorblock_lookup status=\(submissions.isEmpty ? "none" : "ok", privacy: .public) segments=\(submissions.count) latencyMs=\(Self.milliseconds(since: started, now: self.now()))")
                return submissions
            case 404:
                // The API answers 404 when no video with this prefix has segments; that is a cacheable absence.
                Self.logger.info("event=sponsorblock_lookup status=none segments=0 latencyMs=\(Self.milliseconds(since: started, now: self.now()))")
                return []
            case 429:
                deferRequests(until: now().addingTimeInterval(max(1, CatalogTransport.retryDelay(response, now: now()) ?? 60)), error: .rateLimited)
                throw RequestError.rateLimited
            default:
                let delay = CatalogTransport.retryDelay(response, now: now()) ?? (response.statusCode >= 500 ? 15 : 60)
                deferRequests(until: now().addingTimeInterval(max(1, delay)), error: .unavailable)
                throw RequestError.unavailable
            }
        } catch {
            let cancelled = error is CancellationError || Task.isCancelled
            let reason = error as? RequestError
            Self.logger.info("event=sponsorblock_lookup status=\(reason == .rateLimited ? "rateLimited" : "failed", privacy: .public) cancelled=\(cancelled ? 1 : 0) invalid=\(reason == .invalidResponse ? 1 : 0) latencyMs=\(Self.milliseconds(since: started, now: self.now()))")
            if cancelled { throw CancellationError() }
            if let reason { throw reason }
            deferRequests(until: now().addingTimeInterval(15), error: .unavailable)
            throw RequestError.unavailable
        }
    }

    private func deferRequests(until date: Date, error: RequestError) {
        if date > deferredUntil {
            deferredUntil = date
            deferredError = error
        }
    }

    private static func milliseconds(since started: Date, now: Date) -> Int {
        Int(max(0, now.timeIntervalSince(started)) * 1_000)
    }
}

private extension CatalogJSON {
    var double: Double? {
        if case .number(let value) = self, value.isFinite { return value }
        return nil
    }
}

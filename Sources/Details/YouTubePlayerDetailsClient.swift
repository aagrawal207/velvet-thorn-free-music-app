import Foundation
import OSLog

/// Upload-level facts for one YouTube recording: the description, the channel, the publish date and views.
struct YouTubeVideoDetails: Equatable, Sendable {
    var videoID: String
    var description: String?
    var channelTitle: String?
    var publishedAt: Date?
    var publishedAtText: String?
    var viewCount: Int64?
}

/// Cookie-free InnerTube `player` request used only when the Data API cannot supply the description.
/// It reads metadata fields alone; stream selection stays with the playback resolver.
actor YouTubePlayerDetailsClient {
    struct Configuration: Sendable {
        var timeout: TimeInterval = 8
        var maximumBytes = 1_024 * 1_024
        var cacheCapacity = 32
        var cacheLifetime: TimeInterval = 15 * 60
        var maximumConcurrentRequests = 2
        var clientVersion = "2.20250925.01.00"
    }

    enum RequestError: Error, Equatable, Sendable {
        case invalidResponse, unavailable, rateLimited, offline, busy
    }

    private struct Entry {
        let details: YouTubeVideoDetails?
        let expiresAt: Date
        var access: UInt64
    }

    static let endpoint = URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!
    private static let logger = Logger(subsystem: "com.agraabhi.ganabajana", category: "SongDetails")
    private let session: URLSession
    private let configuration: Configuration
    private let now: @Sendable () -> Date
    private let isOffline: @Sendable () async -> Bool
    private var cache: [String: Entry] = [:]
    private var flights: [String: Task<YouTubeVideoDetails?, any Error>] = [:]
    private var access: UInt64 = 0
    private var deferredUntil = Date.distantPast
    private var deferredError = RequestError.unavailable

    init(session: URLSession? = nil, configuration: Configuration = Configuration(),
         now: @escaping @Sendable () -> Date = { Date() }, isOffline: @escaping @Sendable () async -> Bool = { false }) {
        self.session = session ?? Self.anonymousSession(timeout: configuration.timeout)
        self.configuration = configuration
        self.now = now
        self.isOffline = isOffline
    }

    static func anonymousSession(timeout: TimeInterval) -> URLSession {
        let session = URLSessionConfiguration.ephemeral
        session.httpCookieStorage = nil
        session.httpShouldSetCookies = false
        session.urlCredentialStorage = nil
        session.urlCache = nil
        session.requestCachePolicy = .reloadIgnoringLocalCacheData
        session.timeoutIntervalForRequest = timeout
        session.timeoutIntervalForResource = timeout * 2
        session.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: session)
    }

    var cachedCount: Int { cache.count }

    func details(for videoID: String, refresh: Bool = false) async throws -> YouTubeVideoDetails? {
        try Task.checkCancellation()
        guard CatalogText.videoID(videoID) != nil else { throw RequestError.invalidResponse }
        let date = now()
        cache = cache.filter { $0.value.expiresAt > date }
        if !refresh, var entry = cache[videoID] {
            access &+= 1
            entry.access = access
            cache[videoID] = entry
            Self.logger.debug("event=playerDetailsCache hit=1")
            return entry.details
        }
        Self.logger.debug("event=playerDetailsCache hit=0")
        if let flight = flights[videoID] {
            let shared = try await flight.value
            try Task.checkCancellation()
            return shared
        }
        let offline = await isOffline()
        guard !offline else { throw RequestError.offline }
        try Task.checkCancellation()
        guard deferredUntil <= now() else { throw deferredError }
        guard flights.count < max(1, configuration.maximumConcurrentRequests) else { throw RequestError.busy }
        let task = Task<YouTubeVideoDetails?, any Error> {
            defer { flights.removeValue(forKey: videoID) }
            let result = try await fetch(videoID)
            store(result, for: videoID)
            return result
        }
        flights[videoID] = task
        let result = try await task.value
        try Task.checkCancellation()
        return result
    }

    private func store(_ details: YouTubeVideoDetails?, for videoID: String) {
        guard configuration.cacheCapacity > 0, configuration.cacheLifetime > 0 else { return }
        access &+= 1
        cache[videoID] = Entry(details: details, expiresAt: now().addingTimeInterval(configuration.cacheLifetime), access: access)
        while cache.count > configuration.cacheCapacity {
            guard let oldest = cache.min(by: { $0.value.access < $1.value.access })?.key else { break }
            cache.removeValue(forKey: oldest)
        }
    }

    private func fetch(_ videoID: String) async throws -> YouTubeVideoDetails? {
        let started = now()
        do {
            let request = try Self.request(videoID: videoID, clientVersion: configuration.clientVersion, timeout: configuration.timeout)
            let limit = max(1_024, min(configuration.maximumBytes, 8 * 1_024 * 1_024))
            let (data, response) = try await PlaybackDeadline.run(seconds: configuration.timeout) { [session, request] in
                try await session.boundedData(for: request, maximumBytes: limit)
            }
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else { throw RequestError.invalidResponse }
            if response.statusCode == 429 {
                deferRequests(until: now().addingTimeInterval(max(1, CatalogTransport.retryDelay(response, now: now()) ?? 60)), error: .rateLimited)
                throw RequestError.rateLimited
            }
            guard response.statusCode == 200 else {
                deferRequests(until: now().addingTimeInterval(response.statusCode >= 500 ? 15 : 60), error: .unavailable)
                throw RequestError.unavailable
            }
            let details = try Self.parse(data, videoID: videoID)
            Self.logger.info("event=playerDetailsRequest success=1 status=200 latencyMs=\(Self.milliseconds(since: started, now: self.now())) descriptionFound=\(details?.description == nil ? 0 : 1)")
            return details
        } catch {
            let cancelled = error is CancellationError || Task.isCancelled
            let reason = error as? RequestError
            Self.logger.info("event=playerDetailsRequest success=0 cancelled=\(cancelled ? 1 : 0) rateLimited=\(reason == .rateLimited ? 1 : 0) invalid=\(reason == .invalidResponse ? 1 : 0) latencyMs=\(Self.milliseconds(since: started, now: self.now()))")
            if cancelled { throw CancellationError() }
            if let reason { throw reason }
            deferRequests(until: now().addingTimeInterval(15), error: .unavailable)
            throw RequestError.unavailable
        }
    }

    static func request(videoID: String, clientVersion: String, timeout: TimeInterval) throws -> URLRequest {
        let body: CatalogJSON = ["context": ["client": ["clientName": "WEB", "clientVersion": .string(clientVersion),
                                                        "hl": "en", "gl": "US"]],
                                 "videoId": .string(videoID)]
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = try body.encoded()
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(CatalogTransport.browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("1", forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        return request
    }

    /// Nil when the response carries no `videoDetails` for this recording; a foreign id is a malformed response.
    static func parse(_ data: Data, videoID: String) throws -> YouTubeVideoDetails? {
        let json = try CatalogJSON.decode(data)
        guard json.isObject else { throw RequestError.invalidResponse }
        let video = json["videoDetails"]
        guard video.isObject else { return nil }
        guard video["videoId"].string == videoID else { throw RequestError.invalidResponse }
        let microformat = json["microformat"]["playerMicroformatRenderer"]
        let publishedText = CatalogText.clean(microformat["publishDate"].string) ?? CatalogText.clean(microformat["uploadDate"].string)
        let views = video["viewCount"].int64.flatMap { $0 >= 0 ? $0 : nil }
        return YouTubeVideoDetails(videoID: videoID,
                                   description: TrackDetails.trimmedDescription(video["shortDescription"].string),
                                   channelTitle: CatalogText.clean(video["author"].string).map { String($0.prefix(200)) },
                                   publishedAt: TrackDetails.date(from: publishedText),
                                   publishedAtText: publishedText.map { String($0.prefix(40)) },
                                   viewCount: views)
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

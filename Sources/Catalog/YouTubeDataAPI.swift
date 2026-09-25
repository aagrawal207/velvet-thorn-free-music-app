import Foundation
import OSLog

actor YouTubeDataAPI {
    struct Metadata: Equatable, Sendable {
        let duration: TimeInterval?
        let language: ArtistSongLanguageResult?
    }

    struct Configuration: Sendable {
        var capacity = 256
        var lifetime: TimeInterval = 12 * 60 * 60
        var missingLifetime: TimeInterval = 15 * 60
        var timeout: TimeInterval = 2
        var maximumConcurrentLookups = 4
        var maximumWaiters = 16
    }

    struct Activity: Sendable {
        let cachedRecordings: Int
        let activeLookups: Int
        let waitingCallers: Int
    }

    enum RequestError: Error, Equatable {
        case notConfigured, offline, quotaExceeded, credentialsRejected, rateLimited, invalidResponse, unavailable, busy
    }

    private struct Entry {
        let metadata: Metadata?
        let fetchedAt: Date
        let expiresAt: Date
        var access: UInt64
    }

    private struct Flight {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<Metadata?, any Error>]
    }

    private static let logger = Logger(subsystem: "com.agraabhi.ganabajana", category: "YouTubeDataAPI")
    private let apiKey: String
    private let bundleIdentifier: String
    private let session: URLSession
    private let configuration: Configuration
    private let now: @Sendable () -> Date
    private let isOffline: @Sendable () async -> Bool
    private var cache: [String: Entry] = [:]
    private var flights: [String: Flight] = [:]
    private var access: UInt64 = 0
    private var deferredUntil = Date.distantPast
    private var deferredError = RequestError.rateLimited

    init(apiKey: String, bundleIdentifier: String = "com.agraabhi.ganabajana", session: URLSession? = nil,
         configuration: Configuration = Configuration(), now: @escaping @Sendable () -> Date = { Date() },
         isOffline: @escaping @Sendable () async -> Bool = { false }) {
        self.apiKey = apiKey
        self.bundleIdentifier = bundleIdentifier
        self.session = session ?? CatalogTransport.anonymousSession()
        self.configuration = configuration
        self.now = now
        self.isOffline = isOffline
    }

    static func configured(isOffline: @escaping @Sendable () async -> Bool = { false }) -> YouTubeDataAPI? {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              !ProcessInfo.processInfo.arguments.contains("--uitesting") else { return nil }
        #endif
        guard let configuration = bundledCredentials() else {
            logger.info("dataAPIConfigured=0")
            return nil
        }
        logger.info("dataAPIConfigured=1")
        return YouTubeDataAPI(apiKey: configuration.key, bundleIdentifier: configuration.bundleIdentifier, isOffline: isOffline)
    }

    static func bundledCredentials(bundle: Bundle = .main) -> (key: String, bundleIdentifier: String)? {
        guard let url = bundle.url(forResource: "YouTubeDataAPI.local", withExtension: "plist"),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 4_096,
              let data = try? Data(contentsOf: url), data.count <= 4_096,
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String],
              let key = values["APIKey"], validKey(key),
              let identifier = values["BundleIdentifier"], identifier == bundle.bundleIdentifier else { return nil }
        return (key, identifier)
    }

    var activity: Activity {
        Activity(cachedRecordings: cache.count, activeLookups: flights.count,
                 waitingCallers: flights.values.reduce(0) { $0 + $1.waiters.count })
    }

    func recordingLanguage(for track: Track) async throws -> ArtistSongLanguageResult? {
        try Task.checkCancellation()
        guard track.isAudioRecording != false, CatalogText.videoID(track.id) != nil else { return nil }
        return try await metadata(for: track.id)?.language
    }

    func prepareForLookup(_ original: Track) async throws -> Track {
        try Task.checkCancellation()
        guard LyricsMatcher.validDuration(original.duration) == nil else {
            Self.logger.debug("dataAPIDurationAdded=0 dataAPIDurationKept=1 dataAPIDurationMissing=0")
            return original
        }
        var track = original
        do {
            if track.isAudioRecording != false, CatalogText.videoID(track.id) != nil,
               let duration = try await metadata(for: track.id)?.duration {
                track.duration = LyricsMatcher.validDuration(duration)
            }
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
        }
        try Task.checkCancellation()
        let added = LyricsMatcher.validDuration(track.duration) != nil
        Self.logger.debug("dataAPIDurationAdded=\(added ? 1 : 0) dataAPIDurationKept=0 dataAPIDurationMissing=\(added ? 0 : 1)")
        return track
    }

    func metadata(for videoID: String) async throws -> Metadata? {
        try Task.checkCancellation()
        guard Self.validKey(apiKey), !bundleIdentifier.isEmpty else { throw RequestError.notConfigured }
        guard CatalogText.videoID(videoID) != nil else { throw RequestError.invalidResponse }
        let offline = await isOffline()
        try Task.checkCancellation()
        let date = now()
        cache = cache.filter { $0.value.fetchedAt <= date && $0.value.expiresAt > date }
        access &+= 1
        if var entry = cache[videoID] {
            entry.access = access
            cache[videoID] = entry
            Self.logger.debug("dataAPICacheHit=1 dataAPICacheMiss=0 dataAPICoalesced=0")
            return entry.metadata
        }
        guard !offline else { throw RequestError.offline }
        guard deferredUntil <= now() else {
            Self.logger.debug("dataAPIQuotaDeferred=\(self.deferredError == .quotaExceeded ? 1 : 0) dataAPICooldown=1")
            throw deferredError
        }
        let waiterID = UUID()
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Metadata?, any Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                if var flight = flights[videoID] {
                    guard flight.waiters.count < max(1, configuration.maximumWaiters) else {
                        Self.logger.debug("dataAPIRejected=1")
                        continuation.resume(throwing: RequestError.busy)
                        return
                    }
                    flight.waiters[waiterID] = continuation
                    flights[videoID] = flight
                    Self.logger.debug("dataAPICacheHit=0 dataAPICacheMiss=0 dataAPICoalesced=1")
                    return
                }
                guard flights.count < max(1, configuration.maximumConcurrentLookups) else {
                    Self.logger.debug("dataAPIRejected=1")
                    continuation.resume(throwing: RequestError.busy)
                    return
                }
                Self.logger.debug("dataAPICacheHit=0 dataAPICacheMiss=1 dataAPICoalesced=0 dataAPIRejected=0 dataAPIQuotaDeferred=0 dataAPICooldown=0")
                let flightID = UUID()
                let task = Task<Void, Never> {
                    let result: Result<Metadata?, any Error>
                    do {
                        let value = try await fetch(videoID)
                        try Task.checkCancellation()
                        result = .success(value)
                    } catch { result = .failure(error) }
                    finish(videoID, flightID: flightID, result: result)
                }
                flights[videoID] = Flight(id: flightID, task: task, waiters: [waiterID: continuation])
            }
        } onCancel: {
            Task { await self.cancel(videoID, waiterID: waiterID) }
        }
        try Task.checkCancellation()
        return result
    }

    private func fetch(_ videoID: String) async throws -> Metadata? {
        let started = now()
        do {
            let url = URL(string: "https://www.googleapis.com/youtube/v3/videos")!.appending(queryItems: [
                .init(name: "part", value: "snippet,contentDetails"), .init(name: "id", value: videoID),
                .init(name: "fields", value: "items(id,snippet(defaultAudioLanguage),contentDetails(duration))"),
                .init(name: "prettyPrint", value: "false"),
            ])
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 2)
            request.httpShouldHandleCookies = false
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(apiKey, forHTTPHeaderField: "X-Goog-Api-Key")
            request.setValue(bundleIdentifier, forHTTPHeaderField: "X-Ios-Bundle-Identifier")
            let timeout = configuration.timeout.isFinite ? min(2, max(0.01, configuration.timeout)) : 2
            let (data, response) = try await PlaybackDeadline.run(seconds: timeout) { [session, request] in
                try await session.boundedData(for: request, maximumBytes: 256 * 1_024, delegate: YouTubeDataRedirectPolicy())
            }
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else { throw RequestError.invalidResponse }
            if response.statusCode != 200 {
                let json = (try? CatalogJSON.decode(data)) ?? .null
                let reasons = Set(json["error"]["errors"].array.compactMap { $0["reason"].string })
                if !reasons.isDisjoint(with: ["quotaExceeded", "dailyLimitExceeded"]) {
                    deferRequests(until: Self.nextQuotaReset(after: now()), error: .quotaExceeded)
                    throw RequestError.quotaExceeded
                }
                if response.statusCode == 429 || !reasons.isDisjoint(with: ["rateLimitExceeded", "userRateLimitExceeded"]) {
                    deferRequests(until: now().addingTimeInterval(max(1, CatalogTransport.retryDelay(response, now: now()) ?? 60)), error: .rateLimited)
                    throw RequestError.rateLimited
                }
                if [400, 401, 403].contains(response.statusCode) {
                    deferRequests(until: now().addingTimeInterval(60 * 60), error: .credentialsRejected)
                    throw RequestError.credentialsRejected
                }
                if response.statusCode >= 500 {
                    deferRequests(until: now().addingTimeInterval(max(1, CatalogTransport.retryDelay(response, now: now()) ?? 15)), error: .unavailable)
                }
                throw RequestError.unavailable
            }
            let result = try Self.parse(data, videoID: videoID)
            let milliseconds = Int(max(0, now().timeIntervalSince(started)) * 1_000)
            Self.logger.info("dataAPIRequestSuccess=1 dataAPIRequestFailure=0 dataAPICancelled=0 dataAPITimedOut=0 dataAPIQuotaExceeded=0 dataAPICredentialsRejected=0 dataAPIRateLimited=0 dataAPILatencyMs=\(milliseconds) dataAPIMetadataMissing=\(result == nil ? 1 : 0)")
            return result
        } catch {
            let cancelled = error is CancellationError || Task.isCancelled
            let timedOut: Bool
            if let streamError = error as? PlaybackStreamError, case .timedOut = streamError { timedOut = true }
            else { timedOut = (error as? URLError)?.code == .timedOut }
            let reason = error as? RequestError
            let milliseconds = Int(max(0, now().timeIntervalSince(started)) * 1_000)
            Self.logger.info("dataAPIRequestSuccess=0 dataAPIRequestFailure=\(cancelled ? 0 : 1) dataAPICancelled=\(cancelled ? 1 : 0) dataAPITimedOut=\(timedOut ? 1 : 0) dataAPIQuotaExceeded=\(reason == .quotaExceeded ? 1 : 0) dataAPICredentialsRejected=\(reason == .credentialsRejected ? 1 : 0) dataAPIRateLimited=\(reason == .rateLimited ? 1 : 0) dataAPILatencyMs=\(milliseconds)")
            if cancelled { throw CancellationError() }
            if let error = error as? RequestError { throw error }
            deferRequests(until: now().addingTimeInterval(15), error: .unavailable)
            throw RequestError.unavailable
        }
    }

    static func parse(_ data: Data, videoID: String) throws -> Metadata? {
        guard CatalogText.videoID(videoID) != nil else { throw RequestError.invalidResponse }
        let json = try CatalogJSON.decode(data)
        guard json.isObject, case .array(let items) = json["items"], items.count <= 1 else { throw RequestError.invalidResponse }
        guard let item = items.first else { return nil }
        guard item["id"].string == videoID else { throw RequestError.invalidResponse }
        let duration = item["contentDetails"]["duration"].string.flatMap(CatalogText.iso8601Duration)
        let language = ArtistSongLanguageResult.youTubeAudioLanguage(item["snippet"]["defaultAudioLanguage"].string)
        return Metadata(duration: duration, language: language)
    }

    static func nextQuotaReset(after date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar.dateInterval(of: .day, for: date)?.end ?? date.addingTimeInterval(24 * 60 * 60)
    }

    private static func validKey(_ value: String) -> Bool {
        value.utf8.count == 39 && value.hasPrefix("AIza")
            && value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }
    }

    private func deferRequests(until date: Date, error: RequestError) {
        if date > deferredUntil { deferredUntil = date; deferredError = error }
    }

    private func cancel(_ videoID: String, waiterID: UUID) {
        guard var flight = flights[videoID], let waiter = flight.waiters.removeValue(forKey: waiterID) else { return }
        waiter.resume(throwing: CancellationError())
        if flight.waiters.isEmpty {
            flights.removeValue(forKey: videoID)
            flight.task.cancel()
        } else { flights[videoID] = flight }
    }

    private func finish(_ videoID: String, flightID: UUID, result: Result<Metadata?, any Error>) {
        guard let flight = flights[videoID], flight.id == flightID else { return }
        flights.removeValue(forKey: videoID)
        if case .success(let metadata) = result {
            let configuredLifetime = metadata == nil ? configuration.missingLifetime : configuration.lifetime
            let lifetime = configuredLifetime.isFinite ? min(12 * 60 * 60, max(0, configuredLifetime)) : 0
            if lifetime > 0, configuration.capacity > 0 {
                access &+= 1
                let date = now()
                cache[videoID] = Entry(metadata: metadata, fetchedAt: date, expiresAt: date.addingTimeInterval(lifetime), access: access)
                while cache.count > min(256, configuration.capacity) {
                    guard let oldest = cache.min(by: { $0.value.access < $1.value.access })?.key else { break }
                    cache.removeValue(forKey: oldest)
                }
            }
        }
        flight.waiters.values.forEach { $0.resume(with: result) }
    }
}

private final class YouTubeDataRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // The project key is authorized only for the fixed API origin, not a redirect destination.
        completionHandler(nil)
    }
}

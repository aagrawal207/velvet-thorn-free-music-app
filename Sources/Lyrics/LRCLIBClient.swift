import Foundation
import OSLog

struct LRCHTTPResponse: Sendable {
    var data: Data
    var statusCode: Int
    var retryAfter: String?

    init(data: Data = Data(), statusCode: Int, retryAfter: String? = nil) {
        self.data = data
        self.statusCode = statusCode
        self.retryAfter = retryAfter
    }
}

protocol LRCHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> LRCHTTPResponse
}

final class LRCURLSessionTransport: LRCHTTPTransport {
    private let session: URLSession
    static let maximumResponseBytes = 2 * 1024 * 1024

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        configuration.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration: configuration)
    }

    deinit { session.invalidateAndCancel() }

    func send(_ request: URLRequest) async throws -> LRCHTTPResponse {
        let (body, response) = try await session.chunkedBody(for: request)
        guard let response = response as? HTTPURLResponse else {
            body.cancel()
            throw MusicServiceError.invalidResponse
        }
        guard response.expectedContentLength <= Self.maximumResponseBytes else {
            body.cancel()
            throw MusicServiceError.invalidResponse
        }
        guard response.statusCode == 200 else {
            body.cancel()
            return LRCHTTPResponse(statusCode: response.statusCode,
                                   retryAfter: response.value(forHTTPHeaderField: "Retry-After"))
        }
        return try await withTaskCancellationHandler {
            var data = Data()
            data.reserveCapacity(min(Self.maximumResponseBytes, max(0, Int(response.expectedContentLength))))
            for try await chunk in body {
                guard chunk.count <= Self.maximumResponseBytes - data.count else {
                    body.cancel()
                    throw MusicServiceError.invalidResponse
                }
                data.append(chunk)
            }
            try Task.checkCancellation()
            return LRCHTTPResponse(data: data, statusCode: response.statusCode,
                                   retryAfter: response.value(forHTTPHeaderField: "Retry-After"))
        } onCancel: {
            body.cancel()
        }
    }
}

enum LyricsDiagnostics {
    static let logger = Logger(subsystem: "com.agraabhi.ganabajana", category: "Lyrics")
}

actor LRCLIBClient {
    struct Configuration: Sendable {
        var minimumRequestInterval: TimeInterval = 0.15
        var requestTimeout: TimeInterval = 12
        var lookupTimeout: TimeInterval = 35
        var maximumRequests = 10
    }

    private struct Query: Hashable {
        let title: String
        let artist: String
        let album: String?

        var items: [URLQueryItem] {
            var items = [URLQueryItem(name: "track_name", value: title),
                         URLQueryItem(name: "artist_name", value: artist)]
            if let album { items.append(URLQueryItem(name: "album_name", value: album)) }
            return items
        }
    }

    private let transport: any LRCHTTPTransport
    private let configuration: Configuration
    private let now: @Sendable () -> Date
    private var nextRequestAt = Date.distantPast
    private var cooldown: (until: Date, error: MusicServiceError)?

    init(transport: any LRCHTTPTransport, configuration: Configuration = Configuration(),
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport
        self.configuration = configuration
        self.now = now
    }

    func lookup(_ track: Track) async throws -> LyricsDocument {
        let started = now()
        let deadline = started.addingTimeInterval(configuration.lookupTimeout)
        let artists = LyricsMatcher.artistParts(track.artists)
        guard !LyricsMatcher.normalized(track.title).isEmpty, !artists.isEmpty else {
            recordOutcome(.unavailable, searchUsed: false, started: started)
            return LyricsDocument(trackID: track.id, kind: .unavailable, fetchedAt: now())
        }
        let exactQueries = exactQueries(for: track, artists: artists)
        let searchQueries = searchQueries(for: track, artists: artists)
        var records: [Int: LRCLIBRecord] = [:]
        var documents: [Int: LyricsDocument] = [:]
        var invalidLyricsFound = false
        var requests = 0
        var searchUsed = false

        do {
            for query in exactQueries {
                guard requests < configuration.maximumRequests else { break }
                var items = query.items
                if let duration = LyricsMatcher.validDuration(track.duration), (1...3_600).contains(duration) {
                    items.append(URLQueryItem(name: "duration", value: String(duration)))
                }
                requests += 1
                guard let data = try await request(path: "get", items: items, deadline: deadline,
                                                  notFoundIsEmpty: true) else { continue }
                let record: LRCLIBRecord = try decode(data)
                if let match = LyricsMatcher.evaluate(record, for: track) {
                    guard let document = document(for: match, track: track) else {
                        invalidLyricsFound = true
                        continue
                    }
                    records[record.id] = record
                    documents[record.id] = document
                    if match.isExact {
                        recordOutcome(document.kind, searchUsed: false, started: started)
                        return document
                    }
                }
            }

            for query in searchQueries {
                guard requests < configuration.maximumRequests else { break }
                searchUsed = true
                requests += 1
                let data = try await request(path: "search", items: query.items, deadline: deadline,
                                             notFoundIsEmpty: false)
                let candidates: [LRCLIBRecord] = try decode(data ?? Data())
                guard candidates.count <= 20 else { throw MusicServiceError.invalidResponse }
                for record in candidates {
                    guard let match = LyricsMatcher.evaluate(record, for: track) else { continue }
                    guard let document = document(for: match, track: track) else {
                        invalidLyricsFound = true
                        continue
                    }
                    records[record.id] = record
                    documents[record.id] = document
                }
                if let match = LyricsMatcher.bestMatch(in: Array(records.values), for: track), match.isExact,
                   let document = documents[match.record.id] {
                    recordOutcome(document.kind, searchUsed: true, started: started)
                    return document
                }
            }

            let result: LyricsDocument
            if records.isEmpty, invalidLyricsFound { throw MusicServiceError.invalidResponse }
            if let match = LyricsMatcher.bestMatch(in: Array(records.values), for: track),
               let document = documents[match.record.id] {
                result = document
            } else {
                result = LyricsDocument(trackID: track.id, kind: .unavailable, fetchedAt: now())
            }
            recordOutcome(result.kind, searchUsed: searchUsed, started: started)
            return result
        } catch {
            let cancelled = error is CancellationError || Task.isCancelled
            let milliseconds = Int(max(0, now().timeIntervalSince(started)) * 1_000)
            LyricsDiagnostics.logger.info("lookupSuccess=0 lookupFailure=\(cancelled ? 0 : 1) cancelled=\(cancelled ? 1 : 0) fallbackUsed=\(searchUsed ? 1 : 0) latencyMs=\(milliseconds)")
            throw error
        }
    }

    /// Search retains independently published scripts only with exact recording evidence.
    func variants(_ track: Track) async throws -> [LyricsDocument] {
        try Task.checkCancellation()
        guard LyricsMatcher.validDuration(track.duration) != nil else { return [] }
        let artists = LyricsMatcher.artistParts(track.artists)
        guard !artists.isEmpty, !LyricsMatcher.normalized(track.title).isEmpty else { return [] }
        let deadline = now().addingTimeInterval(min(6, configuration.lookupTimeout))
        var records: [Int: LRCLIBRecord] = [:]
        for query in searchQueries(for: track, artists: artists).prefix(min(2, max(0, configuration.maximumRequests))) {
            let data = try await request(path: "search", items: query.items, deadline: deadline, notFoundIsEmpty: false)
            let candidates: [LRCLIBRecord] = try decode(data ?? Data())
            guard candidates.count <= 20 else { throw MusicServiceError.invalidResponse }
            for record in candidates { records[record.id] = record }
        }
        try Task.checkCancellation()
        return variantDocuments(in: Array(records.values), for: track)
    }

    func variantDocuments(in records: [LRCLIBRecord], for track: Track) -> [LyricsDocument] {
        let matches = records.compactMap { LyricsMatcher.evaluate($0, for: track) }
            .filter { $0.isExact && !$0.record.instrumental }
        var representations: [(record: LRCLIBRecord, document: LyricsDocument)] = []
        for match in matches {
            guard let document = document(for: match, track: track) else { continue }
            representations.append((match.record, document))
            // A record's plain field can use a different script; its timing cannot be borrowed from the timed field.
            if document.kind == .synced, let plain = document.plainText {
                let plainScript = LyricsScript.detect(plain)
                if plainScript != LyricsScript.detect(document.displayText), plainScript != .mixed, plainScript != .other {
                    var record = match.record
                    record.syncedLyrics = nil
                    var alternative = document
                    alternative.kind = .plain
                    alternative.lines = []
                    representations.append((record, alternative))
                }
            }
        }
        let groups = Dictionary(grouping: representations) { LyricsScript.detect($0.document.displayText) }
        var result: [LyricsDocument] = []
        for script in LyricsScript.allCases {
            guard let group = groups[script],
                  let match = LyricsMatcher.bestMatch(in: group.map { $0.record }, for: track),
                  let selected = group.first(where: { $0.record.id == match.record.id }) else { continue }
            result.append(selected.document)
        }
        return Array(result.prefix(8))
    }

    private func request(path: String, items: [URLQueryItem], deadline: Date,
                         notFoundIsEmpty: Bool) async throws -> Data? {
        try Task.checkCancellation()
        if let cooldown, cooldown.until > now() { throw cooldown.error }
        let scheduled = max(now(), nextRequestAt)
        guard scheduled < deadline else { throw MusicServiceError.network("Finding lyrics took too long. Please try again.") }
        nextRequestAt = scheduled.addingTimeInterval(max(0, configuration.minimumRequestInterval))
        let delay = scheduled.timeIntervalSince(now())
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        try Task.checkCancellation()
        if let cooldown, cooldown.until > now() { throw cooldown.error }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "lrclib.net"
        components.path = "/api/\(path)"
        components.queryItems = items
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw MusicServiceError.invalidResponse }
        let remaining = deadline.timeIntervalSince(now())
        guard remaining > 0 else { throw MusicServiceError.network("Finding lyrics took too long. Please try again.") }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: min(configuration.requestTimeout, remaining))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("GanaBajana/1.0 (iOS; native LRCLIB client)", forHTTPHeaderField: "User-Agent")
        request.httpShouldHandleCookies = false
        let start = now()
        let response: LRCHTTPResponse
        do {
            response = try await transport.send(request)
            try Task.checkCancellation()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as MusicServiceError {
            throw error
        } catch {
            if Task.isCancelled { throw CancellationError() }
            let milliseconds = Int(max(0, now().timeIntervalSince(start)) * 1_000)
            LyricsDiagnostics.logger.info("requestSuccess=0 requestFailure=1 failure=network latencyMs=\(milliseconds)")
            if let error = error as? URLError {
                switch error.code {
                case .notConnectedToInternet, .networkConnectionLost:
                    throw MusicServiceError.network("You’re offline. Connect to the internet and try lyrics again.")
                case .timedOut, .cannotFindHost, .dnsLookupFailed:
                    throw MusicServiceError.network("Couldn’t reach LRCLIB. Please try again in a moment.")
                default: break
                }
            }
            throw MusicServiceError.network("Couldn’t connect to the lyrics service. Please try again.")
        }
        let milliseconds = Int(max(0, now().timeIntervalSince(start)) * 1_000)
        let success = response.statusCode == 200 || (response.statusCode == 404 && notFoundIsEmpty)
        LyricsDiagnostics.logger.info("requestSuccess=\(success ? 1 : 0) requestFailure=\(success ? 0 : 1) status=\(response.statusCode) latencyMs=\(milliseconds)")
        switch response.statusCode {
        case 200:
            guard !response.data.isEmpty, response.data.count <= LRCURLSessionTransport.maximumResponseBytes else {
                throw MusicServiceError.invalidResponse
            }
            return response.data
        case 404 where notFoundIsEmpty:
            return nil
        case 429:
            cooldown = (retryDate(response.retryAfter) ?? now().addingTimeInterval(30), .rateLimited)
            throw MusicServiceError.rateLimited
        case 500...599:
            let error = MusicServiceError.unavailable("LRCLIB is having trouble right now. Please try again shortly.")
            if let retry = retryDate(response.retryAfter) { cooldown = (retry, error) }
            throw error
        default:
            throw MusicServiceError.unavailable("LRCLIB couldn’t complete the lyrics request (HTTP \(response.statusCode)). Please try again.")
        }
    }

    private func retryDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        if let seconds = Double(value.trimmingCharacters(in: .whitespaces)), seconds.isFinite, seconds >= 0 {
            return min(.distantFuture, now().addingTimeInterval(seconds))
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value)
    }

    private func decode<Value: Decodable>(_ data: Data) throws -> Value {
        do { return try JSONDecoder().decode(Value.self, from: data) }
        catch { throw MusicServiceError.invalidResponse }
    }

    private func exactQueries(for track: Track, artists: [String]) -> [Query] {
        let title = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let clean = LyricsMatcher.cleanTitle(title, artists: track.artists)
        let album = LyricsMatcher.usefulAlbum(track.albumTitle)
        let artistVariants = unique([track.artistName, artists.joined(separator: ", "),
                                     artists.reversed().joined(separator: ", "),
                                     artists.joined(separator: " & ")])
        var result: [Query] = []
        for artist in artistVariants {
            for title in unique([title, clean]) {
                result.append(Query(title: title, artist: artist, album: album))
            }
        }
        return Array(result.prefix(6))
    }

    private func searchQueries(for track: Track, artists: [String]) -> [Query] {
        let clean = LyricsMatcher.cleanTitle(track.title, artists: track.artists)
        let album = LyricsMatcher.usefulAlbum(track.albumTitle)
        var result: [Query] = []
        if let primary = artists.first {
            if let album { result.append(Query(title: clean, artist: primary, album: album)) }
            result.append(Query(title: clean, artist: primary, album: nil))
            if let alternative = artists.dropFirst().first {
                result.append(Query(title: clean, artist: alternative, album: nil))
            }
            if let romanArtist = LyricsMatcher.romanized(primary), LyricsMatcher.normalized(primary) != romanArtist {
                result.append(Query(title: clean, artist: romanArtist, album: album))
                result.append(Query(title: LyricsMatcher.romanized(clean) ?? clean, artist: romanArtist, album: nil))
            }
            if let romanized = LyricsMatcher.romanized(clean), LyricsMatcher.normalized(clean) != romanized {
                result.append(Query(title: romanized, artist: primary, album: album))
                result.append(Query(title: romanized, artist: primary, album: nil))
            }
            if clean != track.title { result.append(Query(title: track.title, artist: primary, album: nil)) }
        }
        var seen: Set<Query> = []
        return Array(result.filter { seen.insert($0).inserted }.prefix(6))
    }

    private func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private func document(for match: LyricsMatcher.Match, track: Track) -> LyricsDocument? {
        let record = match.record
        var document = LyricsDocument(trackID: track.id, kind: .unavailable, sourceID: record.id,
                                       matchedTitle: record.trackName, matchedArtist: record.artistName, fetchedAt: now())
        if record.instrumental {
            document.kind = .instrumental
            return document
        }
        if let plain = record.plainLyrics, plain.utf8.count > LRCParser.maximumSourceBytes { return nil }
        let plain = record.plainLyrics?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let plain, plain.components(separatedBy: .newlines).count > LRCParser.maximumLines { return nil }
        let parsed = record.syncedLyrics.map { LRCParser.parse($0) } ?? []
        let end = LyricsMatcher.validDuration(track.duration)
        let hasWords = parsed.contains { !$0.text.isEmpty }
        let plausible = end.map { end in parsed.allSatisfy { $0.text.isEmpty || $0.time < end } } ?? false
        if match.allowsTiming, hasWords, plausible, let end {
            document.kind = .synced
            document.lines = parsed.filter { $0.time <= end }
            document.plainText = plain?.isEmpty == false ? plain : nil
            return document
        }
        let text = plain?.isEmpty == false ? plain : parsed.map(\.text).joined(separator: "\n")
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            document.kind = .plain
            document.plainText = text
            return document
        }
        return nil
    }

    private func recordOutcome(_ kind: LyricsKind, searchUsed: Bool, started: Date) {
        let milliseconds = Int(max(0, now().timeIntervalSince(started)) * 1_000)
        LyricsDiagnostics.logger.info("lookupSuccess=1 lookupFailure=0 cancelled=0 outcome=\(kind.rawValue, privacy: .public) fallbackUsed=\(searchUsed ? 1 : 0) latencyMs=\(milliseconds)")
    }
}

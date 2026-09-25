import Foundation
import OSLog

actor MusicBrainzRateLimiter {
    static let shared = MusicBrainzRateLimiter()
    private let interval: TimeInterval
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private var nextAllowed = Date.distantPast

    init(interval: TimeInterval = 1, now: @escaping @Sendable () -> Date = { Date() },
         sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.interval = max(1, interval)
        self.now = now
        self.sleep = sleep
    }

    func acquire(before deadline: Date) async throws {
        while true {
            try Task.checkCancellation()
            let current = now()
            guard current < deadline, nextAllowed < deadline else { throw LyricsLookupError.sourcesFailed }
            if current >= nextAllowed {
                nextAllowed = current.addingTimeInterval(interval)
                return
            }
            try await sleep(nextAllowed.timeIntervalSince(current))
        }
    }

    func deferRequests(until date: Date) { nextAllowed = max(nextAllowed, date) }
}

actor ArtistSpotlightMusicBrainz {
    static let shared: ArtistSpotlightMusicBrainz? = {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "MusicBrainzContactURL") as? String,
              let url = URL(string: value), url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else { return nil }
        return ArtistSpotlightMusicBrainz(contactURL: url)
    }()

    private struct Entry {
        let result: ArtistSongLanguageResult?
        let expires: Date
    }

    private let session: URLSession
    private let limiter: MusicBrainzRateLimiter
    private let userAgent: String
    private let contactIsValid: Bool
    private let now: @Sendable () -> Date
    private var cache: [LyricsRequestKey: Entry] = [:]
    private var order: [LyricsRequestKey] = []

    init(contactURL: URL, session: URLSession? = nil, limiter: MusicBrainzRateLimiter = .shared,
         now: @escaping @Sendable () -> Date = { Date() }) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 6
        configuration.httpMaximumConnectionsPerHost = 1
        self.session = session ?? URLSession(configuration: configuration)
        self.limiter = limiter
        self.now = now
        contactIsValid = contactURL.scheme == "https" && contactURL.host != nil && contactURL.user == nil && contactURL.password == nil
        userAgent = "Breezy/1.0 (\(contactURL.absoluteString))"
    }

    func language(for track: Track) async throws -> ArtistSongLanguageResult? {
        try Task.checkCancellation()
        guard contactIsValid else { return nil }
        let key = LyricsRequestKey(track)
        if let entry = cache[key], entry.expires > now() {
            ArtistSpotlightDiagnostics.logger.debug("musicBrainzCacheHit=1 musicBrainzCacheMiss=0")
            return entry.result
        }
        ArtistSpotlightDiagnostics.logger.debug("musicBrainzCacheHit=0 musicBrainzCacheMiss=1")
        let artists = Array(LyricsMatcher.artistParts(track.artists).prefix(3))
        guard CatalogText.videoID(track.id) != nil, track.isAudioRecording != false,
              let duration = LyricsMatcher.validDuration(track.duration), duration <= 3_600,
              !artists.isEmpty, artists.allSatisfy({ $0.utf8.count <= 256 }) else { return nil }
        let deadline = now().addingTimeInterval(6)
        let title = LyricsMatcher.cleanTitle(track.title, artists: track.artists)
        guard CatalogText.clean(title) != nil, title.utf8.count <= 512 else { return nil }
        let milliseconds = Int((duration * 1_000).rounded())
        let credits = artists.map { "artist:\(Self.quoted($0))" }.joined(separator: " OR ")
        let query = "recording:\(Self.quoted(title)) AND (\(credits)) AND dur:[\(max(0, milliseconds - 2_000)) TO \(milliseconds + 2_000)]"
        let search = try await request(path: "recording", items: [URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "limit", value: "20")], deadline: deadline)
        if let search {
            guard case .array = search["recordings"], let count = search["count"].int, count >= 0 else {
                throw MusicServiceError.invalidResponse
            }
        }
        var result: ArtistSongLanguageResult?
        if let search, let id = Self.matchedRecording(in: search, for: track),
           let recording = try await request(path: "recording/\(id)", items: [URLQueryItem(name: "inc", value: "artist-credits+work-rels")], deadline: deadline) {
            guard recording["id"].string == id else { throw LyricsLookupError.recordingMismatch }
            result = try await resolveWork(in: recording, recordingID: id, for: track, deadline: deadline)
        }
        try Task.checkCancellation()
        cache = cache.filter { $0.value.expires > now() }
        order.removeAll { cache[$0] == nil || $0 == key }
        order.append(key)
        cache[key] = Entry(result: result, expires: now().addingTimeInterval(result?.language == nil ? 15 * 60 : 24 * 60 * 60))
        while order.count > 128 { cache.removeValue(forKey: order.removeFirst()) }
        ArtistSpotlightDiagnostics.logger.debug("musicBrainzMatched=\(result?.language == nil ? 0 : 1) musicBrainzUnknown=\(result?.language == nil ? 1 : 0) musicBrainzConflict=\(result?.hasConflictingEvidence == true ? 1 : 0)")
        return result
    }

    private func resolveWork(in recording: CatalogJSON, recordingID: String, for track: Track,
                             deadline: Date) async throws -> ArtistSongLanguageResult? {
        guard let linked = Self.linkedWork(in: recording, recordingID: recordingID, for: track),
              let workID = Self.validID(linked["id"].string) else {
            ArtistSpotlightDiagnostics.logger.debug("musicBrainzWorkFetch=0")
            return nil
        }
        let codes = try Self.languageCodes(in: linked)
        guard codes.isEmpty else {
            ArtistSpotlightDiagnostics.logger.debug("musicBrainzWorkFetch=0")
            return Self.workLanguage(in: recording, recordingID: recordingID, for: track)
        }
        // Follow only this recording's compatible performance link; never search for a similarly named work.
        ArtistSpotlightDiagnostics.logger.debug("musicBrainzWorkFetch=1")
        guard let work = try await request(path: "work/\(workID)", items: [], deadline: deadline) else { return nil }
        guard work["id"].string == workID else { throw LyricsLookupError.recordingMismatch }
        _ = try Self.languageCodes(in: work)
        try Task.checkCancellation()
        return Self.workLanguage(in: recording, recordingID: recordingID, for: track, fetchedWork: work)
    }

    static func matchedRecording(in root: CatalogJSON, for track: Track) -> String? {
        let recordings = root["recordings"].array
        guard let count = root["count"].int, count == recordings.count, recordings.count <= 20 else { return nil }
        let ids = Set(recordings.filter { matches($0, track: track) }.compactMap { validID($0["id"].string) })
        return ids.count == 1 ? ids.first : nil
    }

    static func workLanguage(in recording: CatalogJSON, recordingID: String, for track: Track,
                             fetchedWork: CatalogJSON? = nil) -> ArtistSongLanguageResult? {
        guard let linked = linkedWork(in: recording, recordingID: recordingID, for: track) else { return nil }
        let work = fetchedWork ?? linked
        guard let workID = validID(work["id"].string), workID == linked["id"].string, work["type"].string == "Song",
              LyricsRecordingIdentity.sameTitle(work["title"].text, recording["title"].text, artists: track.artists),
              let workCodes = try? languageCodes(in: work), let linkedCodes = try? languageCodes(in: linked) else { return nil }
        let codes = workCodes.union(linkedCodes)
        guard !codes.isEmpty else { return nil }
        if codes.count > 1 || codes.contains("mul") { return .unclassified(.conflictingEvidence) }
        guard let code = codes.first,
              let language = ["eng": ArtistSongLanguage.english, "hin": .hindi, "tam": .tamil, "tel": .telugu, "ben": .bengali][code] else {
            return .unclassified(.uncertainLanguage)
        }
        return .identified(language, source: .musicBrainzWork(recordingID: recordingID, workID: workID))
    }

    private static func linkedWork(in recording: CatalogJSON, recordingID: String, for track: Track) -> CatalogJSON? {
        guard validID(recordingID) != nil, recording["id"].string == recordingID, matches(recording, track: track) else { return nil }
        guard case .array = recording["relations"] else { return nil }
        let relations = recording["relations"].array.filter { $0["target-type"].string == "work" && $0["type"].string == "performance" }
        guard relations.count == 1, let relation = relations.first, relation["direction"].string == "forward",
              case .array(let attributes) = relation["attributes"], attributes.isEmpty else { return nil }
        let work = relation["work"]
        guard validID(work["id"].string) != nil, work["type"].string == "Song",
              LyricsRecordingIdentity.sameTitle(work["title"].text, recording["title"].text, artists: track.artists) else { return nil }
        return work
    }

    private static func languageCodes(in work: CatalogJSON) throws -> Set<String> {
        var values: [CatalogJSON] = []
        if work["languages"] != .null {
            guard case .array(let languages) = work["languages"] else { throw MusicServiceError.invalidResponse }
            values = languages
        }
        if work["language"] != .null { values.append(work["language"]) }
        var codes = Set<String>()
        for value in values {
            guard let code = value.string, code.utf8.count == 3,
                  code.utf8.allSatisfy({ (97...122).contains($0) }) else { throw MusicServiceError.invalidResponse }
            codes.insert(code)
        }
        return codes
    }

    private static func matches(_ recording: CatalogJSON, track: Track) -> Bool {
        let artists = recording["artist-credit"].array.compactMap { $0["name"].string ?? $0["artist"]["name"].string }
        guard validID(recording["id"].string) != nil, CatalogText.clean(recording["disambiguation"].string) == nil,
              recording["video"].bool != true,
              LyricsRecordingIdentity.sameTitle(track.title, recording["title"].text, artists: track.artists),
              LyricsRecordingIdentity.sameArtists(track.artists, artists),
              let duration = LyricsMatcher.validDuration(track.duration), let length = recording["length"].int, length > 0,
              abs(Double(length) / 1_000 - duration) <= 2 else { return false }
        return true
    }

    private static func validID(_ value: String?) -> String? {
        guard let value, value.count == 36, UUID(uuidString: value) != nil else { return nil }
        return value
    }

    static func quoted(_ text: String) -> String {
        let special = CharacterSet(charactersIn: #"+-&|!(){}[]^\"~*?:\\/"#)
        let escaped = text.unicodeScalars.map { special.contains($0) ? "\\" + String($0) : String($0) }.joined()
        return "\"\(escaped)\""
    }

    private func request(path: String, items: [URLQueryItem], deadline: Date) async throws -> CatalogJSON? {
        try await limiter.acquire(before: deadline)
        try Task.checkCancellation()
        var components = URLComponents()
        components.scheme = "https"
        components.host = "musicbrainz.org"
        components.path = "/ws/2/" + path
        components.queryItems = items + [URLQueryItem(name: "fmt", value: "json")]
        guard let url = components.url else { throw MusicServiceError.invalidResponse }
        let remaining = deadline.timeIntervalSince(now())
        guard remaining > 0 else { throw LyricsLookupError.sourcesFailed }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: min(3, remaining))
        request.httpShouldHandleCookies = false
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let sent = request
        do {
            let (data, response) = try await PlaybackDeadline.run(seconds: min(3, remaining)) { [session] in
                try await session.boundedData(for: sent, maximumBytes: 2 * 1024 * 1024)
            }
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse, data.count <= 2 * 1024 * 1024 else { throw MusicServiceError.invalidResponse }
            if response.statusCode == 404 { return nil }
            if response.statusCode == 429 || response.statusCode == 503 {
                let seconds = Double(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 30
                await limiter.deferRequests(until: now().addingTimeInterval(seconds.isFinite ? min(300, max(1, seconds)) : 30))
                throw MusicServiceError.rateLimited
            }
            guard response.statusCode == 200 else { throw MusicServiceError.invalidResponse }
            let json = try CatalogJSON.decode(data)
            guard json.isObject, json["error"] == .null else { throw MusicServiceError.invalidResponse }
            ArtistSpotlightDiagnostics.logger.debug("musicBrainzRequestSuccess=1 musicBrainzRequestFailure=0")
            return json
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            ArtistSpotlightDiagnostics.logger.debug("musicBrainzRequestSuccess=0 musicBrainzRequestFailure=1")
            if error is BoundedResponseError { throw MusicServiceError.invalidResponse }
            throw error
        }
    }
}

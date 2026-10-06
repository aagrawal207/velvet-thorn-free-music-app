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

    struct DetailsEntry {
        let details: MusicBrainzRecordingDetails?
        let expires: Date
    }

    static let detailsLogger = Logger(subsystem: "com.agraabhi.ganabajana", category: "SongDetails")
    private let session: URLSession
    private let limiter: MusicBrainzRateLimiter
    private let userAgent: String
    private let contactIsValid: Bool
    private let now: @Sendable () -> Date
    private var cache: [LyricsRequestKey: Entry] = [:]
    private var order: [LyricsRequestKey] = []
    var detailsCache: [LyricsRequestKey: DetailsEntry] = [:]
    var detailsOrder: [LyricsRequestKey] = []

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

// MARK: - Song details

/// Writing, production, release and identifier facts for one matched MusicBrainz recording.
struct MusicBrainzRecordingDetails: Equatable, Sendable {
    var recordingID: String
    var credits: [TrackDetails.Credit] = []
    var releaseTitle: String?
    var releaseDate: Date?
    var releaseDateText: String?
    var isrc: String?
    /// Genre votes read from the same lookup, so a details fetch also settles the recording's genre evidence.
    var genres: MusicBrainzRecordingGenres? = nil
}

extension ArtistSpotlightMusicBrainz {
    /// Per details fetch: the recording search, the recording lookup and one follow-up (work credits or release label).
    static let detailsRequestBudget = 3
    static let recordingDetailsInc = "artist-credits+artist-rels+work-rels+work-level-rels+releases+release-groups+isrcs+genres+tags"

    /// Nil when the track has no unique MusicBrainz recording; the result is cached like language lookups.
    func recordingDetails(for track: Track) async throws -> MusicBrainzRecordingDetails? {
        try Task.checkCancellation()
        guard contactIsValid else { return nil }
        let key = LyricsRequestKey(track)
        if let entry = detailsCache[key], entry.expires > now() {
            Self.detailsLogger.debug("event=musicBrainzDetailsCache hit=1")
            return entry.details
        }
        Self.detailsLogger.debug("event=musicBrainzDetailsCache hit=0")
        let artists = Array(LyricsMatcher.artistParts(track.artists).prefix(3))
        guard track.isAudioRecording != false, let duration = LyricsMatcher.validDuration(track.duration), duration <= 3_600,
              !artists.isEmpty, artists.allSatisfy({ $0.utf8.count <= 256 }) else { return nil }
        let title = LyricsMatcher.cleanTitle(track.title, artists: track.artists)
        guard CatalogText.clean(title) != nil, title.utf8.count <= 512 else { return nil }
        let deadline = now().addingTimeInterval(12)
        var requests = 0
        let milliseconds = Int((duration * 1_000).rounded())
        let credits = artists.map { "artist:\(Self.quoted($0))" }.joined(separator: " OR ")
        let query = "recording:\(Self.quoted(title)) AND (\(credits)) AND dur:[\(max(0, milliseconds - 2_000)) TO \(milliseconds + 2_000)]"
        requests += 1
        let search = try await request(path: "recording", items: [URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "limit", value: "20")], deadline: deadline)
        var details: MusicBrainzRecordingDetails?
        if let search, let id = Self.matchedRecording(in: search, for: track) {
            requests += 1
            if let recording = try await request(path: "recording/\(id)",
                                                 items: [URLQueryItem(name: "inc", value: Self.recordingDetailsInc)], deadline: deadline) {
                guard recording["id"].string == id else { throw LyricsLookupError.recordingMismatch }
                var parsed = Self.recordingDetails(in: recording, recordingID: id)
                if requests < Self.detailsRequestBudget, let followUp = Self.followUp(for: recording, parsed: parsed) {
                    requests += 1
                    switch followUp {
                    case .work(let workID):
                        if let work = try await request(path: "work/\(workID)", items: [URLQueryItem(name: "inc", value: "artist-rels")], deadline: deadline),
                           work["id"].string == workID {
                            Self.addWorkCredits(from: work, to: &parsed.credits)
                        }
                    case .release(let releaseID):
                        if let release = try await request(path: "release/\(releaseID)", items: [URLQueryItem(name: "inc", value: "labels")], deadline: deadline),
                           release["id"].string == releaseID {
                            let labels = release["label-info"].array.compactMap { CatalogText.clean($0["label"]["name"].string) }
                            TrackDetails.add(.label, names: Array(labels.prefix(4)), to: &parsed.credits)
                        }
                    }
                }
                details = parsed
            }
        }
        try Task.checkCancellation()
        detailsCache = detailsCache.filter { $0.value.expires > now() }
        detailsOrder.removeAll { detailsCache[$0] == nil || $0 == key }
        detailsOrder.append(key)
        detailsCache[key] = DetailsEntry(details: details, expires: now().addingTimeInterval(details == nil ? 15 * 60 : 24 * 60 * 60))
        while detailsOrder.count > 128 { detailsCache.removeValue(forKey: detailsOrder.removeFirst()) }
        Self.detailsLogger.info("event=musicBrainzDetails matched=\(details == nil ? 0 : 1) requests=\(requests) credits=\(details?.credits.count ?? 0) isrc=\(details?.isrc == nil ? 0 : 1) releaseDate=\(details?.releaseDateText == nil ? 0 : 1)")
        return details
    }

    enum DetailsFollowUp: Equatable, Sendable {
        case work(String), release(String)
    }

    /// Work credits come first; when the recording already embeds them the spare request fetches the release label.
    static func followUp(for recording: CatalogJSON, parsed: MusicBrainzRecordingDetails) -> DetailsFollowUp? {
        let performances = recording["relations"].array.filter { $0["target-type"].string == "work" && $0["type"].string == "performance" }
        if performances.count == 1, let work = performances.first?["work"], let workID = validID(work["id"].string),
           work["relations"] == .null, !parsed.credits.contains(where: { $0.role == .composer || $0.role == .lyricist }) {
            return .work(workID)
        }
        guard !parsed.credits.contains(where: { $0.role == .label }),
              let releaseID = preferredRelease(in: recording).flatMap({ validID($0["id"].string) }) else { return nil }
        return .release(releaseID)
    }

    static func recordingDetails(in recording: CatalogJSON, recordingID: String) -> MusicBrainzRecordingDetails {
        var details = MusicBrainzRecordingDetails(recordingID: recordingID)
        for relation in recording["relations"].array where relation["target-type"].string == "artist" {
            guard let name = CatalogText.clean(relation["artist"]["name"].string), let type = relation["type"].string else { continue }
            let role: TrackDetails.CreditRole? = switch type {
            case "producer": .producer
            case "mix": .mixingEngineer
            case "mastering": .masteringEngineer
            case "recording": .recordingEngineer
            case "engineer": .other("Engineer")
            case "arranger": .arranger
            case "vocal": .vocals
            case "programming": .other("Programming")
            default: nil
            }
            if let role { TrackDetails.add(role, names: [name], to: &details.credits) }
        }
        for relation in recording["relations"].array where relation["target-type"].string == "work" && relation["type"].string == "performance" {
            addWorkCredits(from: relation["work"], to: &details.credits)
        }
        if let release = preferredRelease(in: recording) {
            details.releaseTitle = CatalogText.clean(release["title"].string).map { String($0.prefix(200)) }
            details.releaseDateText = partialDate(release["date"].string)
        }
        details.releaseDateText = details.releaseDateText ?? partialDate(recording["first-release-date"].string)
        details.releaseDate = TrackDetails.date(from: details.releaseDateText)
        details.isrc = recording["isrcs"].array.compactMap { $0.string }.first { isrc in
            isrc.count == 12 && isrc.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII }
        }
        details.genres = recordingGenres(in: recording, recordingID: recordingID)
        return details
    }

    static func addWorkCredits(from work: CatalogJSON, to credits: inout [TrackDetails.Credit]) {
        for relation in work["relations"].array where relation["target-type"].string == "artist" {
            guard let name = CatalogText.clean(relation["artist"]["name"].string), let type = relation["type"].string else { continue }
            let role: TrackDetails.CreditRole? = switch type {
            case "composer": .composer
            case "lyricist": .lyricist
            case "writer": .other("Writer")
            case "arranger": .arranger
            case "librettist": .other("Librettist")
            default: nil
            }
            if let role { TrackDetails.add(role, names: [name], to: &credits) }
        }
    }

    /// The earliest dated official release names the album; bootlegs and undated releases only fill gaps.
    static func preferredRelease(in recording: CatalogJSON) -> CatalogJSON? {
        let releases = recording["releases"].array.filter { CatalogText.clean($0["title"].string) != nil }
        let dated = releases.filter { partialDate($0["date"].string) != nil }
        let official = dated.filter { $0["status"].string == "Official" }
        let pool = official.isEmpty ? (dated.isEmpty ? releases : dated) : official
        return pool.min { ($0["date"].string ?? "9999") < ($1["date"].string ?? "9999") }
    }

    /// MusicBrainz dates are "2013", "2013-04" or "2013-04-03"; anything else is dropped.
    static func partialDate(_ value: String?) -> String? {
        guard let value = CatalogText.clean(value), value.count <= 10,
              value.range(of: #"^[0-9]{4}(-[0-9]{2}(-[0-9]{2})?)?$"#, options: .regularExpression) != nil else { return nil }
        return value
    }
}

// MARK: - Genres

/// Genre and tag votes for one matched recording plus the ids needed for a single follow-up lookup.
struct MusicBrainzRecordingGenres: Equatable, Sendable {
    var recordingID: String
    var recording: [GenreVote] = []
    var releaseGroupID: String?
    /// Nil when the response embedded no release-group tag lists; empty when it did and they were blank.
    var releaseGroup: [GenreVote]?
    /// Credited artist MBIDs in credit order; the first is the primary artist.
    var artistIDs: [String] = []
    /// Embedded per-artist votes when the lookup included them, keyed by artist MBID.
    var artists: [String: [GenreVote]] = [:]
}

/// Outcome of the recording half of a genre classification, with the MusicBrainz requests it cost.
struct MusicBrainzGenreLookup: Equatable, Sendable {
    var genres: MusicBrainzRecordingGenres?
    var requests: Int
}

/// The pieces of the MusicBrainz client the genre classifier needs; tests supply canned answers.
protocol GenreMetadataProviding: Sendable {
    func recordingGenres(for track: Track) async throws -> MusicBrainzGenreLookup
    func releaseGroupGenres(id: String) async throws -> [GenreVote]
    func artistGenres(id: String) async throws -> [GenreVote]
}

extension ArtistSpotlightMusicBrainz: GenreMetadataProviding {
    static let recordingGenresInc = "artist-credits+releases+release-groups+genres+tags"
    /// Tag lists are open-ended; twelve votes per entity keep the store small without losing the ranking.
    static let maximumVotesPerEntity = 12

    /// Search plus one recording lookup, or zero requests when a Song details fetch already matched the recording.
    func recordingGenres(for track: Track) async throws -> MusicBrainzGenreLookup {
        try Task.checkCancellation()
        guard contactIsValid else { return MusicBrainzGenreLookup(genres: nil, requests: 0) }
        let key = LyricsRequestKey(track)
        if let entry = detailsCache[key], entry.expires > now() {
            // A recent details fetch already searched: reuse its match, or its miss, without another request.
            guard let details = entry.details else { return MusicBrainzGenreLookup(genres: nil, requests: 0) }
            return MusicBrainzGenreLookup(genres: details.genres ?? MusicBrainzRecordingGenres(recordingID: details.recordingID), requests: 0)
        }
        let artists = Array(LyricsMatcher.artistParts(track.artists).prefix(3))
        guard track.isAudioRecording != false, let duration = LyricsMatcher.validDuration(track.duration), duration <= 3_600,
              !artists.isEmpty, artists.allSatisfy({ $0.utf8.count <= 256 }) else { return MusicBrainzGenreLookup(genres: nil, requests: 0) }
        let title = LyricsMatcher.cleanTitle(track.title, artists: track.artists)
        guard CatalogText.clean(title) != nil, title.utf8.count <= 512 else { return MusicBrainzGenreLookup(genres: nil, requests: 0) }
        let deadline = now().addingTimeInterval(12)
        let milliseconds = Int((duration * 1_000).rounded())
        let credits = artists.map { "artist:\(Self.quoted($0))" }.joined(separator: " OR ")
        let query = "recording:\(Self.quoted(title)) AND (\(credits)) AND dur:[\(max(0, milliseconds - 2_000)) TO \(milliseconds + 2_000)]"
        var requests = 1
        let search = try await request(path: "recording", items: [URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "limit", value: "20")], deadline: deadline)
        guard let search, let id = Self.matchedRecording(in: search, for: track) else {
            return MusicBrainzGenreLookup(genres: nil, requests: requests)
        }
        requests += 1
        guard let recording = try await request(path: "recording/\(id)",
                                                items: [URLQueryItem(name: "inc", value: Self.recordingGenresInc)], deadline: deadline) else {
            return MusicBrainzGenreLookup(genres: nil, requests: requests)
        }
        guard recording["id"].string == id else { throw LyricsLookupError.recordingMismatch }
        try Task.checkCancellation()
        return MusicBrainzGenreLookup(genres: Self.recordingGenres(in: recording, recordingID: id), requests: requests)
    }

    func releaseGroupGenres(id: String) async throws -> [GenreVote] {
        try await entityGenres(path: "release-group/\(id)", id: id)
    }

    func artistGenres(id: String) async throws -> [GenreVote] {
        try await entityGenres(path: "artist/\(id)", id: id)
    }

    private func entityGenres(path: String, id: String) async throws -> [GenreVote] {
        try Task.checkCancellation()
        guard contactIsValid, Self.validID(id) != nil else { return [] }
        let deadline = now().addingTimeInterval(6)
        guard let entity = try await request(path: path, items: [URLQueryItem(name: "inc", value: "genres+tags")], deadline: deadline) else {
            return []
        }
        guard entity["id"].string == id else { throw LyricsLookupError.recordingMismatch }
        return Self.votes(in: entity)
    }

    static func recordingGenres(in recording: CatalogJSON, recordingID: String) -> MusicBrainzRecordingGenres {
        var genres = MusicBrainzRecordingGenres(recordingID: recordingID, recording: votes(in: recording))
        for credit in recording["artist-credit"].array {
            let artist = credit["artist"]
            guard let id = validID(artist["id"].string), !genres.artistIDs.contains(id) else { continue }
            genres.artistIDs.append(id)
            if artist["genres"] != .null || artist["tags"] != .null { genres.artists[id] = votes(in: artist) }
        }
        if let release = preferredRelease(in: recording) ?? recording["releases"].array.first {
            let group = release["release-group"]
            if let id = validID(group["id"].string) {
                genres.releaseGroupID = id
                if group["genres"] != .null || group["tags"] != .null { genres.releaseGroup = votes(in: group) }
            }
        }
        return genres
    }

    /// `genres` are the tags MusicBrainz recognises as genres; `tags` repeats them with the free-form rest.
    static func votes(in entity: CatalogJSON) -> [GenreVote] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for list in [entity["genres"].array, entity["tags"].array] {
            for item in list {
                guard let name = CatalogText.clean(item["name"].string), name.utf8.count <= 64 else { continue }
                let key = GenreTaxonomy.normalize(name)
                guard !key.isEmpty else { continue }
                let count = max(0, item["count"].int ?? 1)
                if counts[key] == nil { order.append(key) }
                counts[key] = max(counts[key] ?? 0, count)
            }
        }
        return order.map { GenreVote($0, count: counts[$0] ?? 0) }
            .filter { $0.count > 0 }
            .sorted { $0.count == $1.count ? $0.name < $1.name : $0.count > $1.count }
            .prefix(maximumVotesPerEntity)
            .map { $0 }
    }
}

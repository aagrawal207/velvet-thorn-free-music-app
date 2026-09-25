import Foundation
import OSLog

actor YouTubeMusicService: MusicCatalogProviding, LyricsProviding, AlbumDescriptionProviding {
    private static let logger = Logger(subsystem: "com.agraabhi.ganabajana", category: "Catalog")
    private let transport: CatalogTransport
    private let configuration: WebRemixConfiguration
    private let albumDescriptionTimeout: TimeInterval
    private let maximumBrowsePages = 8
    private static let artistEnrichmentTimeout: TimeInterval = 2

    /// Outcome of the speculative artist lookup that runs beside a song search.
    private struct ArtistMatch: Sendable {
        let artist: MusicCollection
        let page: ArtistPage?
    }

    init(session: URLSession = CatalogTransport.anonymousSession(), now: @escaping @Sendable () -> Date = { Date() },
         albumDescriptionTimeout: TimeInterval = 5) {
        let transport = CatalogTransport(session: session, now: now)
        self.transport = transport
        self.configuration = WebRemixConfiguration(transport: transport, now: now)
        self.albumDescriptionTimeout = albumDescriptionTimeout.isFinite ? min(5, max(0.01, albumDescriptionTimeout)) : 5
    }

    func search(query: String, filter: SearchFilter, continuation: String?) async throws -> CatalogPage {
        try Task.checkCancellation()
        guard let query = CatalogText.clean(query) else { return CatalogPage() }
        guard query.utf8.count <= 4_096 else {
            throw MusicServiceError.unavailable("That search is too long. Try a shorter song, artist, or album name.")
        }
        let scope = "search|\(filter.rawValue)|\(query)"
        let cursor = try continuation.map { try CatalogContinuation.decode($0, scope: scope) }
        if filter == .songs { return try await songSearch(query: query, cursor: cursor, scope: scope) }
        let response = try await searchResponse(query: query, filter: filter, cursor: cursor)
        try Task.checkCancellation()
        let page = try CatalogParser.search(response.json, filter: filter, query: query)
        return try CatalogContinuation.attach(to: page, response: response, previous: cursor, scope: scope)
    }

    func browse(id: String) async throws -> CatalogPage {
        try Task.checkCancellation()
        return try await browseAll(id: try Self.browseID(id)).page
    }

    func albumDescription(id: String) async throws -> AlbumDescription? {
        try Task.checkCancellation()
        guard let id = AlbumDescriptionIdentity.albumID(id) else { return nil }
        // Description-only reads need the first header, not pagination or recording enrichment.
        let response = try await PlaybackDeadline.run(seconds: albumDescriptionTimeout) {
            try await self.request("browse", payload: ["browseId": .string(id)], ttl: 10 * 60,
                                   cacheIf: { CatalogAlbumDescriptionParser.hasReadableHeader($0) })
        }
        try Task.checkCancellation()
        guard CatalogAlbumDescriptionParser.hasReadableHeader(response.json) else { throw MusicServiceError.invalidResponse }
        return CatalogAlbumDescriptionParser.parse(response.json, id: id)
    }

    func artist(id: String) async throws -> ArtistPage {
        try Task.checkCancellation()
        let id = try Self.browseID(id)
        guard id.hasPrefix("UC") || id.hasPrefix("MPAD") else {
            throw MusicServiceError.unavailable("This YouTube Music page is not an artist.")
        }
        let (page, first) = try await browseAll(id: id)
        let header = CatalogParser.artistHeader(first.json)
        let audience = header.monthlyAudience
        Self.logger.debug("artistMonthlyAudiencePresent=\(audience == nil ? 0 : 1) artistMonthlyAudienceMissing=\(audience == nil ? 1 : 0) value=\(audience?.value.description ?? "unavailable", privacy: .public) unit=\(audience?.kind.rawValue ?? "unavailable", privacy: .public) source=\(audience?.source.rawValue ?? "unavailable", privacy: .public) headerFetchedAt=\(first.fetchedAt.timeIntervalSince1970)")
        return ArtistPage(id: id, name: header.name ?? page.title ?? "", artworkURL: header.artworkURL,
                          topSongs: page.tracks, releases: page.collections.filter { $0.kind == .album },
                          relatedArtists: page.collections.filter { $0.kind == .artist }, monthlyAudience: audience)
    }

    func recommendations(seed: Track, language: MusicLanguage) async throws -> [Track] {
        guard let videoID = CatalogText.videoID(seed.id) else { throw MusicServiceError.invalidResponse }
        let response = try await request("next", payload: Self.radioPayload(videoID), ttl: 5 * 60,
                                        cacheIf: { (try? Self.radioTracks($0, excluding: videoID).isEmpty) == false })
        let tracks = CatalogDiscovery.select(try CatalogParser.radio(response.json), language: language, excluding: videoID)
        try Task.checkCancellation()
        return Array(tracks.prefix(40))
    }

    func lyrics(for track: Track) async throws -> LyricsDocument {
        try Task.checkCancellation()
        guard let id = CatalogText.videoID(track.id) else { throw MusicServiceError.invalidResponse }
        let next = try await request("next", payload: ["videoId": .string(id), "isAudioOnly": true], ttl: 5 * 60)
        try Task.checkCancellation()
        guard let link = try YouTubeLyricsParser.link(in: next.json, for: track) else {
            Self.logger.debug("linkedLyricsAvailable=0 linkedLyricsMissing=1")
            return LyricsDocument(trackID: track.id, kind: .unavailable, source: LyricsSource.youTubeMusic.rawValue, fetchedAt: next.fetchedAt)
        }
        let response = try await request("browse", payload: ["browseId": .string(link.browseID)], ttl: 15 * 60)
        try Task.checkCancellation()
        let document = try YouTubeLyricsParser.document(response.json, linkedBy: link, for: track, fetchedAt: response.fetchedAt)
        Self.logger.debug("linkedLyricsAvailable=\(document.kind == .plain ? 1 : 0) linkedLyricsMissing=\(document.kind == .unavailable ? 1 : 0) source=\(document.providerSource?.rawValue ?? "unknown", privacy: .public)")
        return document
    }

    /// No language targeting or artist allow-list here: autoplay must follow the song's own neighbors, so an
    /// English seed is not pruned to a fixed artist set the way Home's `recommendations` mixes are.
    func radio(seed: Track) async throws -> [Track] {
        try await radio(seed: seed, forceRefresh: false)
    }

    func radio(seed: Track, forceRefresh: Bool) async throws -> [Track] {
        guard let videoID = CatalogText.videoID(seed.id) else { throw MusicServiceError.invalidResponse }
        let response = try await request("next", payload: Self.radioPayload(videoID), ttl: 5 * 60, forceRefresh: forceRefresh,
                                        cacheIf: { (try? Self.radioTracks($0, excluding: videoID).isEmpty) == false })
        try Task.checkCancellation()
        return try Self.radioTracks(response.json, excluding: videoID)
    }

    private static func radioTracks(_ json: CatalogJSON, excluding videoID: String) throws -> [Track] {
        var seen: Set<String> = [videoID]
        let tracks = try CatalogParser.radio(json).filter { track in
            track.isAudioRecording == true && !CatalogDiscovery.isUnwantedVersion(track.title) && seen.insert(track.id).inserted
        }
        return Array(tracks.prefix(50))
    }

    /// The seed's autoplay radio ("RDAMVM" + id), audio only, at the default tuner setting.
    private static func radioPayload(_ videoID: String) -> CatalogJSON {
        [
            "videoId": .string(videoID), "playlistId": .string("RDAMVM" + videoID),
            "enablePersistentPlaylistPanel": true, "isAudioOnly": true, "tunerSettingValue": "AUTOMIX_SETTING_NORMAL",
        ]
    }

    func discovery(languages: Set<MusicLanguage>) async throws -> [DiscoverySection] {
        try Task.checkCancellation()
        guard !languages.isEmpty else { return [] }
        _ = try await configuration.version()
        return try await withThrowingTaskGroup(of: (MusicLanguage, [DiscoverySection]).self) { group in
            for language in MusicLanguage.allCases where languages.contains(language) {
                group.addTask { (language, try await self.sections(for: language)) }
            }
            var sections: [MusicLanguage: [DiscoverySection]] = [:]
            for try await (language, value) in group { sections[language] = value }
            try Task.checkCancellation()
            return MusicLanguage.allCases.flatMap { sections[$0] ?? [] }
        }
    }

    static func searchParameters(_ filter: SearchFilter) -> String {
        switch filter {
        case .songs: "EgWKAQIIAWoMEA4QChADEAQQCRAF"
        case .albums: "EgWKAQIYAWoMEA4QChADEAQQCRAF"
        case .artists: "EgWKAQIgAWoMEA4QChADEAQQCRAF"
        case .playlists: "Eg-KAQwIABAAGAAgACgBMABqChAEEAMQCRAFEAo%3D"
        }
    }

    func audioMetadata(for ids: [String], inheriting context: CatalogParser.RowContext = .init()) async throws -> [Track] {
        var seen = Set<String>()
        let ids = ids.compactMap(CatalogText.videoID).filter { seen.insert($0).inserted }
        var result: [Track] = []
        for offset in stride(from: 0, to: ids.count, by: 50) {
            let batch = ids[offset..<min(offset + 50, ids.count)]
            let response = try await request("music/get_queue", payload: ["videoIds": .array(batch.map { .string($0) })], ttl: 60 * 60)
            result += try CatalogParser.queue(response.json, inheriting: context).filter { $0.isAudioRecording == true && seen.contains($0.id) }
        }
        try Task.checkCancellation()
        return CatalogText.uniqueTracks(result)
    }

    private static func browseID(_ value: String) throws -> String {
        guard let id = CatalogText.identifier(value) else {
            throw MusicServiceError.unavailable("This collection has no usable YouTube Music identifier.")
        }
        if id.hasPrefix("PL") || id.hasPrefix("OLAK") || id.hasPrefix("RDCLAK") { return "VL" + id }
        guard ["VL", "UC", "MPRE", "MPAL", "MPAD"].contains(where: id.hasPrefix) else {
            throw MusicServiceError.unavailable("This type of YouTube Music collection is not supported.")
        }
        return id
    }

    // MARK: Song search

    private func songSearch(query: String, cursor: CatalogContinuation?, scope: String) async throws -> CatalogPage {
        if let cursor {
            let (parsed, response) = try await songPage(query: query, cursor: cursor)
            var page = parsed
            page.correctedQuery = page.correctedQuery ?? cursor.correctedQuery
            page.featuredArtist = cursor.featuredArtist
            page.tracks = SearchRelevance.rank(page.tracks, query: page.correctedQuery ?? query, artist: cursor.featuredArtist)
            try Task.checkCancellation()
            return try CatalogContinuation.attach(to: page, response: response, previous: cursor, scope: scope)
        }
        // Warm the client version so the concurrent requests below share one bootstrap.
        _ = try await configuration.version()
        // Speculative and best-effort: only cancellation may surface from the artist lookup.
        async let speculative = artistMatch(query: query)
        var (page, response) = try await songPage(query: query, cursor: nil)
        if page.tracks.isEmpty, let corrected = page.correctedQuery {
            let retry = try await songPage(query: corrected, cursor: nil)
            if !retry.page.tracks.isEmpty {
                (page, response) = retry
                page.correctedQuery = corrected
            }
        }
        var featured: MusicCollection?
        var leading: [Track] = []
        if let match = try await speculative,
           page.tracks.filter({ SearchRelevance.tier(of: $0, query: query, artist: match.artist) == 0 }).count
            >= SearchRelevance.minimumFeaturedTracks {
            featured = match.artist
            leading = match.page?.topSongs ?? []
        }
        let ranked = SearchRelevance.rank(page.tracks, query: page.correctedQuery ?? query, artist: featured)
        page.tracks = CatalogText.uniqueTracks(leading + ranked)
        page.featuredArtist = featured
        try Task.checkCancellation()
        return try CatalogContinuation.attach(to: page, response: response, previous: nil, scope: scope,
                                              featuredArtist: featured, correctedQuery: page.correctedQuery)
    }

    /// One songs page with rows that only lacked an ATV confirmation restored through get_queue, in provider order.
    private func songPage(query: String, cursor: CatalogContinuation?) async throws -> (page: CatalogPage, response: CatalogResponse) {
        let response = try await searchResponse(query: query, filter: .songs, cursor: cursor)
        try Task.checkCancellation()
        var page = try CatalogParser.search(response.json, filter: .songs, query: query)
        let order = CatalogParser.searchAudioCandidateIDs(response.json)
        let existing = Set(page.tracks.map(\.id))
        let candidates = Array(order.filter { !existing.contains($0) }.prefix(50))
        if !candidates.isEmpty {
            do {
                let audio = try await audioMetadata(for: candidates)
                let byID = Self.mergedByID(page.tracks, audio)
                page.tracks = CatalogText.uniqueTracks(order.compactMap { byID[$0] } + page.tracks)
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                Self.logger.warning("Search audio validation failed; unconfirmed song rows remain excluded.")
            }
        }
        page.tracks = Self.preservingPlayCounts(page.tracks, from: response.json)
        return (page, response)
    }

    private func artistMatch(query: String) async throws -> ArtistMatch? {
        do {
            // Successful songs must not spend radio's request deadline waiting for optional artist enrichment.
            return try await PlaybackDeadline.run(seconds: Self.artistEnrichmentTimeout) { () async throws -> ArtistMatch? in
                let response = try await self.searchResponse(query: query, filter: .artists, cursor: nil)
                let artists = try CatalogParser.search(response.json, filter: .artists, query: query)
                guard let match = SearchRelevance.matchedArtist(in: artists.collections, query: query,
                                                                correctedQuery: artists.correctedQuery) else { return nil }
                var page: ArtistPage?
                do {
                    page = try await self.artist(id: match.id)
                } catch {
                    if error is CancellationError || Task.isCancelled { throw CancellationError() }
                    Self.logger.warning("Artist page for a song search failed; the artist is featured without top songs.")
                }
                return ArtistMatch(artist: match, page: page)
            }
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            Self.logger.warning("Artist resolution for a song search failed; results stay in ranked provider order.")
            return nil
        }
    }

    private func searchResponse(query: String, filter: SearchFilter, cursor: CatalogContinuation?) async throws -> CatalogResponse {
        let payload: CatalogJSON = cursor.map { ["continuation": .string($0.token)] }
            ?? ["query": .string(query), "params": .string(Self.searchParameters(filter))]
        return try await request("search", payload: payload, ttl: 120, visitorData: cursor?.visitorData)
    }

    // MARK: Browse

    private func browseAll(id: String) async throws -> (page: CatalogPage, first: CatalogResponse) {
        let (initial, first) = try await browsePage(id: id, continuation: nil)
        let context = CatalogParser.rowContext(first.json, id: id)
        var page = initial
        var visited = Set<String>()
        for _ in 1..<maximumBrowsePages {
            guard let token = page.continuation else { break }
            guard visited.insert(token).inserted else { throw MusicServiceError.invalidResponse }
            let (next, _) = try await browsePage(id: id, continuation: token, inheriting: context)
            page.tracks = CatalogText.uniqueTracks(page.tracks + next.tracks)
            page.collections = CatalogText.uniqueCollections(page.collections + next.collections)
            page.continuation = next.continuation
        }
        if page.continuation != nil {
            Self.logger.warning("Collection exceeded the bounded automatic pagination budget; a continuation remains.")
        }
        if page.tracks.contains(where: { $0.duration == nil }) {
            page.tracks = try await enrichMetadata(page.tracks, inheriting: context)
        }
        try Task.checkCancellation()
        return (page, first)
    }

    private func browsePage(id: String, continuation: String?, inheriting inherited: CatalogParser.RowContext? = nil) async throws
        -> (page: CatalogPage, response: CatalogResponse) {
        let scope = "browse|\(id)"
        let cursor = try continuation.map { try CatalogContinuation.decode($0, scope: scope) }
        let payload: CatalogJSON = cursor.map { ["continuation": .string($0.token)] } ?? ["browseId": .string(id)]
        let response = try await request("browse", payload: payload, ttl: 10 * 60, visitorData: cursor?.visitorData)
        let context = CatalogParser.rowContext(response.json, id: id, inheriting: inherited)
        var page = try CatalogParser.browse(response.json, id: id, inheriting: context)
        let order = CatalogParser.audioCandidateIDs(response.json)
        let existing = Set(page.tracks.map(\.id))
        let candidates = order.filter { !existing.contains($0) }
        if !candidates.isEmpty {
            do {
                let audio = try await audioMetadata(for: candidates, inheriting: context)
                let byID = Self.mergedByID(page.tracks, audio)
                page.tracks = CatalogText.uniqueTracks(order.compactMap { byID[$0] } + page.tracks)
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                Self.logger.warning("Album-audio counterpart validation failed; explicit video rows remain excluded.")
            }
        }
        page.tracks = Self.preservingPlayCounts(page.tracks, from: response.json)
        return (try CatalogContinuation.attach(to: page, response: response, previous: cursor, scope: scope), response)
    }

    private static func preservingPlayCounts(_ tracks: [Track], from json: CatalogJSON) -> [Track] {
        let enriched = CatalogParser.enrichPlayCounts(tracks, from: json)
        let updated = zip(tracks, enriched).filter { $0.0.playCount != $0.1.playCount }.count
        let missing = enriched.filter { $0.playCount == nil }.count
        logger.debug("providerPlayCountUpdated=\(updated) providerPlayCountMissing=\(missing)")
        return enriched
    }

    /// Page rows win over get_queue rows for the same recording; the queue only fills in a missing play count.
    private static func mergedByID(_ page: [Track], _ queue: [Track]) -> [String: Track] {
        var byID = Dictionary(uniqueKeysWithValues: CatalogText.uniqueTracks(page + queue).map { ($0.id, $0) })
        for extra in queue where byID[extra.id]?.playCount == nil { byID[extra.id]?.playCount = extra.playCount }
        return byID
    }

    private func request(_ endpoint: String, payload: CatalogJSON, ttl: TimeInterval, visitorData: String? = nil, forceRefresh: Bool = false,
                         cacheIf: @Sendable (CatalogJSON) -> Bool = { _ in true }) async throws -> CatalogResponse {
        let version = try await configuration.version()
        var body = payload.object
        var client: [String: CatalogJSON] = [
            "clientName": "WEB_REMIX", "clientVersion": .string(version), "hl": "en", "gl": "IN",
        ]
        if let visitorData { client["visitorData"] = .string(visitorData) }
        body["context"] = ["client": .object(client)]
        return try await transport.post(baseURL: CatalogTransport.musicURL, endpoint: endpoint, body: .object(body), ttl: ttl,
                                        forceRefresh: forceRefresh, cacheIf: cacheIf)
    }

    private func enrichMetadata(_ tracks: [Track], inheriting context: CatalogParser.RowContext) async throws -> [Track] {
        let missing = tracks.filter { $0.duration == nil }.prefix(50)
        guard !missing.isEmpty else { return tracks }
        do {
            let response = try await request("music/get_queue", payload: ["videoIds": .array(missing.map { .string($0.id) })], ttl: 60 * 60)
            let metadata = Dictionary(try CatalogParser.queue(response.json, inheriting: context).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            return tracks.map { original in
                guard let extra = metadata[original.id] else { return original }
                var track = original
                track.adoptMissingMetadata(from: extra)
                if extra.isAudioRecording == true {
                    track.title = extra.title
                    track.artworkURL = extra.artworkURL ?? track.artworkURL
                    track.isAudioRecording = true
                }
                return track
            }
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            Self.logger.warning("Optional collection duration lookup failed; preserving provider tracks.")
            return tracks
        }
    }

    private func sections(for language: MusicLanguage) async throws -> [DiscoverySection] {
        let starters = CatalogDiscovery.starters(for: language)
        guard let seed = starters.first else { return [] }
        var sections: [DiscoverySection] = []
        do {
            let tracks = try await recommendations(seed: seed, language: language)
            if !tracks.isEmpty {
                // This mix is seeded by a fixed starter, not by the listener; the title must not imply otherwise.
                sections.append(DiscoverySection(id: "radio-\(language.rawValue)",
                                                 title: language == .hindi ? "Hindi mix" : "English mix",
                                                 subtitle: "A YouTube Music radio seeded by “\(seed.title)”",
                                                 language: language, tracks: Array(tracks.prefix(20))))
            }
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            Self.logger.warning("A language-targeted radio could not be loaded.")
        }
        do {
            let id = language == .hindi ? CatalogDiscovery.hindiPlaylist : CatalogDiscovery.englishPlaylist
            let page = try await browse(id: id)
            let tracks = CatalogDiscovery.select(page.tracks, language: language)
            if !tracks.isEmpty {
                let title = language == .hindi ? "Bollywood hits" : "Pop hits"
                let origin = language == .hindi ? "Bollywood Hitlist" : "Pop’s Biggest Hits"
                sections.append(DiscoverySection(id: "editorial-\(language.rawValue)", title: title,
                                                 subtitle: "Selected from YouTube Music’s \(origin)",
                                                 language: language, tracks: Array(tracks.prefix(24))))
            }
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            Self.logger.warning("An editorial discovery source could not be loaded.")
        }
        try Task.checkCancellation()
        if sections.isEmpty {
            sections.append(DiscoverySection(id: "starter-\(language.rawValue)", title: "Start somewhere good",
                                              subtitle: "Breezy editorial starters · Live discovery is unavailable",
                                             language: language, tracks: starters))
        }
        return sections
    }
}

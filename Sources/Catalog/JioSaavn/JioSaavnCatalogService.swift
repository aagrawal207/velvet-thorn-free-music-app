import Foundation
import OSLog

/// JioSaavn's unofficial web API behind the shared catalog protocols. Every id it hands out is `saavn:` prefixed;
/// calls for ids of another source or for surfaces it has no data for answer empty rather than throwing.
actor JioSaavnCatalogService: MusicCatalogProviding, LyricsProviding, AlbumDescriptionProviding {
    static let lyricsSource = "JioSaavn"
    static let searchPageSize = 20
    static let radioLimit = 50
    private static let playlistPageSize = 100
    private static let maximumPlaylistPages = 3
    private static let logger = Logger(subsystem: "com.agraabhi.ganabajana", category: "JioSaavn")

    let transport: JioSaavnTransport

    init(transport: JioSaavnTransport = JioSaavnTransport()) {
        self.transport = transport
    }

    init(session: URLSession, now: @escaping @Sendable () -> Date = { Date() }) {
        transport = JioSaavnTransport(session: session, now: now)
    }

    // MARK: MusicCatalogProviding

    func search(query: String, filter: SearchFilter, continuation: String?) async throws -> CatalogPage {
        try Task.checkCancellation()
        // The composite paginates through YouTube's continuation; a second page here would belong to another query.
        guard continuation == nil, let query = CatalogText.clean(query), query.utf8.count <= 1_024 else { return CatalogPage() }
        let call: String
        switch filter {
        case .songs: call = "search.getResults"
        case .albums: call = "search.getAlbumResults"
        case .artists: call = "search.getArtistResults"
        case .playlists: call = "search.getPlaylistResults"
        }
        let response = try await transport.get(call: call, parameters: [("q", query), ("p", "1"), ("n", String(Self.searchPageSize))],
                                               ttl: JioSaavnTransport.searchLifetime)
        try Task.checkCancellation()
        let page = JioSaavnParser.search(response.json, filter: filter)
        Self.logger.debug("event=search filter=\(filter.rawValue, privacy: .public) tracks=\(page.tracks.count) collections=\(page.collections.count)")
        return page
    }

    func browse(id: String) async throws -> CatalogPage {
        try Task.checkCancellation()
        guard MusicSource.source(of: id) == .jioSaavn, let providerID = JioSaavnText.identifier(MusicSource.entityProviderID(of: id)) else {
            return CatalogPage()
        }
        switch MusicSource.entityKind(of: id) {
        case .album?:
            let response = try await transport.get(call: "content.getAlbumDetails", parameters: [("albumid", providerID)],
                                                   ttl: JioSaavnTransport.detailsLifetime)
            guard let page = JioSaavnParser.albumPage(response.json) else {
                throw MusicServiceError.unavailable("This album is no longer available on JioSaavn.")
            }
            Self.logger.debug("event=browse kind=album tracks=\(page.tracks.count)")
            return page
        case .playlist?:
            return try await playlist(providerID)
        case .artist?:
            let artist = try await artist(id: id)
            return CatalogPage(tracks: artist.topSongs, collections: artist.releases + artist.relatedArtists, title: artist.name)
        case .track?:
            let songs = try await songDetails(providerIDs: [providerID])
            return CatalogPage(tracks: songs.map(\.track), title: songs.first?.track.title)
        case nil:
            return CatalogPage()
        }
    }

    func artist(id: String) async throws -> ArtistPage {
        try Task.checkCancellation()
        guard MusicSource.source(of: id) == .jioSaavn, MusicSource.entityKind(of: id) == .artist,
              let providerID = JioSaavnText.identifier(MusicSource.entityProviderID(of: id)) else {
            throw MusicServiceError.unavailable("This JioSaavn page is not an artist.")
        }
        let response = try await transport.get(call: "artist.getArtistPageDetails", parameters: [("artistId", providerID)],
                                               ttl: JioSaavnTransport.detailsLifetime)
        try Task.checkCancellation()
        guard let page = JioSaavnParser.artistPage(response.json, id: id) else {
            throw MusicServiceError.unavailable("This artist is no longer available on JioSaavn.")
        }
        Self.logger.debug("event=artist topSongs=\(page.topSongs.count) releases=\(page.releases.count) related=\(page.relatedArtists.count)")
        return page
    }

    func recommendations(seed: Track, language: MusicLanguage) async throws -> [Track] {
        let tracks = try await radio(seed: seed, forceRefresh: false)
        return Array(tracks.filter { $0.language == nil || $0.language == language }.prefix(40))
    }

    func radio(seed: Track) async throws -> [Track] {
        try await radio(seed: seed, forceRefresh: false)
    }

    /// `reco.getreco` answers only for the Android context; the web context returns an empty array.
    func radio(seed: Track, forceRefresh: Bool) async throws -> [Track] {
        try Task.checkCancellation()
        guard seed.source == .jioSaavn, MusicSource.entityKind(of: seed.id) == .track,
              let providerID = JioSaavnText.identifier(seed.providerID) else { return [] }
        let response = try await transport.get(call: "reco.getreco", parameters: [("pid", providerID)], context: .android,
                                               ttl: 5 * 60, forceRefresh: forceRefresh,
                                               cacheIf: { !JioSaavnParser.recommendations($0, seedProviderID: providerID).isEmpty })
        try Task.checkCancellation()
        let tracks = Array(JioSaavnParser.recommendations(response.json, seedProviderID: providerID).prefix(Self.radioLimit))
        Self.logger.debug("event=radio tracks=\(tracks.count)")
        return tracks
    }

    /// Home discovery stays with the primary catalog; JioSaavn has no equivalent editorial shelves here.
    func discovery(languages: Set<MusicLanguage>) async throws -> [DiscoverySection] { [] }

    // MARK: LyricsProviding

    /// The lyrics id observed in `more_info.lyrics_id` equals the song id, so no extra lookup is needed.
    func lyrics(for track: Track) async throws -> LyricsDocument {
        try Task.checkCancellation()
        guard track.source == .jioSaavn, MusicSource.entityKind(of: track.id) == .track,
              let providerID = JioSaavnText.identifier(track.providerID) else {
            return LyricsDocument(trackID: track.id, kind: .unavailable, source: Self.lyricsSource)
        }
        let response: JioSaavnResponse
        do {
            response = try await transport.get(call: "lyrics.getLyrics", parameters: [("lyrics_id", providerID)],
                                               ttl: JioSaavnTransport.detailsLifetime)
        } catch is JioSaavnTransport.APIFailure {
            // The provider answers a failure envelope for songs without lyrics; that is absence, not an outage.
            Self.logger.debug("event=lyrics available=0")
            return LyricsDocument(trackID: track.id, kind: .unavailable, source: Self.lyricsSource)
        }
        try Task.checkCancellation()
        guard let text = JioSaavnParser.lyrics(response.json), text.utf8.count <= LRCParser.maximumSourceBytes else {
            Self.logger.debug("event=lyrics available=0")
            return LyricsDocument(trackID: track.id, kind: .unavailable, source: Self.lyricsSource, fetchedAt: response.fetchedAt)
        }
        Self.logger.debug("event=lyrics available=1")
        return LyricsDocument(trackID: track.id, kind: .plain, plainText: text, source: Self.lyricsSource, fetchedAt: response.fetchedAt)
    }

    // MARK: AlbumDescriptionProviding

    /// Successful absence: the provider supplies no licensed prose for albums.
    func albumDescription(id: String) async throws -> AlbumDescription? { nil }

    // MARK: Songs

    /// Fresh song rows with their encrypted media fields; the resolver calls this at play time.
    func songDetails(providerIDs: [String], forceRefresh: Bool = false) async throws -> [JioSaavnSong] {
        var seen = Set<String>()
        let ids = providerIDs.compactMap(JioSaavnText.identifier).filter { seen.insert($0).inserted }
        guard !ids.isEmpty else { return [] }
        let response = try await transport.get(call: "song.getDetails", parameters: [("pids", ids.prefix(20).joined(separator: ","))],
                                               ttl: JioSaavnTransport.detailsLifetime, forceRefresh: forceRefresh,
                                               cacheIf: { !JioSaavnParser.songDetails($0).isEmpty })
        try Task.checkCancellation()
        return JioSaavnParser.songDetails(response.json)
    }

    private func playlist(_ providerID: String) async throws -> CatalogPage {
        var page = CatalogPage()
        var total = Int.max
        var number = 1
        while page.tracks.count < total, number <= Self.maximumPlaylistPages {
            let response = try await transport.get(call: "playlist.getDetails",
                                                   parameters: [("listid", providerID), ("p", String(number)), ("n", String(Self.playlistPageSize))],
                                                   ttl: JioSaavnTransport.detailsLifetime)
            try Task.checkCancellation()
            guard let parsed = JioSaavnParser.playlistPage(response.json) else {
                throw MusicServiceError.unavailable("This playlist is no longer available on JioSaavn.")
            }
            let known = Set(page.tracks.map(\.id))
            let fresh = parsed.page.tracks.filter { !known.contains($0.id) }
            page.title = page.title ?? parsed.page.title
            page.tracks += fresh
            total = parsed.total
            if fresh.isEmpty { break }
            number += 1
        }
        if page.tracks.count < total { Self.logger.notice("event=browse kind=playlist truncated=1 tracks=\(page.tracks.count)") }
        else { Self.logger.debug("event=browse kind=playlist tracks=\(page.tracks.count)") }
        return page
    }
}

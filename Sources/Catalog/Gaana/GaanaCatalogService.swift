import Foundation
import OSLog

/// Gaana's unofficial web API behind the shared catalog protocols. Every id it hands out is `gaana:` prefixed;
/// calls for ids of another source or for surfaces it has no public data for answer empty rather than throwing.
actor GaanaCatalogService: MusicCatalogProviding, AlbumDescriptionProviding {
    static let radioLimit = 20
    static let artistPageSize = 20
    private static let logger = Logger(subsystem: "com.agraabhi.ganabajana", category: "Gaana")

    let transport: GaanaTransport

    init(transport: GaanaTransport = GaanaTransport()) {
        self.transport = transport
    }

    init(session: URLSession, now: @escaping @Sendable () -> Date = { Date() }) {
        transport = GaanaTransport(session: session, now: now)
    }

    // MARK: MusicCatalogProviding

    func search(query: String, filter: SearchFilter, continuation: String?) async throws -> CatalogPage {
        try Task.checkCancellation()
        // The composite paginates through YouTube's continuation; a second page here would belong to another query.
        guard continuation == nil, let query = CatalogText.clean(query), query.utf8.count <= 1_024 else { return CatalogPage() }
        let include: String
        switch filter {
        case .songs: include = "track"
        case .albums: include = "album"
        case .artists: include = "artist"
        case .playlists: include = "playlist"
        }
        let response = try await transport.get(GaanaTransport.searchURL(query: query, include: include), ttl: GaanaTransport.searchLifetime)
        try Task.checkCancellation()
        let page = GaanaParser.search(response.json, filter: filter)
        Self.logger.debug("event=search filter=\(filter.rawValue, privacy: .public) tracks=\(page.tracks.count) collections=\(page.collections.count)")
        return page
    }

    func browse(id: String) async throws -> CatalogPage {
        try Task.checkCancellation()
        guard MusicSource.source(of: id) == .gaana, let providerID = GaanaText.identifier(MusicSource.entityProviderID(of: id)) else {
            return CatalogPage()
        }
        switch MusicSource.entityKind(of: id) {
        case .album?:
            let response = try await details(path: "album/detail", parameters: [("album_id", providerID)],
                                             missing: "This album is no longer available on Gaana.")
            guard let page = GaanaParser.albumPage(response.json) else {
                throw MusicServiceError.unavailable("This album is no longer available on Gaana.")
            }
            Self.logger.debug("event=browse kind=album tracks=\(page.tracks.count)")
            return page
        case .playlist?:
            let response = try await details(path: "playlist/detail", parameters: [("playlist_id", providerID)],
                                             missing: "This playlist is no longer available on Gaana.")
            guard let page = GaanaParser.playlistPage(response.json) else {
                throw MusicServiceError.unavailable("This playlist is no longer available on Gaana.")
            }
            Self.logger.debug("event=browse kind=playlist tracks=\(page.tracks.count)")
            return page
        case .artist?:
            let artist = try await artist(id: id)
            return CatalogPage(tracks: artist.topSongs, collections: artist.releases + artist.relatedArtists, title: artist.name)
        case .track?:
            let song = try await songDetails(providerID: providerID)
            return CatalogPage(tracks: [song?.track].compactMap { $0 }, title: song?.track.title)
        case nil:
            return CatalogPage()
        }
    }

    /// Three bounded calls: the header with its top songs, the album list and the similar-artist list.
    func artist(id: String) async throws -> ArtistPage {
        try Task.checkCancellation()
        guard MusicSource.source(of: id) == .gaana, MusicSource.entityKind(of: id) == .artist,
              let providerID = GaanaText.identifier(MusicSource.entityProviderID(of: id)) else {
            throw MusicServiceError.unavailable("This Gaana page is not an artist.")
        }
        let detail = try await details(path: "artist/entity/detail/v1",
                                       parameters: [("artist_id", providerID), ("sortBy", "popularity"), ("sortOrder", "0")],
                                       streamFields: false, missing: "This artist is no longer available on Gaana.")
        try Task.checkCancellation()
        let limit = "0,\(Self.artistPageSize)"
        let albums = try? await details(path: "home/artist/album/\(providerID)", parameters: [("limit", limit)], streamFields: false)
        let similar = try? await details(path: "player/similar-artists/\(providerID)", parameters: [("limit", limit)], streamFields: false)
        try Task.checkCancellation()
        guard let page = GaanaParser.artistPage(detail.json, albums: albums?.json ?? .null, similar: similar?.json ?? .null, id: id) else {
            throw MusicServiceError.unavailable("This artist is no longer available on Gaana.")
        }
        Self.logger.debug("event=artist topSongs=\(page.topSongs.count) releases=\(page.releases.count) related=\(page.relatedArtists.count)")
        return page
    }

    func recommendations(seed: Track, language: MusicLanguage) async throws -> [Track] {
        let tracks = try await radio(seed: seed, forceRefresh: false)
        return tracks.filter { $0.language == nil || $0.language == language }
    }

    func radio(seed: Track) async throws -> [Track] {
        try await radio(seed: seed, forceRefresh: false)
    }

    /// Gaana's recommendation endpoints need a signed-in token, so radio is the seed's first credited artist's
    /// popular songs. A seed whose credits carry no Gaana artist id (search rows) is looked up once for its ids.
    func radio(seed: Track, forceRefresh: Bool) async throws -> [Track] {
        try Task.checkCancellation()
        guard seed.source == .gaana, MusicSource.entityKind(of: seed.id) == .track,
              let providerID = GaanaText.identifier(seed.providerID) else { return [] }
        var artistID = Self.artistProviderID(in: seed.credits)
        if artistID == nil, let song = try await songDetails(providerID: providerID, forceRefresh: forceRefresh) {
            artistID = Self.artistProviderID(in: song.track.credits)
        }
        guard let artistID else {
            Self.logger.debug("event=radio tracks=0")
            return []
        }
        let response = try await transport.get(
            GaanaTransport.apiURL(path: "home/artist/tracks/\(artistID)",
                                  parameters: [("sortBy", "popularity"), ("sortOrder", "0"), ("song_type", "new"), ("limit", "0,\(Self.radioLimit + 1)")]),
            ttl: 5 * 60, forceRefresh: forceRefresh, cacheIf: { !GaanaParser.entityTracks($0["entities"].array).isEmpty })
        try Task.checkCancellation()
        let tracks = Array(GaanaParser.entityTracks(response.json["entities"].array).filter { $0.id != seed.id }.prefix(Self.radioLimit))
        Self.logger.debug("event=radio tracks=\(tracks.count)")
        return tracks
    }

    /// Home discovery stays with the primary catalog; Gaana has no equivalent editorial shelves here.
    func discovery(languages: Set<MusicLanguage>) async throws -> [DiscoverySection] { [] }

    // MARK: AlbumDescriptionProviding

    /// Successful absence: the provider's album prose is generated boilerplate, not licensed description.
    func albumDescription(id: String) async throws -> AlbumDescription? { nil }

    // MARK: Songs

    /// The fresh song row with its encrypted media fields, or nil for an unknown id; the resolver calls this at play time.
    func songDetails(providerID: String, forceRefresh: Bool = false) async throws -> GaanaSong? {
        guard let providerID = GaanaText.identifier(providerID) else { return nil }
        let response: GaanaResponse
        do {
            response = try await transport.get(
                GaanaTransport.apiURL(path: "", parameters: [("type", "song"), ("subtype", "song_detail"), ("track_id", providerID), ("limit", "0,1")]),
                ttl: GaanaTransport.detailsLifetime, forceRefresh: forceRefresh, cacheIf: { !GaanaParser.songDetails($0).isEmpty })
        } catch is GaanaTransport.APIFailure {
            return nil
        }
        try Task.checkCancellation()
        return GaanaParser.songDetails(response.json).first { $0.track.providerID == providerID }
    }

    /// The provider answers a `status: 0` envelope for a removed entity; `missing` is the listener-facing wording.
    private func details(path: String, parameters: [(String, String)], streamFields: Bool = true,
                         missing: String? = nil) async throws -> GaanaResponse {
        do {
            return try await transport.get(GaanaTransport.apiURL(path: path, parameters: parameters, streamFields: streamFields),
                                           ttl: GaanaTransport.detailsLifetime)
        } catch let failure as GaanaTransport.APIFailure {
            guard let missing else { throw failure }
            throw MusicServiceError.unavailable(missing)
        }
    }

    private static func artistProviderID(in credits: [ArtistCredit]) -> String? {
        credits.lazy.compactMap { credit -> String? in
            guard let id = credit.id, MusicSource.source(of: id) == .gaana, MusicSource.entityKind(of: id) == .artist else { return nil }
            return GaanaText.identifier(MusicSource.entityProviderID(of: id))
        }.first
    }
}

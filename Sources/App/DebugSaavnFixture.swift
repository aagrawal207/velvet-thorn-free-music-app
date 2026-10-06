#if DEBUG
import Foundation

/// Network-free JioSaavn stand-in for UI tests (`--uitesting --seed-ui --saavn-fixture`): two songs and one album
/// answer the query "tum"; every other query is empty. Ids follow the production `saavn:` scheme.
struct DebugSaavnFixtureCatalog: MusicCatalogProviding, LyricsProviding {
    static let artist = ArtistCredit(name: "Mohit Chauhan", id: MusicSource.jioSaavn.collectionID(.artist, providerID: "fixtureMohit01"))
    static let albumID = MusicSource.jioSaavn.collectionID(.album, providerID: "fixtureJabWeMet")
    static let firstSongID = MusicSource.jioSaavn.trackID(forProviderID: "fixtureTum01")
    static let secondSongID = MusicSource.jioSaavn.trackID(forProviderID: "fixtureTum02")

    static var songs: [Track] {
        let artwork = DebugArtworkURLProtocol.url("album")
        return [
            Track(id: firstSongID, title: "Tum Se Hi", credits: [artist], albumTitle: "Jab We Met", albumID: albumID,
                  duration: 320, artworkURL: artwork, language: .hindi, isAudioRecording: true, playCount: 12_345_678),
            Track(id: secondSongID, title: "Tum Ho Toh", credits: [artist, ArtistCredit(name: "Pritam")], albumTitle: "Jab We Met",
                  albumID: albumID, duration: 291, artworkURL: artwork, language: .hindi, isAudioRecording: true, playCount: 2_345_678),
        ]
    }

    static var album: MusicCollection {
        MusicCollection(id: albumID, title: "Jab We Met", subtitle: "Pritam · 2007", artworkURL: DebugArtworkURLProtocol.url("album"),
                        kind: .album, language: .hindi)
    }

    func search(query: String, filter: SearchFilter, continuation: String?) async throws -> CatalogPage {
        try await Task.sleep(for: .milliseconds(80))
        guard continuation == nil, query.localizedCaseInsensitiveContains("tum") else { return CatalogPage() }
        switch filter {
        case .songs: return CatalogPage(tracks: Self.songs)
        case .albums: return CatalogPage(collections: [Self.album])
        case .artists: return CatalogPage(collections: [Self.artist.collection].compactMap { $0 })
        case .playlists: return CatalogPage()
        }
    }

    func browse(id: String) async throws -> CatalogPage {
        guard id == Self.albumID else { return CatalogPage() }
        return CatalogPage(tracks: Self.songs, title: Self.album.title, credits: [Self.artist, ArtistCredit(name: "Pritam")])
    }

    func artist(id: String) async throws -> ArtistPage {
        ArtistPage(id: id, name: Self.artist.name, topSongs: Self.songs, releases: [Self.album])
    }

    func recommendations(seed: Track, language: MusicLanguage) async throws -> [Track] { Self.songs.filter { $0.id != seed.id } }
    func radio(seed: Track) async throws -> [Track] { Self.songs.filter { $0.id != seed.id } }
    func radio(seed: Track, forceRefresh: Bool) async throws -> [Track] { try await radio(seed: seed) }
    func discovery(languages: Set<MusicLanguage>) async throws -> [DiscoverySection] { [] }

    func lyrics(for track: Track) async throws -> LyricsDocument {
        LyricsDocument(trackID: track.id, kind: .plain, plainText: "Tum se hi din hota hai\nSurmayi shaam aati hai",
                       source: JioSaavnCatalogService.lyricsSource)
    }
}
#endif

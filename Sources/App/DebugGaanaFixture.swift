#if DEBUG
import Foundation

/// Network-free Gaana stand-in for UI tests (`--uitesting --seed-ui --gaana-fixture`): one song and one album answer
/// the query "tum"; every other query is empty. Ids follow the production `gaana:` scheme with numeric provider ids.
struct DebugGaanaFixtureCatalog: MusicCatalogProviding {
    static let artist = ArtistCredit(name: "Arijit Singh", id: MusicSource.gaana.collectionID(.artist, providerID: "52767"))
    static let composer = ArtistCredit(name: "Mithoon", id: MusicSource.gaana.collectionID(.artist, providerID: "27"))
    static let albumID = MusicSource.gaana.collectionID(.album, providerID: "92317")
    static let songID = MusicSource.gaana.trackID(forProviderID: "944286")

    static var song: Track {
        Track(id: songID, title: "Tum Hi Ho", credits: [composer, artist], albumTitle: "Aashiqui 2", albumID: albumID,
              duration: 261, artworkURL: DebugArtworkURLProtocol.url("album"), language: .hindi, isAudioRecording: true,
              playCount: 180_685_771)
    }

    static var album: MusicCollection {
        MusicCollection(id: albumID, title: "Aashiqui 2", subtitle: "Mithoon, Jeet Gannguli, Ankit Tiwari", artworkURL: DebugArtworkURLProtocol.url("album"),
                        kind: .album, language: .hindi)
    }

    func search(query: String, filter: SearchFilter, continuation: String?) async throws -> CatalogPage {
        try await Task.sleep(for: .milliseconds(80))
        guard continuation == nil, query.localizedCaseInsensitiveContains("tum") else { return CatalogPage() }
        switch filter {
        case .songs: return CatalogPage(tracks: [Self.song])
        case .albums: return CatalogPage(collections: [Self.album])
        case .artists: return CatalogPage(collections: [Self.artist.collection].compactMap { $0 })
        case .playlists: return CatalogPage()
        }
    }

    func browse(id: String) async throws -> CatalogPage {
        guard id == Self.albumID else { return CatalogPage() }
        return CatalogPage(tracks: [Self.song], title: Self.album.title, credits: [Self.composer, Self.artist])
    }

    func artist(id: String) async throws -> ArtistPage {
        ArtistPage(id: id, name: Self.artist.name, topSongs: [Self.song], releases: [Self.album])
    }

    func recommendations(seed: Track, language: MusicLanguage) async throws -> [Track] { [] }
    func radio(seed: Track) async throws -> [Track] { [] }
    func radio(seed: Track, forceRefresh: Bool) async throws -> [Track] { [] }
    func discovery(languages: Set<MusicLanguage>) async throws -> [DiscoverySection] { [] }
}
#endif

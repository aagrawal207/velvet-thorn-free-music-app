#if DEBUG
import Foundation

actor DebugSeedRadioCatalog: MusicCatalogProviding {
    private let base: any MusicCatalogProviding
    private var failOnce: Bool
    private let slowArtist: Bool
    private let handlesRadio: Bool
    private var radioCalls: [String: Int] = [:]

    init(base: any MusicCatalogProviding, arguments: [String], handlesRadio: Bool = false) {
        self.base = base
        self.handlesRadio = handlesRadio
        failOnce = arguments.contains("--seed-radio-fail-once")
        slowArtist = arguments.contains("--seed-radio-slow-artist")
    }

    nonisolated static var extraTracks: [Track] {
        (1...8).map { index in
            Track(id: String(format: "seedMore%03d", index), title: "Radio Follow Up \(index)",
                  artists: ["Radio Artist \(index)"], duration: 262, language: .hindi, isAudioRecording: true)
        }
    }

    func search(query: String, filter: SearchFilter, continuation: String?) async throws -> CatalogPage {
        if filter == .artists {
            return CatalogPage(collections: DebugMusicFixtures.credits.filter {
                $0.name.localizedCaseInsensitiveContains(query)
            }.compactMap(\.collection))
        }
        return try await base.search(query: query, filter: filter, continuation: continuation)
    }

    func artist(id: String) async throws -> ArtistPage {
        if slowArtist { try await Task.sleep(for: .seconds(3)) }
        guard let artist = DebugMusicFixtures.credits.first(where: { $0.id == id }) else {
            return try await base.artist(id: id)
        }
        return ArtistPage(id: id, name: artist.name, topSongs: DebugMusicFixtures.songs(crediting: artist))
    }

    func radio(seed: Track) async throws -> [Track] { try await radio(seed: seed, forceRefresh: false) }

    func radio(seed: Track, forceRefresh: Bool) async throws -> [Track] {
        guard handlesRadio else { return try await base.radio(seed: seed, forceRefresh: forceRefresh) }
        if failOnce {
            failOnce = false
            throw MusicServiceError.network("The fixture radio request failed. Try More Songs to continue.")
        }
        let count = radioCalls[seed.id, default: 0]
        radioCalls[seed.id] = count + 1
        return count == 0 ? DebugMusicFixtures.tracks.filter { $0.id != seed.id } : Self.extraTracks
    }

    func browse(id: String) async throws -> CatalogPage { try await base.browse(id: id) }
    func recommendations(seed: Track, language: MusicLanguage) async throws -> [Track] {
        try await base.recommendations(seed: seed, language: language)
    }
    func discovery(languages: Set<MusicLanguage>) async throws -> [DiscoverySection] {
        try await base.discovery(languages: languages)
    }
}
#endif

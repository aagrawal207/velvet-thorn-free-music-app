import Foundation
@testable import GanaBajana

enum ArtistSpotlightTestSupport {
    static func track(_ id: String, title: String? = nil, count: Int64? = nil, language: MusicLanguage? = nil) -> Track {
        Track(id: id, title: title ?? "Song \(id)", credits: [ArtistSpotlightFixtures.artist],
              albumTitle: "Synthetic spotlight recordings", duration: 240, language: language,
              isAudioRecording: true, playCount: count)
    }

    static func page(_ tracks: [Track], releases: [MusicCollection] = []) -> ArtistPage {
        ArtistPage(id: ArtistSpotlightFixtures.artist.id!, name: ArtistSpotlightFixtures.artist.name,
                   topSongs: tracks, releases: releases)
    }

    static func document(_ track: Track, text: String = ArtistSpotlightFixtures.englishText) -> LyricsDocument {
        LyricsDocument(trackID: track.id, kind: .plain, plainText: text, sourceID: 90_001,
                       matchedTitle: track.title, matchedArtist: track.artistName)
    }

    static func catalogConfiguration(minimum: Int = 0, countSearches: Int = 0) -> ArtistSpotlightCatalogService.Configuration {
        var configuration = ArtistSpotlightCatalogService.Configuration()
        configuration.minimumSongCount = minimum
        configuration.maximumCountSearches = countSearches
        return configuration
    }

    static func originalScriptHypotheses(_ text: String) -> [String: Double] {
        if text.unicodeScalars.contains(where: { (0x0B80...0x0BFF).contains($0.value) }) { return ["ta": 0.99] }
        return ["en": 0.99]
    }
}

actor ArtistSpotlightCatalogFixture: MusicCatalogProviding {
    let searches = AppModelRequestGate<AppModelSearchRequest, CatalogPage>()
    let albums = AppModelRequestGate<String, CatalogPage>()
    private var activeRequests = 0
    private(set) var maximumActiveRequests = 0

    func search(query: String, filter: SearchFilter, continuation: String?) async throws -> CatalogPage {
        activeRequests += 1
        maximumActiveRequests = max(maximumActiveRequests, activeRequests)
        defer { activeRequests -= 1 }
        return try await searches.receive(AppModelSearchRequest(query: query, filter: filter, continuation: continuation))
    }

    func browse(id: String) async throws -> CatalogPage {
        activeRequests += 1
        maximumActiveRequests = max(maximumActiveRequests, activeRequests)
        defer { activeRequests -= 1 }
        return try await albums.receive(id)
    }

    func recommendations(seed: Track, language: MusicLanguage) async throws -> [Track] {
        throw AppModelTestFailure.unexpectedRequest("Spotlights cannot use discovery-language radio")
    }

    func radio(seed: Track) async throws -> [Track] {
        throw AppModelTestFailure.unexpectedRequest("An artist collection cannot use other artists' radio songs")
    }

    func discovery(languages: Set<MusicLanguage>) async throws -> [DiscoverySection] { [] }

    func close() async {
        await searches.close()
        await albums.close()
    }
}

actor ArtistSpotlightLyricsFixture: LyricsProviding {
    let requests = AppModelRequestGate<Track, LyricsDocument>()

    func lyrics(for track: Track) async throws -> LyricsDocument { try await requests.receive(track) }
}

@MainActor
final class ArtistSpotlightProgress {
    private(set) var updates: [[Track]] = []
    func append(_ tracks: [Track]) { updates.append(tracks) }
}

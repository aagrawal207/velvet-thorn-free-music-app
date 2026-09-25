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

    /// Search pages default to none so language suites stay free of catalog requests; the production default is two.
    static func catalogConfiguration(minimum: Int = 0, countSearches: Int = 0, searchPages: Int = 0) -> ArtistSpotlightCatalogService.Configuration {
        var configuration = ArtistSpotlightCatalogService.Configuration()
        configuration.minimumSongCount = minimum
        configuration.maximumCountSearches = countSearches
        configuration.maximumArtistSearchPages = searchPages
        return configuration
    }

    /// A recording that credits the artist after another performer, as collaborations arrive from search.
    static func collaboration(_ id: String, title: String? = nil, count: Int64? = nil) -> Track {
        var recording = track(id, title: title, count: count)
        recording.credits.insert(ArtistCredit(name: "Another Singer", id: "UCsinger"), at: 0)
        return recording
    }

    static func releaseAliases() -> (page: ArtistPage, single: Track, album: Track) {
        var single = track("listed-single", title: "River Lights", count: 900)
        single.albumTitle = "River Lights"
        single.albumID = "MPRE-single"
        single.artworkURL = URL(string: "https://example.invalid/single.jpg")
        var album = track("album-release", title: "River Lights", count: 800)
        album.albumTitle = "First Album"
        album.albumID = "MPRE-album"
        album.duration = 241
        album.isExplicit = true
        let releases = [MusicCollection(id: "MPRE-album", title: "First Album", subtitle: "Album • 2021", kind: .album),
                        MusicCollection(id: "MPRE-single", title: "River Lights", subtitle: "Single • 2020", kind: .album)]
        return (page([single], releases: releases), single, album)
    }

    static func originalScriptHypotheses(_ text: String) -> [String: Double] {
        if text.unicodeScalars.contains(where: { (0x0B80...0x0BFF).contains($0.value) }) { return ["ta": 0.99] }
        return ["en": 0.99]
    }

    // Authored lyrical fixtures exercise contractions and fragments without storing published lyrics.
    static let englishRapText = """
    [Verse 1: Guest] I'm up past midnight, my rent's late, but I'm still writing.
    I don't need a crown, I just need my people beside me.
    My phone keeps buzzing, I've got three missed calls from home.
    Can't buy back yesterday, so I'll make this moment my own.
    I'm hauling old speakers up the stairs, my shoes covered in dust.
    It ain't about a gold chain, it's about the ones I trust.
    I've been broke, I've been tired, but I won't quit this ride.
    If my brother needs a hand, he knows I'm on his side.
    """

    static let englishRockText = """
    [Verse 1] My hands are cold, but I can feel it coming.
    It's in my head, it's in the cracks beneath my feet.
    I can't sleep, I won't let go of what is left.
    My old radio is broken, but its noise belongs to me.
    [Chorus]
    Don't shut me out, don't leave me on my own.
    I'm not a ghost, I've got a way to get back home.
    My heart is loud, but I'm too tired to pretend.
    If it all falls apart, I'll be here at the end.
    [Outro] Oh oh oh oh oh oh oh oh
    """

    static let shortEnglishRockText = """
    I keep my old radio playing
    You bring the light back home
    We watch the storm rolling away
    My hands are warm with yours
    The morning is ours to keep
    I hear your voice through walls
    You hold my heart through winter
    We leave our troubles far behind
    """

    static let spanishGuestLine = "No he dejado de pensar en todo nuestro pasado."

    static let romanizedHindiText = """
    is dil ki baat me chupaye do sapne us raah par chalte hain
    to phir mere saath aao raat ki khamoshi me nayi kahani sunao
    subah ki halki hawa hamare chhote ghar ki khidki se andar aati hai
    """
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

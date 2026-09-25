import Foundation
@testable import GanaBajana

actor ExperienceRadioCatalogFixture: MusicCatalogProviding {
    private let searches: [String: Result<[Track], any Error>]
    private let radios: [String: Result<[Track], any Error>]
    private let artistPages: [String: Result<ArtistPage, any Error>]
    private let albumPages: [String: Result<CatalogPage, any Error>]
    private let artistSearches: [String: Result<[MusicCollection], any Error>]
    private let playlistSearches: [String: Result<[MusicCollection], any Error>]
    private var radioSequences: [String: [Result<[Track], any Error>]]
    private let delay: Duration
    private var activeRequests = 0
    private(set) var maximumActiveRequests = 0
    private(set) var searchRequests: [AppModelSearchRequest] = []
    private(set) var radioRequests: [Track] = []
    private(set) var targetedRadioRequests = 0
    private(set) var artistRequests: [String] = []
    private(set) var browseRequests: [String] = []

    init(searches: [String: Result<[Track], any Error>] = [:], radios: [String: Result<[Track], any Error>] = [:],
         artists: [String: Result<ArtistPage, any Error>] = [:], albums: [String: Result<CatalogPage, any Error>] = [:],
         artistSearches: [String: Result<[MusicCollection], any Error>] = [:],
         playlistSearches: [String: Result<[MusicCollection], any Error>] = [:],
         radioSequences: [String: [Result<[Track], any Error>]] = [:],
         delay: Duration = .milliseconds(10)) {
        self.searches = searches
        self.radios = radios
        self.artistPages = artists
        self.albumPages = albums
        self.artistSearches = artistSearches
        self.playlistSearches = playlistSearches
        self.radioSequences = radioSequences
        self.delay = delay
    }

    func search(query: String, filter: SearchFilter, continuation: String?) async throws -> CatalogPage {
        searchRequests.append(AppModelSearchRequest(query: query, filter: filter, continuation: continuation))
        try await wait()
        if filter == .artists {
            guard let result = artistSearches[query] else { throw AppModelTestFailure.unexpectedRequest(query) }
            return CatalogPage(collections: try result.get())
        }
        if filter == .playlists {
            guard let result = playlistSearches[query] else { throw AppModelTestFailure.unexpectedRequest(query) }
            return CatalogPage(collections: try result.get())
        }
        guard let result = searches[query] else { throw AppModelTestFailure.unexpectedRequest(query) }
        return CatalogPage(tracks: try result.get())
    }

    func radio(seed: Track) async throws -> [Track] {
        radioRequests.append(seed)
        try await wait()
        if var sequence = radioSequences[seed.id], !sequence.isEmpty {
            let result = sequence.removeFirst()
            radioSequences[seed.id] = sequence
            return try result.get()
        }
        guard let result = radios[seed.id] else { throw AppModelTestFailure.unexpectedRequest(seed.id) }
        return try result.get()
    }

    func recommendations(seed: Track, language: MusicLanguage) async throws -> [Track] {
        targetedRadioRequests += 1
        throw AppModelTestFailure.unexpectedRequest("language-targeted radio")
    }

    func artist(id: String) async throws -> ArtistPage {
        artistRequests.append(id)
        try await wait()
        guard let result = artistPages[id] else { throw AppModelTestFailure.unexpectedRequest(id) }
        return try result.get()
    }

    func browse(id: String) async throws -> CatalogPage {
        browseRequests.append(id)
        try await wait()
        guard let result = albumPages[id] else { throw AppModelTestFailure.unexpectedRequest(id) }
        return try result.get()
    }
    func discovery(languages: Set<MusicLanguage>) async throws -> [DiscoverySection] {
        throw AppModelTestFailure.unexpectedRequest("discovery")
    }

    private func wait() async throws {
        activeRequests += 1
        maximumActiveRequests = max(maximumActiveRequests, activeRequests)
        defer { activeRequests -= 1 }
        try await Task.sleep(for: delay)
    }
}

enum ExperienceRadioFixtures {
    static let melancholy = RadioExperience(id: "fixture-melancholy", title: "Fixture melancholy",
        description: "Offline melancholy fixture", symbol: "cloud.moon", discoveryLanguages: [.english], contentLabel: "English", seeds: [
            .init("Apocalypse", by: "Cigarettes After Sex"), .init("Where Is My Mind?", by: "Pixies"),
        ])
    static let gym = RadioExperience(id: "fixture-gym", title: "Fixture gym",
        description: "Offline Hindi and Punjabi fixture", symbol: "bolt", discoveryLanguages: [.hindi], contentLabel: "Hindi + Punjabi", seeds: [
            .init("Zinda", by: "Siddharth Mahadevan", album: "Bhaag Milkha Bhaag"),
            .init("G.O.A.T.", by: "Diljit Dosanjh"),
        ])
    static let cas = RecommendationFixtures.track("catalog-cas", title: "Apocalypse", artist: "Cigarettes After Sex")
    static let pixies = RecommendationFixtures.track("catalog-pixies", title: "Where Is My Mind?", artist: "Pixies")
    static let dream = RecommendationFixtures.track("catalog-dream", title: "Dreams Tonite", artist: "Alvvays")
    static let alt = RecommendationFixtures.track("catalog-alt", title: "Fade Into You", artist: "Mazzy Star")
    static let zinda = RecommendationFixtures.track("catalog-zinda", title: "Zinda", artist: "Siddharth Mahadevan", language: .hindi)
    static let goat = RecommendationFixtures.track("catalog-goat", title: "G.O.A.T.", artist: "Diljit Dosanjh")
    static let sultan = RecommendationFixtures.track("catalog-sultan", title: "Sultan", artist: "Sukhwinder Singh", language: .hindi)
    static let punjabi = RecommendationFixtures.track("catalog-punjabi", title: "Brown Munde", artist: "AP Dhillon")

    static var melancholySearches: [String: Track] {
        ["Apocalypse Cigarettes After Sex": cas, "Where Is My Mind? Pixies": pixies]
    }
    static var gymSearches: [String: Track] {
        ["Zinda Siddharth Mahadevan Bhaag Milkha Bhaag": zinda, "G.O.A.T. Diljit Dosanjh": goat]
    }
    static var melancholyRadios: [String: [Track]] { [cas.id: [dream], pixies.id: [alt]] }
    static var gymRadios: [String: [Track]] { [zinda.id: [sultan], goat.id: [punjabi]] }

    /// Six usable songs by distinct artists, the shape a style search must return for a wording-only start.
    static func styleSongs(_ prefix: String, language: MusicLanguage? = nil) -> [Track] {
        (0..<6).map { RecommendationFixtures.track("\(prefix)-\($0)", artist: "\(prefix) artist \($0)", language: language) }
    }

    /// A complete style pass includes both filters once per query; cancelled starts can finish only their in-flight wave.
    @MainActor
    @discardableResult
    static func answerStyleSearches(_ context: AppModelTestContext, from offset: Int, count: Int, songs: [Track],
                                    expecting queries: Set<String>) async throws -> [AppModelSearchRequest] {
        guard queries.count <= ExperienceRadioEngine.maximumStyleQueries,
              (0...(queries.count * 2)).contains(count) else {
            throw AppModelTestFailure.unexpectedRequest("Style search budget: \(count) requests for \(queries.count) queries")
        }
        var answered: [AppModelSearchRequest] = []
        for index in offset..<(offset + count) {
            let request = try await context.catalog.searches.request(at: index)
            guard queries.contains(request.input.query), request.input.continuation == nil,
                  request.input.filter == .songs || request.input.filter == .playlists,
                  !answered.contains(request.input) else { throw AppModelTestFailure.unexpectedRequest(request.input.query) }
            let page = request.input.filter == .songs ? CatalogPage(tracks: songs) : CatalogPage()
            try await context.catalog.searches.complete(request, with: .success(page))
            answered.append(request.input)
        }
        return answered
    }

    @MainActor
    static func answerSearches(_ context: AppModelTestContext, from offset: Int, with songs: [String: Track]) async throws {
        for index in offset..<(offset + songs.count) {
            let request = try await context.catalog.searches.request(at: index)
            guard request.input.filter == .songs, request.input.continuation == nil,
                  let song = songs[request.input.query] else { throw AppModelTestFailure.unexpectedRequest(request.input.query) }
            try await context.catalog.searches.complete(request, with: .success(CatalogPage(tracks: [song])))
        }
    }

    @MainActor
    static func answerRadios(_ context: AppModelTestContext, from offset: Int, with radios: [String: [Track]],
                            fail: Bool = false) async throws {
        for index in offset..<(offset + radios.count) {
            let request = try await context.catalog.autoplayRadios.request(at: index)
            guard let songs = radios[request.input.id] else { throw AppModelTestFailure.unexpectedRequest(request.input.id) }
            let result: Result<[Track], any Error> = fail
                ? .failure(MusicServiceError.network("Offline radio fixture")) : .success(songs)
            try await context.catalog.autoplayRadios.complete(request, with: result)
        }
    }
}

extension RadioExperience {
    /// Wording the engine searches for one language set; `styleQueries` alone spans every language.
    func styleQueries(in languages: Set<MusicLanguage>) -> [String] {
        selection(for: languages)?.styleQueries ?? []
    }
}

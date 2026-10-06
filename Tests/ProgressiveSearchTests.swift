import Foundation
import XCTest
@testable import GanaBajana

/// A search-only catalog whose answer is a page, a failure, or a gated response the test releases.
private actor ProgressiveCatalogStub: MusicCatalogProviding {
    enum Answer: Sendable {
        case page(CatalogPage)
        case pages([String: CatalogPage])
        case failure(any Error)
        case gated
    }

    let gate = AppModelRequestGate<AppModelSearchRequest, CatalogPage>()
    private let answer: Answer
    private(set) var calls: [String] = []

    init(_ answer: Answer) { self.answer = answer }

    func search(query: String, filter: SearchFilter, continuation: String?) async throws -> CatalogPage {
        calls.append(query)
        switch answer {
        case .page(let page): return page
        case .pages(let pages): return pages[query] ?? CatalogPage()
        case .failure(let error): throw error
        case .gated: return try await gate.receive(AppModelSearchRequest(query: query, filter: filter, continuation: continuation))
        }
    }

    func browse(id: String) async throws -> CatalogPage { throw AppModelTestFailure.unexpectedRequest("browse: \(id)") }
    func artist(id: String) async throws -> ArtistPage { throw AppModelTestFailure.unexpectedRequest("artist: \(id)") }
    func recommendations(seed: Track, language: MusicLanguage) async throws -> [Track] { [] }
    func radio(seed: Track) async throws -> [Track] { [] }
    func radio(seed: Track, forceRefresh: Bool) async throws -> [Track] { [] }
    func discovery(languages: Set<MusicLanguage>) async throws -> [DiscoverySection] { [] }
}

/// Collects a progressive stream from a background consumer so tests can observe it mid-flight with bounded polls.
private final class ProgressiveStreamLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    private var ended = false
    private var failure: (any Error)?

    var updates: [String] { lock.withLock { stored } }
    var isEnded: Bool { lock.withLock { ended } }
    var error: (any Error)? { lock.withLock { failure } }

    func record(_ update: CompositeCatalog.SearchUpdate) {
        let text: String = switch update {
        case .primary(let page): "primary:" + page.tracks.map(\.id).joined(separator: ",")
        case .secondary(let source, let page): "\(source.rawValue):" + page.tracks.map(\.id).joined(separator: ",")
        }
        lock.withLock { stored.append(text) }
    }

    func end(_ error: (any Error)?) { lock.withLock { ended = true; failure = error } }
}

@MainActor
final class ProgressiveSearchTests: XCTestCase {
    private let youTubeTracks = [Track(id: "fsiPzT50ZiM", title: "Tum Hi Ho", credits: [ArtistCredit(name: "Arijit Singh")]),
                                 Track(id: "NJAv_7lHUIU", title: "Kesariya", credits: [ArtistCredit(name: "Arijit Singh")])]
    private let saavnTracks = [Track(id: "saavn:aRZbUYD7", title: "Tum Hi Ho", credits: [ArtistCredit(name: "Arijit Singh")]),
                               Track(id: "saavn:Bt07_OpM", title: "Tum Se Hi", credits: [ArtistCredit(name: "Mohit Chauhan")])]
    private let gaanaTracks = [Track(id: "gaana:944286", title: "Tum Hi Ho", credits: [ArtistCredit(name: "Mithoon")])]

    private var youTubeLine: String { "primary:" + youTubeTracks.map(\.id).joined(separator: ",") }
    private var saavnLine: String { "saavn:" + saavnTracks.map(\.id).joined(separator: ",") }
    private var gaanaLine: String { "gaana:" + gaanaTracks.map(\.id).joined(separator: ",") }

    private func makeStub(_ answer: ProgressiveCatalogStub.Answer) -> ProgressiveCatalogStub {
        let made = ProgressiveCatalogStub(answer)
        addTeardownBlock { await made.gate.close() }
        return made
    }

    private func composite(youTube: ProgressiveCatalogStub, saavn: ProgressiveCatalogStub? = nil, gaana: ProgressiveCatalogStub? = nil,
                           enabled: [MusicSource] = MusicSource.allCases, deadline: TimeInterval = 6) -> CompositeCatalog {
        var secondary: [MusicSource: any MusicCatalogProviding] = [:]
        if let saavn { secondary[.jioSaavn] = saavn }
        if let gaana { secondary[.gaana] = gaana }
        return CompositeCatalog(youTube: youTube, secondary: secondary, enabledSources: enabled, secondarySearchDeadline: deadline)
    }

    private func consume(_ catalog: CompositeCatalog, query: String = "tum") async -> (ProgressiveStreamLog, Task<Void, Never>) {
        let log = ProgressiveStreamLog()
        let stream = await catalog.progressiveSearch(query: query, filter: .songs)
        let task = Task {
            do {
                for try await update in stream { log.record(update) }
                log.end(nil)
            } catch { log.end(error) }
        }
        addTeardownBlock { task.cancel() }
        return (log, task)
    }

    private func assertPrimaryNetworkError(_ error: (any Error)?, _ expected: String, file: StaticString = #filePath, line: UInt = #line) {
        guard case .network(let message)? = error as? MusicServiceError else {
            return XCTFail("Expected the primary network error, got \(String(describing: error))", file: file, line: line)
        }
        XCTAssertEqual(message, expected, file: file, line: line)
    }

    // MARK: CompositeCatalog.progressiveSearch

    func testPrimaryArrivesWhileASlowSecondaryIsGatedAndEachSecondaryFollows() async throws {
        let youTube = makeStub(.page(CatalogPage(tracks: youTubeTracks)))
        let saavn = makeStub(.gated)
        let gaana = makeStub(.page(CatalogPage(tracks: gaanaTracks)))
        let (log, _) = await consume(composite(youTube: youTube, saavn: saavn, gaana: gaana))
        let blocked = try await saavn.gate.request(at: 0)

        try await AppModelFixtures.eventually { log.updates.count >= 2 }
        XCTAssertEqual(log.updates, [youTubeLine, gaanaLine], "Gaana may beat YouTube, but it is still delivered after the primary")
        XCTAssertFalse(log.isEnded, "The stream stays open for the gated JioSaavn search")

        try await saavn.gate.complete(blocked, with: .success(CatalogPage(tracks: saavnTracks)))
        try await AppModelFixtures.eventually { log.isEnded }
        XCTAssertEqual(log.updates, [youTubeLine, gaanaLine, saavnLine])
        XCTAssertNil(log.error)
    }

    func testSecondariesFinishingBeforeThePrimaryFollowItInSourceOrder() async throws {
        let youTube = makeStub(.gated)
        let saavn = makeStub(.gated)
        let gaana = makeStub(.gated)
        let (log, _) = await consume(composite(youTube: youTube, saavn: saavn, gaana: gaana))
        let primary = try await youTube.gate.request(at: 0)
        let saavnRequest = try await saavn.gate.request(at: 0)
        let gaanaRequest = try await gaana.gate.request(at: 0)

        // Gaana answers first so arrival order is the reverse of MusicSource order; the pause lets both be buffered.
        try await gaana.gate.complete(gaanaRequest, with: .success(CatalogPage(tracks: gaanaTracks)))
        try await saavn.gate.complete(saavnRequest, with: .success(CatalogPage(tracks: saavnTracks)))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(log.updates.isEmpty, "Nothing is delivered before the primary")

        try await youTube.gate.complete(primary, with: .success(CatalogPage(tracks: youTubeTracks)))
        try await AppModelFixtures.eventually { log.isEnded }
        XCTAssertEqual(log.updates, [youTubeLine, saavnLine, gaanaLine])
        XCTAssertNil(log.error)
    }

    func testAFailingSecondaryIsIgnored() async throws {
        let youTube = makeStub(.page(CatalogPage(tracks: youTubeTracks)))
        let saavn = makeStub(.failure(MusicServiceError.rateLimited))
        let (log, _) = await consume(composite(youTube: youTube, saavn: saavn))
        try await AppModelFixtures.eventually { log.isEnded }
        XCTAssertEqual(log.updates, [youTubeLine])
        XCTAssertNil(log.error)
    }

    func testAPrimaryFailureAfterASecondarySuccessYieldsAnEmptyPrimaryThenTheSecondary() async throws {
        let youTube = makeStub(.gated)
        let saavn = makeStub(.page(CatalogPage(tracks: saavnTracks)))
        let (log, _) = await consume(composite(youTube: youTube, saavn: saavn))
        let primary = try await youTube.gate.request(at: 0)
        try await AppModelFixtures.eventually { await saavn.calls.count == 1 }
        // Lets the JioSaavn page be buffered before the primary fails.
        try await Task.sleep(for: .milliseconds(100))

        try await youTube.gate.complete(primary, with: .failure(MusicServiceError.network("primary down")))
        try await AppModelFixtures.eventually { log.isEnded }
        XCTAssertEqual(log.updates, ["primary:", saavnLine])
        XCTAssertNil(log.error)
    }

    /// The contract is the same whichever finishes first, matching `search` under `searchingAllSources`.
    func testAPrimaryFailureBeforeASecondarySuccessYieldsAnEmptyPrimaryThenTheSecondary() async throws {
        let youTube = makeStub(.failure(MusicServiceError.network("primary down")))
        let saavn = makeStub(.gated)
        let (log, _) = await consume(composite(youTube: youTube, saavn: saavn))
        let blocked = try await saavn.gate.request(at: 0)
        try await AppModelFixtures.eventually { await youTube.calls.count == 1 }
        // Lets the primary failure be processed while JioSaavn is still pending.
        try await Task.sleep(for: .milliseconds(100))

        try await saavn.gate.complete(blocked, with: .success(CatalogPage(tracks: saavnTracks)))
        try await AppModelFixtures.eventually { log.isEnded }
        XCTAssertNil(log.error, "A late secondary success must not turn into the primary error")
        XCTAssertEqual(log.updates, ["primary:", saavnLine])
    }

    func testAPrimaryFailureWithoutASecondarySuccessThrowsThePrimaryError() async throws {
        let youTube = makeStub(.failure(MusicServiceError.network("primary down")))
        let saavn = makeStub(.failure(MusicServiceError.rateLimited))
        let (log, _) = await consume(composite(youTube: youTube, saavn: saavn))
        try await AppModelFixtures.eventually { log.isEnded }
        XCTAssertTrue(log.updates.isEmpty)
        assertPrimaryNetworkError(log.error, "primary down")

        let alone = makeStub(.failure(MusicServiceError.network("only source down")))
        let (single, _) = await consume(composite(youTube: alone))
        try await AppModelFixtures.eventually { single.isEnded }
        XCTAssertTrue(single.updates.isEmpty)
        assertPrimaryNetworkError(single.error, "only source down")
    }

    func testOnlyYouTubeEnabledYieldsExactlyOnePrimaryUpdate() async throws {
        let youTube = makeStub(.page(CatalogPage(tracks: youTubeTracks)))
        let saavn = makeStub(.page(CatalogPage(tracks: saavnTracks)))
        let gaana = makeStub(.page(CatalogPage(tracks: gaanaTracks)))
        let (log, _) = await consume(composite(youTube: youTube, saavn: saavn, gaana: gaana, enabled: [.youTubeMusic]))
        try await AppModelFixtures.eventually { log.isEnded }
        XCTAssertEqual(log.updates, [youTubeLine])
        XCTAssertNil(log.error)
        let saavnCalls = await saavn.calls
        let gaanaCalls = await gaana.calls
        XCTAssertTrue(saavnCalls.isEmpty && gaanaCalls.isEmpty, "Disabled sources are not searched")
    }

    func testASecondaryThatNeverAnswersIsCutOffAtTheDeadline() async throws {
        let youTube = makeStub(.page(CatalogPage(tracks: youTubeTracks)))
        let saavn = makeStub(.gated)
        let started = ContinuousClock.now
        let (log, _) = await consume(composite(youTube: youTube, saavn: saavn, deadline: 0.2))
        _ = try await saavn.gate.request(at: 0)
        try await AppModelFixtures.eventually { log.isEnded }
        XCTAssertEqual(log.updates, [youTubeLine])
        XCTAssertNil(log.error, "A timed-out secondary is dropped like a failed one")
        XCTAssertLessThan(started.duration(to: .now), .seconds(2.5), "The secondary deadline bounds the stream")
    }

    func testTerminatingTheStreamCancelsTheSecondarySearch() async throws {
        let youTube = makeStub(.page(CatalogPage(tracks: youTubeTracks)))
        let saavn = makeStub(.gated)
        let (log, consumer) = await consume(composite(youTube: youTube, saavn: saavn))
        let blocked = try await saavn.gate.request(at: 0)
        try await AppModelFixtures.eventually { log.updates.count == 1 }

        consumer.cancel()
        try await AppModelFixtures.eventually { await saavn.gate.cancellations.contains(blocked.id) }
        try await AppModelFixtures.eventually { log.isEnded }
        XCTAssertEqual(log.updates, [youTubeLine])
    }

    // MARK: MusicAppModel.loadSearch

    private struct ModelHarness {
        let model: MusicAppModel
        let youTube: ProgressiveCatalogStub
        let saavn: ProgressiveCatalogStub
    }

    private func makeModel(youTubePages: [String: CatalogPage]) -> ModelHarness {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("progressive-search-tests-\(UUID().uuidString)", isDirectory: true)
        let library = LibraryStore(directory: directory)
        library.preferences.useEncryptedDNS = false
        let youTube = makeStub(.pages(youTubePages))
        let saavn = makeStub(.gated)
        let catalog = CompositeCatalog(youTube: youTube, secondary: [.jioSaavn: saavn], enabledSources: [.youTubeMusic, .jioSaavn])
        let streams = AppModelStreamResolver()
        let charts = AppModelChartsProvider()
        let player = PlayerController(resolver: streams)
        let model = MusicAppModel(library: library, player: player, catalog: catalog, charts: charts,
                                  lyrics: AppModelLyricsProvider(),
                                  account: YouTubeAccountStore(secrets: MemorySecretStore(), registry: YouTubeSessionRegistry()),
                                  connectivity: ConnectivityMonitor(initialStatus: .online, monitorsSystem: false), generatesMixes: false)
        addTeardownBlock { @MainActor in
            model.deactivateDeviceServices()
            player.pause()
            await charts.charts.close()
            await streams.streams.close()
            try? FileManager.default.removeItem(at: directory)
        }
        return ModelHarness(model: model, youTube: youTube, saavn: saavn)
    }

    func testModelPublishesThePrimaryBeforeASlowSecondaryAndAppendsItWithoutDuplicates() async throws {
        let harness = makeModel(youTubePages: ["tum": CatalogPage(tracks: youTubeTracks)])
        let model = harness.model
        model.searchQuery = "tum"
        let search = Task { await model.loadSearch() }
        addTeardownBlock { search.cancel() }
        let blocked = try await harness.saavn.gate.request(at: 0)

        try await AppModelFixtures.eventually { model.hasSearched }
        XCTAssertEqual(model.searchPage.tracks.map(\.id), youTubeTracks.map(\.id))
        XCTAssertFalse(model.isSearching, "The spinner stops with the primary results, not the slowest source")
        XCTAssertNil(model.searchError)

        // JioSaavn repeating a YouTube id must not duplicate the row.
        try await harness.saavn.gate.complete(blocked, with: .success(CatalogPage(tracks: saavnTracks + [youTubeTracks[0]])))
        try await AppModelFixtures.eventually { model.searchPage.tracks.count > youTubeTracks.count }
        await search.value
        let ids = model.searchPage.tracks.map(\.id)
        XCTAssertEqual(ids, youTubeTracks.map(\.id) + saavnTracks.map(\.id))
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertTrue(model.hasSearched)
        XCTAssertFalse(model.isSearching)
    }

    func testANewerQueryIgnoresALateSecondaryFromTheOldOne() async throws {
        let oldTrack = Track(id: "oldYouTube1", title: "Old", credits: [])
        let newTrack = Track(id: "newYouTube1", title: "New", credits: [])
        let harness = makeModel(youTubePages: ["old": CatalogPage(tracks: [oldTrack]), "new": CatalogPage(tracks: [newTrack])])
        let model = harness.model
        model.searchQuery = "old"
        let first = Task { await model.loadSearch() }
        addTeardownBlock { first.cancel() }
        let oldSecondary = try await harness.saavn.gate.request(at: 0)
        XCTAssertEqual(oldSecondary.input.query, "old")
        try await AppModelFixtures.eventually { model.searchPage.tracks.map(\.id) == [oldTrack.id] }

        model.searchQuery = "new"
        let second = Task { await model.loadSearch() }
        addTeardownBlock { second.cancel() }
        let newSecondary = try await harness.saavn.gate.request(at: 1)
        XCTAssertEqual(newSecondary.input.query, "new")
        try await AppModelFixtures.eventually { model.searchPage.tracks.map(\.id) == [newTrack.id] }

        let stale = Track(id: "saavn:stale0001", title: "Stale", credits: [])
        try await harness.saavn.gate.complete(oldSecondary, with: .success(CatalogPage(tracks: [stale])))
        // The superseded search sees the stale page and returns without publishing it.
        await first.value
        XCTAssertEqual(model.searchPage.tracks.map(\.id), [newTrack.id])

        let fresh = Track(id: "saavn:fresh0001", title: "Fresh", credits: [])
        try await harness.saavn.gate.complete(newSecondary, with: .success(CatalogPage(tracks: [fresh])))
        await second.value
        XCTAssertEqual(model.searchPage.tracks.map(\.id), [newTrack.id, fresh.id])
        XCTAssertFalse(model.isSearching)
    }

    // MARK: YouTubeMusicService featured-artist page

    private let songsParams = YouTubeMusicService.searchParameters(.songs)
    private let artistsParams = YouTubeMusicService.searchParameters(.artists)

    private func requests(_ mock: CatalogMockSession, path: String, containing marker: String? = nil) -> [CatalogJSON] {
        mock.state.requests.filter { $0.httpMethod == "POST" && $0.url?.path.hasSuffix(path) == true }
            .compactMap { try? CatalogJSON.decode($0.httpBody ?? Data()) }
            .filter { body in marker == nil || body["params"].string == marker }
    }

    func testANonQualifyingArtistReturnsWithoutWaitingForItsPageAndCancelsIt() async throws {
        let gate = AppModelRequestGate<String, Void>()
        addTeardownBlock { await gate.close() }
        var router = CatalogMockRouter()
        // One tier-0 song is below SearchRelevance.minimumFeaturedTracks, so Arijit cannot be featured.
        router.songs["Arijit Singh"] = try CatalogFixtures.data(CatalogFixtures.search([
            CatalogFixtures.song(),
            CatalogFixtures.song(id: "OaiOf0-kISM", title: "Al Rahman", artist: "Abdel Rahman el Ousi", artistID: "UC1CwoEojJpBZw8gnaZUhMVQ"),
        ]))
        router.artists["Arijit Singh"] = try CatalogFixtures.data(CatalogFixtures.search([CatalogFixtures.artistRow()]))
        router.browse[CatalogFixtures.arijitID] = try CatalogFixtures.data(CatalogFixtures.artistPage(songs: [
            CatalogFixtures.song(id: "i1o1p_DD6TU", title: "Gehra Hua"),
        ]))
        let songs = songsParams
        let mock = CatalogMockSession { [router] request in
            var stub = try router.stub(request)
            guard request.httpMethod == "POST" else { return stub }
            let body = try CatalogJSON.decode(request.httpBody ?? Data())
            if body["browseId"].string == CatalogFixtures.arijitID {
                stub.beforeDelivery = { try await gate.receive("artist-page") }
            } else if body["params"].string == songs {
                // Holding the songs page until the artist page is in flight makes the cancellation observable.
                stub.beforeDelivery = { _ = try await gate.request(at: 0) }
            }
            return stub
        }
        defer { mock.close() }
        let service = YouTubeMusicService(session: mock.session)
        let pending = Task { try await service.search(query: "Arijit Singh", filter: .songs, continuation: nil) }
        defer { pending.cancel() }
        let blocked = try await gate.request(at: 0)

        // Waiting for the gated page would hold the search until the 2 s enrichment deadline.
        let page = try await PlaybackDeadline.run(seconds: 1.5) { try await pending.value }

        XCTAssertNil(page.featuredArtist)
        XCTAssertEqual(page.tracks.map(\.id), [CatalogFixtures.hindiID, "OaiOf0-kISM"])
        try await AppModelFixtures.eventually {
            let cancelled = await gate.cancellations
            return cancelled.contains(blocked.id) && mock.state.cancellations > 0
        }
        try await gate.complete(blocked, with: .success(()))
        XCTAssertEqual(requests(mock, path: "/browse").count, 1)
        XCTAssertEqual(requests(mock, path: "/search", containing: artistsParams).count, 1)
    }

    func testAQualifyingArtistLeadsWithItsFirstArtistPageOnly() async throws {
        var router = CatalogMockRouter()
        router.songs["Arijit Singh"] = try CatalogFixtures.data(CatalogFixtures.search([
            CatalogFixtures.song(), CatalogFixtures.song(id: "NJAv_7lHUIU", title: "Kesariya"),
        ]))
        router.artists["Arijit Singh"] = try CatalogFixtures.data(CatalogFixtures.search([CatalogFixtures.artistRow()]))
        // A next-page item on the top songs shelf: the full artist browse would follow it, the featured fetch must not.
        let nextPage: [String: Any] = ["continuationItemRenderer": ["continuationEndpoint": ["continuationCommand": [
            "token": "arijit-top-2", "request": "CONTINUATION_REQUEST_TYPE_BROWSE",
        ]]]]
        router.browse[CatalogFixtures.arijitID] = try CatalogFixtures.data(CatalogFixtures.artistPage(songs: [
            CatalogFixtures.song(id: "i1o1p_DD6TU", title: "Gehra Hua"), CatalogFixtures.song(id: "NJAv_7lHUIU", title: "Kesariya"), nextPage,
        ]))
        router.continuations["arijit-top-2"] = try CatalogFixtures.data(CatalogFixtures.search([
            CatalogFixtures.song(id: "q1uPPBJ2tcI", title: "Phir Bhi Tumko Chaahunga"),
        ], continued: true))
        let mock = CatalogMockSession { [router] request in try router.stub(request) }
        defer { mock.close() }
        let service = YouTubeMusicService(session: mock.session)

        let page = try await service.search(query: "Arijit Singh", filter: .songs, continuation: nil)
        XCTAssertEqual(page.featuredArtist?.id, CatalogFixtures.arijitID)
        XCTAssertEqual(page.tracks.map(\.id), ["i1o1p_DD6TU", "NJAv_7lHUIU", CatalogFixtures.hindiID],
                       "The artist page's songs lead once, then the remaining search rows")
        let browses = requests(mock, path: "/browse")
        XCTAssertEqual(browses.count, 1, "Only the first artist browse page is fetched")
        XCTAssertNil(browses.first?["continuation"].string)

        // The full artist page does follow the fixture's continuation, so the single request above is meaningful.
        _ = try? await service.artist(id: CatalogFixtures.arijitID)
        XCTAssertTrue(requests(mock, path: "/browse").contains { $0["continuation"].string == "arijit-top-2" })
    }

    func testAnArtistPageThatArrivedIsKeptWhenTheSongsRequestRunsPastTheBudget() async throws {
        var router = CatalogMockRouter()
        router.songs["Arijit Singh"] = try CatalogFixtures.data(CatalogFixtures.search([
            CatalogFixtures.song(), CatalogFixtures.song(id: "NJAv_7lHUIU", title: "Kesariya"),
        ]))
        router.artists["Arijit Singh"] = try CatalogFixtures.data(CatalogFixtures.search([CatalogFixtures.artistRow()]))
        router.browse[CatalogFixtures.arijitID] = try CatalogFixtures.data(CatalogFixtures.artistPage(songs: [
            CatalogFixtures.song(id: "i1o1p_DD6TU", title: "Gehra Hua"),
        ]))
        let songs = songsParams
        // The songs page answers after the 2 s enrichment budget; the artist page has long since arrived.
        let mock = CatalogMockSession { [router] request in
            var stub = try router.stub(request)
            guard request.httpMethod == "POST", let body = try? CatalogJSON.decode(request.httpBody ?? Data()),
                  body["params"].string == songs else { return stub }
            stub.delay = 2.4
            return stub
        }
        defer { mock.close() }
        let service = YouTubeMusicService(session: mock.session)
        let page = try await service.search(query: "Arijit Singh", filter: .songs, continuation: nil)
        XCTAssertEqual(page.featuredArtist?.id, CatalogFixtures.arijitID, "A finished page survives a slow songs request")
        XCTAssertEqual(page.tracks.first?.id, "i1o1p_DD6TU")
    }
}

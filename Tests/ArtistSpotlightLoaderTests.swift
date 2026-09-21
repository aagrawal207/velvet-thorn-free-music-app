import XCTest
@testable import GanaBajana

@MainActor
final class ArtistSpotlightLoaderTests: XCTestCase {
    func testLanguagesAppearIncrementallyAndTheNextBatchIsOnDemand() async throws {
        let catalog = ArtistSpotlightCatalogFixture()
        let provider = ArtistSpotlightLyricsFixture()
        addTeardownBlock { await catalog.close(); await provider.requests.close() }
        let languageService = ArtistSpotlightLanguageService(provider: provider,
            hypotheses: ArtistSpotlightTestSupport.originalScriptHypotheses)
        let known = ArtistSpotlightTestSupport.track("hi", count: 900, language: .hindi)
        let english = ArtistSpotlightTestSupport.track("en", count: 800)
        let tamil = ArtistSpotlightTestSupport.track("ta", count: 700)
        let unknown = ArtistSpotlightTestSupport.track("unknown", count: 600)
        var configuration = ArtistSpotlightLoader.Configuration()
        configuration.automaticLanguageChecks = 2
        let loader = ArtistSpotlightLoader(artist: ArtistSpotlightTestSupport.page([unknown, tamil, known, english]),
            configuration: configuration, catalogConfiguration: ArtistSpotlightTestSupport.catalogConfiguration(),
            languageService: languageService)
        XCTAssertEqual(loader.visibleTracks.map(\.id), ["hi", "en", "ta", "unknown"])
        XCTAssertEqual(loader.filters, [.all, .language(.hindi), .unclassified])
        let loading = Task { await loader.load(catalog: catalog, lyrics: provider) }
        let first = try await provider.requests.request(at: 0)
        let second = try await provider.requests.request(at: 1)
        let englishRequest = first.input.id == english.id ? first : second
        let tamilRequest = first.input.id == tamil.id ? first : second
        try await provider.requests.complete(englishRequest, with: .success(ArtistSpotlightTestSupport.document(english)))
        try await AppModelFixtures.eventually { loader.availableLanguages.contains(.english) }
        XCTAssertTrue(loader.isCheckingLanguages)
        loader.filter = .language(.english)
        XCTAssertEqual(loader.visibleTracks.map(\.id), ["en"])
        try await provider.requests.complete(tamilRequest, with: .success(ArtistSpotlightTestSupport.document(tamil, text: ArtistSpotlightFixtures.tamilText)))
        await loading.value
        XCTAssertEqual(loader.availableLanguages, [.english, .hindi, .tamil])
        XCTAssertEqual(loader.checkedLanguageCount, 3)
        XCTAssertEqual(loader.unclassifiedCount, 1)
        XCTAssertTrue(loader.canCheckMoreLanguages)
        XCTAssertTrue(loader.hasInferredLanguages)
        XCTAssertFalse(loader.isBusy)
        let initialRequests = await provider.requests.requests.count
        XCTAssertEqual(initialRequests, 2)

        await provider.requests.enqueue(.success(LyricsDocument(trackID: unknown.id, kind: .unavailable)))
        loader.checkMoreLanguages()
        try await AppModelFixtures.eventually { !loader.isBusy }
        XCTAssertFalse(loader.canCheckMoreLanguages)
        XCTAssertEqual(loader.checkedLanguageCount, 4)
        XCTAssertEqual(loader.unclassifiedCount, 1)
        loader.filter = .all
        XCTAssertEqual(loader.visibleTracks.map(\.id), ["hi", "en", "ta", "unknown"])
    }

    func testANewerCatalogLoadCancelsAndRejectsOlderCounts() async throws {
        let catalog = ArtistSpotlightCatalogFixture()
        let lyrics = AppModelLyricsProvider()
        addTeardownBlock { await catalog.close() }
        var configuration = ArtistSpotlightLoader.Configuration()
        configuration.automaticLanguageChecks = 0
        let track = ArtistSpotlightTestSupport.track("same-recording")
        let loader = ArtistSpotlightLoader(artist: ArtistSpotlightTestSupport.page([track]), configuration: configuration,
            catalogConfiguration: ArtistSpotlightTestSupport.catalogConfiguration(countSearches: 1))
        let oldLoad = Task { await loader.load(catalog: catalog, lyrics: lyrics) }
        let oldRequest = try await catalog.searches.request(at: 0)
        let newLoad = Task { await loader.load(catalog: catalog, lyrics: lyrics, force: true) }
        let newRequest = try await catalog.searches.request(at: 1)
        await oldLoad.value
        var current = track
        current.playCount = 200
        try await catalog.searches.complete(newRequest, with: .success(CatalogPage(tracks: [current])))
        await newLoad.value
        var stale = track
        stale.playCount = 90_000
        try await catalog.searches.complete(oldRequest, with: .success(CatalogPage(tracks: [stale])))
        XCTAssertEqual(loader.tracks.first?.playCount, 200)
        XCTAssertFalse(loader.isBusy)
        XCTAssertFalse(loader.hadCatalogFailures)
    }

    func testLeavingTheCollectionCancelsLanguageWorkAndStaleLanguageCannotChangeItsFilter() async throws {
        let catalog = ArtistSpotlightCatalogFixture()
        let provider = ArtistSpotlightLyricsFixture()
        addTeardownBlock { await catalog.close(); await provider.requests.close() }
        let service = ArtistSpotlightLanguageService(provider: provider,
            hypotheses: ArtistSpotlightTestSupport.originalScriptHypotheses)
        let track = ArtistSpotlightTestSupport.track("language-stale", count: 100)
        let loader = ArtistSpotlightLoader(artist: ArtistSpotlightTestSupport.page([track]),
            catalogConfiguration: ArtistSpotlightTestSupport.catalogConfiguration(), languageService: service)
        let oldLoad = Task { await loader.load(catalog: catalog, lyrics: provider) }
        let oldRequest = try await provider.requests.request(at: 0)
        loader.cancel()
        await oldLoad.value
        try await AppModelFixtures.eventually { await service.activity.activeLookups == 0 }
        XCTAssertFalse(loader.isBusy)
        XCTAssertEqual(loader.unclassifiedCount, 1)
        let newLoad = Task { await loader.load(catalog: catalog, lyrics: provider, force: true) }
        let newRequest = try await provider.requests.request(at: 1)
        try await provider.requests.complete(newRequest, with: .success(ArtistSpotlightTestSupport.document(track, text: ArtistSpotlightFixtures.tamilText)))
        await newLoad.value
        loader.filter = .language(.tamil)
        try await provider.requests.complete(oldRequest, with: .success(ArtistSpotlightTestSupport.document(track)))
        XCTAssertEqual(loader.availableLanguages, [.tamil])
        XCTAssertEqual(loader.filter, .language(.tamil))
        XCTAssertEqual(loader.visibleTracks.map(\.id), [track.id])
        XCTAssertFalse(loader.filters.contains(.unclassified))
    }

    func testFailedLanguageLookupIsRetryableWithoutInventingALanguage() async throws {
        let catalog = ArtistSpotlightCatalogFixture()
        let provider = ArtistSpotlightLyricsFixture()
        addTeardownBlock { await catalog.close(); await provider.requests.close() }
        let track = ArtistSpotlightTestSupport.track("retry", count: 100)
        await provider.requests.enqueue(.failure(MusicServiceError.network("Synthetic failure")))
        let service = ArtistSpotlightLanguageService(provider: provider, hypotheses: { _ in ["en": 0.99] })
        let loader = ArtistSpotlightLoader(artist: ArtistSpotlightTestSupport.page([track]),
            catalogConfiguration: ArtistSpotlightTestSupport.catalogConfiguration(), languageService: service)
        await loader.load(catalog: catalog, lyrics: provider)
        XCTAssertEqual(loader.filters, [.all, .unclassified])
        XCTAssertTrue(loader.hasFailedLanguageChecks)
        XCTAssertFalse(loader.hasInferredLanguages)
        await provider.requests.enqueue(.success(ArtistSpotlightTestSupport.document(track)))
        loader.checkMoreLanguages(retryFailures: true)
        try await AppModelFixtures.eventually { !loader.isBusy }
        XCTAssertEqual(loader.filters, [.all, .language(.english)])
        XCTAssertFalse(loader.hasFailedLanguageChecks)
    }
}

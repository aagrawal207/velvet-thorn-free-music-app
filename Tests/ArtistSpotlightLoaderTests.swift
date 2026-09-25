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

    func testArtistPageSongLoadSurfacesSearchOnlyCollaborationsAndTheSongListJoinsItWithoutARestart() async throws {
        let catalog = ArtistSpotlightCatalogFixture()
        let lyrics = AppModelLyricsProvider()
        addTeardownBlock { await catalog.close() }
        var configuration = ArtistSpotlightLoader.Configuration()
        configuration.automaticLanguageChecks = 0
        let listed = ArtistSpotlightTestSupport.track("listed", count: 500)
        let listedCollaboration = ArtistSpotlightTestSupport.collaboration("listed-collaboration", count: 400)
        let loader = ArtistSpotlightLoader(artist: ArtistSpotlightTestSupport.page([listed, listedCollaboration]),
            configuration: configuration, catalogConfiguration: ArtistSpotlightTestSupport.catalogConfiguration(searchPages: 1))
        XCTAssertTrue(loader.featuredTracks.isEmpty, "The provider's own listing is never repeated as a collaboration")
        loader.startLoadingSongs(catalog: catalog)
        XCTAssertTrue(loader.isLoadingSongs)
        let request = try await catalog.searches.request(at: 0)
        loader.startLoadingSongs(catalog: catalog)
        let join = Task { await loader.load(catalog: catalog, lyrics: lyrics) }
        try await AppModelFixtures.eventually { loader.isBusy }
        let found = ArtistSpotlightTestSupport.collaboration("found", count: 900)
        var titleFeature = ArtistSpotlightTestSupport.track("title-feature", title: "Night Train (feat. A. R. Rahman)", count: 50)
        titleFeature.credits = [ArtistCredit(name: "Rail Collective")]
        let primaryOnly = ArtistSpotlightTestSupport.track("primary-only", count: 700)
        try await catalog.searches.complete(request, with: .success(CatalogPage(tracks: [found, titleFeature, primaryOnly])))
        await join.value
        XCTAssertTrue(loader.hasLoaded)
        XCTAssertFalse(loader.isBusy)
        XCTAssertEqual(loader.featuredTracks.map(\.id), ["found", "title-feature"], "Collaborations keep count order")
        XCTAssertEqual(loader.visibleTracks.map(\.id), ["found", "primary-only", "listed", "listed-collaboration", "title-feature"])
        let searches = await catalog.searches.requests.count
        XCTAssertEqual(searches, 1, "Joining the artist page's load must not fetch the songs again")
        await loader.load(catalog: catalog, lyrics: lyrics)
        let repeated = await catalog.searches.requests.count
        XCTAssertEqual(repeated, 1)
    }

    func testLeavingTheSongListKeepsTheArtistPagesSongLoadRunning() async throws {
        let catalog = ArtistSpotlightCatalogFixture()
        let lyrics = AppModelLyricsProvider()
        addTeardownBlock { await catalog.close() }
        var configuration = ArtistSpotlightLoader.Configuration()
        configuration.automaticLanguageChecks = 0
        let listed = ArtistSpotlightTestSupport.track("listed", count: 500)
        let loader = ArtistSpotlightLoader(artist: ArtistSpotlightTestSupport.page([listed]), configuration: configuration,
            catalogConfiguration: ArtistSpotlightTestSupport.catalogConfiguration(searchPages: 1))
        loader.startLoadingSongs(catalog: catalog)
        let request = try await catalog.searches.request(at: 0)
        let visit = Task { await loader.load(catalog: catalog, lyrics: lyrics) }
        try await AppModelFixtures.eventually { loader.isBusy }
        visit.cancel()
        loader.cancelLanguageChecks()
        await visit.value
        XCTAssertTrue(loader.isLoadingSongs, "Popping the song list leaves the shared load to the artist page")
        XCTAssertTrue(loader.featuredTracks.isEmpty)
        let found = ArtistSpotlightTestSupport.collaboration("found", count: 900)
        try await catalog.searches.complete(request, with: .success(CatalogPage(tracks: [found])))
        try await AppModelFixtures.eventually { loader.hasLoaded }
        XCTAssertFalse(loader.isLoadingSongs)
        XCTAssertEqual(loader.featuredTracks.map(\.id), ["found"])
        let cancellations = await catalog.searches.cancellations
        XCTAssertTrue(cancellations.isEmpty)
        loader.cancel()
        XCTAssertEqual(loader.featuredTracks.map(\.id), ["found"], "Cancelling stops work without discarding known songs")
    }

    func testTryAgainReloadsOnceAndLaterVisitsNeitherCancelNorRefetch() async throws {
        let catalog = ArtistSpotlightCatalogFixture()
        let lyrics = AppModelLyricsProvider()
        addTeardownBlock { await catalog.close() }
        var configuration = ArtistSpotlightLoader.Configuration()
        configuration.automaticLanguageChecks = 0
        let listed = ArtistSpotlightTestSupport.track("listed", count: 500)
        let loader = ArtistSpotlightLoader(artist: ArtistSpotlightTestSupport.page([listed]), configuration: configuration,
            catalogConfiguration: ArtistSpotlightTestSupport.catalogConfiguration(searchPages: 1))
        loader.startLoadingSongs(catalog: catalog)
        let first = try await catalog.searches.request(at: 0)
        try await catalog.searches.complete(first, with: .failure(MusicServiceError.network("Synthetic failure")))
        try await AppModelFixtures.eventually { loader.hasLoaded }
        XCTAssertTrue(loader.hadCatalogFailures)
        XCTAssertFalse(loader.isBusy)

        loader.requestReload()
        XCTAssertEqual(loader.reloadRequest, 1)
        XCTAssertFalse(loader.hasLoaded)
        let reload = Task { await loader.load(catalog: catalog, lyrics: lyrics) }
        let second = try await catalog.searches.request(at: 1)
        let revisit = Task { await loader.load(catalog: catalog, lyrics: lyrics) }
        let found = ArtistSpotlightTestSupport.collaboration("found", count: 900)
        try await catalog.searches.complete(second, with: .success(CatalogPage(tracks: [found])))
        await reload.value
        await revisit.value
        XCTAssertTrue(loader.hasLoaded)
        XCTAssertFalse(loader.hadCatalogFailures)
        XCTAssertFalse(loader.isBusy)
        XCTAssertEqual(loader.featuredTracks.map(\.id), ["found"])

        await loader.load(catalog: catalog, lyrics: lyrics)
        XCTAssertEqual(loader.reloadRequest, 1)
        XCTAssertTrue(loader.hasLoaded)
        XCTAssertFalse(loader.isBusy)
        XCTAssertEqual(loader.featuredTracks.map(\.id), ["found"])
        let searches = await catalog.searches.requests.count
        let cancellations = await catalog.searches.cancellations
        XCTAssertEqual(searches, 2, "Try again fetches once; joining and later visits must not fetch again")
        XCTAssertTrue(cancellations.isEmpty, "No visit after Try again may cancel the shared load")
    }

    func testASpontaneousCancellationErrorFinishesTheSongLoadAsAFailureAndAllowsRetry() async throws {
        let catalog = ArtistSpotlightCatalogFixture()
        let lyrics = AppModelLyricsProvider()
        addTeardownBlock { await catalog.close() }
        var configuration = ArtistSpotlightLoader.Configuration()
        configuration.automaticLanguageChecks = 0
        let listed = ArtistSpotlightTestSupport.track("listed", count: 500)
        let loader = ArtistSpotlightLoader(artist: ArtistSpotlightTestSupport.page([listed]), configuration: configuration,
            catalogConfiguration: ArtistSpotlightTestSupport.catalogConfiguration(searchPages: 1))
        loader.startLoadingSongs(catalog: catalog)
        let request = try await catalog.searches.request(at: 0)
        let visit = Task { await loader.load(catalog: catalog, lyrics: lyrics) }
        // The transport reports URLError.cancelled as CancellationError while the loader's task keeps running.
        try await catalog.searches.complete(request, with: .failure(CancellationError()))
        await visit.value
        XCTAssertFalse(loader.isLoadingSongs, "A provider-side cancellation must not leave the load open")
        XCTAssertFalse(loader.isBusy)
        XCTAssertTrue(loader.hadCatalogFailures)
        XCTAssertFalse(loader.hasLoaded)
        XCTAssertEqual(loader.visibleTracks.map(\.id), ["listed"])

        loader.startLoadingSongs(catalog: catalog)
        XCTAssertTrue(loader.isLoadingSongs)
        let retry = try await catalog.searches.request(at: 1)
        let found = ArtistSpotlightTestSupport.collaboration("found", count: 900)
        try await catalog.searches.complete(retry, with: .success(CatalogPage(tracks: [found])))
        try await AppModelFixtures.eventually { loader.hasLoaded }
        XCTAssertFalse(loader.hadCatalogFailures)
        XCTAssertEqual(loader.featuredTracks.map(\.id), ["found"])
    }

    func testLeavingDuringTheAutomaticLanguagePassRunsItAgainOnTheNextVisit() async throws {
        let catalog = ArtistSpotlightCatalogFixture()
        let provider = ArtistSpotlightLyricsFixture()
        addTeardownBlock { await catalog.close(); await provider.requests.close() }
        let service = ArtistSpotlightLanguageService(provider: provider,
            hypotheses: ArtistSpotlightTestSupport.originalScriptHypotheses)
        let track = ArtistSpotlightTestSupport.track("interrupted", count: 100)
        let loader = ArtistSpotlightLoader(artist: ArtistSpotlightTestSupport.page([track]),
            catalogConfiguration: ArtistSpotlightTestSupport.catalogConfiguration(), languageService: service)
        let firstVisit = Task { await loader.load(catalog: catalog, lyrics: provider) }
        let interrupted = try await provider.requests.request(at: 0)
        firstVisit.cancel()
        loader.cancelLanguageChecks()
        await firstVisit.value
        try await AppModelFixtures.eventually { await service.activity.activeLookups == 0 }
        try await AppModelFixtures.eventually { loader.hasLoaded }
        XCTAssertFalse(loader.isBusy)
        XCTAssertEqual(loader.unclassifiedCount, 1)
        XCTAssertTrue(loader.canCheckMoreLanguages)

        let secondVisit = Task { await loader.load(catalog: catalog, lyrics: provider) }
        let resumed = try await provider.requests.request(at: 1)
        XCTAssertEqual(resumed.input.id, track.id, "An interrupted automatic pass runs again on the next visit")
        try await provider.requests.complete(resumed, with: .success(ArtistSpotlightTestSupport.document(track, text: ArtistSpotlightFixtures.tamilText)))
        await secondVisit.value
        XCTAssertEqual(loader.availableLanguages, [.tamil])
        XCTAssertFalse(loader.isBusy)
        try await provider.requests.complete(interrupted, with: .success(ArtistSpotlightTestSupport.document(track)))
        XCTAssertEqual(loader.availableLanguages, [.tamil], "The interrupted lookup's late result changes nothing")

        await loader.load(catalog: catalog, lyrics: provider)
        let total = await provider.requests.requests.count
        XCTAssertEqual(total, 2, "A completed pass does not run again on a later visit")
    }

    func testCorrectedAliasRetainsItsRecordingAndClearingCorrectionSelectsTheAlbum() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Breezy-AliasTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = LibraryStore(directory: directory)
        let catalog = ArtistSpotlightCatalogFixture()
        addTeardownBlock { await catalog.close() }
        let fixture = ArtistSpotlightTestSupport.releaseAliases()
        XCTAssertTrue(library.setRecordingLanguageOverride("ta", for: fixture.single.id))
        var preloadedPage = fixture.page
        preloadedPage.topSongs.append(fixture.album)
        var preloadedConfiguration = ArtistSpotlightTestSupport.catalogConfiguration()
        preloadedConfiguration.maximumAdditionalTracks = 0
        let preloaded = ArtistSpotlightLoader(artist: preloadedPage, catalogConfiguration: preloadedConfiguration, library: library)
        XCTAssertEqual(preloaded.tracks, [fixture.single], "Initial projection must honor the corrected recording too")

        let loader = ArtistSpotlightLoader(artist: fixture.page,
            catalogConfiguration: ArtistSpotlightTestSupport.catalogConfiguration(searchPages: 1), library: library)
        loader.filter = .language(.tamil)
        loader.isBrowsingLanguages = true
        loader.startLoadingSongs(catalog: catalog)
        let request = try await catalog.searches.request(at: 0)
        try await catalog.searches.complete(request, with: .success(CatalogPage(tracks: [fixture.album])))
        try await AppModelFixtures.eventually { loader.hasLoaded }
        XCTAssertEqual(loader.tracks, [fixture.single])
        XCTAssertEqual(loader.visibleTracks, [fixture.single])
        XCTAssertEqual(loader.listedTracks, [fixture.single])
        XCTAssertEqual(loader.languageResult(for: fixture.single), .identified(.tamil, source: .userOverride))
        XCTAssertNil(library.recordingLanguageOverrides[fixture.album.id])

        XCTAssertTrue(library.setRecordingLanguageOverride(nil, for: fixture.single.id))
        XCTAssertEqual(loader.tracks, [fixture.album])
        XCTAssertEqual(loader.listedTracks, [fixture.album])
        XCTAssertNil(loader.languageResult(for: fixture.album))
        XCTAssertTrue(loader.visibleTracks.isEmpty)
        XCTAssertEqual(loader.filter, .language(.tamil))
        XCTAssertTrue(loader.isBrowsingLanguages)

        XCTAssertTrue(library.setRecordingLanguageOverride("ta", for: fixture.single.id))
        XCTAssertTrue(library.setRecordingLanguageOverride("en", for: fixture.album.id))
        XCTAssertEqual(Set(loader.tracks.map(\.id)), [fixture.single.id, fixture.album.id])
        XCTAssertEqual(Set(preloaded.tracks.map(\.id)), [fixture.single.id, fixture.album.id],
                       "Splitting conflicting provider-listed recordings cannot consume the additional-song allowance")
        XCTAssertEqual(loader.visibleTracks, [fixture.single], "Conflicting corrections split instead of moving between IDs")
        XCTAssertEqual(loader.languageResult(for: fixture.album), .identified(.english, source: .userOverride))
        let restored = LibraryStore(directory: directory)
        XCTAssertEqual(restored.recordingLanguageOverrides, [fixture.single.id: "ta", fixture.album.id: "en"])
    }

    func testListedCollaborationAliasStaysOutOfFeaturingAndUpdatesListedRepresentative() async throws {
        let catalog = ArtistSpotlightCatalogFixture()
        addTeardownBlock { await catalog.close() }
        var fixture = ArtistSpotlightTestSupport.releaseAliases()
        fixture.single.credits.insert(ArtistCredit(name: "Another Singer", id: "UCsinger"), at: 0)
        fixture.album.credits = fixture.single.credits
        let other = ArtistSpotlightTestSupport.track("other-listed", count: 5_000)
        fixture.page.topSongs = [fixture.single, other]
        let loader = ArtistSpotlightLoader(artist: fixture.page,
            catalogConfiguration: ArtistSpotlightTestSupport.catalogConfiguration(searchPages: 1))
        XCTAssertTrue(loader.featuredTracks.isEmpty)
        loader.startLoadingSongs(catalog: catalog)
        let request = try await catalog.searches.request(at: 0)
        let found = ArtistSpotlightTestSupport.collaboration("new-feature", count: 2_000)
        try await catalog.searches.complete(request, with: .success(CatalogPage(tracks: [fixture.album, found])))
        try await AppModelFixtures.eventually { loader.hasLoaded }
        XCTAssertEqual(loader.featuredTracks, [found])
        XCTAssertEqual(loader.listedTracks, [fixture.album, other], "Listed groups keep provider order while adopting their representative")
        XCTAssertEqual(loader.tracks, [other, found, fixture.album], "The spotlight still sorts representatives by their own counts")
    }

    func testAutomaticChecksWaitForFinalRepresentativeAndRespectTheRecordingBudget() async throws {
        let catalog = ArtistSpotlightCatalogFixture()
        let provider = ArtistSpotlightLyricsFixture()
        addTeardownBlock { await catalog.close(); await provider.requests.close() }
        let fixture = ArtistSpotlightTestSupport.releaseAliases()
        let languageService = ArtistSpotlightLanguageService(provider: provider,
            hypotheses: ArtistSpotlightTestSupport.originalScriptHypotheses)
        var configuration = ArtistSpotlightLoader.Configuration()
        configuration.automaticLanguageChecks = 1
        let loader = ArtistSpotlightLoader(artist: fixture.page, configuration: configuration,
            catalogConfiguration: ArtistSpotlightTestSupport.catalogConfiguration(searchPages: 2), languageService: languageService)
        let loading = Task { await loader.load(catalog: catalog, lyrics: provider) }
        let first = try await catalog.searches.request(at: 0)
        let earlyChecks = await provider.requests.requests
        XCTAssertTrue(earlyChecks.isEmpty)
        try await catalog.searches.complete(first, with: .success(CatalogPage(tracks: [], continuation: "second")))
        let second = try await catalog.searches.request(at: 1)
        let intermediateChecks = await provider.requests.requests
        XCTAssertTrue(intermediateChecks.isEmpty)
        try await catalog.searches.complete(second, with: .success(CatalogPage(tracks: [fixture.album])))
        let language = try await provider.requests.request(at: 0)
        XCTAssertEqual(language.input, fixture.album)
        try await provider.requests.complete(language, with: .success(ArtistSpotlightTestSupport.document(fixture.album)))
        await loading.value
        XCTAssertEqual(loader.tracks, [fixture.album])
        XCTAssertEqual(loader.languageResult(for: fixture.album)?.language, .english)
        XCTAssertNil(loader.languageResult(for: fixture.single))
        XCTAssertEqual(Set(loader.languages.keys), [fixture.album.id])
        let checks = await provider.requests.requests
        XCTAssertEqual(checks.count, 1)
        XCTAssertEqual(loader.checkedLanguageCount, 1)
    }

    func testInFlightLanguageResultStaysWithItsRecordingAfterRepresentativeChanges() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Breezy-AliasEvidenceTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = LibraryStore(directory: directory)
        let catalog = ArtistSpotlightCatalogFixture()
        let provider = ArtistSpotlightLyricsFixture()
        addTeardownBlock { await catalog.close(); await provider.requests.close() }
        var fixture = ArtistSpotlightTestSupport.releaseAliases()
        fixture.page.topSongs.append(fixture.album)
        let service = ArtistSpotlightLanguageService(provider: provider,
            hypotheses: ArtistSpotlightTestSupport.originalScriptHypotheses)
        var configuration = ArtistSpotlightLoader.Configuration()
        configuration.automaticLanguageChecks = 1
        let loader = ArtistSpotlightLoader(artist: fixture.page, configuration: configuration,
            catalogConfiguration: ArtistSpotlightTestSupport.catalogConfiguration(), languageService: service, library: library)
        let loading = Task { await loader.load(catalog: catalog, lyrics: provider) }
        let request = try await provider.requests.request(at: 0)
        XCTAssertEqual(request.input.id, fixture.album.id)
        XCTAssertTrue(library.setRecordingLanguageOverride("ta", for: fixture.single.id))
        loader.filter = .language(.tamil)
        XCTAssertEqual(loader.tracks, [fixture.single])
        try await provider.requests.complete(request, with: .success(ArtistSpotlightTestSupport.document(fixture.album)))
        await loading.value
        XCTAssertEqual(loader.languageResult(for: fixture.single), .identified(.tamil, source: .userOverride))
        XCTAssertEqual(loader.languageResult(for: fixture.album)?.language, .english)
        XCTAssertEqual(Set(loader.tracks.map(\.id)), [fixture.single.id, fixture.album.id])
        XCTAssertEqual(loader.visibleTracks, [fixture.single])
        XCTAssertEqual(Set(loader.languages.keys), [fixture.album.id], "A valid hidden recording's result remains exact-ID evidence")
        let checks = await provider.requests.requests
        XCTAssertEqual(checks.count, 1)

        XCTAssertTrue(library.setRecordingLanguageOverride(nil, for: fixture.single.id))
        XCTAssertEqual(loader.tracks, [fixture.album])
        XCTAssertNil(loader.languageResult(for: fixture.single), "The album's result cannot become evidence for the single")
        XCTAssertEqual(loader.languageResult(for: fixture.album)?.language, .english)
    }
}

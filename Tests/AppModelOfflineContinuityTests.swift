import Foundation
import XCTest
@testable import GanaBajana

@MainActor
final class AppModelOfflineContinuityTests: XCTestCase {
    private let cached = Track(id: "fsiPzT50ZiM", title: "Cached first song", artists: ["First artist"],
                               duration: 30, language: .english, isAudioRecording: true)
    private let missing = Track(id: "NJAv_7lHUIU", title: "Uncached song", artists: ["Second artist"],
                                duration: 30, language: .english, isAudioRecording: true)
    private let nextCached = Track(id: "J7p4bzqLvCw", title: "Cached next song", artists: ["Third artist"],
                                   duration: 30, language: .english, isAudioRecording: true)

    func testRejectedOfflineSinglePlayPreservesPausedQueuePositionAndResumeIntent() async throws {
        let fixture = try makeCacheFixture()
        let media = try fixture.seed(cached.id, seconds: 30)
        try fixture.seed(nextCached.id, seconds: 30)
        let connectivity = ConnectivityMonitor(initialStatus: .offline, monitorsSystem: false)
        let calls = CatalogTestRecorder<String>()
        let resolver = forbiddenNetworkResolver(cache: fixture.cache, connectivity: connectivity, calls: calls)
        let queue = [cached, nextCached]
        let (context, model) = try makeContext(connectivity: connectivity,
            snapshot: PlaybackSnapshot(queue: queue, position: 3.25), resolver: resolver)
        await model.refreshCachedSongs()
        XCTAssertEqual(model.cachedPlayableTrackIDs, Set(queue.map(\.id)))

        XCTAssertFalse(model.play(missing, in: [missing, nextCached]))

        XCTAssertEqual(context.player.currentTrack, cached)
        XCTAssertEqual(context.player.queue, queue)
        XCTAssertEqual(context.player.currentIndex, 0)
        XCTAssertEqual(context.player.position, 3.25)
        XCTAssertFalse(context.player.isPlaying)
        XCTAssertFalse(context.player.isLoading)
        XCTAssertNil(context.player.currentStreamURL)
        XCTAssertNil(context.player.errorMessage)
        XCTAssertEqual(context.library.playback.queue, queue)
        XCTAssertEqual(context.library.playback.position, 3.25)
        XCTAssertTrue(model.toast?.contains("isn’t cached") == true)

        context.player.togglePlayback()
        try await PlaybackTestSupport.waitUntil { context.player.isPlaying && context.player.position > 3.5 }
        XCTAssertEqual(context.player.currentTrack, cached)
        XCTAssertEqual(context.player.currentStreamURL, media)
        XCTAssertTrue(context.player.isCurrentTrackCached)
        XCTAssertTrue(calls.values.isEmpty)
        XCTAssertTrue(fixture.mock.state.requests.isEmpty)
    }

    func testGuardedOfflineResumeOfMissingSongDoesNotSeekOrPausePlayingCachedAudio() async throws {
        let fixture = try makeCacheFixture()
        let media = try fixture.seed(cached.id, seconds: 30)
        try fixture.seed(nextCached.id, seconds: 30)
        let connectivity = ConnectivityMonitor(initialStatus: .offline, monitorsSystem: false)
        let calls = CatalogTestRecorder<String>()
        let resolver = forbiddenNetworkResolver(cache: fixture.cache, connectivity: connectivity, calls: calls)
        let queue = [cached, nextCached]
        let (context, model) = try makeContext(connectivity: connectivity,
            snapshot: PlaybackSnapshot(queue: queue, position: 3.25), resolver: resolver)
        await model.refreshCachedSongs()
        context.player.togglePlayback()
        try await PlaybackTestSupport.waitUntil { context.player.isPlaying && context.player.position > 3.5 }
        XCTAssertEqual(context.player.currentStreamURL, media)
        let position = context.player.position
        let resumePosition: TimeInterval = 21

        let accepted = model.play(missing, in: [cached, missing, nextCached])
        if accepted { context.player.seek(to: resumePosition) }

        XCTAssertFalse(accepted)
        XCTAssertEqual(context.player.currentTrack, cached)
        XCTAssertEqual(context.player.queue, queue)
        XCTAssertEqual(context.player.currentStreamURL, media)
        XCTAssertEqual(context.player.position, position)
        XCTAssertTrue(context.player.isPlaying)
        XCTAssertFalse(context.player.isLoading)
        XCTAssertNil(context.player.errorMessage)
        XCTAssertEqual(context.library.playback.queue, queue)
        try await PlaybackTestSupport.waitUntil { context.player.isPlaying && context.player.position > position + 0.3 }
        XCTAssertLessThan(context.player.position, resumePosition)
        XCTAssertEqual(context.player.currentTrack, cached)
        XCTAssertTrue(calls.values.isEmpty)
        XCTAssertTrue(fixture.mock.state.requests.isEmpty)
    }

    func testAcceptedOfflineResumeSelectsTheCachedSongBeforeApplyingItsPosition() async throws {
        let fixture = try makeCacheFixture()
        try fixture.seed(cached.id, seconds: 30)
        let media = try fixture.seed(nextCached.id, seconds: 30)
        let connectivity = ConnectivityMonitor(initialStatus: .offline, monitorsSystem: false)
        let calls = CatalogTestRecorder<String>()
        let resolver = forbiddenNetworkResolver(cache: fixture.cache, connectivity: connectivity, calls: calls)
        let (context, model) = try makeContext(connectivity: connectivity,
            snapshot: PlaybackSnapshot(queue: [cached], position: 3.25), resolver: resolver)
        await model.refreshCachedSongs()

        let accepted = model.play(nextCached, in: [cached, missing, nextCached])
        if accepted { context.player.seek(to: 10) }

        XCTAssertTrue(accepted)
        XCTAssertEqual(context.player.currentTrack, nextCached)
        XCTAssertEqual(context.player.queue, [cached, nextCached])
        XCTAssertEqual(context.player.currentIndex, 1)
        XCTAssertEqual(context.player.position, 10)
        try await PlaybackTestSupport.waitUntil { context.player.isPlaying && context.player.position > 10.3 }
        XCTAssertEqual(context.player.currentStreamURL, media)
        XCTAssertTrue(context.player.isCurrentTrackCached)
        XCTAssertNil(context.player.errorMessage)
        XCTAssertTrue(calls.values.isEmpty)
        XCTAssertTrue(fixture.mock.state.requests.isEmpty)
    }

    func testInitialUnknownToOnlinePreservesGatedHomeResponsesWithoutDuplicateQueries() async throws {
        let connectivity = ConnectivityMonitor(initialStatus: .unknown, monitorsSystem: false)
        let (context, model) = try makeContext(connectivity: connectivity, languages: [.hindi, .english])
        model.activateDeviceServices()
        let loading = context.start { _ in await model.loadHome() }
        let searches = [try await context.catalog.searches.request(at: 0), try await context.catalog.searches.request(at: 1)]
        let charts = [try await context.charts.charts.request(at: 0), try await context.charts.charts.request(at: 1)]
        XCTAssertTrue(model.isLoadingHome)
        XCTAssertFalse(model.listeningLanguageProfile.isLearned)

        connectivity.setStatus(.online)

        XCTAssertTrue(model.isLoadingHome)
        for request in searches {
            let language: MusicLanguage = request.input.query == "Hindi songs" ? .hindi : .english
            XCTAssertEqual(request.input.filter, .songs)
            XCTAssertNil(request.input.continuation)
            let track = AppModelFixtures.track("initial-\(language.rawValue)", language: language)
            try await context.catalog.searches.complete(request, with: .success(CatalogPage(tracks: [track])))
        }
        for request in charts {
            try await context.charts.charts.complete(request,
                with: .success(AppModelFixtures.chart("initial-\(request.input.rawValue)", language: request.input)))
        }
        await loading.value
        XCTAssertEqual(Set(searches.map(\.input.query)), ["Hindi songs", "English songs"])
        XCTAssertEqual(Set(charts.map(\.input)), [.hindi, .english])
        XCTAssertEqual(Set(model.homeSections.map(\.id)), ["discovery.language.hi", "discovery.language.en"])
        XCTAssertEqual(Set(model.homeSections.flatMap(\.tracks).map(\.id)), ["initial-hindi", "initial-english"])
        XCTAssertEqual(Set(model.charts.map(\.id)), ["initial-hindi", "initial-english"])
        XCTAssertFalse(model.isLoadingHome)
        XCTAssertNil(model.homeError)

        // A duplicate request gets a bounded response so a cache regression fails on its count, not a gate timeout.
        for _ in 0..<2 {
            await context.catalog.searches.enqueue(.success(CatalogPage()))
            await context.charts.charts.enqueue(.failure(MusicServiceError.unavailable("Unexpected duplicate chart")))
        }
        await model.loadHome()
        let allSearches = await context.catalog.searches.requests
        let allCharts = await context.charts.charts.requests
        let searchCancellations = await context.catalog.searches.cancellations
        let chartCancellations = await context.charts.charts.cancellations
        XCTAssertEqual(allSearches.count, 2)
        XCTAssertEqual(allCharts.count, 2)
        XCTAssertTrue(searchCancellations.isEmpty)
        XCTAssertTrue(chartCancellations.isEmpty)
    }

    func testOfflineRetiresLateHomeAndForegroundReconnectRefreshesWithoutClearingUsableContent() async throws {
        let connectivity = ConnectivityMonitor(initialStatus: .online, monitorsSystem: false)
        let (context, model) = try makeContext(connectivity: connectivity,
            snapshot: PlaybackSnapshot(queue: [cached], position: 3.25))
        model.activateDeviceServices()
        let previous = AppModelFixtures.track("previous-home")
        await context.catalog.searches.enqueue(.success(CatalogPage(tracks: [previous])))
        await context.charts.charts.enqueue(.success(AppModelFixtures.chart("previous-chart")))
        await model.loadHome()
        XCTAssertEqual(model.homeSections.flatMap(\.tracks), [previous])
        let staleLoad = context.start { _ in await model.loadHome(force: true) }
        let staleSearch = try await context.catalog.searches.request(at: 1)
        let staleChart = try await context.charts.charts.request(at: 1)

        connectivity.setStatus(.offline)
        await model.loadHome(force: true)
        XCTAssertFalse(model.isLoadingHome)
        XCTAssertEqual(model.homeSections.flatMap(\.tracks), [previous])
        XCTAssertEqual(model.charts.map(\.id), ["previous-chart"])
        try await context.catalog.searches.complete(staleSearch,
            with: .success(CatalogPage(tracks: [AppModelFixtures.track("late-home")])))
        try await context.charts.charts.complete(staleChart, with: .success(AppModelFixtures.chart("late-chart")))
        await staleLoad.value
        XCTAssertEqual(model.homeSections.flatMap(\.tracks), [previous])
        XCTAssertEqual(model.charts.map(\.id), ["previous-chart"])
        XCTAssertNil(model.homeError)
        let offlineSearches = await context.catalog.searches.requests
        let offlineCharts = await context.charts.charts.requests
        XCTAssertEqual(offlineSearches.count, 2)
        XCTAssertEqual(offlineCharts.count, 2)

        model.deactivateDeviceServices()
        connectivity.setStatus(.online)
        model.activateDeviceServices()
        let refreshed = context.start { _ in await model.loadHome() }
        let freshSearch = try await context.catalog.searches.request(at: 2)
        let freshChart = try await context.charts.charts.request(at: 2)
        XCTAssertTrue(model.isLoadingHome)
        XCTAssertEqual(model.homeSections.flatMap(\.tracks), [previous])
        XCTAssertEqual(model.charts.map(\.id), ["previous-chart"])
        let fresh = AppModelFixtures.track("reconnected-home")
        try await context.catalog.searches.complete(freshSearch, with: .success(CatalogPage(tracks: [fresh])))
        try await context.charts.charts.complete(freshChart, with: .success(AppModelFixtures.chart("reconnected-chart")))
        await refreshed.value
        XCTAssertEqual(model.homeSections.flatMap(\.tracks), [fresh])
        XCTAssertEqual(model.charts.map(\.id), ["reconnected-chart"])
        XCTAssertFalse(model.isLoadingHome)
        XCTAssertNil(model.homeError)
        XCTAssertEqual(context.player.queue, [cached])
        XCTAssertEqual(context.player.position, 3.25)
        XCTAssertFalse(context.player.isPlaying)
        XCTAssertFalse(context.player.isLoading)
        let allSearches = await context.catalog.searches.requests
        let allCharts = await context.charts.charts.requests
        XCTAssertEqual(allSearches.count, 3)
        XCTAssertEqual(allCharts.count, 3)
    }

    func testOfflineSearchResponsesCannotPublishOrEndTheReplacementSearchAfterReconnect() async throws {
        for fails in [false, true] {
            let connectivity = ConnectivityMonitor(initialStatus: .online, monitorsSystem: false)
            let (context, model) = try makeContext(connectivity: connectivity)
            model.activateDeviceServices()
            model.searchQuery = "same recording"
            model.searchFilter = .songs
            let staleLoad = context.start { _ in await model.loadSearch() }
            let stale = try await context.catalog.searches.request(at: 0)

            connectivity.setStatus(.offline)
            await model.loadSearch()
            XCTAssertFalse(model.isSearching)
            XCTAssertFalse(model.hasSearched)
            XCTAssertTrue(model.searchPage.tracks.isEmpty)
            let offlineRequests = await context.catalog.searches.requests
            XCTAssertEqual(offlineRequests.count, 1)

            connectivity.setStatus(.online)
            let freshLoad = context.start { _ in await model.loadSearch() }
            let freshRequest = try await context.catalog.searches.request(at: 1)
            XCTAssertEqual(freshRequest.input, stale.input)
            let staleResult: Result<CatalogPage, any Error> = fails
                ? .failure(MusicServiceError.unavailable("Obsolete offline search failure"))
                : .success(CatalogPage(tracks: [AppModelFixtures.track("obsolete-search")], continuation: "obsolete-page"))
            try await context.catalog.searches.complete(stale, with: staleResult)
            await staleLoad.value
            XCTAssertTrue(model.isSearching)
            XCTAssertFalse(model.hasSearched)
            XCTAssertTrue(model.searchPage.tracks.isEmpty)
            XCTAssertNil(model.searchPage.continuation)
            XCTAssertNil(model.searchError)

            let fresh = AppModelFixtures.track("fresh-search")
            try await context.catalog.searches.complete(freshRequest, with: .success(CatalogPage(tracks: [fresh])))
            await freshLoad.value
            XCTAssertEqual(model.searchPage.tracks, [fresh])
            XCTAssertTrue(model.hasSearched)
            XCTAssertFalse(model.isSearching)
            XCTAssertNil(model.searchError)
            let requests = await context.catalog.searches.requests
            XCTAssertEqual(requests.count, 2)
        }
    }

    func testOfflineModelSkipsHomeMixRadioAutoplayAndAutomaticLanguageProviders() async throws {
        let fixture = try makeCacheFixture()
        try fixture.seed(cached.id, seconds: 30)
        let connectivity = ConnectivityMonitor(initialStatus: .offline, monitorsSystem: false)
        let calls = CatalogTestRecorder<String>()
        let resolver = forbiddenNetworkResolver(cache: fixture.cache, connectivity: connectivity, calls: calls)
        let queue = [cached, nextCached]
        let (context, model) = try makeContext(connectivity: connectivity,
            snapshot: PlaybackSnapshot(queue: queue, position: 3.25), resolver: resolver, generatesMixes: true)
        _ = context.seedListener(primary: cached)
        var unknown = missing
        unknown.language = nil
        context.seedHistory(unknown)
        model.updatePreferences { $0.autoplay = true }
        let profile = TasteProfile.build(events: context.library.events, favorites: context.library.favorites,
            playlists: context.library.playlists, recents: context.library.recentlyPlayed, now: Date())
        XCTAssertFalse(profile.isColdStart)
        XCTAssertEqual(model.listeningLanguageSummary().totalPlays, 4)
        XCTAssertTrue(context.library.preferences.saveListeningHistory)
        model.activateDeviceServices()

        await model.loadHome(force: true)
        let mixes = model.refreshMixes()
        XCTAssertNil(mixes)
        mixes?.cancel()
        await mixes?.value
        let radio = model.startRadio(ExperienceRadioFixtures.melancholy)
        XCTAssertFalse(model.isLoadingRadio)
        if model.isLoadingRadio { radio.cancel() }
        await radio.value
        // Both continuation callbacks can try two queued seeds if their offline guard regresses.
        for _ in 0..<4 { await context.catalog.autoplayRadios.enqueue(.success([])) }
        let early = try XCTUnwrap(context.player.onQueueExhausted)
        let ended = try XCTUnwrap(context.player.onQueueEnded)
        let earlyTracks = await early(cached)
        let endedTracks = await ended(cached)
        context.player.prefetch([missing])
        await model.languageDiscovery.waitForChecks()

        XCTAssertTrue(earlyTracks.isEmpty)
        XCTAssertTrue(endedTracks.isEmpty)
        XCTAssertTrue(model.hasLoadedCachedSongs)
        XCTAssertEqual(model.cachedPlayableTrackIDs, [cached.id])
        XCTAssertTrue(model.homeSections.isEmpty)
        XCTAssertTrue(model.charts.isEmpty)
        XCTAssertTrue(context.library.mixes.isEmpty)
        XCTAssertFalse(model.isGeneratingMixes)
        XCTAssertFalse(model.isContinuingAutoplay)
        XCTAssertNil(model.autoplayContinuationError)
        XCTAssertNil(model.selectedRadioExperience)
        XCTAssertFalse(model.languageDiscovery.isChecking)
        XCTAssertEqual(context.player.queue, queue)
        XCTAssertEqual(context.player.position, 3.25)
        XCTAssertFalse(context.player.isPlaying)
        XCTAssertFalse(context.player.isLoading)
        let searches = await context.catalog.searches.requests
        let discoveries = await context.catalog.discoveries.requests
        let targeted = await context.catalog.radios.requests
        let autoplay = await context.catalog.autoplayRadios.requests
        let artists = await context.catalog.artists.requests
        let charts = await context.charts.charts.requests
        let lyrics = await context.lyrics.requests
        XCTAssertTrue(searches.isEmpty)
        XCTAssertTrue(discoveries.isEmpty)
        XCTAssertTrue(targeted.isEmpty)
        XCTAssertTrue(autoplay.isEmpty)
        XCTAssertTrue(artists.isEmpty)
        XCTAssertTrue(charts.isEmpty)
        XCTAssertTrue(lyrics.isEmpty)
        XCTAssertTrue(calls.values.isEmpty)
        XCTAssertTrue(fixture.mock.state.requests.isEmpty)
    }

    func testOfflineArrayPlaybackKeepsCachedOccurrencesAndRejectsAnEntirelyMissingReplacement() async throws {
        let fixture = try makeCacheFixture()
        let media = try fixture.seed(cached.id, seconds: 30)
        try fixture.seed(nextCached.id, seconds: 30)
        let connectivity = ConnectivityMonitor(initialStatus: .offline, monitorsSystem: false)
        let calls = CatalogTestRecorder<String>()
        let resolver = forbiddenNetworkResolver(cache: fixture.cache, connectivity: connectivity, calls: calls)
        let (context, model) = try makeContext(connectivity: connectivity, resolver: resolver)
        await model.refreshCachedSongs()

        model.play([missing, cached, missing, nextCached, cached])

        let expected = [cached, nextCached, cached]
        XCTAssertEqual(context.player.queue, expected)
        XCTAssertEqual(context.player.currentTrack, cached)
        XCTAssertFalse(context.player.shuffleEnabled)
        try await PlaybackTestSupport.waitUntil { context.player.isPlaying && context.player.position > 0.3 }
        let position = context.player.position
        XCTAssertEqual(context.player.currentStreamURL, media)

        model.play([missing, missing], shuffle: true)

        XCTAssertEqual(context.player.queue, expected)
        XCTAssertEqual(context.player.currentTrack, cached)
        XCTAssertEqual(context.player.currentIndex, 0)
        XCTAssertEqual(context.player.currentStreamURL, media)
        XCTAssertEqual(context.player.position, position)
        XCTAssertFalse(context.player.shuffleEnabled)
        XCTAssertTrue(context.player.isPlaying)
        XCTAssertFalse(context.player.isLoading)
        XCTAssertNil(context.player.errorMessage)
        XCTAssertEqual(context.library.playback.queue, expected)
        XCTAssertEqual(context.library.playback.originalQueue, expected)
        try await PlaybackTestSupport.waitUntil { context.player.isPlaying && context.player.position > position + 0.3 }
        XCTAssertEqual(context.player.queue, expected)
        XCTAssertTrue(calls.values.isEmpty)
        XCTAssertTrue(fixture.mock.state.requests.isEmpty)
    }

    func testRemovalRetiresACapturedInventoryWithoutRestoringItsRowOrEndingTheFreshRead() async throws {
        let fixture = try makeCacheFixture()
        let kept = try fixture.seed(cached.id, seconds: 30)
        let removedFile = try fixture.seed(nextCached.id, seconds: 30)
        let connectivity = ConnectivityMonitor(initialStatus: .online, monitorsSystem: false)
        let calls = CatalogTestRecorder<String>()
        let base = forbiddenNetworkResolver(cache: fixture.cache, connectivity: connectivity, calls: calls)
        let resolver = AppModelOfflineInventoryResolver(base: base)
        let (context, model) = try makeContext(connectivity: connectivity,
            snapshot: PlaybackSnapshot(queue: [cached], position: 3.25), resolver: resolver)
        addTeardownBlock { await resolver.snapshots.close() }
        let initialLoad = context.start { _ in await model.refreshCachedSongs() }
        let initial = try await resolver.snapshots.request(at: 0)
        try await resolver.snapshots.complete(initial, with: .success(()))
        await initialLoad.value
        XCTAssertEqual(model.cachedPlayableTrackIDs, [cached.id, nextCached.id])
        let staleLoad = context.start { _ in await model.refreshCachedSongs() }
        let stale = try await resolver.snapshots.request(at: 1)
        XCTAssertEqual(Set(try XCTUnwrap(stale.input).songs.map(\.id)), [cached.id, nextCached.id])

        let removalID = nextCached.id
        let removal = context.start { _ in await model.removeCachedSong(id: removalID) }
        let fresh = try await resolver.snapshots.request(at: 2)
        XCTAssertEqual(try XCTUnwrap(fresh.input).songs.map(\.id), [cached.id])
        XCTAssertTrue(model.isRefreshingCachedSongs)
        XCTAssertFalse(FileManager.default.fileExists(atPath: removedFile.path))
        try await resolver.snapshots.complete(stale, with: .success(()))
        await staleLoad.value

        XCTAssertTrue(model.isRefreshingCachedSongs)
        XCTAssertEqual(model.cachedSongs.map(\.id), [cached.id])
        XCTAssertEqual(model.cachedPlayableTrackIDs, [cached.id])
        XCTAssertEqual(model.cachedSongsUsage?.songCount, 1)
        try await resolver.snapshots.complete(fresh, with: .success(()))
        await removal.value
        XCTAssertFalse(model.isRefreshingCachedSongs)
        XCTAssertTrue(model.hasLoadedCachedSongs)
        XCTAssertNil(model.cachedSongsError)
        XCTAssertEqual(model.cachedSongs.map(\.id), [cached.id])
        XCTAssertEqual(model.cachedSongsUsage?.bytes, Int64(try Data(contentsOf: kept).count))
        XCTAssertEqual(context.player.queue, [cached])
        XCTAssertEqual(context.player.position, 3.25)
        XCTAssertFalse(context.player.isPlaying)
        XCTAssertTrue(calls.values.isEmpty)
        XCTAssertTrue(fixture.mock.state.requests.isEmpty)
    }

    private func makeContext(connectivity: ConnectivityMonitor, languages: Set<MusicLanguage> = [.english],
                             snapshot: PlaybackSnapshot = PlaybackSnapshot(), resolver: (any StreamResolving)? = nil,
                             generatesMixes: Bool = false) throws -> (AppModelTestContext, MusicAppModel) {
        let context = try AppModelTestContext(languages: languages, snapshot: snapshot, resolver: resolver)
        // The shared context owns storage and gates; this model uses an explicit non-system connectivity monitor.
        let model = MusicAppModel(library: context.library, player: context.player, catalog: context.catalog,
            charts: context.charts, lyrics: context.lyrics, account: context.model.account, appIcons: context.model.appIcons,
            recordingLanguageService: context.model.recordingLanguageService, languageDiscovery: context.model.languageDiscovery,
            connectivity: connectivity, generatesMixes: generatesMixes)
        addTeardownBlock { @MainActor in
            model.deactivateDeviceServices()
            model.cancelPendingRadio()
            connectivity.stop()
            try await context.close()
        }
        return (context, model)
    }

    private func makeCacheFixture() throws -> CacheManagementFixture {
        let fixture = try CacheManagementFixture()
        addTeardownBlock { @MainActor in try await fixture.close() }
        return fixture
    }

    private func forbiddenNetworkResolver(cache: AudioCache, connectivity: ConnectivityMonitor,
                                          calls: CatalogTestRecorder<String>) -> YouTubeStreamResolver {
        YouTubeStreamResolver(extract: { _, _ in calls.record("extract"); throw URLError(.notConnectedToInternet) },
            validate: { _ in calls.record("validate"); throw URLError(.notConnectedToInternet) },
            fastExtract: { _ in calls.record("fast"); throw URLError(.notConnectedToInternet) },
            audioCache: cache, isOffline: { connectivity.isOffline })
    }
}

private actor AppModelOfflineInventoryResolver: StreamCacheManaging {
    let snapshots = AppModelRequestGate<AudioCacheSnapshot?, Void>()
    private let base: YouTubeStreamResolver

    init(base: YouTubeStreamResolver) { self.base = base }

    func audioCacheSnapshot() async throws -> AudioCacheSnapshot? {
        let captured = try await base.audioCacheSnapshot()
        try await snapshots.receive(captured)
        return captured
    }

    func audioCacheUsage() async throws -> AudioCache.Usage? { try await base.audioCacheUsage() }
    func resolve(track: Track, forceRefresh: Bool) async throws -> ResolvedStream {
        try await base.resolve(track: track, forceRefresh: forceRefresh)
    }
    func download(_ track: Track) async throws -> ResolvedStream { try await base.download(track) }
    func discardCached(_ track: Track) async { await base.discardCached(track) }
    func discardCached(_ track: Track, url: URL?) async { await base.discardCached(track, url: url) }
    func retainCached(_ trackIDs: Set<String>) async { await base.retainCached(trackIDs) }
    nonisolated func isCachedStream(_ stream: ResolvedStream) -> Bool { base.isCachedStream(stream) }
    func updateCacheListeningHistory(_ events: [ListeningEvent], now: Date) async {
        await base.updateCacheListeningHistory(events, now: now)
    }
    func removeCachedSong(id: String, retaining: @escaping @Sendable () async -> Set<String>) async throws -> AudioCacheRemoval? {
        try await base.removeCachedSong(id: id, retaining: retaining)
    }
    func clearAudioCache(retaining: @escaping @Sendable () async -> Set<String>) async throws -> AudioCache.Usage? {
        try await base.clearAudioCache(retaining: retaining)
    }
    func setAudioCacheLimit(_ limit: AudioCacheLimit,
                           retaining: @escaping @Sendable () async -> Set<String>) async throws -> AudioCache.Usage? {
        try await base.setAudioCacheLimit(limit, retaining: retaining)
    }
}

import XCTest
@testable import GanaBajana

/// Fixture resolvers that are not `StreamWarming` must leave the warmer inert.
@MainActor
final class PlaybackWarmerTests: XCTestCase {
    private let tracks = (0..<6).map { index -> Track in
        Track(id: String(format: "fixture%04d", index), title: "Song \(index)")
    }

    private final class NetworkState {
        var offline = false
        var expensive = false
        var constrained = false
        var cellularAllowed = false
    }

    private func makeWarmer(_ resolver: any StreamResolving, network: NetworkState = NetworkState(), enabled: Bool = true,
                            now: @escaping @MainActor () -> Date = { Date() }) -> PlaybackWarmer {
        PlaybackWarmer(resolver: resolver, network: PlaybackWarmer.Network(
            isOffline: { network.offline }, isExpensive: { network.expensive },
            isConstrained: { network.constrained }, allowsExpensive: { network.cellularAllowed }), enabled: enabled, now: now)
    }

    func testSearchAndCollectionsWarmThreeResultsAndBothDownloadTheFirst() async throws {
        let fake = WarmingFake()
        let warmer = makeWarmer(fake)
        XCTAssertTrue(warmer.isAvailable)
        var video = tracks[1]
        video.isAudioRecording = false
        warmer.warm([tracks[0], video, tracks[0], tracks[2], tracks[3], tracks[4]], surface: .search, owner: PlaybackWarmer.searchOwner)
        try await PlaybackTestSupport.eventually { await fake.calls.count == 1 }
        try await PlaybackTestSupport.eventually { warmer.lastOutcome != nil }
        let search = await fake.calls[0]
        XCTAssertEqual(search.ids, [tracks[0].id, tracks[2].id, tracks[3].id], "Video rows and duplicates never count against the budget")
        XCTAssertTrue(search.download)
        XCTAssertEqual(warmer.resolvedCount, 3)
        XCTAssertEqual(warmer.lastSurface, .search)

        warmer.warm(tracks, surface: .collection, owner: "album")
        try await PlaybackTestSupport.eventually { await fake.calls.count == 2 }
        let collection = await fake.calls[1]
        XCTAssertEqual(collection.ids, [tracks[0].id, tracks[1].id, tracks[2].id])
        XCTAssertTrue(collection.download, "An opened album or playlist also caches its first song")
    }

    func testOfflineLowDataAndUnconsentedExpensivePathsSkipEverything() async throws {
        let fake = WarmingFake()
        let network = NetworkState()
        let warmer = makeWarmer(fake, network: network)
        network.offline = true
        warmer.warm(tracks, surface: .search, owner: PlaybackWarmer.searchOwner)
        XCTAssertFalse(warmer.isActive)
        network.offline = false
        network.expensive = true
        warmer.warm(tracks, surface: .search, owner: PlaybackWarmer.searchOwner)
        XCTAssertFalse(warmer.isActive, "Cellular without Download over cellular spends nothing on a guess")
        network.cellularAllowed = true
        network.constrained = true
        warmer.warm(tracks, surface: .collection, owner: "album")
        XCTAssertFalse(warmer.isActive, "Low Data Mode wins over the cellular consent")
        try await Task.sleep(for: .milliseconds(100))
        let skipped = await fake.calls
        XCTAssertTrue(skipped.isEmpty, "Skipped events make no provider request")

        network.constrained = false
        warmer.warm(tracks, surface: .search, owner: PlaybackWarmer.searchOwner)
        try await PlaybackTestSupport.eventually { await fake.calls.count == 1 }
        let consented = await fake.calls[0]
        XCTAssertTrue(consented.download, "With Download over cellular on, an expensive path warms normally")
    }

    func testTwelveResolutionsPerMinuteAcrossEventsWithSkippedSongsRefunded() async throws {
        let fake = WarmingFake(skipFirst: true)
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let warmer = makeWarmer(fake, now: { clock })
        for index in 0..<5 {
            warmer.warm(tracks, surface: .search, owner: PlaybackWarmer.searchOwner)
            try await PlaybackTestSupport.eventually { await fake.calls.count == index + 1 }
            try await PlaybackTestSupport.eventually { !warmer.isActive }
        }
        // Each event reserved 3 and refunded its 1 skipped song, so five events used 10 of the 12.
        warmer.warm(tracks, surface: .search, owner: PlaybackWarmer.searchOwner)
        try await PlaybackTestSupport.eventually { await fake.calls.count == 6 }
        let partial = await fake.calls[5]
        XCTAssertEqual(partial.ids.count, 2, "Only the rest of the minute's budget is spent")
        try await PlaybackTestSupport.eventually { !warmer.isActive }
        let beforeRefundCount = await fake.calls.count
        warmer.warm(tracks, surface: .search, owner: PlaybackWarmer.searchOwner)
        warmer.warm(tracks, surface: .search, owner: PlaybackWarmer.searchOwner)
        try await Task.sleep(for: .milliseconds(100))
        let exhausted = await fake.calls.count
        XCTAssertLessThanOrEqual(exhausted - beforeRefundCount, 1, "At most the refunded song remains in this minute")

        clock = clock.addingTimeInterval(61)
        warmer.warm(tracks, surface: .search, owner: PlaybackWarmer.searchOwner)
        try await PlaybackTestSupport.eventually { await fake.calls.count == exhausted + 1 }
        let renewed = await fake.calls.last
        XCTAssertEqual(renewed?.ids.count, 3, "A new minute restores the full per-event limit")
    }

    func testANewQueryCancelsTheRunningWarmAndOnlyTheNewestOutcomeIsPublished() async throws {
        let fake = WarmingFake(hold: true)
        let warmer = makeWarmer(fake)
        warmer.warm([tracks[0]], surface: .search, owner: PlaybackWarmer.searchOwner)
        try await PlaybackTestSupport.eventually { await fake.calls.count == 1 }
        XCTAssertTrue(warmer.isActive)
        warmer.warm([tracks[1]], surface: .search, owner: PlaybackWarmer.searchOwner)
        try await PlaybackTestSupport.eventually { await fake.cancelled.count == 1 }
        try await PlaybackTestSupport.eventually { await fake.calls.count == 2 }
        let first = await fake.calls[0]
        try await PlaybackTestSupport.eventually { await fake.cancelledTokens.contains(first.token) }
        await fake.release()
        try await PlaybackTestSupport.eventually { warmer.lastOutcome != nil }
        let calls = await fake.calls
        XCTAssertEqual(calls.map(\.ids), [[tracks[0].id], [tracks[1].id]])
        XCTAssertEqual(warmer.resolvedCount, 1)
        XCTAssertFalse(warmer.isActive)
        let newest = await fake.cancelledTokens
        XCTAssertFalse(newest.contains(calls[1].token), "The newer job's download is never cancelled by the older one")

        warmer.warm([tracks[2]], surface: .collection, owner: "album")
        warmer.cancel()
        XCTAssertFalse(warmer.isActive)
        await fake.release()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(warmer.lastSurface, .search, "A cancelled job publishes nothing")
    }

    func testLeavingAPageCancelsOnlyThatPagesJob() async throws {
        let fake = WarmingFake(hold: true)
        let warmer = makeWarmer(fake)
        warmer.warm([tracks[0]], surface: .collection, owner: "album-b")
        try await PlaybackTestSupport.eventually { await fake.calls.count == 1 }
        warmer.cancel(owner: "album-a")
        XCTAssertTrue(warmer.isActive, "A late disappearance of the previous page leaves the newer page's job running")
        warmer.cancel(owner: "album-b")
        XCTAssertFalse(warmer.isActive)
        let job = await fake.calls[0]
        try await PlaybackTestSupport.eventually { await fake.cancelledTokens.contains(job.token) }
        await fake.release()
    }

    func testResolversWithoutWarmingSupportAndTheDisabledSwitchLeaveTheWarmerInert() async throws {
        let gate = PlaybackResolutionGate()
        let inert = makeWarmer(gate)
        XCTAssertFalse(inert.isAvailable)
        inert.warm(tracks, surface: .search, owner: PlaybackWarmer.searchOwner)
        XCTAssertFalse(inert.isActive)
        try await Task.sleep(for: .milliseconds(50))
        let requests = await gate.requests
        XCTAssertTrue(requests.isEmpty, "A plain resolver is never asked to resolve a song the listener did not choose")

        let fake = WarmingFake()
        let disabled = makeWarmer(fake, enabled: false)
        XCTAssertFalse(disabled.isAvailable)
        disabled.warm(tracks, surface: .search, owner: PlaybackWarmer.searchOwner)
        try await Task.sleep(for: .milliseconds(50))
        let calls = await fake.calls
        XCTAssertTrue(calls.isEmpty)
        XCTAssertFalse(PlaybackWarmer.isEnabledByDefault, "The unit host never warms through a model's default warmer")
    }

    func testYouTubeWarmSkipsLocalCopiesAndLiveURLsAndDownloadsOnlyAnUncachedFirstResult() async throws {
        let fixture = try CacheManagementFixture()
        addTeardownBlock { try await fixture.close() }
        let a = Track(id: "fsiPzT50ZiM", title: "A")
        let b = Track(id: "NJAv_7lHUIU", title: "B")
        let c = Track(id: "J7p4bzqLvCw", title: "C")
        try fixture.seed(a.id)
        let fastCalls = CatalogTestRecorder<String>()
        let resolver = YouTubeStreamResolver(extract: { id, _ in [AudioCacheTests.remote(id)] }, validate: { _ in },
                                             fastExtract: { id in
                                                 fastCalls.record(id)
                                                 return FastPathResult(urls: [AudioCacheTests.remote(id)])
                                             }, audioCache: fixture.cache)
        _ = try await resolver.resolve(track: b, forceRefresh: false)
        let outcome = await resolver.warm([a, b, c], download: true, token: UUID())
        XCTAssertEqual(outcome, StreamWarmOutcome(resolved: 1, skipped: 2, failed: 0, downloadScheduled: false),
                       "A cached first result is never downloaded again; the live URL for B is reused")
        XCTAssertEqual(fastCalls.values, [b.id, c.id])
        let pending = await resolver.prefetchDownloadTrackID
        XCTAssertNil(pending)

        let downloaded = await resolver.warm([c, b], download: true, token: UUID())
        XCTAssertEqual(downloaded.resolved, 0)
        XCTAssertEqual(downloaded.skipped, 2)
        XCTAssertTrue(downloaded.downloadScheduled, "An uncached first result with a live URL still gets its speculative download")
        try await PlaybackTestSupport.eventually(timeout: 5) { await fixture.cache.entry(for: c.id) != nil }
        let bEntry = await fixture.cache.entry(for: b.id)
        XCTAssertNil(bEntry, "Only the first result is downloaded")
    }

    func testCompositeWarmRoutesPrefixedIDsToTheirResolversWithoutDownloadingThem() async throws {
        let fixture = try CacheManagementFixture()
        addTeardownBlock { try await fixture.close() }
        let extracted = CatalogTestRecorder<String>()
        let youTube = YouTubeStreamResolver(timeout: 5, extract: { id, _ in extracted.record(id); return [] }, validate: { _ in },
                                            fastExtract: { FastPathResult(urls: [AudioCacheTests.remote($0)]) }, audioCache: fixture.cache)
        let saavnMock = CatalogMockSession { request in
            let call = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "__call" }?.value
            guard call == "song.getDetails" else { throw URLError(.unsupportedURL) }
            let bundle = Bundle(for: PlaybackWarmerTests.self)
            let url = try XCTUnwrap(bundle.url(forResource: "saavn-song-details", withExtension: "json")
                ?? bundle.url(forResource: "saavn-song-details", withExtension: "json", subdirectory: "Fixtures"))
            return CatalogStub(data: try Data(contentsOf: url))
        }
        defer { saavnMock.close() }
        let probes = CatalogTestRecorder<String>()
        let saavn = JioSaavnStreamResolver(catalog: JioSaavnCatalogService(session: saavnMock.session), probe: { probes.record($0.host ?? "") })
        let gaanaMock = GaanaTests.mock()
        defer { gaanaMock.close() }
        let gaana = GaanaStreamResolver(catalog: GaanaCatalogService(session: gaanaMock.session), probe: { probes.record($0.host ?? "") },
                                        now: { Date(timeIntervalSince1970: 1_790_420_000) })
        let composite = CompositeStreamResolver(youTube: youTube, saavn: saavn, gaana: gaana, audioCache: fixture.cache)
        let saavnTrack = Track(id: "saavn:aRZbUYD7", title: "Tum Hi Ho", credits: [])
        let gaanaTrack = Track(id: "gaana:944286", title: "Tum Hi Ho", credits: [])
        let youTubeTrack = Track(id: "fsiPzT50ZiM", title: "Tum Hi Ho", credits: [])

        let outcome = await composite.warm([saavnTrack, youTubeTrack, gaanaTrack], download: true, token: UUID())
        XCTAssertEqual(outcome.resolved, 3)
        XCTAssertEqual(outcome.skipped, 0)
        XCTAssertFalse(outcome.downloadScheduled, "A prefixed first result never starts a download")
        XCTAssertEqual(saavnMock.state.requests.count, 1)
        XCTAssertTrue(probes.values.contains("aac.saavncdn.com"))
        XCTAssertTrue(probes.values.contains { $0.hasSuffix("akamaized.net") })
        XCTAssertTrue(extracted.values.isEmpty, "Warm-ups never enter YouTubeKit")
        let pending = await youTube.prefetchDownloadTrackID
        XCTAssertNil(pending)

        let again = await composite.warm([youTubeTrack, saavnTrack], download: true, token: UUID())
        XCTAssertEqual(again.resolved, 0)
        XCTAssertEqual(again.skipped, 2, "Live URLs on every source are reused")
        XCTAssertTrue(again.downloadScheduled, "A YouTube first result gets the speculative download")
        XCTAssertEqual(saavnMock.state.requests.count, 1)
        try await PlaybackTestSupport.eventually(timeout: 5) { await fixture.cache.entry(for: youTubeTrack.id) != nil }

        // A tap after the warm reuses the source resolver's signed URL and reports the start as warmed, once.
        _ = try await composite.resolve(track: saavnTrack, forceRefresh: false)
        XCTAssertEqual(saavnMock.state.requests.count, 1)
        XCTAssertEqual(PlaybackStartTrace.path(for: saavnTrack.id), .urlCache)
        XCTAssertEqual(PlaybackStartTrace.startPath(for: saavnTrack.id), .warmed)
        _ = try await composite.resolve(track: gaanaTrack, forceRefresh: false)
        XCTAssertEqual(PlaybackStartTrace.startPath(for: gaanaTrack.id), .warmed)
        _ = try await composite.resolve(track: saavnTrack, forceRefresh: false)
        XCTAssertEqual(PlaybackStartTrace.startPath(for: saavnTrack.id), .urlCache, "Only the first start after a warm counts as warmed")
        _ = try await composite.resolve(track: saavnTrack, forceRefresh: true)
        XCTAssertEqual(PlaybackStartTrace.startPath(for: saavnTrack.id), .saavn, "A fresh provider lookup reports its own path")
    }

    func testTappingAWarmedSongReusesItsURLAndReportsWarmed() async throws {
        let fastCalls = CatalogTestRecorder<String>()
        let resolver = YouTubeStreamResolver(extract: { id, _ in [AudioCacheTests.remote(id)] }, validate: { _ in },
                                             fastExtract: { id in
                                                 fastCalls.record(id)
                                                 return FastPathResult(urls: [AudioCacheTests.remote(id)])
                                             })
        let warmedTrack = Track(id: "9qnqYL0eNNI", title: "Warmed")
        let coldTrack = Track(id: "WrWcOLlmv7k", title: "Cold")
        let outcome = await resolver.warm([warmedTrack], download: false, token: UUID())
        XCTAssertEqual(outcome.resolved, 1)
        _ = try await resolver.resolve(track: warmedTrack, forceRefresh: false)
        XCTAssertEqual(fastCalls.values, [warmedTrack.id], "The tap reuses the warmed signed URL")
        XCTAssertEqual(PlaybackStartTrace.startPath(for: warmedTrack.id), .warmed)
        _ = try await resolver.resolve(track: coldTrack, forceRefresh: false)
        XCTAssertEqual(PlaybackStartTrace.startPath(for: coldTrack.id), .fastPath)
    }

    func testAWarmNeverDisplacesTheQueuePrefetchDownloadAndCancelsOnlyItsOwnDownload() async throws {
        let fixture = try CacheManagementFixture()
        addTeardownBlock { try await fixture.close() }
        let upcoming = Track(id: "7374CZQoS2Y", title: "Upcoming")
        let guess = Track(id: "swJOIjjW69U", title: "Search result")
        let held = Track(id: "WrWcOLlmv7k", title: "Held result")
        let gate = AppModelRequestGate<String, FastPathResult>()
        addTeardownBlock { await gate.close() }
        let heldIDs: Set<String> = [upcoming.id, held.id]
        let resolver = YouTubeStreamResolver(extract: { id, _ in [AudioCacheTests.remote(id)] }, validate: { _ in },
                                             fastExtract: { id in
                                                 if heldIDs.contains(id) { return try await gate.receive(id) }
                                                 return FastPathResult(urls: [AudioCacheTests.remote(id)])
                                             }, audioCache: fixture.cache)
        let queue = Task { await resolver.prefetch([upcoming]) }
        try await PlaybackTestSupport.eventually { await resolver.prefetchDownloadTrackID == upcoming.id }
        let blocked = await resolver.warm([guess], download: true, token: UUID())
        XCTAssertFalse(blocked.downloadScheduled)
        XCTAssertEqual(blocked.resolved, 1, "The warm still resolves its URL")
        let kept = await resolver.prefetchDownloadTrackID
        XCTAssertEqual(kept, upcoming.id, "The upcoming queue song keeps its download")
        queue.cancel()
        let first = try await gate.request(at: 0)
        try await gate.complete(first, with: .failure(CancellationError()))
        await queue.value
        try await PlaybackTestSupport.eventually(timeout: 5) { await resolver.prefetchDownloadTrackID == nil }

        let older = UUID()
        let newer = UUID()
        let warm = Task { await resolver.warm([held], download: true, token: newer) }
        try await PlaybackTestSupport.eventually { await resolver.prefetchDownloadTrackID == held.id }
        await resolver.cancelWarm(token: older)
        let survivor = await resolver.prefetchDownloadTrackID
        XCTAssertEqual(survivor, held.id, "A stale job's cancel leaves the newer warm's download alone")
        // A newest warm of the same first song adopts the running download instead of starting another.
        let newest = UUID()
        let rewarm = Task { await resolver.warm([held], download: true, token: newest) }
        try await PlaybackTestSupport.eventually { await resolver.activeWaiterCount == 3 }
        await resolver.cancelWarm(token: newer)
        let adopted = await resolver.prefetchDownloadTrackID
        XCTAssertEqual(adopted, held.id, "The replaced job's cancel no longer owns the adopted download")
        await resolver.cancelWarm(token: newest)
        let cancelled = await resolver.prefetchDownloadTrackID
        XCTAssertNil(cancelled)
        warm.cancel()
        rewarm.cancel()
        await gate.close()
        _ = await warm.value
        _ = await rewarm.value
    }
}

/// Records every warm and can hold it open so a test observes cancellation.
private actor WarmingFake: StreamWarming {
    struct Call: Sendable {
        let ids: [String]
        let download: Bool
        let token: UUID
    }

    private(set) var calls: [Call] = []
    private(set) var cancelled: [Int] = []
    private(set) var cancelledTokens: [UUID] = []
    private let hold: Bool
    private let skipFirst: Bool
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(hold: Bool = false, skipFirst: Bool = false) {
        self.hold = hold
        self.skipFirst = skipFirst
    }

    func resolve(track: Track, forceRefresh: Bool) async throws -> ResolvedStream {
        throw PlaybackStreamError.noAudio
    }

    func warm(_ tracks: [Track], download: Bool, token: UUID) async -> StreamWarmOutcome {
        let index = calls.count
        calls.append(Call(ids: tracks.map(\.id), download: download, token: token))
        if hold {
            await withTaskCancellationHandler {
                await withCheckedContinuation { waiting.append($0) }
            } onCancel: {
                Task { await self.noteCancelled(index) }
            }
        }
        if Task.isCancelled { return StreamWarmOutcome() }
        let skipped = skipFirst && !tracks.isEmpty ? 1 : 0
        return StreamWarmOutcome(resolved: tracks.count - skipped, skipped: skipped)
    }

    func cancelWarm(token: UUID) async {
        cancelledTokens.append(token)
    }

    func release() {
        waiting.forEach { $0.resume() }
        waiting.removeAll()
    }

    private func noteCancelled(_ index: Int) {
        cancelled.append(index)
        release()
    }
}

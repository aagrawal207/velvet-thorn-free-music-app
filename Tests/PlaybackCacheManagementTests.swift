import XCTest
@testable import GanaBajana

@MainActor
final class PlaybackCacheManagementTests: XCTestCase {
    private let a = Track(id: "fsiPzT50ZiM", title: "First")
    private let b = Track(id: "NJAv_7lHUIU", title: "Next")
    private let c = Track(id: "J7p4bzqLvCw", title: "Later")
    private let d = Track(id: "xTvyyoF_LZY", title: "Suggested")

    func testPlayerReportsTheInjectedCacheAndClearsWithoutInterruptingCurrentOrStandbyAudio() async throws {
        let payload = PlaybackTestSupport.audioData(seconds: 1)
        let fixture = try makeFixture { _ in
            CatalogStub(headers: ["Content-Type": "audio/wav", "Content-Length": "\(payload.count)"], data: payload, delay: 10)
        }
        let firstURL = try fixture.seed(a.id, seconds: 6)
        let nextURL = try fixture.seed(b.id, seconds: 5)
        let unusedURL = try fixture.seed(c.id)
        let player = PlayerController(resolver: fixture.resolver())
        defer { player.pause() }
        player.apply(settings())
        player.play([a, b])
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.isStandbyReady && player.isNextTrackCached }
        player.prefetch([d])
        try await PlaybackTestSupport.eventually { fixture.mock.state.requests.count == 1 }
        let before = try await player.audioCacheUsage()
        XCTAssertEqual(before?.songCount, 3)
        XCTAssertEqual(before?.pendingDownloads, 1, "Usage comes from the writer's live cache instance")
        let position = player.position

        let cleared = try await player.clearTemporaryAudioCache()

        XCTAssertEqual(cleared?.retainedSongCount, 2)
        XCTAssertEqual(cleared?.retainedBytes, Int64(try Data(contentsOf: firstURL).count + Data(contentsOf: nextURL).count))
        XCTAssertEqual(cleared?.pendingDownloads, 0)
        XCTAssertEqual(player.currentStreamURL, firstURL)
        XCTAssertEqual(player.standbyStreamURL, nextURL)
        XCTAssertTrue(player.isStandbyReady)
        XCTAssertFalse(FileManager.default.fileExists(atPath: unusedURL.path))
        XCTAssertNil(player.errorMessage)
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.position > position + 0.25 }
        try await PlaybackTestSupport.eventually { fixture.mock.state.cancellations == 1 }
        try await PlaybackTestSupport.waitUntil(timeout: 9) { player.currentTrack == self.b && player.isPlaying }
        XCTAssertEqual(player.currentStreamURL, nextURL, "The retained standby can still become the playing item")
        XCTAssertNil(player.errorMessage)
        let suggested = await fixture.cache.entry(for: d.id)
        XCTAssertNil(suggested, "The cancelled suggested download cannot repopulate the cache")
    }

    func testClearingDuringACrossfadeRetainsTheOutgoingFileAsWellAsTheNewPair() async throws {
        let fixture = try makeFixture()
        let outgoingURL = try fixture.seed(a.id, seconds: 8)
        let activeURL = try fixture.seed(b.id, seconds: 8)
        let upcomingURL = try fixture.seed(c.id, seconds: 8)
        let unusedURL = try fixture.seed(d.id)
        let player = PlayerController(resolver: fixture.resolver())
        defer { player.pause() }
        player.apply(settings(crossfade: 3))
        player.play([a, b, c])
        try await PlaybackTestSupport.waitUntil(timeout: 10) { player.currentTrack == self.b && player.crossfadeState != nil }
        await fixture.cache.pin(only: [b.id, c.id])

        let cleared = try await player.clearTemporaryAudioCache()

        XCTAssertEqual(cleared?.retainedSongCount, 3, "The outgoing player still owns its audio even after the next pair is pinned")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outgoingURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: upcomingURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: unusedURL.path))
        XCTAssertEqual(player.currentStreamURL, activeURL)
        try await PlaybackTestSupport.waitUntil { player.crossfadeState == nil && player.isPlaying }
        XCTAssertNil(player.errorMessage)
    }

    func testResolverClearStopsAPrefetchWhoseExtractionFinishesLate() async throws {
        let fixture = try makeFixture()
        let gate = AppModelRequestGate<String, FastPathResult>()
        addTeardownBlock { await gate.close() }
        let delayedID = a.id
        let resolver = fixture.resolver { id in
            if id == delayedID { return try await gate.receive(id) }
            return FastPathResult(urls: [AudioCacheTests.remote(id)])
        }
        let prefetch = Task { await resolver.prefetch([a, b]) }
        let request = try await gate.request(at: 0)
        try await PlaybackTestSupport.eventually { await resolver.prefetchDownloadTrackID == delayedID }

        let cleared = try await resolver.clearAudioCache { [] }
        try await gate.complete(request, with: .success(FastPathResult(urls: [AudioCacheTests.remote(a.id)])))
        await prefetch.value

        XCTAssertEqual(cleared?.songCount, 0)
        XCTAssertEqual(fixture.mock.state.requests.count, 0, "Late extraction cannot start a pre-clear download")
        let pending = await resolver.prefetchDownloadTrackID
        XCTAssertNil(pending)
        let fresh = try await resolver.download(b)
        XCTAssertTrue(fresh.url.isFileURL)
        let usage = try await resolver.audioCacheUsage()
        XCTAssertEqual(usage?.songCount, 1)
        XCTAssertEqual(fixture.mock.state.requests.count, 1)
    }

    func testResolverClearInvalidatesDownloadsWaitingForForegroundWithoutCancellingPlaybackResolution() async throws {
        let fixture = try makeFixture()
        let gate = AppModelRequestGate<String, FastPathResult>()
        addTeardownBlock { await gate.close() }
        let foregroundID = a.id
        let resolver = fixture.resolver { id in
            if id == foregroundID { return try await gate.receive(id) }
            return FastPathResult(urls: [AudioCacheTests.remote(id)])
        }
        let foreground = Task { try await resolver.resolve(track: a, forceRefresh: false) }
        let request = try await gate.request(at: 0)
        let download = Task { try await resolver.download(b) }
        try await PlaybackTestSupport.eventually { await resolver.activeDownloadCount == 1 }

        _ = try await resolver.clearAudioCache { [] }
        try await gate.complete(request, with: .success(FastPathResult(urls: [AudioCacheTests.remote(a.id)])))
        let playingStream = try await foreground.value

        XCTAssertFalse(playingStream.url.isFileURL)
        do { _ = try await download.value; XCTFail("The waiting download belongs to the cleared generation") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertEqual(fixture.mock.state.requests.count, 0)
    }

    func testPipelineCancelsTheOldPairAndAcceptsAQueueChangeMadeDuringClear() async throws {
        let payload = PlaybackTestSupport.audioData(seconds: 1)
        let fixture = try makeFixture { _ in
            CatalogStub(headers: ["Content-Type": "audio/wav", "Content-Length": "\(payload.count)"], data: payload, delay: 10)
        }
        try fixture.seed(a.id)
        try fixture.seed(c.id)
        let pipeline = PlaybackCachePipeline(resolver: fixture.resolver())
        defer { pipeline.cancel() }
        var delivered: [String] = []
        pipeline.onNextCached = { target, _ in delivered.append(target.track.id) }
        pipeline.onCurrentCached = { track, _ in delivered.append(track.id) }
        pipeline.sync(current: a, next: .init(track: b, entryID: UUID()))
        try await PlaybackTestSupport.eventually { fixture.mock.state.requests.count == 1 }
        let gate = AppModelRequestGate<String, Set<String>>()
        addTeardownBlock { await gate.close() }
        let clear = Task { try await pipeline.clearStorage { (try? await gate.receive("snapshot")) ?? [] } }
        let request = try await gate.request(at: 0)
        pipeline.sync(current: a, next: .init(track: c, entryID: UUID()))
        try await gate.complete(request, with: .success([a.id, c.id]))

        let result = try await clear.value
        try await PlaybackTestSupport.waitUntil { delivered.count == 3 }

        XCTAssertEqual(result?.retainedSongCount, 2)
        // The current copy reports before and after the clear; the cancelled next song never does.
        XCTAssertEqual(delivered, [a.id, a.id, c.id], "The cancelled next song cannot report completion or start an old download")
        XCTAssertEqual(fixture.mock.state.requests.count, 1)
        let oldNext = await fixture.cache.entry(for: b.id)
        XCTAssertNil(oldNext)
    }

    func testPlainAndCachelessFixtureResolversReportUnavailableAndLeaveFilesAlone() async throws {
        let fixture = try makeFixture()
        let local = try fixture.seed(a.id)
        let original = try Data(contentsOf: local)
        let player = PlayerController(resolver: PlaybackFileResolver(url: local))
        defer { player.pause() }
        let usage = try await player.audioCacheUsage()
        let cleared = try await player.clearTemporaryAudioCache()
        XCTAssertNil(usage)
        XCTAssertNil(cleared)
        XCTAssertEqual(try Data(contentsOf: local), original)

        let cacheless = YouTubeStreamResolver(extract: { id, _ in [AudioCacheTests.remote(id)] }, validate: { _ in })
        let cachelessUsage = try await cacheless.audioCacheUsage()
        let cachelessClear = try await cacheless.clearAudioCache { [] }
        XCTAssertNil(cachelessUsage)
        XCTAssertNil(cachelessClear)
        XCTAssertEqual(try Data(contentsOf: local), original)
    }

    private func settings(crossfade: TimeInterval = 0) -> PlaybackTransitionSettings {
        var settings = PlaybackTransitionSettings()
        settings.crossfadeSeconds = crossfade
        settings.gapless = true
        settings.automix = false
        settings.autoplay = false
        return settings
    }

    private func makeFixture(handler: CatalogMockState.Handler? = nil) throws -> CacheManagementFixture {
        let fixture = try CacheManagementFixture(handler: handler)
        addTeardownBlock { try await fixture.close() }
        return fixture
    }
}

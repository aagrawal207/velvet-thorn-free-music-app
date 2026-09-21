import XCTest
@testable import GanaBajana

@MainActor
final class PlayerCacheLimitStorageTests: XCTestCase {
    func testModelStartupRegistersTheSavedLimitBeforeItsFirstPrefetch() async throws {
        let fixture = try CacheManagementFixture()
        addTeardownBlock { try await fixture.close() }
        let library = LibraryStore(directory: fixture.root.appendingPathComponent("Library", isDirectory: true))
        var preferences = library.preferences
        preferences.audioCacheLimit = .mb500
        library.preferences = preferences
        let resolver = CacheLimitRecordingResolver()
        addTeardownBlock { await resolver.close() }
        let player = PlayerController(resolver: resolver)
        defer { player.pause() }
        let catalog = AppModelCatalogProvider()
        let charts = AppModelChartsProvider()
        addTeardownBlock {
            await catalog.close()
            await charts.charts.close()
        }
        let model = MusicAppModel(library: library, player: player, catalog: catalog, charts: charts,
                                  lyrics: AppModelLyricsProvider(),
                                  account: YouTubeAccountStore(secrets: MemorySecretStore(), registry: YouTubeSessionRegistry()),
                                  generatesMixes: false)
        model.player.prefetch([libraryTestTrack()])

        let startup = try await resolver.changes.request(at: 0)
        XCTAssertEqual(startup.input, .mb500)
        let before = await resolver.prefetchedCapacities
        XCTAssertTrue(before.isEmpty)
        try await resolver.changes.complete(startup, with: .success(cacheLimitUsage(.mb500)))
        try await PlaybackTestSupport.eventually { await resolver.prefetchedCapacities.count == 1 }

        let prefetched = await resolver.prefetchedCapacities
        XCTAssertEqual(prefetched, [524_288_000])
        XCTAssertEqual(model.library.preferences.audioCacheLimit, .mb500)
    }

    func testRapidChoicesCoalesceAndStartupPrefetchWaitsForTheLatestPolicy() async throws {
        let resolver = CacheLimitRecordingResolver()
        addTeardownBlock { await resolver.close() }
        let player = PlayerController(resolver: resolver)
        defer { player.pause() }
        let first = player.setAudioCacheLimit(.mb250)
        let firstRequest = try await resolver.changes.request(at: 0)
        let skipped = player.setAudioCacheLimit(.gb2)
        let latest = player.setAudioCacheLimit(.gb5)
        player.prefetch([libraryTestTrack()])
        XCTAssertTrue(player.isUpdatingAudioCacheLimit)
        let before = await resolver.prefetchedCapacities
        XCTAssertTrue(before.isEmpty)

        try await resolver.changes.complete(firstRequest, with: .success(cacheLimitUsage(.mb250)))
        let lastRequest = try await resolver.changes.request(at: 1)
        XCTAssertEqual(lastRequest.input, .gb5)
        for old in [first, skipped] {
            do { _ = try await old.value; XCTFail("Superseded choices must not publish success") }
            catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        }
        XCTAssertTrue(player.isUpdatingAudioCacheLimit)
        XCTAssertNil(player.audioCacheLimitUsage)
        let stillWaiting = await resolver.prefetchedCapacities
        XCTAssertTrue(stillWaiting.isEmpty)

        try await resolver.changes.complete(lastRequest, with: .success(cacheLimitUsage(.gb5)))
        let applied = try await latest.value
        try await PlaybackTestSupport.eventually { await resolver.prefetchedCapacities.count == 1 }

        XCTAssertEqual(applied?.capacityBytes, 5_368_709_120)
        XCTAssertEqual(player.audioCacheLimitUsage?.maximumSongs, 1_000)
        XCTAssertFalse(player.isUpdatingAudioCacheLimit)
        XCTAssertNil(player.audioCacheLimitError)
        let prefetched = await resolver.prefetchedCapacities
        XCTAssertEqual(prefetched, [5_368_709_120])
        let requests = await resolver.changes.requests
        XCTAssertEqual(requests.map(\.input), [.mb250, .gb5])
    }

    func testAnOlderFailureCannotReplaceNewerSuccessAndLatestFailuresAreVisible() async throws {
        let resolver = CacheLimitRecordingResolver()
        addTeardownBlock { await resolver.close() }
        let player = PlayerController(resolver: resolver)
        defer { player.pause() }
        let old = player.setAudioCacheLimit(.mb250)
        let oldRequest = try await resolver.changes.request(at: 0)
        let latest = player.setAudioCacheLimit(.gb2)
        try await resolver.changes.complete(oldRequest, with: .failure(CocoaError(.fileWriteNoPermission)))
        _ = await old.result
        let nextRequest = try await resolver.changes.request(at: 1)
        XCTAssertNil(player.audioCacheLimitError)
        try await resolver.changes.complete(nextRequest, with: .success(cacheLimitUsage(.gb2)))
        _ = try await latest.value
        XCTAssertNil(player.audioCacheLimitError)
        XCTAssertEqual(player.audioCacheLimitUsage?.capacityBytes, 2_147_483_648)

        let failure = player.setAudioCacheLimit(.mb500)
        let failedRequest = try await resolver.changes.request(at: 2)
        try await resolver.changes.complete(failedRequest, with: .failure(CocoaError(.fileWriteNoPermission)))
        do { _ = try await failure.value; XCTFail("The latest failure must be returned to the caller") }
        catch { XCTAssertTrue(error is CocoaError) }
        XCTAssertNotNil(player.audioCacheLimitError)
        XCTAssertNil(player.audioCacheLimitUsage)
        XCTAssertFalse(player.isUpdatingAudioCacheLimit)
        let actual = try await player.audioCacheUsage()
        XCTAssertEqual(actual?.capacityBytes, 2_147_483_648)
    }

    func testAProviderCannotReportSuccessWithTheWrongPolicy() async throws {
        let resolver = CacheLimitRecordingResolver()
        addTeardownBlock { await resolver.close() }
        let player = PlayerController(resolver: resolver)
        defer { player.pause() }
        let change = player.setAudioCacheLimit(.gb5)
        let request = try await resolver.changes.request(at: 0)
        try await resolver.changes.complete(request, with: .success(cacheLimitUsage(.gb1)))

        do { _ = try await change.value; XCTFail("A mismatched applied policy is not success") }
        catch { XCTAssertTrue(error is AudioCache.ManagementError) }
        XCTAssertNotNil(player.audioCacheLimitError)
        XCTAssertNil(player.audioCacheLimitUsage)
    }

    func testPlainAndLegacyCacheFixturesCanOptOutWithoutOpeningProductionStorage() async throws {
        let fixture = try CacheManagementFixture()
        addTeardownBlock { try await fixture.close() }
        let local = try fixture.seed("fixture")
        let bytes = try Data(contentsOf: local)
        let player = PlayerController(resolver: PlaybackFileResolver(url: local))
        defer { player.pause() }

        let plainResult = try await player.setAudioCacheLimit(.gb5).value
        XCTAssertNil(plainResult)
        XCTAssertFalse(player.isUpdatingAudioCacheLimit)
        XCTAssertNil(player.audioCacheLimitError)
        XCTAssertEqual(try Data(contentsOf: local), bytes)

        let legacy = LegacyCacheLimitResolver()
        let legacyPlayer = PlayerController(resolver: legacy)
        defer { legacyPlayer.pause() }
        let legacyResult = try await legacyPlayer.setAudioCacheLimit(.gb5).value
        XCTAssertNil(legacyResult)
        let legacyUsage = try await legacyPlayer.audioCacheUsage()
        XCTAssertNil(legacyUsage)
        XCTAssertEqual(try Data(contentsOf: local), bytes)
    }

    func testLimitChangesWaitForAnActiveClearInsteadOfFailingOrRacingIt() async throws {
        let resolver = CacheLimitRecordingResolver()
        addTeardownBlock { await resolver.close() }
        let player = PlayerController(resolver: resolver)
        defer { player.pause() }
        let clear = Task { try await player.clearTemporaryAudioCache() }
        let clearing = try await resolver.clears.request(at: 0)
        let change = player.setAudioCacheLimit(.gb2)
        XCTAssertTrue(player.isUpdatingAudioCacheLimit)
        let before = await resolver.changes.requests
        XCTAssertTrue(before.isEmpty)

        try await resolver.clears.complete(clearing, with: .success(nil))
        _ = try await clear.value
        let applying = try await resolver.changes.request(at: 0)
        XCTAssertEqual(applying.input, .gb2)
        try await resolver.changes.complete(applying, with: .success(cacheLimitUsage(.gb2)))

        let applied = try await change.value
        XCTAssertEqual(applied?.capacityBytes, 2_147_483_648)
        XCTAssertNil(player.audioCacheLimitError)
        XCTAssertFalse(player.isUpdatingAudioCacheLimit)
    }

    func testLoweringTheLimitKeepsCurrentAndReadyStandbyPlaybackContinuous() async throws {
        let fixture = try makePlayingFixture()
        let first = Track(id: "fsiPzT50ZiM", title: "Current")
        let next = Track(id: "NJAv_7lHUIU", title: "Next")
        let firstURL = try fixture.seed(first.id, seconds: 7)
        let nextURL = try fixture.seed(next.id, seconds: 7)
        let player = PlayerController(resolver: fixture.resolver())
        defer { player.pause() }
        player.apply(playbackSettings(crossfade: 0))
        player.play([first, next])
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.isStandbyReady }
        let position = player.position

        let usage = try await player.setAudioCacheLimit(.mb250).value

        XCTAssertEqual(usage?.capacityBytes, 262_144_000)
        XCTAssertEqual(usage?.maximumSongs, 50)
        XCTAssertEqual(usage?.songCount, 50)
        XCTAssertEqual(player.currentStreamURL, firstURL)
        XCTAssertEqual(player.standbyStreamURL, nextURL)
        XCTAssertTrue(player.isStandbyReady)
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.position > position + 0.25 }
        XCTAssertNil(player.errorMessage)
    }

    func testLoweringDuringCrossfadeRetainsTheOutgoingFileAfterPinsMoveToTheNewPair() async throws {
        let fixture = try makePlayingFixture()
        let a = Track(id: "fsiPzT50ZiM", title: "Outgoing")
        let b = Track(id: "NJAv_7lHUIU", title: "Incoming")
        let c = Track(id: "J7p4bzqLvCw", title: "Upcoming")
        let outgoingURL = try fixture.seed(a.id, seconds: 8)
        let currentURL = try fixture.seed(b.id, seconds: 8)
        let upcomingURL = try fixture.seed(c.id, seconds: 8)
        let player = PlayerController(resolver: fixture.resolver())
        defer { player.pause() }
        player.apply(playbackSettings(crossfade: 3))
        player.play([a, b, c])
        try await PlaybackTestSupport.waitUntil(timeout: 10) { player.currentTrack == b && player.crossfadeState != nil }
        await fixture.cache.pin(only: [b.id, c.id])
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: outgoingURL.path)

        let usage = try await player.setAudioCacheLimit(.mb250).value

        XCTAssertEqual(usage?.retainedSongCount, 3)
        XCTAssertEqual(usage?.songCount, 50)
        XCTAssertEqual(player.currentStreamURL, currentURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outgoingURL.path), "The oldest file is still playing on the outgoing deck")
        XCTAssertTrue(FileManager.default.fileExists(atPath: upcomingURL.path))
        try await PlaybackTestSupport.waitUntil { player.crossfadeState == nil && player.isPlaying && player.isStandbyReady }
        XCTAssertEqual(player.standbyStreamURL, upcomingURL)
        XCTAssertNil(player.errorMessage)
    }

    private func makePlayingFixture() throws -> CacheManagementFixture {
        let fixture = try CacheManagementFixture(capacityBytes: AudioCacheLimit.gb1.bytes, maximumFiles: 200)
        addTeardownBlock { try await fixture.close() }
        let payload = PlaybackTestSupport.audioData(seconds: 1)
        try FileManager.default.createDirectory(at: fixture.cache.directory, withIntermediateDirectories: true)
        for index in 0..<52 {
            let id = "unused-\(index)"
            let url = fixture.cache.directory.appendingPathComponent("\(id).wav")
            try payload.write(to: url)
            try fixture.sidecar(id, bytes: Int64(payload.count))
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(index + 100))],
                                                 ofItemAtPath: url.path)
        }
        return fixture
    }

    private func playbackSettings(crossfade: TimeInterval) -> PlaybackTransitionSettings {
        var settings = PlaybackTransitionSettings()
        settings.crossfadeSeconds = crossfade
        settings.gapless = true
        settings.automix = false
        settings.autoplay = false
        return settings
    }
}

private func cacheLimitUsage(_ limit: AudioCacheLimit) -> AudioCache.Usage {
    AudioCache.Usage(bytes: 0, songCount: 0, retainedBytes: 0, retainedSongCount: 0,
                     capacityBytes: limit.bytes, maximumSongs: limit.maximumSongs, pendingDownloads: 0)
}

private actor CacheLimitRecordingResolver: StreamCacheManaging {
    let changes = AppModelRequestGate<AudioCacheLimit, AudioCache.Usage?>()
    let clears = AppModelRequestGate<String, AudioCache.Usage?>()
    private var applied: AudioCache.Usage?
    private(set) var prefetchedCapacities: [Int64?] = []

    func setAudioCacheLimit(_ limit: AudioCacheLimit,
                           retaining: @escaping @Sendable () async -> Set<String>) async throws -> AudioCache.Usage? {
        _ = await retaining()
        let result = try await changes.receive(limit)
        applied = result
        return result
    }

    func prefetch(_ tracks: [Track]) { prefetchedCapacities.append(applied?.capacityBytes) }
    func audioCacheUsage() -> AudioCache.Usage? { applied }
    func clearAudioCache(retaining: @escaping @Sendable () async -> Set<String>) async throws -> AudioCache.Usage? {
        try await clears.receive("clear")
    }
    func close() async {
        await changes.close()
        await clears.close()
    }
    func retainCached(_ trackIDs: Set<String>) { }
    func discardCached(_ track: Track) { }
    nonisolated func isCachedStream(_ stream: ResolvedStream) -> Bool { false }
    func resolve(track: Track, forceRefresh: Bool) throws -> ResolvedStream { throw PlaybackStreamError.noAudio }
    func download(_ track: Track) throws -> ResolvedStream { throw PlaybackStreamError.noAudio }
}

private actor LegacyCacheLimitResolver: StreamCacheManaging {
    func audioCacheUsage() -> AudioCache.Usage? { nil }
    func clearAudioCache(retaining: @escaping @Sendable () async -> Set<String>) -> AudioCache.Usage? { nil }
    func retainCached(_ trackIDs: Set<String>) { }
    func discardCached(_ track: Track) { }
    nonisolated func isCachedStream(_ stream: ResolvedStream) -> Bool { false }
    func resolve(track: Track, forceRefresh: Bool) throws -> ResolvedStream { throw PlaybackStreamError.noAudio }
    func download(_ track: Track) throws -> ResolvedStream { throw PlaybackStreamError.noAudio }
}

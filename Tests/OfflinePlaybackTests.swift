import AudioToolbox
import AVFoundation
import XCTest
@testable import GanaBajana

@MainActor
final class OfflinePlaybackTests: XCTestCase {
    private let track = Track(id: "fsiPzT50ZiM", title: "Offline audio", artists: ["Fixture artist"], duration: 8)
    private let other = Track(id: "NJAv_7lHUIU", title: "Uncached audio", duration: 8)
    private let later = Track(id: "J7p4bzqLvCw", title: "Later cached audio", duration: 8)

    func testInjectedConnectivityHasAThreadSafeSnapshotAndNoAutomaticSystemMonitoring() async {
        let connectivity = ConnectivityMonitor(initialStatus: .offline, monitorsSystem: false)
        var changes: [ConnectivityMonitor.Status] = []
        connectivity.onChange = { changes.append($0) }
        connectivity.start()
        let initial = await Task.detached { connectivity.isOffline }.value
        XCTAssertTrue(initial)
        XCTAssertEqual(connectivity.status, .offline)
        connectivity.setStatus(.offline)
        XCTAssertTrue(changes.isEmpty)
        connectivity.setStatus(.online)
        connectivity.setStatus(.online)
        let connected = await Task.detached { connectivity.isOffline }.value
        XCTAssertFalse(connected)
        connectivity.setStatus(.unknown)
        connectivity.setStatus(.offline)
        connectivity.stop()
        XCTAssertEqual(changes, [.online, .unknown, .offline])
        XCTAssertTrue(connectivity.isOffline)
        let unstarted = ConnectivityMonitor()
        XCTAssertEqual(unstarted.status, .unknown)
        XCTAssertFalse(unstarted.isOffline)
        unstarted.stop()
    }

    func testKnownOfflineMissFailsPromptlyWithoutExtractionValidationDownloadOrPrefetch() async throws {
        let fixture = try makeFixture()
        let connectivity = ConnectivityMonitor(initialStatus: .offline, monitorsSystem: false)
        let calls = CatalogTestRecorder<String>()
        let resolver = offlineResolver(cache: fixture.cache, connectivity: connectivity, calls: calls)
        let started = ContinuousClock.now
        for refresh in [false, true] {
            await expectOffline { try await resolver.resolve(track: self.track, forceRefresh: refresh) }
        }
        await expectOffline { try await resolver.refreshQuality(track: self.track) }
        await expectOffline { try await resolver.download(self.track) }
        await resolver.prefetch([track, other])
        XCTAssertLessThan(started.duration(to: .now), .seconds(1))
        XCTAssertTrue(calls.values.isEmpty)
        XCTAssertTrue(fixture.mock.state.requests.isEmpty)

        let player = PlayerController(resolver: resolver)
        defer { player.pause() }
        player.setNetworkOffline(true)
        player.play([track])
        try await PlaybackTestSupport.waitUntil(timeout: 2) { player.errorMessage != nil }
        XCTAssertTrue(player.errorMessage?.contains("isn’t cached") == true)
        XCTAssertFalse(player.isLoading)
        XCTAssertFalse(player.isPlaying)
        connectivity.setStatus(.online)
        player.setNetworkOffline(false)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(player.isLoading)
        XCTAssertTrue(calls.values.isEmpty, "Reconnection must not replay a failed play request")
    }

    func testAnUnexpiredInMemoryStreamURLIsNotAnOfflineCacheHit() async throws {
        let connectivity = ConnectivityMonitor(initialStatus: .online, monitorsSystem: false)
        let calls = CatalogTestRecorder<String>()
        let resolver = YouTubeStreamResolver(extract: { id, _ in
            calls.record("extract")
            return [AudioCacheTests.remote(id)]
        }, validate: { _ in calls.record("validate") }, isOffline: { connectivity.isOffline })
        let remote = try await resolver.resolve(track: track, forceRefresh: false)
        XCTAssertFalse(remote.url.isFileURL)
        XCTAssertNotNil(remote.expiresAt)
        let before = calls.values
        connectivity.setStatus(.offline)
        await expectOffline { try await resolver.resolve(track: self.track, forceRefresh: false) }
        XCTAssertEqual(calls.values, before)
    }

    func testColdAACCacheUsesNativePlaybackSeekAndRestoreWithEveryNetworkPathForbidden() async throws {
        let data = try makeAAC()
        let fixture = try makeFixture(handler: { _ in
            CatalogStub(headers: ["Content-Type": "audio/mp4", "Content-Length": "\(data.count)"], data: data)
        })
        let source = AudioCacheTests.remote(track.id)
        let quality = SourceAudioQuality(codec: .aac, bitRate: 128_000, sampleRate: 44_100, channels: 1)
        let saved = try await fixture.cache.store(trackID: track.id, from: source,
            stream: ResolvedStream(url: source, duration: 8, loudnessDb: 6, quality: quality), track: track)
        let asset = AVURLAsset(url: saved.url)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let descriptions = try await XCTUnwrap(audio.first).load(.formatDescriptions)
        let format = try XCTUnwrap(descriptions.first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0) })
        XCTAssertEqual(format.pointee.mFormatID, kAudioFormatMPEG4AAC)
        let calls = CatalogTestRecorder<String>()
        let forbidden = CatalogMockSession { _ in calls.record("media"); throw URLError(.notConnectedToInternet) }
        defer { forbidden.close() }
        let reopened = AudioCache(directory: fixture.cache.directory, session: forbidden.session)
        let connectivity = ConnectivityMonitor(initialStatus: .offline, monitorsSystem: false)
        let resolver = offlineResolver(cache: reopened, connectivity: connectivity, calls: calls)
        var catalogTrack = track
        catalogTrack.duration = 1
        let local = try await resolver.resolve(track: catalogTrack, forceRefresh: true)
        XCTAssertEqual(local.url, saved.url)
        XCTAssertNil(local.expiresAt)
        XCTAssertEqual(local.duration, 8)
        let player = PlayerController(resolver: resolver)
        defer { player.pause() }
        player.setNetworkOffline(true)
        player.restore(PlaybackSnapshot(queue: [catalogTrack], position: 2))
        XCTAssertFalse(player.isPlaying)
        XCTAssertNil(player.currentStreamURL)
        player.togglePlayback()
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.position > 2.3 }
        XCTAssertEqual(player.currentStreamURL, saved.url)
        XCTAssertTrue(player.isCurrentTrackCached)
        XCTAssertEqual(player.duration, 8, accuracy: 0.001)
        XCTAssertEqual(player.sourceAudioQuality, quality)
        XCTAssertEqual(player.normalizationGain, 0.501_187, accuracy: 0.000_001)
        player.seek(to: 5)
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.position > 5.3 }
        player.pause()
        let pausedAt = player.position
        connectivity.setStatus(.online)
        player.setNetworkOffline(false)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.position, pausedAt, accuracy: 0.05)
        XCTAssertTrue(calls.values.isEmpty)
        XCTAssertTrue(forbidden.state.requests.isEmpty)
        XCTAssertEqual(fixture.mock.state.requests.count, 1)
        let snapshot = try await player.cachedSongsSnapshot()
        XCTAssertEqual(snapshot?.songs.first?.track, track)
    }

    func testColdPreparedOpusCachePlaysAndSeeksWithoutAnyNewProviderLookup() async throws {
        guard OpusNativeAudio.isSupported else { throw XCTSkip("Native Opus requires iOS 26.5+") }
        let bundle = Bundle(for: Self.self)
        let input = try XCTUnwrap(bundle.url(forResource: "opus-160", withExtension: "webm")
            ?? bundle.url(forResource: "opus-160", withExtension: "webm", subdirectory: "Fixtures"))
        let data = try Data(contentsOf: input)
        let fixture = try makeFixture(handler: { _ in
            CatalogStub(headers: ["Content-Type": "audio/webm", "Content-Length": "\(data.count)"], data: data)
        })
        let permit = try await fixture.cache.writePermit()
        let prepared = try await fixture.cache.storeOpus(trackID: track.id, stream: OpusTestSupport.source(),
                                                         permit: permit, foreground: true, track: track)
        XCTAssertEqual(prepared.quality?.codec, .opus)
        let calls = CatalogTestRecorder<String>()
        let forbidden = CatalogMockSession { _ in calls.record("media"); throw URLError(.notConnectedToInternet) }
        defer { forbidden.close() }
        let reopened = AudioCache(directory: fixture.cache.directory, session: forbidden.session)
        let connectivity = ConnectivityMonitor(initialStatus: .offline, monitorsSystem: false)
        let resolver = offlineResolver(cache: reopened, connectivity: connectivity, calls: calls, opusEnabled: true)
        let player = PlayerController(resolver: resolver)
        defer { player.pause() }
        player.setNetworkOffline(true)
        player.play([track])
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.position > 0.5 }
        XCTAssertEqual(player.currentStreamURL, prepared.url)
        XCTAssertEqual(player.sourceAudioQuality?.codec, .opus)
        XCTAssertEqual(player.duration, 8, accuracy: 0.1)
        player.seek(to: 5)
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.position > 5.3 }
        XCTAssertNil(player.errorMessage)
        XCTAssertTrue(calls.values.isEmpty)
        XCTAssertTrue(forbidden.state.requests.isEmpty)
        XCTAssertEqual(fixture.mock.state.requests.count, 1)
    }

    func testMissingSidecarDurationUsesTheNativeFileInsteadOfTheWrongCatalogDuration() async throws {
        let fixture = try makeFixture()
        let media = try fixture.seed(track.id, seconds: 6)
        try removeSidecarDuration(track.id, in: fixture.cache.directory)
        let metadataURL = fixture.cache.directory.appendingPathComponent("\(track.id).json")
        let metadata = try Data(contentsOf: metadataURL)
        let calls = CatalogTestRecorder<String>()
        let connectivity = ConnectivityMonitor(initialStatus: .offline, monitorsSystem: false)
        let resolver = offlineResolver(cache: fixture.cache, connectivity: connectivity, calls: calls)
        var wrong = track
        wrong.duration = 1
        let local = try await resolver.resolve(track: wrong, forceRefresh: true)
        XCTAssertEqual(local.duration, 6)
        let player = PlayerController(resolver: resolver)
        defer { player.pause() }
        player.setNetworkOffline(true)
        player.play([wrong])
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.position > 1.3 }
        XCTAssertEqual(player.currentStreamURL, media)
        XCTAssertEqual(player.duration, 6, accuracy: 0.001)
        XCTAssertEqual(try Data(contentsOf: metadataURL), metadata)
        XCTAssertTrue(calls.values.isEmpty)
    }

    func testNativeDurationReaderKeepsItsLeaseAfterTheCallerCancelsUntilTheReaderUnwinds() async throws {
        let gate = AppModelRequestGate<URL, TimeInterval>()
        let fixture = try CacheManagementFixture(localDurationLoader: { try await gate.receive($0) })
        addTeardownBlock { try await fixture.close() }
        addTeardownBlock { await gate.close() }
        let media = try fixture.seed(track.id, seconds: 6)
        try removeSidecarDuration(track.id, in: fixture.cache.directory)
        let calls = CatalogTestRecorder<String>()
        let connectivity = ConnectivityMonitor(initialStatus: .offline, monitorsSystem: false)
        let resolver = offlineResolver(cache: fixture.cache, connectivity: connectivity, calls: calls)
        let track = track
        let resolution = Task { try await resolver.resolve(track: track, forceRefresh: false) }
        defer { resolution.cancel() }
        let request = try await gate.request(at: 0)
        let pending = try await fixture.cache.snapshot()
        XCTAssertTrue(try XCTUnwrap(pending.songs.first).isInUse)
        resolution.cancel()
        do { _ = try await resolution.value; XCTFail("The cancelled waiter must return promptly") }
        catch { XCTAssertTrue(error is CancellationError) }
        try await PlaybackTestSupport.eventually { await gate.cancellations.contains(request.id) }
        let removal = try await fixture.cache.removeSong(id: track.id)
        XCTAssertEqual(removal.outcome, .inUse)
        let clear = try await fixture.cache.clearUnused()
        XCTAssertEqual(clear.retainedSongCount, 1)
        let resize = try await fixture.cache.updatePolicy(capacityBytes: 1, maximumFiles: 1)
        XCTAssertEqual(resize.retainedSongCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: media.path))
        let readers = await fixture.cache.activeReaderCount
        XCTAssertEqual(readers, 1)
        try await gate.complete(request, with: .success(6))
        try await PlaybackTestSupport.eventually { await fixture.cache.activeReaderCount == 0 }
        let after = try await fixture.cache.removeSong(id: track.id)
        XCTAssertEqual(after.outcome, .removed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: media.path))
        XCTAssertTrue(calls.values.isEmpty)
    }

    func testCorruptPreferredVariantFallsBackToAnotherLocalEncodingWhileOffline() async throws {
        for missingDuration in [false, true] {
            let fixture = try makeFixture()
            let original = try fixture.seed(track.id, seconds: 6)
            let bad = try seedBadOpus(in: fixture.cache.directory, duration: missingDuration ? nil : 6)
            let calls = CatalogTestRecorder<String>()
            let connectivity = ConnectivityMonitor(initialStatus: .offline, monitorsSystem: false)
            let resolver = offlineResolver(cache: fixture.cache, connectivity: connectivity, calls: calls, opusEnabled: true)
            let player = PlayerController(resolver: resolver)
            defer { player.pause() }
            player.setNetworkOffline(true)
            player.play([track])
            try await PlaybackTestSupport.waitUntil(timeout: 12) {
                player.isPlaying && player.currentStreamURL == original && player.position > 0.3
            }
            XCTAssertNil(player.errorMessage)
            XCTAssertTrue(calls.values.isEmpty)
            let snapshot = try await resolver.audioCacheSnapshot()
            XCTAssertEqual(snapshot?.songs.first?.preferredAudio?.url, original)
            XCTAssertTrue(snapshot?.songs.first?.isPlayable == true)
            XCTAssertTrue(FileManager.default.fileExists(atPath: bad.path), "A rejected variant stays protected with the active logical song")
        }
    }

    func testCancellingOneNativeReaderDoesNotReleaseAnotherReadersProtection() async throws {
        let gate = AppModelRequestGate<URL, TimeInterval>()
        let fixture = try CacheManagementFixture(localDurationLoader: { try await gate.receive($0) })
        addTeardownBlock { try await fixture.close() }
        addTeardownBlock { await gate.close() }
        try fixture.seed(track.id, seconds: 6)
        try removeSidecarDuration(track.id, in: fixture.cache.directory)
        let calls = CatalogTestRecorder<String>()
        let connectivity = ConnectivityMonitor(initialStatus: .offline, monitorsSystem: false)
        let resolver = offlineResolver(cache: fixture.cache, connectivity: connectivity, calls: calls)
        let track = track
        let first = Task { try await resolver.resolve(track: track, forceRefresh: false) }
        defer { first.cancel() }
        let firstRead = try await gate.request(at: 0)
        let second = Task { try await resolver.resolve(track: track, forceRefresh: false) }
        defer { second.cancel() }
        let secondRead = try await gate.request(at: 1)
        first.cancel()
        _ = await first.result
        try await gate.complete(firstRead, with: .success(6))
        try await PlaybackTestSupport.eventually { await fixture.cache.activeReaderCount == 1 }
        let retained = try await fixture.cache.removeSong(id: track.id)
        XCTAssertEqual(retained.outcome, .inUse)
        try await gate.complete(secondRead, with: .success(6))
        let completed = try await second.value
        XCTAssertEqual(completed.duration, 6)
        let removed = try await fixture.cache.removeSong(id: track.id)
        XCTAssertEqual(removed.outcome, .removed)
        XCTAssertTrue(calls.values.isEmpty)
    }

    func testUnsupportedOpusOnlyCacheIsAVisibleButUnplayableOfflineSong() async throws {
        let fixture = try makeFixture()
        try FileManager.default.createDirectory(at: fixture.cache.directory, withIntermediateDirectories: true)
        _ = try seedBadOpus(in: fixture.cache.directory, duration: 8)
        let calls = CatalogTestRecorder<String>()
        let connectivity = ConnectivityMonitor(initialStatus: .offline, monitorsSystem: false)
        let resolver = offlineResolver(cache: fixture.cache, connectivity: connectivity, calls: calls, opusEnabled: false)
        let snapshot = try await resolver.audioCacheSnapshot()
        XCTAssertEqual(snapshot?.songs.count, 1)
        XCTAssertFalse(try XCTUnwrap(snapshot?.songs.first).isPlayable)
        await expectOffline { try await resolver.resolve(track: self.track, forceRefresh: true) }
        XCTAssertTrue(calls.values.isEmpty)
    }

    func testOfflineQualityReloadAndPrefetchUseNoNetworkWhenAFileIsAlreadyCached() async throws {
        let fixture = try makeFixture()
        let media = try fixture.seed(track.id)
        let calls = CatalogTestRecorder<String>()
        let connectivity = ConnectivityMonitor(initialStatus: .offline, monitorsSystem: false)
        let resolver = offlineResolver(cache: fixture.cache, connectivity: connectivity, calls: calls)
        let fresh = try await resolver.refreshQuality(track: track)
        let downloaded = try await resolver.download(track)
        await resolver.prefetch([track, other])
        XCTAssertEqual(fresh.url, media)
        XCTAssertEqual(downloaded.url, media)
        XCTAssertTrue(calls.values.isEmpty)
        XCTAssertTrue(fixture.mock.state.requests.isEmpty)
    }

    func testCachedQueuePreparesAndAdvancesOfflineWithoutRequestingAutoplay() async throws {
        let fixture = try makeFixture()
        try fixture.seed(track.id, seconds: 4)
        let next = try fixture.seed(other.id, seconds: 4)
        let calls = CatalogTestRecorder<String>()
        let connectivity = ConnectivityMonitor(initialStatus: .offline, monitorsSystem: false)
        let resolver = offlineResolver(cache: fixture.cache, connectivity: connectivity, calls: calls)
        let player = PlayerController(resolver: resolver)
        defer { player.pause() }
        var continuations = 0
        player.onQueueExhausted = { _ in continuations += 1; return [] }
        player.onQueueEnded = { _ in continuations += 1; return [] }
        player.setNetworkOffline(true)
        player.play([track, other])
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.isStandbyReady && player.isNextTrackCached }
        try await PlaybackTestSupport.waitUntil(timeout: 8) {
            player.currentTrack == self.other && player.isPlaying && player.position > 0.3
        }
        XCTAssertEqual(player.currentStreamURL, next)
        XCTAssertEqual(continuations, 0)
        XCTAssertTrue(calls.values.isEmpty)
        XCTAssertTrue(fixture.mock.state.requests.isEmpty)
    }

    func testLosingConnectivityHandsOffToTheLocalCopyAtTheCurrentPositionWithoutAnotherStart() async throws {
        let fixture = try makeFixture()
        let remote = try PlaybackTestSupport.audioFile(seconds: 12)
        addTeardownBlock { try FileManager.default.removeItem(at: remote.deletingLastPathComponent()) }
        let connectivity = ConnectivityMonitor(initialStatus: .online, monitorsSystem: false)
        let calls = CatalogTestRecorder<String>()
        let resolver = remoteFixtureResolver(url: remote, cache: fixture.cache, connectivity: connectivity, calls: calls)
        var current = track
        current.duration = 12
        let player = PlayerController(resolver: resolver)
        defer { player.pause() }
        var starts = 0
        player.onTrackStarted = { _ in starts += 1 }
        var settings = PlaybackTransitionSettings()
        settings.autoplay = false
        player.apply(settings)
        player.play([current])
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.position > 1 }
        XCTAssertEqual(player.currentStreamURL, remote)
        let local = try fixture.seed(track.id, seconds: 12)
        let position = player.position
        let before = calls.values
        connectivity.setStatus(.offline)
        player.setNetworkOffline(true)
        try await PlaybackTestSupport.waitUntil {
            player.isPlaying && player.currentStreamURL == local && player.position > position + 0.2
        }
        XCTAssertEqual(starts, 1)
        XCTAssertTrue(player.isCurrentTrackCached)
        XCTAssertEqual(calls.values, before)
        XCTAssertNil(player.errorMessage)
    }

    func testPausedRemoteAudioStaysPausedAcrossConnectivityChangesAndExplicitOfflineResumeUsesCache() async throws {
        let fixture = try makeFixture()
        let remote = try PlaybackTestSupport.audioFile(seconds: 12)
        addTeardownBlock { try FileManager.default.removeItem(at: remote.deletingLastPathComponent()) }
        let connectivity = ConnectivityMonitor(initialStatus: .online, monitorsSystem: false)
        let calls = CatalogTestRecorder<String>()
        let resolver = remoteFixtureResolver(url: remote, cache: fixture.cache, connectivity: connectivity, calls: calls)
        var current = track
        current.duration = 12
        let player = PlayerController(resolver: resolver)
        defer { player.pause() }
        player.play([current])
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.position > 0.5 }
        player.pause()
        let position = player.position
        let local = try fixture.seed(track.id, seconds: 12)
        let before = calls.values
        connectivity.setStatus(.offline)
        player.setNetworkOffline(true)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.currentStreamURL, remote)
        XCTAssertEqual(player.position, position, accuracy: 0.05)
        player.togglePlayback()
        try await PlaybackTestSupport.waitUntil {
            player.isPlaying && player.currentStreamURL == local && player.position > position + 0.2
        }
        player.pause()
        connectivity.setStatus(.online)
        player.setNetworkOffline(false)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(calls.values, before)
    }

    func testOfflineTransitionRetiresPendingNetworkResolutionAndRejectsItsLateResult() async throws {
        let fixture = try makeFixture()
        let gate = AppModelRequestGate<String, FastPathResult>()
        addTeardownBlock { await gate.close() }
        let connectivity = ConnectivityMonitor(initialStatus: .online, monitorsSystem: false)
        let calls = CatalogTestRecorder<String>()
        let resolver = YouTubeStreamResolver(extract: { _, _ in calls.record("extract"); return [] },
            validate: { _ in calls.record("validate") }, fastExtract: { try await gate.receive($0) },
            audioCache: fixture.cache, isOffline: { connectivity.isOffline })
        let player = PlayerController(resolver: resolver)
        defer { player.pause() }
        player.play([track])
        let request = try await gate.request(at: 0)
        connectivity.setStatus(.offline)
        player.setNetworkOffline(true)
        try await PlaybackTestSupport.waitUntil(timeout: 2) { player.errorMessage?.contains("isn’t cached") == true }
        try await gate.complete(request, with: .success(FastPathResult(urls: [AudioCacheTests.remote(track.id)])))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(player.isLoading)
        XCTAssertNil(player.currentStreamURL)
        XCTAssertTrue(calls.values.isEmpty)
    }

    func testOfflineTransitionDrainsSpeculativeDownloadsAndRemovalWaitsForThatBarrier() async throws {
        let payload = PlaybackTestSupport.audioData(seconds: 1)
        let fixture = try makeFixture(handler: { _ in
            CatalogStub(headers: ["Content-Type": "audio/wav", "Content-Length": "\(payload.count)"], data: payload, delay: 10)
        })
        let current = try fixture.seed(track.id, seconds: 8)
        let connectivity = ConnectivityMonitor(initialStatus: .online, monitorsSystem: false)
        let resolver = YouTubeStreamResolver(extract: { _, _ in [] }, validate: { _ in },
            fastExtract: { FastPathResult(urls: [AudioCacheTests.remote($0)]) },
            audioCache: fixture.cache, isOffline: { connectivity.isOffline })
        let player = PlayerController(resolver: resolver)
        defer { player.pause() }
        var settings = PlaybackTransitionSettings()
        settings.autoplay = false
        player.apply(settings)
        player.play([track])
        try await PlaybackTestSupport.waitUntil { player.isPlaying }
        player.prefetch([other])
        try await PlaybackTestSupport.eventually { fixture.mock.state.requests.count == 1 }
        let position = player.position
        connectivity.setStatus(.offline)
        player.setNetworkOffline(true)
        let removed = try await player.removeCachedSong(id: other.id)
        XCTAssertEqual(removed?.outcome, .notFound)
        XCTAssertEqual(removed?.usage.pendingDownloads, 0)
        try await PlaybackTestSupport.eventually { fixture.mock.state.cancellations == 1 }
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.position > position + 0.2 }
        XCTAssertEqual(player.currentStreamURL, current)
        XCTAssertNil(player.errorMessage)
        connectivity.setStatus(.online)
        player.setNetworkOffline(false)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(fixture.mock.state.requests.count, 1)
    }

    func testOfflineQueueTraversalPreservesOccurrencesAndBoundsRepeatWrapping() throws {
        var queue = PlaybackQueue()
        queue.replace([track, other, later, track], startingAt: 0)
        let ids = queue.entries.map(\.id)
        let first = try XCTUnwrap(OfflineQueueNavigation.advancing(queue, repeatMode: .off, automatic: true,
                                                                  cachedTrackIDs: [track.id, later.id]))
        XCTAssertEqual(first.index, 2)
        XCTAssertEqual(first.selectedID, ids[2])
        XCTAssertEqual(first.entries.map(\.id), ids)
        XCTAssertEqual(first.original.map(\.id), ids)
        let duplicate = try XCTUnwrap(OfflineQueueNavigation.advancing(first, repeatMode: .off, automatic: true,
                                                                      cachedTrackIDs: [track.id, later.id]))
        XCTAssertEqual(duplicate.selectedID, ids[3])
        XCTAssertNotEqual(duplicate.selectedID, ids[0])
        let repeated = try XCTUnwrap(OfflineQueueNavigation.advancing(queue, repeatMode: .one, automatic: true,
                                                                     cachedTrackIDs: [track.id, later.id]))
        XCTAssertEqual(repeated.selectedID, ids[0])
        XCTAssertNil(OfflineQueueNavigation.advancing(queue, repeatMode: .one, automatic: true, cachedTrackIDs: [later.id]))
        XCTAssertEqual(OfflineQueueNavigation.advancing(queue, repeatMode: .one, automatic: false,
                                                       cachedTrackIDs: [later.id])?.selectedID, ids[2])
        XCTAssertEqual(OfflineQueueNavigation.advancing(duplicate, repeatMode: .all, automatic: true,
                                                       cachedTrackIDs: [later.id])?.selectedID, ids[2])
        XCTAssertNil(OfflineQueueNavigation.advancing(duplicate, repeatMode: .off, automatic: true, cachedTrackIDs: [track.id]))
        XCTAssertNil(OfflineQueueNavigation.advancing(queue, repeatMode: .all, automatic: true, cachedTrackIDs: []))
        XCTAssertEqual(queue.selectedID, ids[0])
    }

    func testNativeOfflineQueueSkipsMissingMiddleSongWithoutRewritingTheQueue() async throws {
        for gapless in [false, true] {
            let fixture = try makeFixture()
            try fixture.seed(track.id, seconds: 2)
            let last = try fixture.seed(later.id, seconds: 2)
            let calls = CatalogTestRecorder<String>()
            let connectivity = ConnectivityMonitor(initialStatus: .offline, monitorsSystem: false)
            let player = PlayerController(resolver: offlineResolver(cache: fixture.cache, connectivity: connectivity, calls: calls))
            defer { player.pause() }
            var settings = PlaybackTransitionSettings()
            settings.gapless = gapless
            player.apply(settings)
            var starts: [String] = []
            var snapshot = PlaybackSnapshot()
            var catalogCalls = 0
            player.onTrackStarted = { starts.append($0.id) }
            player.onSnapshotChanged = { snapshot = $0 }
            player.onQueueExhausted = { _ in catalogCalls += 1; return [] }
            player.onQueueEnded = { _ in catalogCalls += 1; return [] }
            let tracks = [track, other, later]
            player.setNetworkOffline(true)
            player.play(tracks)
            try await PlaybackTestSupport.waitUntil(timeout: 8) {
                player.currentIndex == 2 && player.isPlaying && player.position > 0.2
            }
            XCTAssertEqual(player.currentStreamURL, last)
            XCTAssertEqual(starts, [track.id, later.id])
            XCTAssertEqual(player.queue, tracks)
            XCTAssertEqual(snapshot.originalQueue, tracks)
            XCTAssertEqual(catalogCalls, 0)
            XCTAssertTrue(calls.values.isEmpty)
            XCTAssertTrue(fixture.mock.state.requests.isEmpty)
        }
    }

    func testNativeOfflineRepeatOneAndRepeatAllKeepTheirQueueSemantics() async throws {
        for mode in [RepeatMode.one, .all] {
            let fixture = try makeFixture()
            try fixture.seed(track.id, seconds: 1)
            try fixture.seed(later.id, seconds: 1)
            let calls = CatalogTestRecorder<String>()
            let connectivity = ConnectivityMonitor(initialStatus: .offline, monitorsSystem: false)
            let player = PlayerController(resolver: offlineResolver(cache: fixture.cache, connectivity: connectivity, calls: calls))
            defer { player.pause() }
            player.cycleRepeatMode()
            if mode == .one { player.cycleRepeatMode() }
            var starts: [String] = []
            player.onTrackStarted = { starts.append($0.id) }
            player.setNetworkOffline(true)
            let tracks = [track, other, later]
            player.play(tracks, startingAt: mode == .one ? 0 : 2)
            try await PlaybackTestSupport.waitUntil(timeout: 8) { starts.count >= 3 && player.isPlaying }
            XCTAssertEqual(Array(starts.prefix(3)), mode == .one ? [track.id, track.id, track.id] : [later.id, track.id, later.id])
            XCTAssertEqual(player.queue, tracks)
            XCTAssertEqual(player.repeatMode, mode)
            XCTAssertTrue(calls.values.isEmpty)
        }
    }

    func testOfflineExhaustionPausesTruthfullyAndReconnectDoesNotReplayTheFailedQueue() async throws {
        let fixture = try makeFixture()
        try fixture.seed(track.id, seconds: 1)
        let calls = CatalogTestRecorder<String>()
        let connectivity = ConnectivityMonitor(initialStatus: .offline, monitorsSystem: false)
        let player = PlayerController(resolver: offlineResolver(cache: fixture.cache, connectivity: connectivity, calls: calls))
        defer { player.pause() }
        player.setNetworkOffline(true)
        player.play([track, other])
        try await PlaybackTestSupport.waitUntil(timeout: 5) { player.errorMessage?.contains("no more cached songs") == true }
        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(player.isLoading)
        XCTAssertEqual(player.currentIndex, 0)
        connectivity.setStatus(.online)
        player.setNetworkOffline(false)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.currentIndex, 0)
        XCTAssertTrue(calls.values.isEmpty)
    }

    func testUnknownOrFailedInventoryCannotTriggerAnUncachedOfflineResolution() async throws {
        for mode in [OfflineInventoryResolver.Mode.unavailable, .failure] {
            let fixture = try makeFixture()
            try fixture.seed(track.id, seconds: 1)
            try fixture.seed(later.id, seconds: 2)
            let calls = CatalogTestRecorder<String>()
            let connectivity = ConnectivityMonitor(initialStatus: .offline, monitorsSystem: false)
            let resolver = OfflineInventoryResolver(base: offlineResolver(cache: fixture.cache, connectivity: connectivity, calls: calls), mode: mode)
            addTeardownBlock { await resolver.reads.close() }
            let player = PlayerController(resolver: resolver)
            defer { player.pause() }
            player.setNetworkOffline(true)
            player.play([track, other, later])
            try await PlaybackTestSupport.waitUntil(timeout: 5) { player.errorMessage?.contains("couldn’t be checked") == true }
            XCTAssertFalse(player.isPlaying)
            XCTAssertFalse(player.isLoading)
            XCTAssertEqual(player.currentIndex, 0)
            XCTAssertTrue(calls.values.isEmpty)
        }
    }

    func testFreshInventorySkipsAnExternallyPurgedStandbyCopy() async throws {
        let fixture = try makeFixture()
        try fixture.seed(track.id, seconds: 4)
        let purged = try fixture.seed(later.id, seconds: 2)
        let replacement = Track(id: "xTvyyoF_LZY", title: "Still cached", duration: 2)
        let kept = try fixture.seed(replacement.id, seconds: 2)
        let calls = CatalogTestRecorder<String>()
        let connectivity = ConnectivityMonitor(initialStatus: .offline, monitorsSystem: false)
        let player = PlayerController(resolver: offlineResolver(cache: fixture.cache, connectivity: connectivity, calls: calls))
        defer { player.pause() }
        player.setNetworkOffline(true)
        let tracks = [track, other, later, replacement]
        player.play(tracks)
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.isStandbyReady && player.standbyTrack == self.later }
        try FileManager.default.removeItem(at: purged)
        _ = try await player.cachedSongsSnapshot()
        try await PlaybackTestSupport.waitUntil(timeout: 9) { player.currentTrack == replacement && player.isPlaying }
        XCTAssertEqual(player.currentStreamURL, kept)
        XCTAssertEqual(player.currentIndex, 3)
        XCTAssertEqual(player.queue, tracks)
        XCTAssertTrue(calls.values.isEmpty)
    }

    func testNewPlaybackIntentRejectsLateOfflineAdvanceInventory() async throws {
        let fixture = try makeFixture()
        try fixture.seed(track.id, seconds: 4)
        try fixture.seed(later.id, seconds: 4)
        let replacement = Track(id: "xTvyyoF_LZY", title: "New selection", duration: 4)
        try fixture.seed(replacement.id, seconds: 4)
        let calls = CatalogTestRecorder<String>()
        let connectivity = ConnectivityMonitor(initialStatus: .offline, monitorsSystem: false)
        let base = offlineResolver(cache: fixture.cache, connectivity: connectivity, calls: calls)
        let resolver = OfflineInventoryResolver(base: base)
        addTeardownBlock { await resolver.reads.close() }
        let player = PlayerController(resolver: resolver)
        defer { player.pause() }
        player.setNetworkOffline(true)
        player.play([track, other, later])
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.isStandbyReady }
        let oldSnapshot = try await base.audioCacheSnapshot()
        await resolver.setMode(.held)
        player.seek(to: 4)
        let pending = try await resolver.reads.request(at: 0)
        player.play([replacement])
        try await PlaybackTestSupport.waitUntil { player.currentTrack == replacement && player.isPlaying }
        try await resolver.reads.complete(pending, with: .success(oldSnapshot))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(player.currentTrack, replacement)
        XCTAssertEqual(player.queue, [replacement])
        XCTAssertTrue(calls.values.isEmpty)
    }

    func testOfflineManualNextSkipsMissingSongsWithoutStartingPausedAudio() async throws {
        let fixture = try makeFixture()
        try fixture.seed(track.id)
        try fixture.seed(later.id)
        let calls = CatalogTestRecorder<String>()
        let connectivity = ConnectivityMonitor(initialStatus: .offline, monitorsSystem: false)
        let player = PlayerController(resolver: offlineResolver(cache: fixture.cache, connectivity: connectivity, calls: calls))
        defer { player.pause() }
        player.setNetworkOffline(true)
        player.restore(PlaybackSnapshot(queue: [track, other, later], repeatMode: .one))
        player.next()
        try await PlaybackTestSupport.waitUntil { player.currentIndex == 2 }
        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(player.isLoading)
        XCTAssertEqual(player.queue, [track, other, later])
        XCTAssertTrue(calls.values.isEmpty)
    }

    func testOfflineFilteredNextIsRetainedBeforeItsPlayerItemIsPrepared() async throws {
        let fixture = try makeFixture()
        let current = try fixture.seed(track.id)
        let next = try fixture.seed(later.id)
        try fixture.seed("xTvyyoF_LZY")
        let calls = CatalogTestRecorder<String>()
        let connectivity = ConnectivityMonitor(initialStatus: .offline, monitorsSystem: false)
        let player = PlayerController(resolver: offlineResolver(cache: fixture.cache, connectivity: connectivity, calls: calls))
        defer { player.pause() }
        player.setNetworkOffline(true)
        player.restore(PlaybackSnapshot(queue: [track, other, later]))
        _ = try await player.cachedSongsSnapshot()
        XCTAssertFalse(player.hasStandbyPlayer && player.isStandbyReady)
        let cleared = try await player.clearTemporaryAudioCache()
        XCTAssertEqual(cleared?.retainedSongCount, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: next.path))
        XCTAssertFalse(player.isPlaying)
        XCTAssertTrue(calls.values.isEmpty)
    }

    func testReconnectRestartsInterruptedUnchangedPairAndPausedPlaybackWaitsForPlay() async throws {
        for pauseBeforeReconnect in [false, true] {
            let urls = try (0..<3).map { _ in try PlaybackTestSupport.audioFile(seconds: 20) }
            addTeardownBlock { for url in urls { try FileManager.default.removeItem(at: url.deletingLastPathComponent()) } }
            let connectivity = ConnectivityMonitor(initialStatus: .online, monitorsSystem: false)
            let resolver = ReconnectCacheResolver(entries: [track.id: .init(remote: urls[0], cached: urls[0], duration: 20),
                other.id: .init(remote: urls[1], cached: urls[2], duration: 20)], cached: [track.id], isOffline: { connectivity.isOffline })
            addTeardownBlock { await resolver.downloads.close() }
            let player = PlayerController(resolver: resolver)
            defer { player.pause() }
            player.play([track, other])
            let interrupted = try await resolver.downloads.request(at: 0)
            connectivity.setStatus(.offline)
            player.setNetworkOffline(true)
            try await PlaybackTestSupport.eventually { await resolver.downloads.cancellations.contains(interrupted.id) }
            try await resolver.downloads.complete(interrupted, with: .success(true))
            if pauseBeforeReconnect { player.pause() }
            let position = player.position
            connectivity.setStatus(.online)
            player.setNetworkOffline(false)
            if pauseBeforeReconnect {
                try await Task.sleep(for: .milliseconds(150))
                let requests = await resolver.downloads.requests
                XCTAssertEqual(requests.count, 1)
                XCTAssertFalse(player.isPlaying)
                player.togglePlayback()
            }
            let retry = try await resolver.downloads.request(at: 1)
            XCTAssertEqual(retry.input, other.id)
            try await resolver.downloads.complete(retry, with: .success(true))
            try await PlaybackTestSupport.waitUntil {
                player.isPlaying && player.isStandbyReady && player.standbyStreamURL == urls[2] && player.position > position + 0.2
            }
            XCTAssertEqual(player.currentTrack, track)
            XCTAssertEqual(player.currentStreamURL, urls[0])
            XCTAssertTrue(player.isNextTrackCached)
            XCTAssertNil(player.errorMessage)
        }
    }

    func testReconnectPreservesACompletedCachePairWithoutRedownloadingIt() async throws {
        let urls = try (0..<2).map { _ in try PlaybackTestSupport.audioFile(seconds: 4) }
        addTeardownBlock { for url in urls { try FileManager.default.removeItem(at: url.deletingLastPathComponent()) } }
        let resolver = ReconnectCacheResolver(entries: [track.id: .init(remote: urls[0], cached: urls[0], duration: 4),
            other.id: .init(remote: urls[1], cached: urls[1], duration: 4)], cached: [track.id, other.id])
        let pipeline = PlaybackCachePipeline(resolver: resolver)
        defer { pipeline.cancel() }
        var complete = false
        pipeline.onCurrentCached = { _, _ in complete = true }
        let target = PlaybackCachePipeline.Target(track: other, entryID: UUID())
        pipeline.sync(current: track, next: target)
        try await PlaybackTestSupport.waitUntil { complete }
        let before = await resolver.downloadRequests
        pipeline.setNetworkOffline(true)
        pipeline.setNetworkOffline(false)
        pipeline.sync(current: track, next: target)
        try await Task.sleep(for: .milliseconds(100))
        let after = await resolver.downloadRequests
        XCTAssertEqual(before, [other.id, track.id])
        XCTAssertEqual(after, before)
    }

    func testReconnectRearmsAnOfflineFailedStandbyEvenWhenBackgroundDownloadsFail() async throws {
        let urls = try (0..<2).map { _ in try PlaybackTestSupport.audioFile(seconds: 12) }
        addTeardownBlock { for url in urls { try FileManager.default.removeItem(at: url.deletingLastPathComponent()) } }
        let connectivity = ConnectivityMonitor(initialStatus: .offline, monitorsSystem: false)
        let resolver = ReconnectCacheResolver(entries: [track.id: .init(remote: urls[0], cached: urls[0], duration: 12),
            other.id: .init(remote: urls[1], cached: urls[1], duration: 12)], cached: [track.id, other.id],
            failingFirstResolution: [other.id], failDownloads: true, isOffline: { connectivity.isOffline })
        let player = PlayerController(resolver: resolver)
        defer { player.pause() }
        player.setNetworkOffline(true)
        player.play([track, other])
        try await PlaybackTestSupport.eventually {
            let failures = await resolver.resolutionFailures
            return failures == 1 && player.isPlaying && player.standbyTrack == self.other
        }
        connectivity.setStatus(.online)
        player.setNetworkOffline(false)
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.isStandbyReady && player.standbyStreamURL == urls[1] }
        let attempts = await resolver.resolutionRequests
        XCTAssertEqual(attempts.filter { $0 == other.id }.count, 2)
        XCTAssertEqual(player.currentTrack, track)
        XCTAssertNil(player.errorMessage)
    }

    private func offlineResolver(cache: AudioCache, connectivity: ConnectivityMonitor, calls: CatalogTestRecorder<String>,
                                  opusEnabled: Bool = false) -> YouTubeStreamResolver {
        YouTubeStreamResolver(extract: { _, _ in calls.record("extract"); throw URLError(.notConnectedToInternet) },
            validate: { _ in calls.record("validate"); throw URLError(.notConnectedToInternet) },
            fastExtract: { _ in calls.record("fast"); throw URLError(.notConnectedToInternet) },
            audioCache: cache, opusEnabled: opusEnabled, isOffline: { connectivity.isOffline })
    }

    private func remoteFixtureResolver(url: URL, cache: AudioCache, connectivity: ConnectivityMonitor,
                                        calls: CatalogTestRecorder<String>) -> YouTubeStreamResolver {
        YouTubeStreamResolver(extract: { _, _ in [] }, validate: { _ in calls.record("validate") }, audioCache: cache,
            qualityExtract: { _, _ in calls.record("extract"); return [ResolvedStream(url: url, duration: 12)] },
            isOffline: { connectivity.isOffline })
    }

    private func expectOffline(_ operation: () async throws -> ResolvedStream, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await operation(); XCTFail("Expected an offline cache miss", file: file, line: line) }
        catch {
            XCTAssertTrue(error is MusicServiceError, file: file, line: line)
            XCTAssertTrue(error.localizedDescription.contains("isn’t cached"), file: file, line: line)
        }
    }

    private func removeSidecarDuration(_ id: String, in directory: URL) throws {
        let path = directory.appendingPathComponent("\(id).json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        json.removeValue(forKey: "duration")
        try JSONSerialization.data(withJSONObject: json).write(to: path, options: .atomic)
    }

    private func seedBadOpus(in directory: URL, duration: TimeInterval?) throws -> URL {
        let storageID = "\(track.id).opus-\(UUID().uuidString)"
        let media = directory.appendingPathComponent("\(storageID).m4a")
        try OpusTestSupport.mp4.write(to: media)
        let sidecar = AudioCache.Sidecar(duration: duration, bytes: Int64(OpusTestSupport.mp4.count), storedAt: Date(),
                                        fileExtension: "m4a", quality: OpusTestSupport.opusQuality, opusPreparationVersion: 1)
        try JSONEncoder().encode(sidecar).write(to: directory.appendingPathComponent("\(storageID).json"))
        return media
    }

    private func makeAAC() throws -> Data {
        let wave = try PlaybackTestSupport.audioFile()
        addTeardownBlock { try FileManager.default.removeItem(at: wave.deletingLastPathComponent()) }
        let output = wave.deletingLastPathComponent().appendingPathComponent("native-aac.m4a")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let count = 44_100 * 8
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
        buffer.frameLength = AVAudioFrameCount(count)
        let samples = try XCTUnwrap(buffer.floatChannelData)[0]
        for index in 0..<count { samples[index] = Float(sin(Double(index) * 2 * .pi * 440 / 44_100) * 0.02) }
        try writeAAC(buffer, to: output)
        return try Data(contentsOf: output)
    }

    private func writeAAC(_ buffer: AVAudioPCMBuffer, to url: URL) throws {
        let writer = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128_000],
                                    commonFormat: .pcmFormatFloat32, interleaved: false)
        try writer.write(from: buffer)
    }

    private func makeFixture(handler: CatalogMockState.Handler? = nil) throws -> CacheManagementFixture {
        let fixture = try CacheManagementFixture(handler: handler)
        addTeardownBlock { try await fixture.close() }
        return fixture
    }
}

private actor OfflineInventoryResolver: StreamCacheManaging {
    enum Mode { case normal, unavailable, failure, held }
    nonisolated let base: any StreamCacheManaging
    let reads = AppModelRequestGate<String, AudioCacheSnapshot?>()
    private var mode: Mode

    init(base: any StreamCacheManaging, mode: Mode = .normal) { self.base = base; self.mode = mode }
    func setMode(_ mode: Mode) { self.mode = mode }
    func audioCacheSnapshot() async throws -> AudioCacheSnapshot? {
        switch mode {
        case .normal: try await base.audioCacheSnapshot()
        case .unavailable: nil
        case .failure: throw CocoaError(.fileReadNoPermission)
        case .held: try await reads.receive("snapshot")
        }
    }
    func resolve(track: Track, forceRefresh: Bool) async throws -> ResolvedStream { try await base.resolve(track: track, forceRefresh: forceRefresh) }
    func download(_ track: Track) async throws -> ResolvedStream { try await base.download(track) }
    func retainCached(_ trackIDs: Set<String>) async { await base.retainCached(trackIDs) }
    func discardCached(_ track: Track) async { await base.discardCached(track) }
    nonisolated func isCachedStream(_ stream: ResolvedStream) -> Bool { base.isCachedStream(stream) }
    func audioCacheUsage() async throws -> AudioCache.Usage? { try await base.audioCacheUsage() }
    func clearAudioCache(retaining: @escaping @Sendable () async -> Set<String>) async throws -> AudioCache.Usage? {
        try await base.clearAudioCache(retaining: retaining)
    }
}

private actor ReconnectCacheResolver: StreamCacheManaging {
    nonisolated let entries: [String: PlaybackCachingFixtureResolver.Entry]
    let downloads = AppModelRequestGate<String, Bool>()
    private let isOffline: @Sendable () -> Bool
    private var cached: Set<String>
    private var failures: Set<String>
    private let failDownloads: Bool
    private var retained: Set<String> = []
    private(set) var downloadRequests: [String] = []
    private(set) var resolutionRequests: [String] = []
    private(set) var resolutionFailures = 0

    init(entries: [String: PlaybackCachingFixtureResolver.Entry], cached: Set<String>, failingFirstResolution: Set<String> = [],
         failDownloads: Bool = false, isOffline: @escaping @Sendable () -> Bool = { false }) {
        self.entries = entries
        self.cached = cached
        failures = failingFirstResolution
        self.failDownloads = failDownloads
        self.isOffline = isOffline
    }
    func resolve(track: Track, forceRefresh: Bool) throws -> ResolvedStream {
        resolutionRequests.append(track.id)
        if failures.remove(track.id) != nil { resolutionFailures += 1; throw PlaybackStreamError.noAudio }
        guard let entry = entries[track.id] else { throw PlaybackStreamError.noAudio }
        if cached.contains(track.id), let url = entry.cached { return ResolvedStream(url: url, duration: entry.duration) }
        guard !isOffline() else { throw MusicServiceError.network(YouTubeStreamResolver.offlineMessage) }
        return ResolvedStream(url: entry.remote, duration: entry.duration)
    }
    func download(_ track: Track) async throws -> ResolvedStream {
        downloadRequests.append(track.id)
        guard !failDownloads, let entry = entries[track.id], let url = entry.cached else { throw PlaybackStreamError.noAudio }
        if !cached.contains(track.id) {
            guard !isOffline() else { throw MusicServiceError.network(YouTubeStreamResolver.offlineMessage) }
            _ = try await downloads.receive(track.id)
            try Task.checkCancellation()
            cached.insert(track.id)
        }
        return ResolvedStream(url: url, duration: entry.duration)
    }
    func audioCacheSnapshot() throws -> AudioCacheSnapshot? {
        let songs = try cached.sorted().compactMap { id -> CachedSong? in
            guard let entry = entries[id], let url = entry.cached else { return nil }
            let bytes = Int64(try Data(contentsOf: url).count)
            let audio = CachedAudio(trackID: id, url: url, duration: entry.duration, loudnessDb: nil, viewCount: nil,
                                    bytes: bytes, storedAt: Date())
            return CachedSong(id: id, track: nil, preferredAudio: audio, bytes: bytes, variantCount: 1, isInUse: retained.contains(id))
        }
        let usage = AudioCache.Usage(bytes: songs.reduce(0) { $0 + $1.bytes }, songCount: songs.count,
            retainedBytes: songs.filter(\.isInUse).reduce(0) { $0 + $1.bytes }, retainedSongCount: songs.filter(\.isInUse).count,
            capacityBytes: 200 << 20, maximumSongs: 40, pendingDownloads: 0)
        return AudioCacheSnapshot(usage: usage, songs: songs)
    }
    func audioCacheUsage() throws -> AudioCache.Usage? { try audioCacheSnapshot()?.usage }
    func retainCached(_ trackIDs: Set<String>) { retained = trackIDs }
    func discardCached(_ track: Track) { cached.remove(track.id) }
    nonisolated func isCachedStream(_ stream: ResolvedStream) -> Bool { entries.values.contains { $0.cached == stream.url } }
    func clearAudioCache(retaining: @escaping @Sendable () async -> Set<String>) -> AudioCache.Usage? { nil }
}

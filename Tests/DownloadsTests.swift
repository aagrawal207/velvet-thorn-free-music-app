import XCTest
@testable import GanaBajana

/// Download tier of `AudioCache` plus the `DownloadManager` queue; transfers are stubbed, files are real.
final class DownloadsTests: XCTestCase {
    private let a = "fsiPzT50ZiM"
    private let b = "NJAv_7lHUIU"
    private let c = "J7p4bzqLvCw"
    private let d = "FOA9iyxsW_A"
    private var directories: [URL] = []
    private var mocks: [CatalogMockSession] = []

    override func tearDown() async throws {
        for mock in mocks { mock.close() }
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        mocks.removeAll()
        directories.removeAll()
    }

    // MARK: - Identifiers

    func testTrackIDValidationAcceptsSourcePrefixesAndRejectsPathTricks() {
        XCTAssertTrue(AudioCache.isValidTrackID("saavn:abc123"))
        XCTAssertTrue(AudioCache.isProviderTrackID("saavn:abc123"), "Prefixed sources define their own ID lengths")
        XCTAssertTrue(AudioCache.isValidTrackID("gaana:Song_9-x"))
        XCTAssertTrue(AudioCache.isProviderTrackID(a))
        XCTAssertFalse(AudioCache.isProviderTrackID("CacheOnly01x"), "Bare IDs remain YouTube's 11 characters")
        for invalid in ["../x", "saavn:", "saavn:a/b", "saavn:../x", "spotify:abc", "", "a:b", "saavn~abc", String(repeating: "a", count: 65)] {
            XCTAssertFalse(AudioCache.isValidTrackID(invalid), invalid)
        }
        XCTAssertEqual(AudioCache.storageKey(for: "saavn:abc123"), "saavn~abc123")
        XCTAssertEqual(AudioCache.trackID(forStorageKey: "saavn~abc123"), "saavn:abc123")
        XCTAssertEqual(AudioCache.trackID(forStorageKey: a), a)
        XCTAssertNil(AudioCache.trackID(forStorageKey: "foo~bar"))
        let url = URL(fileURLWithPath: "/tmp/Audio/saavn~abc123.opus-\(UUID().uuidString).m4a")
        XCTAssertEqual(AudioCache.logicalTrackID(for: url), "saavn:abc123")
        let song = CachedSong(id: "saavn:abc123", track: nil,
                              preferredAudio: CachedAudio(trackID: "saavn:abc123", url: url, duration: 3, loudnessDb: nil, viewCount: nil,
                                                          bytes: 10, storedAt: Date()),
                              bytes: 10, variantCount: 1, isInUse: false)
        XCTAssertTrue(song.isPlayable)
    }

    func testPrefixedIDStoresUnderATildeFileNameAndReadsBack() async throws {
        let payload = PlaybackTestSupport.audioData(seconds: 1)
        let fixture = try makeCache(serving: { _ in Self.wav(payload) })
        let id = "saavn:abc123"
        let stored = try await fixture.cache.store(trackID: id, from: Self.remote(id), stream: ResolvedStream(url: Self.remote(id), duration: 1))
        XCTAssertEqual(stored.url.lastPathComponent, "saavn~abc123.wav")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.cache.directory.appendingPathComponent("saavn~abc123.json").path))
        let entry = await fixture.cache.entry(for: id)
        XCTAssertEqual(entry?.trackID, id)
        let snapshot = try await fixture.cache.snapshot()
        XCTAssertEqual(snapshot.songs.map(\.id), [id])
        XCTAssertTrue(snapshot.songs[0].isPlayable)
        let promoted = try await fixture.cache.promoteToDownloads(id)
        XCTAssertEqual(promoted, .moved(bytes: Int64(payload.count)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.cache.downloadsDirectory.appendingPathComponent("saavn~abc123.wav").path))
    }

    // MARK: - Tier moves

    func testPromotionRenamesMediaAndSidecarIntoTheDownloadTierAndLookupPrefersIt() async throws {
        let payload = PlaybackTestSupport.audioData(seconds: 2)
        let fixture = try makeCache(serving: { _ in Self.wav(payload) })
        let cache = fixture.cache
        let stored = try await cache.store(trackID: a, from: Self.remote(a),
                                           stream: ResolvedStream(url: Self.remote(a), duration: 2, loudnessDb: -3, viewCount: 42),
                                           track: Track(id: a, title: "Tum Hi Ho", artists: ["Arijit Singh"], duration: 262))
        let originalInode = try inode(of: stored.url)
        let change = try await cache.promoteToDownloads(a)
        XCTAssertEqual(change, .moved(bytes: Int64(payload.count)))

        let downloadedMedia = cache.downloadsDirectory.appendingPathComponent("\(a).wav")
        let downloadedSidecar = cache.downloadsDirectory.appendingPathComponent("\(a).json")
        XCTAssertEqual(try inode(of: downloadedMedia), originalInode, "Promotion is a rename of the same file, not a copy")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.directory.path), [], "Nothing stays in the temporary tier")
        let sidecar = try JSONSerialization.jsonObject(with: Data(contentsOf: downloadedSidecar)) as? [String: Any]
        XCTAssertEqual(sidecar?["downloaded"] as? Bool, true)
        XCTAssertEqual(sidecar?["bytes"] as? Int, payload.count)
        XCTAssertEqual((sidecar?["track"] as? [String: Any])?["title"] as? String, "Tum Hi Ho")
        let excluded = try cache.downloadsDirectory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        XCTAssertEqual(excluded, true)

        let lookup = await cache.entry(for: a)
        let entry = try XCTUnwrap(lookup)
        XCTAssertTrue(entry.isDownloaded)
        XCTAssertEqual(entry.url, downloadedMedia)
        XCTAssertEqual(entry.duration, 2)
        XCTAssertEqual(entry.loudnessDb, -3)
        XCTAssertEqual(entry.track?.title, "Tum Hi Ho")
        let prepared = try await cache.preparedEntry(for: a)
        XCTAssertEqual(prepared?.url, downloadedMedia)
        let again = try await cache.promoteToDownloads(a)
        XCTAssertEqual(again, .alreadyThere(bytes: Int64(payload.count)))
        let missing = try await cache.promoteToDownloads(b)
        XCTAssertEqual(missing, .notFound)
        XCTAssertTrue(AudioCache.isDownloadedMediaURL(downloadedMedia))
        XCTAssertFalse(AudioCache.isDownloadedMediaURL(stored.url))
    }

    func testDownloadsAreExcludedFromLimitEvictionClearAndRemovalButCountedSeparately() async throws {
        let payload = PlaybackTestSupport.audioData(seconds: 2)
        let bytes = Int64(payload.count)
        // Room for two cached songs; the download tier must not consume that room or become a victim.
        let fixture = try makeCache(capacityBytes: bytes * 2 + 1_024, maximumFiles: 2, serving: { _ in Self.wav(payload) })
        let cache = fixture.cache
        _ = try await cache.store(trackID: a, from: Self.remote(a), stream: ResolvedStream(url: Self.remote(a), duration: 2))
        _ = try await cache.promoteToDownloads(a)
        _ = try await cache.store(trackID: b, from: Self.remote(b), stream: ResolvedStream(url: Self.remote(b), duration: 2))
        _ = try await cache.store(trackID: c, from: Self.remote(c), stream: ResolvedStream(url: Self.remote(c), duration: 2))

        let usage = try await cache.storageUsage()
        XCTAssertEqual(usage.bytes, bytes * 2, "Downloaded bytes never count against the cache limit")
        XCTAssertEqual(usage.songCount, 2)
        XCTAssertEqual(usage.downloadedBytes, bytes)
        XCTAssertEqual(usage.downloadedSongCount, 1)
        let snapshot = try await cache.snapshot()
        XCTAssertEqual(snapshot.songs.filter(\.isDownloaded).map(\.id), [a])
        XCTAssertEqual(snapshot.songs.count, 3)
        XCTAssertTrue(snapshot.songs.allSatisfy(\.isPlayable))

        // A fourth song forces eviction of a temporary copy; the download stays.
        _ = try await cache.store(trackID: "Fourth00001", from: Self.remote("Fourth00001"),
                                  stream: ResolvedStream(url: Self.remote("Fourth00001"), duration: 2))
        let afterEviction = try await cache.snapshot()
        XCTAssertTrue(afterEviction.songs.contains { $0.id == a && $0.isDownloaded })
        XCTAssertEqual(afterEviction.usage.songCount, 2)

        let cleared = try await cache.clearUnused()
        XCTAssertEqual(cleared.songCount, 0)
        XCTAssertEqual(cleared.downloadedSongCount, 1)
        await cache.removeAll()
        let stillDownloaded = await cache.isDownloaded(a)
        XCTAssertTrue(stillDownloaded)
        let removal = try await cache.removeSong(id: a)
        XCTAssertEqual(removal.outcome, .notFound, "Per-song cache removal never reaches the download tier")
        let entry = await cache.entry(for: a)
        XCTAssertEqual(entry?.isDownloaded, true)

        let limited = try await cache.updatePolicy(capacityBytes: 1, maximumFiles: 1)
        XCTAssertEqual(limited.downloadedSongCount, 1)
        XCTAssertEqual(limited.songCount, 0)
    }

    func testDemotionReturnsFilesToTheCacheTierAndDeletionRemovesOrDemotesInUse() async throws {
        let payload = PlaybackTestSupport.audioData(seconds: 1)
        let fixture = try makeCache(serving: { _ in Self.wav(payload) })
        let cache = fixture.cache
        _ = try await cache.store(trackID: a, from: Self.remote(a), stream: ResolvedStream(url: Self.remote(a), duration: 1))
        _ = try await cache.promoteToDownloads(a)
        let demoted = try await cache.demoteToCache(a)
        XCTAssertEqual(demoted, .moved(bytes: Int64(payload.count)))
        let lookup = await cache.entry(for: a)
        let entry = try XCTUnwrap(lookup)
        XCTAssertFalse(entry.isDownloaded)
        XCTAssertEqual(entry.url.deletingLastPathComponent().standardizedFileURL, cache.directory)
        let sidecar = try JSONSerialization.jsonObject(with: Data(contentsOf: cache.directory.appendingPathComponent("\(a).json"))) as? [String: Any]
        XCTAssertNil(sidecar?["downloaded"], "The temporary tier keeps the legacy sidecar shape")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.downloadsDirectory.path), [])
        let demoteAgain = try await cache.demoteToCache(a)
        XCTAssertEqual(demoteAgain, .alreadyThere(bytes: Int64(payload.count)))

        _ = try await cache.promoteToDownloads(a)
        await cache.pin(a)
        let protected = try await cache.deleteDownload(a)
        XCTAssertEqual(protected, .demotedInUse(bytes: Int64(payload.count)), "A song in use keeps its file, in the temporary tier")
        let keptEntry = await cache.entry(for: a)
        XCTAssertEqual(keptEntry?.isDownloaded, false)
        await cache.unpin(a)

        _ = try await cache.promoteToDownloads(a)
        let deleted = try await cache.deleteDownload(a)
        XCTAssertEqual(deleted, .deleted(bytes: Int64(payload.count)))
        let gone = await cache.entry(for: a)
        XCTAssertNil(gone)
        let notFound = try await cache.deleteDownload(a)
        XCTAssertEqual(notFound, .notFound)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.downloadsDirectory.path), [])
    }

    func testStoringADownloadedSongAgainReturnsTheDownloadWithoutANetworkRequest() async throws {
        let payload = PlaybackTestSupport.audioData(seconds: 1)
        let fixture = try makeCache(serving: { _ in Self.wav(payload) })
        _ = try await fixture.cache.store(trackID: a, from: Self.remote(a), stream: ResolvedStream(url: Self.remote(a), duration: 1))
        _ = try await fixture.cache.promoteToDownloads(a)
        let again = try await fixture.cache.store(trackID: a, from: Self.remote(a), stream: ResolvedStream(url: Self.remote(a), duration: 1))
        XCTAssertTrue(again.isDownloaded)
        XCTAssertEqual(fixture.mock.state.requests.count, 1)
    }

    // MARK: - Queue

    @MainActor
    func testManagerPromotesACompleteCachedCopyOfflineWithoutTransferring() async throws {
        let payload = PlaybackTestSupport.audioData(seconds: 1)
        let fixture = try makeCache(serving: { _ in Self.wav(payload) })
        _ = try await fixture.cache.store(trackID: a, from: Self.remote(a), stream: ResolvedStream(url: Self.remote(a), duration: 1))
        let transfers = CatalogTestRecorder<String>()
        let connectivity = StubConnectivity(offline: true)
        let manager = DownloadManager(store: fixture.cache, transfer: { track in
            transfers.record(track.id)
            throw URLError(.notConnectedToInternet)
        }, connectivity: connectivity, queueFile: nil, configuration: Self.fastConfiguration)
        let observer = DownloadObserver()
        await manager.setObservers(onChange: { observer.record($0) }, onTierChange: { id, downloaded in observer.tier(id, downloaded) })
        let added = await manager.enqueue([Self.track(a), Self.track(b)])
        XCTAssertEqual(added, 2)
        try await PlaybackTestSupport.waitUntil { observer.tierChanges.contains { $0 == (self.a, true) } }
        let downloaded = await fixture.cache.isDownloaded(a)
        XCTAssertTrue(downloaded)
        let items = await manager.items
        XCTAssertEqual(items.map(\.id), [b], "The finished song leaves the queue; the uncached one waits for a connection")
        XCTAssertEqual(items.first?.state, .queued)
        XCTAssertTrue(transfers.values.isEmpty, "Known offline, nothing is transferred")
    }

    @MainActor
    func testWiFiGatingHoldsCellularTransfersUntilAllowedAndTransfersAtMostTwoAtOnce() async throws {
        let payload = PlaybackTestSupport.audioData(seconds: 1)
        let fixture = try makeCache(serving: { _ in Self.wav(payload) })
        let connectivity = StubConnectivity(offline: false, expensive: true)
        let gate = TransferGate()
        let cache = fixture.cache
        let manager = DownloadManager(store: cache, transfer: { track in
            try await gate.enter(track.id)
            return try await cache.store(trackID: track.id, from: Self.remote(track.id),
                                         stream: ResolvedStream(url: Self.remote(track.id), duration: 1)).stream
        }, connectivity: connectivity, queueFile: nil, configuration: Self.fastConfiguration)
        let observer = DownloadObserver()
        await manager.setObservers(onChange: { observer.record($0) }, onTierChange: { id, downloaded in observer.tier(id, downloaded) })
        await manager.enqueue([Self.track(a), Self.track(b), Self.track(c)])
        try await PlaybackTestSupport.waitUntil {
            observer.latest.count == 3 && observer.latest.allSatisfy { $0.state == .waitingForWiFi }
        }
        XCTAssertEqual(gate.entered, [])

        await manager.setAllowCellular(true)
        try await PlaybackTestSupport.waitUntil { gate.entered.count == 2 }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(gate.entered.count, 2, "Only two transfers run concurrently")
        let states = observer.latest.map(\.state)
        XCTAssertEqual(states.filter(\.isDownloading).count, 2)
        XCTAssertEqual(states.filter { $0 == .queued }.count, 1)

        gate.release(a)
        try await PlaybackTestSupport.waitUntil { observer.tierChanges.contains { $0 == (self.a, true) } }
        try await PlaybackTestSupport.waitUntil { gate.entered.count == 3 }
        gate.release(b)
        gate.release(c)
        try await PlaybackTestSupport.waitUntil { observer.latest.isEmpty }
        let snapshot = try await cache.snapshot()
        XCTAssertEqual(snapshot.songs.filter(\.isDownloaded).map(\.id).sorted(), [a, b, c].sorted())
        XCTAssertEqual(snapshot.usage.songCount, 0)
    }

    @MainActor
    func testRetriesTwiceWithBackoffThenReportsFailureAndRetryRequeues() async throws {
        let payload = PlaybackTestSupport.audioData(seconds: 1)
        let fixture = try makeCache(serving: { _ in Self.wav(payload) })
        let attempts = CatalogTestRecorder<String>()
        let connectivity = StubConnectivity(offline: false)
        let manager = DownloadManager(store: fixture.cache, transfer: { track in
            attempts.record(track.id)
            throw MusicServiceError.network("Synthetic transfer failure")
        }, connectivity: connectivity, queueFile: nil, configuration: Self.fastConfiguration)
        let observer = DownloadObserver()
        await manager.setObservers(onChange: { observer.record($0) }, onTierChange: { _, _ in })
        await manager.enqueue([Self.track(a)])
        try await PlaybackTestSupport.waitUntil(timeout: 10) {
            if case .failed = observer.latest.first?.state { return true }
            return false
        }
        XCTAssertEqual(attempts.values.count, 3, "Three attempts: the first plus two retries")
        guard case .failed(let reason) = observer.latest.first?.state else { return XCTFail("Expected a failed item") }
        XCTAssertTrue(reason.contains("Synthetic transfer failure"))
        XCTAssertTrue(observer.sawQueuedAfterDownloading, "Backoff returns the item to the queue between attempts")

        await manager.retry(a)
        try await PlaybackTestSupport.waitUntil(timeout: 10) { attempts.values.count == 6 }
        try await PlaybackTestSupport.waitUntil(timeout: 10) {
            if case .failed = observer.latest.first?.state { return true }
            return false
        }
        await manager.cancel(a)
        let remaining = await manager.items
        XCTAssertTrue(remaining.isEmpty)
    }

    @MainActor
    func testCancellationStopsTheTransferAndPersistedQueueSurvivesANewManager() async throws {
        let payload = PlaybackTestSupport.audioData(seconds: 1)
        let fixture = try makeCache(serving: { _ in Self.wav(payload) })
        let queueFile = fixture.cache.directory.deletingLastPathComponent().appendingPathComponent("downloads-queue.json")
        let gate = TransferGate()
        let connectivity = StubConnectivity(offline: false)
        let cancelled = CatalogTestRecorder<String>()
        let manager = DownloadManager(store: fixture.cache, transfer: { track in
            do { try await gate.enter(track.id) } catch { cancelled.record(track.id); throw error }
            throw MusicServiceError.network("not reached")
        }, connectivity: connectivity, queueFile: queueFile, configuration: Self.fastConfiguration)
        let observer = DownloadObserver()
        await manager.setObservers(onChange: { observer.record($0) }, onTierChange: { _, _ in })
        await manager.enqueue([Self.track(a), Self.track(b), Self.track(c), Self.track("../escape"), Self.track(a)])
        let record = try XCTUnwrap(DownloadQueueRecord.load(from: queueFile))
        XCTAssertEqual(record.trackIDs, [a, b, c], "Invalid IDs and duplicates are never queued or persisted")
        try await PlaybackTestSupport.waitUntil { gate.entered.count == 2 }

        await manager.cancel(a)
        try await PlaybackTestSupport.waitUntil { cancelled.values.contains(self.a) }
        XCTAssertEqual(try XCTUnwrap(DownloadQueueRecord.load(from: queueFile)).trackIDs, [b, c])
        try await PlaybackTestSupport.waitUntil { gate.entered.contains(self.c) }

        // A second manager over the same file re-queues the pending IDs it can still resolve to tracks.
        let restored = DownloadManager(store: fixture.cache, transfer: { _ in throw MusicServiceError.network("offline") },
                                       connectivity: StubConnectivity(offline: true), queueFile: queueFile,
                                       configuration: Self.fastConfiguration)
        let dropped = c
        await restored.restore(resolvingTracks: { ids in ids.filter { $0 != dropped }.map(Self.track) })
        let items = await restored.items
        XCTAssertEqual(items.map(\.id), [b], "Unresolvable IDs are dropped instead of downloading placeholder metadata")
        XCTAssertEqual(items.first?.state, .queued)
        await manager.cancelAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: queueFile.path), "An empty queue removes its file")
        gate.releaseAll()
    }

    @MainActor
    func testCollectionStateIsDerivedFromDownloadedAndQueuedSongs() async throws {
        let center = DownloadCenter(manager: nil)
        let tracks = [Self.track(a), Self.track(b), Self.track(c)]
        XCTAssertEqual(center.collectionState(for: tracks, downloadedIDs: []), .none)
        XCTAssertEqual(center.collectionState(for: tracks, downloadedIDs: [a, b, c]), .downloaded)
        XCTAssertEqual(center.collectionState(for: tracks, downloadedIDs: [a]), .none, "Partial without activity offers Download again")
        XCTAssertEqual(center.collectionState(for: [], downloadedIDs: [a]), .none)
        XCTAssertEqual(CollectionDownloadState.downloading(done: 1, total: 3).title, "Downloading 1 of 3")
        XCTAssertEqual(DownloadState.downloading(fraction: 0.4211).title, "Downloading 42%")
        XCTAssertEqual(DownloadState.downloading(fraction: 1).title, "Downloading 99%")
        XCTAssertFalse(center.isAvailable)

        let payload = PlaybackTestSupport.audioData(seconds: 1)
        let fixture = try makeCache(serving: { _ in Self.wav(payload) })
        let gate = TransferGate()
        let manager = DownloadManager(store: fixture.cache, transfer: { track in
            try await gate.enter(track.id)
            throw CancellationError()
        }, connectivity: StubConnectivity(offline: false), queueFile: nil, configuration: Self.fastConfiguration)
        let live = DownloadCenter(manager: manager)
        live.download([Self.track(b), Self.track(c)])
        try await PlaybackTestSupport.waitUntil { live.items.count == 2 }
        XCTAssertEqual(live.collectionState(for: tracks, downloadedIDs: [a]), .downloading(done: 1, total: 3))
        XCTAssertTrue(live.isQueued(b))
        live.cancelAll()
        try await PlaybackTestSupport.waitUntil { live.items.isEmpty }
        gate.releaseAll()
    }

    // MARK: - Model integration

    @MainActor
    func testLikingASongEnqueuesItOnlyWhileAutoDownloadIsOnAndBulkEnqueueSkipsDownloaded() async throws {
        let payload = PlaybackTestSupport.audioData(seconds: 1)
        let fixture = try makeCache(serving: { _ in Self.wav(payload) })
        _ = try await fixture.cache.store(trackID: b, from: Self.remote(b), stream: ResolvedStream(url: Self.remote(b), duration: 1))
        _ = try await fixture.cache.promoteToDownloads(b)
        let enqueued = CatalogTestRecorder<String>()
        let gate = TransferGate()
        let manager = DownloadManager(store: fixture.cache, transfer: { track in
            enqueued.record(track.id)
            try await gate.enter(track.id)
            throw CancellationError()
        }, connectivity: StubConnectivity(offline: false), queueFile: nil, configuration: Self.fastConfiguration)
        defer { gate.releaseAll() }
        let center = DownloadCenter(manager: manager)
        let model = try makeModel(downloads: center)
        // The test player has no inventory, so the promotion is observed through the center's tier callback.
        center.download([Self.track(b)])
        try await PlaybackTestSupport.waitUntil { model.isDownloaded(Self.track(b)) }

        model.library.toggleFavorite(Self.track(a))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(enqueued.values.isEmpty, "Likes do nothing while the preference is off")

        model.updatePreferences { $0.autoDownloadLikedSongs = true }
        model.library.toggleFavorite(Self.track(c))
        try await PlaybackTestSupport.waitUntil { enqueued.values.contains(self.c) }
        XCTAssertFalse(enqueued.values.contains(a), "Turning the toggle on is the Settings flow's decision, not an implicit backlog")
        model.library.toggleFavorite(Self.track(c))
        try await Task.sleep(for: .milliseconds(200))
        let stillDownloaded = await fixture.cache.isDownloaded(b)
        XCTAssertTrue(stillDownloaded, "Unliking never deletes a file")

        model.library.toggleFavorite(Self.track(b))
        XCTAssertEqual(model.pendingLikedDownloads.map(\.id), [a], "Downloaded and queued likes are not part of the backlog")
        model.downloadAllLikedSongs()
        try await PlaybackTestSupport.waitUntil { enqueued.values.contains(self.a) }
        XCTAssertEqual(enqueued.values.filter { $0 == self.b }.count, 0)
    }

    // MARK: - One home per song

    func testPromotionKeepsTheBestVariantInTheDownloadTierAndRemovesTheRest() async throws {
        let payload = PlaybackTestSupport.audioData(seconds: 1)
        let fixture = try makeCache(preparesOpus: true, serving: Self.wavOrWebM(payload))
        let cache = fixture.cache
        _ = try await cache.store(trackID: a, from: Self.remote(a), stream: ResolvedStream(url: Self.remote(a), duration: 1))
        let permit = try await cache.writePermit()
        let opus = try await cache.storeOpus(trackID: a, stream: OpusTestSupport.source(), permit: permit, foreground: true)
        XCTAssertFalse(opus.isDownloaded)
        let before = try await cache.snapshot()
        XCTAssertEqual(before.songs.first { $0.id == a }?.variantCount, 2)
        let knownBefore = cache.isDownloaded(trackID: a)
        XCTAssertFalse(knownBefore)

        let change = try await cache.promoteToDownloads(a)
        XCTAssertEqual(change, .moved(bytes: Int64(OpusTestSupport.mp4.count)), "Only the best encoding moves; the rest is removed")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.directory.path), [],
                       "The AAC original leaves the cache tier once nothing reads it")
        let downloaded = try FileManager.default.contentsOfDirectory(atPath: cache.downloadsDirectory.path).sorted()
        XCTAssertEqual(downloaded.count, 2)
        XCTAssertTrue(downloaded.allSatisfy { $0.hasPrefix("\(a).opus-") })
        let lookup = await cache.entry(for: a)
        XCTAssertEqual(lookup?.isDownloaded, true)
        XCTAssertEqual(lookup?.url.deletingLastPathComponent().standardizedFileURL, cache.downloadsDirectory)
        let usage = try await cache.storageUsage()
        XCTAssertEqual(usage.songCount, 0)
        XCTAssertEqual(usage.bytes, 0)
        XCTAssertEqual(usage.downloadedSongCount, 1)
        XCTAssertEqual(usage.downloadedBytes, Int64(OpusTestSupport.mp4.count))
        let after = try await cache.snapshot()
        let song = try XCTUnwrap(after.songs.first { $0.id == a })
        XCTAssertTrue(song.isDownloaded)
        XCTAssertEqual(song.variantCount, 1)
        XCTAssertTrue(cache.isDownloaded(trackID: a), "The index answers without a disk read after the move")
        let again = try await cache.promoteToDownloads(a)
        XCTAssertEqual(again, .alreadyThere(bytes: Int64(OpusTestSupport.mp4.count)))
    }

    func testPromotionOfAnInUseSongDefersTheRemovalUntilItsReadersLeave() async throws {
        let payload = PlaybackTestSupport.audioData(seconds: 1)
        let fixture = try makeCache(preparesOpus: true, serving: Self.wavOrWebM(payload))
        let cache = fixture.cache
        _ = try await cache.store(trackID: a, from: Self.remote(a), stream: ResolvedStream(url: Self.remote(a), duration: 1))
        let permit = try await cache.writePermit()
        _ = try await cache.storeOpus(trackID: a, stream: OpusTestSupport.source(), permit: permit, foreground: true)
        await cache.pin(a)

        let change = try await cache.promoteToDownloads(a)
        XCTAssertEqual(change, .moved(bytes: Int64(OpusTestSupport.mp4.count)))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.directory.path).sorted(), ["\(a).json", "\(a).wav"],
                       "The original a live player may be reading stays until the song leaves use")
        let pinnedUsage = try await cache.storageUsage()
        XCTAssertEqual(pinnedUsage.songCount, 1, "A stale variant still counts while it exists")
        XCTAssertEqual(pinnedUsage.downloadedSongCount, 1)
        let pinnedSnapshot = try await cache.snapshot()
        XCTAssertEqual(pinnedSnapshot.songs.first { $0.id == a }?.variantCount, 2)
        XCTAssertEqual(pinnedSnapshot.songs.first { $0.id == a }?.isDownloaded, true)

        // Maintenance passes respect the same protection: the pinned song keeps its stale file.
        let cleared = try await cache.clearUnused()
        XCTAssertEqual(cleared.retainedSongCount, 1)
        _ = try await cache.updatePolicy(capacityBytes: 1, maximumFiles: 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.directory.path).sorted(), ["\(a).json", "\(a).wav"])

        await cache.unpin(a)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.directory.path), [],
                       "The deferred removal runs as soon as protection ends")
        let usage = try await cache.storageUsage()
        XCTAssertEqual(usage.songCount, 0)
        XCTAssertEqual(usage.downloadedSongCount, 1)
        let entry = await cache.entry(for: a)
        XCTAssertEqual(entry?.isDownloaded, true)
    }

    func testBetterOpusVariantReplacesTheDownloadedFileInsideTheDownloadTier() async throws {
        let payload = PlaybackTestSupport.audioData(seconds: 1)
        let fixture = try makeCache(preparesOpus: true, serving: Self.wavOrWebM(payload))
        let cache = fixture.cache
        _ = try await cache.store(trackID: a, from: Self.remote(a), stream: ResolvedStream(url: Self.remote(a), duration: 1))
        _ = try await cache.promoteToDownloads(a)
        let permit = try await cache.writePermit()
        let prepared = try await cache.storeOpus(trackID: a, stream: OpusTestSupport.source(), permit: permit, foreground: true)
        XCTAssertTrue(prepared.isDownloaded, "The better encoding is adopted by the download tier at publication")
        XCTAssertEqual(prepared.url.deletingLastPathComponent().standardizedFileURL, cache.downloadsDirectory)
        XCTAssertTrue(prepared.url.lastPathComponent.hasPrefix("\(a).opus-"))
        XCTAssertEqual(try Data(contentsOf: prepared.url), OpusTestSupport.mp4)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.directory.path), [], "Nothing lives in the cache tier")
        let downloaded = try FileManager.default.contentsOfDirectory(atPath: cache.downloadsDirectory.path)
        XCTAssertEqual(downloaded.count, 2)
        XCTAssertFalse(downloaded.contains("\(a).wav"), "The replaced download is removed")
        let usage = try await cache.storageUsage()
        XCTAssertEqual(usage.downloadedSongCount, 1)
        XCTAssertEqual(usage.downloadedBytes, Int64(OpusTestSupport.mp4.count))
        XCTAssertEqual(usage.songCount, 0)
        let lookup = await cache.entry(for: a)
        XCTAssertEqual(lookup?.url, prepared.url)
        XCTAssertTrue(AudioCache.isDownloadedMediaURL(prepared.url))

        // The base encoding is gone, yet a store for the song still answers with the download and no transfer.
        let requests = fixture.mock.state.requests.count
        let stored = try await cache.store(trackID: a, from: Self.remote(a), stream: ResolvedStream(url: Self.remote(a), duration: 1))
        XCTAssertEqual(stored.url, prepared.url)
        XCTAssertEqual(fixture.mock.state.requests.count, requests)
        let demoted = try await cache.demoteToCache(a)
        XCTAssertEqual(demoted, .moved(bytes: Int64(OpusTestSupport.mp4.count)))
        XCTAssertFalse(cache.isDownloaded(trackID: a))
    }

    func testLesserAdmissionsForADownloadedSongReturnTheDownloadWithoutWriting() async throws {
        let payload = PlaybackTestSupport.audioData(seconds: 1)
        let fixture = try makeCache(preparesOpus: true, serving: Self.wavOrWebM(payload))
        let cache = fixture.cache
        let quality = SourceAudioQuality(codec: .aac, bitRate: 256_000, sampleRate: 44_100, channels: 2)
        _ = try await cache.store(trackID: a, from: Self.remote(a), stream: ResolvedStream(url: Self.remote(a), duration: 1, quality: quality))
        _ = try await cache.promoteToDownloads(a)
        let requests = fixture.mock.state.requests.count
        let permit = try await cache.writePermit()
        let answered = try await cache.storeOpus(trackID: a, stream: OpusTestSupport.source(rate: 160_000), permit: permit, foreground: true)
        XCTAssertTrue(answered.isDownloaded)
        XCTAssertEqual(answered.url.lastPathComponent, "\(a).wav")
        XCTAssertEqual(fixture.mock.state.requests.count, requests, "A lesser encoding is refused before any transfer")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.directory.path), [])
        let speculative = try await cache.storeOpus(trackID: a, stream: OpusTestSupport.source(rate: 128_000), permit: permit,
                                                    foreground: false, speculative: true)
        XCTAssertEqual(speculative.url, answered.url)
        XCTAssertEqual(fixture.mock.state.requests.count, requests)
    }

    func testACopyFinishedAfterAPromotionIsDroppedInFavourOfTheBetterDownload() async throws {
        let payload = PlaybackTestSupport.audioData(seconds: 1)
        let gate = TransferGate()
        let fixture = try makeCache(preparesOpus: true, serving: { _ in
            var stub = Self.wav(payload)
            stub.beforeDelivery = { try await gate.enter("transfer") }
            return stub
        })
        let cache = fixture.cache
        let id = a
        let remote = Self.remote(id)
        let work = Task { try await cache.store(trackID: id, from: remote, stream: ResolvedStream(url: remote, duration: 1)) }
        try await PlaybackTestSupport.waitUntil { gate.entered.count == 1 }
        // A better encoding lands in the download tier while the transfer is still receiving.
        try seedDownloadedOpus(id, in: cache)
        gate.release("transfer")
        let stored = try await work.value
        XCTAssertTrue(stored.isDownloaded)
        XCTAssertTrue(stored.url.lastPathComponent.hasPrefix("\(id).opus-"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.directory.path), [],
                       "The finished copy is dropped instead of becoming a second home")
        let usage = try await cache.storageUsage()
        XCTAssertEqual(usage.songCount, 0)
        XCTAssertEqual(usage.downloadedSongCount, 1)
    }

    func testClearLimitAndRemovalLeaveADownloadedSongWithZeroCacheVariantsIntact() async throws {
        let payload = PlaybackTestSupport.audioData(seconds: 1)
        let bytes = Int64(payload.count)
        let fixture = try makeCache(preparesOpus: true, serving: Self.wavOrWebM(payload))
        let cache = fixture.cache
        _ = try await cache.store(trackID: a, from: Self.remote(a), stream: ResolvedStream(url: Self.remote(a), duration: 1))
        let permit = try await cache.writePermit()
        _ = try await cache.storeOpus(trackID: a, stream: OpusTestSupport.source(), permit: permit, foreground: true)
        _ = try await cache.promoteToDownloads(a)
        // Room for two cached songs from here on; preparation needed the default budget above.
        _ = try await cache.updatePolicy(capacityBytes: bytes * 2 + 1_024, maximumFiles: 2)
        _ = try await cache.store(trackID: b, from: Self.remote(b), stream: ResolvedStream(url: Self.remote(b), duration: 1))
        _ = try await cache.store(trackID: c, from: Self.remote(c), stream: ResolvedStream(url: Self.remote(c), duration: 1))

        let snapshot = try await cache.snapshot()
        XCTAssertEqual(snapshot.songs.filter(\.isDownloaded).map(\.id), [a])
        XCTAssertEqual(snapshot.songs.filter { !$0.isDownloaded }.map(\.id).sorted(), [b, c].sorted(), "Tiers separate cleanly in one inventory")
        XCTAssertEqual(snapshot.usage.songCount, 2)
        XCTAssertEqual(snapshot.usage.bytes, bytes * 2)
        XCTAssertEqual(snapshot.usage.downloadedSongCount, 1)
        XCTAssertEqual(snapshot.usage.downloadedBytes, Int64(OpusTestSupport.mp4.count))

        await cache.removeAll()
        let afterClear = try await cache.storageUsage()
        XCTAssertEqual(afterClear.songCount, 0)
        XCTAssertEqual(afterClear.downloadedSongCount, 1)
        let stillDownloaded = await cache.isDownloaded(a)
        XCTAssertTrue(stillDownloaded)
        _ = try await cache.store(trackID: b, from: Self.remote(b), stream: ResolvedStream(url: Self.remote(b), duration: 1))
        let cleared = try await cache.clearUnused()
        XCTAssertEqual(cleared.downloadedSongCount, 1)
        let limited = try await cache.updatePolicy(capacityBytes: 1, maximumFiles: 1)
        XCTAssertEqual(limited.downloadedSongCount, 1)
        XCTAssertEqual(limited.downloadedBytes, Int64(OpusTestSupport.mp4.count))
        let removal = try await cache.removeSong(id: a)
        XCTAssertEqual(removal.outcome, .notFound)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.directory.path).filter { $0.hasPrefix(a) }, [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.downloadsDirectory.path).count, 2)
        let entry = await cache.entry(for: a)
        XCTAssertEqual(entry?.isDownloaded, true)
    }

    func testInventoryLoadRepairsLegacyDuplicatesOnceAndDefersSongsInUse() async throws {
        let payload = PlaybackTestSupport.audioData(seconds: 1)
        let fixture = try makeCache(preparesOpus: true, serving: Self.wavOrWebM(payload))
        let cache = fixture.cache
        // a: downloaded AAC beside a better prepared Opus left in the cache by an older reload.
        try seedFile(a, payload: payload, tier: .downloads, in: cache)
        let betterOpus = try seedOpus(a, version: 1, tier: .cache, in: cache)
        // b: downloaded AAC beside an unprepared Opus variant that can never play.
        try seedFile(b, payload: payload, tier: .downloads, in: cache)
        _ = try seedOpus(b, version: 0, tier: .cache, in: cache)
        // c: downloaded AAC beside a stale cache variant, but pinned like a restored current song.
        try seedFile(c, payload: payload, tier: .downloads, in: cache)
        _ = try seedOpus(c, version: 0, tier: .cache, in: cache)
        await cache.pin(c)
        XCTAssertFalse(cache.isDownloaded(trackID: a), "Nothing is known before the first inventory read")

        let snapshot = try await cache.snapshot()
        let songA = try XCTUnwrap(snapshot.songs.first { $0.id == a })
        XCTAssertTrue(songA.isDownloaded)
        XCTAssertEqual(songA.variantCount, 1)
        XCTAssertEqual(songA.preferredAudio?.url.lastPathComponent, betterOpus.lastPathComponent, "The better variant became the download")
        XCTAssertEqual(songA.preferredAudio?.url.deletingLastPathComponent().standardizedFileURL, cache.downloadsDirectory)
        let songB = try XCTUnwrap(snapshot.songs.first { $0.id == b })
        XCTAssertEqual(songB.variantCount, 1)
        XCTAssertEqual(songB.preferredAudio?.url.lastPathComponent, "\(b).wav")
        let songC = try XCTUnwrap(snapshot.songs.first { $0.id == c })
        XCTAssertEqual(songC.variantCount, 2, "A song in use keeps its files until protection ends")
        XCTAssertTrue(songC.isDownloaded)
        XCTAssertEqual(snapshot.usage.downloadedSongCount, 3)
        XCTAssertEqual(snapshot.usage.songCount, 1, "Only the deferred stale variant remains in the cache tier")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.directory.path).filter { $0.hasPrefix(a) || $0.hasPrefix(b) }, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.downloadsDirectory.appendingPathComponent("\(a).wav").path))
        XCTAssertTrue(cache.isDownloaded(trackID: a))
        XCTAssertTrue(cache.isDownloaded(trackID: c))

        await cache.unpin(c)
        let repaired = try await cache.snapshot()
        XCTAssertEqual(repaired.songs.first { $0.id == c }?.variantCount, 1)
        XCTAssertEqual(repaired.usage.songCount, 0)
        XCTAssertEqual(repaired.usage.downloadedSongCount, 3)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.directory.path), [])

        // A relaunch runs the load cleanup again; with one home per song it finds nothing to remove.
        try seedFile(d, payload: payload, tier: .cache, in: cache)
        let downloadsBefore = try FileManager.default.contentsOfDirectory(atPath: cache.downloadsDirectory.path).sorted()
        let relaunched = AudioCache(directory: cache.directory, downloadsDirectory: cache.downloadsDirectory, session: fixture.mock.session)
        let again = try await relaunched.snapshot()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.downloadsDirectory.path).sorted(), downloadsBefore)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.directory.path).sorted(), ["\(d).json", "\(d).wav"],
                       "A cache-tier song without a download is never a duplicate")
        XCTAssertEqual(again.songs.map(\.variantCount), [1, 1, 1, 1])
        XCTAssertEqual(again.usage.songCount, 1)
        XCTAssertEqual(again.usage.downloadedSongCount, 3)
    }

    /// A native reader's lease protects the original it is reading; the removal runs when that lease ends.
    func testPromotionWhileAReaderHoldsTheOriginalRetiresItWhenTheReaderReleases() async throws {
        let payload = PlaybackTestSupport.audioData(seconds: 1)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GanaBajanaDownloadsTests-\(UUID())", isDirectory: true)
        directories.append(root)
        let mock = CatalogMockSession(handler: { _ in Self.wav(payload) })
        mocks.append(mock)
        let (release, releaseReader) = AsyncStream<Void>.makeStream()
        let (entered, readerEntered) = AsyncStream<Void>.makeStream()
        let cache = AudioCache(directory: root.appendingPathComponent("Audio", isDirectory: true),
                               downloadsDirectory: root.appendingPathComponent("Downloads", isDirectory: true),
                               session: mock.session, localDurationLoader: { _ in
                                   readerEntered.yield()
                                   for await _ in release { break }
                                   return 1
                               })
        // The AAC has no stored duration, so reading it holds a lease while the native inspection runs.
        try FileManager.default.createDirectory(at: cache.directory, withIntermediateDirectories: true)
        try payload.write(to: cache.directory.appendingPathComponent("\(a).wav"))
        let sidecar = AudioCache.Sidecar(duration: nil, bytes: Int64(payload.count), storedAt: Date(), fileExtension: "wav")
        try JSONEncoder().encode(sidecar).write(to: cache.directory.appendingPathComponent("\(a).json"))
        let opus = try seedOpus(a, version: 1, tier: .cache, in: cache)

        let id = a
        let reading = Task { try await cache.preparedEntry(for: id, allowOpus: false) }
        var readers = entered.makeAsyncIterator()
        _ = await readers.next()
        let change = try await cache.promoteToDownloads(a)
        XCTAssertEqual(change, .moved(bytes: Int64(OpusTestSupport.mp4.count)), "The better Opus becomes the download")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.downloadsDirectory.appendingPathComponent(opus.lastPathComponent).path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.directory.path).sorted(), ["\(a).json", "\(a).wav"],
                       "The original stays while its reader holds it")

        releaseReader.yield()
        let read = try await reading.value
        XCTAssertEqual(read?.url.lastPathComponent, "\(a).wav")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.directory.path), [],
                       "Releasing the lease retires the pending removal")
        let snapshot = try await cache.snapshot()
        XCTAssertEqual(snapshot.songs.map(\.variantCount), [1])
        XCTAssertEqual(snapshot.usage.songCount, 0)
        XCTAssertEqual(snapshot.usage.downloadedSongCount, 1)
    }

    /// Remove download renames the file back, so the song is a cached song again and counts in the temporary tier.
    func testRemoveDownloadReturnsTheSongToTheCachedInventoryAndItsTotals() async throws {
        let payload = PlaybackTestSupport.audioData(seconds: 1)
        let fixture = try makeCache(serving: { _ in Self.wav(payload) })
        let cache = fixture.cache
        _ = try await cache.store(trackID: a, from: Self.remote(a), stream: ResolvedStream(url: Self.remote(a), duration: 1))
        _ = try await cache.store(trackID: b, from: Self.remote(b), stream: ResolvedStream(url: Self.remote(b), duration: 1))
        _ = try await cache.promoteToDownloads(a)
        let downloaded = try await cache.snapshot()
        XCTAssertEqual(downloaded.songs.filter { !$0.isDownloaded }.map(\.id), [b])
        XCTAssertEqual(downloaded.usage.songCount, 1)
        XCTAssertEqual(downloaded.usage.bytes, Int64(payload.count))
        XCTAssertEqual(downloaded.usage.downloadedSongCount, 1)

        _ = try await cache.demoteToCache(a)
        let returned = try await cache.snapshot()
        XCTAssertEqual(returned.songs.filter { !$0.isDownloaded }.map(\.id), [a, b].sorted(), "The demoted song is a cached song again")
        XCTAssertTrue(returned.songs.allSatisfy(\.isPlayable))
        XCTAssertEqual(returned.usage.songCount, 2)
        XCTAssertEqual(returned.usage.bytes, Int64(payload.count) * 2)
        XCTAssertEqual(returned.usage.downloadedSongCount, 0)
        XCTAssertEqual(returned.usage.downloadedBytes, 0)
        XCTAssertFalse(cache.isDownloaded(trackID: a))
    }

    @MainActor
    func testManagerPromotionOfATwoEncodingSongLeavesOneFileAndTheCachedInventoryDropsIt() async throws {
        let payload = PlaybackTestSupport.audioData(seconds: 1)
        let fixture = try makeCache(preparesOpus: true, serving: Self.wavOrWebM(payload))
        let cache = fixture.cache
        _ = try await cache.store(trackID: a, from: Self.remote(a), stream: ResolvedStream(url: Self.remote(a), duration: 1))
        let permit = try await cache.writePermit()
        _ = try await cache.storeOpus(trackID: a, stream: OpusTestSupport.source(), permit: permit, foreground: true)
        _ = try await cache.store(trackID: b, from: Self.remote(b), stream: ResolvedStream(url: Self.remote(b), duration: 1))
        let manager = DownloadManager(store: cache, transfer: { _ in throw URLError(.notConnectedToInternet) },
                                      connectivity: StubConnectivity(offline: true), queueFile: nil, configuration: Self.fastConfiguration)
        let observer = DownloadObserver()
        await manager.setObservers(onChange: { observer.record($0) }, onTierChange: { id, downloaded in observer.tier(id, downloaded) })
        await manager.enqueue([Self.track(a)])
        try await PlaybackTestSupport.waitUntil { observer.tierChanges.contains { $0 == (self.a, true) } }
        let snapshot = try await cache.snapshot()
        let temporary = snapshot.songs.filter { !$0.isDownloaded }
        XCTAssertEqual(temporary.map(\.id), [b], "The Cached songs inventory excludes the downloaded song")
        XCTAssertEqual(snapshot.songs.filter(\.isDownloaded).map(\.id), [a])
        XCTAssertEqual(snapshot.songs.first { $0.id == a }?.variantCount, 1)
        XCTAssertEqual(snapshot.usage.songCount, 1)
        XCTAssertEqual(snapshot.usage.bytes, Int64(payload.count))
        XCTAssertEqual(snapshot.usage.downloadedBytes, Int64(OpusTestSupport.mp4.count))
        XCTAssertTrue(Set(snapshot.songs.filter(\.isPlayable).map(\.id)).isSuperset(of: [a, b]), "Offline playback covers both tiers")
    }

    // MARK: - Scoped local readers

    @MainActor
    func testScopedLocalCopyProtectsRemovalAndClearUntilOperationReturns() async throws {
        let payload = PlaybackTestSupport.audioData(seconds: 1)
        let fixture = try makeCache(serving: { _ in Self.wav(payload) })
        let source = try await fixture.cache.store(trackID: a, from: Self.remote(a), stream: ResolvedStream(url: Self.remote(a), duration: 1))
        let manager = DownloadManager(store: fixture.cache, transfer: { _ in throw PlaybackStreamError.noAudio },
                                      connectivity: StubConnectivity(offline: true), queueFile: nil)
        let center = DownloadCenter(manager: manager)
        let gate = ScopedLocalCopyGate()
        let id = a
        let work = Task {
            try await center.withLocalCopy(for: id) { audio in
                await gate.wait()
                return try Data(contentsOf: audio.url).count
            }
        }
        try await PlaybackTestSupport.waitUntil { gate.entered }
        let readers = await fixture.cache.activeReaderCount
        XCTAssertEqual(readers, 1)
        let removal = try await fixture.cache.removeSong(id: a)
        XCTAssertEqual(removal.outcome, .inUse)
        let cleared = try await fixture.cache.clearUnused()
        XCTAssertEqual(cleared.retainedSongCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.url.path))
        gate.release()
        let result = try await work.value
        XCTAssertEqual(result, payload.count)
        let released = await fixture.cache.activeReaderCount
        XCTAssertEqual(released, 0)
        _ = try await fixture.cache.clearUnused()
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.url.path))
    }

    @MainActor
    func testScopedLocalCopyKeepsLeaseUntilCancelledOperationDrains() async throws {
        let payload = PlaybackTestSupport.audioData(seconds: 1)
        let fixture = try makeCache(serving: { _ in Self.wav(payload) })
        let source = try await fixture.cache.store(trackID: a, from: Self.remote(a), stream: ResolvedStream(url: Self.remote(a), duration: 1))
        let gate = ScopedLocalCopyGate()
        let cache = fixture.cache
        let id = a
        let work = Task {
            try await cache.withLocalCopy(for: id) { audio in
                await gate.wait()
                XCTAssertEqual(try Data(contentsOf: audio.url), payload)
                try Task.checkCancellation()
                return audio.bytes
            }
        }
        try await PlaybackTestSupport.waitUntil { gate.entered }
        work.cancel()
        _ = try await cache.clearUnused()
        let readers = await cache.activeReaderCount
        XCTAssertEqual(readers, 1, "Cancellation cannot release a reader still doing cleanup")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.url.path))
        gate.release()
        do { _ = try await work.value; XCTFail("The cancelled operation must propagate cancellation") }
        catch is CancellationError { }
        let released = await cache.activeReaderCount
        XCTAssertEqual(released, 0)
        _ = try await cache.clearUnused()
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.url.path))
    }

    @MainActor
    func testScopedLocalCopyAcquiresLeaseBeforeAsynchronousDurationLookup() async throws {
        let gate = ScopedLocalCopyGate()
        let payload = PlaybackTestSupport.audioData(seconds: 1)
        let fixture = try makeCache(localDurationLoader: { url in
            await gate.wait()
            XCTAssertEqual(try Data(contentsOf: url), payload)
            return 1
        }, serving: { _ in Self.wav(payload) })
        _ = try await fixture.cache.store(trackID: a, from: Self.remote(a), stream: ResolvedStream(url: Self.remote(a)))
        let cache = fixture.cache
        let id = a
        let work = Task { try await cache.withLocalCopy(for: id) { $0.duration ?? 0 } }
        try await PlaybackTestSupport.waitUntil { gate.entered }
        let readers = await cache.activeReaderCount
        XCTAssertEqual(readers, 1)
        let removal = try await cache.removeSong(id: a)
        XCTAssertEqual(removal.outcome, .inUse)
        _ = try await cache.clearUnused()
        gate.release()
        let result = try await work.value
        XCTAssertEqual(result, 1)
        let released = await cache.activeReaderCount
        XCTAssertEqual(released, 0)
    }

    @MainActor
    func testScopedDownloadedCopyKeepsOriginalURLAcrossInUseDemotion() async throws {
        let payload = PlaybackTestSupport.audioData(seconds: 1)
        let fixture = try makeCache(serving: { _ in Self.wav(payload) })
        let cache = fixture.cache
        _ = try await cache.store(trackID: a, from: Self.remote(a), stream: ResolvedStream(url: Self.remote(a), duration: 1))
        _ = try await cache.promoteToDownloads(a)
        let original = cache.downloadsDirectory.appendingPathComponent("\(a).wav")
        let gate = ScopedLocalCopyGate()
        let id = a
        let work = Task {
            try await cache.withLocalCopy(for: id) { audio in
                XCTAssertEqual(audio.url, original)
                await gate.wait()
                return try Data(contentsOf: audio.url)
            }
        }
        try await PlaybackTestSupport.waitUntil { gate.entered }
        let deletion = try await cache.deleteDownload(a)
        XCTAssertEqual(deletion, .demotedInUse(bytes: Int64(payload.count)))
        let current = await cache.entry(for: a)
        XCTAssertEqual(current?.isDownloaded, false)
        let usage = try await cache.clearUnused()
        XCTAssertEqual(usage.downloadedSongCount, 0)
        XCTAssertEqual(usage.bytes, Int64(payload.count * 2), "The borrowed original remains accounted for until release")
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        gate.release()
        let result = try await work.value
        XCTAssertEqual(result, payload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        let after = try await cache.storageUsage()
        XCTAssertEqual(after.bytes, Int64(payload.count))
        _ = try await cache.clearUnused()
        let remaining = await cache.entry(for: a)
        XCTAssertNil(remaining)
    }

    func testScopedLocalCopyMissingAndOperationErrorReleaseWithoutRejectingValidAudio() async throws {
        let payload = PlaybackTestSupport.audioData(seconds: 1)
        let fixture = try makeCache(serving: { _ in Self.wav(payload) })
        let absent: Int? = try await fixture.cache.withLocalCopy(for: a) { _ in XCTFail("Missing audio cannot invoke the operation"); return 1 }
        XCTAssertNil(absent)
        _ = try await fixture.cache.store(trackID: a, from: Self.remote(a), stream: ResolvedStream(url: Self.remote(a), duration: 1))
        do {
            let _: Int? = try await fixture.cache.withLocalCopy(for: a) { _ in throw PlaybackStreamError.timedOut }
            XCTFail("Operation errors must propagate")
        } catch PlaybackStreamError.timedOut { }
        let retained = await fixture.cache.entry(for: a)
        XCTAssertNotNil(retained, "An export failure does not make the source corrupt")
        let readers = await fixture.cache.activeReaderCount
        XCTAssertEqual(readers, 0)
    }

    // MARK: - Helpers

    private static let fastConfiguration = DownloadManager.Configuration(
        maximumConcurrent: 2, maximumAttempts: 3, backoff: [.milliseconds(20), .milliseconds(40)],
        progressInterval: .milliseconds(50), allowOpus: false)

    private static func track(_ id: String) -> Track {
        Track(id: id, title: "Song \(id)", artists: ["Fixture artist"], duration: 8, isAudioRecording: true)
    }

    private struct CacheFixture {
        let cache: AudioCache
        let mock: CatalogMockSession
    }

    private func makeCache(capacityBytes: Int64 = 200 << 20, maximumFiles: Int = 40, preparesOpus: Bool = false,
                           localDurationLoader: AudioCache.LocalDurationLoader? = nil,
                           serving handler: @escaping CatalogMockState.Handler) throws -> CacheFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GanaBajanaDownloadsTests-\(UUID())", isDirectory: true)
        directories.append(root)
        let mock = CatalogMockSession(handler: handler)
        mocks.append(mock)
        let preparation: AudioCache.OpusPreparation
        if preparesOpus {
            preparation = { try await OpusTestSupport.prepare(input: $0, output: $1) }
        } else {
            preparation = { try await OpusNativeAudio.prepare(input: $0, output: $1) }
        }
        let cache = AudioCache(directory: root.appendingPathComponent("Audio", isDirectory: true),
                               downloadsDirectory: root.appendingPathComponent("Downloads", isDirectory: true),
                               capacityBytes: capacityBytes, maximumFiles: maximumFiles, session: mock.session,
                               opusPreparation: preparation, localDurationLoader: localDurationLoader)
        return CacheFixture(cache: cache, mock: mock)
    }

    /// Writes a complete WAV pair straight into a tier, the way an older install left it.
    private func seedFile(_ id: String, payload: Data, tier: AudioCache.Tier, in cache: AudioCache) throws {
        let directory = tier == .cache ? cache.directory : cache.downloadsDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try payload.write(to: directory.appendingPathComponent("\(id).wav"))
        let sidecar = AudioCache.Sidecar(duration: 1, bytes: Int64(payload.count), storedAt: Date(), fileExtension: "wav",
                                         downloaded: tier == .downloads)
        try JSONEncoder().encode(sidecar).write(to: directory.appendingPathComponent("\(id).json"))
    }

    /// A prepared (version 1) or unprepared (version 0) Opus variant pair; returns the media URL.
    private func seedOpus(_ id: String, version: Int, tier: AudioCache.Tier, in cache: AudioCache) throws -> URL {
        let directory = tier == .cache ? cache.directory : cache.downloadsDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let key = "\(id).opus-\(UUID().uuidString)"
        let media = directory.appendingPathComponent("\(key).m4a")
        try OpusTestSupport.mp4.write(to: media)
        let sidecar = AudioCache.Sidecar(duration: 8, bytes: Int64(OpusTestSupport.mp4.count), storedAt: Date(), fileExtension: "m4a",
                                         quality: OpusTestSupport.opusQuality, opusPreparationVersion: version,
                                         downloaded: tier == .downloads)
        try JSONEncoder().encode(sidecar).write(to: directory.appendingPathComponent("\(key).json"))
        return media
    }

    private func seedDownloadedOpus(_ id: String, in cache: AudioCache) throws {
        _ = try seedOpus(id, version: 1, tier: .downloads, in: cache)
    }

    @MainActor
    private func makeModel(downloads: DownloadCenter) throws -> MusicAppModel {
        let context = try AppModelTestContext()
        let model = MusicAppModel(library: context.library, player: context.player, catalog: context.catalog,
                                  charts: context.charts, lyrics: context.lyrics, account: context.model.account,
                                  appIcons: context.model.appIcons, recordingLanguageService: context.model.recordingLanguageService,
                                  languageDiscovery: context.model.languageDiscovery,
                                  connectivity: ConnectivityMonitor(initialStatus: .online, monitorsSystem: false),
                                  downloads: downloads, generatesMixes: false)
        addTeardownBlock { @MainActor in
            model.deactivateDeviceServices()
            try await context.close()
        }
        return model
    }

    private func inode(of url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    }

    private static func wav(_ payload: Data) -> CatalogStub {
        CatalogStub(headers: ["Content-Type": "audio/wav", "Content-Length": "\(payload.count)"], data: payload)
    }

    /// Opus candidates carry itag 251; everything else is the WAV original.
    private static func wavOrWebM(_ payload: Data) -> CatalogMockState.Handler {
        { request in
            guard request.url?.absoluteString.contains("itag=251") == true else { return wav(payload) }
            return CatalogStub(headers: ["Content-Type": "audio/webm", "Content-Length": "\(OpusTestSupport.webM.count)"],
                               data: OpusTestSupport.webM)
        }
    }

    private static func remote(_ id: String) -> URL {
        URL(string: "https://audio.googlevideo.com/videoplayback?id=\(id.replacingOccurrences(of: ":", with: "_"))&dur=8&expire=4000000000")!
    }
}

private struct StubConnectivity: DownloadConnectivity {
    var offline: Bool
    var expensive = false
    var isOffline: Bool { offline }
    var isExpensivePath: Bool { expensive }
}

/// Holds a consumer past cancellation so tests can distinguish cancellation intent from actual reader cleanup.
private final class ScopedLocalCopyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    var entered: Bool { lock.withLock { continuation != nil } }
    func wait() async { await withCheckedContinuation { value in lock.withLock { continuation = value } } }
    func release() { lock.withLock { let value = continuation; continuation = nil; return value }?.resume() }
}

private final class DownloadObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [[DownloadItem]] = []
    private var tiers: [(String, Bool)] = []
    var latest: [DownloadItem] { lock.withLock { snapshots.last ?? [] } }
    var tierChanges: [(String, Bool)] { lock.withLock { tiers } }
    func record(_ items: [DownloadItem]) { lock.withLock { snapshots.append(items) } }
    func tier(_ id: String, _ downloaded: Bool) { lock.withLock { tiers.append((id, downloaded)) } }

    var sawQueuedAfterDownloading: Bool {
        lock.withLock {
            var downloading = false
            for snapshot in snapshots {
                guard let state = snapshot.first?.state else { continue }
                if state.isDownloading { downloading = true }
                else if downloading, state == .queued { return true }
            }
            return false
        }
    }
}

/// Holds transfers open until the test releases them, so concurrency and cancellation are observable.
private final class TransferGate: @unchecked Sendable {
    private let lock = NSLock()
    private var enteredIDs: [String] = []
    private var waiters: [String: CheckedContinuation<Void, any Error>] = [:]

    var entered: [String] { lock.withLock { enteredIDs } }

    func enter(_ id: String) async throws {
        lock.withLock { enteredIDs.append(id) }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.withLock { waiters[id] = continuation }
            }
        } onCancel: {
            lock.withLock { waiters.removeValue(forKey: id) }?.resume(throwing: CancellationError())
        }
    }

    func release(_ id: String) {
        lock.withLock { waiters.removeValue(forKey: id) }?.resume()
    }

    func releaseAll() {
        let all = lock.withLock { let values = Array(waiters.values); waiters.removeAll(); return values }
        all.forEach { $0.resume(throwing: CancellationError()) }
    }
}

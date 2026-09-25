import XCTest
@testable import GanaBajana

@MainActor
final class CachedSongInventoryTests: XCTestCase {
    private let a = Track(id: "fsiPzT50ZiM", title: "Saved song", credits: [ArtistCredit(name: "Artist", id: "artist-id")],
                          albumTitle: "Album", albumID: "album-id", duration: 8,
                          artworkURL: URL(string: "https://images.example.com/cover.jpg"), isAudioRecording: true)
    private let b = Track(id: "NJAv_7lHUIU", title: "Second")
    private let c = Track(id: "J7p4bzqLvCw", title: "Third")
    private let d = Track(id: "xTvyyoF_LZY", title: "Unused")

    func testInventoryGroupsEveryEncodingWithStableIdentityMetadataAndUntouchedAccessTimes() async throws {
        let fixture = try opusFixture()
        let original = try fixture.seed(a.id)
        let permit = try await fixture.cache.writePermit()
        let first = try await fixture.cache.storeOpus(trackID: a.id, stream: OpusTestSupport.source(),
                                                      permit: permit, foreground: false, track: a)
        let best = try await fixture.cache.storeOpus(trackID: a.id, stream: OpusTestSupport.source(rate: 256_000),
                                                     permit: permit, foreground: false, track: a)
        let urls = [original, first.url, best.url]
        let accessed = Date(timeIntervalSince1970: 12_345)
        for url in urls { try FileManager.default.setAttributes([.modificationDate: accessed], ofItemAtPath: url.path) }
        let files = try FileManager.default.contentsOfDirectory(atPath: fixture.cache.directory.path).sorted()
        let total = try urls.reduce(Int64(0)) { $0 + Int64(try Data(contentsOf: $1).count) }

        let snapshot = try await fixture.cache.snapshot()
        let song = try XCTUnwrap(snapshot.songs.first)
        XCTAssertEqual(snapshot.songs.count, 1)
        XCTAssertEqual(song.id, a.id)
        XCTAssertEqual(song.track, a)
        XCTAssertEqual(song.preferredAudio?.url, best.url)
        XCTAssertEqual(song.preferredAudio?.track, a)
        XCTAssertTrue(song.isPlayable)
        XCTAssertFalse(song.isInUse)
        XCTAssertEqual(song.variantCount, 3)
        XCTAssertEqual(song.bytes, total)
        XCTAssertEqual(snapshot.usage.bytes, total)
        XCTAssertEqual(snapshot.usage.songCount, 1)
        XCTAssertEqual(snapshot.usage.retainedSongCount, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.cache.directory.path).sorted(), files)
        for url in urls {
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date, accessed)
        }
        let aacOnly = try await fixture.cache.snapshot(allowOpus: false)
        XCTAssertEqual(aacOnly.songs.first?.preferredAudio?.url, original)
        XCTAssertEqual(aacOnly.songs.first?.track, a, "Another encoding can supply matching display metadata")
        await fixture.cache.pin(a.id)
        let retained = try await fixture.cache.snapshot()
        XCTAssertTrue(try XCTUnwrap(retained.songs.first).isInUse)
        XCTAssertEqual(retained.usage.retainedBytes, total)
    }

    func testAACPublicationPersistsTrackMetadataWithoutTheSignedSourceURL() async throws {
        let fixture = try makeFixture()
        let url = AudioCacheTests.remote(a.id)
        let stored = try await fixture.cache.store(trackID: a.id, from: url,
            stream: ResolvedStream(url: url, duration: 8, quality: OpusTestSupport.aacQuality), track: a)
        XCTAssertEqual(stored.track, a)
        let metadata = try Data(contentsOf: fixture.cache.directory.appendingPathComponent("\(a.id).json"))
        let text = String(decoding: metadata, as: UTF8.self)
        XCTAssertFalse(text.contains("googlevideo"))
        XCTAssertFalse(text.contains("expire="))
        let reopened = AudioCache(directory: fixture.cache.directory, session: fixture.mock.session)
        let snapshot = try await reopened.snapshot()
        XCTAssertEqual(snapshot.songs.first?.track, a)
        XCTAssertEqual(snapshot.songs.first?.preferredAudio?.url, stored.url)
    }

    func testMissingMalformedAndMismatchedOptionalMetadataNeverInvalidateCompleteMedia() async throws {
        let fixture = try makeFixture()
        let media = try fixture.seed(a.id)
        let path = fixture.cache.directory.appendingPathComponent("\(a.id).json")
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        let invalid: [Any?] = [nil, NSNull(), "bad metadata", ["id": a.id],
                              ["id": b.id, "title": "Wrong recording"],
                              ["id": a.id, "title": "", "duration": -1]]
        for value in invalid {
            var json = original
            json["track"] = value
            try JSONSerialization.data(withJSONObject: json).write(to: path, options: .atomic)
            let snapshot = try await fixture.cache.snapshot()
            let song = try XCTUnwrap(snapshot.songs.first)
            XCTAssertNil(song.track)
            XCTAssertNil(song.preferredAudio?.track)
            XCTAssertEqual(song.preferredAudio?.url, media)
            XCTAssertTrue(song.isPlayable)
        }
        var valid = original
        valid["track"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(a))
        try JSONSerialization.data(withJSONObject: valid).write(to: path, options: .atomic)
        let snapshot = try await fixture.cache.snapshot()
        XCTAssertEqual(snapshot.songs.first?.track, a)
    }

    func testIncompleteRejectedUnsupportedAndNonProviderIDsAreNotAdvertisedAsPlayable() async throws {
        let fixture = try makeFixture()
        let rejected = try fixture.seed(a.id)
        await fixture.cache.pin(a.id)
        await fixture.cache.rejectPlaybackFile(rejected)
        let short = try fixture.seed("short-id")
        let variant = "\(b.id).opus-\(UUID().uuidString)"
        try OpusTestSupport.mp4.write(to: fixture.cache.directory.appendingPathComponent("\(variant).m4a"))
        let future = AudioCache.Sidecar(duration: 8, bytes: Int64(OpusTestSupport.mp4.count), storedAt: Date(),
                                       fileExtension: "m4a", quality: OpusTestSupport.opusQuality, opusPreparationVersion: 2)
        try JSONEncoder().encode(future).write(to: fixture.cache.directory.appendingPathComponent("\(variant).json"))
        try Data([1, 2, 3]).write(to: fixture.cache.directory.appendingPathComponent("\(c.id).wav"))
        try fixture.sidecar(c.id, bytes: 100)
        try fixture.sidecar(d.id, bytes: 100)
        try Data([1]).write(to: fixture.cache.directory.appendingPathComponent("\(c.id)-\(UUID()).part"))

        let snapshot = try await fixture.cache.snapshot()
        XCTAssertEqual(Set(snapshot.songs.map(\.id)), [a.id, b.id, "short-id"])
        XCTAssertTrue(snapshot.songs.allSatisfy { !$0.isPlayable && $0.preferredAudio == nil })
        XCTAssertEqual(snapshot.usage.songCount, 3)
        XCTAssertEqual(snapshot.usage.bytes,
                       Int64(try Data(contentsOf: rejected).count + Data(contentsOf: short).count + OpusTestSupport.mp4.count))
        XCTAssertTrue(try XCTUnwrap(snapshot.songs.first { $0.id == a.id }).isInUse)
    }

    func testSnapshotUsesTheExistingResolverWithoutNetworkAndUnsupportedDoesNotMeanEmpty() async throws {
        let fixture = try makeFixture()
        let media = try fixture.seed(a.id)
        let requests = CatalogTestRecorder<String>()
        let resolver = YouTubeStreamResolver(extract: { _, _ in requests.record("extract"); throw PlaybackStreamError.noAudio },
            validate: { _ in requests.record("validate") }, fastExtract: { _ in
                requests.record("fast"); throw PlaybackStreamError.noAudio
            }, audioCache: fixture.cache, isOffline: { true })
        let player = PlayerController(resolver: resolver)
        defer { player.pause() }
        let snapshot = try await player.cachedSongsSnapshot()
        XCTAssertEqual(snapshot?.songs.map(\.id), [a.id])
        XCTAssertTrue(requests.values.isEmpty)
        XCTAssertTrue(fixture.mock.state.requests.isEmpty)
        let plain = PlayerController(resolver: PlaybackFileResolver(url: media))
        defer { plain.pause() }
        let absent = try await plain.cachedSongsSnapshot()
        let removal = try await plain.removeCachedSong(id: a.id)
        XCTAssertNil(absent)
        XCTAssertNil(removal)
        XCTAssertNil(plain.updateCacheListeningHistory([], now: Date()))
        let legacy = LegacyInventoryResolver()
        let legacySnapshot = try await legacy.audioCacheSnapshot()
        let legacyRemoval = try await legacy.removeCachedSong(id: a.id) { [] }
        await legacy.updateCacheListeningHistory([], now: Date())
        XCTAssertNil(legacySnapshot)
        XCTAssertNil(legacyRemoval)
        let empty = try makeFixture()
        let emptySnapshot = try await empty.cache.snapshot()
        XCTAssertEqual(emptySnapshot.songs, [])
        XCTAssertEqual(emptySnapshot.usage.bytes, 0)
    }

    func testRemovalDeletesAllVariantsButPreservesOtherSongsAndSavedLibraryBytes() async throws {
        let fixture = try opusFixture()
        try fixture.seed(a.id)
        let other = try fixture.seed(b.id)
        let permit = try await fixture.cache.writePermit()
        _ = try await fixture.cache.storeOpus(trackID: a.id, stream: OpusTestSupport.source(), permit: permit,
                                             foreground: false, track: a)
        let libraryDirectory = fixture.root.appendingPathComponent("Library")
        let library = LibraryStore(directory: libraryDirectory)
        library.toggleFavorite(a)
        library.recordListening(track: a, sessionID: UUID(), startedAt: Date().addingTimeInterval(-60), seconds: 45)
        let libraryURL = libraryDirectory.appendingPathComponent(LibraryPersistence.fileName)
        let saved = try Data(contentsOf: libraryURL)
        let player = PlayerController(resolver: fixture.resolver())
        defer { player.pause() }

        let removal = try await player.removeCachedSong(id: a.id)

        XCTAssertEqual(removal?.outcome, .removed)
        XCTAssertEqual(removal?.usage.songCount, 1)
        XCTAssertEqual(removal?.usage.bytes, Int64(try Data(contentsOf: other).count))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.cache.directory.path)
            .contains { $0.hasPrefix(a.id) })
        XCTAssertEqual(try Data(contentsOf: libraryURL), saved)
        let repeated = try await player.removeCachedSong(id: a.id)
        XCTAssertEqual(repeated?.outcome, .notFound)
    }

    func testRemovalKeepsPausedSelectionNextStandbyAndOutgoingCrossfadeFiles() async throws {
        let fixture = try makeFixture()
        let outgoing = try fixture.seed(a.id, seconds: 8)
        let incoming = try fixture.seed(b.id, seconds: 8)
        try fixture.seed(c.id, seconds: 8)
        try fixture.seed(d.id)
        let player = PlayerController(resolver: fixture.resolver())
        defer { player.pause() }
        var settings = PlaybackTransitionSettings()
        settings.crossfadeSeconds = 3
        settings.autoplay = false
        player.apply(settings)
        player.restore(PlaybackSnapshot(queue: [a, b, c]))
        for track in [a, b] {
            let result = try await player.removeCachedSong(id: track.id)
            XCTAssertEqual(result?.outcome, .inUse)
            XCTAssertFalse(player.isPlaying)
        }
        let unused = try await player.removeCachedSong(id: d.id)
        XCTAssertEqual(unused?.outcome, .removed)
        player.togglePlayback()
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.isStandbyReady }
        let standby = try await player.removeCachedSong(id: b.id)
        XCTAssertEqual(standby?.outcome, .inUse)
        try await PlaybackTestSupport.waitUntil(timeout: 12) { player.currentTrack == self.b && player.crossfadeState != nil }
        await fixture.cache.pin(only: [b.id, c.id])
        let result = try await player.removeCachedSong(id: a.id)
        XCTAssertEqual(result?.outcome, .inUse)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outgoing.path))
        XCTAssertEqual(player.currentStreamURL, incoming)
        XCTAssertNil(player.errorMessage)
    }

    func testRemovalDrainsActiveAndQueuedWritersAndRejectsTheirOldPermit() async throws {
        let delayedID = b.id
        let payload = PlaybackTestSupport.audioData(seconds: 1)
        let fixture = try makeFixture(handler: { request in
            CatalogStub(headers: ["Content-Type": "audio/wav", "Content-Length": "\(payload.count)"], data: payload,
                        delay: request.url?.query?.contains("id=\(delayedID)") == true ? 10 : 0)
        })
        try fixture.seed(a.id)
        let permit = try await fixture.cache.writePermit()
        let firstURL = AudioCacheTests.remote(b.id), nextURL = AudioCacheTests.remote(c.id)
        let firstID = b.id, nextID = c.id
        let first = Task { try await fixture.cache.store(trackID: firstID, from: firstURL, stream: ResolvedStream(url: firstURL), permit: permit) }
        defer { first.cancel() }
        try await PlaybackTestSupport.eventually { fixture.mock.state.requests.count == 1 }
        let next = Task { try await fixture.cache.store(trackID: nextID, from: nextURL, stream: ResolvedStream(url: nextURL), permit: permit) }
        defer { next.cancel() }
        try await PlaybackTestSupport.eventually { await fixture.cache.activeWaiterCount == 2 }

        let result = try await fixture.cache.removeSong(id: a.id)

        XCTAssertEqual(result.outcome, .removed)
        XCTAssertEqual(result.usage.pendingDownloads, 0)
        XCTAssertEqual(result.usage.bytes, 0)
        for work in [first, next] {
            do { _ = try await work.value; XCTFail("A retired writer cannot publish") }
            catch { XCTAssertTrue(error is CancellationError) }
        }
        XCTAssertEqual(fixture.mock.state.requests.count, 1)
        do {
            _ = try await fixture.cache.store(trackID: nextID, from: nextURL, stream: ResolvedStream(url: nextURL), permit: permit)
            XCTFail("A pre-removal permit cannot start a later writer")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.cache.directory.path), [])
    }

    func testRemovalWaitsForNativePreparationCleanupAndCannotPublishItsLateVariant() async throws {
        let gate = AppModelRequestGate<URL, OpusNativeAudio.Inspection>()
        let fixture = try opusFixture(preparation: { input, output in
            _ = try await OpusTestSupport.prepare(input: input, output: output)
            return try await gate.receive(output)
        })
        addTeardownBlock { await gate.close() }
        let id = a.id
        try fixture.seed(id)
        let permit = try await fixture.cache.writePermit()
        let writer = Task { try await fixture.cache.storeOpus(trackID: id, stream: OpusTestSupport.source(), permit: permit, foreground: false) }
        defer { writer.cancel() }
        let request = try await gate.request(at: 0)
        let returned = CatalogTestRecorder<Bool>()
        let removal = Task { let result = try await fixture.cache.removeSong(id: id); returned.record(true); return result }
        defer { removal.cancel() }
        try await PlaybackTestSupport.eventually { await gate.cancellations.contains(request.id) }
        XCTAssertTrue(returned.values.isEmpty)
        try await gate.complete(request, with: .success(OpusTestSupport.inspection))
        let result = try await removal.value
        XCTAssertEqual(result.outcome, .removed)
        XCTAssertEqual(result.usage.bytes, 0)
        XCTAssertEqual(result.usage.pendingDownloads, 0)
        do { _ = try await writer.value; XCTFail("The old preparation must not publish") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.cache.directory.path), [])
    }

    func testInventoryCountsActivePreparationBytesButPublishesOnlyCommittedEncodings() async throws {
        let gate = AppModelRequestGate<URL, OpusNativeAudio.Inspection>()
        let fixture = try opusFixture(preparation: { input, output in
            _ = try await OpusTestSupport.prepare(input: input, output: output)
            return try await gate.receive(output)
        })
        addTeardownBlock { await gate.close() }
        let original = try fixture.seed(a.id)
        let originalBytes = Int64(try Data(contentsOf: original).count)
        let id = a.id
        let permit = try await fixture.cache.writePermit()
        let writer = Task { try await fixture.cache.storeOpus(trackID: id, stream: OpusTestSupport.source(), permit: permit, foreground: false) }
        defer { writer.cancel() }
        let request = try await gate.request(at: 0)
        let pending = try await fixture.cache.snapshot()
        XCTAssertEqual(pending.usage.bytes, originalBytes + Int64(OpusTestSupport.webM.count + OpusTestSupport.mp4.count))
        XCTAssertEqual(pending.usage.pendingDownloads, 1)
        XCTAssertEqual(pending.usage.songCount, 1)
        XCTAssertEqual(pending.songs.first?.variantCount, 1)
        XCTAssertEqual(pending.songs.first?.preferredAudio?.url, original)
        try await gate.complete(request, with: .success(OpusTestSupport.inspection))
        let completed = try await writer.value
        let snapshot = try await fixture.cache.snapshot()
        XCTAssertEqual(snapshot.usage.bytes, originalBytes + completed.bytes)
        XCTAssertEqual(snapshot.usage.pendingDownloads, 0)
        XCTAssertEqual(snapshot.songs.first?.variantCount, 2)
        XCTAssertEqual(snapshot.songs.first?.preferredAudio?.url, completed.url)
    }

    func testPlayerSerializesRemovalWithFollowingLimitAndClear() async throws {
        let resolver = InventoryBarrierResolver()
        addTeardownBlock { await resolver.close() }
        let player = PlayerController(resolver: resolver)
        defer { player.pause() }
        let id = a.id
        let remove = Task { try await player.removeCachedSong(id: id) }
        defer { remove.cancel() }
        let removal = try await resolver.removals.request(at: 0)
        let limit = player.setAudioCacheLimit(.mb250)
        let before = await resolver.limits.requests
        XCTAssertTrue(before.isEmpty)
        let original = AudioCache.Usage(bytes: 0, songCount: 0, retainedBytes: 0, retainedSongCount: 0,
                                        capacityBytes: AudioCacheLimit.gb1.bytes, maximumSongs: 200, pendingDownloads: 0)
        try await resolver.removals.complete(removal, with: .success(AudioCacheRemoval(outcome: .removed, usage: original)))
        let removed = try await remove.value
        XCTAssertEqual(removed?.outcome, .removed)
        let updating = try await resolver.limits.request(at: 0)
        XCTAssertEqual(updating.input, .mb250)
        let clear = Task { try await player.clearTemporaryAudioCache() }
        defer { clear.cancel() }
        await Task.yield()
        let pendingClears = await resolver.clears.requests
        XCTAssertTrue(pendingClears.isEmpty)
        let smaller = AudioCache.Usage(bytes: 0, songCount: 0, retainedBytes: 0, retainedSongCount: 0,
                                       capacityBytes: AudioCacheLimit.mb250.bytes, maximumSongs: 50, pendingDownloads: 0)
        try await resolver.limits.complete(updating, with: .success(smaller))
        _ = try await limit.value
        let clearing = try await resolver.clears.request(at: 0)
        try await resolver.clears.complete(clearing, with: .success(smaller))
        let cleared = try await clear.value
        XCTAssertEqual(cleared, smaller)
        XCTAssertFalse(player.isUpdatingAudioCacheLimit)
        XCTAssertNil(player.audioCacheLimitError)
    }

    func testRemovalFencesLatePrefetchExtractionForTheSameRecording() async throws {
        let fixture = try makeFixture()
        let gate = AppModelRequestGate<String, FastPathResult>()
        addTeardownBlock { await gate.close() }
        let resolver = fixture.resolver { try await gate.receive($0) }
        let track = a
        let prefetch = Task { await resolver.prefetch([track]) }
        defer { prefetch.cancel() }
        let request = try await gate.request(at: 0)

        let removal = try await resolver.removeCachedSong(id: track.id) { [] }
        try await gate.complete(request, with: .success(FastPathResult(urls: [AudioCacheTests.remote(track.id)])))
        await prefetch.value
        try await PlaybackTestSupport.eventually { await resolver.activeDownloadCount == 0 }

        XCTAssertEqual(removal?.outcome, .notFound)
        XCTAssertTrue(fixture.mock.state.requests.isEmpty)
        let snapshot = try await resolver.audioCacheSnapshot()
        XCTAssertEqual(snapshot?.songs, [])
    }

    func testReadAndRemovalFailuresAreErrorsAndDoNotClaimAnEmptyCache() async throws {
        let fixture = try makeFixture()
        let media = try fixture.seed(a.id)
        let original = try Data(contentsOf: media)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: fixture.cache.directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.cache.directory.path) }
        do { _ = try await fixture.cache.removeSong(id: a.id); XCTFail("Deletion failure must throw") }
        catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        let snapshot = try await fixture.cache.snapshot()
        XCTAssertEqual(snapshot.usage.bytes, Int64(original.count))
        XCTAssertEqual(try Data(contentsOf: media), original)

        let blocked = try makeFixture()
        try Data("not a directory".utf8).write(to: blocked.cache.directory)
        do { _ = try await blocked.cache.snapshot(); XCTFail("A read error is not empty storage") }
        catch { XCTAssertTrue(error is AudioCache.ManagementError) }
        do { _ = try await blocked.cache.removeSong(id: a.id); XCTFail("A failed scan cannot report notFound") }
        catch { XCTAssertTrue(error is AudioCache.ManagementError) }
    }

    private func makeFixture(handler: CatalogMockState.Handler? = nil) throws -> CacheManagementFixture {
        let fixture = try CacheManagementFixture(handler: handler)
        addTeardownBlock { try await fixture.close() }
        return fixture
    }

    private func opusFixture(preparation: @escaping AudioCache.OpusPreparation = OpusTestSupport.prepare) throws -> CacheManagementFixture {
        let fixture = try CacheManagementFixture(handler: { _ in
            CatalogStub(headers: ["Content-Type": "audio/webm", "Content-Length": "\(OpusTestSupport.webM.count)"], data: OpusTestSupport.webM)
        }, opusPreparation: preparation)
        addTeardownBlock { try await fixture.close() }
        return fixture
    }
}

private actor LegacyInventoryResolver: StreamCacheManaging {
    func audioCacheUsage() -> AudioCache.Usage? { nil }
    func clearAudioCache(retaining: @escaping @Sendable () async -> Set<String>) -> AudioCache.Usage? { nil }
    func retainCached(_ trackIDs: Set<String>) { }
    func discardCached(_ track: Track) { }
    nonisolated func isCachedStream(_ stream: ResolvedStream) -> Bool { false }
    func resolve(track: Track, forceRefresh: Bool) throws -> ResolvedStream { throw PlaybackStreamError.noAudio }
    func download(_ track: Track) throws -> ResolvedStream { throw PlaybackStreamError.noAudio }
}

private actor InventoryBarrierResolver: StreamCacheManaging {
    let removals = AppModelRequestGate<String, AudioCacheRemoval?>()
    let limits = AppModelRequestGate<AudioCacheLimit, AudioCache.Usage?>()
    let clears = AppModelRequestGate<String, AudioCache.Usage?>()

    func removeCachedSong(id: String, retaining: @escaping @Sendable () async -> Set<String>) async throws -> AudioCacheRemoval? {
        _ = await retaining()
        return try await removals.receive(id)
    }
    func setAudioCacheLimit(_ limit: AudioCacheLimit, retaining: @escaping @Sendable () async -> Set<String>) async throws -> AudioCache.Usage? {
        try await limits.receive(limit)
    }
    func clearAudioCache(retaining: @escaping @Sendable () async -> Set<String>) async throws -> AudioCache.Usage? {
        try await clears.receive("clear")
    }
    func close() async {
        await removals.close()
        await limits.close()
        await clears.close()
    }
    func audioCacheUsage() -> AudioCache.Usage? { nil }
    func retainCached(_ trackIDs: Set<String>) { }
    func discardCached(_ track: Track) { }
    nonisolated func isCachedStream(_ stream: ResolvedStream) -> Bool { false }
    func resolve(track: Track, forceRefresh: Bool) throws -> ResolvedStream { throw PlaybackStreamError.noAudio }
    func download(_ track: Track) throws -> ResolvedStream { throw PlaybackStreamError.noAudio }
}

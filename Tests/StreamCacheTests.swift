import XCTest
@testable import GanaBajana

/// `YouTubeStreamResolver` over an `AudioCache` fed by the mock URL protocol: cache-first resolution, `download`,
/// prefetch downloads, and discarding.
final class StreamCacheTests: XCTestCase {
    private let a = Track(id: "fsiPzT50ZiM", title: "A", duration: 200)
    private let b = Track(id: "NJAv_7lHUIU", title: "B")
    private let c = Track(id: "J7p4bzqLvCw", title: "C")
    private var directories: [URL] = []
    private var mocks: [CatalogMockSession] = []

    override func tearDown() async throws {
        for mock in mocks { mock.close() }
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        mocks.removeAll()
        directories.removeAll()
    }

    func testResolveReturnsTheCachedFileBeforeAnyNetworkEvenWhenForced() async throws {
        let payload = PlaybackTestSupport.audioData(seconds: 1)
        let (cache, _) = try makeCache(delay: 0, payload: payload)
        let remote = AudioCacheTests.remote(a.id)
        _ = try await cache.store(trackID: a.id, from: remote, stream: ResolvedStream(url: remote, duration: 261.9, loudnessDb: 3, viewCount: 42))
        let recorder = CatalogTestRecorder<String>()
        let resolver = YouTubeStreamResolver(extract: { id, _ in recorder.record(id); return [AudioCacheTests.remote(id)] },
                                             validate: { _ in recorder.record("validate") }, audioCache: cache)
        for forced in [false, true] {
            let stream = try await resolver.resolve(track: a, forceRefresh: forced)
            XCTAssertTrue(stream.url.isFileURL)
            XCTAssertEqual(stream.duration, 261.9, "The sidecar duration wins over the catalog's")
            XCTAssertEqual(stream.loudnessDb, 3)
            XCTAssertEqual(stream.viewCount, 42)
            XCTAssertNil(stream.expiresAt)
            XCTAssertTrue(resolver.isCachedStream(stream))
        }
        XCTAssertTrue(recorder.values.isEmpty, "No extraction or validation happens for a cached track")
        XCTAssertFalse(resolver.isCachedStream(ResolvedStream(url: remote)))
        XCTAssertFalse(resolver.isCachedStream(ResolvedStream(url: FileManager.default.temporaryDirectory.appendingPathComponent("x.m4a"))),
                       "Local files outside the cache directory are not cache entries")

        let download = try await resolver.download(a)
        XCTAssertTrue(download.url.isFileURL)
        XCTAssertTrue(recorder.values.isEmpty, "Downloading an already cached track is a no-op")
    }

    func testDownloadResolvesStoresAndLaterResolutionsUseTheFile() async throws {
        let payload = PlaybackTestSupport.audioData(seconds: 1)
        let (cache, mock) = try makeCache(delay: 0, payload: payload)
        let recorder = CatalogTestRecorder<String>()
        let resolver = YouTubeStreamResolver(extract: { id, _ in recorder.record(id); return [AudioCacheTests.remote(id)] },
                                             validate: { _ in }, fastExtract: { id in
                                                 recorder.record("fast-" + id)
                                                 return FastPathResult(urls: [AudioCacheTests.remote(id)], loudnessDb: 2.5, viewCount: 9)
                                             }, audioCache: cache)
        let downloaded = try await resolver.download(a)
        XCTAssertTrue(downloaded.url.isFileURL)
        XCTAssertEqual(downloaded.duration, 8, "The googlevideo `dur` travels into the sidecar")
        XCTAssertEqual(downloaded.loudnessDb, 2.5)
        XCTAssertEqual(downloaded.viewCount, 9)
        XCTAssertEqual(recorder.values, ["fast-" + a.id], "Downloads use the fast path, never the serialized extractor")
        XCTAssertEqual(mock.state.requests.count, 1)
        let stored = await cache.entry(for: a.id)
        let entry = try XCTUnwrap(stored)
        XCTAssertEqual(entry.bytes, Int64(payload.count))

        let again = try await resolver.resolve(track: a, forceRefresh: true)
        XCTAssertEqual(again.url, downloaded.url)
        XCTAssertEqual(recorder.values.count, 1)

        await resolver.discardCached(a)
        let discarded = await cache.entry(for: a.id)
        XCTAssertNil(discarded)
        let remote = try await resolver.resolve(track: a, forceRefresh: true)
        XCTAssertFalse(remote.url.isFileURL, "After a discard the resolver goes back to the network")
        XCTAssertEqual(recorder.values, ["fast-" + a.id, "fast-" + a.id])
    }

    func testDownloadIsUnavailableWithoutACache() async {
        let resolver = YouTubeStreamResolver(extract: { id, _ in [AudioCacheTests.remote(id)] }, validate: { _ in })
        do { _ = try await resolver.download(a); XCTFail("No cache, no download") }
        catch { XCTAssertTrue(error is MusicServiceError) }
        XCTAssertFalse(resolver.isCachedStream(ResolvedStream(url: FileManager.default.temporaryDirectory)))
        await resolver.prefetch([a])
        let pending = await resolver.prefetchDownloadTrackID
        XCTAssertNil(pending)
    }

    func testPrefetchDownloadsOnlyTheFirstTrackAndANewerFirstTrackReplacesIt() async throws {
        let payload = PlaybackTestSupport.audioData(seconds: 1)
        let (cache, mock) = try makeCache(delay: 0.6, payload: payload)
        let resolver = YouTubeStreamResolver(extract: { id, _ in [AudioCacheTests.remote(id)] }, validate: { _ in },
                                             fastExtract: { FastPathResult(urls: [AudioCacheTests.remote($0)]) }, audioCache: cache)
        await resolver.prefetch([a, b])
        let started = await resolver.prefetchDownloadTrackID
        XCTAssertEqual(started, a.id)
        try await PlaybackTestSupport.eventually { mock.state.requests.count == 1 }
        XCTAssertTrue(mock.state.requests[0].url?.query?.contains("id=\(a.id)") == true, "Only the first track is downloaded")

        await resolver.prefetch([c, a])
        try await PlaybackTestSupport.eventually { mock.state.cancellations == 1 }
        let replaced = await resolver.prefetchDownloadTrackID
        XCTAssertEqual(replaced, c.id, "A newer first track cancels the previous download")
        try await PlaybackTestSupport.eventually { mock.state.requests.count == 2 }
        XCTAssertTrue(mock.state.requests[1].url?.query?.contains("id=\(c.id)") == true)

        await resolver.prefetch([])
        let kept = await resolver.prefetchDownloadTrackID
        XCTAssertEqual(kept, c.id, "An empty prefetch leaves the running download alone")
        await resolver.prefetch([c, b])
        XCTAssertEqual(mock.state.cancellations, 1, "Re-naming the same first track does not restart it")

        let cID = c.id
        try await PlaybackTestSupport.eventually(timeout: 5) { await cache.entry(for: cID) != nil }
        try await PlaybackTestSupport.eventually { await resolver.prefetchDownloadTrackID == nil }
        let aEntry = await cache.entry(for: a.id)
        XCTAssertNil(aEntry)
        let bEntry = await cache.entry(for: b.id)
        XCTAssertNil(bEntry)
        XCTAssertEqual(mock.state.requests.count, 2)
    }

    func testDownloadWaitsForAForegroundResolutionToFinish() async throws {
        let payload = PlaybackTestSupport.audioData(seconds: 1)
        let (cache, mock) = try makeCache(delay: 0, payload: payload)
        let gate = ForegroundGate()
        let held = c.id
        let resolver = YouTubeStreamResolver(extract: { id, _ in [AudioCacheTests.remote(id)] }, validate: { _ in },
                                             fastExtract: { id in
                                                 if id == held { try await gate.wait() }
                                                 return FastPathResult(urls: [AudioCacheTests.remote(id)])
                                             }, audioCache: cache)
        let (a, c) = (a, c)
        let foreground = Task { try await resolver.resolve(track: c, forceRefresh: false) }
        try await PlaybackTestSupport.eventually { await gate.waiting }
        let download = Task(priority: .utility) { try await resolver.download(a) }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(mock.state.requests.count, 0, "Nothing downloads while the listener's resolution is in flight")
        await gate.open()
        _ = try await foreground.value
        let stream = try await download.value
        XCTAssertTrue(stream.url.isFileURL)
        XCTAssertEqual(mock.state.requests.count, 1)
        let aCached = await cache.entry(for: a.id)
        XCTAssertNotNil(aCached)
    }

    // MARK: - Helpers

    private actor ForegroundGate {
        private(set) var waiting = false
        private var continuation: CheckedContinuation<Void, Error>?
        func wait() async throws {
            waiting = true
            try await withCheckedThrowingContinuation { continuation = $0 }
        }
        func open() {
            continuation?.resume()
            continuation = nil
        }
    }

    private func makeCache(delay: TimeInterval, payload: Data) throws -> (AudioCache, CatalogMockSession) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GanaBajanaStreamCacheTests-\(UUID())", isDirectory: true)
        directories.append(directory)
        let mock = CatalogMockSession { _ in
            CatalogStub(headers: ["Content-Type": "audio/wav", "Content-Length": "\(payload.count)"], data: payload, delay: delay)
        }
        mocks.append(mock)
        return (AudioCache(directory: directory, session: mock.session), mock)
    }
}

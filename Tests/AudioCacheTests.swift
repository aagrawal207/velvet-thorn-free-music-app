import XCTest
@testable import GanaBajana

final class AudioCacheTests: XCTestCase {
    private let a = "fsiPzT50ZiM"
    private let b = "NJAv_7lHUIU"
    private let c = "J7p4bzqLvCw"
    private var directories: [URL] = []
    private var mocks: [CatalogMockSession] = []

    override func tearDown() async throws {
        for mock in mocks { mock.close() }
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        mocks.removeAll()
        directories.removeAll()
    }

    // MARK: - Store and read back

    func testStoreVerifiesTheDeclaredLengthWritesTheSidecarAndEntryReadsItBack() async throws {
        let payload = PlaybackTestSupport.audioData(seconds: 2)
        let cache = try makeCache(serving: { _ in Self.wav(payload) })
        let remote = Self.remote(a)
        let stored = try await cache.store(trackID: a, from: remote, stream: ResolvedStream(url: remote, duration: 2, loudnessDb: 4.5, viewCount: 777))
        XCTAssertEqual(stored.bytes, Int64(payload.count))
        XCTAssertEqual(stored.url.pathExtension, "wav", "The file extension follows the served media type")
        XCTAssertEqual(try Data(contentsOf: stored.url), payload)

        let readBack = await cache.entry(for: a)
        let entry = try XCTUnwrap(readBack)
        XCTAssertEqual(entry, stored)
        XCTAssertEqual(entry.duration, 2)
        XCTAssertEqual(entry.loudnessDb, 4.5)
        XCTAssertEqual(entry.viewCount, 777)
        XCTAssertNil(entry.stream.expiresAt, "A complete local file never expires")
        XCTAssertTrue(entry.stream.url.isFileURL)
        let total = await cache.totalBytes
        XCTAssertEqual(total, Int64(payload.count))

        let sidecar = try JSONSerialization.jsonObject(with: Data(contentsOf: cache.directory.appendingPathComponent("\(a).json"))) as? [String: Any]
        XCTAssertEqual(Set(try XCTUnwrap(sidecar).keys), ["duration", "loudnessDb", "viewCount", "bytes", "storedAt", "fileExtension"])
        XCTAssertEqual(sidecar?["bytes"] as? Int, payload.count)
        let missing = await cache.entry(for: b)
        XCTAssertNil(missing)
        let escaped = await cache.entry(for: "../escape")
        XCTAssertNil(escaped, "Only identifier-safe track IDs are ever looked up")
    }

    func testStoringATrackAlreadyOnDiskDoesNotDownloadAgain() async throws {
        let payload = PlaybackTestSupport.audioData(seconds: 1)
        let (cache, mock) = try makeCacheAndMock(serving: { _ in Self.wav(payload) })
        _ = try await cache.store(trackID: a, from: Self.remote(a), stream: ResolvedStream(url: Self.remote(a)))
        _ = try await cache.store(trackID: a, from: Self.remote(a), stream: ResolvedStream(url: Self.remote(a)))
        XCTAssertEqual(mock.state.requests.count, 1)
    }

    // MARK: - Rejections

    func testTruncatedResponseIsRejectedAndLeavesNothingBehind() async throws {
        let payload = PlaybackTestSupport.audioData(seconds: 1)
        let cache = try makeCache(serving: { _ in
            CatalogStub(headers: ["Content-Type": "audio/wav", "Content-Length": "\(payload.count + 4_000)"], data: payload)
        })
        do {
            _ = try await cache.store(trackID: a, from: Self.remote(a), stream: ResolvedStream(url: Self.remote(a)))
            XCTFail("A short body must not be cached")
        } catch {
            XCTAssertTrue(error is PlaybackStreamError || error is MusicServiceError, "\(error)")
        }
        let truncated = await cache.entry(for: a)
        XCTAssertNil(truncated)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.directory.path), [], "No partial file or sidecar remains")
    }

    func testDeclaredLengthFallsBackToTheGooglevideoClenParameter() async throws {
        let payload = PlaybackTestSupport.audioData(seconds: 1)
        let cache = try makeCache(serving: { _ in CatalogStub(headers: ["Content-Type": "audio/wav"], data: payload) })
        let exact = Self.remote(a, clen: payload.count)
        let stored = try await cache.store(trackID: a, from: exact, stream: ResolvedStream(url: exact))
        XCTAssertEqual(stored.bytes, Int64(payload.count))

        let wrong = Self.remote(b, clen: payload.count - 1)
        do { _ = try await cache.store(trackID: b, from: wrong, stream: ResolvedStream(url: wrong)); XCTFail("A clen mismatch must be rejected") }
        catch { XCTAssertTrue(error is PlaybackStreamError, "\(error)") }
        let unknown = Self.remote(c)
        do { _ = try await cache.store(trackID: c, from: unknown, stream: ResolvedStream(url: unknown)); XCTFail("Without any declared length completeness cannot be verified") }
        catch { XCTAssertTrue(error is PlaybackStreamError, "\(error)") }
    }

    func testNonMediaAndErrorResponsesAreRejected() async throws {
        let html = Data("<html>blocked</html>".utf8)
        let forbidden = b
        let cache = try makeCache(serving: { request in
            if request.url?.query?.contains("id=\(forbidden)") == true {
                return CatalogStub(status: 403, headers: ["Content-Type": "audio/wav", "Content-Length": "\(html.count)"], data: html)
            }
            return CatalogStub(headers: ["Content-Type": "text/html", "Content-Length": "\(html.count)"], data: html)
        })
        do { _ = try await cache.store(trackID: a, from: Self.remote(a), stream: ResolvedStream(url: Self.remote(a))); XCTFail("HTML is not audio") }
        catch { XCTAssertTrue(error is PlaybackStreamError) }
        do { _ = try await cache.store(trackID: b, from: Self.remote(b), stream: ResolvedStream(url: Self.remote(b))); XCTFail("403 is not audio") }
        catch let error as PlaybackStreamError {
            guard case .httpStatus(403) = error else { return XCTFail("\(error)") }
        }
        let riffless = Data(repeating: 0, count: 64)
        let junk = try makeCache(serving: { _ in Self.wav(riffless) })
        do { _ = try await junk.store(trackID: c, from: Self.remote(c), stream: ResolvedStream(url: Self.remote(c))); XCTFail("A WAV without a RIFF header is not media") }
        catch { XCTAssertTrue(error is PlaybackStreamError) }
        let count = await cache.count
        XCTAssertEqual(count, 0)
    }

    func testOnDiskSizeMismatchInvalidatesTheEntryAndDeletesThePair() async throws {
        let payload = PlaybackTestSupport.audioData(seconds: 1)
        let cache = try makeCache(serving: { _ in Self.wav(payload) })
        let stored = try await cache.store(trackID: a, from: Self.remote(a), stream: ResolvedStream(url: Self.remote(a)))
        try payload.prefix(payload.count / 2).write(to: stored.url, options: .atomic)
        let shrunk = await cache.entry(for: a)
        XCTAssertNil(shrunk, "A file that shrank under us is not complete")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.directory.path), [])
        let total = await cache.totalBytes
        XCTAssertEqual(total, 0)
    }

    // MARK: - Eviction and pinning

    func testLRUEvictionRespectsAccessOrderPinsAndTheFileLimit() async throws {
        let payload = PlaybackTestSupport.audioData(seconds: 1)
        let cache = try makeCache(capacityBytes: Int64(payload.count) * 2 + 10, maximumFiles: 10, serving: { _ in Self.wav(payload) })
        for id in [a, b] { _ = try await cache.store(trackID: id, from: Self.remote(id), stream: ResolvedStream(url: Self.remote(id))) }
        try await Task.sleep(for: .milliseconds(30))
        _ = await cache.entry(for: a)
        _ = try await cache.store(trackID: c, from: Self.remote(c), stream: ResolvedStream(url: Self.remote(c)))
        let refreshedA = await cache.entry(for: a)
        XCTAssertNotNil(refreshedA, "Reading a refreshed its access date")
        let evictedB = await cache.entry(for: b)
        XCTAssertNil(evictedB, "The least recently used entry goes first")
        let storedC = await cache.entry(for: c)
        XCTAssertNotNil(storedC)

        await cache.pin(c)
        try await Task.sleep(for: .milliseconds(30))
        _ = await cache.entry(for: a)
        _ = try await cache.store(trackID: b, from: Self.remote(b), stream: ResolvedStream(url: Self.remote(b)))
        let pinnedC = await cache.entry(for: c)
        XCTAssertNotNil(pinnedC, "Pinned entries are never evicted")
        let evictedA = await cache.entry(for: a)
        XCTAssertNil(evictedA, "The oldest unpinned entry goes instead")
        await cache.unpin(c)

        let limited = try makeCache(capacityBytes: 1 << 30, maximumFiles: 1, serving: { _ in Self.wav(payload) })
        for id in [a, b] { _ = try await limited.store(trackID: id, from: Self.remote(id), stream: ResolvedStream(url: Self.remote(id))) }
        let limitedCount = await limited.count
        XCTAssertEqual(limitedCount, 1)
        let limitedA = await limited.entry(for: a)
        XCTAssertNil(limitedA)
        let limitedB = await limited.entry(for: b)
        XCTAssertNotNil(limitedB)
    }

    func testRemoveAndRemoveAllDeleteFilesAndSidecars() async throws {
        let payload = PlaybackTestSupport.audioData(seconds: 1)
        let cache = try makeCache(serving: { _ in Self.wav(payload) })
        for id in [a, b] { _ = try await cache.store(trackID: id, from: Self.remote(id), stream: ResolvedStream(url: Self.remote(id))) }
        await cache.remove(trackID: a)
        let removedA = await cache.entry(for: a)
        XCTAssertNil(removedA)
        let keptB = await cache.entry(for: b)
        XCTAssertNotNil(keptB)
        await cache.removeAll()
        let emptied = await cache.count
        XCTAssertEqual(emptied, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.directory.path), [])
    }

    func testLeftoversFromInterruptedDownloadsArePrunedAfterTheNextStore() async throws {
        let payload = PlaybackTestSupport.audioData(seconds: 1)
        let cache = try makeCache(serving: { _ in Self.wav(payload) })
        try FileManager.default.createDirectory(at: cache.directory, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: cache.directory.appendingPathComponent("\(b)-\(UUID().uuidString).part"))
        try payload.write(to: cache.directory.appendingPathComponent("\(c).m4a"))
        _ = try await cache.store(trackID: a, from: Self.remote(a), stream: ResolvedStream(url: Self.remote(a)))
        let names = try FileManager.default.contentsOfDirectory(atPath: cache.directory.path).sorted()
        XCTAssertEqual(names, ["\(a).json", "\(a).wav"], "A stale part file and a media file without a sidecar are gone")
        let orphan = await cache.entry(for: c)
        XCTAssertNil(orphan)
    }

    // MARK: - Concurrency

    func testConcurrentStoresShareOneDownloadAndDifferentTracksDownloadOneAtATime() async throws {
        let payload = PlaybackTestSupport.audioData(seconds: 1)
        let (cache, mock) = try makeCacheAndMock(serving: { _ in
            var stub = Self.wav(payload)
            stub.delay = 0.4
            return stub
        })
        let (a, b) = (a, b)
        let first = Task { try await cache.store(trackID: a, from: Self.remote(a), stream: ResolvedStream(url: Self.remote(a))) }
        let second = Task { try await cache.store(trackID: a, from: Self.remote(a), stream: ResolvedStream(url: Self.remote(a))) }
        let other = Task { try await cache.store(trackID: b, from: Self.remote(b), stream: ResolvedStream(url: Self.remote(b))) }
        try await PlaybackTestSupport.eventually { await cache.downloadingTrackID != nil }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(mock.state.requests.count, 1, "Only one request is in flight: the two A waiters share it and B waits")
        let waiters = await cache.activeWaiterCount
        XCTAssertEqual(waiters, 3)
        let one = try await first.value
        let two = try await second.value
        XCTAssertEqual(one, two)
        _ = try await other.value
        XCTAssertEqual(mock.state.requests.count, 2)
        let stored = await cache.count
        XCTAssertEqual(stored, 2)
        let remaining = await cache.activeWaiterCount
        XCTAssertEqual(remaining, 0)
        let downloading = await cache.downloadingTrackID
        XCTAssertNil(downloading)
    }

    func testCancellingTheOnlyWaiterStopsTheDownloadAndKeepsTheDiskClean() async throws {
        let payload = PlaybackTestSupport.audioData(seconds: 1)
        let (cache, mock) = try makeCacheAndMock(serving: { _ in
            var stub = Self.wav(payload)
            stub.delay = 3
            return stub
        })
        let a = a
        let work = Task { try await cache.store(trackID: a, from: Self.remote(a), stream: ResolvedStream(url: Self.remote(a))) }
        try await PlaybackTestSupport.eventually { mock.state.requests.count == 1 }
        work.cancel()
        do { _ = try await work.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        try await PlaybackTestSupport.eventually { mock.state.cancellations == 1 }
        let cancelled = await cache.entry(for: a)
        XCTAssertNil(cancelled)
        let waitersAfterCancel = await cache.activeWaiterCount
        XCTAssertEqual(waitersAfterCancel, 0)
        try await PlaybackTestSupport.eventually { await cache.downloadingTrackID == nil }
        try await PlaybackTestSupport.eventually { (try? FileManager.default.contentsOfDirectory(atPath: cache.directory.path))?.isEmpty == true }
    }

    func testCancellingOneOfTwoWaitersKeepsTheDownloadRunning() async throws {
        let payload = PlaybackTestSupport.audioData(seconds: 1)
        let (cache, mock) = try makeCacheAndMock(serving: { _ in
            var stub = Self.wav(payload)
            stub.delay = 0.4
            return stub
        })
        let a = a
        let first = Task { try await cache.store(trackID: a, from: Self.remote(a), stream: ResolvedStream(url: Self.remote(a))) }
        let second = Task { try await cache.store(trackID: a, from: Self.remote(a), stream: ResolvedStream(url: Self.remote(a))) }
        try await PlaybackTestSupport.eventually { await cache.activeWaiterCount == 2 }
        first.cancel()
        do { _ = try await first.value; XCTFail("Expected cancellation") } catch { }
        let stored = try await second.value
        XCTAssertEqual(stored.bytes, Int64(payload.count))
        XCTAssertEqual(mock.state.cancellations, 0)
        XCTAssertEqual(mock.state.requests.count, 1)
    }

    // MARK: - Helpers

    private func makeCache(capacityBytes: Int64 = 200 << 20, maximumFiles: Int = 40,
                           serving handler: @escaping CatalogMockState.Handler) throws -> AudioCache {
        try makeCacheAndMock(capacityBytes: capacityBytes, maximumFiles: maximumFiles, serving: handler).0
    }

    private func makeCacheAndMock(capacityBytes: Int64 = 200 << 20, maximumFiles: Int = 40,
                                  serving handler: @escaping CatalogMockState.Handler) throws -> (AudioCache, CatalogMockSession) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GanaBajanaAudioCacheTests-\(UUID())", isDirectory: true)
        directories.append(directory)
        let mock = CatalogMockSession(handler: handler)
        mocks.append(mock)
        return (AudioCache(directory: directory, capacityBytes: capacityBytes, maximumFiles: maximumFiles, session: mock.session), mock)
    }

    private static func wav(_ payload: Data) -> CatalogStub {
        CatalogStub(headers: ["Content-Type": "audio/wav", "Content-Length": "\(payload.count)"], data: payload)
    }

    static func remote(_ id: String, clen: Int? = nil) -> URL {
        var text = "https://audio.googlevideo.com/videoplayback?id=\(id)&dur=8&expire=4000000000"
        if let clen { text += "&clen=\(clen)" }
        return URL(string: text)!
    }
}

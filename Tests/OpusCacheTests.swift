import XCTest
@testable import GanaBajana

@MainActor
final class OpusCacheTests: XCTestCase {
    func testPreparedVariantsAreImmutableAndUsageCountsLogicalSongsAndEveryEncoding() async throws {
        let fixture = try makeFixture()
        let id = OpusTestSupport.track.id
        let original = try fixture.seed(id)
        let originalBytes = try Data(contentsOf: original)
        await fixture.cache.pin(id)
        let permit = try await fixture.cache.writePermit()
        let first = try await fixture.cache.storeOpus(trackID: id, stream: OpusTestSupport.source(), permit: permit, foreground: true)
        let second = try await fixture.cache.storeOpus(trackID: id, stream: OpusTestSupport.source(rate: 256_000), permit: permit, foreground: true)
        XCTAssertNotEqual(first.url, second.url)
        XCTAssertEqual(first.trackID, id)
        XCTAssertEqual(AudioCache.logicalTrackID(for: second.url), id)
        XCTAssertEqual(try Data(contentsOf: original), originalBytes)
        XCTAssertEqual(try Data(contentsOf: first.url), OpusTestSupport.mp4)
        let preferred = await fixture.cache.entry(for: id)
        XCTAssertEqual(preferred?.url, second.url)
        XCTAssertEqual(preferred?.quality?.bitRate, 256_000)
        let legacy = await fixture.cache.entry(for: id, allowOpus: false)
        XCTAssertEqual(legacy?.url, original)
        let usage = try await fixture.cache.storageUsage()
        XCTAssertEqual(usage.songCount, 1)
        XCTAssertEqual(usage.retainedSongCount, 1)
        XCTAssertEqual(usage.bytes, Int64(originalBytes.count + 2 * OpusTestSupport.mp4.count))
        XCTAssertEqual(usage.retainedBytes, usage.bytes)

        let reused = try await fixture.cache.storeOpus(trackID: id, stream: OpusTestSupport.source(), permit: permit, foreground: true)
        XCTAssertEqual(reused.url, second.url)
        XCTAssertEqual(fixture.mock.state.requests.count, 2)
        do {
            _ = try await fixture.cache.storeOpus(trackID: id, stream: OpusTestSupport.source(rate: 320_000), permit: permit, foreground: true)
            XCTFail("Pinned encodings must not be replaced to make room for a third variant")
        } catch { XCTAssertTrue(error is OpusPreparationError) }
        XCTAssertEqual(fixture.mock.state.requests.count, 2)

        let reduced = try await fixture.cache.updatePolicy(capacityBytes: 1, maximumFiles: 1)
        XCTAssertEqual(reduced.bytes, usage.bytes)
        XCTAssertEqual(reduced.retainedBytes, usage.bytes)
        await fixture.cache.pin(only: [])
        let cleared = try await fixture.cache.clearUnused()
        XCTAssertEqual(cleared.bytes, 0)
        XCTAssertEqual(cleared.songCount, 0)
    }

    func testActivePreparationBytesAreReportedButNotExposedAsPlayableEntries() async throws {
        let gate = AppModelRequestGate<URL, OpusNativeAudio.Inspection>()
        let fixture = try makeFixture(preparation: { input, output in
            _ = try await OpusTestSupport.prepare(input: input, output: output)
            return try await gate.receive(output)
        })
        addTeardownBlock { await gate.close() }
        let permit = try await fixture.cache.writePermit()
        let work = Task { try await fixture.cache.storeOpus(trackID: OpusTestSupport.track.id,
                            stream: OpusTestSupport.source(), permit: permit, foreground: true) }
        defer { work.cancel() }
        let request = try await gate.request(at: 0)
        let pending = try await fixture.cache.storageUsage()
        XCTAssertEqual(pending.bytes, Int64(OpusTestSupport.webM.count + OpusTestSupport.mp4.count))
        XCTAssertEqual(pending.songCount, 0)
        XCTAssertEqual(pending.pendingDownloads, 1)
        let unavailable = await fixture.cache.entry(for: OpusTestSupport.track.id)
        XCTAssertNil(unavailable)
        try await gate.complete(request, with: .success(OpusTestSupport.inspection))
        let stored = try await work.value
        let completed = try await fixture.cache.storageUsage()
        XCTAssertEqual(completed.bytes, stored.bytes)
        XCTAssertEqual(completed.pendingDownloads, 0)
        XCTAssertEqual(completed.songCount, 1)
    }

    func testClearDrainsCancelledPreparationAndRejectsStalePermitsWithoutTouchingPinnedAAC() async throws {
        let gate = AppModelRequestGate<URL, OpusNativeAudio.Inspection>()
        let fixture = try makeFixture(preparation: { input, output in
            _ = try await OpusTestSupport.prepare(input: input, output: output)
            return try await gate.receive(output)
        })
        addTeardownBlock { await gate.close() }
        let id = OpusTestSupport.track.id
        let original = try fixture.seed(id)
        let originalBytes = try Data(contentsOf: original)
        await fixture.cache.pin(id)
        let permit = try await fixture.cache.writePermit()
        let work = Task { try await fixture.cache.storeOpus(trackID: id, stream: OpusTestSupport.source(), permit: permit, foreground: true) }
        defer { work.cancel() }
        let request = try await gate.request(at: 0)
        let returned = CatalogTestRecorder<Bool>()
        let clear = Task { let value = try await fixture.cache.clearUnused(); returned.record(true); return value }
        try await PlaybackTestSupport.eventually { await gate.cancellations.contains(request.id) }
        XCTAssertTrue(returned.values.isEmpty, "Clear must wait for the native operation and its file cleanup")
        try await gate.complete(request, with: .success(OpusTestSupport.inspection))
        let usage = try await clear.value
        do { _ = try await work.value; XCTFail("A stale operation must not publish a variant") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(usage.bytes, Int64(originalBytes.count))
        XCTAssertEqual(usage.songCount, 1)
        XCTAssertEqual(usage.pendingDownloads, 0)
        XCTAssertEqual(try Data(contentsOf: original), originalBytes)
        let files = try FileManager.default.contentsOfDirectory(atPath: fixture.cache.directory.path)
        XCTAssertFalse(files.contains { $0.contains(".opus-") || $0.hasSuffix(".part") })
        do {
            _ = try await fixture.cache.storeOpus(trackID: id, stream: OpusTestSupport.source(), permit: permit, foreground: true)
            XCTFail("The pre-clear write permit is invalid")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testResizeCancelsPreparationBeforeApplyingTheSmallerBudget() async throws {
        let gate = AppModelRequestGate<URL, OpusNativeAudio.Inspection>()
        let fixture = try makeFixture(preparation: { input, output in
            _ = try await OpusTestSupport.prepare(input: input, output: output)
            return try await gate.receive(output)
        })
        addTeardownBlock { await gate.close() }
        let id = OpusTestSupport.track.id
        let original = try fixture.seed(id)
        let bytes = Int64(try Data(contentsOf: original).count)
        await fixture.cache.pin(id)
        let permit = try await fixture.cache.writePermit()
        let work = Task { try await fixture.cache.storeOpus(trackID: id, stream: OpusTestSupport.source(), permit: permit, foreground: false) }
        defer { work.cancel() }
        let request = try await gate.request(at: 0)
        let resize = Task { try await fixture.cache.updatePolicy(capacityBytes: bytes, maximumFiles: 1) }
        try await PlaybackTestSupport.eventually { await gate.cancellations.contains(request.id) }
        try await gate.complete(request, with: .failure(URLError(.cancelled)))
        let result = try await resize.value
        XCTAssertEqual(result.capacityBytes, bytes)
        XCTAssertEqual(result.bytes, bytes)
        XCTAssertEqual(result.pendingDownloads, 0)
        do { _ = try await work.value; XCTFail("The old preparation was cancelled") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testPreparedQualitiesUseDistinctFlightsAndAllWritesRemainSerialized() async throws {
        let gate = AppModelRequestGate<URL, OpusNativeAudio.Inspection>()
        let fixture = try makeFixture(preparation: { input, output in
            _ = try await OpusTestSupport.prepare(input: input, output: output)
            return try await gate.receive(output)
        })
        addTeardownBlock { await gate.close() }
        let permit = try await fixture.cache.writePermit()
        let id = OpusTestSupport.track.id
        let first = Task { try await fixture.cache.storeOpus(trackID: id, stream: OpusTestSupport.source(), permit: permit, foreground: true) }
        let request = try await gate.request(at: 0)
        let higher = Task { try await fixture.cache.storeOpus(trackID: id, stream: OpusTestSupport.source(rate: 256_000), permit: permit, foreground: true) }
        defer { first.cancel(); higher.cancel() }
        try await PlaybackTestSupport.eventually { await fixture.cache.activeWaiterCount == 2 }
        XCTAssertEqual(fixture.mock.state.requests.count, 1)
        try await gate.complete(request, with: .success(OpusTestSupport.inspection))
        let savedFirst = try await first.value
        let secondRequest = try await gate.request(at: 1)
        try await gate.complete(secondRequest, with: .success(OpusTestSupport.inspection))
        let savedHigher = try await higher.value
        XCTAssertNotEqual(savedFirst.url, savedHigher.url)
        XCTAssertEqual(savedHigher.quality?.bitRate, 256_000)
        XCTAssertEqual(fixture.mock.state.requests.count, 2)
    }

    func testCancellingOneWaiterReturnsPromptlyAndDoesNotCancelTheOtherOwner() async throws {
        let gate = AppModelRequestGate<URL, OpusNativeAudio.Inspection>()
        let fixture = try makeFixture(preparation: { input, output in
            _ = try await OpusTestSupport.prepare(input: input, output: output)
            return try await gate.receive(output)
        })
        addTeardownBlock { await gate.close() }
        let permit = try await fixture.cache.writePermit()
        let id = OpusTestSupport.track.id
        let first = Task { try await fixture.cache.storeOpus(trackID: id, stream: OpusTestSupport.source(), permit: permit, foreground: false) }
        let request = try await gate.request(at: 0)
        let second = Task { try await fixture.cache.storeOpus(trackID: id, stream: OpusTestSupport.source(), permit: permit, foreground: true) }
        defer { first.cancel(); second.cancel() }
        try await PlaybackTestSupport.eventually { await fixture.cache.activeWaiterCount == 2 }
        first.cancel()
        do { _ = try await first.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let cancellations = await gate.cancellations
        XCTAssertTrue(cancellations.isEmpty)
        try await gate.complete(request, with: .success(OpusTestSupport.inspection))
        _ = try await second.value
        XCTAssertEqual(fixture.mock.state.requests.count, 1)
    }

    func testForegroundPreparationPreemptsABackgroundOriginalDownload() async throws {
        let fixture = try CacheManagementFixture(handler: { request in
            if request.url?.query?.contains("id=background") == true {
                let wave = PlaybackTestSupport.audioData(seconds: 1)
                return CatalogStub(headers: ["Content-Type": "audio/wav", "Content-Length": "\(wave.count)"], data: wave, delay: 10)
            }
            return CatalogStub(headers: ["Content-Type": "audio/webm", "Content-Length": "\(OpusTestSupport.webM.count)"], data: OpusTestSupport.webM)
        }, opusPreparation: OpusTestSupport.prepare)
        addTeardownBlock { try await fixture.close() }
        let url = AudioCacheTests.remote("background")
        let background = Task { try await fixture.cache.store(trackID: "background", from: url, stream: ResolvedStream(url: url)) }
        defer { background.cancel() }
        try await PlaybackTestSupport.waitUntil { fixture.mock.state.requests.count == 1 }
        let permit = try await fixture.cache.writePermit()
        let result = try await fixture.cache.storeOpus(trackID: OpusTestSupport.track.id,
            stream: OpusTestSupport.source(), permit: permit, foreground: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.url.path))
        do { _ = try await background.value; XCTFail("Background acquisition should yield to playback") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testJustPreparedFileIsNotItsOwnEvictionVictim() async throws {
        let fixture = try makeFixture(maximumFiles: 1)
        let unused = try fixture.seed("other-recording")
        let permit = try await fixture.cache.writePermit()
        let result = try await fixture.cache.storeOpus(trackID: OpusTestSupport.track.id,
            stream: OpusTestSupport.source(), permit: permit, foreground: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: unused.path))
        let usage = try await fixture.cache.storageUsage()
        XCTAssertEqual(usage.songCount, 1)
    }

    func testInsufficientPreparationBudgetPreservesTheExistingFileAndDoesNotDownload() async throws {
        let fixture = try makeFixture(capacityBytes: 64 << 20)
        let original = try fixture.seed(OpusTestSupport.track.id)
        let permit = try await fixture.cache.writePermit()
        do {
            _ = try await fixture.cache.storeOpus(trackID: OpusTestSupport.track.id,
                stream: OpusTestSupport.source(), permit: permit, foreground: true)
            XCTFail("Both bounded local files need a reservation")
        } catch { XCTAssertTrue(error is OpusPreparationError) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertTrue(fixture.mock.state.requests.isEmpty)
    }

    func testRejectingPinnedOpusLeavesItsBytesAndAACFallbackIntact() async throws {
        let fixture = try makeFixture()
        let id = OpusTestSupport.track.id
        let original = try fixture.seed(id)
        await fixture.cache.pin(id)
        let permit = try await fixture.cache.writePermit()
        let opus = try await fixture.cache.storeOpus(trackID: id, stream: OpusTestSupport.source(), permit: permit, foreground: true)
        await fixture.cache.rejectPlaybackFile(opus.url)
        let fallback = await fixture.cache.entry(for: id)
        XCTAssertEqual(fallback?.url, original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: opus.url.path))
        let retained = try await fixture.cache.clearUnused()
        XCTAssertEqual(retained.retainedSongCount, 1)
        XCTAssertEqual(retained.bytes, Int64(try Data(contentsOf: original).count + OpusTestSupport.mp4.count))
        await fixture.cache.pin(only: [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: opus.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }

    func testQualityReloadDoesNotJoinAnOlderOrdinaryResolutionOrReturnCachedAAC() async throws {
        let gate = AppModelRequestGate<String, FastPathResult>()
        let fixture = try makeFixture()
        addTeardownBlock { await gate.close() }
        let resolver = YouTubeStreamResolver(extract: { _, _ in [] }, validate: { _ in },
            fastExtract: { try await gate.receive($0) }, audioCache: fixture.cache, opusEnabled: true)
        let track = OpusTestSupport.track
        let regular = Task { try await resolver.resolve(track: track, forceRefresh: false) }
        let oldRequest = try await gate.request(at: 0)
        let original = try fixture.seed(track.id)
        let refresh = Task { try await resolver.refreshQuality(track: track) }
        defer { regular.cancel(); refresh.cancel() }
        let freshRequest = try await gate.request(at: 1)
        try await gate.complete(freshRequest, with: .success(OpusTestSupport.fast()))
        let upgraded = try await refresh.value
        XCTAssertNotEqual(upgraded.url, original)
        XCTAssertTrue(upgraded.url.isFileURL)
        XCTAssertEqual(upgraded.quality?.codec, .opus)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        try await gate.complete(oldRequest, with: .success(FastPathResult(urls: [OpusTestSupport.aacURL])))
        _ = try await regular.value
        let later = try await resolver.resolve(track: track, forceRefresh: false)
        XCTAssertEqual(later.url, upgraded.url)
    }

    func testVariantLookupDoesNotDeleteUnrelatedJSONInTheCacheDirectory() async throws {
        let fixture = try makeFixture()
        try FileManager.default.createDirectory(at: fixture.cache.directory, withIntermediateDirectories: true)
        let unrelated = fixture.cache.directory.appendingPathComponent("library.json")
        let data = Data(#"{"version":1,"favorites":[]}"#.utf8)
        try data.write(to: unrelated)
        let missing = await fixture.cache.entry(for: "library")
        XCTAssertNil(missing)
        XCTAssertEqual(try Data(contentsOf: unrelated), data)
        _ = try await fixture.cache.clearUnused()
        XCTAssertEqual(try Data(contentsOf: unrelated), data)
    }

    private func makeFixture(capacityBytes: Int64 = 200 << 20, maximumFiles: Int = 40,
                             preparation: @escaping AudioCache.OpusPreparation = OpusTestSupport.prepare) throws -> CacheManagementFixture {
        let fixture = try CacheManagementFixture(capacityBytes: capacityBytes, maximumFiles: maximumFiles, handler: { _ in
            CatalogStub(headers: ["Content-Type": "audio/webm", "Content-Length": "\(OpusTestSupport.webM.count)"], data: OpusTestSupport.webM)
        }, opusPreparation: preparation)
        addTeardownBlock { try await fixture.close() }
        return fixture
    }
}

import Foundation
import XCTest
import YouTubeKit
@testable import GanaBajana

@MainActor
final class ExtractorUpdateResolutionTests: XCTestCase {
    nonisolated private static let track = Track(id: "fsiPzT50ZiM", title: "Fixture", duration: 8)
    nonisolated private static let oldURL = URL(string: "https://audio.googlevideo.com/old.wav?dur=8&expire=4000000000")!
    nonisolated private static let newURL = URL(string: "https://audio.googlevideo.com/new.wav?dur=8&expire=4000000000")!

    private func activate() throws -> UInt64 {
        try YouTubeKitHooks.installExtractionCompatibility(.init(visitorKeys: ["VISITOR_TOKEN"])).generation
    }

    func testFastFullAndRemoteFallbackStampFreshGenerationAndKeepProvenance() async throws {
        let generation = try activate()
        defer { try? YouTubeKitHooks.installExtractionCompatibility(.bundled) }
        for path in 0..<3 {
            let fast: YouTubeStreamResolver.FastExtraction? = path == 0 ? { @Sendable _ in FastPathResult(urls: [Self.newURL]) } : nil
            let resolver = YouTubeStreamResolver(allowRemoteFallback: path == 2, extract: { _, remote in
                if path == 2 && !remote { throw PlaybackStreamError.noAudio }
                return [Self.newURL]
            }, validate: { _ in }, fastExtract: fast)
            let fresh = try await resolver.resolve(track: Self.track, forceRefresh: false)
            let reused = try await resolver.resolve(track: Self.track, forceRefresh: false)
            XCTAssertEqual(fresh.extractionGeneration, generation)
            XCTAssertEqual(reused.extractionGeneration, generation)
            XCTAssertEqual(fresh.playbackSource, .youTubeMusic)
            XCTAssertEqual(reused.playbackSource, .youTubeMusic)
        }
        XCTAssertNil(ResolvedStream(url: Self.newURL).extractionGeneration)
    }

    func testLateFastAndFullResultsFailEvenBeforeActorInvalidationCallback() async throws {
        defer { try? YouTubeKitHooks.installExtractionCompatibility(.bundled) }
        for fast in [false, true] {
            _ = try activate()
            let gate = AppModelRequestGate<String, [URL]>()
            addTeardownBlock { await gate.close() }
            let fastExtract: YouTubeStreamResolver.FastExtraction? = fast ? { @Sendable id in
                FastPathResult(urls: try await gate.receive(id))
            } : nil
            let resolver = YouTubeStreamResolver(extract: { id, _ in try await gate.receive(id) }, validate: { _ in }, fastExtract: fastExtract)
            let work = Task { try await resolver.resolve(track: Self.track, forceRefresh: false) }
            let old = try await gate.request(at: 0)
            let current = try activate()
            try await gate.complete(old, with: .success([Self.oldURL]))
            await assertCancelled(work)
            await gate.enqueue(.success([Self.newURL]))
            let fresh = try await resolver.resolve(track: Self.track, forceRefresh: false)
            XCTAssertEqual(fresh.url, Self.newURL)
            XCTAssertEqual(fresh.extractionGeneration, current)
        }
    }

    func testNewGenerationCannotJoinOldCoalescedFlightOrAcceptItsLateCacheWrite() async throws {
        _ = try activate()
        defer { try? YouTubeKitHooks.installExtractionCompatibility(.bundled) }
        let gate = AppModelRequestGate<String, [URL]>()
        addTeardownBlock { await gate.close() }
        let resolver = YouTubeStreamResolver(extract: { id, _ in try await gate.receive(id) }, validate: { _ in })
        let first = Task { try await resolver.resolve(track: Self.track, forceRefresh: false) }
        let old = try await gate.request(at: 0)
        let second = Task { try await resolver.resolve(track: Self.track, forceRefresh: false) }
        try await PlaybackTestSupport.eventually { await resolver.activeWaiterCount == 2 }
        let generation = try activate()
        let replacement = Task { try await resolver.resolve(track: Self.track, forceRefresh: false) }
        let newer = try await gate.request(at: 1)
        try await gate.complete(old, with: .success([Self.oldURL]))
        await assertCancelled(first)
        await assertCancelled(second)
        try await gate.complete(newer, with: .success([Self.newURL]))
        let fresh = try await replacement.value
        let reused = try await resolver.resolve(track: Self.track, forceRefresh: false)
        XCTAssertEqual(fresh.extractionGeneration, generation)
        XCTAssertEqual(reused.url, Self.newURL)
        XCTAssertEqual(reused.extractionGeneration, generation)
        let requests = await gate.requests
        XCTAssertEqual(requests.count, 2)
    }

    func testPrefetchedURLIsRetiredWithoutWaitingForCallbackAndLateCallbackSparesNewCache() async throws {
        let calls = CatalogTestCounter()
        let resolver = YouTubeStreamResolver(extract: { _, _ in XCTFail("URL warm must stay on fast path"); return [] }, validate: { _ in },
            fastExtract: { _ in FastPathResult(urls: [calls.increment() == 1 ? Self.oldURL : Self.newURL]) })
        _ = try activate()
        defer { try? YouTubeKitHooks.installExtractionCompatibility(.bundled) }
        _ = await resolver.warm([Self.track], download: false, token: UUID())
        let first = try await resolver.resolve(track: Self.track, forceRefresh: false)
        XCTAssertEqual(first.url, Self.oldURL)
        let current = try activate()
        let second = try await resolver.resolve(track: Self.track, forceRefresh: false)
        XCTAssertEqual(second.url, Self.newURL)
        XCTAssertEqual(second.extractionGeneration, current)
        await resolver.invalidateExtractionCompatibility()
        let third = try await resolver.resolve(track: Self.track, forceRefresh: false)
        XCTAssertEqual(third.extractionGeneration, current)
        XCTAssertEqual(calls.increment(), 3, "Only two extraction calls; the late idempotent callback retains the new URL")
    }

    func testProbeCompletionAfterActivationCannotReturnOrCacheOldStream() async throws {
        _ = try activate()
        defer { try? YouTubeKitHooks.installExtractionCompatibility(.bundled) }
        let probe = AppModelRequestGate<URL, Void>()
        addTeardownBlock { await probe.close() }
        let resolver = YouTubeStreamResolver(extract: { _, _ in [Self.oldURL] }, validate: { try await probe.receive($0) })
        let task = Task { try await resolver.resolve(track: Self.track, forceRefresh: false) }
        let request = try await probe.request(at: 0)
        _ = try activate()
        try await probe.complete(request, with: .success(()))
        await assertCancelled(task)
    }

    func testInvalidationCancelsPendingFastHedgeAndRetiresWaiters() async throws {
        _ = try activate()
        defer { try? YouTubeKitHooks.installExtractionCompatibility(.bundled) }
        let fast = AppModelRequestGate<String, FastPathResult>()
        let timer = AppModelRequestGate<TimeInterval, Void>()
        addTeardownBlock { await fast.close(); await timer.close() }
        let resolver = YouTubeStreamResolver(extract: { _, _ in XCTFail("Retired hedge cannot start extraction"); return [] }, validate: { _ in },
            fastExtract: { try await fast.receive($0) }, hedgeDelay: 2, hedgeSleep: { try await timer.receive($0) })
        let task = Task { try await resolver.resolve(track: Self.track, forceRefresh: false) }
        let request = try await fast.request(at: 0)
        let alarm = try await timer.request(at: 0)
        _ = try activate()
        await resolver.invalidateExtractionCompatibility()
        await assertCancelled(task)
        try await timer.complete(alarm, with: .success(()))
        try await fast.complete(request, with: .success(FastPathResult(urls: [Self.oldURL])))
        let waiters = await resolver.activeWaiterCount
        let events = await resolver.activeHedgeEventCount
        XCTAssertEqual(waiters, 0)
        XCTAssertEqual(events, 0)
    }

    func testDiskCopyAndDownloadResultsKeepNilStampAndSurviveInvalidation() async throws {
        let fixture = try CacheManagementFixture()
        addTeardownBlock { try await fixture.close() }
        let file = try fixture.seed(Self.track.id)
        let originalBytes = try Data(contentsOf: file)
        let resolver = YouTubeStreamResolver(extract: { _, _ in XCTFail("Complete media needs no extraction"); return [] }, validate: { _ in }, audioCache: fixture.cache)
        _ = try activate()
        defer { try? YouTubeKitHooks.installExtractionCompatibility(.bundled) }
        let first = try await resolver.resolve(track: Self.track, forceRefresh: false)
        XCTAssertNil(first.extractionGeneration)
        _ = try activate()
        await resolver.invalidateExtractionCompatibility()
        await resolver.setNetworkOffline(true)
        let reused = try await resolver.resolve(track: Self.track, forceRefresh: true)
        let downloaded = try await resolver.download(Self.track)
        XCTAssertEqual(reused.url, file)
        XCTAssertNil(reused.extractionGeneration)
        XCTAssertNil(downloaded.extractionGeneration)
        XCTAssertEqual(try Data(contentsOf: file), originalBytes)
    }

    func testBackgroundPlanIsFencedButPublishedMetadataAndFilesCannotConfirmUpdate() async throws {
        _ = try activate()
        defer { try? YouTubeKitHooks.installExtractionCompatibility(.bundled) }
        let gate = AppModelRequestGate<String, [URL]>()
        addTeardownBlock { await gate.close() }
        let fixture = try CacheManagementFixture()
        addTeardownBlock { try await fixture.close() }
        let resolver = YouTubeStreamResolver(extract: { id, _ in try await gate.receive(id) }, validate: { _ in }, audioCache: fixture.cache)
        let task = Task { try await resolver.backgroundDownloadPlan(for: Self.track) }
        let old = try await gate.request(at: 0)
        let generation = try activate()
        try await gate.complete(old, with: .success([Self.oldURL]))
        do { _ = try await task.value; XCTFail("Old background plan must be rejected") }
        catch { XCTAssertTrue(error is CancellationError) }
        await gate.enqueue(.success([Self.newURL]))
        let plan = try await resolver.backgroundDownloadPlan(for: Self.track)
        XCTAssertEqual(plan.stream.extractionGeneration, generation)
        XCTAssertEqual(plan.metadata.playbackSource, .youTubeMusic)
        let json = try JSONEncoder().encode(plan.metadata)
        XCTAssertFalse(String(decoding: json, as: UTF8.self).contains("extractionGeneration"))
        let downloadResolver = YouTubeStreamResolver(extract: { _, _ in [] }, validate: { _ in },
            fastExtract: { _ in FastPathResult(urls: [Self.newURL]) }, audioCache: fixture.cache)
        let downloaded = try await downloadResolver.download(Self.track)
        XCTAssertTrue(downloaded.url.isFileURL)
        XCTAssertNil(downloaded.extractionGeneration)
        XCTAssertEqual(downloaded.playbackSource, .youTubeMusic)
    }

    func testQualityReloadRetiresOldWorkWithoutFallingBackAndLeavesSavedCopyIntact() async throws {
        let fixture = try CacheManagementFixture()
        addTeardownBlock { try await fixture.close() }
        let saved = try fixture.seed(Self.track.id)
        let gate = AppModelRequestGate<String, [URL]>()
        addTeardownBlock { await gate.close() }
        let resolver = YouTubeStreamResolver(extract: { id, _ in try await gate.receive(id) }, validate: { _ in }, audioCache: fixture.cache)
        _ = try activate()
        defer { try? YouTubeKitHooks.installExtractionCompatibility(.bundled) }
        let task = Task { try await resolver.refreshQuality(track: Self.track) }
        let old = try await gate.request(at: 0)
        _ = try activate()
        try await gate.complete(old, with: .success([Self.oldURL]))
        await assertCancelled(task)
        let cached = try await resolver.resolve(track: Self.track, forceRefresh: false)
        XCTAssertEqual(cached.url, saved)
        XCTAssertNil(cached.extractionGeneration)
    }

    func testCompositePreservesGaanaFallbackProvenanceAndRefreshesItsOldYouTubeURL() async throws {
        _ = try activate()
        defer { try? YouTubeKitHooks.installExtractionCompatibility(.bundled) }
        let calls = CatalogTestCounter()
        let youtube = YouTubeStreamResolver(extract: { _, _ in [calls.increment() == 1 ? Self.oldURL : Self.newURL] }, validate: { _ in })
        let gaanaMock = GaanaTests.mock(details: "gaana-song-detail-missing")
        let unused = CatalogMockSession { _ in XCTFail("No Saavn request expected"); return CatalogStub(data: Data()) }
        defer { gaanaMock.close(); unused.close() }
        let gaana = GaanaStreamResolver(catalog: GaanaCatalogService(session: gaanaMock.session), fallbacks: [
            ExtractorResolutionFallback(source: .youTubeMusic) { refresh in try await youtube.resolve(track: Self.track, forceRefresh: refresh) }
        ])
        let composite = CompositeStreamResolver(youTube: youtube, saavn: JioSaavnStreamResolver(catalog: JioSaavnCatalogService(session: unused.session), probe: { _ in }), gaana: gaana)
        let track = Track(id: "gaana:944286", title: "Fixture", duration: 8)
        let old = try await composite.resolve(track: track, forceRefresh: false)
        XCTAssertEqual(old.url, Self.oldURL)
        let generation = try activate()
        let fresh = try await composite.resolve(track: track, forceRefresh: false)
        XCTAssertEqual(fresh.url, Self.newURL)
        XCTAssertEqual(fresh.playbackSource, .youTubeMusic)
        XCTAssertEqual(fresh.extractionGeneration, generation)
        XCTAssertEqual(track.source, .gaana)
        XCTAssertEqual(PlaybackStartTrace.path(for: track.id), .gaana, "Replacing a stale fallback is not a URL-cache hit")
        await composite.invalidateExtractionCompatibility()
        let cached = try await composite.resolve(track: track, forceRefresh: false)
        XCTAssertEqual(cached.extractionGeneration, generation)
    }

    func testCompositeSaavnFallbackAndLocalYouTubeFallbackNeverAcquireAStamp() async throws {
        let unused = CatalogMockSession { _ in XCTFail("No primary request expected"); return CatalogStub(data: Data()) }
        defer { unused.close() }
        _ = try activate()
        defer { try? YouTubeKitHooks.installExtractionCompatibility(.bundled) }
        for file in [false, true] {
            let mock = GaanaTests.mock(details: "gaana-song-detail-missing")
            defer { mock.close() }
            let source: MusicSource = file ? .youTubeMusic : .jioSaavn
            let gaana = GaanaStreamResolver(catalog: GaanaCatalogService(session: mock.session), fallbacks: [
                ExtractorResolutionFallback(source: source) { _ in
                    ResolvedStream(url: file ? URL(fileURLWithPath: "/fixture/local.m4a") : Self.newURL, playbackSource: source)
                }
            ])
            let composite = CompositeStreamResolver(youTube: YouTubeStreamResolver(extract: { _, _ in [] }, validate: { _ in }),
                saavn: JioSaavnStreamResolver(catalog: JioSaavnCatalogService(session: unused.session), probe: { _ in }), gaana: gaana)
            let result = try await composite.resolve(track: Track(id: "gaana:944286", title: "Fixture"), forceRefresh: false)
            XCTAssertEqual(result.playbackSource, source)
            XCTAssertNil(result.extractionGeneration)
        }
    }

    func testCompositeRejectsLateFallbackAndForcesReplacementOfItsRetainedURL() async throws {
        _ = try activate()
        defer { try? YouTubeKitHooks.installExtractionCompatibility(.bundled) }
        let gate = AppModelRequestGate<Bool, URL>()
        addTeardownBlock { await gate.close() }
        let mock = GaanaTests.mock(details: "gaana-song-detail-missing")
        let unused = CatalogMockSession { _ in XCTFail("No Saavn request expected"); return CatalogStub(data: Data()) }
        defer { mock.close(); unused.close() }
        let gaana = GaanaStreamResolver(catalog: GaanaCatalogService(session: mock.session), fallbacks: [
            ExtractorResolutionFallback(source: .youTubeMusic) { refresh in
                let generation = YouTubeKitHooks.extractionCompatibility.generation
                let url = try await gate.receive(refresh)
                return ResolvedStream(url: url, playbackSource: .youTubeMusic, extractionGeneration: generation)
            }
        ])
        let composite = CompositeStreamResolver(youTube: YouTubeStreamResolver(extract: { _, _ in [] }, validate: { _ in }),
            saavn: JioSaavnStreamResolver(catalog: JioSaavnCatalogService(session: unused.session), probe: { _ in }), gaana: gaana)
        let track = Track(id: "gaana:944286", title: "Fixture")
        let old = Task { try await composite.resolve(track: track, forceRefresh: false) }
        let request = try await gate.request(at: 0)
        let generation = try activate()
        await composite.invalidateExtractionCompatibility()
        try await gate.complete(request, with: .success(Self.oldURL))
        await assertCancelled(old)
        await gate.enqueue(.success(Self.newURL))
        let new = try await composite.resolve(track: track, forceRefresh: false)
        XCTAssertEqual(new.extractionGeneration, generation)
        XCTAssertEqual(new.url, Self.newURL)
        let calls = await gate.requests
        XCTAssertEqual(calls.count, 2)
        XCTAssertTrue(calls.last?.input == true)
    }

    private func assertCancelled(_ task: Task<ResolvedStream, Error>, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await task.value; XCTFail("Expected retired extraction", file: file, line: line) }
        catch { XCTAssertTrue(error is CancellationError, file: file, line: line) }
    }
}

private struct ExtractorResolutionFallback: CrossSourceStreamFallback {
    let source: MusicSource
    let answer: @Sendable (Bool) async throws -> ResolvedStream?
    func resolve(matching track: Track, forceRefresh: Bool) async throws -> ResolvedStream? { try await answer(forceRefresh) }
}

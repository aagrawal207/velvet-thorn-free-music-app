import XCTest
@testable import GanaBajana

@MainActor
final class OpusSelectionTests: XCTestCase {
    func testEnabledOpusWinsByAverageBitrateAndKeepsBestAACFallback() throws {
        let formats = [OpusTestSupport.format(opus: false, rate: 128_000), OpusTestSupport.format(opus: true, rate: 160_000)]
        let data = try OpusTestSupport.payload(formats)
        let selected = try YouTubeAudioFastPath.audioResult(in: data, videoID: OpusTestSupport.track.id, allowOpus: true)
        XCTAssertEqual(selected.urls, [OpusTestSupport.opusURL])
        XCTAssertEqual(selected.streams.first?.quality, OpusTestSupport.opusQuality)
        XCTAssertEqual(selected.aacFallbacks.first?.quality, OpusTestSupport.aacQuality)
        let olderOS = try YouTubeAudioFastPath.audioResult(in: data, videoID: OpusTestSupport.track.id, allowOpus: false)
        XCTAssertEqual(olderOS.urls, [OpusTestSupport.aacURL])
    }

    func testHigherAACAndEqualBitrateAACDoNotRequireRemuxing() throws {
        for rate in [160_000, 256_000] {
            let data = try OpusTestSupport.payload([OpusTestSupport.format(opus: true, rate: 160_000),
                                                   OpusTestSupport.format(opus: false, rate: rate)])
            let selected = try YouTubeAudioFastPath.audioResult(in: data, videoID: OpusTestSupport.track.id, allowOpus: true)
            XCTAssertEqual(selected.urls, [OpusTestSupport.aacURL])
        }
    }

    func testChallengedBestOpusDefersBeforeUsingClearAAC() async throws {
        var opus = OpusTestSupport.format(opus: true, rate: 160_000)
        opus["signatureCipher"] = "s=challenge"
        let data = try OpusTestSupport.payload([opus, OpusTestSupport.format(opus: false, rate: 128_000)])
        let fast = try YouTubeAudioFastPath.audioResult(in: data, videoID: OpusTestSupport.track.id, allowOpus: true)
        XCTAssertTrue(fast.urls.isEmpty)
        XCTAssertEqual(fast.aacFallbacks.count, 1)
        let calls = CatalogTestRecorder<Bool>()
        let fixture = try makeFixture()
        let resolver = YouTubeStreamResolver(extract: { _, remote in calls.record(remote); return [] }, validate: { _ in },
            fastExtract: { _ in fast }, audioCache: fixture.cache,
            qualityExtract: { _, remote in calls.record(remote); return [OpusTestSupport.source()] }, opusEnabled: true)
        let result = try await resolver.resolve(track: OpusTestSupport.track, forceRefresh: false)
        XCTAssertEqual(calls.values, [false])
        XCTAssertTrue(result.url.isFileURL)
        XCTAssertEqual(result.quality?.codec, .opus)
    }

    func testChallengedBestAACIsNotReplacedByAReadyLowerAACFallback() throws {
        var highAAC = OpusTestSupport.format(opus: false, rate: 128_000)
        highAAC["url"] = OpusTestSupport.aacURL.absoluteString + "&n=challenge"
        let lowAAC = OpusTestSupport.format(opus: false, rate: 48_000)
        let data = try OpusTestSupport.payload([OpusTestSupport.format(opus: true, rate: 160_000), highAAC, lowAAC])
        let result = try YouTubeAudioFastPath.audioResult(in: data, videoID: OpusTestSupport.track.id, allowOpus: true)
        XCTAssertEqual(result.urls, [OpusTestSupport.opusURL])
        XCTAssertTrue(result.aacFallbacks.isEmpty)
    }

    func testDubbedAndVideoOpusCannotDisplaceOriginalAudio() throws {
        var dubbed = OpusTestSupport.format(opus: true, rate: 256_000)
        dubbed["audioTrack"] = ["displayName": "English", "audioIsDefault": true]
        var video = OpusTestSupport.format(opus: true, rate: 256_000)
        video["width"] = 1920
        let data = try OpusTestSupport.payload([dubbed, video, OpusTestSupport.format(opus: false, rate: 128_000)])
        let result = try YouTubeAudioFastPath.audioResult(in: data, videoID: OpusTestSupport.track.id, allowOpus: true)
        XCTAssertEqual(result.urls, [OpusTestSupport.aacURL])
    }

    func testAcquisitionRemuxAndNativeFailuresReturnAACWithoutPublishingWebM() async throws {
        for phase in 0..<3 {
            let fixture = try makeFixture(status: phase == 0 ? 403 : 200, preparation: { input, output in
                if phase == 1 { throw OpusPreparationError.remux(-1) }
                _ = try await OpusTestSupport.prepare(input: input, output: output)
                throw OpusPreparationError.invalidOutput
            })
            let validated = CatalogTestRecorder<URL>()
            let resolver = YouTubeStreamResolver(extract: { _, _ in [] }, validate: { validated.record($0) },
                fastExtract: { _ in OpusTestSupport.fast() }, audioCache: fixture.cache, opusEnabled: true)
            let result = try await resolver.resolve(track: OpusTestSupport.track, forceRefresh: false)
            XCTAssertEqual(result.url, OpusTestSupport.aacURL)
            XCTAssertEqual(validated.values, [OpusTestSupport.aacURL])
            let usage = try await fixture.cache.storageUsage()
            XCTAssertEqual(usage.bytes, 0)
            XCTAssertEqual(usage.songCount, 0)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.cache.directory.path), [])
        }
    }

    func testCancellationNeverBecomesAnAACFallback() async throws {
        let fixture = try makeFixture(preparation: { _, _ in throw CancellationError() })
        let validated = CatalogTestRecorder<URL>()
        let resolver = YouTubeStreamResolver(extract: { _, _ in [] }, validate: { validated.record($0) },
            fastExtract: { _ in OpusTestSupport.fast() }, audioCache: fixture.cache, opusEnabled: true)
        do { _ = try await resolver.resolve(track: OpusTestSupport.track, forceRefresh: false); XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(validated.values.isEmpty)
    }

    func testPreparationTimeoutReturnsAACAndTracksItsFilesUntilTheWorkerDrains() async throws {
        let gate = AppModelRequestGate<URL, OpusNativeAudio.Inspection>()
        let fixture = try makeFixture(preparation: { input, output in
            _ = try await OpusTestSupport.prepare(input: input, output: output)
            return try await gate.receive(output)
        })
        addTeardownBlock { await gate.close() }
        let resolver = YouTubeStreamResolver(extract: { _, _ in [] }, validate: { _ in },
            fastExtract: { _ in OpusTestSupport.fast() }, audioCache: fixture.cache, opusEnabled: true, opusTimeout: 0.05)
        let resolution = Task { try await resolver.resolve(track: OpusTestSupport.track, forceRefresh: false) }
        defer { resolution.cancel() }
        let request = try await gate.request(at: 0)
        let result = try await resolution.value
        XCTAssertEqual(result.url, OpusTestSupport.aacURL)
        try await PlaybackTestSupport.eventually { await gate.cancellations.contains(request.id) }
        let stopping = try await fixture.cache.storageUsage()
        XCTAssertEqual(stopping.pendingDownloads, 1)
        XCTAssertGreaterThan(stopping.bytes, 0)
        try await gate.complete(request, with: .success(OpusTestSupport.inspection))
        try await PlaybackTestSupport.eventually { (try? await fixture.cache.storageUsage().pendingDownloads) == 0 }
        let stopped = try await fixture.cache.storageUsage()
        XCTAssertEqual(stopped.bytes, 0)
        XCTAssertEqual(stopped.songCount, 0)
    }

    func testDisabledOpusSkipsPreparationAndUsesAAC() async throws {
        let fixture = try makeFixture(preparation: { _, _ in XCTFail("Opus is disabled"); throw OpusPreparationError.invalidOutput })
        let resolver = YouTubeStreamResolver(extract: { _, _ in [] }, validate: { _ in },
            fastExtract: { _ in OpusTestSupport.fast() }, audioCache: fixture.cache, opusEnabled: false)
        let result = try await resolver.resolve(track: OpusTestSupport.track, forceRefresh: false)
        XCTAssertEqual(result.url, OpusTestSupport.aacURL)
        XCTAssertTrue(fixture.mock.state.requests.isEmpty)
    }

    func testFullExtractionAlwaysRetainsAACBeyondSeveralOpusCandidates() async throws {
        let fixture = try makeFixture(preparation: { _, _ in throw OpusPreparationError.invalidOutput })
        let candidates = [320_000, 300_000, 256_000, 192_000].map { OpusTestSupport.source(rate: $0) }
            + [ResolvedStream(url: OpusTestSupport.aacURL, quality: OpusTestSupport.aacQuality)]
        let resolver = YouTubeStreamResolver(extract: { _, _ in [] }, validate: { _ in }, audioCache: fixture.cache,
                                             qualityExtract: { _, _ in candidates }, opusEnabled: true)
        let result = try await resolver.resolve(track: OpusTestSupport.track, forceRefresh: false)
        XCTAssertEqual(result.url, OpusTestSupport.aacURL)
        XCTAssertEqual(fixture.mock.state.requests.count, 1, "A failed preparation is not repeated for lower Opus tiers")
    }

    private func makeFixture(status: Int = 200,
                             preparation: @escaping AudioCache.OpusPreparation = OpusTestSupport.prepare) throws -> CacheManagementFixture {
        let fixture = try CacheManagementFixture(handler: { _ in
            CatalogStub(status: status, headers: ["Content-Type": "audio/webm", "Content-Length": "\(OpusTestSupport.webM.count)"],
                        data: OpusTestSupport.webM)
        }, opusPreparation: preparation)
        addTeardownBlock { try await fixture.close() }
        return fixture
    }
}

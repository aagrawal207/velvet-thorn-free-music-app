import XCTest
@testable import GanaBajana

/// Progressive first (AAC now, Opus prepared later by a complete download) and the hedged fast path versus YouTubeKit
/// race; see `docs/FAST_START.md`.
@MainActor
final class StreamResolverFastStartTests: XCTestCase {
    private let track = OpusTestSupport.track
    private let wav = PlaybackTestSupport.audioData(seconds: 1)

    // MARK: Start policy

    func testFirstPlayStartsWithTheAACAndACompleteDownloadPreparesTheOpusUpgradeForLaterPlays() async throws {
        let fixture = try makeFixture()
        let validated = CatalogTestRecorder<URL>()
        let resolver = YouTubeStreamResolver(extract: { _, _ in [] }, validate: { validated.record($0) },
            fastExtract: { _ in OpusTestSupport.fast() }, audioCache: fixture.cache, opusEnabled: true)
        let first = try await resolver.resolve(track: track, forceRefresh: false)
        XCTAssertEqual(first.url, OpusTestSupport.aacURL, "A first play streams the clear AAC at once")
        XCTAssertEqual(first.quality, OpusTestSupport.aacQuality)
        XCTAssertEqual(validated.values, [OpusTestSupport.aacURL], "Only the pick is range-probed")
        XCTAssertTrue(fixture.mock.state.requests.isEmpty, "Nothing is downloaded before audio can start")
        XCTAssertEqual(PlaybackStartTrace.path(for: track.id), .fastPath)

        let again = try await resolver.resolve(track: track, forceRefresh: false)
        XCTAssertEqual(again.url, OpusTestSupport.aacURL)
        XCTAssertEqual(PlaybackStartTrace.path(for: track.id), .urlCache, "A repeat play within the URL lifetime is a cache hit")

        let complete = try await resolver.download(track)
        XCTAssertTrue(complete.url.isFileURL)
        XCTAssertEqual(complete.quality?.codec, .opus, "The background download prepares the Opus the fast start skipped")
        XCTAssertEqual(fixture.mock.state.requests.count, 1)
        XCTAssertEqual(fixture.mock.state.requests.first?.url?.query?.contains("itag=251"), true, "The Opus URL is downloaded, not the AAC")

        let later = try await resolver.resolve(track: track, forceRefresh: true)
        XCTAssertEqual(later.url, complete.url, "The next play uses the prepared Opus copy")
        XCTAssertEqual(PlaybackStartTrace.path(for: track.id), .local)
        XCTAssertEqual(validated.values, [OpusTestSupport.aacURL], "A local copy needs no further probe")
    }

    func testOpusOnlyOfferKeepsTheOpusPreparationBeforePlayback() async throws {
        let fixture = try makeFixture()
        let opusOnly = FastPathResult(urls: [OpusTestSupport.opusURL], qualityByURL: [OpusTestSupport.opusURL: OpusTestSupport.opusQuality])
        let resolver = YouTubeStreamResolver(extract: { _, _ in [] }, validate: { _ in },
            fastExtract: { _ in opusOnly }, audioCache: fixture.cache, opusEnabled: true)
        let result = try await resolver.resolve(track: track, forceRefresh: false)
        XCTAssertTrue(result.url.isFileURL)
        XCTAssertEqual(result.quality?.codec, .opus)
        XCTAssertEqual(fixture.mock.state.requests.count, 1)
    }

    func testAACRankedAboveOpusLeavesNothingToUpgrade() async throws {
        let fixture = try makeFixture()
        let aac256 = URL(string: "https://audio.googlevideo.com/videoplayback?itag=141&dur=8&expire=4000000000")!
        let aac256Quality = SourceAudioQuality(codec: .aac, bitRate: 256_000, sampleRate: 44_100, channels: 2)
        let fast = FastPathResult(urls: [aac256], qualityByURL: [aac256: aac256Quality],
                                  aacFallbacks: [ResolvedStream(url: aac256, quality: aac256Quality)])
        let resolver = YouTubeStreamResolver(extract: { _, _ in [] }, validate: { _ in },
            fastExtract: { _ in fast }, audioCache: fixture.cache, opusEnabled: true)
        let first = try await resolver.resolve(track: track, forceRefresh: false)
        XCTAssertEqual(first.url, aac256)
        let complete = try await resolver.download(track)
        XCTAssertEqual(complete.quality?.codec, .aac, "Without a better Opus the download stores the AAC itself")
        XCTAssertEqual(fixture.mock.state.requests.first?.url, aac256)
    }

    func testFailedUpgradeStoresTheAACAndCoolsOpusDown() async throws {
        let fixture = try makeFixture(handler: { [wav] request in
            if request.url?.query?.contains("itag=251") == true {
                return CatalogStub(headers: ["Content-Type": "audio/webm", "Content-Length": "\(OpusTestSupport.webM.count)"], data: OpusTestSupport.webM)
            }
            return CatalogStub(headers: ["Content-Type": "audio/wav", "Content-Length": "\(wav.count)"], data: wav)
        }, preparation: { _, _ in throw OpusPreparationError.remux(-1) })
        let resolver = YouTubeStreamResolver(extract: { _, _ in [] }, validate: { _ in },
            fastExtract: { _ in OpusTestSupport.fast() }, audioCache: fixture.cache, opusEnabled: true)
        _ = try await resolver.resolve(track: track, forceRefresh: false)
        let complete = try await resolver.download(track)
        XCTAssertTrue(complete.url.isFileURL)
        XCTAssertNotEqual(complete.quality?.codec, .opus, "A failed preparation falls back to the AAC copy")
        let urls = fixture.mock.state.requests.compactMap { $0.url?.query }
        XCTAssertEqual(urls.filter { $0.contains("itag=251") }.count, 1)
        XCTAssertEqual(urls.filter { $0.contains("itag=140") }.count, 1)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.cache.directory.path).contains { $0.contains(".opus-") },
                       "No WebM or half-prepared variant is published")
    }

    func testQualityCeilingGovernsTheFastStartPickAndItsUpgrade() async throws {
        let aac128 = OpusTestSupport.aacURL
        let aac256 = URL(string: "https://audio.googlevideo.com/videoplayback?itag=141&dur=8&expire=4000000000")!
        let aac256Quality = SourceAudioQuality(codec: .aac, bitRate: 256_000, sampleRate: 44_100, channels: 2)
        let offered = [ResolvedStream(url: aac128, quality: OpusTestSupport.aacQuality),
                       ResolvedStream(url: aac256, quality: aac256Quality),
                       OpusTestSupport.source(rate: 160_000)]
        let cases: [(AudioQualityPreference, URL, String?)] = [
            (.best, aac256, nil),
            (.balanced, aac128, "rate=160000"),
            (.dataSaver, aac128, nil),
        ]
        for (preference, expectedStart, expectedUpgrade) in cases {
            let fixture = try makeFixture(handler: { [wav] request in
                if request.url?.query?.contains("itag=251") == true {
                    return CatalogStub(headers: ["Content-Type": "audio/webm", "Content-Length": "\(OpusTestSupport.webM.count)"], data: OpusTestSupport.webM)
                }
                return CatalogStub(headers: ["Content-Type": "audio/wav", "Content-Length": "\(wav.count)"], data: wav)
            })
            let resolver = YouTubeStreamResolver(extract: { _, _ in [] }, validate: { _ in }, audioCache: fixture.cache,
                                                 qualityExtract: { _, _ in offered }, opusEnabled: true)
            await resolver.setAudioQualityPreference(preference)
            let start = try await resolver.resolve(track: track, forceRefresh: false)
            XCTAssertEqual(start.url, expectedStart, preference.rawValue)
            let complete = try await resolver.download(track)
            let downloaded = fixture.mock.state.requests.first?.url?.query ?? ""
            if let expectedUpgrade {
                XCTAssertEqual(complete.quality?.codec, .opus, preference.rawValue)
                XCTAssertTrue(downloaded.contains(expectedUpgrade), "\(preference.rawValue) downloads \(expectedUpgrade), got \(downloaded)")
            } else {
                XCTAssertEqual(complete.quality?.codec, .aac, preference.rawValue)
                XCTAssertEqual(fixture.mock.state.requests.first?.url, expectedStart, preference.rawValue)
            }
        }
    }

    func testReloadBestAvailableAudioStillWaitsForThePreparedOpus() async throws {
        let fixture = try makeFixture()
        let validated = CatalogTestRecorder<URL>()
        let resolver = YouTubeStreamResolver(extract: { _, _ in [] }, validate: { validated.record($0) },
            fastExtract: { _ in OpusTestSupport.fast() }, audioCache: fixture.cache, opusEnabled: true)
        let reloaded = try await resolver.refreshQuality(track: track)
        XCTAssertTrue(reloaded.url.isFileURL)
        XCTAssertEqual(reloaded.quality?.codec, .opus, "The listener asked for the best audio, so the reload prepares it")
        XCTAssertTrue(validated.values.isEmpty)
    }

    func testDownloadJoiningAFastStartFlightPreparesTheUpgradeAfterTheSharedResolution() async throws {
        let fixture = try makeFixture()
        let gate = AppModelRequestGate<String, FastPathResult>()
        addTeardownBlock { await gate.close() }
        let resolver = YouTubeStreamResolver(extract: { _, _ in [] }, validate: { _ in },
            fastExtract: { try await gate.receive($0) }, audioCache: fixture.cache, opusEnabled: true)
        let track = track
        let warm = Task(priority: .utility) { await resolver.prefetch([track]) }
        let request = try await gate.request(at: 0)
        try await PlaybackTestSupport.eventually { await resolver.activeWaiterCount == 2 }
        try await gate.complete(request, with: .success(OpusTestSupport.fast()))
        await warm.value
        try await PlaybackTestSupport.eventually { await fixture.cache.entry(for: track.id)?.quality?.codec == .opus }
        try await PlaybackTestSupport.eventually { await resolver.prefetchDownloadTrackID == nil }
        XCTAssertEqual(fixture.mock.state.requests.count, 1, "One fast-path lookup served both the warm and its download")
        let requests = await gate.requests
        XCTAssertEqual(requests.count, 1)
    }

    // MARK: Hedged extraction

    func testSlowFastPathLetsTheHedgedExtractionAnswerFirst() async throws {
        let fixture = StreamHedgeFixture()
        let resolver = YouTubeStreamResolver(extract: { id, _ in await fixture.extracted(id) }, validate: { _ in },
                                             fastExtract: { try await fixture.holdFast($0) }, hedgeDelay: 0.05)
        let started = ContinuousClock.now
        let stream = try await resolver.resolve(track: track, forceRefresh: false)
        XCTAssertEqual(stream.url.host, "library.googlevideo.com", "YouTubeKit's answer plays while the fast path is still silent")
        XCTAssertLessThan(started.duration(to: .now), .seconds(3))
        XCTAssertEqual(PlaybackStartTrace.path(for: track.id), .extraction)
        try await PlaybackTestSupport.eventually { await fixture.fastCancelled }
        await fixture.releaseFast()
    }

    func testFastPathAnsweringFirstCancelsTheHedgedExtraction() async throws {
        let fixture = StreamHedgeFixture()
        let resolver = YouTubeStreamResolver(extract: { id, _ in try await fixture.holdExtraction(id) }, validate: { _ in },
                                             fastExtract: { try await fixture.fastAfterDelay($0, .milliseconds(250)) }, hedgeDelay: 0.05)
        let stream = try await resolver.resolve(track: track, forceRefresh: false)
        XCTAssertEqual(stream.url.host, "fast.googlevideo.com")
        XCTAssertEqual(PlaybackStartTrace.path(for: track.id), .fastPath)
        let extractions = await fixture.extractions
        XCTAssertEqual(extractions, [track.id], "The hedge had started YouTubeKit before the fast path answered")
        try await PlaybackTestSupport.eventually { await fixture.extractionCancelled }
    }

    func testFastPathFailureStartsExtractionAtOnceWithoutWaitingForTheHedge() async throws {
        let fixture = StreamHedgeFixture()
        let resolver = YouTubeStreamResolver(extract: { id, _ in await fixture.extracted(id) }, validate: { _ in },
                                             fastExtract: { _ in throw PlaybackStreamError.noAudio }, hedgeDelay: 5)
        let started = ContinuousClock.now
        let stream = try await resolver.resolve(track: track, forceRefresh: false)
        XCTAssertEqual(stream.url.host, "library.googlevideo.com")
        XCTAssertLessThan(started.duration(to: .now), .seconds(2), "A failed fast path does not wait out the hedge delay")
    }

    func testBothPathsFailingSurfacesOneError() async throws {
        struct ExtractionFailure: Error { }
        let resolver = YouTubeStreamResolver(extract: { _, _ in throw ExtractionFailure() }, validate: { _ in },
                                             fastExtract: { _ in throw PlaybackStreamError.noAudio }, hedgeDelay: 0.05)
        do {
            _ = try await resolver.resolve(track: track, forceRefresh: false)
            XCTFail("Expected a failure")
        } catch {
            guard case MusicServiceError.unavailable? = error as? MusicServiceError else {
                return XCTFail("Both paths failed, so the generic YouTube failure is reported: \(error)")
            }
        }
    }

    func testSpeculativeWarmUpsNeverStartTheHedgedExtraction() async throws {
        let fixture = StreamHedgeFixture()
        let resolver = YouTubeStreamResolver(extract: { id, _ in await fixture.extracted(id) }, validate: { _ in },
                                             fastExtract: { try await fixture.holdFast($0) }, hedgeDelay: 0.05)
        let track = track
        let warm = Task(priority: .utility) { await resolver.warm([track], download: false, token: UUID()) }
        try await Task.sleep(for: .milliseconds(300))
        let extractions = await fixture.extractions
        XCTAssertTrue(extractions.isEmpty, "Speculation never enters YouTubeKit's serialized JS path")
        warm.cancel()
        _ = await warm.value
        await fixture.releaseFast()
    }

    func testLateWarmPromotionStartsExtractionWithoutWaitingForTheFastTimeout() async throws {
        let fixture = LatePromotionFixture()
        addTeardownBlock { await fixture.close() }
        let resolver = fixture.resolver
        let track = track
        let warm = Task { await resolver.warm([track], download: false, token: UUID()) }
        defer { warm.cancel() }
        _ = try await fixture.fast.request(at: 0)
        let timer = try await fixture.timer.request(at: 0)
        XCTAssertEqual(timer.input, 2)
        try await fixture.timer.complete(timer, with: .success(()))
        try await PlaybackTestSupport.eventually { await resolver.elapsedHedgeCount == 1 }
        let speculativeExtractions = await fixture.extraction.requests
        XCTAssertTrue(speculativeExtractions.isEmpty)

        let foreground = Task { try await resolver.resolve(track: track, forceRefresh: false) }
        defer { foreground.cancel() }
        // The fast request stays held; the extraction gate has a three-second deadline, below its six-second timeout.
        let extraction = try await fixture.extraction.request(at: 0)
        try await fixture.extraction.complete(extraction, with: .success([LatePromotionFixture.extractedURL]))
        let stream = try await foreground.value
        let outcome = await warm.value
        XCTAssertEqual(stream.url, LatePromotionFixture.extractedURL)
        XCTAssertEqual(outcome.resolved, 1)
        let cached = try await resolver.resolve(track: track, forceRefresh: false)
        XCTAssertEqual(cached.url, stream.url)
        XCTAssertEqual(PlaybackStartTrace.startPath(for: track.id), .warmed)
        let fastRequests = await fixture.fast.requests
        XCTAssertEqual(fastRequests.count, 1, "The foreground joined the warm and its result remains cached")
        let events = await resolver.activeHedgeEventCount
        XCTAssertEqual(events, 0)
    }

    func testEarlyPromotionKeepsTheOriginalHedgeBudgetAndWarmCancellationSparesForeground() async throws {
        let fixture = LatePromotionFixture()
        addTeardownBlock { await fixture.close() }
        let resolver = fixture.resolver
        let track = track
        let warm = Task { await resolver.warm([track], download: false, token: UUID()) }
        defer { warm.cancel() }
        _ = try await fixture.fast.request(at: 0)
        let timer = try await fixture.timer.request(at: 0)
        let foreground = Task { try await resolver.resolve(track: track, forceRefresh: false) }
        defer { foreground.cancel() }
        try await PlaybackTestSupport.eventually { await resolver.activeWaiterCount == 2 }
        let early = await fixture.extraction.requests
        XCTAssertTrue(early.isEmpty, "Joining alone cannot spend the unelapsed hedge budget")
        warm.cancel()
        _ = await warm.value
        let remaining = await resolver.activeWaiterCount
        XCTAssertEqual(remaining, 1)

        try await fixture.timer.complete(timer, with: .success(()))
        let extraction = try await fixture.extraction.request(at: 0)
        try await fixture.extraction.complete(extraction, with: .success([LatePromotionFixture.extractedURL]))
        let stream = try await foreground.value
        let timers = await fixture.timer.requests
        XCTAssertEqual(timers.count, 1, "Promotion uses the flight's original timer, not a new two-second wait")
        let cached = try await resolver.resolve(track: track, forceRefresh: false)
        XCTAssertEqual(cached.url, stream.url)
        let events = await resolver.activeHedgeEventCount
        XCTAssertEqual(events, 0)
    }

    func testCancelledFlightLateTimerAndResultCannotWakeOrClearItsReplacement() async throws {
        let fixture = LatePromotionFixture()
        addTeardownBlock { await fixture.close() }
        let resolver = fixture.resolver
        let track = track
        let warm = Task { await resolver.warm([track], download: false, token: UUID()) }
        defer { warm.cancel() }
        let oldFast = try await fixture.fast.request(at: 0)
        let oldTimer = try await fixture.timer.request(at: 0)
        warm.cancel()
        _ = await warm.value
        try await PlaybackTestSupport.eventually { await resolver.activeHedgeEventCount == 0 }

        let foreground = Task { try await resolver.resolve(track: track, forceRefresh: false) }
        defer { foreground.cancel() }
        _ = try await fixture.fast.request(at: 1)
        let newTimer = try await fixture.timer.request(at: 1)
        try await fixture.timer.complete(oldTimer, with: .success(()))
        try await fixture.fast.complete(oldFast, with: .success(FastPathResult(urls: [OpusTestSupport.aacURL])))
        let elapsed = await resolver.elapsedHedgeCount
        let events = await resolver.activeHedgeEventCount
        let extractions = await fixture.extraction.requests
        XCTAssertEqual(elapsed, 0)
        XCTAssertEqual(events, 1)
        XCTAssertTrue(extractions.isEmpty)

        try await fixture.timer.complete(newTimer, with: .success(()))
        let extraction = try await fixture.extraction.request(at: 0)
        try await fixture.extraction.complete(extraction, with: .success([LatePromotionFixture.extractedURL]))
        let stream = try await foreground.value
        let cached = try await resolver.resolve(track: track, forceRefresh: false)
        XCTAssertEqual(stream.url, LatePromotionFixture.extractedURL)
        XCTAssertEqual(cached.url, stream.url, "The retired fast response cannot populate the replacement's cache")
        let remaining = await resolver.activeHedgeEventCount
        XCTAssertEqual(remaining, 0)
    }

    func testForegroundLeavingBeforeHedgeKeepsTheRemainingWarmSpeculative() async throws {
        let fixture = LatePromotionFixture()
        addTeardownBlock { await fixture.close() }
        let resolver = fixture.resolver
        let track = track
        let warm = Task { await resolver.warm([track], download: false, token: UUID()) }
        defer { warm.cancel() }
        let fast = try await fixture.fast.request(at: 0)
        let timer = try await fixture.timer.request(at: 0)
        let foreground = Task { try await resolver.resolve(track: track, forceRefresh: false) }
        defer { foreground.cancel() }
        try await PlaybackTestSupport.eventually { await resolver.activeWaiterCount == 2 }
        foreground.cancel()
        do { _ = try await foreground.value; XCTFail("Expected foreground cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        try await PlaybackTestSupport.eventually { await resolver.activeWaiterCount == 1 }
        try await fixture.timer.complete(timer, with: .success(()))
        try await PlaybackTestSupport.eventually { await resolver.elapsedHedgeCount == 1 }
        let extractions = await fixture.extraction.requests
        XCTAssertTrue(extractions.isEmpty)
        try await fixture.fast.complete(fast, with: .success(FastPathResult(urls: [OpusTestSupport.aacURL])))
        let outcome = await warm.value
        XCTAssertEqual(outcome.resolved, 1)
        let events = await resolver.activeHedgeEventCount
        XCTAssertEqual(events, 0)
    }

    func testElapsedSpeculativeFailureNeverEntersExtractionAndCleansEvents() async throws {
        let fixture = LatePromotionFixture()
        addTeardownBlock { await fixture.close() }
        let resolver = fixture.resolver
        let track = track
        let warm = Task { await resolver.warm([track], download: false, token: UUID()) }
        defer { warm.cancel() }
        let fast = try await fixture.fast.request(at: 0)
        let timer = try await fixture.timer.request(at: 0)
        try await fixture.timer.complete(timer, with: .success(()))
        try await PlaybackTestSupport.eventually { await resolver.elapsedHedgeCount == 1 }
        try await fixture.fast.complete(fast, with: .failure(PlaybackStreamError.noAudio))
        let outcome = await warm.value
        XCTAssertEqual(outcome.failed, 1)
        let extractions = await fixture.extraction.requests
        let events = await resolver.activeHedgeEventCount
        XCTAssertTrue(extractions.isEmpty)
        XCTAssertEqual(events, 0)
    }

    func testForegroundJoiningBeforeWarmFastSuccessKeepsTheWarmedURL() async throws {
        let fixture = LatePromotionFixture()
        addTeardownBlock { await fixture.close() }
        let resolver = fixture.resolver
        let track = track
        let warm = Task { await resolver.warm([track], download: false, token: UUID()) }
        defer { warm.cancel() }
        let fast = try await fixture.fast.request(at: 0)
        _ = try await fixture.timer.request(at: 0)
        let foreground = Task { try await resolver.resolve(track: track, forceRefresh: false) }
        defer { foreground.cancel() }
        try await PlaybackTestSupport.eventually { await resolver.activeWaiterCount == 2 }
        try await fixture.fast.complete(fast, with: .success(FastPathResult(urls: [OpusTestSupport.aacURL])))
        let stream = try await foreground.value
        let outcome = await warm.value
        XCTAssertEqual(outcome.resolved, 1)
        let cached = try await resolver.resolve(track: track, forceRefresh: false)
        XCTAssertEqual(cached.url, stream.url)
        XCTAssertEqual(PlaybackStartTrace.startPath(for: track.id), .warmed)
        let extractions = await fixture.extraction.requests
        let fastRequests = await fixture.fast.requests
        XCTAssertTrue(extractions.isEmpty)
        XCTAssertEqual(fastRequests.count, 1)
    }

    func testQueueAdoptsSameSongWarmDownloadBeforeTheWarmOwnerCancels() async throws {
        let fixture = try makeFixture()
        let gate = AppModelRequestGate<String, FastPathResult>()
        addTeardownBlock { await gate.close() }
        let resolver = YouTubeStreamResolver(extract: { _, _ in [] }, validate: { _ in },
            fastExtract: { try await gate.receive($0) }, audioCache: fixture.cache)
        let track = track
        let token = UUID()
        let warm = Task { await resolver.warm([track], download: true, token: token) }
        defer { warm.cancel() }
        let request = try await gate.request(at: 0)
        try await PlaybackTestSupport.eventually { await resolver.activeWaiterCount == 2 }
        let queue = Task { await resolver.prefetch([track]) }
        defer { queue.cancel() }
        try await PlaybackTestSupport.eventually { await resolver.activeWaiterCount == 3 }
        await resolver.cancelWarm(token: token)
        warm.cancel()
        _ = await warm.value
        let download = await resolver.prefetchDownloadTrackID
        XCTAssertEqual(download, track.id)
        let remaining = await resolver.activeWaiterCount
        XCTAssertEqual(remaining, 2, "Queue resolution and the adopted download retain their ownership")
        try await gate.complete(request, with: .success(FastPathResult(urls: [OpusTestSupport.aacURL])))
        await queue.value
        try await PlaybackTestSupport.eventually { await fixture.cache.entry(for: track.id) != nil }
        try await PlaybackTestSupport.eventually { await resolver.prefetchDownloadTrackID == nil }
        XCTAssertEqual(fixture.mock.state.requests.count, 1)
    }

    // MARK: Startup accounting

    func testAutomaticRetryPreservesTotalElapsedAndAccumulatesEveryStage() {
        let start = ContinuousClock.now
        var timing = PlaybackStartupTiming(at: start)
        timing.beginAttempt(at: start)
        timing.beginResolution(at: start.advanced(by: .milliseconds(100)))
        timing.resolved(path: .fastPath, at: start.advanced(by: .seconds(1)))
        timing.beginAttempt(at: start.advanced(by: .seconds(26)))
        XCTAssertNil(timing.path, "A retry cannot inherit the previous attempt's path")
        timing.beginResolution(at: start.advanced(by: .milliseconds(26_200)))
        timing.resolved(path: .extraction, at: start.advanced(by: .seconds(27)))
        XCTAssertEqual(timing.sample(at: start.advanced(by: .seconds(28))), 28_000)
        XCTAssertEqual(timing.attempts, 2)
        XCTAssertEqual(timing.setup, .milliseconds(300))
        XCTAssertEqual(timing.resolution, .milliseconds(1_700))
        XCTAssertEqual(timing.readyBuffer, .seconds(26))
        XCTAssertEqual(timing.path, .extraction)
    }

    func testNewSelectionOrExplicitRetryResetsStartupAccounting() {
        let start = ContinuousClock.now
        var timing = PlaybackStartupTiming(at: start)
        timing.beginAttempt(at: start)
        timing.beginResolution(at: start)
        timing.resolved(path: .extraction, at: start.advanced(by: .seconds(1)))
        timing = PlaybackStartupTiming(at: start.advanced(by: .seconds(26)))
        timing.beginAttempt(at: start.advanced(by: .seconds(26)))
        XCTAssertEqual(timing.sample(at: start.advanced(by: .seconds(28))), 2_000)
        XCTAssertEqual(timing.attempts, 1)
        XCTAssertEqual(timing.resolution, .zero)
        XCTAssertEqual(timing.readyBuffer, .zero)
        XCTAssertNil(timing.path)
    }

    func testStartupPathIsCapturedBeforeLaterTraceWrites() {
        let id = "startup-trace-fixture"
        let start = ContinuousClock.now
        PlaybackStartTrace.record(.urlCache, for: id)
        PlaybackStartTrace.markWarmed(id)
        var timing = PlaybackStartupTiming(at: start)
        timing.beginAttempt(at: start)
        timing.resolved(path: PlaybackStartTrace.startPath(for: id), at: start)
        PlaybackStartTrace.record(.local, for: id)
        _ = timing.sample(at: start.advanced(by: .seconds(1)))
        XCTAssertEqual(timing.path, .warmed)
        XCTAssertEqual(PlaybackStartTrace.startPath(for: id), .local, "The warm mark was consumed at resolution")
    }

    func testStartupAttemptCounterSaturatesWithoutResettingElapsedTime() {
        let start = ContinuousClock.now
        var timing = PlaybackStartupTiming(at: start)
        for second in 0..<300 {
            timing.beginAttempt(at: start.advanced(by: .seconds(second)))
        }
        XCTAssertEqual(timing.attempts, 255)
        XCTAssertEqual(timing.sample(at: start.advanced(by: .seconds(300))), 300_000)
        XCTAssertEqual(timing.setup, .seconds(300))
    }

    // MARK: Helpers

    /// Opus URLs (itag 251) answer with the WebM stub; every other URL answers with a playable WAV so the AAC fallback
    /// of a complete download can be stored.
    private func makeFixture(handler: CatalogMockState.Handler? = nil,
                             preparation: @escaping AudioCache.OpusPreparation = OpusTestSupport.prepare) throws -> CacheManagementFixture {
        let wav = wav
        let fixture = try CacheManagementFixture(handler: handler ?? { request in
            if request.url?.query?.contains("itag=251") == true {
                return CatalogStub(headers: ["Content-Type": "audio/webm", "Content-Length": "\(OpusTestSupport.webM.count)"],
                                   data: OpusTestSupport.webM)
            }
            return CatalogStub(headers: ["Content-Type": "audio/wav", "Content-Length": "\(wav.count)"], data: wav)
        }, opusPreparation: preparation)
        addTeardownBlock { try await fixture.close() }
        return fixture
    }
}

private struct LatePromotionFixture: Sendable {
    let fast = AppModelRequestGate<String, FastPathResult>()
    let timer = AppModelRequestGate<TimeInterval, Void>()
    let extraction = AppModelRequestGate<String, [URL]>()
    static let extractedURL = URL(string: "https://library.googlevideo.com/videoplayback?dur=8&expire=4000000000")!

    var resolver: YouTubeStreamResolver {
        YouTubeStreamResolver(extract: { [extraction] id, _ in try await extraction.receive(id) }, validate: { _ in },
            fastExtract: { [fast] in try await fast.receive($0) }, hedgeDelay: 2,
            hedgeSleep: { [timer] in try await timer.receive($0) })
    }

    func close() async {
        await fast.close()
        await timer.close()
        await extraction.close()
    }
}

/// Holds or delays either path so a test can decide which one answers first and observe the loser's cancellation.
private actor StreamHedgeFixture {
    private(set) var extractions: [String] = []
    private(set) var fastCancelled = false
    private(set) var extractionCancelled = false
    private var fastContinuations: [CheckedContinuation<FastPathResult, Error>] = []
    private var extractionContinuations: [CheckedContinuation<[URL], Error>] = []

    private static func url(_ host: String, _ id: String) -> URL {
        URL(string: "https://\(host).googlevideo.com/videoplayback?id=\(id)&dur=200&expire=4000000000")!
    }

    func extracted(_ id: String) -> [URL] {
        extractions.append(id)
        return [Self.url("library", id)]
    }

    func holdExtraction(_ id: String) async throws -> [URL] {
        extractions.append(id)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { extractionContinuations.append($0) }
        } onCancel: {
            Task { await self.noteExtractionCancelled() }
        }
    }

    func holdFast(_ id: String) async throws -> FastPathResult {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { fastContinuations.append($0) }
        } onCancel: {
            Task { await self.noteFastCancelled() }
        }
    }

    func fastAfterDelay(_ id: String, _ delay: Duration) async throws -> FastPathResult {
        try await Task.sleep(for: delay)
        return FastPathResult(urls: [Self.url("fast", id)])
    }

    func releaseFast() {
        fastContinuations.forEach { $0.resume(throwing: CancellationError()) }
        fastContinuations.removeAll()
    }

    private func noteFastCancelled() {
        fastCancelled = true
        releaseFast()
    }

    private func noteExtractionCancelled() {
        extractionCancelled = true
        extractionContinuations.forEach { $0.resume(throwing: CancellationError()) }
        extractionContinuations.removeAll()
    }
}

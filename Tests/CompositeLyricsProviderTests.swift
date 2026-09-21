import XCTest
@testable import GanaBajana

@MainActor
final class CompositeLyricsProviderTests: XCTestCase {
    func testPrimarySyncedPlainAndInstrumentalNeverStartFallback() async throws {
        for kind in [LyricsKind.synced, .plain, .instrumental] {
            let primary = ArtistSpotlightLyricsFixture()
            let fallback = ArtistSpotlightLyricsFixture()
            addTeardownBlock { await primary.requests.close(); await fallback.requests.close() }
            var document = LyricsFallbackFixtures.plain(source: .lrcLib)
            document.kind = kind
            document.lines = kind == .synced ? [LyricLine(id: 0, time: 1, text: "An invented lyric")] : []
            await primary.requests.enqueue(.success(document))
            let provider = CompositeLyricsProvider(primary: primary, fallback: fallback)
            let result = try await provider.lyrics(for: LyricsFallbackFixtures.track)
            XCTAssertEqual(result.kind, kind)
            XCTAssertEqual(result.source, "LRCLIB")
            let calls = await fallback.requests.requests
            XCTAssertTrue(calls.isEmpty)
        }
    }

    func testMissingAndFailedPrimaryFallBackToAttributedPlainLyricsAndCache() async throws {
        for failed in [false, true] {
            let primary = ArtistSpotlightLyricsFixture()
            let fallback = ArtistSpotlightLyricsFixture()
            addTeardownBlock { await primary.requests.close(); await fallback.requests.close() }
            await primary.requests.enqueue(failed ? .failure(MusicServiceError.rateLimited)
                : .success(LyricsDocument(trackID: LyricsFallbackFixtures.track.id, kind: .unavailable)))
            await fallback.requests.enqueue(.success(LyricsFallbackFixtures.plain()))
            let provider = CompositeLyricsProvider(primary: primary, fallback: fallback)
            let result = try await provider.lyrics(for: LyricsFallbackFixtures.track)
            XCTAssertEqual(result.kind, .plain)
            XCTAssertTrue(result.lines.isEmpty)
            XCTAssertEqual(result.providerSource, .lyricFind)
            XCTAssertEqual(result.sourceURL, LyricsFallbackFixtures.track.shareURL)
            _ = try await provider.lyrics(for: LyricsFallbackFixtures.track)
            let primaryCalls = await primary.requests.requests.count
            let fallbackCalls = await fallback.requests.requests.count
            XCTAssertEqual(primaryCalls, 1)
            XCTAssertEqual(fallbackCalls, 1)
        }
    }

    func testAllMissingIsUnavailableButAnOutageIsAnErrorAndNotNegativeCached() async throws {
        let track = LyricsFallbackFixtures.track
        for failed in [false, true] {
            let primary = ArtistSpotlightLyricsFixture()
            let fallback = ArtistSpotlightLyricsFixture()
            addTeardownBlock { await primary.requests.close(); await fallback.requests.close() }
            await primary.requests.enqueue(.success(LyricsDocument(trackID: track.id, kind: .unavailable)))
            await fallback.requests.enqueue(failed ? .failure(MusicServiceError.network("Offline fixture"))
                : .success(LyricsDocument(trackID: track.id, kind: .unavailable)))
            let provider = CompositeLyricsProvider(primary: primary, fallback: fallback)
            do {
                let result = try await provider.lyrics(for: track)
                XCTAssertFalse(failed)
                XCTAssertEqual(result.kind, .unavailable)
            } catch {
                XCTAssertTrue(failed)
                let activity = await provider.activity
                XCTAssertEqual(activity.cachedRecordings, 0)
            }
        }
    }

    func testCancellationStopsPrimaryWithoutStartingFallbackOrCachingALateResult() async throws {
        let primary = ArtistSpotlightLyricsFixture()
        let fallback = ArtistSpotlightLyricsFixture()
        addTeardownBlock { await primary.requests.close(); await fallback.requests.close() }
        let provider = CompositeLyricsProvider(primary: primary, fallback: fallback)
        let task = Task { try await provider.lyrics(for: LyricsFallbackFixtures.track) }
        let request = try await primary.requests.request(at: 0)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        try await primary.requests.complete(request, with: .success(LyricsFallbackFixtures.plain(source: .lrcLib)))
        let activity = await provider.activity
        let fallbackCalls = await fallback.requests.requests
        XCTAssertEqual(activity.cachedRecordings, 0)
        XCTAssertEqual(activity.activeLookups, 0)
        XCTAssertTrue(fallbackCalls.isEmpty)
    }

    func testPrimaryTimeoutCanUseFallbackAndLatePrimaryDoesNotReplaceIt() async throws {
        let primary = ArtistSpotlightLyricsFixture()
        let fallback = ArtistSpotlightLyricsFixture()
        addTeardownBlock { await primary.requests.close(); await fallback.requests.close() }
        await fallback.requests.enqueue(.success(LyricsFallbackFixtures.plain()))
        var configuration = CompositeLyricsProvider.Configuration()
        configuration.primaryTimeout = 0.2
        let provider = CompositeLyricsProvider(primary: primary, fallback: fallback, configuration: configuration)
        let task = Task { try await provider.lyrics(for: LyricsFallbackFixtures.track) }
        let request = try await primary.requests.request(at: 0)
        let result = try await task.value
        XCTAssertEqual(result.providerSource, .lyricFind)
        try await primary.requests.complete(request, with: .success(LyricsFallbackFixtures.plain(source: .lrcLib)))
        let cached = try await provider.lyrics(for: LyricsFallbackFixtures.track)
        XCTAssertEqual(cached.providerSource, .lyricFind)
    }

    func testConcurrentWaitersCoalesceAndOneCanCancelWithoutAffectingTheOther() async throws {
        let primary = ArtistSpotlightLyricsFixture()
        addTeardownBlock { await primary.requests.close() }
        let provider = CompositeLyricsProvider(primary: primary, fallback: nil)
        let first = Task { try await provider.lyrics(for: LyricsFallbackFixtures.track) }
        let request = try await primary.requests.request(at: 0)
        let second = Task { try await provider.lyrics(for: LyricsFallbackFixtures.track) }
        try await AppModelFixtures.eventually { await provider.activity.waitingCallers == 2 }
        first.cancel()
        do { _ = try await first.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        try await primary.requests.complete(request, with: .success(LyricsFallbackFixtures.plain(source: .lrcLib)))
        let result = try await second.value
        XCTAssertEqual(result.trackID, LyricsFallbackFixtures.track.id)
        let calls = await primary.requests.requests.count
        XCTAssertEqual(calls, 1)
    }

    func testWrongRecordingCannotBecomeSuccessfulFallback() async throws {
        let primary = ArtistSpotlightLyricsFixture()
        let fallback = ArtistSpotlightLyricsFixture()
        addTeardownBlock { await primary.requests.close(); await fallback.requests.close() }
        await primary.requests.enqueue(.success(LyricsDocument(trackID: LyricsFallbackFixtures.track.id, kind: .unavailable)))
        var wrong = LyricsFallbackFixtures.plain()
        wrong.trackID = "another-recording"
        await fallback.requests.enqueue(.success(wrong))
        let provider = CompositeLyricsProvider(primary: primary, fallback: fallback)
        do { _ = try await provider.lyrics(for: LyricsFallbackFixtures.track); XCTFail("Accepted another recording") }
        catch { XCTAssertTrue(error is LyricsLookupError) }
    }

    func testFallbackCacheExpiresSoPrimarySyncedLyricsCanRecover() async throws {
        let primary = ArtistSpotlightLyricsFixture()
        let fallback = ArtistSpotlightLyricsFixture()
        addTeardownBlock { await primary.requests.close(); await fallback.requests.close() }
        let clock = LyricsTestClock()
        await primary.requests.enqueue(.success(LyricsDocument(trackID: LyricsFallbackFixtures.track.id, kind: .unavailable)))
        await fallback.requests.enqueue(.success(LyricsFallbackFixtures.plain()))
        var configuration = CompositeLyricsProvider.Configuration()
        configuration.fallbackLifetime = 10
        let provider = CompositeLyricsProvider(primary: primary, fallback: fallback, configuration: configuration, now: { clock.now() })
        let first = try await provider.lyrics(for: LyricsFallbackFixtures.track)
        XCTAssertEqual(first.kind, .plain)
        clock.advance(11)
        var synced = LyricsFallbackFixtures.plain(source: .lrcLib)
        synced.kind = .synced
        synced.lines = [LyricLine(id: 0, time: 1, text: "An invented lyric")]
        await primary.requests.enqueue(.success(synced))
        let refreshed = try await provider.lyrics(for: LyricsFallbackFixtures.track)
        XCTAssertEqual(refreshed.kind, .synced)
        let calls = await fallback.requests.requests.count
        XCTAssertEqual(calls, 1)
    }
}

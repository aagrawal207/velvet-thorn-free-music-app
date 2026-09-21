import XCTest
@testable import GanaBajana

@MainActor
final class ArtistSpotlightLanguageServiceTests: XCTestCase {
    func testRecordingMetadataSkipsLyricsAndUnknownDoesNotInheritIt() async throws {
        let provider = ArtistSpotlightLyricsFixture()
        addTeardownBlock { await provider.requests.close() }
        let service = ArtistSpotlightLanguageService(provider: provider)
        let result = try await service.classification(for: ArtistSpotlightTestSupport.track("hi", language: .hindi))
        XCTAssertEqual(result, .identified(.hindi, source: .recordingMetadata))
        let requests = await provider.requests.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testCoalescedCallersShareClassificationAndOneCancellationDoesNotCancelTheOther() async throws {
        let provider = ArtistSpotlightLyricsFixture()
        addTeardownBlock { await provider.requests.close() }
        let service = ArtistSpotlightLanguageService(provider: provider, hypotheses: { _ in ["en": 0.99] })
        let track = ArtistSpotlightTestSupport.track("first")
        let first = Task { try await service.classification(for: track) }
        let request = try await provider.requests.request(at: 0)
        let secondTrack = track
        let second = Task { try await service.classification(for: secondTrack) }
        try await AppModelFixtures.eventually { await service.activity.waitingCallers == 2 }
        first.cancel()
        do { _ = try await first.value; XCTFail("Cancelled waiter completed") }
        catch is CancellationError { }
        try await provider.requests.complete(request, with: .success(ArtistSpotlightTestSupport.document(track)))
        let result = try await second.value
        XCTAssertEqual(result, .identified(.english, source: .matchedLyrics))
        _ = try await service.classification(for: secondTrack)
        let requests = await provider.requests.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testLastCancellationCannotPopulateCacheOrReplaceANewerFlight() async throws {
        let provider = ArtistSpotlightLyricsFixture()
        addTeardownBlock { await provider.requests.close() }
        let service = ArtistSpotlightLanguageService(provider: provider, hypotheses: ArtistSpotlightTestSupport.originalScriptHypotheses)
        let track = ArtistSpotlightTestSupport.track("same-key")
        let first = Task { try await service.classification(for: track) }
        let stale = try await provider.requests.request(at: 0)
        first.cancel()
        do { _ = try await first.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        let cancelled = await service.activity
        XCTAssertEqual(cancelled.activeLookups, 0)
        XCTAssertEqual(cancelled.cachedRecordings, 0)
        let second = Task { try await service.classification(for: track) }
        let current = try await provider.requests.request(at: 1)
        try await provider.requests.complete(current, with: .success(ArtistSpotlightTestSupport.document(track)))
        let result = try await second.value
        XCTAssertEqual(result.language, .english)
        try await provider.requests.complete(stale, with: .success(ArtistSpotlightTestSupport.document(track, text: ArtistSpotlightFixtures.tamilText)))
        let cached = try await service.classification(for: track)
        XCTAssertEqual(cached.language, .english)
        let requests = await provider.requests.requests
        XCTAssertEqual(requests.count, 2)
    }

    func testUnknownResultsExpireSoonerAndNetworkFailuresAreNotCached() async throws {
        let clock = LyricsTestClock()
        let provider = ArtistSpotlightLyricsFixture()
        addTeardownBlock { await provider.requests.close() }
        var configuration = ArtistSpotlightLanguageService.Configuration()
        configuration.negativeLifetime = 10
        configuration.positiveLifetime = 100
        let service = ArtistSpotlightLanguageService(provider: provider, configuration: configuration,
            hypotheses: { _ in ["en": 0.99] }, now: { clock.now() })
        let track = ArtistSpotlightTestSupport.track("cache")
        await provider.requests.enqueue(.success(LyricsDocument(trackID: track.id, kind: .unavailable)))
        let missing = try await service.classification(for: track)
        XCTAssertNil(missing.language)
        _ = try await service.classification(for: track)
        let cachedRequests = await provider.requests.requests.count
        XCTAssertEqual(cachedRequests, 1)
        clock.advance(11)
        await provider.requests.enqueue(.failure(MusicServiceError.network("Synthetic offline failure")))
        do { _ = try await service.classification(for: track); XCTFail("Expected a retryable error") }
        catch { XCTAssertTrue(error is MusicServiceError) }
        let afterFailure = await service.activity
        XCTAssertEqual(afterFailure.cachedRecordings, 0)
        await provider.requests.enqueue(.success(ArtistSpotlightTestSupport.document(track)))
        let recovered = try await service.classification(for: track)
        XCTAssertEqual(recovered.language, .english)
        clock.advance(11)
        _ = try await service.classification(for: track)
        let requests = await provider.requests.requests.count
        XCTAssertEqual(requests, 3)
        clock.advance(101)
        await provider.requests.enqueue(.success(ArtistSpotlightTestSupport.document(track)))
        _ = try await service.classification(for: track)
        let expiredRequests = await provider.requests.requests.count
        XCTAssertEqual(expiredRequests, 4)
    }

    func testCacheEvictsLeastRecentlyUsedRecordingAndChangedMetadataHasADifferentKey() async throws {
        let provider = ArtistSpotlightLyricsFixture()
        addTeardownBlock { await provider.requests.close() }
        var configuration = ArtistSpotlightLanguageService.Configuration()
        configuration.capacity = 2
        let service = ArtistSpotlightLanguageService(provider: provider, configuration: configuration, hypotheses: { _ in ["en": 0.99] })
        let first = ArtistSpotlightTestSupport.track("first")
        let second = ArtistSpotlightTestSupport.track("second")
        var changed = first
        changed.title = "A different recording with a reused identifier"
        for track in [first, second] {
            await provider.requests.enqueue(.success(ArtistSpotlightTestSupport.document(track)))
            _ = try await service.classification(for: track)
        }
        _ = try await service.classification(for: first)
        await provider.requests.enqueue(.success(ArtistSpotlightTestSupport.document(changed)))
        _ = try await service.classification(for: changed)
        _ = try await service.classification(for: first)
        await provider.requests.enqueue(.success(ArtistSpotlightTestSupport.document(second)))
        _ = try await service.classification(for: second)
        let activity = await service.activity
        let requests = await provider.requests.requests.count
        XCTAssertEqual(activity.cachedRecordings, 2)
        XCTAssertEqual(requests, 4)
    }

    func testDeadlineAndConcurrencyLimitsBoundUncooperativeProviderWork() async throws {
        let provider = ArtistSpotlightLyricsFixture()
        addTeardownBlock { await provider.requests.close() }
        var configuration = ArtistSpotlightLanguageService.Configuration()
        configuration.lookupTimeout = 0.3
        configuration.maximumConcurrentLookups = 1
        configuration.maximumWaitersPerLookup = 1
        let service = ArtistSpotlightLanguageService(provider: provider, configuration: configuration, hypotheses: { _ in ["en": 0.99] })
        let track = ArtistSpotlightTestSupport.track("deadline")
        let first = Task { try await service.classification(for: track) }
        let request = try await provider.requests.request(at: 0)
        for other in [track, ArtistSpotlightTestSupport.track("another")] {
            do { _ = try await service.classification(for: other); XCTFail("Expected bounded work") }
            catch { XCTAssertTrue(error is MusicServiceError) }
        }
        do { _ = try await first.value; XCTFail("Expected deadline") }
        catch PlaybackStreamError.timedOut { }
        let activity = await service.activity
        XCTAssertEqual(activity.activeLookups, 0)
        XCTAssertEqual(activity.cachedRecordings, 0)
        try await provider.requests.complete(request, with: .success(ArtistSpotlightTestSupport.document(track)))
        await provider.requests.enqueue(.success(ArtistSpotlightTestSupport.document(track)))
        let retry = try await service.classification(for: track)
        XCTAssertEqual(retry.language, .english)
    }
}

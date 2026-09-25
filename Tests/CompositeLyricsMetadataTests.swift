import XCTest
@testable import GanaBajana

@MainActor
final class CompositeLyricsMetadataTests: XCTestCase {
    func testMissingDurationIsPreparedOnceWithoutChangingOtherFieldsOrTheCaller() async throws {
        let primary = ArtistSpotlightLyricsFixture()
        addTeardownBlock { await primary.requests.close() }
        var track = LyricsFallbackFixtures.track
        track.duration = nil
        let original = track
        let preparations = CatalogTestRecorder<String>()
        let provider = CompositeLyricsProvider(primary: primary, fallback: nil, prepareTrack: { value in
            preparations.record(value.id)
            var prepared = value
            prepared.duration = 262
            prepared.title = "Unrelated title must not replace catalog metadata"
            return prepared
        })
        let pending = Task { try await provider.lyrics(for: original) }
        let request = try await primary.requests.request(at: 0)
        XCTAssertEqual(request.input.duration, 262)
        XCTAssertEqual(request.input.title, original.title)
        XCTAssertEqual(request.input.credits, original.credits)
        try await primary.requests.complete(request, with: .success(LyricsFallbackFixtures.plain(source: .lrcLib)))
        _ = try await pending.value
        _ = try await provider.lyrics(for: original)
        XCTAssertEqual(preparations.values, [original.id])
        XCTAssertNil(original.duration)
    }

    func testKnownDurationDoesNotTriggerAnOptionalMetadataLookup() async throws {
        let primary = ArtistSpotlightLyricsFixture()
        addTeardownBlock { await primary.requests.close() }
        await primary.requests.enqueue(.success(LyricsFallbackFixtures.plain(source: .lrcLib)))
        let calls = CatalogTestRecorder<String>()
        let provider = CompositeLyricsProvider(primary: primary, fallback: nil, prepareTrack: { value in
            calls.record(value.id)
            return value
        })
        _ = try await provider.lyrics(for: LyricsFallbackFixtures.track)
        XCTAssertTrue(calls.values.isEmpty)
    }

    func testForeignMissingAndFailedMetadataPreserveTheLyricsRequest() async throws {
        for scenario in 0..<3 {
            let primary = ArtistSpotlightLyricsFixture()
            addTeardownBlock { await primary.requests.close() }
            var track = LyricsFallbackFixtures.track
            track.duration = nil
            let original = track
            let provider = CompositeLyricsProvider(primary: primary, fallback: nil, prepareTrack: { value in
                if scenario == 0 { throw YouTubeDataAPI.RequestError.quotaExceeded }
                var result = value
                if scenario == 1 { result.id = "wrong-recording"; result.duration = 300 }
                return result
            })
            let pending = Task { try await provider.lyrics(for: original) }
            let request = try await primary.requests.request(at: 0)
            XCTAssertEqual(request.input, original)
            try await primary.requests.complete(request, with: .success(LyricsFallbackFixtures.plain(source: .lrcLib)))
            let result = try await pending.value
            XCTAssertEqual(result.kind, .plain)
        }
    }

    func testMetadataTimeoutDoesNotPreventLyricsFromLoading() async throws {
        let primary = ArtistSpotlightLyricsFixture()
        addTeardownBlock { await primary.requests.close() }
        await primary.requests.enqueue(.success(LyricsFallbackFixtures.plain(source: .lrcLib)))
        var track = LyricsFallbackFixtures.track
        track.duration = nil
        var configuration = CompositeLyricsProvider.Configuration()
        configuration.metadataTimeout = 0.05
        let provider = CompositeLyricsProvider(primary: primary, fallback: nil, prepareTrack: { value in
            try await Task.sleep(for: .seconds(30))
            return value
        }, configuration: configuration)
        let result = try await provider.lyrics(for: track)
        XCTAssertEqual(result.kind, .plain)
    }

    func testCancellationDuringMetadataDoesNotStartLyrics() async throws {
        let primary = ArtistSpotlightLyricsFixture()
        let metadata = AppModelRequestGate<Track, Track>()
        addTeardownBlock { await primary.requests.close(); await metadata.close() }
        var track = LyricsFallbackFixtures.track
        track.duration = nil
        let original = track
        let provider = CompositeLyricsProvider(primary: primary, fallback: nil,
                                              prepareTrack: { try await metadata.receive($0) })
        let pending = Task { try await provider.lyrics(for: original) }
        let request = try await metadata.request(at: 0)
        pending.cancel()
        do { _ = try await pending.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        try await metadata.complete(request, with: .success(original))
        let calls = await primary.requests.requests
        let activity = await provider.activity
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(activity.cachedRecordings, 0)
    }
}

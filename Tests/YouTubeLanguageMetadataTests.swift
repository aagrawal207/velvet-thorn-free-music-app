import XCTest
@testable import GanaBajana

@MainActor
final class YouTubeLanguageMetadataTests: XCTestCase {
    func testExplicitAudioLanguageSkipsLyricsWorkLookupAndClassificationAndIsCached() async throws {
        let lyrics = ArtistSpotlightLyricsFixture()
        addTeardownBlock { await lyrics.requests.close() }
        let events = CatalogTestRecorder<String>()
        let clock = CatalogTestClock()
        var configuration = ArtistSpotlightLanguageService.Configuration()
        configuration.positiveLifetime = 60
        let service = ArtistSpotlightLanguageService(provider: lyrics, configuration: configuration,
            hypotheses: { _ in events.record("classification"); return ["en": 0.99] }, now: { clock.now },
            recordingMetadataLookup: { _ in events.record("audio-language"); return .identified(.hindi, source: .youTubeAudioLanguage) },
            metadataLookup: { _ in events.record("work"); return nil })
        let track = ArtistSpotlightTestSupport.track(CatalogFixtures.hindiID)
        for _ in 0..<3 {
            let result = try await service.classification(for: track)
            XCTAssertEqual(result, .identified(.hindi, source: .youTubeAudioLanguage))
        }
        XCTAssertEqual(events.values, ["audio-language"])
        let requests = await lyrics.requests.requests
        XCTAssertTrue(requests.isEmpty)
        clock.advance(61)
        _ = try await service.classification(for: track)
        XCTAssertEqual(events.values, ["audio-language", "audio-language"])
    }

    func testExplicitUnsupportedMixedAndNonlinguisticTagsDoNotBecomeGuessedEnglish() async throws {
        for result in [ArtistSongLanguageResult.unclassified(.uncertainLanguage), .unclassified(.conflictingEvidence),
                       .unclassified(.noMatchedLyrics)] {
            let lyrics = ArtistSpotlightLyricsFixture()
            addTeardownBlock { await lyrics.requests.close() }
            let service = ArtistSpotlightLanguageService(provider: lyrics,
                recordingMetadataLookup: { _ in result })
            let actual = try await service.classification(for: ArtistSpotlightTestSupport.track(CatalogFixtures.hindiID))
            XCTAssertEqual(actual, result)
            let requests = await lyrics.requests.requests
            XCTAssertTrue(requests.isEmpty)
        }
    }

    func testMissingFailedAndWeakProviderMetadataUseAndCacheTheExistingClassifier() async throws {
        for scenario in 0..<3 {
            let lyrics = ArtistSpotlightLyricsFixture()
            addTeardownBlock { await lyrics.requests.close() }
            let track = ArtistSpotlightTestSupport.track(CatalogFixtures.englishID)
            await lyrics.requests.enqueue(.success(ArtistSpotlightTestSupport.document(track, text: ArtistSpotlightTestSupport.englishRockText)))
            let events = CatalogTestRecorder<String>()
            let service = ArtistSpotlightLanguageService(provider: lyrics,
                hypotheses: { _ in events.record("classification"); return ["en": 0.99] },
                recordingMetadataLookup: { _ in
                    events.record("metadata")
                    if scenario == 1 { throw YouTubeDataAPI.RequestError.quotaExceeded }
                    if scenario == 2 { return .likely(.hindi, source: .titleLabel) }
                    return nil
                })
            let first = try await service.classification(for: track)
            let cached = try await service.classification(for: track)
            XCTAssertEqual(first, .identified(.english, source: .matchedLyrics))
            XCTAssertEqual(cached, first)
            XCTAssertEqual(events.values.filter { $0 == "metadata" }.count, 1)
            XCTAssertTrue(events.values.contains("classification"))
            let requests = await lyrics.requests.requests
            XCTAssertEqual(requests.count, 1)
        }
    }

    func testProviderMetadataDeadlineLeavesTheClassifierUsable() async throws {
        let lyrics = ArtistSpotlightLyricsFixture()
        addTeardownBlock { await lyrics.requests.close() }
        let track = ArtistSpotlightTestSupport.track(CatalogFixtures.englishID)
        await lyrics.requests.enqueue(.success(ArtistSpotlightTestSupport.document(track, text: ArtistSpotlightTestSupport.englishRockText)))
        let events = CatalogTestRecorder<String>()
        var configuration = ArtistSpotlightLanguageService.Configuration()
        configuration.recordingMetadataTimeout = 0.05
        let service = ArtistSpotlightLanguageService(provider: lyrics, configuration: configuration,
            hypotheses: { _ in ["en": 0.99] }, recordingMetadataLookup: { _ in
                try await withTaskCancellationHandler {
                    try await Task.sleep(for: .seconds(30))
                    return .identified(.hindi, source: .youTubeAudioLanguage)
                } onCancel: { events.record("cancelled") }
            })
        let result = try await service.classification(for: track)
        XCTAssertEqual(result, .identified(.english, source: .matchedLyrics))
        try await AppModelFixtures.eventually { events.values.contains("cancelled") }
    }

    func testCancellationDuringProviderMetadataDoesNotStartLyricsOrCacheALateTag() async throws {
        let lyrics = ArtistSpotlightLyricsFixture()
        let gate = AppModelRequestGate<Track, ArtistSongLanguageResult?>()
        addTeardownBlock { await lyrics.requests.close(); await gate.close() }
        let track = ArtistSpotlightTestSupport.track(CatalogFixtures.hindiID)
        let service = ArtistSpotlightLanguageService(provider: lyrics,
            recordingMetadataLookup: { try await gate.receive($0) })
        let pending = Task { try await service.classification(for: track) }
        let blocked = try await gate.request(at: 0)
        pending.cancel()
        do { _ = try await pending.value; XCTFail("Cancelled lookup returned a language") }
        catch is CancellationError { }
        try await gate.complete(blocked, with: .success(.identified(.hindi, source: .youTubeAudioLanguage)))
        let requests = await lyrics.requests.requests
        let activity = await service.activity
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(activity.cachedRecordings, 0)
        XCTAssertEqual(activity.activeLookups, 0)
    }

    func testExplicitAudioLanguageRoundTripsThroughTheBoundedDerivedCache() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("YouTubeLanguageCache-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(ListeningLanguageDiscoveryCache.fileName)
        let track = ArtistSpotlightTestSupport.track(CatalogFixtures.hindiID)
        let result = ArtistSongLanguageResult.identified(.hindi, source: .youTubeAudioLanguage)
        let date = Date(timeIntervalSince1970: 1_790_200_000)
        let entry = ListeningLanguageDiscoveryCache.Entry(key: LyricsRequestKey(track), result: result,
            checkedAt: date, expiresAt: date.addingTimeInterval(ListeningLanguageDiscoveryCache.positiveLifetime))
        let cache = ListeningLanguageDiscoveryCache(url: url)
        let saved = await cache.save([entry], revision: 1)
        XCTAssertEqual(saved, .saved)
        let reloaded = await ListeningLanguageDiscoveryCache(url: url).load()
        XCTAssertEqual(reloaded.status, .loaded)
        XCTAssertEqual(reloaded.entries, [entry])
        XCTAssertFalse(try XCTUnwrap(reloaded.entries.first).isReusable(at: entry.expiresAt))
        let overridden = ArtistSpotlight.languageResult(for: track, in: [track.id: result], overrides: [track.id: "ta"])
        XCTAssertEqual(overridden, .identified(.tamil, source: .userOverride))
    }

    func testRealAPIClientIsWiredIntoTheLanguageServiceWithoutCallingLyrics() async throws {
        let id = CatalogFixtures.hindiID
        let json: CatalogJSON = ["items": [["id": .string(id), "snippet": ["defaultAudioLanguage": "hi"],
                                            "contentDetails": ["duration": "PT4M22S"]]]]
        let data = try json.encoded()
        let mock = CatalogMockSession { _ in CatalogStub(data: data) }
        defer { mock.close() }
        let api = YouTubeDataAPI(apiKey: "AIza" + String(repeating: "0", count: 35), session: mock.session)
        let lyrics = ArtistSpotlightLyricsFixture()
        addTeardownBlock { await lyrics.requests.close() }
        let service = ArtistSpotlightLanguageService(provider: lyrics, recordingMetadataLookup: { try await api.recordingLanguage(for: $0) })
        let result = try await service.classification(for: ArtistSpotlightTestSupport.track(id))
        XCTAssertEqual(result, .identified(.hindi, source: .youTubeAudioLanguage))
        XCTAssertEqual(mock.state.requests.count, 1)
        let requests = await lyrics.requests.requests
        XCTAssertTrue(requests.isEmpty)
    }
}

import XCTest
@testable import GanaBajana

@MainActor
final class YouTubeDataAPITests: XCTestCase {
    private nonisolated static let key = "AIza" + String(repeating: "0", count: 35)
    private let id = CatalogFixtures.hindiID

    private nonisolated static func response(_ id: String, language: String? = "hi", duration: String = "PT4M22S") throws -> Data {
        let snippet: CatalogJSON
        if let language { snippet = ["defaultAudioLanguage": .string(language), "defaultLanguage": "en"] }
        else { snippet = ["defaultLanguage": "en"] }
        let json: CatalogJSON = ["items": [["id": .string(id), "snippet": snippet, "contentDetails": ["duration": .string(duration)]]]]
        return try json.encoded()
    }

    func testUnitHostsDoNotEnableBundledProductionCredentials() {
        XCTAssertNil(YouTubeDataAPI.configured())
    }

    func testOversizedResponseIsRejectedWithoutCachingMetadata() async throws {
        let mock = CatalogMockSession { _ in CatalogStub(data: Data(repeating: 32, count: 256 * 1024 + 1)) }
        defer { mock.close() }
        let api = YouTubeDataAPI(apiKey: Self.key, session: mock.session)
        do { _ = try await api.metadata(for: id); XCTFail("Oversized response accepted") }
        catch { XCTAssertEqual(error as? YouTubeDataAPI.RequestError, .unavailable) }
        let activity = await api.activity
        XCTAssertEqual(activity.cachedRecordings, 0)
    }

    func testWaiterAndActiveLookupLimitsDoNotCreateAdditionalRequests() async throws {
        let id = id
        let gate = AppModelRequestGate<String, Void>()
        addTeardownBlock { await gate.close() }
        let mock = CatalogMockSession { _ in
            CatalogStub(data: try Self.response(id), beforeDelivery: { try await gate.receive(id) })
        }
        defer { mock.close() }
        var configuration = YouTubeDataAPI.Configuration()
        configuration.maximumWaiters = 1
        configuration.maximumConcurrentLookups = 1
        let api = YouTubeDataAPI(apiKey: Self.key, session: mock.session, configuration: configuration)
        let first = Task { try await api.metadata(for: id) }
        defer { first.cancel() }
        let blocked = try await gate.request(at: 0)
        for requestedID in [id, CatalogFixtures.englishID] {
            do { _ = try await api.metadata(for: requestedID); XCTFail("Expected bounded admission") }
            catch { XCTAssertEqual(error as? YouTubeDataAPI.RequestError, .busy) }
        }
        XCTAssertEqual(mock.state.requests.count, 1)
        try await gate.complete(blocked, with: .success(()))
        _ = try await first.value
    }

    func testOfficialRequestUsesRestrictedHeadersAndOnlyRecordingMetadata() async throws {
        let id = id
        let mock = CatalogMockSession { request in
            XCTAssertEqual(request.url?.scheme, "https")
            XCTAssertEqual(request.url?.host, "www.googleapis.com")
            XCTAssertEqual(request.url?.path, "/youtube/v3/videos")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Goog-Api-Key"), Self.key)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Ios-Bundle-Identifier"), "com.agraabhi.ganabajana")
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertFalse(request.httpShouldHandleCookies)
            let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(query.first { $0.name == "id" }?.value, id)
            XCTAssertEqual(query.first { $0.name == "part" }?.value, "snippet,contentDetails")
            XCTAssertEqual(query.first { $0.name == "fields" }?.value,
                           "items(id,snippet(defaultAudioLanguage),contentDetails(duration))")
            XCTAssertNil(query.first { $0.name == "key" })
            return CatalogStub(data: try Self.response(id))
        }
        defer { mock.close() }
        let api = YouTubeDataAPI(apiKey: Self.key, session: mock.session)
        let result = try await api.metadata(for: id)
        XCTAssertEqual(result?.duration, 262)
        XCTAssertEqual(result?.language, .identified(.hindi, source: .youTubeAudioLanguage))
    }

    func testDurationParsingUsesIndependentISOBoundaries() {
        for (input, expected) in [("PT4M22S", 262.0), ("PT1H2M3S", 3723), ("P1DT2H", 93600),
                                  ("P1D", 86400), ("PT0.5S", 0.5), ("PT60S", 60)] {
            XCTAssertEqual(CatalogText.iso8601Duration(input), expected, input)
        }
        for input in ["", "P", "PT", "P1DT", "P1Y", "PTNaNS", "-PT1S", "PT1M2H", "PT0S", "PT999999999S", "PT1S\n", "4:22"] {
            XCTAssertNil(CatalogText.iso8601Duration(input), input)
        }
    }

    func testOnlyTheAudioLanguageFieldCanIdentifyTheRecording() throws {
        let withoutAudioLanguage = try YouTubeDataAPI.parse(Self.response(id, language: nil), videoID: id)
        XCTAssertNil(withoutAudioLanguage?.language, "English titles/descriptions do not establish a Hindi recording's language")
        for (code, language) in [("hi-Latn-IN", ArtistSongLanguage.hindi), ("en-US", .english),
                                  ("bn", .bengali), ("tam", .tamil), ("te-IN", .telugu)] {
            let result = try YouTubeDataAPI.parse(Self.response(id, language: code), videoID: id)
            XCTAssertEqual(result?.language, .identified(language, source: .youTubeAudioLanguage))
        }
        XCTAssertEqual(ArtistSongLanguageResult.youTubeAudioLanguage("es"), .unclassified(.uncertainLanguage))
        XCTAssertEqual(ArtistSongLanguageResult.youTubeAudioLanguage("und"), .unclassified(.uncertainLanguage))
        XCTAssertEqual(ArtistSongLanguageResult.youTubeAudioLanguage("mul"), .unclassified(.conflictingEvidence))
        XCTAssertEqual(ArtistSongLanguageResult.youTubeAudioLanguage("zxx"), .unclassified(.noMatchedLyrics))
        for input in [nil, "", "not a language", "en_US", "en-", String(repeating: "e", count: 65)] {
            XCTAssertNil(ArtistSongLanguageResult.youTubeAudioLanguage(input))
        }
    }

    func testForeignDuplicateAndMalformedResultsAreNotAcceptedAsMetadata() throws {
        XCTAssertThrowsError(try YouTubeDataAPI.parse(Self.response(CatalogFixtures.englishID), videoID: id))
        let malformed: [CatalogJSON] = [["items": .null], ["items": [["id": .string(id)], ["id": .string(id)]]], []]
        for json in malformed {
            XCTAssertThrowsError(try YouTubeDataAPI.parse(json.encoded(), videoID: id))
        }
        XCTAssertThrowsError(try YouTubeDataAPI.parse(Data("not json".utf8), videoID: id))
        XCTAssertNil(try YouTubeDataAPI.parse(Data(#"{"items":[]}"#.utf8), videoID: id))
    }

    func testPositiveAndMissingMetadataHaveBoundedCacheLifetimes() async throws {
        let id = id
        let clock = CatalogTestClock()
        let mock = CatalogMockSession { request in
            let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
            return CatalogStub(data: query?.first { $0.name == "id" }?.value == id
                               ? try Self.response(id) : Data(#"{"items":[]}"#.utf8))
        }
        defer { mock.close() }
        var configuration = YouTubeDataAPI.Configuration()
        configuration.lifetime = 60
        configuration.missingLifetime = 10
        let api = YouTubeDataAPI(apiKey: Self.key, session: mock.session, configuration: configuration, now: { clock.now })
        _ = try await api.metadata(for: id)
        _ = try await api.metadata(for: id)
        let missing = try await api.metadata(for: CatalogFixtures.englishID)
        XCTAssertNil(missing)
        _ = try await api.metadata(for: CatalogFixtures.englishID)
        XCTAssertEqual(mock.state.requests.count, 2)
        clock.advance(11)
        _ = try await api.metadata(for: CatalogFixtures.englishID)
        _ = try await api.metadata(for: id)
        XCTAssertEqual(mock.state.requests.count, 3)
        clock.advance(50)
        _ = try await api.metadata(for: id)
        XCTAssertEqual(mock.state.requests.count, 4)
    }

    func testCacheCapacityAndClockRollbackCannotRetainUnboundedOrFutureEntries() async throws {
        let clock = CatalogTestClock()
        let mock = CatalogMockSession { request in
            let id = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value
            return CatalogStub(data: try Self.response(try XCTUnwrap(id)))
        }
        defer { mock.close() }
        var configuration = YouTubeDataAPI.Configuration()
        configuration.capacity = 1
        let api = YouTubeDataAPI(apiKey: Self.key, session: mock.session, configuration: configuration, now: { clock.now })
        _ = try await api.metadata(for: id)
        _ = try await api.metadata(for: CatalogFixtures.englishID)
        _ = try await api.metadata(for: id)
        let activity = await api.activity
        XCTAssertEqual(activity.cachedRecordings, 1)
        XCTAssertEqual(mock.state.requests.count, 3)
        clock.advance(-1)
        _ = try await api.metadata(for: id)
        XCTAssertEqual(mock.state.requests.count, 4)
    }

    func testQuotaExhaustionDefersOtherRecordingsUntilPacificMidnight() async throws {
        let id = id
        let clock = CatalogTestClock()
        let counter = CatalogTestCounter()
        let mock = CatalogMockSession { _ in
            if counter.increment() == 1 {
                return CatalogStub(status: 403, data: Data(#"{"error":{"errors":[{"reason":"quotaExceeded"}]}}"#.utf8))
            }
            return CatalogStub(data: try Self.response(id))
        }
        defer { mock.close() }
        let api = YouTubeDataAPI(apiKey: Self.key, session: mock.session, now: { clock.now })
        for value in [id, CatalogFixtures.englishID] {
            do { _ = try await api.metadata(for: value); XCTFail("Exceeded quota was not respected") }
            catch { XCTAssertEqual(error as? YouTubeDataAPI.RequestError, .quotaExceeded) }
        }
        XCTAssertEqual(mock.state.requests.count, 1)
        let reset = YouTubeDataAPI.nextQuotaReset(after: clock.now)
        clock.advance(reset.timeIntervalSince(clock.now))
        let result = try await api.metadata(for: id)
        XCTAssertEqual(result?.duration, 262)
        XCTAssertEqual(mock.state.requests.count, 2)
    }

    func testQuotaResetUsesPacificCalendarAcrossDaylightSavingChanges() throws {
        let formatter = ISO8601DateFormatter()
        for (input, expected) in [("2026-03-08T09:30:00Z", "2026-03-09T07:00:00Z"),
                                  ("2026-11-01T08:30:00Z", "2026-11-02T08:00:00Z")] {
            let actual = YouTubeDataAPI.nextQuotaReset(after: try XCTUnwrap(formatter.date(from: input)))
            XCTAssertEqual(actual, formatter.date(from: expected))
        }
    }

    func testRateAndCredentialFailuresBackOffWithoutRepeatedRequests() async throws {
        for (status, delay, expected) in [(429, 120.0, YouTubeDataAPI.RequestError.rateLimited),
                                          (403, 3600.0, .credentialsRejected), (503, 120.0, .unavailable)] {
            let id = id
            let counter = CatalogTestCounter()
            let clock = CatalogTestClock()
            let mock = CatalogMockSession { _ in
                if counter.increment() == 1 {
                    return CatalogStub(status: status, headers: ["Retry-After": "120"], data: Data("{}".utf8))
                }
                return CatalogStub(data: try Self.response(id))
            }
            defer { mock.close() }
            let api = YouTubeDataAPI(apiKey: Self.key, session: mock.session, now: { clock.now })
            do { _ = try await api.metadata(for: id); XCTFail("Expected provider failure") }
            catch { XCTAssertEqual(error as? YouTubeDataAPI.RequestError, expected) }
            clock.advance(delay - 1)
            do { _ = try await api.metadata(for: id); XCTFail("Expected cooldown") }
            catch { XCTAssertEqual(error as? YouTubeDataAPI.RequestError, expected) }
            XCTAssertEqual(mock.state.requests.count, 1)
            clock.advance(2)
            _ = try await api.metadata(for: id)
            XCTAssertEqual(mock.state.requests.count, 2)
        }
    }

    func testCoalescedRequestSurvivesOneCallerCancellation() async throws {
        let id = id
        let gate = AppModelRequestGate<String, Void>()
        addTeardownBlock { await gate.close() }
        let mock = CatalogMockSession { _ in
            CatalogStub(data: try Self.response(id), beforeDelivery: { try await gate.receive(id) })
        }
        defer { mock.close() }
        let api = YouTubeDataAPI(apiKey: Self.key, session: mock.session)
        let first = Task { try await api.metadata(for: id) }
        let blocked = try await gate.request(at: 0)
        let second = Task { try await api.metadata(for: id) }
        try await AppModelFixtures.eventually { await api.activity.waitingCallers == 2 }
        first.cancel()
        do { _ = try await first.value; XCTFail("Cancelled caller completed") }
        catch is CancellationError { }
        XCTAssertEqual(mock.state.cancellations, 0)
        try await gate.complete(blocked, with: .success(()))
        let result = try await second.value
        XCTAssertEqual(result?.language, .identified(.hindi, source: .youTubeAudioLanguage))
        XCTAssertEqual(mock.state.requests.count, 1)
        let activity = await api.activity
        XCTAssertEqual(activity.activeLookups, 0)
        XCTAssertEqual(activity.waitingCallers, 0)
    }

    func testLastCancellationRetiresTransferAndDoesNotCacheItsResult() async throws {
        let id = id
        let gate = AppModelRequestGate<String, Void>()
        addTeardownBlock { await gate.close() }
        let mock = CatalogMockSession { _ in
            CatalogStub(data: try Self.response(id), beforeDelivery: { try await gate.receive(id) })
        }
        defer { mock.close() }
        let api = YouTubeDataAPI(apiKey: Self.key, session: mock.session)
        let pending = Task { try await api.metadata(for: id) }
        _ = try await gate.request(at: 0)
        pending.cancel()
        do { _ = try await pending.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        try await AppModelFixtures.eventually {
            let activity = await api.activity
            return mock.state.cancellations > 0 && activity.activeLookups == 0
        }
        let activity = await api.activity
        XCTAssertEqual(activity.cachedRecordings, 0)
        XCTAssertEqual(activity.waitingCallers, 0)
    }

    func testDeadlineCancelsStalledTransferAndDoesNotImmediatelyRetry() async throws {
        let id = id
        let gate = AppModelRequestGate<String, Void>()
        addTeardownBlock { await gate.close() }
        let mock = CatalogMockSession { _ in
            CatalogStub(data: try Self.response(id), beforeDelivery: { try await gate.receive(id) })
        }
        defer { mock.close() }
        var configuration = YouTubeDataAPI.Configuration()
        configuration.timeout = 0.05
        let api = YouTubeDataAPI(apiKey: Self.key, session: mock.session, configuration: configuration)
        do { _ = try await api.metadata(for: id); XCTFail("Expected bounded deadline") }
        catch { XCTAssertEqual(error as? YouTubeDataAPI.RequestError, .unavailable) }
        try await AppModelFixtures.eventually { mock.state.cancellations > 0 }
        do { _ = try await api.metadata(for: id); XCTFail("Expected transient backoff") }
        catch { XCTAssertEqual(error as? YouTubeDataAPI.RequestError, .unavailable) }
        XCTAssertEqual(mock.state.requests.count, 1)
    }

    func testMissingConfigurationInvalidIDsAndOfflineDoNotMakeRequests() async throws {
        let mock = CatalogMockSession { _ in XCTFail("Unexpected network request"); return CatalogStub(data: Data()) }
        defer { mock.close() }
        let missing = YouTubeDataAPI(apiKey: "", session: mock.session)
        do { _ = try await missing.metadata(for: id); XCTFail("Missing key accepted") }
        catch { XCTAssertEqual(error as? YouTubeDataAPI.RequestError, .notConfigured) }
        let offline = YouTubeDataAPI(apiKey: Self.key, session: mock.session, isOffline: { true })
        do { _ = try await offline.metadata(for: id); XCTFail("Offline request accepted") }
        catch { XCTAssertEqual(error as? YouTubeDataAPI.RequestError, .offline) }
        do { _ = try await offline.metadata(for: "invalid"); XCTFail("Invalid ID accepted") }
        catch { XCTAssertEqual(error as? YouTubeDataAPI.RequestError, .invalidResponse) }
        XCTAssertTrue(mock.state.requests.isEmpty)
    }

    func testLookupPreparationFillsOnlyMissingDurationAndPreservesOriginalTrack() async throws {
        let id = id
        let mock = CatalogMockSession { _ in CatalogStub(data: try Self.response(id)) }
        defer { mock.close() }
        let api = YouTubeDataAPI(apiKey: Self.key, session: mock.session)
        let track = Track(id: id, title: "Tum Hi Ho", credits: [.init(name: "Arijit Singh", id: CatalogFixtures.arijitID)],
                          albumTitle: "Aashiqui 2", isAudioRecording: true, playCount: 1_200_000_000)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(track)
        let enriched = try await api.prepareForLookup(track)
        var expected = track
        expected.duration = 262
        XCTAssertEqual(enriched, expected)
        XCTAssertEqual(try encoder.encode(track), before)
        var known = track
        known.duration = 261.5
        let preserved = try await api.prepareForLookup(known)
        XCTAssertEqual(preserved, known)
        XCTAssertEqual(mock.state.requests.count, 1)
    }
}

import XCTest
@testable import GanaBajana

@MainActor
final class ArtistSpotlightMusicBrainzWorkTests: XCTestCase {
    private let recordingID = ArtistSpotlightMusicBrainzFixtures.recordingID
    private let workID = ArtistSpotlightMusicBrainzFixtures.workID
    private let track = LyricsFallbackFixtures.track

    func testMissingEmbeddedFieldsFetchOnlyTheExactLinkedWorkAndRetainProvenance() async throws {
        let clock = CatalogTestClock()
        let record = ArtistSpotlightMusicBrainzFixtures.recording(language: nil)
        let search = try ArtistSpotlightMusicBrainzFixtures.search([record]).encoded()
        let recording = try record.encoded()
        let work = try ArtistSpotlightMusicBrainzFixtures.work(language: "hin").encoded()
        let mock = CatalogMockSession { request in
            if request.url?.path.contains("/work/") == true { return CatalogStub(data: work) }
            if request.url?.path.contains("/recording/") == true { return CatalogStub(data: recording) }
            return CatalogStub(data: search)
        }
        defer { mock.close() }
        let service = try makeService(mock, clock: clock)
        let result = try await service.language(for: track)
        XCTAssertEqual(result, .identified(.hindi, source: .musicBrainzWork(recordingID: recordingID, workID: workID)))
        XCTAssertEqual(mock.state.requests.compactMap { $0.url?.path },
                       ["/ws/2/recording", "/ws/2/recording/\(recordingID)", "/ws/2/work/\(workID)"])
        let workRequest = try XCTUnwrap(mock.state.requests.last)
        XCTAssertEqual(workRequest.httpMethod, "GET")
        XCTAssertFalse(workRequest.httpShouldHandleCookies)
        XCTAssertNil(workRequest.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(workRequest.value(forHTTPHeaderField: "Authorization"))
        XCTAssertLessThanOrEqual(workRequest.timeoutInterval, 3)
        _ = try await service.language(for: track)
        XCTAssertEqual(mock.state.requests.count, 3)
    }

    func testPluralAndLegacyFieldsAreValidatedWithoutDiscardingOtherLanguages() {
        let record = ArtistSpotlightMusicBrainzFixtures.recording(language: nil)
        for field in ["language", "languages"] {
            var work = ArtistSpotlightMusicBrainzFixtures.work(language: "ben").object
            work.removeValue(forKey: field)
            XCTAssertEqual(ArtistSpotlightMusicBrainz.workLanguage(in: record, recordingID: recordingID, for: track, fetchedWork: .object(work)),
                           .identified(.bengali, source: .musicBrainzWork(recordingID: recordingID, workID: workID)))
        }
        let multilingual: [CatalogJSON] = [["eng", "hin"], ["eng", "fra"], ["mul"]]
        for values in multilingual {
            var work = ArtistSpotlightMusicBrainzFixtures.work(language: nil).object
            work["languages"] = values
            XCTAssertEqual(ArtistSpotlightMusicBrainz.workLanguage(in: record, recordingID: recordingID, for: track, fetchedWork: .object(work)),
                           .unclassified(.conflictingEvidence))
        }
        var disagreeing = ArtistSpotlightMusicBrainzFixtures.work(language: "eng").object
        disagreeing["languages"] = ["hin"]
        XCTAssertEqual(ArtistSpotlightMusicBrainz.workLanguage(in: record, recordingID: recordingID, for: track, fetchedWork: .object(disagreeing)),
                       .unclassified(.conflictingEvidence))
        XCTAssertEqual(ArtistSpotlightMusicBrainz.workLanguage(in: ArtistSpotlightMusicBrainzFixtures.recording(language: "hin"),
            recordingID: recordingID, for: track, fetchedWork: ArtistSpotlightMusicBrainzFixtures.work(language: "eng")),
            .unclassified(.conflictingEvidence))
        for code in ["und", "zxx", "fra"] {
            XCTAssertEqual(ArtistSpotlightMusicBrainz.workLanguage(in: record, recordingID: recordingID, for: track,
                fetchedWork: ArtistSpotlightMusicBrainzFixtures.work(language: code)), .unclassified(.uncertainLanguage))
        }
    }

    func testFullWorkCannotBypassRecordingRelationVersionOrWorkIdentityChecks() {
        let full = ArtistSpotlightMusicBrainzFixtures.work()
        let incompatibleAttributes: [[CatalogJSON]] = [["instrumental"], ["partial"], ["translated"], ["live"]]
        for attributes in incompatibleAttributes {
            let record = ArtistSpotlightMusicBrainzFixtures.recording(language: nil, attributes: attributes)
            XCTAssertNil(ArtistSpotlightMusicBrainz.workLanguage(in: record, recordingID: recordingID, for: track, fetchedWork: full))
        }
        let record = ArtistSpotlightMusicBrainzFixtures.recording(language: nil)
        let wrongFields: [(String, CatalogJSON)] = [("id", "33333333-3333-4333-8333-333333333333"),
                                                   ("title", "Paper Satellites (Translation)"), ("type", "Opera")]
        for (key, value) in wrongFields {
            var wrong = full.object
            wrong[key] = value
            XCTAssertNil(ArtistSpotlightMusicBrainz.workLanguage(in: record, recordingID: recordingID, for: track, fetchedWork: .object(wrong)), key)
        }
        var wrongTrack = track
        wrongTrack.title += " (Live)"
        XCTAssertNil(ArtistSpotlightMusicBrainz.workLanguage(in: record, recordingID: recordingID, for: wrongTrack, fetchedWork: full))
        wrongTrack = track
        wrongTrack.credits = [ArtistCredit(name: "A different singer")]
        XCTAssertNil(ArtistSpotlightMusicBrainz.workLanguage(in: record, recordingID: recordingID, for: wrongTrack, fetchedWork: full))
        var multiple = record.object
        multiple["relations"] = .array(record["relations"].array + record["relations"].array)
        XCTAssertNil(ArtistSpotlightMusicBrainz.workLanguage(in: .object(multiple), recordingID: recordingID, for: track, fetchedWork: full))
    }

    func testMissingWorkLanguageUsesNegativeCacheAndExpiresForRetry() async throws {
        let clock = CatalogTestClock()
        let record = ArtistSpotlightMusicBrainzFixtures.recording(language: nil)
        let search = try ArtistSpotlightMusicBrainzFixtures.search([record]).encoded()
        let recording = try record.encoded()
        let work = try ArtistSpotlightMusicBrainzFixtures.work(language: nil).encoded()
        let mock = CatalogMockSession { request in
            if request.url?.path.contains("/work/") == true { return CatalogStub(data: work) }
            if request.url?.path.contains("/recording/") == true { return CatalogStub(data: recording) }
            return CatalogStub(data: search)
        }
        defer { mock.close() }
        let service = try makeService(mock, clock: clock)
        let first = try await service.language(for: track)
        let cached = try await service.language(for: track)
        XCTAssertNil(first)
        XCTAssertNil(cached)
        XCTAssertEqual(mock.state.requests.count, 3)
        clock.advance(15 * 60 + 1)
        let retry = try await service.language(for: track)
        XCTAssertNil(retry)
        XCTAssertEqual(mock.state.requests.count, 6)
    }

    func testMalformedWorkResponseIsNotNegativeCached() async throws {
        let clock = CatalogTestClock()
        let requests = CatalogTestCounter()
        let record = ArtistSpotlightMusicBrainzFixtures.recording(language: nil)
        let search = try ArtistSpotlightMusicBrainzFixtures.search([record]).encoded()
        let recording = try record.encoded()
        let work = try ArtistSpotlightMusicBrainzFixtures.work().encoded()
        var invalid = ArtistSpotlightMusicBrainzFixtures.work().object
        invalid["languages"] = ["eng", 7]
        let malformed = try CatalogJSON.object(invalid).encoded()
        let mock = CatalogMockSession { request in
            if request.url?.path.contains("/work/") == true {
                return CatalogStub(data: requests.increment() == 1 ? malformed : work)
            }
            if request.url?.path.contains("/recording/") == true { return CatalogStub(data: recording) }
            return CatalogStub(data: search)
        }
        defer { mock.close() }
        let service = try makeService(mock, clock: clock)
        do { _ = try await service.language(for: track); XCTFail("Malformed language data must stay retryable") }
        catch MusicServiceError.invalidResponse { }
        let retry = try await service.language(for: track)
        XCTAssertEqual(retry?.language, .english)
        XCTAssertEqual(mock.state.requests.count, 6)
    }

    func testCancellationDuringWorkFetchCancelsTransportAndCannotCacheAMiss() async throws {
        let clock = CatalogTestClock()
        let requests = CatalogTestCounter()
        let record = ArtistSpotlightMusicBrainzFixtures.recording(language: nil)
        let search = try ArtistSpotlightMusicBrainzFixtures.search([record]).encoded()
        let recording = try record.encoded()
        let work = try ArtistSpotlightMusicBrainzFixtures.work().encoded()
        let mock = CatalogMockSession { request in
            if request.url?.path.contains("/work/") == true {
                return CatalogStub(data: work, delay: requests.increment() == 1 ? 30 : 0)
            }
            if request.url?.path.contains("/recording/") == true { return CatalogStub(data: recording) }
            return CatalogStub(data: search)
        }
        defer { mock.close() }
        let service = try makeService(mock, clock: clock)
        let pending = Task { try await service.language(for: track) }
        try await AppModelFixtures.eventually { mock.state.requests.count == 3 }
        pending.cancel()
        do { _ = try await pending.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        try await AppModelFixtures.eventually { mock.state.cancellations > 0 }
        let retry = try await service.language(for: track)
        XCTAssertEqual(retry?.language, .english)
        XCTAssertEqual(mock.state.requests.count, 6)
    }

    func testWorkFallbackSharesTheOriginalDeadlineAndDeadlineFailuresAreRetryable() async throws {
        let clock = CatalogTestClock()
        let recordingRequests = CatalogTestCounter()
        let record = ArtistSpotlightMusicBrainzFixtures.recording(language: nil)
        let search = try ArtistSpotlightMusicBrainzFixtures.search([record]).encoded()
        let recording = try record.encoded()
        let work = try ArtistSpotlightMusicBrainzFixtures.work().encoded()
        let mock = CatalogMockSession { request in
            if request.url?.path.contains("/work/") == true { return CatalogStub(data: work) }
            if request.url?.path.contains("/recording/") == true {
                if recordingRequests.increment() == 1 { clock.advance(5) }
                return CatalogStub(data: recording)
            }
            return CatalogStub(data: search)
        }
        defer { mock.close() }
        let service = try makeService(mock, clock: clock)
        do { _ = try await service.language(for: track); XCTFail("A third hop must not extend the six-second deadline") }
        catch LyricsLookupError.sourcesFailed { }
        XCTAssertEqual(mock.state.requests.count, 2)
        let retry = try await service.language(for: track)
        XCTAssertEqual(retry?.language, .english)
        XCTAssertEqual(mock.state.requests.count, 5)
    }

    private func makeService(_ mock: CatalogMockSession, clock: CatalogTestClock) throws -> ArtistSpotlightMusicBrainz {
        let limiter = MusicBrainzRateLimiter(now: { clock.now }, sleep: { clock.advance($0) })
        return ArtistSpotlightMusicBrainz(contactURL: try XCTUnwrap(URL(string: "https://example.org/support")),
                                        session: mock.session, limiter: limiter, now: { clock.now })
    }
}

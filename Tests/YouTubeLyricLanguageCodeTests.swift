import XCTest
@testable import GanaBajana

@MainActor
final class YouTubeLyricLanguageCodeTests: XCTestCase {
    private nonisolated static let key = "AIza" + String(repeating: "0", count: 35)
    private nonisolated static let id = CatalogFixtures.hindiID

    private nonisolated static func response(code: CatalogJSON = "pa-Guru") throws -> Data {
        let json: CatalogJSON = ["items": [["id": .string(id),
            "snippet": ["defaultAudioLanguage": code, "defaultLanguage": "en"],
            "contentDetails": ["duration": "PT4M22S"]]]]
        return try json.encoded()
    }

    func testRawLanguageAndScriptTagsAreNormalizedWithoutNarrowingTheClassifier() throws {
        for (raw, expected) in [("pa", "pa"), (" PA-gURU-in \n", "pa-Guru-IN"),
                                ("PA-aRAB-PK", "pa-Arab-PK"), ("PAN", "pan"),
                                ("hi-latn-in", "hi-Latn-IN"), ("EN-us", "en-US"),
                                ("zh-hANT-tw", "zh-Hant-TW"), ("es-419", "es-419"),
                                ("und", "und"), ("mul", "mul"), ("zxx", "zxx")] {
            let metadata = try XCTUnwrap(YouTubeDataAPI.parse(Self.response(code: .string(raw)), videoID: Self.id))
            XCTAssertEqual(metadata.audioLanguageCode, expected)
            XCTAssertEqual(metadata.language, ArtistSongLanguageResult.youTubeAudioLanguage(raw))
        }
        let punjabi = try XCTUnwrap(YouTubeDataAPI.parse(Self.response(), videoID: Self.id))
        XCTAssertEqual(punjabi.language, .unclassified(.uncertainLanguage))
        XCTAssertEqual(punjabi.audioLanguageCode, "pa-Guru")
        XCTAssertEqual(punjabi.duration, 262)
        XCTAssertNil(YouTubeDataAPI.Metadata(duration: nil, language: nil).audioLanguageCode)
    }

    func testMalformedAndOversizedTagsCannotBecomeLyricLanguageEvidence() throws {
        for raw in ["", " ", "p", "punjabi", "pa_India", "pa-", "-pa", "pa--Guru", "pa GURU",
                    "pa-Guru/IN", "pa-ਗੁਰੂ", "pa-123456789", "pa-\u{0000}Guru", "pa\nGuru",
                    "pa-u-ca-gregory", String(repeating: "p", count: 65)] {
            let metadata = try XCTUnwrap(YouTubeDataAPI.parse(Self.response(code: .string(raw)), videoID: Self.id))
            XCTAssertNil(metadata.audioLanguageCode)
        }
        let wrongTypes: [CatalogJSON] = [.null, 12, ["code": "pa"], ["pa"]]
        for raw in wrongTypes {
            let metadata = try XCTUnwrap(YouTubeDataAPI.parse(Self.response(code: raw), videoID: Self.id))
            XCTAssertNil(metadata.audioLanguageCode)
        }
        let boundary = "pa" + String(repeating: "-abcdefgh", count: 6) + "-abcdefg"
        XCTAssertEqual(boundary.utf8.count, 64)
        let accepted = try YouTubeDataAPI.parse(Self.response(code: .string(boundary)), videoID: Self.id)
        XCTAssertEqual(accepted?.audioLanguageCode, boundary)
        let tooLong = try YouTubeDataAPI.parse(Self.response(code: .string(boundary + "h")), videoID: Self.id)
        XCTAssertNil(tooLong?.audioLanguageCode)
    }

    func testDefaultLanguageArtistAndTrackLanguageCannotSupplyAnAbsentAudioTag() async throws {
        let json: CatalogJSON = ["items": [["id": .string(Self.id),
            "snippet": ["defaultLanguage": "pa", "channelTitle": "Punjabi Artist",
                        "description": "Punjabi song", "title": "ਗਾਣਾ"]]]]
        let data = try json.encoded()
        let mock = CatalogMockSession { _ in CatalogStub(data: data) }
        defer { mock.close() }
        let api = YouTubeDataAPI(apiKey: Self.key, session: mock.session)
        let track = Track(id: Self.id, title: "ਗਾਣਾ", artists: ["Punjabi Artist"], language: .hindi, isAudioRecording: true)
        let code = try await api.lyricLanguageCode(for: track)
        XCTAssertNil(code)
        let metadata = try await api.metadata(for: Self.id)
        XCTAssertNil(metadata?.audioLanguageCode)
        XCTAssertNil(metadata?.language)
        XCTAssertEqual(mock.state.requests.count, 1)
    }

    func testLyricCodeSharesTheExistingMetadataRequestAndCache() async throws {
        let mock = CatalogMockSession { _ in CatalogStub(data: try Self.response()) }
        defer { mock.close() }
        let api = YouTubeDataAPI(apiKey: Self.key, session: mock.session)
        let metadata = try await api.metadata(for: Self.id)
        let track = Track(id: Self.id, title: "Synthetic recording", isAudioRecording: true)
        let code = try await api.lyricLanguageCode(for: track)
        let language = try await api.recordingLanguage(for: track)
        let prepared = try await api.prepareForLookup(track)
        XCTAssertEqual(code, "pa-Guru")
        XCTAssertEqual(code, metadata?.audioLanguageCode)
        XCTAssertEqual(language, .unclassified(.uncertainLanguage))
        XCTAssertEqual(prepared.duration, 262)
        XCTAssertEqual(mock.state.requests.count, 1)
        let request = try XCTUnwrap(mock.state.requests.first)
        XCTAssertEqual(request.url?.host, "www.googleapis.com")
        XCTAssertEqual(request.url?.path, "/youtube/v3/videos")
        let items = LyricsTestFixtures.items(request)
        XCTAssertEqual(items["part"], "snippet,contentDetails,statistics")
        XCTAssertEqual(items["fields"], "items(id,snippet(defaultAudioLanguage,description,channelTitle,publishedAt),contentDetails(duration),statistics(viewCount))")
        XCTAssertEqual(Set(items.keys), ["part", "fields", "id", "prettyPrint"])
    }

    func testPrefixedIDsCollectionsAndExplicitNonrecordingsMakeNoRequest() async throws {
        let mock = CatalogMockSession { _ in XCTFail("Ineligible recording made a request"); return CatalogStub(data: Data()) }
        defer { mock.close() }
        let api = YouTubeDataAPI(apiKey: Self.key, session: mock.session)
        let excluded = [
            Track(id: "saavn:\(Self.id)", title: "Source recording", isAudioRecording: true),
            Track(id: "gaana:\(Self.id)", title: "Source recording", isAudioRecording: true),
            Track(id: "saavn:album:123", title: "Collection"),
            Track(id: "MPREb_collection", title: "Collection"),
            Track(id: "invalid", title: "Invalid ID"),
            Track(id: Self.id, title: "Video", isAudioRecording: false)
        ]
        for track in excluded {
            let code = try await api.lyricLanguageCode(for: track)
            XCTAssertNil(code)
        }
        XCTAssertTrue(mock.state.requests.isEmpty)
    }

    func testLyricCodeCoalescesWithMetadataAndCancellingOneWaiterKeepsTheOther() async throws {
        let gate = AppModelRequestGate<String, Void>()
        addTeardownBlock { await gate.close() }
        let mock = CatalogMockSession { _ in
            CatalogStub(data: try Self.response(), beforeDelivery: { try await gate.receive(Self.id) })
        }
        defer { mock.close() }
        let api = YouTubeDataAPI(apiKey: Self.key, session: mock.session)
        let track = Track(id: Self.id, title: "Legacy recording without an audio flag")
        let metadata = Task { try await api.metadata(for: Self.id) }
        defer { metadata.cancel() }
        let blocked = try await gate.request(at: 0)
        let lyric = Task { try await api.lyricLanguageCode(for: track) }
        defer { lyric.cancel() }
        try await AppModelFixtures.eventually { await api.activity.waitingCallers == 2 }
        lyric.cancel()
        do { _ = try await lyric.value; XCTFail("Cancelled lyric waiter returned a code") }
        catch is CancellationError { }
        XCTAssertEqual(mock.state.cancellations, 0)
        try await gate.complete(blocked, with: .success(()))
        let value = try await metadata.value
        XCTAssertEqual(value?.audioLanguageCode, "pa-Guru")
        let cached = try await api.lyricLanguageCode(for: track)
        XCTAssertEqual(cached, "pa-Guru")
        XCTAssertEqual(mock.state.requests.count, 1)
    }

    func testLastLyricWaiterCancellationRetiresTransferWithoutCaching() async throws {
        let gate = AppModelRequestGate<String, Void>()
        addTeardownBlock { await gate.close() }
        let mock = CatalogMockSession { _ in
            CatalogStub(data: try Self.response(), beforeDelivery: { try await gate.receive(Self.id) })
        }
        defer { mock.close() }
        let api = YouTubeDataAPI(apiKey: Self.key, session: mock.session)
        let pending = Task { try await api.lyricLanguageCode(for: Track(id: Self.id, title: "Synthetic recording")) }
        defer { pending.cancel() }
        _ = try await gate.request(at: 0)
        pending.cancel()
        do { _ = try await pending.value; XCTFail("Cancelled lookup returned a code") }
        catch is CancellationError { }
        try await AppModelFixtures.eventually {
            let activity = await api.activity
            return activity.activeLookups == 0 && mock.state.cancellations > 0
        }
        let activity = await api.activity
        XCTAssertEqual(activity.cachedRecordings, 0)
    }

    func testMissingMetadataIsNilButQuotaFailureStillThrows() async throws {
        let missing = CatalogMockSession { _ in CatalogStub(data: Data(#"{"items":[]}"#.utf8)) }
        defer { missing.close() }
        let api = YouTubeDataAPI(apiKey: Self.key, session: missing.session)
        let track = Track(id: Self.id, title: "Synthetic recording")
        for _ in 0..<2 {
            let code = try await api.lyricLanguageCode(for: track)
            XCTAssertNil(code)
        }
        XCTAssertEqual(missing.state.requests.count, 1)
        let failed = CatalogMockSession { _ in
            CatalogStub(status: 403, data: Data(#"{"error":{"errors":[{"reason":"quotaExceeded"}]}}"#.utf8))
        }
        defer { failed.close() }
        let failingAPI = YouTubeDataAPI(apiKey: Self.key, session: failed.session)
        do { _ = try await failingAPI.lyricLanguageCode(for: track); XCTFail("Quota failure became absence") }
        catch { XCTAssertEqual(error as? YouTubeDataAPI.RequestError, .quotaExceeded) }
    }
}

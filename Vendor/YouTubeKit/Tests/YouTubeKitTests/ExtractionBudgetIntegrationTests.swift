import Foundation
import XCTest
@testable import YouTubeKit

@available(iOS 15.0, watchOS 8.0, tvOS 15.0, macOS 12.0, *)
final class ExtractionBudgetIntegrationTests: ExtractionStreamingTestCase {
    private let videoID = "unitfixture"

    private func watchPage(jsPath: String = "/s/player/fixture/player_ias.vflset/en_US/base.js") -> Data {
        Data("""
        ytplayer.config = {"assets":{"js":"\(jsPath)"}};
        ytcfg.set({});
        var ytInitialPlayerResponse = {"playabilityStatus":{"status":"OK"}};
        """.utf8)
    }

    private func remoteRequest(_ stream: ExtractionTestStream, redirects: Bool, cookies: Bool = false) -> RemoteYouTubeClient.RemoteURLRequest {
        .init(id: "fixture", url: stream.request.url!, method: "GET", body: nil, headers: [:],
              allowRedirects: redirects, applyCookiesOnRedirect: cookies, saveIntermediateResponses: true, maxMessageChunkSize: 32_000)
    }

    func testRejectedWatchResponseIsNotCachedByFullExtraction() async throws {
        let first = ExtractionTestStream(path: "/watch")
        let retry = ExtractionTestStream(path: "/watch")
        let youtube = YouTube(videoID: videoID, session: makeSession([first, retry]))
        let work = try await start(first) { try await youtube.checkAvailability() }
        first.respond(expectedLength: 4_000_001)
        try await assertOversized(work, stream: first)

        let retried = try await start(retry) { try await youtube.checkAvailability() }
        retry.complete(watchPage())
        try await retried.value
        XCTAssertTrue(retry.didFinish)
    }

    func testFullExtractionFallthroughCannotRebufferARejectedWatchPage() async throws {
        let fast = ExtractionTestStream(path: "/watch")
        let full = ExtractionTestStream(path: "/watch")
        let session = makeSession([fast, full])
        let videoID = self.videoID
        let work = try await start(fast) {
            do {
                _ = try await ExtractionTransport.data(for: fast.request, budget: .html, session: session)
                XCTFail("The first lookup must reject the oversized body")
            } catch ExtractionTransportError.responseTooLarge { }
            return try await YouTube(videoID: videoID, session: session).streams
        }
        fast.respond(expectedLength: 4_000_001)
        try await eventually { fast.cancellations == 1 && full.recordedRequest != nil }
        full.respond()
        let chunk = Data(repeating: 0x61, count: 1_000_000)
        for _ in 0..<4 { XCTAssertTrue(full.send(chunk)) }
        XCTAssertTrue(full.send(Data([0x61])))
        try await assertOversized(work, stream: full)
        XCTAssertFalse(fast.didFinish)
        XCTAssertEqual(fast.deliveredBytes, 0)
        XCTAssertEqual(full.deliveredBytes, 4_000_001)
    }

    func testEmbedPageFetchUsesTheFourMillionByteHTMLBudget() async throws {
        let watch = ExtractionTestStream(path: "/watch")
        let embed = ExtractionTestStream(path: "/embed/\(videoID)")
        let youtube = YouTube(videoID: videoID, session: makeSession([watch, embed]))
        let work = try await start(watch) { try await youtube.js }
        watch.complete(Data("<meta property=\"og:restrictions:age\" content=\"18+\">".utf8))
        try await eventually { embed.recordedRequest != nil }
        embed.respond(expectedLength: 4_000_001)
        try await assertOversized(work, stream: embed)
    }

    func testPlayerFetchUsesTheFourMillionByteJSONBudget() async throws {
        let stream = ExtractionTestStream(path: "/youtubei/v1/player")
        let configuration = try JSONDecoder().decode(Extraction.YtCfg.self, from: Data("{}".utf8))
        let player = InnerTube(client: .visionOS, signatureTimestamp: nil, ytcfg: configuration, session: makeSession([stream]))
        let videoID = self.videoID
        let work = try await start(stream) { try await player.player(videoID: videoID) }
        stream.respond(expectedLength: 4_000_001)
        try await assertOversized(work, stream: stream)
    }

    func testJavaScriptHasABoundedLargerBudgetThanHTML() async throws {
        for oversized in [false, true] {
            let path = "/s/player/\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))/player_ias.vflset/en_US/base.js"
            let watch = ExtractionTestStream(path: "/watch")
            let javaScript = ExtractionTestStream(path: path)
            let youtube = YouTube(videoID: videoID, session: makeSession([watch, javaScript]))
            let work = try await start(watch) { try await youtube.js }
            watch.complete(watchPage(jsPath: path))
            try await eventually { javaScript.recordedRequest != nil }
            if oversized {
                javaScript.respond(expectedLength: 12_000_001)
                try await assertOversized(work, stream: javaScript)
                XCTAssertEqual(javaScript.deliveredBytes, 0)
            } else {
                javaScript.complete(Data(repeating: 0x61, count: 4_000_001))
                let result = try await work.value
                XCTAssertEqual(result.utf8.count, 4_000_001)
                XCTAssertTrue(javaScript.didFinish)
            }
        }
    }

    func testFullExtractionKeepsAValidPlayerSiblingWhenAnotherExceedsItsBudget() async throws {
        let path = "/s/player/\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))/player_ias.vflset/en_US/base.js"
        let watch = ExtractionTestStream(path: "/watch")
        let javaScript = ExtractionTestStream(path: path)
        let rejected = ExtractionTestStream(path: "/youtubei/v1/player")
        let sibling = ExtractionTestStream(path: "/youtubei/v1/player")
        let youtube = YouTube(videoID: videoID, session: makeSession([watch, javaScript, rejected, sibling]))
        let work = try await start(watch) { try await youtube.videoInfos }
        watch.complete(watchPage(jsPath: path))
        try await eventually { javaScript.recordedRequest != nil }
        javaScript.complete(Data("var signatureTimestamp = {sts:20000};".utf8))
        try await eventually { rejected.recordedRequest != nil && sibling.recordedRequest != nil }
        rejected.respond(expectedLength: 4_000_001)
        try await eventually { rejected.cancellations == 1 }
        sibling.complete(Data("""
        {"playabilityStatus":{"status":"OK"},"videoDetails":{"videoId":"\(videoID)","thumbnail":{"thumbnails":[]}}}
        """.utf8))
        let result = try await work.value
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.videoDetails?.videoId, videoID)
        XCTAssertFalse(rejected.didFinish)
        XCTAssertEqual(sibling.cancellations, 0)
    }

    func testCancellingFullExtractionStopsItsPlayersButNotAnUnrelatedRequest() async throws {
        let path = "/s/player/\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))/player_ias.vflset/en_US/base.js"
        let watch = ExtractionTestStream(path: "/watch")
        let javaScript = ExtractionTestStream(path: path)
        let first = ExtractionTestStream(path: "/youtubei/v1/player")
        let second = ExtractionTestStream(path: "/youtubei/v1/player")
        let unrelated = ExtractionTestStream()
        let session = makeSession([watch, javaScript, first, second, unrelated])
        let youtube = YouTube(videoID: videoID, session: session)
        let work = try await start(watch) { try await youtube.videoInfos }
        watch.complete(watchPage(jsPath: path))
        try await eventually { javaScript.recordedRequest != nil }
        javaScript.complete(Data("var signatureTimestamp = {sts:20000};".utf8))
        try await eventually { first.recordedRequest != nil && second.recordedRequest != nil }
        first.respond()
        second.respond()
        let other = try await start(unrelated, session: session)
        work.cancel()
        try await eventually { first.cancellations == 1 && second.cancellations == 1 }
        do { _ = try await work.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(first.didFinish)
        XCTAssertFalse(second.didFinish)
        XCTAssertEqual(unrelated.cancellations, 0)
        unrelated.complete(Data([9]))
        let (data, _) = try await other.value
        XCTAssertEqual(data, Data([9]))
    }

    func testConcurrentMapRetainsClientPreferenceOrder() async {
        let results = await [3, 2, 1].concurrentMap { value in
            try? await Task.sleep(nanoseconds: UInt64(value) * 10_000_000)
            return value * 2
        }
        XCTAssertEqual(results, [6, 4, 2])
    }

    func testRemoteDeclaredBodyLimitAppliesBeforeBase64InEveryRedirectMode() async throws {
        for (redirects, cookies) in [(true, false), (false, false), (true, true)] {
            let stream = ExtractionTestStream()
            let remote = RemoteYouTubeClient(serverURL: URL(string: "https://example.invalid")!, session: makeSession([stream]))
            let request = remoteRequest(stream, redirects: redirects, cookies: cookies)
            let work = try await start(stream) { try await remote.response(for: request) }
            stream.respond(expectedLength: 8_000_001)
            try await assertOversized(work, stream: stream)
            XCTAssertEqual(stream.deliveredBytes, 0)
            XCTAssertFalse(stream.recordedRequest?.httpShouldHandleCookies ?? true)
        }
    }

    func testRemoteUnknownLengthBodyCannotGrowUntilEOFOrEncoding() async throws {
        let stream = ExtractionTestStream()
        let remote = RemoteYouTubeClient(serverURL: URL(string: "https://example.invalid")!, session: makeSession([stream]))
        let request = remoteRequest(stream, redirects: true)
        let work = try await start(stream) { try await remote.response(for: request) }
        stream.respond()
        let chunk = Data(repeating: 0xFF, count: 1_000_000)
        for _ in 0..<8 { XCTAssertTrue(stream.send(chunk)) }
        XCTAssertTrue(stream.send(Data([0xFF])))
        try await assertOversized(work, stream: stream)
        XCTAssertEqual(stream.deliveredBytes, 8_000_001)
    }

    func testRemoteEncodingDoesNotDoubleBase64SlashExpansion() async throws {
        let stream = ExtractionTestStream()
        let remote = RemoteYouTubeClient(serverURL: URL(string: "https://example.invalid")!, session: makeSession([stream]))
        let request = remoteRequest(stream, redirects: true)
        let work = try await start(stream) { try await remote.response(for: request) }
        stream.complete(Data(repeating: 0xFF, count: 6))
        let response = try await work.value
        let encoded = try RemoteYouTubeClient.responseEncoder().encode(response)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["data"] as? String, "////////")
        XCTAssertEqual(object["status_code"] as? Int, 200)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("\\/"))
    }

    func testRemoteCancellationLeavesAnUnrelatedSharedSessionRequestRunning() async throws {
        for cookies in [false, true] {
            let stream = ExtractionTestStream()
            let sibling = ExtractionTestStream()
            let session = makeSession([stream, sibling])
            let remote = RemoteYouTubeClient(serverURL: URL(string: "https://example.invalid")!, session: session)
            let request = remoteRequest(stream, redirects: true, cookies: cookies)
            let work = try await start(stream) { try await remote.response(for: request) }
            let other = try await start(sibling, session: session)
            stream.respond()
            stream.send(Data([1]))
            work.cancel()
            try await eventually { stream.cancellations == 1 }
            do { _ = try await work.value; XCTFail("Expected cancellation") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertFalse(stream.didFinish)
            XCTAssertEqual(sibling.cancellations, 0)
            sibling.complete(Data([2]))
            let (data, _) = try await other.value
            XCTAssertEqual(data, Data([2]))
        }
    }
}

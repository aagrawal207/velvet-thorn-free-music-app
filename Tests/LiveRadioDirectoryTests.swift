import XCTest
@testable import GanaBajana

enum LiveRadioTestSupport {
    static let station = LiveRadioStation(id: UUID(uuidString: "8dedb027-22d3-42c9-9743-6daf1d728e6f")!,
        name: "Public Radio", streamingURL: URL(string: "https://stream.example.org/live")!,
        homepageURL: URL(string: "https://www.example.org/")!, artworkURL: nil,
        countryCode: "US", languages: ["english"], tags: ["npr", "news"], codec: "AAC", isHLS: false)

    static func row(id: UUID = station.id, url: String = station.streamingURL.absoluteString,
                    codec: String = "AAC", hls: Int = 0) -> [String: Any] {
        ["stationuuid": id.uuidString, "name": "Public Radio", "url_resolved": url, "url": "http://old.example.org",
         "homepage": "https://www.example.org/", "countrycode": "US", "language": "english", "tags": "npr,news",
         "codec": codec, "hls": hls, "lastcheckok": 1, "clickcount": 987, "votes": 432]
    }

    static func payload(_ rows: [[String: Any]]? = nil) throws -> Data {
        try JSONSerialization.data(withJSONObject: rows ?? [row()])
    }
}

final class LiveRadioDirectoryTests: XCTestCase {
    func testDocumentedStationSchemaKeepsPublicStationIdentityAndResolvedURL() throws {
        let result = try LiveRadioDirectory.decodeStations(LiveRadioTestSupport.payload())
        XCTAssertEqual(result, [LiveRadioTestSupport.station])
        let encoded = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        for forbidden in ["clickcount", "playCount", "votes", "duration", "trackID"] { XCTAssertFalse(encoded.contains(forbidden)) }
    }

    func testRejectsHTTPPrivateHostsCredentialsVideoCodecsAndOversizedMetadata() throws {
        var longName = LiveRadioTestSupport.row()
        longName["name"] = String(repeating: "a", count: 257)
        var broken = LiveRadioTestSupport.row()
        broken["lastcheckok"] = 0
        let rows = [longName, broken,
                    LiveRadioTestSupport.row(url: "http://stream.example.org/live"),
                    LiveRadioTestSupport.row(url: "https://127.0.0.1/live"),
                    LiveRadioTestSupport.row(url: "https://radio.local/live"),
                    LiveRadioTestSupport.row(url: "https://user:password@stream.example.org/live"),
                    LiveRadioTestSupport.row(codec: "AAC,H.264"), LiveRadioTestSupport.row(codec: "OGG")]
        XCTAssertTrue(try LiveRadioDirectory.decodeStations(LiveRadioTestSupport.payload(rows)).isEmpty)
    }

    func testPayloadAndRowBoundsAreInclusiveAndDuplicatesKeepFirst() throws {
        let hundred = (0..<100).map { _ in LiveRadioTestSupport.row(id: UUID()) }
        XCTAssertEqual(try LiveRadioDirectory.decodeStations(LiveRadioTestSupport.payload(hundred)).count, 100)
        XCTAssertThrowsError(try LiveRadioDirectory.decodeStations(LiveRadioTestSupport.payload(hundred + [LiveRadioTestSupport.row()])))
        XCTAssertThrowsError(try LiveRadioDirectory.decodeStations(Data(repeating: 32, count: LiveRadioDirectory.maximumBytes + 1)))
        XCTAssertThrowsError(try LiveRadioDirectory.decodeStations(Data("{}".utf8)))
        XCTAssertEqual(try LiveRadioDirectory.decodeStations(LiveRadioTestSupport.payload([LiveRadioTestSupport.row(), LiveRadioTestSupport.row()])).count, 1)
    }

    func testFilterEncodingCannotInjectAccountOrTrackingParameters() throws {
        let filter = LiveRadioFilter(name: "NPR & café?x=1", countryCode: "us", language: "english", tags: "news, talk & arts")
        let request = try LiveRadioDirectory.request(host: "de1.api.radio-browser.info", path: "/json/stations/search", query: filter.queryItems())
        let url = try XCTUnwrap(request.url)
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let values = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(values["name"], filter.name)
        XCTAssertEqual(values["tagList"], "news,talk & arts")
        XCTAssertEqual(values["countrycode"], "US")
        XCTAssertEqual(values["languageExact"], "true")
        XCTAssertEqual(values["limit"], "100")
        XCTAssertEqual(values["is_https"], "true")
        XCTAssertNil(values["x"])
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Breezy/1.0")
        XCTAssertThrowsError(try LiveRadioDirectory.request(host: "de1.api.radio-browser.info", path: "/json/url/\(UUID())", query: []))
        XCTAssertThrowsError(try LiveRadioFilter(countryCode: "USA").queryItems())
        XCTAssertThrowsError(try LiveRadioFilter(tags: "a,b,c,d,e,f").queryItems())
        XCTAssertEqual(try LiveRadioFilter.npr.queryItems().first { $0.name == "tagList" }?.value, "npr")
    }

    func testMirrorNamesAreValidatedAndDeduplicatedWithoutUsingReturnedIPs() throws {
        let rows = [["name": "de1.api.radio-browser.info", "ip": "127.0.0.1"],
                    ["name": "de1.api.radio-browser.info"], ["name": "evil.example.org"],
                    ["name": "de1.api.radio-browser.info.evil.org"], ["name": "https://de1.api.radio-browser.info"]]
        let data = try JSONSerialization.data(withJSONObject: rows)
        XCTAssertEqual(try LiveRadioDirectory.decodeMirrors(data), ["de1.api.radio-browser.info"])
        XCTAssertThrowsError(try LiveRadioDirectory.decodeMirrors(Data(repeating: 32, count: 32_769)))
    }

    func testDirectoryFailoverIsReadOnlyAndBounded() async throws {
        let transport = LiveRadioDirectoryFixture(failAll: false)
        let directory = LiveRadioDirectory(transport: { try await transport.fetch($0, limit: $1) })
        let stations = try await directory.search(.npr)
        XCTAssertEqual(stations.count, 1)
        let requests = await transport.requests
        XCTAssertEqual(requests.filter { $0.url?.path == "/json/stations/search" }.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" && $0.httpBody == nil })
        XCTAssertTrue(requests.allSatisfy { ["/json/stations/search", "/json/servers"].contains($0.url?.path ?? "") })
    }

    func testDirectoryExhaustionSurfacesFixedErrorWithoutServerDetails() async throws {
        let transport = LiveRadioDirectoryFixture(failAll: true)
        let directory = LiveRadioDirectory(transport: { try await transport.fetch($0, limit: $1) })
        do { _ = try await directory.search(.npr); XCTFail("Expected failure") }
        catch { XCTAssertEqual(error.localizedDescription, LiveRadioError.unavailable.localizedDescription) }
        let requests = await transport.requests
        XCTAssertLessThanOrEqual(requests.count, 5)
    }

    func testHLSAcceptsRelativeHTTPSAudioAndRejectsInsecureOrOversizedPlaylists() throws {
        let base = URL(string: "https://stream.example.org/live/index.m3u8")!
        try LiveRadioStreamResolver.validatePlaylist(Data("#EXTM3U\n#EXTINF:6,\nsegment.aac\n".utf8), base: base)
        try LiveRadioStreamResolver.validatePlaylist(Data("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=128000,CODECS=\"mp4a.40.2\"\naudio.m3u8\n".utf8), base: base)
        for text in ["not a playlist", "#EXTM3U\nhttp://stream.example.org/a.aac", "#EXTM3U\nfile:///a.aac",
                     "#EXTM3U\n#EXT-X-STREAM-INF:CODECS=\"avc1,mp4a\"\naudio.m3u8",
                     "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"http://keys.example.org/key\"\na.aac"] {
            XCTAssertThrowsError(try LiveRadioStreamResolver.validatePlaylist(Data(text.utf8), base: base))
        }
        XCTAssertThrowsError(try LiveRadioStreamResolver.validatePlaylist(Data(repeating: 32, count: 65_537), base: base))
    }

    func testTransportHasNoSharedCookiesCredentialsOrCache() {
        let config = LiveRadioHTTP.configuration()
        XCTAssertNil(config.httpCookieStorage)
        XCTAssertNil(config.urlCredentialStorage)
        XCTAssertNil(config.urlCache)
        XCTAssertFalse(config.httpShouldSetCookies)
        XCTAssertEqual(config.timeoutIntervalForRequest, 8)
        XCTAssertEqual(config.timeoutIntervalForResource, 12)
    }

    func testHLSAudioKeyAndMediaURIsCannotMasqueradeAsVideoAttributes() throws {
        let base = URL(string: "https://stream.example.org/live/index.m3u8")!
        let playlists = [
            """
            #EXTM3U
            #EXT-X-KEY:METHOD=AES-128,URI="https://keys.example.org/avc1/hvc1/key?label=TYPE=VIDEO,CODECS=av01",IV=0x1234
            #EXTINF:6,
            segment.aac
            """,
            """
            #EXTM3U
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="hvc1",NAME="RESOLUTION=1920x1080,TYPE=VIDEO",URI="audio/avc1/hvc1.m3u8?CODECS=hev1,RESOLUTION=1920x1080"
            #EXT-X-STREAM-INF:BANDWIDTH=128000,CODECS="mp4a.40.2",AUDIO="hvc1"
            audio.m3u8
            """,
            """
            #EXTM3U
            #EXT-X-SESSION-KEY:METHOD=AES-128,URI="https://keys.example.org/i-frame-stream/av01"
            #EXT-X-MAP:URI="https://stream.example.org/vp09/header.aac"
            #EXTINF:6,
            segment.aac
            """
        ]
        for playlist in playlists {
            XCTAssertNoThrow(try LiveRadioStreamResolver.validatePlaylist(Data(playlist.utf8), base: base))
        }
    }

    func testHLSActualVideoAttributesAndIFrameTagsAreRejected() {
        let base = URL(string: "https://stream.example.org/live/index.m3u8")!
        var tags = [
            "#EXT-X-STREAM-INF:BANDWIDTH=128000,CODECS=\"mp4a.40.2\",RESOLUTION=1920x1080",
            "#EXT-X-MEDIA:URI=\"audio.m3u8?TYPE=AUDIO\",TYPE=VIDEO,GROUP-ID=\"video\",NAME=\"Camera\"",
            "#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=128000,URI=\"audio.m3u8\"",
            "#EXT-X-I-FRAMES-ONLY"
        ]
        for codec in ["avc1.4d001f", "avc3.4d001f", "hvc1.1.6.L93.B0", "hev1.1.6.L93.B0", "vp09.00.10.08", "av01.0.04M.08"] {
            tags.append("#EXT-X-STREAM-INF:BANDWIDTH=128000,CODECS=\"mp4a.40.2,\(codec)\"")
        }
        for tag in tags {
            XCTAssertThrowsError(try LiveRadioStreamResolver.validatePlaylist(Data("#EXTM3U\n\(tag)\naudio.m3u8\n".utf8), base: base), tag)
        }
    }

    func testHLSParsedURIsStillRequireQuotedPublicHTTPSReferences() {
        let base = URL(string: "https://stream.example.org/live/index.m3u8")!
        for uri in ["http://stream.example.org/avc1", "https://radio.local/hvc1", "file:///avc1.aac",
                    "https://127.0.0.1/live", "https://user:secret@stream.example.org/live", ""] {
            for tag in ["#EXT-X-KEY:METHOD=AES-128", "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",NAME=\"Live\""] {
                let text = "#EXTM3U\n\(tag),URI=\"\(uri)\"\naudio.m3u8\n"
                XCTAssertThrowsError(try LiveRadioStreamResolver.validatePlaylist(Data(text.utf8), base: base))
            }
        }
        let steering = "#EXTM3U\n#EXT-X-CONTENT-STEERING:SERVER-URI=\"http://stream.example.org/steering\"\naudio.m3u8\n"
        XCTAssertThrowsError(try LiveRadioStreamResolver.validatePlaylist(Data(steering.utf8), base: base))
    }

    func testHLSRepeatedAudioOnlyCodecsListIsAcceptedAsAllIndiaRadioPublishesIt() throws {
        let base = URL(string: "https://stream.example.org/live/index.m3u8")!
        let playlist = """
        #EXTM3U
        #EXT-X-STREAM-INF:PROGRAM-ID=1,AVERAGE-BANDWIDTH=32000,BANDWIDTH=32000,CODECS="mp4a.40.29",CODECS="mp4a.40.5"
        audio32kbps.m3u8
        """
        XCTAssertNoThrow(try LiveRadioStreamResolver.validatePlaylist(Data(playlist.utf8), base: base))
    }

    func testHLSMalformedDuplicateAndExcessiveAttributesFailClosed() {
        let base = URL(string: "https://stream.example.org/live/index.m3u8")!
        let invalid = [
            "#EXT-X-KEY:METHOD=AES-128,URI=https://keys.example.org/key",
            "#EXT-X-KEY:METHOD=AES-128,URI=\"https://keys.example.org/key",
            "#EXT-X-KEY:METHOD=AES-128,URI=\"https://keys.example.org/key\"garbage",
            "#EXT-X-KEY:METHOD=AES-128,URI=\"https://keys.example.org/key\",URI=\"http://keys.example.org/key\"",
            "#EXT-X-MEDIA:TYPE=AUDIO,TYPE=VIDEO,URI=\"audio.m3u8\"",
            "#EXT-X-STREAM-INF:CODECS=\"mp4a.40.2\",CODECS=\"avc1.4d001f\"",
            "#EXT-X-KEY:METHOD=AES-128,URI=\"https://keys.example.org/key\",",
            "#EXT-X-KEY:",
            "#EXT-X-KEY:" + (0..<65).map { "X-\($0)=1" }.joined(separator: ",")
        ]
        for tag in invalid {
            XCTAssertThrowsError(try LiveRadioStreamResolver.validatePlaylist(Data("#EXTM3U\n\(tag)\naudio.m3u8\n".utf8), base: base))
        }
    }

    func testRedirectsRejectDowngradesAndStripCredentialsWithThreeHopLimit() async {
        let session = URLSession(configuration: LiveRadioHTTP.configuration())
        defer { session.invalidateAndCancel() }
        let original = URL(string: "https://stream.example.org/live")!
        let response = HTTPURLResponse(url: original, statusCode: 302, httpVersion: nil, headerFields: nil)!
        func redirected(_ delegate: LiveRadioRedirects, _ destination: URL) async -> URLRequest? {
            var request = URLRequest(url: destination)
            request.setValue("account-secret", forHTTPHeaderField: "Authorization")
            request.setValue("cookie-secret", forHTTPHeaderField: "Cookie")
            request.setValue("recording-id", forHTTPHeaderField: "Referer")
            let task = session.dataTask(with: request)
            defer { task.cancel() }
            return await withCheckedContinuation { continuation in
                delegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request) {
                    continuation.resume(returning: $0)
                }
            }
        }
        let streams = LiveRadioRedirects(allowsStreams: true)
        for _ in 0..<3 {
            let clean = await redirected(streams, original)
            XCTAssertNotNil(clean)
            XCTAssertNil(clean?.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(clean?.value(forHTTPHeaderField: "Cookie"))
            XCTAssertNil(clean?.value(forHTTPHeaderField: "Referer"))
        }
        let excessive = await redirected(streams, original)
        XCTAssertNil(excessive)
        for url in ["http://stream.example.org/live", "https://localhost/live", "https://127.0.0.1/live", "file:///audio.mp3"] {
            let rejected = await redirected(LiveRadioRedirects(allowsStreams: true), URL(string: url)!)
            XCTAssertNil(rejected)
        }
        let directoryRedirect = await redirected(LiveRadioRedirects(allowsStreams: false), original)
        XCTAssertNil(directoryRedirect)
    }
}

private actor LiveRadioDirectoryFixture {
    let failAll: Bool
    private(set) var requests: [URLRequest] = []
    private var stationRequests = 0
    init(failAll: Bool) { self.failAll = failAll }

    func fetch(_ request: URLRequest, limit: Int) throws -> Data {
        requests.append(request)
        if request.url?.path == "/json/servers" { return Data("[]".utf8) }
        stationRequests += 1
        if failAll || stationRequests == 1 { throw URLError(.cannotConnectToHost) }
        return try LiveRadioTestSupport.payload()
    }
}

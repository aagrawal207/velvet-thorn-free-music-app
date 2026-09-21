import XCTest
@testable import GanaBajana

final class StreamValidationTests: XCTestCase {
    private let prefix = Data([0, 0, 0, 24]) + Data("ftypdash".utf8)
    private let url = URL(string: "https://audio.googlevideo.com/videoplayback")!

    func testAcceptsRealMP4RangeAndSaneWholeResponseHeaders() throws {
        let partial = HTTPURLResponse(url: url, statusCode: 206, httpVersion: nil, headerFields: [
            "Content-Type": "audio/mp4", "Content-Range": "bytes 0-1023/4000000"
        ])!
        XCTAssertNoThrow(try StreamValidation.validate(response: partial, prefix: prefix))
        let whole = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "audio/mp4"])!
        XCTAssertNoThrow(try StreamValidation.validate(response: whole, prefix: prefix))
    }

    func testRejectsForbiddenEmptyHTMLAndWrongByteRanges() {
        for (status, mime, range, data) in [
            (403, "audio/mp4", "bytes 0-1023/4000000", prefix),
            (206, "text/html", "bytes 0-1023/4000000", Data("<html>error</html>".utf8)),
            (206, "audio/mp4", "bytes 1-1023/4000000", prefix),
            (206, "audio/mp4", "bytes 0-invalid/4000000", prefix),
            (206, "audio/mp4", "bytes 0-1023/100", prefix),
            (206, "audio/mp4", "bytes 0-1023/0", prefix),
            (200, "audio/mp4", "", Data())
        ] {
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                headerFields: ["Content-Type": mime, "Content-Range": range])!
            XCTAssertThrowsError(try StreamValidation.validate(response: response, prefix: data))
        }
    }

    func testMP4AndWebMShareStrictFirstRangeValidation() throws {
        let webM = Data(OpusTestSupport.webM.prefix(12))
        for (mime, data) in [("audio/mp4", prefix), ("audio/webm", webM)] {
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 206, httpVersion: nil, headerFields: [
                "Content-Type": mime, "Content-Range": "bytes 0-1048575/4781518", "Content-Length": "1048576"
            ]))
            if mime == "audio/webm" { XCTAssertNoThrow(try StreamValidation.validateWebM(response: response, prefix: data)) }
            else { XCTAssertNoThrow(try StreamValidation.validate(response: response, prefix: data)) }
            let range = try StreamValidation.contentRange(in: response)
            XCTAssertEqual(range.start, 0)
            XCTAssertEqual(range.end, 1_048_575)
            XCTAssertEqual(range.total, 4_781_518)
            XCTAssertEqual(range.length, 1_048_576)
        }
        let later = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 206, httpVersion: nil, headerFields: [
            "Content-Type": "audio/webm", "Content-Range": "bytes 1048576-2097151/4781518", "Content-Length": "1048576"
        ]))
        XCTAssertEqual(try StreamValidation.contentRange(in: later).start, 1_048_576)
        XCTAssertThrowsError(try StreamValidation.validateWebM(response: later, prefix: webM))
    }

    func testRangeParserRejectsSignedFractionalWildcardOverflowAndAmbiguousFields() throws {
        for range in [
            "bytes +0-1023/4000000", "bytes 0-+1023/4000000", "bytes 0-1023/+4000000",
            "bytes 0-1023.0/4000000", "bytes 0-1023/4e6", "bytes 0-1023/4000000.0",
            "bytes 0-1023/9223372036854775808", "bytes 0-9223372036854775808/9223372036854775809",
            "bytes 0-1023/*", "bytes */4000000", "bytes 0--1023/4000000", "bytes 0-1023//4000000",
            "bytes 0-1023/4000000/", "bytes 0-1023/4000000, bytes 1024-2047/4000000",
            "bytes  0-1023/4000000", "bytes 0-1023/ 4000000", "items 0-1023/4000000",
            "bytes 1023-0/4000000", "bytes 0-1023/1023", "bytes 0-0/0"
        ] {
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 206, httpVersion: nil, headerFields: [
                "Content-Type": "audio/mp4", "Content-Range": range
            ]))
            XCTAssertThrowsError(try StreamValidation.contentRange(in: response), range)
            XCTAssertThrowsError(try StreamValidation.validate(response: response, prefix: prefix), range)
        }
    }

    func testRangeParserChecksDeclaredResponseLengthAndRejectsMultipart() throws {
        for length in ["0", "1023", "1025", "4000000", "+1024", "1024.0", "1024, 1024", "-1024"] {
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 206, httpVersion: nil, headerFields: [
                "Content-Type": "audio/mp4", "Content-Range": "bytes 0-1023/4000000", "Content-Length": length
            ]))
            XCTAssertThrowsError(try StreamValidation.contentRange(in: response), length)
        }
        let multipart = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 206, httpVersion: nil, headerFields: [
            "Content-Type": "multipart/byteranges; boundary=range", "Content-Range": "bytes 0-1023/4000000"
        ]))
        XCTAssertThrowsError(try StreamValidation.contentRange(in: multipart))
        let short = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 206, httpVersion: nil, headerFields: [
            "Content-Type": "audio/webm", "Content-Range": "bytes 0-10/4000000", "Content-Length": "11"
        ]))
        XCTAssertThrowsError(try StreamValidation.validateWebM(response: short, prefix: Data(OpusTestSupport.webM.prefix(12))))
    }

    func testClenUsesOnlyOnePositiveDecimalInteger() {
        for query in ["clen=+12", "clen=-12", "clen=12.0", "clen=1e6", "clen=NaN", "clen=0",
                      "clen=", "clen", "clen=12&clen=12", "clen=9223372036854775808", "clen=%2012", "clen=12%20"] {
            let source = URL(string: "https://audio.googlevideo.com/videoplayback?\(query)")!
            XCTAssertNil(AudioDownloader.declaredLength(in: source), query)
        }
        XCTAssertEqual(AudioDownloader.declaredLength(in: URL(string: "https://audio.googlevideo.com/videoplayback?clen=4781518")!), 4_781_518)
        XCTAssertEqual(AudioDownloader.declaredLength(in: URL(string: "https://audio.googlevideo.com/videoplayback?clen=00012")!), 12)
    }

    func testExactURLDurationWinsOverMismatchedCatalogAndResolverMetadata() {
        let track = Track(id: "JGwWNGJdvx8", title: "Shape of You", duration: 150)
        let stream = ResolvedStream(url: URL(string: "https://audio.googlevideo.com/videoplayback?dur=263.267")!, duration: 160)
        XCTAssertEqual(PlaybackTiming.duration(stream: stream, track: track), 263.267)
        XCTAssertEqual(PlaybackTiming.position(220, duration: PlaybackTiming.duration(stream: stream, track: track)), 220)
    }

    func testDurationRejectsNonfiniteNegativeImplausibleAndAmbiguousValues() {
        let track = Track(id: "JGwWNGJdvx8", title: "Song", duration: 200)
        for query in ["dur=nan", "dur=inf", "dur=-1", "dur=0", "dur=9999999999", "dur=10&dur=20"] {
            let stream = ResolvedStream(url: URL(string: "https://audio.googlevideo.com/videoplayback?\(query)")!, duration: 180)
            XCTAssertEqual(PlaybackTiming.duration(stream: stream, track: track), 180)
        }
        XCTAssertNil(PlaybackTiming.duration(stream: ResolvedStream(url: url), track: Track(id: "x", title: "Unknown")))
        XCTAssertEqual(PlaybackTiming.position(.infinity), 0)
        XCTAssertEqual(PlaybackTiming.position(-3, duration: 200), 0)
    }
}

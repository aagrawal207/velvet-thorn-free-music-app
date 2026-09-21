import XCTest
@testable import GanaBajana

final class StreamFastPathTests: XCTestCase {
    private let id = "fsiPzT50ZiM"
    private var audio: [String: Any] {
        ["mimeType": "audio/mp4; codecs=\"mp4a.40.2\"", "bitrate": 130_000,
         "url": "https://audio.googlevideo.com/videoplayback?dur=261.974&expire=4000000000&sig=ready"]
    }

    private func response(_ formats: [[String: Any]], status: String = "OK", videoID: String? = nil, viewCount: Any? = nil) throws -> Data {
        var details: [String: Any] = ["videoId": videoID ?? id]
        if let viewCount { details["viewCount"] = viewCount }
        return try JSONSerialization.data(withJSONObject: ["playabilityStatus": ["status": status],
            "videoDetails": details, "streamingData": ["adaptiveFormats": formats]])
    }

    func testViewCountIsTheDecimalStringInVideoDetailsAndNothingElse() throws {
        XCTAssertEqual(YouTubeAudioFastPath.viewCount(in: try response([audio], viewCount: "1234567890")), 1_234_567_890)
        XCTAssertEqual(YouTubeAudioFastPath.viewCount(in: try response([audio], viewCount: "0")), 0)
        XCTAssertNil(YouTubeAudioFastPath.viewCount(in: try response([audio])))
        XCTAssertNil(YouTubeAudioFastPath.viewCount(in: try response([audio], viewCount: "")))
        XCTAssertNil(YouTubeAudioFastPath.viewCount(in: try response([audio], viewCount: "-12")))
        XCTAssertNil(YouTubeAudioFastPath.viewCount(in: try response([audio], viewCount: "1.2B")))
        XCTAssertNil(YouTubeAudioFastPath.viewCount(in: try response([audio], viewCount: 1234)), "Only the provider's string form is trusted")
        XCTAssertNil(YouTubeAudioFastPath.viewCount(in: try response([audio], viewCount: "99999999999999999999")))
        XCTAssertNil(YouTubeAudioFastPath.viewCount(in: Data("not json".utf8)))
        XCTAssertEqual(try YouTubeAudioFastPath.audioURLs(in: response([audio], viewCount: "42"), videoID: id).count, 1)
    }

    func testReadyAudioIsAcceptedButVideoCipherChallengesAndDubbedAudioAreExcluded() throws {
        var video = audio; video["mimeType"] = "video/mp4; codecs=\"avc1.64001f, mp4a.40.2\""
        var disguisedVideo = audio; disguisedVideo["width"] = 1920
        var cipher = audio; cipher["signatureCipher"] = "s=challenge"
        var challenged = audio; challenged["url"] = (audio["url"] as! String) + "&n=challenge"
        var dubbed = audio; dubbed["audioTrack"] = ["displayName": "Hindi dubbed"]
        let urls = try YouTubeAudioFastPath.audioURLs(in: response([video, disguisedVideo, cipher, challenged, dubbed, audio]), videoID: id)
        XCTAssertEqual(urls.count, 1)
        XCTAssertEqual(PlaybackTiming.queryNumber("dur", in: urls[0]), 261.974)
    }

    func testRejectsUnplayableResponsesWrongVideoAndMissingDuration() throws {
        XCTAssertThrowsError(try YouTubeAudioFastPath.audioURLs(in: response([audio], status: "LOGIN_REQUIRED"), videoID: id))
        XCTAssertThrowsError(try YouTubeAudioFastPath.audioURLs(in: response([audio], videoID: "other"), videoID: id))
        var missingDuration = audio; missingDuration["url"] = "https://audio.googlevideo.com/videoplayback?sig=ready"
        XCTAssertTrue(try YouTubeAudioFastPath.audioURLs(in: response([missingDuration]), videoID: id).isEmpty)
    }

    func testBotCheckIsLoginRequiredOrASignInReasonAndStillYieldsNoAudio() throws {
        let botCheck = Data(#"{"playabilityStatus":{"status":"LOGIN_REQUIRED","reason":"Sign in to confirm you’re not a bot"}}"#.utf8)
        XCTAssertTrue(YouTubeAudioFastPath.isBotCheck(botCheck))
        XCTAssertTrue(YouTubeAudioFastPath.isBotCheck(Data(#"{"playabilityStatus":{"status":"LOGIN_REQUIRED"}}"#.utf8)), "The reason wording is not required")
        XCTAssertTrue(YouTubeAudioFastPath.isBotCheck(Data(#"{"playabilityStatus":{"status":"ERROR","reason":"Please SIGN IN to continue"}}"#.utf8)))
        XCTAssertTrue(YouTubeAudioFastPath.isBotCheck(Data(#"{"playabilityStatus":{"status":"UNPLAYABLE","reason":"Automated bot traffic"}}"#.utf8)))
        XCTAssertFalse(YouTubeAudioFastPath.isBotCheck(try response([audio])))
        XCTAssertFalse(YouTubeAudioFastPath.isBotCheck(Data(#"{"playabilityStatus":{"status":"OK","reason":"robot"}}"#.utf8)), "A playable response is never a gate")
        XCTAssertFalse(YouTubeAudioFastPath.isBotCheck(Data(#"{"playabilityStatus":{"status":"ERROR","reason":"Video unavailable"}}"#.utf8)))
        XCTAssertFalse(YouTubeAudioFastPath.isBotCheck(Data(#"{"videoDetails":{"videoId":"x"}}"#.utf8)))
        XCTAssertFalse(YouTubeAudioFastPath.isBotCheck(Data("not json".utf8)))
        XCTAssertThrowsError(try YouTubeAudioFastPath.audioURLs(in: botCheck, videoID: id)) { error in
            guard case PlaybackStreamError.noAudio = error else { return XCTFail("Expected noAudio, got \(error)") }
        }
    }

    func testLoudnessComesFromPlayerConfigAudioConfigAndRejectsGarbage() throws {
        func payload(_ audioConfig: [String: Any]?) throws -> Data {
            var object: [String: Any] = ["playabilityStatus": ["status": "OK"], "videoDetails": ["videoId": id],
                                         "streamingData": ["adaptiveFormats": [audio]]]
            if let audioConfig { object["playerConfig"] = ["audioConfig": audioConfig] }
            return try JSONSerialization.data(withJSONObject: object)
        }
        XCTAssertEqual(YouTubeAudioFastPath.loudness(in: try payload(["loudnessDb": 5.32, "perceptualLoudnessDb": -18.2])), 5.32)
        XCTAssertEqual(YouTubeAudioFastPath.loudness(in: try payload(["loudnessDb": -3])), -3)
        XCTAssertEqual(YouTubeAudioFastPath.loudness(in: try payload(["loudnessDb": 0])), 0)
        XCTAssertNil(YouTubeAudioFastPath.loudness(in: try payload(nil)))
        XCTAssertNil(YouTubeAudioFastPath.loudness(in: try payload(["perceptualLoudnessDb": -18.2])))
        XCTAssertNil(YouTubeAudioFastPath.loudness(in: try payload(["loudnessDb": "loud"])))
        XCTAssertNil(YouTubeAudioFastPath.loudness(in: try payload(["loudnessDb": 400])))
        XCTAssertNil(YouTubeAudioFastPath.loudness(in: Data("not json".utf8)))
        XCTAssertEqual(try YouTubeAudioFastPath.audioURLs(in: payload(["loudnessDb": 5.32]), videoID: id).count, 1)
    }
}

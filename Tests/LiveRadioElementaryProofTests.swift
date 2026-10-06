import XCTest
@testable import GanaBajana

enum LiveRadioFrameFixtures {
    static let url = URL(string: "https://stream.example.org/live")!
    static let mp3Frame = Data([0xFF, 0xFB, 0xB0, 0x60] + Array(repeating: UInt8(0), count: 622))
    static let adtsFrame = Data([0xFF, 0xF1, 0x50, 0x80, 0x0D, 0x7F, 0xFC] + Array(repeating: UInt8(0), count: 100))
    static var mp3: Data { mp3Frame + mp3Frame }
    static var adts: Data { adtsFrame + adtsFrame }
}

final class LiveRadioElementaryProofTests: XCTestCase {
    private let url = LiveRadioFrameFixtures.url

    func testTwoCompleteMP3FramesProduceURLBoundProofIncludingVBR() throws {
        let proof = try XCTUnwrap(LiveRadioElementaryProof.inspect(LiveRadioFrameFixtures.mp3, contentType: "audio/mpeg", url: url))
        XCTAssertEqual(proof.format, .mp3)
        XCTAssertTrue(proof.matches(url))
        XCTAssertFalse(proof.matches(URL(string: "https://stream.example.org/other")!))
        XCTAssertFalse(proof.matches(URL(string: "https://stream.example.org/live?token=other")!))
        let second = Data([0xFF, 0xFB, 0x90, 0x64] + Array(repeating: UInt8(0), count: 413))
        XCTAssertNotNil(LiveRadioElementaryProof.inspect(LiveRadioFrameFixtures.mp3Frame + second, contentType: "audio/mp3", url: url))
        for frame in [Data([0xFF, 0xF3, 0x80, 0x60] + Array(repeating: UInt8(0), count: 204)),
                      Data([0xFF, 0xE3, 0x80, 0x60] + Array(repeating: UInt8(0), count: 413))] {
            XCTAssertNotNil(LiveRadioElementaryProof.inspect(frame + frame, contentType: "audio/mpeg", url: url))
        }
    }

    func testTwoCompleteADTSFramesProduceProofWithAndWithoutCRC() throws {
        let proof = try XCTUnwrap(LiveRadioElementaryProof.inspect(LiveRadioFrameFixtures.adts, contentType: "audio/aacp", url: url))
        XCTAssertEqual(proof.format, .adts)
        var crcFrame = LiveRadioFrameFixtures.adtsFrame
        crcFrame[1] = 0xF0
        XCTAssertNotNil(LiveRadioElementaryProof.inspect(crcFrame + crcFrame, contentType: "audio/aac", url: url))
    }

    func testSinglePartialNonconsecutiveOrInconsistentFramesDoNotProveAudio() {
        let frame = LiveRadioFrameFixtures.mp3Frame
        var wrongRate = frame
        wrongRate[2] = 0xB4
        for data in [frame, frame + Data(frame.prefix(4)), frame + Data([0]) + frame, frame + wrongRate] {
            XCTAssertNil(LiveRadioElementaryProof.inspect(data, contentType: "audio/mpeg", url: url))
        }
        XCTAssertNil(LiveRadioElementaryProof.inspect(Data(LiveRadioFrameFixtures.adts.dropLast()), contentType: "audio/aac", url: url))
    }

    func testReservedMPEGFieldsAndMalformedADTSHeadersAreRejected() {
        for (offset, value) in [(0, UInt8(0)), (1, 0xEB), (1, 0xFF), (2, 0x00), (2, 0xF0), (2, 0xBC), (3, 0x62)] {
            var frame = LiveRadioFrameFixtures.mp3Frame
            frame[offset] = value
            XCTAssertNil(LiveRadioElementaryProof.inspect(frame + frame, contentType: "audio/mpeg", url: url))
        }
        for (offset, value) in [(0, UInt8(0)), (1, 0xF7), (2, 0x7C), (3, 0x00), (6, 0xFD)] {
            var frame = LiveRadioFrameFixtures.adtsFrame
            frame[offset] = value
            XCTAssertNil(LiveRadioElementaryProof.inspect(frame + frame, contentType: "audio/aac", url: url))
        }
        var tooShort = LiveRadioFrameFixtures.adtsFrame
        tooShort[4] = 0
        tooShort[5] = 0xFF
        XCTAssertNil(LiveRadioElementaryProof.inspect(tooShort + tooShort, contentType: "audio/aac", url: url))
    }

    func testMIMEOrEmbeddedAudioInsideVideoAndContainersIsNotProof() {
        let prefixes = [Data("<html>audio/mpeg".utf8), Data([0, 0, 0, 24]) + Data("ftypisom".utf8),
                        Data([0, 0, 1, 0xBA]), Data([0, 0, 0, 1, 0x67]), Data([0x47]) + Data(repeating: 0, count: 187),
                        Data("OggS".utf8), Data("RIFF".utf8)]
        for prefix in prefixes {
            XCTAssertNil(LiveRadioElementaryProof.inspect(prefix + LiveRadioFrameFixtures.mp3, contentType: "audio/mpeg", url: url))
        }
        XCTAssertNil(LiveRadioElementaryProof.inspect(Data("audio/mpeg".utf8), contentType: "audio/mpeg", url: url))
        XCTAssertNil(LiveRadioElementaryProof.inspect(LiveRadioFrameFixtures.mp3, contentType: "video/mp4", url: url))
        // A mislabelled audio type still needs real frames; the proof records the format the bytes show.
        XCTAssertEqual(LiveRadioElementaryProof.inspect(LiveRadioFrameFixtures.mp3, contentType: "audio/aac", url: url)?.format, .mp3)
        XCTAssertEqual(LiveRadioElementaryProof.inspect(LiveRadioFrameFixtures.adts, contentType: "audio/mpeg", url: url)?.format, .adts)
        XCTAssertNil(LiveRadioElementaryProof.inspect(LiveRadioFrameFixtures.mp3, contentType: "audio/mpeg", url: URL(fileURLWithPath: "/audio.mp3")))
        XCTAssertNil(LiveRadioElementaryProof.inspect(Data(repeating: 0, count: 8_193), contentType: "audio/mpeg", url: url))
    }

    func testBoundedID3TagAndFooterAreSkippedWithoutScanningArbitraryPayload() {
        let tag = Data([0x49, 0x44, 0x33, 4, 0, 0, 0, 0, 0, 4]) + Data(repeating: 0, count: 4)
        XCTAssertNotNil(LiveRadioElementaryProof.inspect(tag + LiveRadioFrameFixtures.mp3, contentType: "audio/mpeg", url: url))
        let header = Data([0x49, 0x44, 0x33, 4, 0, 0x10, 0, 0, 0, 4])
        let footer = Data([0x33, 0x44, 0x49, 4, 0, 0x10, 0, 0, 0, 4])
        XCTAssertNotNil(LiveRadioElementaryProof.inspect(header + Data(repeating: 0, count: 4) + footer + LiveRadioFrameFixtures.mp3,
                                                        contentType: "audio/mpeg", url: url))
        for invalid in [Data([0x49, 0x44, 0x33, 4, 0, 0, 0, 0, 0x20, 0]),
                        Data([0x49, 0x44, 0x33, 4, 0, 0, 0, 0, 0, 0x80]),
                        Data([0x49, 0x44, 0x33, 4, 0, 1, 0, 0, 0, 0]),
                        Data([0x49, 0x44, 0x33, 9, 0, 0, 0, 0, 0, 0])] {
            XCTAssertNil(LiveRadioElementaryProof.inspect(invalid + LiveRadioFrameFixtures.mp3, contentType: "audio/mpeg", url: url))
        }
    }

    func testMidFrameJoinNeedsThreeConsecutiveFramesFromTheFirstSyncWord() {
        let frame = LiveRadioFrameFixtures.mp3Frame
        let tail = Data(frame.suffix(200))
        XCTAssertNotNil(LiveRadioElementaryProof.inspect(tail + frame + frame + frame, contentType: "audio/mpeg", url: url))
        XCTAssertNil(LiveRadioElementaryProof.inspect(tail + frame + frame, contentType: "audio/mpeg", url: url),
                     "Two frames after a mid-stream join are not enough to rule out a chance sync word")
        let adts = LiveRadioFrameFixtures.adtsFrame
        XCTAssertNotNil(LiveRadioElementaryProof.inspect(Data(adts.suffix(40)) + adts + adts + adts, contentType: "audio/aac", url: url))
        let farJoin = Data(repeating: 0, count: LiveRadioElementaryProof.maximumSyncSearchBytes) + frame + frame + frame
        XCTAssertNil(LiveRadioElementaryProof.inspect(farJoin, contentType: "audio/mpeg", url: url))
    }

    func testContainersStayRejectedEvenWithThreeEmbeddedFrames() {
        let frames = LiveRadioFrameFixtures.mp3Frame + LiveRadioFrameFixtures.mp3Frame + LiveRadioFrameFixtures.mp3Frame
        for prefix in [Data("<html>".utf8), Data([0, 0, 0, 24]) + Data("ftypisom".utf8), Data("OggS".utf8), Data("RIFF".utf8)] {
            XCTAssertNil(LiveRadioElementaryProof.inspect(prefix + frames, contentType: "audio/mpeg", url: url))
        }
    }

    func testShoutcastContentTypeVariantsAndOctetStreamFollowTheDirectoryCodec() {
        for type in ["audio/x-mpeg", "audio/mpeg3", "audio/x-mp3", "audio/mpg"] {
            XCTAssertNotNil(LiveRadioElementaryProof.inspect(LiveRadioFrameFixtures.mp3, contentType: type, url: url))
        }
        XCTAssertNotNil(LiveRadioElementaryProof.inspect(LiveRadioFrameFixtures.adts, contentType: "audio/x-aacp", url: url))
        XCTAssertNotNil(LiveRadioElementaryProof.inspect(LiveRadioFrameFixtures.mp3, contentType: "application/octet-stream",
                                                        url: url, stationCodec: "MP3"))
        XCTAssertNotNil(LiveRadioElementaryProof.inspect(LiveRadioFrameFixtures.adts, contentType: "application/octet-stream",
                                                        url: url, stationCodec: "HE-AAC"))
        XCTAssertNil(LiveRadioElementaryProof.inspect(LiveRadioFrameFixtures.mp3, contentType: "application/octet-stream", url: url))
        XCTAssertEqual(LiveRadioElementaryProof.inspect(LiveRadioFrameFixtures.mp3, contentType: "application/octet-stream",
                                                       url: url, stationCodec: "AAC")?.format, .mp3)
        XCTAssertNil(LiveRadioElementaryProof.inspect(LiveRadioFrameFixtures.mp3, contentType: "application/octet-stream",
                                                     url: url, stationCodec: "OGG"))
    }
}

import Foundation
@testable import GanaBajana

enum OpusTestSupport {
    static let track = Track(id: "fsiPzT50ZiM", title: "Opus fixture", duration: 8)
    static let aacURL = URL(string: "https://audio.googlevideo.com/videoplayback?itag=140&dur=8&expire=4000000000")!
    static let opusURL = URL(string: "https://audio.googlevideo.com/videoplayback?itag=251&dur=8&expire=4000000000")!
    static let aacQuality = SourceAudioQuality(codec: .aac, bitRate: 128_000, sampleRate: 44_100, channels: 2)
    static let opusQuality = SourceAudioQuality(codec: .opus, bitRate: 160_000, sampleRate: 48_000, channels: 2)
    static let webM = Data([0x1a, 0x45, 0xdf, 0xa3]) + Data(repeating: 7, count: 128)
    static let mp4 = Data([0, 0, 0, 24]) + Data("ftypisom".utf8) + Data(repeating: 9, count: 256)
    static let inspection = OpusNativeAudio.Inspection(duration: 8, sampleRate: 48_000, channels: 2,
                                                      decodedFrames: 8_192, decodedBytes: 32_768)

    static func prepare(input: URL, output: URL) async throws -> OpusNativeAudio.Inspection {
        try Task.checkCancellation()
        _ = try Data(contentsOf: input)
        try mp4.write(to: output)
        return inspection
    }

    static func source(rate: Int = 160_000) -> ResolvedStream {
        ResolvedStream(url: URL(string: opusURL.absoluteString + "&rate=\(rate)")!, duration: 8,
                       quality: SourceAudioQuality(codec: .opus, bitRate: rate, sampleRate: 48_000, channels: 2))
    }

    static func fast() -> FastPathResult {
        FastPathResult(urls: [opusURL], loudnessDb: 2.5, viewCount: 42, qualityByURL: [opusURL: opusQuality],
                       aacFallbacks: [ResolvedStream(url: aacURL, quality: aacQuality)])
    }

    static func payload(_ formats: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["playabilityStatus": ["status": "OK"],
            "videoDetails": ["videoId": track.id], "streamingData": ["adaptiveFormats": formats]])
    }

    static func format(opus: Bool, rate: Int) -> [String: Any] {
        ["mimeType": opus ? "audio/webm; codecs=\"opus\"" : "audio/mp4; codecs=\"mp4a.40.2\"",
         "bitrate": rate + 10_000, "averageBitrate": rate, "audioSampleRate": opus ? "48000" : "44100",
         "audioChannels": 2, "url": (opus ? opusURL : aacURL).absoluteString]
    }
}

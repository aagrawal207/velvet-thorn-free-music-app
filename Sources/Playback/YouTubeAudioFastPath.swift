import Foundation
import YouTubeKit

struct FastPathResult: Sendable {
    var urls: [URL]
    var loudnessDb: Double?
    var viewCount: Int64?
    var qualityByURL: [URL: SourceAudioQuality]
    var aacFallbacks: [ResolvedStream]

    init(urls: [URL], loudnessDb: Double? = nil, viewCount: Int64? = nil, qualityByURL: [URL: SourceAudioQuality] = [:],
         aacFallbacks: [ResolvedStream] = []) {
        self.urls = urls
        self.loudnessDb = loudnessDb
        self.viewCount = viewCount
        self.qualityByURL = qualityByURL
        self.aacFallbacks = aacFallbacks
    }

    var streams: [ResolvedStream] {
        urls.map { ResolvedStream(url: $0, loudnessDb: loudnessDb, viewCount: viewCount, quality: qualityByURL[$0]) }
    }
}

enum YouTubeAudioFastPath {
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    static func extract(videoID: String, maximumBitRate: Int? = nil) async throws -> FastPathResult {
        let compatibility = YouTubeKitHooks.extractionCompatibility
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 6
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var watch = URLRequest(url: URL(string: "https://www.youtube.com/watch?v=\(videoID)")!)
        watch.httpShouldHandleCookies = false
        watch.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        watch.setValue("en-US,en", forHTTPHeaderField: "Accept-Language")
        let (html, response) = try await boundedResponse(for: watch, session: session)
        guard (response as? HTTPURLResponse)?.statusCode == 200, html.count <= 4_000_000,
              let text = String(data: html, encoding: .utf8) else { throw PlaybackStreamError.invalidMedia }
        guard let visitor = visitorData(in: text, compatibility: compatibility.rules) else { throw PlaybackStreamError.noAudio }
        try Task.checkCancellation()
        var request = URLRequest(url: URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue(visitor, forHTTPHeaderField: "X-Goog-Visitor-Id")
        request.setValue("101", forHTTPHeaderField: "X-Youtube-Client-Name")
        request.setValue("1.02", forHTTPHeaderField: "X-Youtube-Client-Version")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "videoId": videoID, "contentCheckOk": true, "racyCheckOk": true,
            "context": ["client": ["clientName": "VISIONOS", "clientVersion": "1.02",
                "deviceMake": "Apple", "deviceModel": "RealityDevice17,1",
                "osName": "visionOS", "osVersion": "26.5.23O471"]]
        ])
        let (data, playerResponse) = try await boundedResponse(for: request, session: session)
        guard (playerResponse as? HTTPURLResponse)?.statusCode == 200 else { throw PlaybackStreamError.invalidMedia }
        if isBotCheck(data) {
            YouTubeSessionRegistry.shared.recordBotCheck()
            throw PlaybackStreamError.signInRequired
        }
        guard compatibility.generation == YouTubeKitHooks.extractionCompatibility.generation else { throw CancellationError() }
        return try audioResult(in: data, videoID: videoID, allowOpus: OpusNativeAudio.isSupported, maximumBitRate: maximumBitRate)
    }

    static func visitorData(in text: String, compatibility: ExtractionCompatibility = .bundled) -> String? {
        if let updated = compatibility.visitorData(in: text) { return updated }
        return ExtractionCompatibility(visitorKeys: ["VISITOR_DATA", "visitorData"]).visitorData(in: text)
    }

    private static func boundedResponse(for request: URLRequest, session: URLSession) async throws -> (Data, URLResponse) {
        do { return try await session.boundedData(for: request, maximumBytes: 4_000_000) }
        catch is BoundedResponseError { throw PlaybackStreamError.invalidMedia }
    }

    /// YouTube's "confirm you're not a bot" gate arrives as LOGIN_REQUIRED; the reason wording changes, so it only adds evidence.
    static func isBotCheck(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let playability = object["playabilityStatus"] as? [String: Any],
              let status = playability["status"] as? String, status != "OK" else { return false }
        if status == "LOGIN_REQUIRED" { return true }
        let reason = (playability["reason"] as? String ?? "").lowercased()
        return reason.contains("bot") || reason.contains("sign in")
    }

    /// `videoDetails.viewCount` is a decimal string; anything else (missing, signed, non-numeric) is unknown.
    static func viewCount(in data: Data) -> Int64? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let details = object["videoDetails"] as? [String: Any],
              let text = details["viewCount"] as? String, !text.isEmpty, text.count <= 18,
              text.utf8.allSatisfy({ (48...57).contains($0) }), let count = Int64(text) else { return nil }
        return count
    }

    /// YouTube's own "stable volume" reference: positive values are louder than its target and get attenuated.
    static func loudness(in data: Data) -> Double? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let config = object["playerConfig"] as? [String: Any],
              let audio = config["audioConfig"] as? [String: Any],
              let loudness = (audio["loudnessDb"] as? NSNumber)?.doubleValue,
              loudness.isFinite, abs(loudness) <= 60 else { return nil }
        return loudness
    }

    static func audioURLs(in data: Data, videoID: String) throws -> [URL] {
        try audioResult(in: data, videoID: videoID).urls
    }

    static func audioResult(in data: Data, videoID: String, allowOpus: Bool = false, maximumBitRate: Int? = nil) throws -> FastPathResult {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = object["playabilityStatus"] as? [String: Any], status["status"] as? String == "OK",
              let details = object["videoDetails"] as? [String: Any], details["videoId"] as? String == videoID,
              details["isLiveContent"] as? Bool != true,
              let streaming = object["streamingData"] as? [String: Any],
              let formats = streaming["adaptiveFormats"] as? [[String: Any]] else { throw PlaybackStreamError.noAudio }
        let eligibleAudio = formats.compactMap { format -> (format: [String: Any], quality: SourceAudioQuality)? in
            guard let mime = format["mimeType"] as? String,
                  format["width"] == nil, format["height"] == nil, format["fps"] == nil,
                  isOriginalAudio(format) else { return nil }
            let codec: SourceAudioQuality.Codec
            switch mime {
            case "audio/mp4; codecs=\"mp4a.40.2\"": codec = .aac
            case "audio/mp4; codecs=\"mp4a.40.5\"": codec = .heAAC
            case "audio/webm; codecs=\"opus\"" where allowOpus: codec = .opus
            default: return nil
            }
            let quality = SourceAudioQuality(codec: codec,
                bitRate: SourceAudioQuality.preferredBitRate(average: format["averageBitrate"] as? Int, advertised: format["bitrate"] as? Int),
                sampleRate: (format["audioSampleRate"] as? String).flatMap(Int.init) ?? format["audioSampleRate"] as? Int,
                channels: format["audioChannels"] as? Int)
            return (format, quality)
        }
        var result = FastPathResult(urls: [], loudnessDb: loudness(in: data), viewCount: viewCount(in: data))
        // Under a ceiling the "best" tier is the best fitting format (or the lowest offered), for Opus and AAC alike.
        let ranked = SourceAudioQuality.ranked(eligibleAudio, maximumBitRate: maximumBitRate) { $0.quality }
        let best = ranked.first?.quality
        let bestAACRate = ranked.first { $0.quality.codec != .opus }.map { $0.quality.bitRate ?? 0 }
        // Ranking precedes URL usability so a challenged best tier reaches full extraction before an AAC downgrade.
        for (format, quality) in ranked {
            let isBest = (quality.bitRate ?? 0) == (best?.bitRate ?? 0) && (quality.codec == .opus) == (best?.codec == .opus)
            let isAACFallback = quality.codec != .opus && (quality.bitRate ?? 0) == bestAACRate
            guard isBest || isAACFallback,
                  format["signatureCipher"] == nil, format["cipher"] == nil,
                  let text = format["url"] as? String, let url = URL(string: text), url.scheme == "https",
                  url.host?.hasSuffix(".googlevideo.com") == true,
                  PlaybackTiming.validDuration(PlaybackTiming.queryNumber("dur", in: url)) != nil else { continue }
            let keys = Set(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name) ?? [])
            // Cipher and n challenges belong to YouTubeKit; a guessed transform can produce an apparently valid but rejected URL.
            guard keys.isDisjoint(with: ["n", "s"]) else { continue }
            if isBest, result.urls.count < 3, !result.urls.contains(url) {
                result.urls.append(url)
                result.qualityByURL[url] = quality
            }
            if isAACFallback, result.aacFallbacks.count < 3, !result.aacFallbacks.contains(where: { $0.url == url }) {
                result.aacFallbacks.append(ResolvedStream(url: url, loudnessDb: result.loudnessDb,
                    viewCount: result.viewCount, quality: quality))
            }
        }
        return result
    }

    private static func isOriginalAudio(_ format: [String: Any]) -> Bool {
        guard let value = format["audioTrack"] else { return true }
        guard let track = value as? [String: Any], let name = track["displayName"] as? String else { return false }
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !label.contains("dub"), !label.contains("not original"), !label.contains("non-original"),
              !label.contains("non original") else { return false }
        return label == "original" || label.hasSuffix(" original") || label.hasSuffix(" (original)")
    }
}

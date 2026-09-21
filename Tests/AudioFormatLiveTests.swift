import AudioToolbox
import AVFoundation
import CryptoKit
import Foundation
import XCTest
@testable import GanaBajana

@MainActor
final class AudioFormatLiveTests: XCTestCase {
    private struct Source {
        let url: URL
        let fileExtension: String
        let formatID: AudioFormatID
        let length: Int
        let metadata: [String: Any]
    }

    private func requireProbe() throws {
        guard ProcessInfo.processInfo.environment["GANABAJANA_AUDIO_FORMAT_TESTS"] == "1" else {
            throw XCTSkip("Set GANABAJANA_AUDIO_FORMAT_TESTS=1 to run native audio-format probes.")
        }
    }

    func testAnonymousAACAndOpusWebMWithNativeAVPlayer() async throws {
        try requireProbe()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 90
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let sources: [Source]
        do { sources = try await publicSources(session: session) }
        catch { throw XCTSkip("Anonymous source acquisition unavailable: \(Self.errorCode(error)). No format conclusion.") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GanaBajanaAudioFormat-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try await withPlaybackSession {
            for source in sources {
                let data: Data
                let response: HTTPURLResponse
                do {
                    var request = URLRequest(url: source.url)
                    request.httpShouldHandleCookies = false
                    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                    (data, response) = try await fetch(request, session: session, limit: source.length)
                    guard data.count == source.length else { throw PlaybackStreamError.invalidMedia }
                    if source.fileExtension == "webm" {
                        guard response.mimeType == "audio/webm", data.starts(with: [0x1a, 0x45, 0xdf, 0xa3]) else {
                            throw PlaybackStreamError.invalidMedia
                        }
                    } else { try StreamValidation.validate(response: response, prefix: Data(data.prefix(1024))) }
                } catch {
                    XCTFail("\(source.fileExtension) acquisition failed: \(Self.errorCode(error)). No format conclusion.")
                    continue
                }
                let local = directory.appendingPathComponent("source.\(source.fileExtension)")
                try data.write(to: local, options: .atomic)
                let identical = try Data(contentsOf: local) == data
                XCTAssertTrue(identical, "The native file probe must receive the exact downloaded bytes.")
                var metadata = source.metadata
                metadata["httpStatus"] = response.statusCode
                metadata["contentType"] = response.mimeType
                metadata["contentLength"] = response.expectedContentLength
                metadata["bytes"] = data.count
                metadata["sha256"] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                metadata["downloadMatchesFile"] = identical

                // A complete local copy separates container/decoder support from CDN transport failures.
                for (transport, url) in [("file", local), ("https", source.url)] {
                    let result = await probe(url: url, expectedFormat: source.formatID)
                    try record(result, label: "\(source.fileExtension)-\(transport)", metadata: metadata)
                    XCTAssertTrue(result.proven, "\(source.fileExtension)-\(transport) native support not established. See AUDIO FORMAT attachment.")
                }
            }
        }
    }

    // A supplied CAF/MP4 establishes container playback only; its WebM packet equivalence needs separate evidence.
    func testProvidedOpusContainerWithNativeAVPlayer() async throws {
        try requireProbe()
        guard let path = ProcessInfo.processInfo.environment["GANABAJANA_OPUS_FIXTURE_PATH"], !path.isEmpty else {
            throw XCTSkip("Set GANABAJANA_OPUS_FIXTURE_PATH to a local, audio-only Opus CAF, MP4, or WebM fixture.")
        }
        for path in path.split(separator: "\n") {
            try await probeProvidedContainer(URL(fileURLWithPath: String(path)))
        }
    }

    private func probeProvidedContainer(_ url: URL) async throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= AudioCache.maximumFileBytes,
              ["caf", "m4a", "mp4", "webm"].contains(url.pathExtension.lowercased()) else {
            throw PlaybackStreamError.invalidMedia
        }
        let data = try Data(contentsOf: url)
        try await withPlaybackSession {
            let result = await probe(url: url, expectedFormat: kAudioFormatOpus)
            try record(result, label: "provided-opus-\(url.lastPathComponent)", metadata: [
                "source": "coordinator-supplied fixture", "bytes": data.count,
                "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                "remuxEquivalenceVerified": false,
            ])
            XCTAssertTrue(result.proven, "Native Opus container support not established. See AUDIO FORMAT attachment.")
            XCTAssertGreaterThan(result.tracks?.decodedFrames ?? 0, 0, "The native reader must decode actual PCM frames.")
        }
    }

    private func withPlaybackSession(_ operation: @MainActor () async throws -> Void) async throws {
        let session = AVAudioSession.sharedInstance()
        let previous = (session.category, session.mode, session.categoryOptions)
        defer {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            try? session.setCategory(previous.0, mode: previous.1, options: previous.2)
        }
        try session.setCategory(.playback, mode: .default, options: [])
        try session.setActive(true)
        try await operation()
    }

    private func probe(url: URL, expectedFormat: AudioFormatID) async -> NativeAudioProbeResult {
        let asset = AVURLAsset(url: url)
        defer { asset.cancelLoading() }
        var result = NativeAudioProbeResult(expectedFormat: expectedFormat)
        do {
            result.isPlayable = try await PlaybackDeadline.run(seconds: 15) { try await asset.load(.isPlayable) }
        } catch { result.errors.append("isPlayable: \(Self.errorCode(error))") }
        do {
            result.tracks = try await PlaybackDeadline.run(seconds: 15) { try await Self.inspect(asset, readPacket: url.isFileURL) }
        } catch { result.errors.append("tracks: \(Self.errorCode(error))") }

        // Metadata and MIME predictions alone can succeed without an operational decoder.
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = url.isFileURL ? 0 : 15
        let player = AVPlayer(playerItem: item)
        player.allowsExternalPlayback = false
        player.isMuted = false
        player.volume = 1
        defer {
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
        do {
            try await PlaybackTestSupport.waitUntil(timeout: 25) { item.status != .unknown }
            result.readyToPlay = item.status == .readyToPlay
            result.enabledAudioTracks = item.tracks.filter { $0.isEnabled && $0.assetTrack?.mediaType == .audio }.count
            if result.readyToPlay, result.tracks?.audioCount == 1, result.tracks?.videoCount == 0 {
                let start = player.currentTime().seconds
                player.play()
                try await PlaybackTestSupport.waitUntil(timeout: 20) {
                    item.status == .failed || (player.timeControlStatus == .playing && player.rate > 0
                        && player.currentTime().seconds.isFinite && player.currentTime().seconds - start >= 2)
                }
                let advanced = player.currentTime().seconds - start
                if advanced.isFinite { result.advancedSeconds = advanced }
                result.playing = player.timeControlStatus == .playing && player.rate > 0 && item.status == .readyToPlay
            }
        } catch { result.errors.append("player: \(Self.errorCode(error))") }
        result.itemStatus = item.status.rawValue
        if let error = item.error { result.errors.append("item: \(Self.errorCode(error))") }
        if let error = player.error { result.errors.append("player: \(Self.errorCode(error))") }
        return result
    }

    nonisolated private static func inspect(_ asset: AVURLAsset, readPacket: Bool) async throws -> NativeAudioProbeTracks {
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let video = try await asset.loadTracks(withMediaType: .video)
        var result = NativeAudioProbeTracks(audioCount: audio.count, videoCount: video.count)
        for track in audio {
            let descriptions = try await track.load(.formatDescriptions)
            for description in descriptions {
                guard let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else { continue }
                result.formats.append(.init(formatID: format.mFormatID, sampleRate: format.mSampleRate, channels: format.mChannelsPerFrame))
            }
        }
        guard readPacket, audio.count == 1, video.isEmpty else { return result }
        do {
            let reader = try AVAssetReader(asset: asset)
            defer { reader.cancelReading() }
            // nil requests stored compressed samples; this is a demux capability probe, not a transcoder.
            let output = AVAssetReaderTrackOutput(track: audio[0], outputSettings: nil)
            guard reader.canAdd(output) else { result.readerError = "cannotAdd"; return result }
            reader.add(output)
            if reader.startReading(), let sample = output.copyNextSampleBuffer(),
               let description = CMSampleBufferGetFormatDescription(sample) {
                result.storedSampleBytes = CMSampleBufferGetTotalSampleSize(sample)
                result.storedSampleFormatID = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee.mFormatID
            } else { result.readerError = reader.error.map(errorCode) ?? "no stored sample" }
        } catch { result.readerError = errorCode(error) }
        do {
            let reader = try AVAssetReader(asset: asset)
            defer { reader.cancelReading() }
            let output = AVAssetReaderTrackOutput(track: audio[0], outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            guard reader.canAdd(output) else { result.decoderError = "cannotAdd"; return result }
            reader.add(output)
            if reader.startReading(), let sample = output.copyNextSampleBuffer() {
                result.decodedFrames = CMSampleBufferGetNumSamples(sample)
                result.decodedBytes = CMSampleBufferGetTotalSampleSize(sample)
            } else { result.decoderError = reader.error.map(errorCode) ?? "no decoded sample" }
        } catch { result.decoderError = errorCode(error) }
        return result
    }

    private func record(_ result: NativeAudioProbeResult, label: String, metadata: [String: Any]) throws {
        var report = metadata
        report["os"] = ProcessInfo.processInfo.operatingSystemVersionString
        #if targetEnvironment(simulator)
        report["runtime"] = "iOS Simulator"
        #else
        report["runtime"] = "iOS device"
        #endif
        report["label"] = label
        report["proven"] = result.proven
        report["native"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(result))
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "AUDIO FORMAT \(label)"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("AUDIO FORMAT \(String(decoding: data, as: UTF8.self))")
    }

    private func publicSources(session: URLSession) async throws -> [Source] {
        let id = "fsiPzT50ZiM"
        var watch = URLRequest(url: URL(string: "https://www.youtube.com/watch?v=\(id)")!)
        watch.httpShouldHandleCookies = false
        watch.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        watch.setValue("en-US,en", forHTTPHeaderField: "Accept-Language")
        let (html, _) = try await fetch(watch, session: session, limit: 4 << 20)
        let text = String(decoding: html, as: UTF8.self)
        let expression = try NSRegularExpression(pattern: #""(?:VISITOR_DATA|visitorData)":"([^"]+)""#)
        guard let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { throw PlaybackStreamError.noAudio }
        var request = URLRequest(url: URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue(String(text[range]), forHTTPHeaderField: "X-Goog-Visitor-Id")
        request.setValue("101", forHTTPHeaderField: "X-Youtube-Client-Name")
        request.setValue("1.02", forHTTPHeaderField: "X-Youtube-Client-Version")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "videoId": id, "context": ["client": ["clientName": "VISIONOS", "clientVersion": "1.02",
                "deviceMake": "Apple", "deviceModel": "RealityDevice17,1", "osName": "visionOS", "osVersion": "26.5.23O471"]],
        ])
        let (data, _) = try await fetch(request, session: session, limit: 4 << 20)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = object["playabilityStatus"] as? [String: Any], status["status"] as? String == "OK",
              let details = object["videoDetails"] as? [String: Any], details["videoId"] as? String == id,
              details["isLiveContent"] as? Bool != true,
              let streaming = object["streamingData"] as? [String: Any],
              let formats = streaming["adaptiveFormats"] as? [[String: Any]] else { throw PlaybackStreamError.noAudio }
        let targets: [(Int, String, String, AudioFormatID)] = [
            (140, "audio/mp4; codecs=\"mp4a.40.2\"", "m4a", kAudioFormatMPEG4AAC),
            (251, "audio/webm; codecs=\"opus\"", "webm", kAudioFormatOpus),
        ]
        return try targets.map { itag, mime, fileExtension, formatID in
            guard let format = formats.first(where: { ($0["itag"] as? Int) == itag && ($0["isDrc"] as? Bool) != true }),
                  format["mimeType"] as? String == mime, format["width"] == nil, format["height"] == nil, format["fps"] == nil,
                  format["signatureCipher"] == nil, format["cipher"] == nil,
                  let text = format["url"] as? String, let url = URL(string: text), url.scheme == "https",
                  url.host?.hasSuffix(".googlevideo.com") == true,
                  let lengthText = format["contentLength"] as? String, let length = Int(lengthText),
                  length > 0, length <= AudioCache.maximumFileBytes else { throw PlaybackStreamError.noAudio }
            let keys = Set(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name) ?? [])
            guard keys.isDisjoint(with: ["n", "s"]) else { throw PlaybackStreamError.noAudio }
            if let track = format["audioTrack"] as? [String: Any],
               !(track["displayName"] as? String ?? "").lowercased().hasSuffix("original") { throw PlaybackStreamError.noAudio }
            var metadata: [String: Any] = ["source": "anonymous VISIONOS", "recordingID": id, "itag": itag, "mime": mime]
            for key in ["bitrate", "averageBitrate", "audioChannels"] {
                if let value = format[key] as? Int { metadata[key] = value }
            }
            if let value = format["audioSampleRate"] as? String, let rate = Int(value) { metadata["audioSampleRate"] = rate }
            return Source(url: url, fileExtension: fileExtension, formatID: formatID, length: length, metadata: metadata)
        }
    }

    private func fetch(_ request: URLRequest, session: URLSession, limit: Int) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw PlaybackStreamError.invalidMedia }
        guard http.statusCode == 200 else { throw PlaybackStreamError.httpStatus(http.statusCode) }
        guard http.expectedContentLength <= limit else { throw PlaybackStreamError.invalidMedia }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < limit else { throw PlaybackStreamError.invalidMedia }
            data.append(byte)
        }
        return (data, http)
    }

    // NSError descriptions and AVPlayer error logs can contain signed URLs; retain only diagnostic codes.
    nonisolated private static func errorCode(_ error: any Error) -> String {
        if let error = error as? PlaybackStreamError { return String(describing: error) }
        let error = error as NSError
        let underlying = (error.userInfo[NSUnderlyingErrorKey] as? NSError).map { " underlying=\($0.domain)(\($0.code))" } ?? ""
        return "\(error.domain)(\(error.code))\(underlying)"
    }
}

private struct NativeAudioProbeResult: Encodable {
    let expectedFormat: AudioFormatID
    var isPlayable: Bool?
    var tracks: NativeAudioProbeTracks?
    var readyToPlay = false
    var enabledAudioTracks = 0
    var playing = false
    var advancedSeconds = 0.0
    var itemStatus = 0
    var errors: [String] = []

    var proven: Bool {
        guard isPlayable == true, readyToPlay, enabledAudioTracks == 1, playing, advancedSeconds >= 2,
              let tracks, tracks.audioCount == 1, tracks.videoCount == 0, !tracks.formats.isEmpty else { return false }
        return tracks.formats.allSatisfy { $0.formatID == expectedFormat && $0.sampleRate.isFinite && $0.sampleRate > 0 && $0.channels > 0 }
    }
}

private struct NativeAudioProbeTracks: Encodable, Sendable {
    struct Format: Encodable, Sendable {
        let formatID: AudioFormatID
        let sampleRate: Double
        let channels: UInt32
    }
    let audioCount: Int
    let videoCount: Int
    var formats: [Format] = []
    var storedSampleBytes: Int?
    var storedSampleFormatID: AudioFormatID?
    var readerError: String?
    var decodedFrames: Int?
    var decodedBytes: Int?
    var decoderError: String?
}

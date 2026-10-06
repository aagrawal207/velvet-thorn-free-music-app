import AVFoundation
import XCTest
@testable import GanaBajana

/// Live start latency per path from an empty cache (`GANABAJANA_LIVE_TESTS=1`, `GanaBajanaLive`); values are printed
/// as `FASTSTART` lines and attached, and nothing asserts on timing because the network is not under test.
final class PlaybackStartLiveTests: XCTestCase {
    private static let recordings = ["7374CZQoS2Y", "swJOIjjW69U", "9qnqYL0eNNI", "WrWcOLlmv7k", "NJAv_7lHUIU"]

    private struct Measurement: Encodable {
        var id: String
        var fastPathMs: Int?
        var fastPathOutcome: String
        var fastPathBest = ""
        var fastPathAAC = ""
        var extractionMs: Int?
        var extractionOutcome: String
        var extractionCodecs = ""
        var aacProbeMs: Int?
        var aacProbeOutcome = "skipped"
        var opusPrepareMs: Int?
        var opusPrepareOutcome = "skipped"
        var opusBytes: Int64?
        var resolveMs: Int?
        var resolveOutcome: String
        var resolvePath = ""
        var resolveCodec = ""
        var resolveIsFile = false
        var readyToPlayMs: Int?
        var readyOutcome = "skipped"
    }

    private func requireLiveTests() throws {
        guard ProcessInfo.processInfo.environment["GANABAJANA_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Set GANABAJANA_LIVE_TESTS=1 to measure live start latency against public YouTube recordings.")
        }
    }

    private static func milliseconds(_ start: ContinuousClock.Instant) -> Int {
        Int(start.duration(to: .now).components.seconds * 1000)
            + Int(start.duration(to: .now).components.attoseconds / 1_000_000_000_000_000)
    }

    private static func describe(_ error: any Error) -> String {
        if let error = error as? PlaybackStreamError {
            switch error {
            case .signInRequired: return "botCheck"
            case .noAudio: return "noAudio"
            case .timedOut: return "timedOut"
            case .expired: return "expired"
            case .invalidMedia: return "invalidMedia"
            case .httpStatus(let code): return "http\(code)"
            default: return "playbackStreamError"
            }
        }
        if error is CancellationError { return "cancelled" }
        if let error = error as? URLError { return "urlError\(error.errorCode)" }
        if error is MusicServiceError { return "musicServiceError" }
        return String(describing: type(of: error))
    }

    private static func codecSummary(_ streams: [ResolvedStream]) -> String {
        let aac = streams.filter { $0.quality?.codec != .opus }.compactMap { $0.quality?.bitRate }.max()
        let opus = streams.filter { $0.quality?.codec == .opus }.compactMap { $0.quality?.bitRate }.max()
        return "aac=\(aac.map { String($0 / 1000) } ?? "none") opus=\(opus.map { String($0 / 1000) } ?? "none") n=\(streams.count)"
    }

    /// One recording, one fresh cache per stage that writes; the resolver run uses its own empty cache.
    private func measure(_ id: String) async -> Measurement {
        var candidateTrack = Track(id: id, title: id)
        candidateTrack.isAudioRecording = true
        let track = candidateTrack
        var result = Measurement(id: id, fastPathOutcome: "", extractionOutcome: "", resolveOutcome: "")
        var candidates: [ResolvedStream] = []

        let fastStart = ContinuousClock.now
        do {
            let fast = try await PlaybackDeadline.run(seconds: 12) { try await YouTubeAudioFastPath.extract(videoID: id) }
            result.fastPathMs = Self.milliseconds(fastStart)
            candidates = fast.streams + fast.aacFallbacks
            result.fastPathOutcome = fast.streams.isEmpty ? (fast.aacFallbacks.isEmpty ? "challengedAll" : "challengedBest") : "ok"
            result.fastPathBest = Self.codecSummary(fast.streams)
            result.fastPathAAC = Self.codecSummary(fast.aacFallbacks)
        } catch {
            result.fastPathMs = Self.milliseconds(fastStart)
            result.fastPathOutcome = Self.describe(error)
        }

        let extractionStart = ContinuousClock.now
        do {
            let streams = try await PlaybackDeadline.run(seconds: 40) { try await YouTubeExtractionWorker.shared.extract(id: id, remote: false) }
            result.extractionMs = Self.milliseconds(extractionStart)
            result.extractionOutcome = streams.isEmpty ? "empty" : "ok"
            result.extractionCodecs = Self.codecSummary(streams)
            if candidates.isEmpty { candidates = streams }
        } catch {
            result.extractionMs = Self.milliseconds(extractionStart)
            result.extractionOutcome = Self.describe(error)
        }

        let ranked = SourceAudioQuality.ranked(candidates, maximumBitRate: nil, quality: \.quality)
        if let aac = ranked.first(where: { $0.quality?.codec != .opus }) {
            let probeStart = ContinuousClock.now
            do {
                try await PlaybackDeadline.run(seconds: 12) { try await StreamValidation.validate(url: aac.url) }
                result.aacProbeOutcome = "ok"
            } catch { result.aacProbeOutcome = Self.describe(error) }
            result.aacProbeMs = Self.milliseconds(probeStart)
        }
        if OpusNativeAudio.isSupported, let opus = ranked.first(where: { $0.quality?.codec == .opus }) {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BreezyFastStartOpus-\(UUID())", isDirectory: true)
            let cache = AudioCache(directory: directory)
            await cache.pin(id)
            let prepareStart = ContinuousClock.now
            do {
                let permit = try await cache.writePermit()
                let prepared = try await PlaybackDeadline.run(seconds: 40) {
                    try await cache.storeOpus(trackID: id, stream: opus, permit: permit, foreground: true)
                }
                result.opusPrepareOutcome = "ok"
                result.opusBytes = prepared.bytes
            } catch { result.opusPrepareOutcome = Self.describe(error) }
            result.opusPrepareMs = Self.milliseconds(prepareStart)
            await cache.pin(only: [])
            _ = try? await cache.clearUnused()
            try? FileManager.default.removeItem(at: directory)
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BreezyFastStartResolve-\(UUID())", isDirectory: true)
        let cache = AudioCache(directory: directory)
        let resolver = Self.productionShapedResolver(cache: cache)
        let resolveStart = ContinuousClock.now
        var resolved: ResolvedStream?
        do {
            let stream = try await PlaybackDeadline.run(seconds: 80) { try await resolver.resolve(track: track, forceRefresh: false) }
            result.resolveMs = Self.milliseconds(resolveStart)
            result.resolveOutcome = "ok"
            result.resolveCodec = stream.quality?.codec == .opus ? "opus" : "aac"
            result.resolveIsFile = stream.url.isFileURL
            result.resolvePath = PlaybackStartTrace.path(for: id)?.rawValue ?? "unknown"
            resolved = stream
        } catch {
            result.resolveMs = Self.milliseconds(resolveStart)
            result.resolveOutcome = Self.describe(error)
        }
        if let resolved {
            let readyStart = ContinuousClock.now
            result.readyOutcome = await Self.awaitReadiness(url: resolved.url, timeout: 25)
            result.readyToPlayMs = Self.milliseconds(readyStart)
        }
        await cache.pin(only: [])
        _ = try? await cache.clearUnused()
        try? FileManager.default.removeItem(at: directory)
        return result
    }

    /// The production initializer binds the app's installed cache directory; this mirrors it over a temporary cache.
    private static func productionShapedResolver(cache: AudioCache) -> YouTubeStreamResolver {
        YouTubeStreamResolver(extract: { _, _ in [] },
                              validate: { try await StreamValidation.validate(url: $0) },
                              fastExtract: { try await YouTubeAudioFastPath.extract(videoID: $0) },
                              audioCache: cache,
                              qualityExtract: { id, remote in try await YouTubeExtractionWorker.shared.extract(id: id, remote: remote) },
                              opusEnabled: OpusNativeAudio.isSupported)
    }

    /// AVPlayer readiness in the unit host; the simulator can load remote and local items without an audio route.
    @MainActor
    private static func awaitReadiness(url: URL, timeout: TimeInterval) async -> String {
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false
        defer { player.replaceCurrentItem(with: nil) }
        let start = ContinuousClock.now
        while start.duration(to: .now) < .seconds(timeout) {
            switch item.status {
            case .readyToPlay: return "ready"
            case .failed: return "failed"
            default: try? await Task.sleep(for: .milliseconds(20))
            }
        }
        return "timedOut"
    }

    func testStartLatencyPerPathForFivePublicRecordings() async throws {
        try requireLiveTests()
        var measurements: [Measurement] = []
        for id in Self.recordings {
            let measurement = await measure(id)
            measurements.append(measurement)
            print("FASTSTART id=\(measurement.id) fastPath=\(measurement.fastPathMs ?? -1)ms/\(measurement.fastPathOutcome) [\(measurement.fastPathBest) | fallback \(measurement.fastPathAAC)] "
                + "extraction=\(measurement.extractionMs ?? -1)ms/\(measurement.extractionOutcome) [\(measurement.extractionCodecs)] "
                + "aacProbe=\(measurement.aacProbeMs ?? -1)ms/\(measurement.aacProbeOutcome) "
                + "opusPrepare=\(measurement.opusPrepareMs ?? -1)ms/\(measurement.opusPrepareOutcome) bytes=\(measurement.opusBytes ?? 0) "
                + "resolve=\(measurement.resolveMs ?? -1)ms/\(measurement.resolveOutcome) path=\(measurement.resolvePath) codec=\(measurement.resolveCodec) file=\(measurement.resolveIsFile) "
                + "ready=\(measurement.readyToPlayMs ?? -1)ms/\(measurement.readyOutcome)")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let attachment = XCTAttachment(data: try encoder.encode(measurements), uniformTypeIdentifier: "public.json")
        attachment.name = "fast-start-measurements"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertFalse(measurements.isEmpty)
    }

    /// Resolution plus AVPlayer readiness for one track; `warm` first runs the warmer's URL-only resolution.
    private func startLine(_ label: String, track: Track, resolver: any StreamResolving,
                           warm: (() async -> Void)? = nil) async -> String {
        if let warm { await warm() }
        let start = ContinuousClock.now
        do {
            let stream = try await PlaybackDeadline.run(seconds: 60) { try await resolver.resolve(track: track, forceRefresh: false) }
            let resolveMs = Self.milliseconds(start)
            let readyStart = ContinuousClock.now
            let ready = await Self.awaitReadiness(url: stream.url, timeout: 25)
            let readyMs = Self.milliseconds(readyStart)
            let path = PlaybackStartTrace.startPath(for: track.id)?.rawValue ?? "unknown"
            return "FASTSTART-PATH case=\(label) path=\(path) codec=\(stream.quality?.codec == .opus ? "opus" : "aac") "
                + "bitRate=\((stream.quality?.bitRate ?? 0) / 1000) resolve=\(resolveMs)ms ready=\(readyMs)ms/\(ready) total=\(resolveMs + readyMs)ms"
        } catch {
            return "FASTSTART-PATH case=\(label) outcome=\(Self.describe(error)) resolve=\(Self.milliseconds(start))ms"
        }
    }

    /// Cold versus warmed starts per source, plus the AAC-best YouTube case (Data saver offers no Opus upgrade).
    func testStartLatencyForAACBestWarmedAndProviderPaths() async throws {
        try requireLiveTests()
        var lines: [String] = []
        for (index, id) in Self.recordings.prefix(2).enumerated() {
            var track = Track(id: id, title: id)
            track.isAudioRecording = true
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BreezyFastStartPaths-\(UUID())", isDirectory: true)
            let cache = AudioCache(directory: directory)
            let resolver = Self.productionShapedResolver(cache: cache)
            if index == 0 {
                await resolver.setAudioQualityPreference(.dataSaver)
                lines.append(await startLine("youtube-aac-best", track: track, resolver: resolver))
            } else {
                lines.append(await startLine("youtube-warmed", track: track, resolver: resolver) {
                    _ = await resolver.warm([track], download: false, token: UUID())
                })
            }
            await cache.pin(only: [])
            _ = try? await cache.clearUnused()
            try? FileManager.default.removeItem(at: directory)
        }

        let saavnCatalog = JioSaavnCatalogService()
        let saavn = JioSaavnStreamResolver(catalog: saavnCatalog)
        let gaanaCatalog = GaanaCatalogService()
        let gaana = GaanaStreamResolver(catalog: gaanaCatalog)
        let compositeDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("BreezyFastStartComposite-\(UUID())", isDirectory: true)
        let compositeCache = AudioCache(directory: compositeDirectory)
        defer { try? FileManager.default.removeItem(at: compositeDirectory) }
        let composite = CompositeStreamResolver(youTube: Self.productionShapedResolver(cache: compositeCache),
                                                saavn: saavn, gaana: gaana, audioCache: compositeCache)
        for (source, catalog) in [("saavn", saavnCatalog as any MusicCatalogProviding), ("gaana", gaanaCatalog as any MusicCatalogProviding)] {
            do {
                let page = try await PlaybackDeadline.run(seconds: 20) {
                    try await catalog.search(query: "Tum Hi Ho", filter: .songs, continuation: nil)
                }
                let songs = Array(page.tracks.prefix(2))
                guard songs.count == 2 else { lines.append("FASTSTART-PATH case=\(source) outcome=fewResults"); continue }
                lines.append(await startLine("\(source)-cold", track: songs[0], resolver: composite))
                lines.append(await startLine("\(source)-warmed", track: songs[1], resolver: composite) {
                    _ = await composite.warm([songs[1]], download: false, token: UUID())
                })
            } catch {
                lines.append("FASTSTART-PATH case=\(source) outcome=\(Self.describe(error))")
            }
        }
        lines.forEach { print($0) }
        let attachment = XCTAttachment(string: lines.joined(separator: "\n"))
        attachment.name = "fast-start-paths"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertFalse(lines.isEmpty)
    }
}

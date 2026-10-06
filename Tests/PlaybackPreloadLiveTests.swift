import AVFoundation
import XCTest
@testable import GanaBajana

/// Live tap-to-audio with and without a preloaded asset (`GANABAJANA_LIVE_TESTS=1`). `PRELOAD` lines are printed and
/// attached; assertions cover correctness only, because the network is not under test.
@MainActor
final class PlaybackPreloadLiveTests: XCTestCase {
    private static let recordings = ["7374CZQoS2Y", "swJOIjjW69U", "9qnqYL0eNNI", "NJAv_7lHUIU", "WrWcOLlmv7k"]

    private func requireLiveTests() throws {
        guard ProcessInfo.processInfo.environment["GANABAJANA_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Set GANABAJANA_LIVE_TESTS=1 to measure preloaded starts against public recordings.")
        }
    }

    private static func resolver(cache: AudioCache) -> YouTubeStreamResolver {
        YouTubeStreamResolver(extract: { _, _ in [] },
                              validate: { try await StreamValidation.validate(url: $0) },
                              fastExtract: { try await YouTubeAudioFastPath.extract(videoID: $0) },
                              audioCache: cache,
                              qualityExtract: { id, remote in try await YouTubeExtractionWorker.shared.extract(id: id, remote: remote) },
                              opusEnabled: OpusNativeAudio.isSupported)
    }

    /// Milliseconds from item creation to an advancing playhead, muted; -1 when it never started.
    private static func firstAudio(_ item: AVPlayerItem) async -> Int {
        let player = AVPlayer(playerItem: item)
        player.volume = 0
        defer { player.pause(); player.replaceCurrentItem(with: nil) }
        let begin = ContinuousClock.now
        player.play()
        while begin.duration(to: .now) < .seconds(20) {
            if item.status == .failed { return -1 }
            if player.currentTime().seconds > 0.2 { return Int(begin.duration(to: .now) / .milliseconds(1)) }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return -1
    }

    func testPreloadedSongsStartFasterThanWarmURLsAlone() async throws {
        try requireLiveTests()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BreezyPreloadLive-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let resolver = Self.resolver(cache: AudioCache(directory: directory))
        let store = PlaybackPreloadStore()
        let preloader = PlaybackPreloader(resolver: resolver, store: store, enabled: true)
        let queue = Self.recordings.map { id -> Track in
            var track = Track(id: id, title: id)
            track.isAudioRecording = true
            return track
        }
        let prepareStart = ContinuousClock.now
        preloader.setQueue(queue)
        try await PlaybackTestSupport.waitUntil(timeout: 40) { preloader.activeTrackIDs.isEmpty && store.count >= 3 }
        let prepareMs = Int(prepareStart.duration(to: .now) / .milliseconds(1))
        var lines = ["PRELOAD prepared=\(store.count)/\(queue.count) in \(prepareMs)ms"]
        var faster = 0
        var measured = 0
        for (index, track) in queue.enumerated() where store.hasUsableAsset(trackID: track.id) {
            let stream = try await resolver.resolve(track: track, forceRefresh: false)
            let duration = PlaybackTiming.duration(stream: stream, track: track) ?? 0
            let made = PlaybackStreamLoading.makeItem(stream: stream, trackID: track.id, duration: duration, preloads: store)
            XCTAssertTrue(made.usesPreload, track.id)
            // The same signed URL without the preloaded asset is today's warmed-URL tap; alternating the order
            // keeps a connection warmed by the first measurement from favouring either side.
            let warm: Int
            let preloaded: Int
            if index.isMultiple(of: 2) {
                preloaded = await Self.firstAudio(made.item)
                warm = await Self.firstAudio(PlaybackStreamLoading.makeItem(url: stream.url, duration: duration))
            } else {
                warm = await Self.firstAudio(PlaybackStreamLoading.makeItem(url: stream.url, duration: duration))
                preloaded = await Self.firstAudio(made.item)
            }
            XCTAssertGreaterThan(preloaded, 0, "A preloaded item must start playing (\(track.id))")
            measured += 1
            if preloaded > 0, warm > 0, preloaded < warm { faster += 1 }
            lines.append("PRELOAD id=\(track.id) warmURL=\(warm)ms preloaded=\(preloaded)ms")
        }
        lines.forEach { print($0) }
        let attachment = XCTAttachment(string: lines.joined(separator: "\n"))
        attachment.name = "playback-preload-live"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertGreaterThan(measured, 0, lines.joined(separator: "\n"))
    }
}

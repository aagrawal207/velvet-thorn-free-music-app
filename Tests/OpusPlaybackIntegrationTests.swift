import AudioToolbox
import AVFoundation
import CryptoKit
import XCTest
@testable import GanaBajana

@MainActor
final class OpusPlaybackIntegrationTests: XCTestCase {
    func testBridgePreserves160And256OpusPacketsAndNativePlaybackDecodesSeeksAndAdvances() async throws {
        try requireNativeTests()
        let manifest = try JSONDecoder().decode(OpusFixtureManifest.self,
            from: Data(contentsOf: fixture("OpusFixtures", fileExtension: "json")))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BreezyOpusNative-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = AVAudioSession.sharedInstance()
        let previous = (session.category, session.mode, session.categoryOptions)
        defer {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            try? session.setCategory(previous.0, mode: previous.1, options: previous.2)
        }
        try session.setCategory(.playback, mode: .default, options: [])
        try session.setActive(true)

        for sample in manifest.fixtures {
            let input = try fixture(sample.name, fileExtension: "webm")
            let reference = try fixture(sample.name, fileExtension: "mp4")
            let output = directory.appendingPathComponent("\(sample.name).m4a")
            try await OpusRemuxer.remux(input: input, output: output)
            let inspection = try await OpusNativeAudio.inspect(output)
            XCTAssertEqual(inspection.sampleRate, 48_000)
            XCTAssertEqual(inspection.channels, 2)
            XCTAssertEqual(inspection.duration, 8, accuracy: 0.1)
            XCTAssertGreaterThan(inspection.decodedFrames, 0)
            XCTAssertGreaterThan(inspection.decodedBytes, 0)
            let actual = try await Self.compressedFingerprint(output)
            let expected = try await Self.compressedFingerprint(reference)
            XCTAssertEqual(actual.sha256, sample.packetSHA256, "Compare encoded packet bytes with the WebM generator's independent hash")
            XCTAssertEqual(actual.sha256, expected.sha256)
            XCTAssertEqual(actual.bytes, sample.packetBytes * sample.packetCount)
            XCTAssertEqual(actual.sampleCount, expected.sampleCount)

            let asset = AVURLAsset(url: output)
            let playable = try await asset.load(.isPlayable)
            XCTAssertTrue(playable)
            let item = AVPlayerItem(asset: asset)
            let player = AVPlayer(playerItem: item)
            player.allowsExternalPlayback = false
            player.volume = 0.1
            defer { player.pause(); player.replaceCurrentItem(with: nil) }
            try await PlaybackTestSupport.waitUntil { item.status != .unknown }
            XCTAssertEqual(item.status, .readyToPlay)
            XCTAssertEqual(item.tracks.filter { $0.isEnabled && $0.assetTrack?.mediaType == .audio }.count, 1)
            XCTAssertFalse(item.tracks.contains { $0.assetTrack?.mediaType == .video })
            player.play()
            try await PlaybackTestSupport.waitUntil { player.timeControlStatus == .playing && player.currentTime().seconds > 2 }
            player.pause()
            let seeked = await withCheckedContinuation { continuation in
                player.seek(to: CMTime(seconds: 5, preferredTimescale: 48_000), toleranceBefore: .zero, toleranceAfter: .zero) {
                    continuation.resume(returning: $0)
                }
            }
            XCTAssertTrue(seeked)
            XCTAssertEqual(player.currentTime().seconds, 5, accuracy: 0.05)
            player.play()
            try await PlaybackTestSupport.waitUntil { player.timeControlStatus == .playing && player.currentTime().seconds > 5.5 }
            XCTAssertNil(item.error)
            print("OPUS NATIVE os=\(ProcessInfo.processInfo.operatingSystemVersionString) ffmpeg=\(OpusRemuxer.version) bitrate=\(sample.bitRate) encodedBytes=\(actual.bytes) sha256=\(actual.sha256) decodedFrames=\(inspection.decodedFrames)")
        }
    }

    func testNativeBridgeDeadlineAndInvalidInputLeaveNoOutputAndPreserveExistingFiles() async throws {
        try requireNativeTests()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BreezyOpusFailures-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = try fixture("opus-160", fileExtension: "webm")
        let output = directory.appendingPathComponent("output.part")
        do { try await OpusRemuxer.remux(input: input, output: output, timeout: 0); XCTFail("Expected deadline") }
        catch { guard case PlaybackStreamError.timedOut = error else { return XCTFail("Unexpected deadline result") } }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        let invalid = directory.appendingPathComponent("invalid.webm")
        try Data("not an audio container".utf8).write(to: invalid)
        do { try await OpusRemuxer.remux(input: invalid, output: output); XCTFail("Invalid input was accepted") }
        catch { XCTAssertTrue(error is OpusPreparationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        let existing = Data("preserve the caller's file".utf8)
        try existing.write(to: output)
        do { try await OpusRemuxer.remux(input: input, output: output); XCTFail("Existing output must not be overwritten") }
        catch { XCTAssertTrue(error is OpusPreparationError) }
        XCTAssertEqual(try Data(contentsOf: output), existing)
        let part = directory.appendingPathComponent("successful.part")
        try await OpusRemuxer.remux(input: input, output: part)
        let playable = directory.appendingPathComponent("successful.m4a")
        try FileManager.default.moveItem(at: part, to: playable)
        let inspected = try await OpusNativeAudio.inspect(playable)
        XCTAssertGreaterThan(inspected.decodedFrames, 0)
    }

    func testRealOpusAcquisitionFlowsThroughResolverPreparationCacheAndOfflineReuse() async throws {
        try requireNativeTests()
        guard OpusNativeAudio.isSupported else { throw XCTSkip("Production Opus preparation is gated to iOS 26.5+") }
        let input = try Data(contentsOf: fixture("opus-160", fileExtension: "webm"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BreezyOpusPipeline-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let mock = CatalogMockSession { _ in
            CatalogStub(headers: ["Content-Type": "audio/webm", "Content-Length": "\(input.count)"], data: input)
        }
        defer { mock.close() }
        let cache = AudioCache(directory: directory, session: mock.session)
        let resolver = YouTubeStreamResolver(extract: { _, _ in [] }, validate: { _ in },
            fastExtract: { _ in OpusTestSupport.fast() }, audioCache: cache, opusEnabled: true)
        await resolver.retainCached([OpusTestSupport.track.id])
        let prepared = try await resolver.resolve(track: OpusTestSupport.track, forceRefresh: false)
        XCTAssertTrue(prepared.url.isFileURL)
        XCTAssertTrue(resolver.isCachedStream(prepared))
        XCTAssertEqual(prepared.quality, OpusTestSupport.opusQuality)
        let hash = try await Self.compressedFingerprint(prepared.url)
        XCTAssertEqual(hash.sha256, "6cc88d45dc43977917025f1c7660afc40b1d9a486139ec036d7a3d845c04f046")
        let again = try await resolver.resolve(track: OpusTestSupport.track, forceRefresh: true)
        XCTAssertEqual(again.url, prepared.url)
        XCTAssertEqual(mock.state.requests.count, 1)
        let usage = try await resolver.audioCacheUsage()
        XCTAssertEqual(usage?.songCount, 1)
        XCTAssertEqual(usage?.pendingDownloads, 0)
        XCTAssertEqual(usage?.bytes, Int64(try Data(contentsOf: prepared.url).count))
    }

    func testPlayerQualityReloadAndClearRetainBothLiveEncodingAndOriginalFallback() async throws {
        try requireNativeTests()
        guard OpusNativeAudio.isSupported else { throw XCTSkip("Production Opus preparation is gated to iOS 26.5+") }
        let input = try Data(contentsOf: fixture("opus-160", fileExtension: "webm"))
        let storage = try CacheManagementFixture(handler: { _ in
            CatalogStub(headers: ["Content-Type": "audio/webm", "Content-Length": "\(input.count)"], data: input)
        })
        addTeardownBlock { try await storage.close() }
        let original = try storage.seed(OpusTestSupport.track.id, seconds: 8)
        let originalBytes = try Data(contentsOf: original)
        let resolver = YouTubeStreamResolver(extract: { _, _ in [] }, validate: { _ in },
            fastExtract: { _ in OpusTestSupport.fast() }, audioCache: storage.cache, opusEnabled: true)
        let player = PlayerController(resolver: resolver)
        defer { player.pause() }
        player.play([OpusTestSupport.track])
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.currentStreamURL == original }
        player.retry(preferBestAudio: true)
        try await PlaybackTestSupport.waitUntil(timeout: 20) { player.isPlaying && player.sourceAudioQuality?.codec == .opus }
        let prepared = try XCTUnwrap(player.currentStreamURL)
        XCTAssertNotEqual(prepared, original)
        let preparedBytes = try Data(contentsOf: prepared)
        let usage = try await player.clearTemporaryAudioCache()
        XCTAssertEqual(usage?.retainedSongCount, 1)
        XCTAssertEqual(usage?.retainedBytes, Int64(originalBytes.count + preparedBytes.count))
        XCTAssertEqual(try Data(contentsOf: original), originalBytes)
        let position = player.position
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.position > position + 0.2 }
        XCTAssertNil(player.errorMessage)
    }

    private func requireNativeTests() throws {
        guard OpusNativeAudio.isSupported else {
            throw XCTSkip("Native Opus integration is enabled on iOS 26.5 and later.")
        }
    }

    private func fixture(_ name: String, fileExtension ext: String) throws -> URL {
        let bundle = Bundle(for: Self.self)
        return try XCTUnwrap(bundle.url(forResource: name, withExtension: ext)
            ?? bundle.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"), "Bundle Tests/Fixtures as test resources")
    }

    nonisolated private static func compressedFingerprint(_ url: URL) async throws -> OpusPacketFingerprint {
        let asset = AVURLAsset(url: url)
        defer { asset.cancelLoading() }
        let audio = try await asset.loadTracks(withMediaType: .audio)
        guard audio.count == 1 else { throw MusicServiceError.unavailable("Fingerprint expected one audio track, found \(audio.count).") }
        let reader = try AVAssetReader(asset: asset)
        defer { reader.cancelReading() }
        let output = AVAssetReaderTrackOutput(track: audio[0], outputSettings: nil)
        guard reader.canAdd(output) else { throw MusicServiceError.unavailable("Fingerprint reader cannot add compressed audio output.") }
        reader.add(output)
        guard reader.startReading() else { throw MusicServiceError.unavailable("Fingerprint reader could not start: \(String(describing: reader.error)).") }
        var hash = SHA256()
        var byteCount = 0
        var sampleCount = 0
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            // Timing-only buffers contain no encoded packets to fingerprint.
            if CMSampleBufferGetNumSamples(sample) == 0 && CMSampleBufferGetTotalSampleSize(sample) == 0 { continue }
            let description = try XCTUnwrap(CMSampleBufferGetFormatDescription(sample), "Stored sample must identify its format.")
            let format = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(description), "Stored sample must expose its audio format.")
            XCTAssertEqual(format.pointee.mFormatID, kAudioFormatOpus)
            let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample), "Stored sample must contain packet bytes; samples=\(CMSampleBufferGetNumSamples(sample)).")
            let count = CMBlockBufferGetDataLength(block)
            guard count > 0, count <= 1 << 20 else { throw MusicServiceError.unavailable("Unexpected compressed chunk size: \(count).") }
            var bytes = Data(count: count)
            let status = bytes.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count, destination: $0.baseAddress!)
            }
            guard status == noErr else { throw MusicServiceError.unavailable("Compressed sample copy failed: \(status).") }
            hash.update(data: bytes)
            byteCount += count
            sampleCount += CMSampleBufferGetNumSamples(sample)
        }
        guard reader.status == .completed else { throw MusicServiceError.unavailable("Fingerprint reader ended with status \(reader.status.rawValue): \(String(describing: reader.error)).") }
        return OpusPacketFingerprint(sha256: hash.finalize().map { String(format: "%02x", $0) }.joined(),
                                     bytes: byteCount, sampleCount: sampleCount)
    }
}

private struct OpusPacketFingerprint: Sendable {
    let sha256: String
    let bytes: Int
    let sampleCount: Int
}

private struct OpusFixtureManifest: Decodable {
    struct Fixture: Decodable {
        let name: String
        let bitRate: Int
        let packetBytes: Int
        let packetCount: Int
        let packetSHA256: String
    }
    let fixtures: [Fixture]
}

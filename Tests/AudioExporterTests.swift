import AudioToolbox
import AVFoundation
import CryptoKit
import ImageIO
import UIKit
import XCTest
@testable import GanaBajana

final class AudioExporterTests: XCTestCase {
    private static let track = Track(id: "fsiPzT50ZiM", title: "Tum Hi Ho", artists: ["Arijit Singh"],
                                     albumTitle: "Aashiqui 2", duration: 2)

    func testAACPassthroughPreservesPacketsAndReadsBackAllTagsAndCover() async throws {
        let workspace = try makeDirectory()
        let source = try await Self.generateAAC(in: workspace)
        let original = try Data(contentsOf: source)
        let packets = try await Self.packetHash(source)
        let artwork = try AudioExportArtwork.jpeg(from: Self.image(width: 1_600, height: 1_600))
        let exporter = AudioExporter(directory: workspace.appendingPathComponent("exports"))
        let result = try await exporter.export(track: Self.track, source: Self.audio(source), artwork: artwork)
        XCTAssertFalse(result.transcoded)
        XCTAssertTrue(result.hasArtwork)
        XCTAssertEqual(result.url.lastPathComponent, "Arijit Singh - Tum Hi Ho.m4a")
        XCTAssertNotNil(UUID(uuidString: result.url.deletingLastPathComponent().lastPathComponent))
        try await Self.assertAAC(result, duration: 2, artwork: artwork)
        let exportedPackets = try await Self.packetHash(result.url)
        XCTAssertEqual(exportedPackets, packets, "AAC passthrough must preserve compressed packets, not merely the codec label")
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testActualAACOverridesWrongSidecarCodecAndWavExtension() async throws {
        let workspace = try makeDirectory()
        let source = try await Self.generateAAC(in: workspace)
        let misleading = workspace.appendingPathComponent("actually-aac.wav")
        try FileManager.default.copyItem(at: source, to: misleading)
        let exporter = AudioExporter(directory: workspace.appendingPathComponent("exports"))
        let result = try await exporter.export(track: Self.track,
            source: Self.audio(misleading, quality: SourceAudioQuality(codec: .opus)), artwork: nil)
        XCTAssertFalse(result.transcoded)
        try await Self.assertAAC(result, duration: 2)
        let originalPackets = try await Self.packetHash(source)
        let exportedPackets = try await Self.packetHash(result.url)
        XCTAssertEqual(exportedPackets, originalPackets)
    }

    func testPCMWithM4ANameAndAACSidecarIsActuallyEncodedToAAC() async throws {
        let workspace = try makeDirectory()
        let original = PlaybackTestSupport.audioData(seconds: 2)
        let exporter = AudioExporter(directory: workspace.appendingPathComponent("exports"))
        for name in ["source.wav", "actually-pcm.m4a"] {
            let source = workspace.appendingPathComponent(name)
            try original.write(to: source)
            let result = try await exporter.export(track: Self.track,
                source: Self.audio(source, quality: SourceAudioQuality(codec: .aac)), artwork: nil)
            XCTAssertTrue(result.transcoded)
            try await Self.assertAAC(result, duration: 2)
            XCTAssertEqual(try Data(contentsOf: source), original)
        }
    }

    func testFailedAACPassthroughFallsBackToNativeEncodingWithTags() async throws {
        let workspace = try makeDirectory()
        let source = try await Self.generateAAC(in: workspace)
        let original = try Data(contentsOf: source)
        let artwork = try AudioExportArtwork.jpeg(from: Self.image(width: 1_024, height: 512))
        let exporter = AudioExporter(directory: workspace.appendingPathComponent("exports"), stageObserver: { stage in
            if stage == .passthrough { throw AudioExportError.exportFailed }
        })
        let result = try await exporter.export(track: Self.track, source: Self.audio(source), artwork: artwork)
        XCTAssertTrue(result.transcoded)
        try await Self.assertAAC(result, duration: 2, artwork: artwork)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testGeneratedOpusFixturesConvertToTaggedAACOnSupportedRuntime() async throws {
        guard OpusNativeAudio.isSupported else { throw XCTSkip("Native Opus decoding requires the supported iOS runtime") }
        let workspace = try makeDirectory()
        let exporter = AudioExporter(directory: workspace.appendingPathComponent("exports"))
        let artwork = try AudioExportArtwork.jpeg(from: Self.image(width: 1_024, height: 1_024))
        for name in ["opus-160", "opus-256"] {
            let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "mp4", subdirectory: "Fixtures")
                ?? Bundle(for: Self.self).url(forResource: name, withExtension: "mp4"))
            let source = workspace.appendingPathComponent(name + ".m4a")
            let original = try Data(contentsOf: fixture)
            try original.write(to: source)
            let result = try await exporter.export(track: Self.track,
                source: Self.audio(source, quality: SourceAudioQuality(codec: .aac)), artwork: artwork)
            XCTAssertTrue(result.transcoded)
            try await Self.assertAAC(result, duration: 8, artwork: artwork)
            XCTAssertEqual(try Data(contentsOf: source), original)
        }
    }

    func testDamagedAndEmptyAudioFailWithoutPublishingOrChangingSource() async throws {
        let workspace = try makeDirectory()
        let valid = try await Self.generateAAC(in: workspace)
        let root = workspace.appendingPathComponent("exports")
        let exporter = AudioExporter(directory: root)
        for bytes in [Data(), Data("not audio".utf8), Data(try Data(contentsOf: valid).prefix(400))] {
            let source = workspace.appendingPathComponent("damaged.m4a")
            try bytes.write(to: source)
            do {
                _ = try await exporter.export(track: Self.track, source: Self.audio(source), artwork: nil)
                XCTFail("Invalid media must never become a shareable original")
            } catch {
                XCTAssertTrue(error is AudioExportError)
            }
            XCTAssertEqual(try Data(contentsOf: source), bytes)
            XCTAssertTrue(try Self.children(root).isEmpty)
        }
    }

    func testUnsupportedMultichannelPCMIsRejectedTruthfully() async throws {
        let workspace = try makeDirectory()
        let source = workspace.appendingPathComponent("surround.caf")
        let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_MPEG_5_1_A))
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channelLayout: layout)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
        buffer.frameLength = 48_000
        let channels = try XCTUnwrap(buffer.floatChannelData)
        for channel in 0..<6 { channels[channel].initialize(repeating: 0, count: 48_000) }
        do {
            let file = try AVAudioFile(forWriting: source, settings: format.settings)
            try file.write(from: buffer)
        }
        let original = try Data(contentsOf: source)
        let root = workspace.appendingPathComponent("exports")
        do {
            _ = try await AudioExporter(directory: root).export(track: Self.track, source: Self.audio(source), artwork: nil)
            XCTFail("Unsupported channels must not be copied or silently downmixed")
        } catch { XCTAssertEqual(error as? AudioExportError, .unsupportedAudio) }
        XCTAssertTrue(try Self.children(root).isEmpty)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testInvalidArtworkFailsInsteadOfSilentlyDroppingCover() async throws {
        let workspace = try makeDirectory()
        let source = try await Self.generateAAC(in: workspace)
        let root = workspace.appendingPathComponent("exports")
        do {
            _ = try await AudioExporter(directory: root).export(track: Self.track, source: Self.audio(source), artwork: Data([1, 2, 3]))
            XCTFail("Supplied artwork must be valid and embedded")
        } catch { XCTAssertEqual(error as? AudioExportError, .invalidArtwork) }
        XCTAssertTrue(try Self.children(root).isEmpty)
    }

    func testCancellationAfterEncodingDrainsAndRemovesUnpublishedOutput() async throws {
        let workspace = try makeDirectory()
        let source = workspace.appendingPathComponent("source.wav")
        let original = PlaybackTestSupport.audioData(seconds: 2)
        try original.write(to: source)
        let root = workspace.appendingPathComponent("exports")
        let entered = expectation(description: "Native encoder finished; validation has not published")
        let drained = expectation(description: "Cancelled operation drained")
        let exporter = AudioExporter(directory: root, stageObserver: { stage in
            if stage == .verify {
                entered.fulfill()
                defer { drained.fulfill() }
                try await Task.sleep(for: .seconds(60))
            }
        })
        let task = Task { try await exporter.export(track: Self.track, source: Self.audio(source), artwork: nil) }
        await fulfillment(of: [entered], timeout: 15)
        let folder = try XCTUnwrap(Self.children(root).first)
        XCTAssertFalse(try Self.children(folder).isEmpty, "Exercise cleanup after bytes have been written")
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled export returned a URL") }
        catch { XCTAssertTrue(error is CancellationError) }
        await fulfillment(of: [drained], timeout: 1)
        XCTAssertTrue(try Self.children(root).isEmpty)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testDeadlineDrainsAndRemovesPartialFilesWithoutLatePublication() async throws {
        let workspace = try makeDirectory()
        let source = workspace.appendingPathComponent("source.wav")
        let original = PlaybackTestSupport.audioData(seconds: 2)
        try original.write(to: source)
        let root = workspace.appendingPathComponent("exports")
        let drained = expectation(description: "Timeout drains the operation")
        let exporter = AudioExporter(directory: root, timeout: 0.1, stageObserver: { stage in
            if stage == .inspect {
                let folder = try XCTUnwrap(Self.children(root).first)
                try Data([1, 2, 3]).write(to: folder.appendingPathComponent("partial.m4a"))
                defer { drained.fulfill() }
                try await Task.sleep(for: .seconds(60))
            }
        })
        do { _ = try await exporter.export(track: Self.track, source: Self.audio(source), artwork: nil); XCTFail("Expected deadline") }
        catch { XCTAssertEqual(error as? AudioExportError, .timedOut) }
        await fulfillment(of: [drained], timeout: 1)
        XCTAssertTrue(try Self.children(root).isEmpty)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testPreCancelledAndZeroDeadlineCallsCreateNoOutput() async throws {
        let workspace = try makeDirectory()
        let source = try await Self.generateAAC(in: workspace)
        let root = workspace.appendingPathComponent("exports")
        let exporter = AudioExporter(directory: root, timeout: 0)
        do { _ = try await exporter.export(track: Self.track, source: Self.audio(source), artwork: nil); XCTFail("Expected timeout") }
        catch { XCTAssertEqual(error as? AudioExportError, .timedOut) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await exporter.export(track: Self.track, source: Self.audio(source), artwork: nil)
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(try Self.children(root).isEmpty)
    }

    func testConcurrentSameTitleExportsHaveIndependentFilesAndActiveSharesSurvivePruning() async throws {
        let workspace = try makeDirectory()
        let source = try await Self.generateAAC(in: workspace)
        let root = workspace.appendingPathComponent("exports")
        let exporter = AudioExporter(directory: root)
        async let first = exporter.export(track: Self.track, source: Self.audio(source), artwork: nil)
        async let second = exporter.export(track: Self.track, source: Self.audio(source), artwork: nil)
        let results = try await [first, second]
        XCTAssertNotEqual(results[0].url, results[1].url)
        XCTAssertEqual(results[0].url.lastPathComponent, results[1].url.lastPathComponent)
        let contents = try results.map { try Data(contentsOf: $0.url) }
        AudioExporter.pruneStaleExports(now: Date().addingTimeInterval(7_200), directory: root)
        for (index, result) in results.enumerated() {
            XCTAssertEqual(try Data(contentsOf: result.url), contents[index])
            try await Self.assertAAC(result, duration: 2)
        }
    }

    func testConcurrencyLimitRejectsThirdRequestWithoutTouchingActiveFiles() async throws {
        let workspace = try makeDirectory()
        let source = try await Self.generateAAC(in: workspace)
        let root = workspace.appendingPathComponent("exports")
        let entered = expectation(description: "Two active exports")
        entered.expectedFulfillmentCount = 2
        let exporter = AudioExporter(directory: root, stageObserver: { stage in
            if stage == .inspect { entered.fulfill(); try await Task.sleep(for: .seconds(60)) }
        })
        let first = Task { try await exporter.export(track: Self.track, source: Self.audio(source), artwork: nil) }
        let second = Task { try await exporter.export(track: Self.track, source: Self.audio(source), artwork: nil) }
        await fulfillment(of: [entered], timeout: 5)
        do { _ = try await exporter.export(track: Self.track, source: Self.audio(source), artwork: nil); XCTFail("Expected busy") }
        catch { XCTAssertEqual(error as? AudioExportError, .busy) }
        AudioExporter.pruneStaleExports(now: Date().addingTimeInterval(7_200), directory: root)
        XCTAssertEqual(try Self.children(root).count, 2)
        first.cancel(); second.cancel()
        _ = await first.result
        _ = await second.result
        XCTAssertTrue(try Self.children(root).isEmpty)
    }

    func testVerifierRejectsMissingTagsWrongMetadataAndWrongDuration() async throws {
        let workspace = try makeDirectory()
        let source = try await Self.generateAAC(in: workspace)
        do {
            try await NativeAudioExport.verify(source, expected: .init(duration: 2, isAAC: true), track: Self.track, artwork: nil)
            XCTFail("AAC with missing tags must fail readback")
        } catch { XCTAssertEqual(error as? AudioExportError, .failed(stage: .verify, reason: .title)) }
        let result = try await AudioExporter(directory: workspace.appendingPathComponent("exports"))
            .export(track: Self.track, source: Self.audio(source), artwork: nil)
        let wrongTrack = Track(id: "fsiPzT50ZiM", title: "Wrong title", artists: ["Wrong artist"])
        do {
            try await NativeAudioExport.verify(result.url, expected: .init(duration: 2, isAAC: true), track: wrongTrack, artwork: nil)
            XCTFail("Wrong metadata must fail readback")
        } catch { XCTAssertEqual(error as? AudioExportError, .failed(stage: .verify, reason: .title)) }
        do {
            try await NativeAudioExport.verify(result.url, expected: .init(duration: 20, isAAC: true), track: Self.track, artwork: nil)
            XCTFail("A truncated duration must fail validation")
        } catch { XCTAssertEqual(error as? AudioExportError, .failed(stage: .verify, reason: .duration)) }
    }

    func testExportCoverUsesLargeJPEGAndHonoursPixelAndByteBounds() throws {
        let image = Self.image(width: 2_048, height: 1_024)
        let png = try XCTUnwrap(image.pngData())
        let data = try AudioExportArtwork.prepare(png)
        XCTAssertTrue(AudioExportArtwork.isValid(data))
        XCTAssertLessThanOrEqual(data.count, 512 << 10)
        let decoded = try XCTUnwrap(UIImage(data: data)?.cgImage)
        XCTAssertEqual(decoded.width, 1_024)
        XCTAssertEqual(decoded.height, 512)
        XCTAssertEqual(try AudioExportArtwork.prepare(data), data)
        XCTAssertFalse(AudioExportArtwork.isValid(png))
        XCTAssertFalse(AudioExportArtwork.isValid(Data([0xff, 0xd8, 0xff, 0xd9])))
        XCTAssertThrowsError(try AudioExportArtwork.prepare(Data(repeating: 0, count: (12 << 20) + 1)))
    }

    func testFileNamesAreSanitisedAndBoundedInCharactersAndUTF8Bytes() {
        XCTAssertEqual(AudioExporter.fileName(artist: "A/B:C", title: "Song\u{0}Name"), "A B C - Song Name")
        XCTAssertEqual(AudioExporter.fileName(artist: "", title: ""), "Song")
        XCTAssertEqual(AudioExporter.fileName(artist: "", title: ".hidden"), "_hidden")
        let long = AudioExporter.fileName(artist: String(repeating: "a", count: 100), title: String(repeating: "b", count: 100))
        XCTAssertEqual(long.count, AudioExporter.maximumFileNameLength)
        let unicode = AudioExporter.fileName(artist: "", title: String(repeating: "👨‍👩‍👧‍👦", count: 120))
        XCTAssertLessThanOrEqual((unicode + ".m4a").utf8.count, 255)
        XCTAssertFalse(unicode.isEmpty)
    }

    func testPruningRemovesExpiredReleasedExportsButKeepsFreshAndUnrelatedFiles() async throws {
        let workspace = try makeDirectory()
        let source = try await Self.generateAAC(in: workspace)
        let root = workspace.appendingPathComponent("exports")
        let stale = Date().addingTimeInterval(-7_200)
        let exporter = AudioExporter(now: { stale }, directory: root)
        var result: AudioExport? = try await exporter.export(track: Self.track, source: Self.audio(source), artwork: nil)
        let url = try XCTUnwrap(result?.url)
        AudioExporter.pruneStaleExports(directory: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        withExtendedLifetime(result) {}
        result = nil
        let fresh = root.appendingPathComponent("fresh.m4a")
        let unrelated = root.appendingPathComponent("keep.txt")
        try Data([1]).write(to: fresh)
        try Data([2]).write(to: unrelated)
        try FileManager.default.setAttributes([.modificationDate: stale], ofItemAtPath: unrelated.path)
        AudioExporter.pruneStaleExports(directory: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GanaBajanaExportTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private static func children(_ directory: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    }

    private static func audio(_ url: URL, quality: SourceAudioQuality? = nil) -> CachedAudio {
        CachedAudio(trackID: track.id, url: url, duration: 999, loudnessDb: nil, viewCount: nil,
                    bytes: AudioExporter.size(of: url), storedAt: Date(), quality: quality, isDownloaded: true)
    }

    private static func generateAAC(in directory: URL) async throws -> URL {
        let wav = directory.appendingPathComponent("source.wav")
        try PlaybackTestSupport.audioData(seconds: 2).write(to: wav)
        return try await DebugFixtureAudio.exportAAC(from: wav, to: directory.appendingPathComponent("source.m4a")).url
    }

    private static func image(width: Int, height: Int) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: CGFloat(width), height: CGFloat(height)), format: format).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        }
    }

    private static func assertAAC(_ result: AudioExport, duration: Double, artwork: Data? = nil,
                                  file: StaticString = #filePath, line: UInt = #line) async throws {
        XCTAssertTrue(result.tagged, file: file, line: line)
        XCTAssertEqual(result.codec, .aac, file: file, line: line)
        XCTAssertEqual(result.url.pathExtension, "m4a", file: file, line: line)
        XCTAssertGreaterThan(result.bytes, 0, file: file, line: line)
        let asset = AVURLAsset(url: result.url)
        let actualDuration = try await asset.load(.duration).seconds
        XCTAssertEqual(actualDuration, duration, accuracy: 0.15, file: file, line: line)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(tracks.count, 1, file: file, line: line)
        let audio = try XCTUnwrap(tracks.first)
        let formats = try await audio.load(.formatDescriptions)
        XCTAssertFalse(formats.isEmpty, file: file, line: line)
        for format in formats {
            XCTAssertEqual(CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee.mFormatID,
                           kAudioFormatMPEG4AAC, file: file, line: line)
        }
        let metadata = try await asset.load(.metadata)
        for (identifier, expected) in [(AVMetadataIdentifier.iTunesMetadataSongName, track.title),
                                      (.iTunesMetadataArtist, track.artistName), (.iTunesMetadataAlbum, track.albumTitle!)] {
            let item = try XCTUnwrap(AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: identifier).first)
            let value = try await item.load(.stringValue)
            XCTAssertEqual(value, expected, file: file, line: line)
        }
        if let artwork {
            let cover = try XCTUnwrap(AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .iTunesMetadataCoverArt).first)
            let data = try await cover.load(.dataValue)
            XCTAssertEqual(data, artwork, file: file, line: line)
            XCTAssertNotNil(data.flatMap { UIImage(data: $0)?.cgImage }, file: file, line: line)
        }
        let reader = try AVAssetReader(asset: asset)
        defer { reader.cancelReading() }
        let output = AVAssetReaderTrackOutput(track: audio, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false])
        reader.add(output)
        XCTAssertTrue(reader.startReading(), file: file, line: line)
        var seconds: Double = 0
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) == 0 {
                XCTAssertEqual(CMSampleBufferGetTotalSampleSize(sample), 0, file: file, line: line)
                continue
            }
            let format = try XCTUnwrap(CMSampleBufferGetFormatDescription(sample))
            let pcm = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(format)).pointee
            XCTAssertGreaterThan(CMSampleBufferGetTotalSampleSize(sample), 0, file: file, line: line)
            seconds += Double(CMSampleBufferGetNumSamples(sample)) / pcm.mSampleRate
        }
        XCTAssertEqual(reader.status, .completed, file: file, line: line)
        XCTAssertGreaterThan(seconds, 0, file: file, line: line)
        XCTAssertEqual(seconds, duration, accuracy: 0.15, file: file, line: line)
    }

    private struct PacketFingerprint: Equatable, Sendable {
        let sha256: Data
        let byteCount: Int
        let sampleCount: Int
    }

    private static func packetHash(_ url: URL) async throws -> PacketFingerprint {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let reader = try AVAssetReader(asset: asset)
        defer { reader.cancelReading() }
        let output = AVAssetReaderTrackOutput(track: try XCTUnwrap(tracks.first), outputSettings: nil)
        reader.add(output)
        guard reader.startReading() else { throw AudioExportError.exportFailed }
        var hash = SHA256()
        var total = 0
        var samples = 0
        while let sample = output.copyNextSampleBuffer() {
            let count = CMSampleBufferGetNumSamples(sample)
            // Compressed track outputs may also emit zero-sample markers with no CMBlockBuffer.
            if count == 0 {
                XCTAssertEqual(CMSampleBufferGetTotalSampleSize(sample), 0)
                continue
            }
            let description = try XCTUnwrap(CMSampleBufferGetFormatDescription(sample))
            let format = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(description)).pointee
            XCTAssertEqual(format.mFormatID, kAudioFormatMPEG4AAC)
            let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample),
                                     "A nonempty compressed sample must contain packet bytes; samples=\(count)")
            let length = CMBlockBufferGetDataLength(block)
            guard length > 0, length <= 1 << 20 else { throw AudioExportError.exportFailed }
            var bytes = Data(count: length)
            let status = bytes.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
            }
            XCTAssertEqual(status, noErr)
            hash.update(data: bytes)
            total += length
            samples += count
        }
        XCTAssertEqual(reader.status, .completed)
        XCTAssertGreaterThan(total, 0)
        XCTAssertGreaterThan(samples, 0)
        return PacketFingerprint(sha256: Data(hash.finalize()), byteCount: total, sampleCount: samples)
    }
}

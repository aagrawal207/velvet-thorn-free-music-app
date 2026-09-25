#if DEBUG
import AudioToolbox
import AVFoundation
import CryptoKit
import Foundation

enum DebugFixtureAudio {
    static func waveform(in directory: URL) async throws -> URL {
        let work = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("ganabajana-ui-silence.wav")
            if FileManager.default.fileExists(atPath: url.path) { return url }
            let sampleCount: UInt32 = 8_000 * 360
            let bytes = sampleCount * 2
            var data = Data("RIFF".utf8)
            func append<T: FixedWidthInteger>(_ value: T) {
                var little = value.littleEndian
                withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
            }
            append(bytes + 36); data.append(Data("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1))
            append(UInt16(1)); append(UInt32(8_000)); append(UInt32(16_000)); append(UInt16(2)); append(UInt16(16))
            data.append(Data("data".utf8)); append(bytes); data.append(Data(count: Int(bytes)))
            try Task.checkCancellation()
            try data.write(to: url, options: .atomic)
            return url
        }
        return try await withTaskCancellationHandler {
            let url = try await work.value
            try Task.checkCancellation()
            return url
        } onCancel: { work.cancel() }
    }

    static func exportAAC(from input: URL, to output: URL) async throws -> ResolvedStream {
        let asset = AVURLAsset(url: input)
        defer { asset.cancelLoading() }
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw PlaybackStreamError.invalidMedia
        }
        try await exporter.export(to: output, as: .m4a)
        try Task.checkCancellation()
        return try await inspectAAC(output)
    }

    private static func inspectAAC(_ url: URL) async throws -> ResolvedStream {
        let asset = AVURLAsset(url: url)
        defer { asset.cancelLoading() }
        guard try await asset.load(.isPlayable) else { throw PlaybackStreamError.invalidMedia }
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let video = try await asset.loadTracks(withMediaType: .video)
        guard audio.count == 1, video.isEmpty,
              let description = try await audio[0].load(.formatDescriptions).first,
              let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              format.mFormatID == kAudioFormatMPEG4AAC,
              let duration = PlaybackTiming.validDuration(try await asset.load(.duration).seconds) else {
            throw PlaybackStreamError.invalidMedia
        }
        let reader = try AVAssetReader(asset: asset)
        defer { reader.cancelReading() }
        let output = AVAssetReaderTrackOutput(track: audio[0], outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ])
        guard reader.canAdd(output) else { throw PlaybackStreamError.invalidMedia }
        reader.add(output)
        guard reader.startReading(), let sample = output.copyNextSampleBuffer(),
              CMSampleBufferGetNumSamples(sample) > 0, CMSampleBufferGetTotalSampleSize(sample) > 0 else {
            throw PlaybackStreamError.invalidMedia
        }
        let rate = try await audio[0].load(.estimatedDataRate)
        let bitRate = rate.isFinite && (8_000...1_536_000).contains(rate) ? Int(rate.rounded()) : nil
        let quality = SourceAudioQuality(codec: .aac, bitRate: bitRate,
                                         sampleRate: Int(format.mSampleRate), channels: Int(format.mChannelsPerFrame))
        try Task.checkCancellation()
        return ResolvedStream(url: url, duration: duration, quality: quality)
    }

    static func incompatibleOpus(to url: URL) throws -> ResolvedStream {
        guard let data = Data(base64Encoded: opusMP4, options: .ignoreUnknownCharacters),
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined()
                == "9764b9eb061bc8430c1f394a64aaac6b6b10b7b0b7ce5f4b16f13240da6efa18" else {
            throw PlaybackStreamError.invalidMedia
        }
        try data.write(to: url, options: .atomic)
        return ResolvedStream(url: url,
                              quality: SourceAudioQuality(codec: .opus, bitRate: 160_000, sampleRate: 48_000, channels: 2))
    }

    // Packet-copied 120 ms from Tests/Fixtures/opus-160.webm into fragmented MP4, without encoding changes.
    // Embedding this real Opus clip keeps test-bundle paths and fixture resources out of the shipping app.
    private static let opusMP4 = """
    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
    AAAAQw==
    """
}
#endif

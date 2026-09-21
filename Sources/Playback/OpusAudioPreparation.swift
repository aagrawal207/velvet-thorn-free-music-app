import AudioToolbox
import AVFoundation
import FFmpegBridge
import Foundation

enum OpusPreparationError: LocalizedError, Sendable {
    case unsupportedRuntime, invalidOutput, remux(Int32), insufficientSpace

    var errorDescription: String? {
        switch self {
        case .unsupportedRuntime: "This system has not been enabled for Opus playback."
        case .invalidOutput: "The prepared audio could not be verified for native playback."
        case .remux: "The audio container could not be prepared."
        case .insufficientSpace: "There is not enough unused audio cache space to prepare this recording."
        }
    }

    static func diagnosticReason(_ error: any Error) -> String {
        if let error = error as? OpusPreparationError {
            switch error {
            case .unsupportedRuntime: return "runtime"
            case .invalidOutput: return "native_validation"
            case .remux: return "remux"
            case .insufficientSpace: return "cache_budget"
            }
        }
        if case PlaybackStreamError.timedOut = error { return "timeout" }
        return "acquisition"
    }
}

enum OpusRemuxer {
    private static let queue = DispatchQueue(label: "com.agraabhi.ganabajana.opus-remux", qos: .userInitiated)

    static var version: String { String(cString: gb_ffmpeg_version()) }

    static func remux(input: URL, output: URL, timeout: TimeInterval = 10) async throws {
        guard input.isFileURL, output.isFileURL, input != output else { throw OpusPreparationError.invalidOutput }
        let interrupt = RemuxInterrupt(timeout: timeout)
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                queue.async {
                    var ownsOutput = false
                    do {
                        try interrupt.check()
                        guard !FileManager.default.fileExists(atPath: output.path),
                              (try? FileManager.default.destinationOfSymbolicLink(atPath: output.path)) == nil else {
                            throw OpusPreparationError.invalidOutput
                        }
                        ownsOutput = true
                        let status = withExtendedLifetime(interrupt) {
                            input.path.withCString { source in
                                output.path.withCString { destination in
                                    gb_remux_opus(source, destination, { context in
                                        guard let context else { return 1 }
                                        return Unmanaged<RemuxInterrupt>.fromOpaque(context).takeUnretainedValue().shouldStop ? 1 : 0
                                    }, Unmanaged.passUnretained(interrupt).toOpaque())
                                }
                            }
                        }
                        try interrupt.check()
                        guard status == 0 else { throw OpusPreparationError.remux(status) }
                        continuation.resume()
                    } catch {
                        if ownsOutput { try? FileManager.default.removeItem(at: output) }
                        continuation.resume(throwing: error)
                    }
                }
            }
            do { try Task.checkCancellation() }
            catch { try? FileManager.default.removeItem(at: output); throw error }
        } onCancel: { interrupt.cancel() }
    }
}

// C reads the cancellation state concurrently; the dispatch block keeps the callback context alive until C returns.
private final class RemuxInterrupt: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private let deadline: TimeInterval

    init(timeout: TimeInterval) {
        deadline = ProcessInfo.processInfo.systemUptime + (timeout.isFinite ? min(max(timeout, 0), 30) : 10)
    }

    func cancel() { lock.withLock { cancelled = true } }

    var shouldStop: Bool { lock.withLock { cancelled } || ProcessInfo.processInfo.systemUptime >= deadline }

    func check() throws {
        if lock.withLock({ cancelled }) { throw CancellationError() }
        if ProcessInfo.processInfo.systemUptime >= deadline { throw PlaybackStreamError.timedOut }
    }
}

enum OpusNativeAudio {
    struct Inspection: Sendable {
        let duration: TimeInterval
        let sampleRate: Int
        let channels: Int
        let decodedFrames: Int
        let decodedBytes: Int
    }

    static var isSupported: Bool {
        #if os(iOS)
        if #available(iOS 26.5, *) { return true }
        #endif
        return false
    }

    static func prepare(input: URL, output: URL) async throws -> Inspection {
        guard isSupported else { throw OpusPreparationError.unsupportedRuntime }
        try await OpusRemuxer.remux(input: input, output: output)
        return try await inspect(output)
    }

    static func inspect(_ url: URL) async throws -> Inspection {
        guard url.isFileURL else { throw OpusPreparationError.invalidOutput }
        let asset = AVURLAsset(url: url)
        defer { asset.cancelLoading() }
        let work = Task.detached {
            try Task.checkCancellation()
            guard try await asset.load(.isPlayable) else { throw OpusPreparationError.invalidOutput }
            let audio = try await asset.loadTracks(withMediaType: .audio)
            let video = try await asset.loadTracks(withMediaType: .video)
            guard audio.count == 1, video.isEmpty else { throw OpusPreparationError.invalidOutput }
            let descriptions = try await audio[0].load(.formatDescriptions)
            guard !descriptions.isEmpty else { throw OpusPreparationError.invalidOutput }
            var channels: UInt32 = 0
            for description in descriptions {
                guard let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
                      format.mFormatID == kAudioFormatOpus, format.mSampleRate == 48_000,
                      (1...2).contains(format.mChannelsPerFrame), channels == 0 || channels == format.mChannelsPerFrame else {
                    throw OpusPreparationError.invalidOutput
                }
                channels = format.mChannelsPerFrame
            }
            guard let duration = PlaybackTiming.validDuration(try await asset.load(.duration).seconds) else {
                throw OpusPreparationError.invalidOutput
            }
            try Task.checkCancellation()
            let reader = try AVAssetReader(asset: asset)
            defer { reader.cancelReading() }
            // Actual PCM output verifies the system decoder, independently of isPlayable and container metadata.
            let output = AVAssetReaderTrackOutput(track: audio[0], outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            ])
            guard reader.canAdd(output) else { throw OpusPreparationError.invalidOutput }
            reader.add(output)
            guard reader.startReading(), let sample = output.copyNextSampleBuffer(),
                  let description = CMSampleBufferGetFormatDescription(sample),
                  let pcm = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
                  pcm.mFormatID == kAudioFormatLinearPCM, pcm.mSampleRate == 48_000, pcm.mChannelsPerFrame == channels,
                  CMSampleBufferGetNumSamples(sample) > 0, CMSampleBufferGetTotalSampleSize(sample) > 0 else {
                throw OpusPreparationError.invalidOutput
            }
            try Task.checkCancellation()
            return Inspection(duration: duration, sampleRate: 48_000, channels: Int(channels),
                decodedFrames: CMSampleBufferGetNumSamples(sample), decodedBytes: CMSampleBufferGetTotalSampleSize(sample))
        }
        // The cache owns the deadline and keeps the files until this reader has actually unwound.
        return try await withTaskCancellationHandler {
            do {
                let result = try await work.value
                try Task.checkCancellation()
                return result
            } catch {
                try Task.checkCancellation()
                throw error
            }
        } onCancel: {
            work.cancel()
            asset.cancelLoading()
        }
    }
}

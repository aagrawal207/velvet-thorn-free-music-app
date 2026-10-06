import AudioToolbox
import AVFoundation

enum AudioExportPCM {
    // Marker buffers have no PCM payload; a nonzero frame count must never take this path.
    static func isMarker(_ sample: CMSampleBuffer) throws -> Bool {
        guard CMSampleBufferIsValid(sample) else { throw AudioExportError.failed(stage: .verify, reason: .pcmPayload) }
        guard CMSampleBufferGetNumSamples(sample) == 0 else { return false }
        guard CMSampleBufferGetTotalSampleSize(sample) == 0,
              CMSampleBufferGetDataBuffer(sample).map({ CMBlockBufferGetDataLength($0) == 0 }) ?? true else {
            throw AudioExportError.failed(stage: .verify, reason: .pcmPayload)
        }
        return true
    }

    static func playableRange(_ sample: CMSampleBuffer) throws -> CMTimeRange? {
        if try isMarker(sample) { return nil }
        guard let description = CMSampleBufferGetFormatDescription(sample),
              let pcm = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              pcm.mFormatID == kAudioFormatLinearPCM, pcm.mSampleRate.isFinite, pcm.mSampleRate > 0,
              pcm.mBytesPerFrame > 0, CMSampleBufferDataIsReady(sample),
              CMSampleBufferGetNumSamples(sample) > 0,
              Int64(CMSampleBufferGetTotalSampleSize(sample)) == Int64(CMSampleBufferGetNumSamples(sample)) * Int64(pcm.mBytesPerFrame),
              let block = CMSampleBufferGetDataBuffer(sample),
              CMBlockBufferGetDataLength(block) >= CMSampleBufferGetTotalSampleSize(sample) else {
            throw AudioExportError.failed(stage: .verify, reason: .pcmPayload)
        }
        let start = CMSampleBufferGetOutputPresentationTimeStamp(sample)
        let duration = CMSampleBufferGetOutputDuration(sample)
        let raw = CMSampleBufferGetDuration(sample)
        let framesDuration = Double(CMSampleBufferGetNumSamples(sample)) / pcm.mSampleRate
        let speed = (CMGetAttachment(sample, key: kCMSampleBufferAttachmentKey_SpeedMultiplier,
                                     attachmentModeOut: nil) as? NSNumber)?.doubleValue ?? 1
        // OutputDuration already subtracts both trims and applies the edit speed. Do not trim it twice.
        guard start.isNumeric, duration.isNumeric, duration >= .zero, raw.isNumeric,
              speed.isFinite, speed > 0,
              abs(raw.seconds - framesDuration) <= 1 / pcm.mSampleRate,
              duration.seconds * speed <= framesDuration + 1 / pcm.mSampleRate else {
            throw AudioExportError.failed(stage: .verify, reason: .pcmTiming)
        }
        return CMTimeRange(start: start, duration: duration)
    }

    struct Coverage {
        let ranges: [CMTimeRange]
        private(set) var seconds = 0.0
        private var lastEnd: CMTime?

        init(ranges: [CMTimeRange]) { self.ranges = ranges }

        mutating func append(_ sample: CMSampleBuffer) throws {
            guard let playable = try playableRange(sample), playable.duration > .zero else { return }
            let format = CMSampleBufferGetFormatDescription(sample)!
            let rate = CMAudioFormatDescriptionGetStreamBasicDescription(format)!.pointee.mSampleRate
            if let lastEnd, playable.start.seconds < lastEnd.seconds - 1 / rate {
                throw AudioExportError.failed(stage: .verify, reason: .pcmTiming)
            }
            lastEnd = playable.end
            for range in ranges {
                let intersection = CMTimeRangeGetIntersection(playable, otherRange: range)
                if intersection.isValid, intersection.duration > .zero { seconds += intersection.duration.seconds }
            }
        }

        func requireComplete(tolerance: Double) throws {
            let expected = ranges.reduce(0) { $0 + $1.duration.seconds }
            guard expected.isFinite, expected > 0, seconds > 0, seconds >= expected * 0.8,
                  abs(seconds - expected) <= tolerance else {
                throw AudioExportError.failed(stage: .verify, reason: .pcmDuration)
            }
        }
    }

    static func mediaRanges(for audio: AVAssetTrack, duration: CMTime) async throws -> [CMTimeRange] {
        let window = CMTimeRange(start: .zero, duration: duration)
        let segments = try await audio.load(.segments)
        let ranges: [CMTimeRange]
        if segments.isEmpty { ranges = [try await audio.load(.timeRange)] }
        else { ranges = segments.filter { !$0.isEmpty }.map(\.timeMapping.target) }
        let clipped = ranges.map { CMTimeRangeGetIntersection($0, otherRange: window) }
            .filter { $0.isValid && $0.duration.isNumeric && $0.duration > .zero }
            .sorted { $0.start < $1.start }
        guard !clipped.isEmpty else { throw AudioExportError.failed(stage: .verify, reason: .pcmDuration) }
        for pair in zip(clipped, clipped.dropFirst()) where pair.0.end > pair.1.start {
            throw AudioExportError.failed(stage: .verify, reason: .pcmTiming)
        }
        return clipped
    }
}

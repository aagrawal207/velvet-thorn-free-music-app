import AVFoundation
#if targetEnvironment(macCatalyst)
// The audio buffer list pointer overlay only arrives through AVFoundation on iOS.
import CoreAudio
#endif
import Foundation
import MediaToolbox
import OSLog
import Synchronization

/// One item's shared EQ and gain-up tap. Render adopts a nonblocking snapshot and otherwise keeps its last targets.
/// The tap serializes prepare, unprepare and process, the only users of the DSP state.
final class EqualizerProcessor: @unchecked Sendable {
    /// SIMD storage keeps the snapshot free of heap references so copying it on the audio thread allocates nothing.
    struct Targets: Sendable {
        var gains = SIMD16<Double>()
        var preampDb: Double = 0
        var isEnabled = false
        var normalizationGainDb: Double = 0
        var revision: UInt64 = 0

        init() { }

        init(_ settings: EqualizerSettings, revision: UInt64) {
            for (index, gain) in settings.effectiveGains.prefix(16).enumerated() { gains[index] = gain }
            preampDb = settings.resolvedPreamp
            isEnabled = settings.isEnabled
            self.revision = revision
        }
    }

    enum BypassReason: String, Sendable {
        case format, noAudioTrack = "no_audio_track", assetType = "asset_type", tapCreate = "tap_create",
             tracksFailed = "tracks_failed", itemReleased = "item_released", existingMix = "existing_mix"
    }

    /// Frames processed by EQ or gain-up; pure pass-through leaves this unchanged.
    let processedFrames = Atomic<Int>(0)
    let preparedChannels = Atomic<Int>(0)
    let formatBypassed = Atomic<Bool>(false)
    let normalizationFrames = Atomic<Int>(0)
    let limiterClips = Atomic<Int>(0)
    let invalidSamples = Atomic<Int>(0)
    let lastInputRMS = Atomic<Double>(0)
    let lastOutputRMS = Atomic<Double>(0)
    let renderedNormalizationGainDb = Atomic<Double>(0)

    private let targets: Mutex<Targets>
    private var audioTargets: Targets
    private var appliedRevision: UInt64 = .max
    private var bank: BiquadBank?
    private var gainLimiter: GainLimiter?
    private var channelStarts: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>?
    private var channelCapacity = 0
    private var interleaved = true
    private var formatSupported = false
    private var passingThrough = true
    /// Frames still to filter after a disable so the flat filters drain their state before the pure pass-through.
    private var passThroughTailFrames = 0
    private var settlingToPassThrough = false
    private let meter: PlaybackLevelMeter?
    private var meterState = AudioLevelMeter.State()
    private let log = Logger(subsystem: "com.agraabhi.ganabajana", category: "Equalizer")

    init(settings: EqualizerSettings = EqualizerSettings(), revision: UInt64 = 0, meter: PlaybackLevelMeter? = nil) {
        let initial = Targets(settings, revision: revision)
        targets = Mutex(initial)
        audioTargets = initial
        self.meter = meter
    }

    deinit {
        channelStarts?.deallocate()
    }

    func apply(_ settings: EqualizerSettings, revision: UInt64) {
        var next = Targets(settings, revision: revision)
        targets.withLock {
            next.normalizationGainDb = $0.normalizationGainDb
            next.revision = $0.revision &+ 1
            $0 = next
        }
    }

    /// Accepts the total requested linear gain; attenuation belongs exclusively to AVPlayer.volume.
    func setNormalizationGain(_ gain: Double) {
        let boost = gain.isFinite && gain > 1 ? min(GainLimiter.maximumGainDb, 20 * log10(gain)) : 0
        targets.withLock {
            guard $0.normalizationGainDb != boost else { return }
            $0.normalizationGainDb = boost
            $0.revision &+= 1
        }
    }

    /// Creates the tap that retains this processor until AVFoundation finalizes it.
    func makeTap() -> MTAudioProcessingTap? {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passRetained(self).toOpaque(),
            init: { _, clientInfo, storageOut in storageOut.pointee = clientInfo },
            finalize: { tap in Unmanaged<EqualizerProcessor>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release() },
            prepare: { tap, maxFrames, format in
                EqualizerProcessor.owner(of: tap).prepare(maxFrames: Int(maxFrames), format: format.pointee)
            },
            unprepare: { tap in EqualizerProcessor.owner(of: tap).unprepare() },
            process: { tap, frames, _, bufferList, framesOut, flagsOut in
                EqualizerProcessor.owner(of: tap).process(tap: tap, frames: frames, bufferList: bufferList,
                                                          framesOut: framesOut, flagsOut: flagsOut)
            })
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                                MTAudioProcessingTapCreationFlags(kMTAudioProcessingTapCreationFlag_PostEffects), &tap)
        guard status == noErr, let tap else {
            // Creation failed before the init callback could take ownership, so balance the retain here.
            Unmanaged.passUnretained(self).release()
            log.notice("event=equalizer_bypass reason=\(BypassReason.tapCreate.rawValue, privacy: .public)")
            return nil
        }
        return tap
    }

    private static func owner(of tap: MTAudioProcessingTap) -> EqualizerProcessor {
        Unmanaged<EqualizerProcessor>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    }

    // MARK: - Tap callbacks

    func prepare(maxFrames: Int, format: AudioStreamBasicDescription) {
        let isFloat32 = format.mFormatID == kAudioFormatLinearPCM
            && format.mFormatFlags & kAudioFormatFlagIsFloat != 0 && format.mBitsPerChannel == 32
        let channels = Int(format.mChannelsPerFrame)
        interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let bytesPerFrame = MemoryLayout<Float>.size * (interleaved ? channels : 1)
        formatSupported = isFloat32 && (1...8).contains(channels)
            && format.mSampleRate.isFinite && (8_000...192_000).contains(format.mSampleRate)
            && Int(format.mBytesPerFrame) == bytesPerFrame
            && format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0
        preparedChannels.store(0, ordering: .relaxed)
        renderedNormalizationGainDb.store(0, ordering: .relaxed)
        formatBypassed.store(!formatSupported, ordering: .relaxed)
        guard formatSupported else {
            bank = nil
            gainLimiter = nil
            return
        }
        if channelCapacity < channels {
            channelStarts?.deallocate()
            channelStarts = .allocate(capacity: channels)
            channelStarts?.initialize(repeating: nil, count: channels)
            channelCapacity = channels
        }
        let bank = BiquadBank(sampleRate: format.mSampleRate, channels: channels)
        meterState = AudioLevelMeter.State()
        gainLimiter = GainLimiter(sampleRate: format.mSampleRate)
        // The first buffer already carries the live curve; ramping in from flat would fade the start of the song.
        if let snapshot = targets.withLockIfAvailable({ $0 }) { audioTargets = snapshot }
        let snapshot = audioTargets
        appliedRevision = snapshot.revision
        adopt(snapshot, into: bank, immediate: true)
        self.bank = bank
        preparedChannels.store(channels, ordering: .relaxed)
    }

    func unprepare() {
        bank = nil
        gainLimiter = nil
        preparedChannels.store(0, ordering: .relaxed)
        renderedNormalizationGainDb.store(0, ordering: .relaxed)
    }

    private func process(tap: MTAudioProcessingTap, frames: CMItemCount, bufferList: UnsafeMutablePointer<AudioBufferList>,
                         framesOut: UnsafeMutablePointer<CMItemCount>, flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>) {
        framesOut.pointee = 0
        let status = MTAudioProcessingTapGetSourceAudio(tap, frames, bufferList, flagsOut, nil, framesOut)
        guard status == noErr else { framesOut.pointee = 0; return }
        guard formatSupported else { return }
        render(frames: Int(framesOut.pointee), bufferList: UnsafeMutableAudioBufferListPointer(bufferList))
    }

    /// Filters the source audio in place; the tap callback and unit tests both come through here.
    func render(frames: Int, bufferList: UnsafeMutableAudioBufferListPointer) {
        guard frames > 0, let bank, let gainLimiter, let channelStarts else { return }
        if let snapshot = targets.withLockIfAvailable({ $0 }), snapshot.revision != appliedRevision {
            audioTargets = snapshot
            appliedRevision = snapshot.revision
            adopt(snapshot, into: bank, immediate: false)
        }
        let processes = !passingThrough || gainLimiter.isActive
        let meters = meter?.isEnabled == true
        guard processes || meters else { return }
        let channels = bank.channels
        let stride: Int
        if interleaved {
            guard bufferList.count == 1, let base = bufferList[0].mData,
                  Int(bufferList[0].mNumberChannels) == channels,
                  frames <= Int(bufferList[0].mDataByteSize) / (channels * MemoryLayout<Float>.size) else { return }
            let pointer = base.assumingMemoryBound(to: Float.self)
            for channel in 0..<channels { channelStarts[channel] = pointer + channel }
            stride = channels
        } else {
            guard bufferList.count == channels else { return }
            for channel in 0..<channels {
                let buffer = bufferList[channel]
                guard buffer.mNumberChannels == 1, let data = buffer.mData,
                      frames <= Int(buffer.mDataByteSize) / MemoryLayout<Float>.size else { return }
                channelStarts[channel] = data.assumingMemoryBound(to: Float.self)
            }
            stride = 1
        }
        // Metering alone only reads the buffer, so a measuring-only tap stays bit-transparent.
        guard processes else { return measure(frames: frames, channels: channels, sampleRate: bank.sampleRate) }
        if !passingThrough { bank.process(frames: frames, channelStarts: UnsafePointer(channelStarts), stride: stride) }
        let gainWasActive = gainLimiter.currentGainDb != 0 || gainLimiter.targetGainDb != 0
        let measurement = gainLimiter.process(frames: frames, channels: channels, channelStarts: UnsafePointer(channelStarts), stride: stride)
        if gainWasActive { normalizationFrames.wrappingAdd(frames, ordering: .relaxed) }
        limiterClips.wrappingAdd(measurement.limitedFrames, ordering: .relaxed)
        invalidSamples.wrappingAdd(measurement.invalidSamples, ordering: .relaxed)
        let count = Double(frames) * Double(channels)
        lastInputRMS.store(sqrt(measurement.inputEnergy / count), ordering: .relaxed)
        lastOutputRMS.store(sqrt(measurement.outputEnergy / count), ordering: .relaxed)
        renderedNormalizationGainDb.store(gainLimiter.currentGainDb, ordering: .relaxed)
        processedFrames.wrappingAdd(frames, ordering: .relaxed)
        if settlingToPassThrough, bank.isFlatAndSettled {
            passThroughTailFrames -= frames
            if passThroughTailFrames <= 0 {
                settlingToPassThrough = false
                passingThrough = true
                bank.resetState()
            }
        }
        if meters { measure(frames: frames, channels: channels, sampleRate: bank.sampleRate) }
    }

    /// Reads the processed buffer through `channelStarts`; no allocation, lock or logging.
    private func measure(frames: Int, channels: Int, sampleRate: Double) {
        guard let meter, let channelStarts, sampleRate > 0 else { return }
        var sum: Float = 0
        var count = 0
        if interleaved {
            guard let base = channelStarts[0] else { return }
            let totals = AudioLevelMeter.sumOfSquares(UnsafeBufferPointer(start: base, count: frames * channels))
            sum = totals.sum
            count = totals.count
        } else {
            for channel in 0..<channels {
                guard let start = channelStarts[channel] else { continue }
                let totals = AudioLevelMeter.sumOfSquares(UnsafeBufferPointer(start: start, count: frames))
                sum += totals.sum
                count += totals.count
            }
        }
        meterState = AudioLevelMeter.advance(meterState, meanSquare: count > 0 ? sum / Float(count) : 0,
                                             seconds: Float(Double(frames) / sampleRate))
        meter.publish(meterState)
    }

    /// Disabling ramps to flat and keeps filtering for 50 ms so the state drains, then stops touching the buffers.
    private func adopt(_ snapshot: Targets, into bank: BiquadBank, immediate: Bool) {
        // A newly installed tap may already be audible, so normalization starts with the same ramp as live edits.
        gainLimiter?.setGainDb(snapshot.normalizationGainDb)
        if snapshot.isEnabled {
            bank.setTargets(preampDb: snapshot.preampDb, immediate: immediate) { $0 < 16 ? snapshot.gains[$0] : 0 }
            passingThrough = false
            settlingToPassThrough = false
        } else if immediate || passingThrough {
            bank.setTargets(preampDb: 0, immediate: true) { _ in 0 }
            passingThrough = true
            settlingToPassThrough = false
        } else {
            bank.setTargets(preampDb: 0, immediate: false) { _ in 0 }
            settlingToPassThrough = true
            passThroughTailFrames = Int(bank.sampleRate * 0.05)
        }
    }
}

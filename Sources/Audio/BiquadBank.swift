import Foundation

/// Second-order section normalized by a0 (RBJ Audio EQ Cookbook).
struct BiquadCoefficients: Equatable, Sendable {
    var b0: Double = 1
    var b1: Double = 0
    var b2: Double = 0
    var a1: Double = 0
    var a2: Double = 0

    static let identity = BiquadCoefficients()

    /// Peaking EQ. Bands at or above 45% of the sample rate cannot be represented and become identity so a low-rate
    /// file (8 kHz fixtures, 22 kHz voice recordings) keeps its audible bands instead of an unstable filter.
    static func peaking(frequency: Double, sampleRate: Double, gainDb: Double, q: Double) -> BiquadCoefficients {
        guard sampleRate > 0, frequency > 0, frequency < sampleRate * 0.45, q > 0, gainDb.isFinite else { return .identity }
        let amplitude = pow(10, gainDb / 40)
        let omega = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(omega) / (2 * q)
        let cosine = cos(omega)
        let a0 = 1 + alpha / amplitude
        return BiquadCoefficients(b0: (1 + alpha * amplitude) / a0, b1: -2 * cosine / a0, b2: (1 - alpha * amplitude) / a0,
                                  a1: -2 * cosine / a0, a2: (1 - alpha / amplitude) / a0)
    }

    /// |H(e^jw)| for w = 2π frequency / sampleRate.
    func magnitude(frequency: Double, sampleRate: Double) -> Double {
        let omega = 2 * Double.pi * frequency / sampleRate
        let cos1 = cos(omega), sin1 = sin(omega), cos2 = cos(2 * omega), sin2 = sin(2 * omega)
        let numeratorReal = b0 + b1 * cos1 + b2 * cos2
        let numeratorImaginary = -(b1 * sin1 + b2 * sin2)
        let denominatorReal = 1 + a1 * cos1 + a2 * cos2
        let denominatorImaginary = -(a1 * sin1 + a2 * sin2)
        let numerator = (numeratorReal * numeratorReal + numeratorImaginary * numeratorImaginary).squareRoot()
        let denominator = (denominatorReal * denominatorReal + denominatorImaginary * denominatorImaginary).squareRoot()
        guard denominator > 0 else { return 0 }
        return numerator / denominator
    }
}

/// Peaking-filter cascade with a preamp in front; gains ramp in dB every 32 frames so a change never steps audibly.
/// Storage is allocated once in `init` so `process` can run on the audio thread; the owner serializes `setTargets`.
final class BiquadBank {
    static let defaultQ = 1.41
    static let subBlockFrames = 32

    let sampleRate: Double
    let channels: Int
    let frequencies: [Double]
    let q: Double
    let smoothingSeconds: Double

    private let bands: Int
    private let coefficients: UnsafeMutablePointer<BiquadCoefficients>
    /// Transposed direct form II state, two doubles per channel per band.
    private let state: UnsafeMutablePointer<Double>
    private let currentDb: UnsafeMutablePointer<Double>
    private let targetDb: UnsafeMutablePointer<Double>
    private let stepDb: UnsafeMutablePointer<Double>
    private var currentPreampDb: Double = 0
    private var targetPreampDb: Double = 0
    private var stepPreampDb: Double = 0
    private var preampLinear: Double = 1
    private var rampFramesRemaining = 0
    private var rampFramesTotal: Int

    init(sampleRate: Double, channels: Int, frequencies: [Double] = EqualizerPreset.bandFrequencies,
         q: Double = BiquadBank.defaultQ, smoothingSeconds: Double = 0.02) {
        self.sampleRate = max(1, sampleRate)
        self.channels = max(1, channels)
        self.frequencies = frequencies
        self.q = q
        self.smoothingSeconds = smoothingSeconds
        bands = frequencies.count
        rampFramesTotal = max(1, Int((smoothingSeconds * self.sampleRate).rounded()))
        coefficients = .allocate(capacity: max(1, bands))
        coefficients.initialize(repeating: .identity, count: max(1, bands))
        state = .allocate(capacity: max(1, self.channels * bands * 2))
        state.initialize(repeating: 0, count: max(1, self.channels * bands * 2))
        currentDb = .allocate(capacity: max(1, bands))
        currentDb.initialize(repeating: 0, count: max(1, bands))
        targetDb = .allocate(capacity: max(1, bands))
        targetDb.initialize(repeating: 0, count: max(1, bands))
        stepDb = .allocate(capacity: max(1, bands))
        stepDb.initialize(repeating: 0, count: max(1, bands))
    }

    deinit {
        coefficients.deallocate()
        state.deallocate()
        currentDb.deallocate()
        targetDb.deallocate()
        stepDb.deallocate()
    }

    var isRamping: Bool { rampFramesRemaining > 0 }

    var currentGainsDb: [Double] { (0..<bands).map { currentDb[$0] } }
    var targetGainsDb: [Double] { (0..<bands).map { targetDb[$0] } }
    var currentPreamp: Double { currentPreampDb }

    /// True once every band and the preamp sit at 0 dB with no ramp pending; the filters are then exact identities.
    var isFlatAndSettled: Bool {
        guard rampFramesRemaining == 0, targetPreampDb == 0 else { return false }
        for band in 0..<bands where targetDb[band] != 0 { return false }
        return true
    }

    /// Starts a ramp from the current values. Missing bands read as 0 dB, extra values are ignored.
    func setTargets(gainsDb: [Double], preampDb: Double, immediate: Bool = false) {
        setTargets(preampDb: preampDb, immediate: immediate) { $0 < gainsDb.count ? gainsDb[$0] : 0 }
    }

    /// Allocation-free form for the audio thread: `gain` supplies each band's target in dB.
    func setTargets(preampDb: Double, immediate: Bool, gain: (Int) -> Double) {
        for band in 0..<bands {
            let value = gain(band)
            targetDb[band] = value.isFinite ? value : 0
        }
        targetPreampDb = preampDb.isFinite ? preampDb : 0
        if immediate {
            snapToTargets()
            return
        }
        rampFramesRemaining = rampFramesTotal
        let frames = Double(rampFramesTotal)
        for band in 0..<bands { stepDb[band] = (targetDb[band] - currentDb[band]) / frames }
        stepPreampDb = (targetPreampDb - currentPreampDb) / frames
    }

    func snapToTargets() {
        rampFramesRemaining = 0
        for band in 0..<bands {
            currentDb[band] = targetDb[band]
            stepDb[band] = 0
        }
        currentPreampDb = targetPreampDb
        stepPreampDb = 0
        refreshCoefficients()
    }

    func resetState() {
        state.update(repeating: 0, count: max(1, channels * bands * 2))
    }

    /// Filters `frames` frames in place. Channel `c` starts at `channelStarts[c]`; consecutive frames of one channel
    /// are `stride` samples apart (1 for planar buffers, the channel count for interleaved ones).
    func process(frames: Int, channelStarts: UnsafePointer<UnsafeMutablePointer<Float>?>, stride: Int) {
        guard frames > 0, bands > 0 else { return }
        var offset = 0
        while offset < frames {
            let count = min(Self.subBlockFrames, frames - offset)
            advanceRamp(frames: count)
            for channel in 0..<channels {
                guard let start = channelStarts[channel] else { continue }
                processChannel(channel, samples: start + offset * stride, count: count, stride: stride)
            }
            offset += count
        }
    }

    /// Convenience for tests and offline measurement: frames interleaved across `channels`.
    func process(interleaved samples: inout [Float]) {
        let frames = samples.count / channels
        guard frames > 0 else { return }
        samples.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            let starts: [UnsafeMutablePointer<Float>?] = (0..<channels).map { base + $0 }
            starts.withUnsafeBufferPointer { process(frames: frames, channelStarts: $0.baseAddress!, stride: channels) }
        }
    }

    /// Convenience for tests: one buffer per channel, all the same length.
    func process(planar buffers: inout [[Float]]) {
        guard let frames = buffers.first?.count, frames > 0 else { return }
        var interleaved = [Float](repeating: 0, count: frames * channels)
        for channel in 0..<min(channels, buffers.count) {
            for frame in 0..<frames { interleaved[frame * channels + channel] = buffers[channel][frame] }
        }
        process(interleaved: &interleaved)
        for channel in 0..<min(channels, buffers.count) {
            for frame in 0..<frames { buffers[channel][frame] = interleaved[frame * channels + channel] }
        }
    }

    /// Combined magnitude of all bands and the current preamp target, in dB.
    func magnitudeDb(at frequency: Double) -> Double {
        var magnitude = pow(10, targetPreampDb / 20)
        for band in 0..<bands {
            let target = BiquadCoefficients.peaking(frequency: frequencies[band], sampleRate: sampleRate, gainDb: targetDb[band], q: q)
            magnitude *= target.magnitude(frequency: frequency, sampleRate: sampleRate)
        }
        return magnitude > 0 ? 20 * log10(magnitude) : -160
    }

    /// Band-only response for a curve preview at a nominal rate; independent of any live instance.
    static func responseDb(gainsDb: [Double], at frequency: Double, sampleRate: Double = 48_000,
                           frequencies: [Double] = EqualizerPreset.bandFrequencies, q: Double = BiquadBank.defaultQ) -> Double {
        var magnitude = 1.0
        for (index, center) in frequencies.enumerated() {
            let gain = index < gainsDb.count ? gainsDb[index] : 0
            magnitude *= BiquadCoefficients.peaking(frequency: center, sampleRate: sampleRate, gainDb: gain, q: q)
                .magnitude(frequency: frequency, sampleRate: sampleRate)
        }
        return magnitude > 0 ? 20 * log10(magnitude) : -160
    }

    private func advanceRamp(frames: Int) {
        guard rampFramesRemaining > 0 else { return }
        let advanced = min(frames, rampFramesRemaining)
        rampFramesRemaining -= advanced
        if rampFramesRemaining == 0 {
            snapToTargets()
            return
        }
        let scale = Double(advanced)
        for band in 0..<bands { currentDb[band] += stepDb[band] * scale }
        currentPreampDb += stepPreampDb * scale
        refreshCoefficients()
    }

    private func refreshCoefficients() {
        for band in 0..<bands {
            coefficients[band] = BiquadCoefficients.peaking(frequency: frequencies[band], sampleRate: sampleRate,
                                                            gainDb: currentDb[band], q: q)
        }
        preampLinear = pow(10, currentPreampDb / 20)
    }

    private func processChannel(_ channel: Int, samples: UnsafeMutablePointer<Float>, count: Int, stride: Int) {
        let channelState = state + channel * bands * 2
        let gain = preampLinear
        var pointer = samples
        for _ in 0..<count {
            var value = pointer.pointee.isFinite ? Double(pointer.pointee) * gain : 0
            for band in 0..<bands {
                let c = coefficients[band]
                let s1 = channelState[band * 2]
                let s2 = channelState[band * 2 + 1]
                let output = c.b0 * value + s1
                let next1 = c.b1 * value - c.a1 * output + s2
                let next2 = c.b2 * value - c.a2 * output
                if output.isFinite, next1.isFinite, next2.isFinite {
                    channelState[band * 2] = next1
                    channelState[band * 2 + 1] = next2
                    value = output
                } else {
                    channelState[band * 2] = 0
                    channelState[band * 2 + 1] = 0
                    value = 0
                }
            }
            pointer.pointee = Float(value)
            pointer += stride
        }
    }
}

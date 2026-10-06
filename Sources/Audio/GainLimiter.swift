import Foundation

/// Per-item gain and sample-peak protection after EQ. One envelope links every channel in a frame.
/// The tap serializes access; processing uses caller-owned buffers and no heap storage or locks.
final class GainLimiter {
    static let maximumGainDb = 6.0
    static let ceiling = 0.98

    struct Measurement {
        var limitedFrames = 0
        var invalidSamples = 0
        var inputEnergy = 0.0
        var outputEnergy = 0.0
    }

    private(set) var currentGainDb = 0.0
    private(set) var targetGainDb = 0.0
    private(set) var reduction = 1.0
    private var remaining = 0
    private var step = 0.0
    private var linearGain = 1.0
    private var linearStep = 1.0
    private var targetLinearGain = 1.0
    private let rampFrames: Int
    private let releaseCoefficient: Double

    init(sampleRate: Double) {
        let rate = sampleRate.isFinite ? min(192_000, max(8_000, sampleRate)) : 48_000
        rampFrames = Int(rate * 0.02)
        releaseCoefficient = exp(-1 / (rate * 0.1))
    }

    var isActive: Bool { currentGainDb != 0 || remaining > 0 || reduction < 1 }

    func setGainDb(_ value: Double, immediate: Bool = false) {
        let target = value.isFinite ? min(Self.maximumGainDb, max(-60, value)) : 0
        guard target != targetGainDb || immediate else { return }
        targetGainDb = target
        targetLinearGain = pow(10, target / 20)
        if immediate {
            currentGainDb = target
            linearGain = targetLinearGain
            remaining = 0
        } else {
            remaining = rampFrames
            step = (target - currentGainDb) / Double(rampFrames)
            linearStep = pow(10, step / 20)
        }
    }

    @discardableResult
    func process(frames: Int, channels: Int, channelStarts: UnsafePointer<UnsafeMutablePointer<Float>?>,
                 stride: Int) -> Measurement {
        var measurement = Measurement()
        guard frames > 0, channels > 0, stride > 0 else { return measurement }
        for frame in 0..<frames {
            if remaining > 0 {
                remaining -= 1
                currentGainDb = remaining == 0 ? targetGainDb : currentGainDb + step
                linearGain = remaining == 0 ? targetLinearGain : linearGain * linearStep
            }
            let gain = linearGain
            var peak = 0.0
            for channel in 0..<channels {
                guard let sample = channelStarts[channel]?.advanced(by: frame * stride) else { continue }
                if !sample.pointee.isFinite {
                    sample.pointee = 0
                    measurement.invalidSamples += 1
                }
                let input = Double(sample.pointee)
                measurement.inputEnergy += input * input
                peak = max(peak, abs(input * gain))
            }
            let required = peak > Self.ceiling ? Self.ceiling / peak : 1
            // Instant attack bounds this very frame; a 100 ms release avoids pumping between nearby peaks.
            reduction = min(required, 1 - (1 - reduction) * releaseCoefficient)
            if required == 1, reduction > 0.999_999 { reduction = 1 }
            if reduction < 1 { measurement.limitedFrames += 1 }
            for channel in 0..<channels {
                guard let sample = channelStarts[channel]?.advanced(by: frame * stride) else { continue }
                let output = Double(sample.pointee) * gain * reduction
                sample.pointee = Float(min(Self.ceiling, max(-Self.ceiling, output)))
                measurement.outputEnergy += Double(sample.pointee) * Double(sample.pointee)
            }
        }
        return measurement
    }
}

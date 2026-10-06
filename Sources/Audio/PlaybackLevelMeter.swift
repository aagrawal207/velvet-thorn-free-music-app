import Foundation
import Synchronization

/// Audio-thread math for the player's React to Music backdrop. Pure and allocation-free so the tap render
/// path can call it on every buffer.
enum AudioLevelMeter {
    struct State: Equatable, Sendable {
        /// Smoothed loudness mapped to 0...1 over `floorDb...ceilingDb`.
        var level: Float = 0
        /// Attack/release-smoothed mean square.
        var fastEnergy: Float = 0
        /// Slow mean square; an onset is a buffer well above it.
        var slowEnergy: Float = 0
        /// 1 on an onset, decaying towards 0.
        var beat: Float = 0
    }

    static let floorDb: Float = -48
    static let ceilingDb: Float = -6
    static let attackSeconds: Float = 0.03
    static let releaseSeconds: Float = 0.25
    static let slowSeconds: Float = 1.2
    static let beatDecaySeconds: Float = 0.18
    /// Energy ratio over the slow average that counts as an onset (about +2 dB).
    static let onsetRatio: Float = 1.6
    /// Mean square below -40 dBFS never counts as an onset, so a fade-in from silence is not a beat storm.
    static let onsetFloor: Float = 1e-4

    /// Sum of squares over finite samples; NaN and infinity are skipped rather than poisoning the level.
    static func sumOfSquares(_ samples: UnsafeBufferPointer<Float>) -> (sum: Float, count: Int) {
        var sum: Float = 0
        var count = 0
        for sample in samples where sample.isFinite {
            sum += sample * sample
            count += 1
        }
        return (sum, count)
    }

    static func normalizedLevel(rms: Float) -> Float {
        guard rms.isFinite, rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        return min(1, max(0, (db - floorDb) / (ceilingDb - floorDb)))
    }

    /// Advances the meter by one buffer of `seconds` duration whose mean square is `meanSquare`.
    static func advance(_ state: State, meanSquare: Float, seconds: Float) -> State {
        guard seconds.isFinite, seconds > 0 else { return state }
        let energy = meanSquare.isFinite ? max(0, meanSquare) : 0
        var next = state
        let rising = energy > state.fastEnergy
        let fast = 1 - exp(-seconds / (rising ? attackSeconds : releaseSeconds))
        next.fastEnergy += fast * (energy - state.fastEnergy)
        // Compared before the slow average absorbs this buffer, so a step registers on its first buffer.
        let onset = energy > onsetFloor && energy > state.slowEnergy * onsetRatio
        next.slowEnergy += (1 - exp(-seconds / slowSeconds)) * (energy - state.slowEnergy)
        next.beat = onset ? 1 : state.beat * exp(-seconds / beatDecaySeconds)
        next.level = normalizedLevel(rms: next.fastEnergy.squareRoot())
        return next
    }
}

/// Shared between every tap processor and the player backdrop. Floats travel as bit patterns in atomics,
/// so neither side ever waits on the other.
final class PlaybackLevelMeter: Sendable {
    struct Reading: Equatable, Sendable {
        var level: Float = 0
        var beat: Float = 0
        /// Changes on every published buffer; an unchanged value means no tap is rendering.
        var sequence: UInt32 = 0
    }

    private let enabled = Atomic<Bool>(false)
    private let levelBits = Atomic<UInt32>(0)
    private let beatBits = Atomic<UInt32>(0)
    private let sequence = Atomic<UInt32>(0)

    var isEnabled: Bool { enabled.load(ordering: .relaxed) }

    func setEnabled(_ value: Bool) { enabled.store(value, ordering: .relaxed) }

    /// Audio thread. Crossfading decks both publish; the backdrop's own smoothing absorbs the interleaving.
    func publish(_ state: AudioLevelMeter.State) {
        levelBits.store(state.level.bitPattern, ordering: .relaxed)
        beatBits.store(state.beat.bitPattern, ordering: .relaxed)
        sequence.wrappingAdd(1, ordering: .releasing)
    }

    func read() -> Reading {
        let published = sequence.load(ordering: .acquiring)
        return Reading(level: Float(bitPattern: levelBits.load(ordering: .relaxed)),
                       beat: Float(bitPattern: beatBits.load(ordering: .relaxed)), sequence: published)
    }
}

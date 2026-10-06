import AVFoundation
import SwiftUI
import XCTest
@testable import GanaBajana

final class PlayerBackgroundMotionPolicyTests: XCTestCase {
    private typealias Policy = PlayerBackdropMotionPolicy

    private func inputs(_ style: PlayerBackgroundMotion, playing: Bool = true, visible: Bool = true,
                        reduceMotion: Bool = false, flat: Bool = false, lowPower: Bool = false, thermal: Bool = false,
                        meter: Bool = true) -> Policy.Inputs {
        Policy.Inputs(style: style, reduceMotion: reduceMotion, flatBackdrop: flat, lowPower: lowPower, thermalPressure: thermal,
                      levelMeterAvailable: meter, isPlaying: playing, isVisible: visible)
    }

    func testOffIsAlwaysStaticWithNoReason() {
        for reduceMotion in [false, true] {
            for lowPower in [false, true] {
                for meter in [false, true] {
                    let resolution = Policy.resolve(inputs(.off, reduceMotion: reduceMotion, lowPower: lowPower, meter: meter))
                    XCTAssertEqual(resolution, Policy.Resolution(effect: .static, reason: .none, animates: false))
                }
            }
        }
        XCTAssertFalse(Policy.wantsLevelMeter(inputs(.off)))
    }

    func testEveryAnimatedStyleFallsBackToStaticInOrderOfPrecedence() {
        for style in [PlayerBackgroundMotion.drift, .pulse, .reactive] {
            XCTAssertEqual(Policy.resolve(inputs(style, reduceMotion: true, flat: true, lowPower: true, thermal: true)),
                           Policy.Resolution(effect: .static, reason: .reduceMotion, animates: false), "\(style)")
            XCTAssertEqual(Policy.resolve(inputs(style, flat: true, lowPower: true)).reason, .reduceTransparency)
            XCTAssertEqual(Policy.resolve(inputs(style, lowPower: true, thermal: true)).reason, .lowPower)
            XCTAssertEqual(Policy.resolve(inputs(style, thermal: true)).reason, .thermal)
            for reason in [inputs(style, reduceMotion: true), inputs(style, flat: true), inputs(style, lowPower: true),
                           inputs(style, thermal: true)] {
                XCTAssertEqual(Policy.resolve(reason).effect, .static)
                XCTAssertFalse(Policy.resolve(reason).animates)
                XCTAssertFalse(Policy.wantsLevelMeter(reason), "A static backdrop never asks for a tap")
            }
        }
    }

    func testDriftAnimatesWhilePausedButOnlyWhenVisible() {
        XCTAssertEqual(Policy.resolve(inputs(.drift, playing: false)), Policy.Resolution(effect: .drift, reason: .none, animates: true))
        XCTAssertEqual(Policy.resolve(inputs(.drift, playing: true)).animates, true)
        XCTAssertEqual(Policy.resolve(inputs(.drift, visible: false)), Policy.Resolution(effect: .drift, reason: .none, animates: false))
        XCTAssertEqual(Policy.frameInterval(for: .drift), 1.0 / 24)
    }

    func testPulseAndReactiveFollowPlayback() {
        XCTAssertEqual(Policy.resolve(inputs(.pulse)), Policy.Resolution(effect: .pulse, reason: .none, animates: true))
        XCTAssertEqual(Policy.resolve(inputs(.pulse, playing: false)), Policy.Resolution(effect: .pulse, reason: .none, animates: false))
        XCTAssertEqual(Policy.resolve(inputs(.reactive)), Policy.Resolution(effect: .reactive, reason: .none, animates: true))
        XCTAssertEqual(Policy.resolve(inputs(.reactive, playing: false)).animates, false)
        XCTAssertEqual(Policy.resolve(inputs(.reactive, visible: false)).animates, false)
        XCTAssertEqual(Policy.frameInterval(for: .pulse), 1.0 / 30)
        XCTAssertEqual(Policy.frameInterval(for: .reactive), 1.0 / 30)
    }

    func testReactiveWithoutATapFallsBackToPulseButStillAsksForTheMeter() {
        XCTAssertEqual(Policy.resolve(inputs(.reactive, meter: false)), Policy.Resolution(effect: .pulse, reason: .noTap, animates: true))
        XCTAssertEqual(Policy.resolve(inputs(.reactive, playing: false, meter: false)),
                       Policy.Resolution(effect: .pulse, reason: .noTap, animates: false))
        XCTAssertTrue(Policy.wantsLevelMeter(inputs(.reactive, meter: false)), "The tap request cannot wait for the tap")
        XCTAssertTrue(Policy.wantsLevelMeter(inputs(.reactive, playing: false)))
        XCTAssertFalse(Policy.wantsLevelMeter(inputs(.reactive, visible: false)), "A hidden player stops measuring")
        XCTAssertFalse(Policy.wantsLevelMeter(inputs(.pulse)))
        XCTAssertFalse(Policy.wantsLevelMeter(inputs(.drift)))
        // Accessibility and power fallbacks outrank the tap fallback.
        XCTAssertEqual(Policy.resolve(inputs(.reactive, reduceMotion: true, meter: false)).reason, .reduceMotion)
        XCTAssertEqual(Policy.resolve(inputs(.reactive, lowPower: true, meter: false)).reason, .lowPower)
    }

    func testEveryStillReasonExceptAMissingTapIsExplainedInSettings() {
        for reason in [Policy.Reason.reduceMotion, .reduceTransparency, .lowPower, .thermal] {
            XCTAssertNotNil(PlayerBackgroundHoldNote.message(for: reason), reason.rawValue)
        }
        XCTAssertNil(PlayerBackgroundHoldNote.message(for: .none))
        XCTAssertNil(PlayerBackgroundHoldNote.message(for: .noTap), "A song without a tap still pulses")
    }

    func testReactiveTargetAndSmoothing() {
        XCTAssertEqual(Policy.reactiveTarget(PlaybackLevelMeter.Reading(level: 1, beat: 1, sequence: 3), isFresh: true), 1)
        XCTAssertEqual(Policy.reactiveTarget(PlaybackLevelMeter.Reading(level: 1, beat: 1, sequence: 3), isFresh: false), 0)
        XCTAssertEqual(Policy.reactiveTarget(PlaybackLevelMeter.Reading(level: .nan, beat: 0.5, sequence: 1), isFresh: true), 0.175,
                       accuracy: 1e-9)
        let rising = Policy.smoothedIntensity(previous: 0, target: 1, seconds: 0.08)
        let falling = 1 - Policy.smoothedIntensity(previous: 1, target: 0, seconds: 0.08)
        XCTAssertEqual(rising, 1 - exp(-1), accuracy: 1e-9)
        XCTAssertLessThan(falling, rising, "Release is slower than attack")
        XCTAssertEqual(Policy.smoothedIntensity(previous: 0.4, target: 1, seconds: 0), 0.4)
    }
}

final class PlayerBackgroundMotionPreferenceTests: XCTestCase {
    func testDefaultsToOffAndDecodesLeniently() throws {
        XCTAssertEqual(UserPreferences().playerBackgroundMotion, .off)
        XCTAssertEqual(PlayerBackgroundMotion.allCases.map(\.title), ["Off", "Drift", "Pulse", "React to Music"])
        XCTAssertEqual(PlayerBackgroundMotion.allCases.map(\.rawValue), ["off", "drift", "pulse", "reactive"])
        let decoder = JSONDecoder()
        for unreadable in ["{}", #"{"playerBackgroundMotion":null}"#, #"{"playerBackgroundMotion":"future-style"}"#,
                           #"{"playerBackgroundMotion":7}"#, #"{"playerBackgroundMotion":{"style":"drift"}}"#] {
            let decoded = try decoder.decode(UserPreferences.self, from: Data(unreadable.utf8))
            XCTAssertEqual(decoded.playerBackgroundMotion, .off, unreadable)
        }
        // An unreadable value never blocks a sibling preference.
        let mixed = try decoder.decode(UserPreferences.self, from: Data(#"{"playerBackgroundMotion":3,"playerSwipeUpAction":"queue"}"#.utf8))
        XCTAssertEqual(mixed.playerSwipeUpAction, .queue)
        for style in PlayerBackgroundMotion.allCases {
            let decoded = try decoder.decode(UserPreferences.self, from: Data(#"{"playerBackgroundMotion":"\#(style.rawValue)"}"#.utf8))
            XCTAssertEqual(decoded.playerBackgroundMotion, style)
            var preferences = UserPreferences()
            preferences.playerBackgroundMotion = style
            XCTAssertEqual(try decoder.decode(UserPreferences.self, from: JSONEncoder().encode(preferences)), preferences)
        }
    }

    func testSyncsAsItsOwnLeafAndRefusesValuesTheDecoderWouldRewrite() throws {
        let defaults = try LibrarySyncPreferences.fields(UserPreferences())
        XCTAssertEqual(defaults["playerBackgroundMotion"], Data("\"off\"".utf8))
        for style in PlayerBackgroundMotion.allCases where style != .off {
            var preferences = UserPreferences()
            preferences.playerBackgroundMotion = style
            let fields = try LibrarySyncPreferences.fields(preferences)
            XCTAssertEqual(fields.filter { defaults[$0.key] != $0.value }.keys.sorted(), ["playerBackgroundMotion"])
            XCTAssertEqual(fields["playerBackgroundMotion"], Data("\"\(style.rawValue)\"".utf8))
            XCTAssertEqual(try LibrarySyncPreferences.applying(["playerBackgroundMotion": fields["playerBackgroundMotion"]!],
                                                              to: UserPreferences()), preferences)
        }
        var base = UserPreferences()
        base.playerSwipeUpAction = .queue
        var expected = base
        expected.playerBackgroundMotion = .pulse
        XCTAssertEqual(try LibrarySyncPreferences.applying(["playerBackgroundMotion": Data("\"pulse\"".utf8)], to: base), expected,
                       "Only the one leaf changes")
        for refused in ["\"future-style\"", "7", "null", "true"] {
            XCTAssertThrowsError(try LibrarySyncPreferences.applying(["playerBackgroundMotion": Data(refused.utf8)], to: UserPreferences()),
                                 refused)
        }
    }
}

final class AudioLevelMeterTests: XCTestCase {
    private let sampleRate: Float = 48_000

    private func meanSquare(_ samples: [Float]) -> Float {
        samples.withUnsafeBufferPointer { buffer in
            let totals = AudioLevelMeter.sumOfSquares(buffer)
            return totals.count > 0 ? totals.sum / Float(totals.count) : 0
        }
    }

    private func sine(amplitude: Float, frames: Int, frequency: Float = 1_000) -> [Float] {
        (0..<frames).map { amplitude * sin(2 * .pi * frequency * Float($0) / sampleRate) }
    }

    /// Feeds equal 10 ms buffers of the given mean square.
    private func run(_ state: AudioLevelMeter.State, meanSquare: Float, seconds: Float) -> AudioLevelMeter.State {
        var state = state
        for _ in 0..<Int((seconds / 0.01).rounded()) { state = AudioLevelMeter.advance(state, meanSquare: meanSquare, seconds: 0.01) }
        return state
    }

    func testSilenceStaysAtZero() {
        XCTAssertEqual(meanSquare([Float](repeating: 0, count: 480)), 0)
        let state = run(AudioLevelMeter.State(), meanSquare: 0, seconds: 2)
        XCTAssertEqual(state.level, 0)
        XCTAssertEqual(state.beat, 0)
        XCTAssertEqual(AudioLevelMeter.normalizedLevel(rms: 0), 0)
        XCTAssertEqual(AudioLevelMeter.normalizedLevel(rms: .nan), 0)
    }

    func testSineMeasuresItsExpectedRMS() {
        let tone = sine(amplitude: 0.5, frames: 4_800)
        XCTAssertEqual(meanSquare(tone).squareRoot(), 0.5 / Float(2).squareRoot(), accuracy: 1e-3)
        XCTAssertEqual(AudioLevelMeter.normalizedLevel(rms: 1), 1, "Above the ceiling clamps to 1")
        // -27 dBFS sits exactly halfway between the -48 dB floor and the -6 dB ceiling.
        XCTAssertEqual(AudioLevelMeter.normalizedLevel(rms: pow(10, Float(-27) / 20)), 0.5, accuracy: 1e-4)
        let settled = run(AudioLevelMeter.State(), meanSquare: meanSquare(tone), seconds: 1)
        XCTAssertEqual(settled.fastEnergy.squareRoot(), 0.5 / Float(2).squareRoot(), accuracy: 1e-3)
        XCTAssertEqual(settled.level, AudioLevelMeter.normalizedLevel(rms: 0.5 / Float(2).squareRoot()), accuracy: 1e-3)
    }

    func testNonFiniteSamplesAreSkipped() {
        let samples: [Float] = [.nan, 0.5, .infinity, -0.5]
        samples.withUnsafeBufferPointer { buffer in
            let totals = AudioLevelMeter.sumOfSquares(buffer)
            XCTAssertEqual(totals.count, 2)
            XCTAssertEqual(totals.sum, 0.5, accuracy: 1e-6)
        }
        XCTAssertEqual(AudioLevelMeter.advance(AudioLevelMeter.State(), meanSquare: .nan, seconds: 0.01), AudioLevelMeter.State())
        XCTAssertEqual(AudioLevelMeter.advance(AudioLevelMeter.State(fastEnergy: 0.1), meanSquare: 1, seconds: 0).fastEnergy, 0.1)
    }

    func testAttackIsFastAndReleaseIsSlower() {
        let loud: Float = 0.125
        let attack = AudioLevelMeter.advance(AudioLevelMeter.State(), meanSquare: loud, seconds: 0.03)
        XCTAssertEqual(attack.fastEnergy, loud * (1 - exp(-1)), accuracy: 1e-6, "One attack time constant")
        let full = run(AudioLevelMeter.State(), meanSquare: loud, seconds: 0.3)
        XCTAssertGreaterThan(full.fastEnergy, loud * 0.99)
        let afterRelease = run(full, meanSquare: 0, seconds: 0.03)
        XCTAssertGreaterThan(afterRelease.fastEnergy, loud * 0.8, "Release keeps most of the energy after one attack time")
        let released = run(full, meanSquare: 0, seconds: 3)
        XCTAssertLessThan(released.level, 0.05)
    }

    func testEnergyStepTriggersOneOnsetThatDecays() {
        let quiet: Float = 1e-3
        let loud: Float = 0.1
        let steady = run(AudioLevelMeter.State(), meanSquare: quiet, seconds: 3)
        XCTAssertLessThan(steady.beat, 0.01, "Constant energy is not a beat")
        let step = AudioLevelMeter.advance(steady, meanSquare: loud, seconds: 0.01)
        XCTAssertEqual(step.beat, 1, "The first loud buffer is the onset")
        XCTAssertGreaterThan(step.level, steady.level)
        let sustained = run(step, meanSquare: loud, seconds: 4)
        XCTAssertLessThan(sustained.beat, 0.05, "A held level stops counting as onsets once the slow average catches up")
        let belowFloor = AudioLevelMeter.advance(AudioLevelMeter.State(), meanSquare: AudioLevelMeter.onsetFloor / 2, seconds: 0.01)
        XCTAssertEqual(belowFloor.beat, 0, "Near-silence never registers as an onset")
    }
}

@MainActor
final class PlayerBackgroundMeteringTapTests: XCTestCase {
    private let sampleRate = 48_000.0

    func testTapRequirementIncludesMeteringOnlyOnPathsThatAllowGainUp() {
        XCTAssertFalse(EqualizerTapInstaller.needsTap(equalizerEnabled: false, normalizationGain: 1, allowsGainUp: true, meteringRequested: false))
        XCTAssertTrue(EqualizerTapInstaller.needsTap(equalizerEnabled: false, normalizationGain: 1, allowsGainUp: true, meteringRequested: true),
                      "EQ off and no boost still taps for React to Music")
        XCTAssertFalse(EqualizerTapInstaller.needsTap(equalizerEnabled: false, normalizationGain: 1, allowsGainUp: false, meteringRequested: true),
                       "Live items never tap just to measure")
        XCTAssertTrue(EqualizerTapInstaller.needsTap(equalizerEnabled: false, normalizationGain: 1.5, allowsGainUp: true, meteringRequested: false))
        XCTAssertFalse(EqualizerTapInstaller.needsTap(equalizerEnabled: false, normalizationGain: 0.5, allowsGainUp: true, meteringRequested: false))
        XCTAssertTrue(EqualizerTapInstaller.needsTap(equalizerEnabled: true, normalizationGain: 1, allowsGainUp: false, meteringRequested: false))
    }

    func testMeteringInstallsATapWithEqualizerOffAndSkipsHLSAndLiveItems() async throws {
        let url = try PlaybackTestSupport.audioFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let installer = EqualizerTapInstaller()
        let before = AVPlayerItem(url: url)
        installer.setNormalizationGain(1, for: before)
        XCTAssertNil(before.audioMix, "Nothing needs a tap yet")
        XCTAssertEqual(installer.meterAvailability(for: before), .unavailable)

        installer.setMetering(true)
        XCTAssertTrue(installer.levelMeter.isEnabled)
        let standby = AVPlayerItem(url: url)
        installer.setNormalizationGain(1, for: standby)
        XCTAssertEqual(installer.meterAvailability(for: standby), .available, "A pending tap counts as available")
        try await PlaybackTestSupport.waitUntil { installer.status.attached == 2 }
        XCTAssertEqual(before.audioMix?.inputParameters.count, 1, "Requesting the meter taps an already registered item")
        XCTAssertEqual(standby.audioMix?.inputParameters.count, 1)
        XCTAssertEqual(installer.meterAvailability(for: before), .available)

        let hls = AVPlayerItem(url: URL(string: "https://example.invalid/stream.m3u8")!)
        installer.setNormalizationGain(1, for: hls)
        XCTAssertNil(hls.audioMix)
        XCTAssertEqual(installer.status.bypassed, 1)
        XCTAssertEqual(installer.meterAvailability(for: hls), .unavailable)

        let live = AVPlayerItem(url: URL(string: "https://example.invalid/live")!)
        installer.setNormalizationGain(1, for: live, allowsGainUp: false)
        XCTAssertNil(live.audioMix)
        XCTAssertEqual(installer.status.pending, 0, "A live item is never queued for a measuring tap")
        XCTAssertEqual(installer.meterAvailability(for: live), .unavailable)

        installer.setMetering(false)
        XCTAssertEqual(installer.meterAvailability(for: before), .unavailable)
        let later = AVPlayerItem(url: url)
        installer.setNormalizationGain(1, for: later)
        XCTAssertNil(later.audioMix, "Withdrawing the meter leaves later items untapped")
        XCTAssertEqual(before.audioMix?.inputParameters.count, 1, "Installed taps stay and pass audio through")
    }

    func testMeasuringOnlyTapLeavesAudioUntouchedAndPublishesALevel() throws {
        let meter = PlaybackLevelMeter()
        let processor = EqualizerProcessor(settings: EqualizerSettings(isEnabled: false), revision: 1, meter: meter)
        processor.prepare(maxFrames: 4_800, format: format(channels: 2, interleaved: false))
        let source = (0..<4_800).map { Float(sin(2 * Double.pi * 1_000 * Double($0) / sampleRate)) * 0.5 }
        var left = source, right = source
        try render(processor, frames: source.count, planar: &left, &right)
        XCTAssertEqual(meter.read().sequence, 0, "A disabled meter is never written")

        meter.setEnabled(true)
        try render(processor, frames: source.count, planar: &left, &right)
        XCTAssertEqual(left, source, "Metering alone is bit-transparent")
        XCTAssertEqual(right, source)
        XCTAssertEqual(processor.processedFrames.load(ordering: .relaxed), 0, "Pure pass-through keeps its counter")
        let reading = meter.read()
        XCTAssertEqual(reading.sequence, 1)
        XCTAssertGreaterThan(reading.level, 0.5)
        XCTAssertEqual(reading.beat, 1, "The first loud buffer after silence is an onset")

        var interleaved = [Float](repeating: 0, count: 960)
        let stereo = EqualizerProcessor(settings: EqualizerSettings(isEnabled: false), revision: 1, meter: meter)
        stereo.prepare(maxFrames: 480, format: format(channels: 2, interleaved: true))
        try render(stereo, frames: 480, interleaved: &interleaved, channels: 2)
        XCTAssertEqual(meter.read().sequence, 2, "Interleaved buffers are measured too")
    }

    private static let palettes = [
        ArtworkPalette(primary: .init(red: 0.95, green: 0.85, blue: 0.2), secondary: .init(red: 1, green: 1, blue: 0.9),
                       averageLuminance: 0.8, isChromatic: true),
        ArtworkPalette(primary: .init(red: 0.9, green: 0.2, blue: 0.3), secondary: .init(red: 0.1, green: 0.3, blue: 0.9),
                       averageLuminance: 0.3, isChromatic: true),
        ArtworkPalette(primary: .init(red: 0.2, green: 0.9, blue: 0.3), secondary: .init(red: 0.7, green: 0.2, blue: 0.9),
                       averageLuminance: 0.5, isChromatic: true),
        ArtworkPalette.tinted(AppTheme.gold),
        ArtworkPalette.tinted(AppTheme.violet),
    ]

    private func contrast(_ a: Double, _ b: Double) -> Double { (max(a, b) + 0.05) / (min(a, b) + 0.05) }

    func testEveryMeshColourAndEveryBlendBetweenNeighboursKeepsPlayerTextAt4Point5To1() {
        for palette in Self.palettes {
            for dark in [true, false] {
                let mesh = PlayerBackdropMesh(palette: palette, dark: dark)
                // Dark mode: white text and the 0xEFEFF4 secondary. Light mode: 0x0B0B10 text and the 0x3F3F49 secondary.
                let texts = dark ? [1.0, 0.86] : [0.0036, 0.05]
                for energy in stride(from: 0.0, through: 1, by: 0.25) {
                    for cycle in stride(from: 0.0, through: 19, by: 2.375) {
                        let colors = mesh.colors(energy: energy, cycle: cycle)
                        // MeshGradient interpolates between neighbours; their blends must hold the bound too.
                        var samples = colors
                        for row in 0..<4 {
                            for column in 0..<4 {
                                let index = row * 4 + column
                                for neighbour in [column < 3 ? index + 1 : nil, row < 3 ? index + 4 : nil, row < 3 && column < 3 ? index + 5 : nil] {
                                    guard let neighbour else { continue }
                                    for t in [0.25, 0.5, 0.75] { samples.append(PlayerBackdropMesh.mix(colors[index], colors[neighbour], t)) }
                                }
                            }
                        }
                        for color in samples {
                            for text in texts {
                                XCTAssertGreaterThanOrEqual(contrast(color.relativeLuminance, text), 4.5,
                                                            "dark \(dark) energy \(energy) cycle \(cycle)")
                            }
                        }
                    }
                }
            }
        }
    }

    func testMeshShowsClearlyDifferentColoursSoTheMotionIsVisible() {
        for palette in Self.palettes {
            for dark in [true, false] {
                let mesh = PlayerBackdropMesh(palette: palette, dark: dark)
                XCTAssertEqual(mesh.vertices.count, 16)
                let colors = mesh.colors(energy: 1, cycle: 0)
                let luminances = colors.map(\.relativeLuminance)
                // The quiet-to-loud range is what Pulse and React to Music animate; it must be well beyond a flicker.
                let ratio = (luminances.max()! + 0.05) / (luminances.min()! + 0.05)
                XCTAssertGreaterThan(ratio, 1.6, "dark \(dark): vertices need visible contrast between each other: \(luminances)")
                let quiet = mesh.colors(energy: 0, cycle: 0).map(\.relativeLuminance)
                let loudest = zip(luminances, quiet).map { abs($0 - $1) }.max()!
                XCTAssertGreaterThan(loudest, dark ? 0.04 : 0.1, "dark \(dark): energy must change brightness visibly")
                let later = mesh.colors(energy: 1, cycle: 19 / 2)
                let hueTravel = zip(colors, later).map { abs($0.red - $1.red) + abs($0.green - $1.green) + abs($0.blue - $1.blue) }.max()!
                if palette.primary != palette.secondary {
                    XCTAssertGreaterThan(hueTravel, 0.1, "dark \(dark): colour families must travel across vertices")
                }
            }
        }
        XCTAssertEqual(PlayerBackdropMesh(palette: Self.palettes[0], dark: true).colors(energy: 5, cycle: 0),
                       PlayerBackdropMesh(palette: Self.palettes[0], dark: true).colors(energy: 1, cycle: 0), "Energy clamps")
    }

    func testFramesPinCornersKeepEdgesOnTheirEdgesAndNeverFoldTheMesh() {
        for effect in [PlayerBackdropMotionPolicy.Effect.drift, .pulse, .reactive] {
            for phase in stride(from: 0.0, through: 90, by: 1.3) {
                for intensity in [0.0, 0.5, 1, 4] {
                    let frame = PlayerBackdropMesh.frame(effect: effect, phase: phase, intensity: intensity)
                    XCTAssertLessThanOrEqual(frame.energy, 1)
                    XCTAssertGreaterThanOrEqual(frame.energy, 0)
                    let points = frame.points
                    XCTAssertEqual(points.count, 16)
                    XCTAssertEqual(points[0], SIMD2<Float>(0, 0))
                    XCTAssertEqual(points[3], SIMD2<Float>(1, 0))
                    XCTAssertEqual(points[12], SIMD2<Float>(0, 1))
                    XCTAssertEqual(points[15], SIMD2<Float>(1, 1))
                    for column in 1...2 {
                        XCTAssertEqual(points[column].y, 0)
                        XCTAssertEqual(points[12 + column].y, 1)
                    }
                    for row in 1...2 {
                        XCTAssertEqual(points[row * 4].x, 0)
                        XCTAssertEqual(points[row * 4 + 3].x, 1)
                    }
                    for row in 0..<4 {
                        for column in 0..<3 {
                            XCTAssertLessThan(points[row * 4 + column].x, points[row * 4 + column + 1].x, "\(effect) row \(row) folds")
                        }
                    }
                    for column in 0..<4 {
                        for row in 0..<3 {
                            XCTAssertLessThan(points[row * 4 + column].y, points[(row + 1) * 4 + column].y, "\(effect) column \(column) folds")
                        }
                    }
                }
            }
        }
        let still = PlayerBackdropMesh.frame(effect: .drift, phase: 0, intensity: 0).points
        let moved = PlayerBackdropMesh.frame(effect: .drift, phase: 4, intensity: 0).points
        let travel = zip(still, moved).map { abs($0.x - $1.x) + abs($0.y - $1.y) }.max()!
        XCTAssertGreaterThan(travel, 0.08, "Drift must visibly move within four seconds")
        XCTAssertEqual(PlayerBackdropMesh.frame(effect: .drift, phase: 12, intensity: 0).energy, 1, "Drift keeps full colour")
        let quiet = PlayerBackdropMesh.frame(effect: .reactive, phase: 3, intensity: 0)
        let loud = PlayerBackdropMesh.frame(effect: .reactive, phase: 3, intensity: 1)
        XCTAssertGreaterThan(loud.energy - quiet.energy, 0.6, "Loud passages light the background clearly")
    }

    func testDriverCapsResumedStepsAndSettlesWhenTheMeterGoesQuiet() {
        let driver = PlayerBackdropMotionDriver()
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        driver.advance(to: start, animates: true, reading: nil)
        driver.advance(to: start.addingTimeInterval(1 / 30), animates: true, reading: nil)
        XCTAssertEqual(driver.phase, 1 / 30, accuracy: 1e-9)
        driver.advance(to: start.addingTimeInterval(60), animates: true, reading: nil)
        XCTAssertEqual(driver.phase, 1 / 30 + PlayerBackdropMotionDriver.maximumStep, accuracy: 1e-9, "A paused minute is not replayed")
        driver.advance(to: start.addingTimeInterval(61), animates: false, reading: nil)
        XCTAssertEqual(driver.phase, 1 / 30 + PlayerBackdropMotionDriver.maximumStep, accuracy: 1e-9)

        var date = start.addingTimeInterval(62)
        driver.advance(to: date, animates: true, reading: nil)
        for index in 1...30 {
            date = date.addingTimeInterval(1 / 30)
            driver.advance(to: date, animates: true, reading: PlaybackLevelMeter.Reading(level: 1, beat: 0, sequence: UInt32(index)))
        }
        let loud = driver.intensity
        XCTAssertGreaterThan(loud, 0.5)
        for _ in 0..<60 {
            date = date.addingTimeInterval(1 / 30)
            driver.advance(to: date, animates: true, reading: PlaybackLevelMeter.Reading(level: 1, beat: 0, sequence: 30))
        }
        XCTAssertLessThan(driver.intensity, 0.05, "An unchanged sequence means no tap is rendering")
    }

    // MARK: - Helpers

    private func format(channels: Int, interleaved: Bool) -> AudioStreamBasicDescription {
        var flags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        if !interleaved { flags |= kAudioFormatFlagIsNonInterleaved }
        let bytesPerFrame = UInt32(interleaved ? 4 * channels : 4)
        return AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: flags,
                                           mBytesPerPacket: bytesPerFrame, mFramesPerPacket: 1, mBytesPerFrame: bytesPerFrame,
                                           mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
    }

    private func render(_ processor: EqualizerProcessor, frames: Int, planar left: inout [Float], _ right: inout [Float]) throws {
        let list = AudioBufferList.allocate(maximumBuffers: 2)
        defer { free(list.unsafeMutablePointer) }
        try left.withUnsafeMutableBufferPointer { leftBuffer in
            try right.withUnsafeMutableBufferPointer { rightBuffer in
                list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4),
                                      mData: UnsafeMutableRawPointer(try XCTUnwrap(leftBuffer.baseAddress)))
                list[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4),
                                      mData: UnsafeMutableRawPointer(try XCTUnwrap(rightBuffer.baseAddress)))
                processor.render(frames: frames, bufferList: list)
            }
        }
    }

    private func render(_ processor: EqualizerProcessor, frames: Int, interleaved samples: inout [Float], channels: Int) throws {
        let list = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(list.unsafeMutablePointer) }
        try samples.withUnsafeMutableBufferPointer { buffer in
            list[0] = AudioBuffer(mNumberChannels: UInt32(channels), mDataByteSize: UInt32(frames * channels * 4),
                                  mData: UnsafeMutableRawPointer(try XCTUnwrap(buffer.baseAddress)))
            processor.render(frames: frames, bufferList: list)
        }
    }
}

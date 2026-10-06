import Combine
import OSLog
import SwiftUI
import UIKit

/// Decides what the full-screen player backdrop may do. Pure so every accessibility, power and tap combination
/// is unit-testable; the view only feeds it inputs.
enum PlayerBackdropMotionPolicy {
    enum Effect: String, Equatable, Sendable {
        case `static`, drift, pulse, reactive
    }

    /// Why the effect differs from the chosen style. Bounded: these are the only metric values.
    enum Reason: String, Equatable, Sendable {
        case none, reduceMotion, reduceTransparency, lowPower, thermal, noTap
    }

    struct Inputs: Equatable, Sendable {
        var style: PlayerBackgroundMotion = .off
        var reduceMotion = false
        /// Reduce Transparency or Increase Contrast: the flat tint stays flat.
        var flatBackdrop = false
        var lowPower = false
        /// Serious or critical thermal state.
        var thermalPressure = false
        var levelMeterAvailable = true
        var isPlaying = false
        /// On screen, scene active and not covered by a player sheet.
        var isVisible = false
    }

    struct Resolution: Equatable, Sendable {
        var effect: Effect
        var reason: Reason
        /// False means zero frames: TimelineView is paused and nothing redraws.
        var animates: Bool
    }

    /// Drift's slow flow reads smoothly at 24 fps; more frames only add GPU work.
    static let driftFrameInterval = 1.0 / 24
    /// Beats need a quicker response; still capped well under the display rate.
    static let playbackFrameInterval = 1.0 / 30

    static func resolve(_ inputs: Inputs) -> Resolution {
        let wanted: Effect
        switch inputs.style {
        case .off: return Resolution(effect: .static, reason: .none, animates: false)
        case .drift: wanted = .drift
        case .pulse: wanted = .pulse
        case .reactive: wanted = .reactive
        }
        if inputs.reduceMotion { return Resolution(effect: .static, reason: .reduceMotion, animates: false) }
        if inputs.flatBackdrop { return Resolution(effect: .static, reason: .reduceTransparency, animates: false) }
        if inputs.lowPower { return Resolution(effect: .static, reason: .lowPower, animates: false) }
        if inputs.thermalPressure { return Resolution(effect: .static, reason: .thermal, animates: false) }
        var effect = wanted
        var reason = Reason.none
        if wanted == .reactive, !inputs.levelMeterAvailable {
            effect = .pulse
            reason = .noTap
        }
        // Drift is ambient; Pulse and React to Music follow playback and hold still while paused.
        let animates = inputs.isVisible && (effect == .drift || inputs.isPlaying)
        return Resolution(effect: effect, reason: reason, animates: animates)
    }

    /// Asked before the tap exists, so availability is assumed; a visible player is the only consumer.
    static func wantsLevelMeter(_ inputs: Inputs) -> Bool {
        var assumingTap = inputs
        assumingTap.levelMeterAvailable = true
        return inputs.isVisible && resolve(assumingTap).effect == .reactive
    }

    static func frameInterval(for effect: Effect) -> Double {
        effect == .drift ? driftFrameInterval : playbackFrameInterval
    }

    /// Level drives most of the response; the beat adds a short lift on onsets.
    static func reactiveTarget(_ reading: PlaybackLevelMeter.Reading, isFresh: Bool) -> Double {
        guard isFresh else { return 0 }
        let level = reading.level.isFinite ? Double(reading.level) : 0
        let beat = reading.beat.isFinite ? Double(reading.beat) : 0
        return min(1, max(0, 0.65 * level + 0.35 * beat))
    }

    static func smoothedIntensity(previous: Double, target: Double, seconds: Double) -> Double {
        guard seconds > 0 else { return previous }
        let tau = target > previous ? 0.08 : 0.25
        return previous + (target - previous) * (1 - exp(-seconds / tau))
    }
}

/// A 4 by 4 mesh of the artwork's own colours. Every tone is chosen inside a luminance band that keeps the
/// player's text at 4.5:1 or better, so the motion needs no scrim over it.
struct PlayerBackdropMesh: Equatable {
    struct Vertex: Equatable {
        /// The vertex's resting tone and the same position in the other colour family.
        let own: ArtworkPalette.RGB
        let other: ArtworkPalette.RGB
        /// The quiet end of Pulse and React to Music.
        let ownQuiet: ArtworkPalette.RGB
        let otherQuiet: ArtworkPalette.RGB
        let cyclePhase: Double
    }

    enum Level: Int { case deep, mid, vivid }

    static let width = 4
    static let height = 4
    /// White text needs relative luminance at most 0.183; dark text on light needs at least 0.40 against the
    /// artwork secondary grey. Bands stay inside both with room for mesh interpolation.
    static func luminance(_ level: Level, dark: Bool) -> Double {
        switch level {
        case .deep: dark ? 0.018 : 0.9
        case .mid: dark ? 0.055 : 0.7
        case .vivid: dark ? 0.12 : 0.5
        }
    }

    /// Pale tones only reach their luminance with little saturation; deep ones carry the most colour.
    static func saturation(_ level: Level, dark: Bool) -> ClosedRange<Double> {
        switch (level, dark) {
        case (.deep, true): 0.4...0.8
        case (.mid, true): 0.5...0.9
        case (.vivid, true): 0.55...0.95
        case (.deep, false): 0.04...0.12
        case (.mid, false): 0.12...0.35
        case (.vivid, false): 0.3...0.7
        }
    }

    /// Row by row from the top; the bottom row stays deeper under the transport controls.
    static let layout: [(Level, Bool)] = [
        (.mid, false), (.vivid, true), (.mid, false), (.deep, true),
        (.vivid, false), (.mid, true), (.vivid, true), (.mid, false),
        (.mid, true), (.vivid, false), (.mid, false), (.vivid, true),
        (.deep, false), (.mid, true), (.deep, false), (.mid, true),
    ]

    let vertices: [Vertex]

    init(palette: ArtworkPalette, fallback: ArtworkPalette? = nil, dark: Bool) {
        // Grey covers have no colour to animate; the language or accent tint supplies one.
        let source = palette.isChromatic ? palette : (fallback ?? palette)
        func tone(_ family: Bool, _ level: Level) -> ArtworkPalette.RGB {
            source.tint(family ? source.secondary : source.primary, luminance: Self.luminance(level, dark: dark),
                        saturation: Self.saturation(level, dark: dark))
        }
        func quiet(_ level: Level) -> Level { level == .vivid ? .mid : .deep }
        vertices = Self.layout.enumerated().map { index, entry in
            let (level, secondary) = entry
            return Vertex(own: tone(secondary, level), other: tone(!secondary, level),
                          ownQuiet: tone(secondary, quiet(level)), otherQuiet: tone(!secondary, quiet(level)),
                          cyclePhase: Double(index) * 0.73)
        }
    }

    /// `energy` in 0...1 runs from the quiet tones to the resting tones; `cycle` is seconds of colour drift.
    func colors(energy: Double, cycle: Double) -> [ArtworkPalette.RGB] {
        let e = min(1, max(0, energy.isFinite ? energy : 1))
        return vertices.map { vertex in
            // Each vertex fades between the two colour families on its own phase, so the colours visibly travel.
            let blend = 0.5 + 0.5 * sin(2 * .pi * cycle / Self.colorCyclePeriod + vertex.cyclePhase)
            let own = Self.mix(vertex.ownQuiet, vertex.own, e)
            let other = Self.mix(vertex.otherQuiet, vertex.other, e)
            return Self.mix(own, other, blend * 0.85)
        }
    }

    static let colorCyclePeriod = 19.0

    static func mix(_ a: ArtworkPalette.RGB, _ b: ArtworkPalette.RGB, _ t: Double) -> ArtworkPalette.RGB {
        ArtworkPalette.RGB(red: a.red + (b.red - a.red) * t, green: a.green + (b.green - a.green) * t,
                           blue: a.blue + (b.blue - a.blue) * t)
    }

    /// Corners stay put and edge points slide along their edge, so the mesh always covers the view. Interior
    /// travel stays under half the 1/3 spacing, so neighbouring points never cross and fold the mesh.
    static func points(phase: Double, amplitude: Double, kick: Double = 0) -> [SIMD2<Float>] {
        func wave(_ period: Double, _ offset: Double) -> Double { sin(2 * .pi * phase / period + offset) }
        let a = min(1, max(0, amplitude.isFinite ? amplitude : 0))
        let k = min(1, max(0, kick.isFinite ? kick : 0))
        let interior = 0.15 * a, edge = 0.13 * a
        var points: [SIMD2<Float>] = []
        for row in 0..<height {
            for column in 0..<width {
                var x = Double(column) / 3, y = Double(row) / 3
                let seed = Double(row * width + column)
                let onTopOrBottom = row == 0 || row == height - 1, onSides = column == 0 || column == width - 1
                if onTopOrBottom && onSides {
                } else if onTopOrBottom {
                    x += edge * wave(11 + seed, seed)
                } else if onSides {
                    y += edge * wave(13 + seed, seed * 1.7)
                } else {
                    x += interior * wave(12 + seed * 0.9, seed * 2.1)
                    y += interior * wave(15 + seed * 0.7, seed * 1.3)
                    // A beat pushes the middle outwards for a moment.
                    x += (x - 0.5) * 0.25 * k
                    y += (y - 0.5) * 0.25 * k
                }
                points.append(SIMD2<Float>(Float(x), Float(y)))
            }
        }
        return points
    }

    struct Frame: Equatable {
        var points: [SIMD2<Float>]
        var energy: Double
        var cycle: Double
    }

    static let pulsePeriod = 3.6

    static func frame(effect: PlayerBackdropMotionPolicy.Effect, phase: Double, intensity: Double) -> Frame {
        let i = min(1, max(0, intensity.isFinite ? intensity : 0))
        switch effect {
        case .static:
            return Frame(points: points(phase: 0, amplitude: 0), energy: 1, cycle: 0)
        case .drift:
            return Frame(points: points(phase: phase, amplitude: 1), energy: 1, cycle: phase)
        case .pulse:
            let breath = 0.5 + 0.5 * sin(2 * .pi * phase / pulsePeriod)
            return Frame(points: points(phase: phase, amplitude: 0.45, kick: 0.6 * breath), energy: 0.25 + 0.75 * breath,
                         cycle: phase * 0.5)
        case .reactive:
            return Frame(points: points(phase: phase, amplitude: 0.35 + 0.5 * i, kick: i), energy: 0.15 + 0.85 * i,
                         cycle: phase * 0.5)
        }
    }
}

extension ArtworkPalette {
    /// Palette for a player without artwork: the existing fallback tint, with no scrim boost.
    static func tinted(_ color: Color) -> ArtworkPalette {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return .neutral }
        let rgb = RGB(red: Double(red), green: Double(green), blue: Double(blue))
        // One fallback colour gives Drift nothing to blend; a neighbouring hue keeps the family recognisable.
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0
        UIColor(red: red, green: green, blue: blue, alpha: 1).getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        let shifted = UIColor(hue: (hue + 0.93).truncatingRemainder(dividingBy: 1), saturation: saturation, brightness: brightness, alpha: 1)
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0
        shifted.getRed(&r2, green: &g2, blue: &b2, alpha: &alpha)
        let secondary = saturation > 0.05 ? RGB(red: Double(r2), green: Double(g2), blue: Double(b2)) : rgb
        return ArtworkPalette(primary: rgb, secondary: secondary, averageLuminance: 0.2, isChromatic: saturation > 0.05)
    }
}

/// Phase and intensity live in a reference so 30 Hz frames never invalidate SwiftUI state.
@MainActor
final class PlayerBackdropMotionDriver {
    private static let log = Logger(subsystem: "com.agraabhi.ganabajana", category: "Player")
    /// A resumed timeline continues from where it paused instead of jumping by the paused duration.
    static let maximumStep = 0.1
    /// No new buffer within this window means no tap is rendering, so the backdrop settles.
    static let staleAfter = 0.25

    private(set) var phase = 0.0
    private(set) var intensity = 0.0
    private var lastDate: Date?
    private var lastSequence: UInt32?
    private var lastFreshDate: Date?
    private var reported: String?

    func advance(to date: Date, animates: Bool, reading: PlaybackLevelMeter.Reading?) {
        defer { lastDate = date }
        guard animates, let lastDate else { return }
        let seconds = min(max(0, date.timeIntervalSince(lastDate)), Self.maximumStep)
        phase += seconds
        guard let reading else { return }
        if reading.sequence != lastSequence {
            lastSequence = reading.sequence
            lastFreshDate = date
        }
        let fresh = lastFreshDate.map { date.timeIntervalSince($0) <= Self.staleAfter } ?? false
        let target = PlayerBackdropMotionPolicy.reactiveTarget(reading, isFresh: fresh)
        intensity = PlayerBackdropMotionPolicy.smoothedIntensity(previous: intensity, target: target, seconds: seconds)
    }

    /// Logs only when the style, effect or reason changes; never per frame.
    func report(style: PlayerBackgroundMotion, _ resolution: PlayerBackdropMotionPolicy.Resolution) {
        let key = "\(style.rawValue)|\(resolution.effect.rawValue)|\(resolution.reason.rawValue)"
        guard key != reported else { return }
        reported = key
        Self.log.info("event=player_background style=\(style.rawValue, privacy: .public) effective=\(resolution.effect.rawValue, privacy: .public) reason=\(resolution.reason.rawValue, privacy: .public)")
    }
}

/// The player's backdrop. Off, Reduce Motion, flat tints, Low Power and thermal pressure render the shared
/// static `ArtworkBackdropSurface` unchanged; the other styles render the capped-rate mesh.
@MainActor
struct PlayerArtworkBackdrop: View {
    let url: URL?
    let fallbackTint: Color
    let style: PlayerBackgroundMotion
    /// Resets loaded artwork when it changes, like the `.id` the player used to apply directly.
    let identity: Bool
    let isPlaying: Bool
    let isCovered: Bool
    let meter: PlaybackLevelMeter
    let meterAvailable: @MainActor () -> Bool
    let setMetering: @MainActor (Bool) -> Void

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var isOnScreen = false
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var thermalPressure = PlayerArtworkBackdrop.thermalPressure()
    @State private var driver = PlayerBackdropMotionDriver()

    private var inputs: PlayerBackdropMotionPolicy.Inputs {
        PlayerBackdropMotionPolicy.Inputs(style: style, reduceMotion: reduceMotion,
                                          flatBackdrop: reduceTransparency || colorSchemeContrast == .increased,
                                          lowPower: lowPower, thermalPressure: thermalPressure, levelMeterAvailable: true,
                                          isPlaying: isPlaying, isVisible: isOnScreen && scenePhase == .active && !isCovered)
    }

    var body: some View {
        let inputs = self.inputs
        let resolution = PlayerBackdropMotionPolicy.resolve(inputs)
        let wantsMeter = PlayerBackdropMotionPolicy.wantsLevelMeter(inputs)
        PlayerArtworkBackdropContent(url: url, fallbackTint: fallbackTint, style: style, inputs: inputs,
                                     resolution: resolution, meter: meter, meterAvailable: meterAvailable, driver: driver)
            .id(identity)
            .onAppear { isOnScreen = true }
            .onDisappear {
                isOnScreen = false
                setMetering(false)
            }
            .onChange(of: wantsMeter, initial: true) { _, wants in setMetering(wants) }
            .onChange(of: resolution, initial: true) { _, resolution in
                // React to Music reports from its frames, where tap availability is known.
                if resolution.effect != .reactive { driver.report(style: style, resolution) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)
                .merge(with: NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification))
                .receive(on: RunLoop.main)) { _ in
                    lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
                    thermalPressure = Self.thermalPressure()
                }
    }

    private nonisolated static func thermalPressure() -> Bool {
        let state = ProcessInfo.processInfo.thermalState
        return state == .serious || state == .critical
    }
}

@MainActor
private struct PlayerArtworkBackdropContent: View {
    let url: URL?
    let fallbackTint: Color
    let style: PlayerBackgroundMotion
    let inputs: PlayerBackdropMotionPolicy.Inputs
    let resolution: PlayerBackdropMotionPolicy.Resolution
    let meter: PlaybackLevelMeter
    let meterAvailable: @MainActor () -> Bool
    let driver: PlayerBackdropMotionDriver

    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var state = ArtworkBackdropState()

    private var isMotion: Bool { resolution.effect != .static }

    var body: some View {
        Group {
            if isMotion {
                PlayerMotionBackdropSurface(artwork: state.displayed, fallbackTint: fallbackTint, style: style,
                                            inputs: inputs, resolution: resolution, meter: meter,
                                            meterAvailable: meterAvailable, driver: driver)
            } else {
                ArtworkBackdropSurface(artwork: state.displayed, fallbackTint: fallbackTint, reduceMotion: reduceMotion,
                                       reduceTransparency: reduceTransparency, increaseContrast: colorSchemeContrast == .increased)
            }
        }
        .task(id: url) {
            guard let request = state.begin(url) else { return }
            defer { state.cancel(request) }
            let loaded = await ArtworkLoader.shared.image(for: request.url, tier: .standard, maxPixels: 300)
            state.complete(loaded, for: request)
        }
        .onDisappear { state.cancel() }
    }
}

@MainActor
private struct PlayerMotionBackdropSurface: View {
    let artwork: ArtworkBackdropState.Artwork?
    let fallbackTint: Color
    let style: PlayerBackgroundMotion
    let inputs: PlayerBackdropMotionPolicy.Inputs
    let resolution: PlayerBackdropMotionPolicy.Resolution
    let meter: PlaybackLevelMeter
    let meterAvailable: @MainActor () -> Bool
    let driver: PlayerBackdropMotionDriver
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // Tones are computed once per cover or appearance change, never inside the frame closure.
        let palette = artwork?.palette ?? .tinted(fallbackTint)
        let mesh = PlayerBackdropMesh(palette: palette, fallback: .tinted(fallbackTint), dark: colorScheme == .dark)
        ZStack {
            AppTheme.background
            TimelineView(.animation(minimumInterval: PlayerBackdropMotionPolicy.frameInterval(for: resolution.effect),
                                    paused: !resolution.animates)) { context in
                let frame = currentFrame(at: context.date)
                MeshGradient(width: PlayerBackdropMesh.width, height: PlayerBackdropMesh.height, points: frame.points,
                             colors: mesh.colors(energy: frame.energy, cycle: frame.cycle).map(\.color))
            }
            .id(artwork?.url)
            .transition(.opacity)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .animation(.easeInOut(duration: 0.6), value: artwork?.url)
    }

    private func currentFrame(at date: Date) -> PlayerBackdropMesh.Frame {
        var effect = resolution.effect
        if effect == .reactive {
            var resolved = inputs
            resolved.levelMeterAvailable = meterAvailable()
            let final = PlayerBackdropMotionPolicy.resolve(resolved)
            driver.report(style: style, final)
            effect = final.effect
        }
        driver.advance(to: date, animates: resolution.animates, reading: effect == .reactive ? meter.read() : nil)
        return PlayerBackdropMesh.frame(effect: effect, phase: driver.phase, intensity: driver.intensity)
    }
}

/// Says why the chosen style is held still, so a static player never looks like a broken setting.
@MainActor
struct PlayerBackgroundHoldNote: View {
    let style: PlayerBackgroundMotion

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var thermalPressure = PlayerBackgroundHoldNote.thermalPressure()

    nonisolated static func message(for reason: PlayerBackdropMotionPolicy.Reason) -> String? {
        switch reason {
        case .reduceMotion: "Reduce Motion is on, so the player background stays still."
        case .reduceTransparency: "Reduce Transparency or Increase Contrast is on, so the player background stays still."
        case .lowPower: "Low Power Mode is on, so the player background stays still."
        case .thermal: "This device is warm, so the player background is paused until it cools down."
        case .none, .noTap: nil
        }
    }

    var body: some View {
        let inputs = PlayerBackdropMotionPolicy.Inputs(style: style, reduceMotion: reduceMotion,
                                                       flatBackdrop: reduceTransparency || colorSchemeContrast == .increased,
                                                       lowPower: lowPower, thermalPressure: thermalPressure)
        Group {
            if let message = Self.message(for: PlayerBackdropMotionPolicy.resolve(inputs).reason) {
                Text(message).accessibilityIdentifier("settings.playerBackground.hold")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)
            .merge(with: NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification))
            .receive(on: RunLoop.main)) { _ in
                lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
                thermalPressure = Self.thermalPressure()
            }
    }

    private nonisolated static func thermalPressure() -> Bool {
        let state = ProcessInfo.processInfo.thermalState
        return state == .serious || state == .critical
    }
}


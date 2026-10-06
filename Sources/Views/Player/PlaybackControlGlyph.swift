import SwiftUI

/// The play, pause or retry glyph shared by the full player and the mini player. State changes morph through the
/// platform symbol replace; while loading the glyph pulses and one thin arc orbits inside `arcDiameter`, so the
/// button keeps its shape instead of swapping to a spinner. Reduce Motion keeps the pulse and drops the morph and arc.
struct PlaybackControlGlyph: View {
    let symbol: String
    let isLoading: Bool
    let font: Font
    let arcDiameter: CGFloat
    let arcLineWidth: CGFloat
    let arcColor: Color
    /// Optical nudge for the asymmetric play triangle; pause and retry sit on the geometric centre.
    var playOffset: CGFloat = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if isLoading && !reduceMotion {
                LoadingArc(diameter: arcDiameter, lineWidth: arcLineWidth, color: arcColor)
                    .transition(.opacity)
            }
            Image(systemName: symbol)
                .font(font)
                .offset(x: symbol == "play.fill" ? playOffset : 0)
                .contentTransition(.symbolEffect(.replace.downUp.byLayer))
                .symbolEffect(.pulse, options: .repeating, isActive: isLoading)
                .animation(reduceMotion ? nil : .snappy(duration: 0.15, extraBounce: 0), value: symbol)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isLoading)
    }
}

/// A constant one-turn-per-second arc; linear because the motion is continuous, not a transition.
private struct LoadingArc: View {
    let diameter: CGFloat
    let lineWidth: CGFloat
    let color: Color

    var body: some View {
        KeyframeAnimator(initialValue: 0.0, repeating: true) { angle in
            Circle()
                .trim(from: 0, to: 0.3)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .frame(width: diameter, height: diameter)
                .rotationEffect(.degrees(angle))
        } keyframes: { _ in
            LinearKeyframe(360.0, duration: 1)
        }
        .accessibilityHidden(true)
    }
}

extension View {
    /// The current-song badge: the waveform's layers light up in turn while playing and hold still when paused
    /// or under Reduce Motion, so the paused glyph alone still tells the state.
    func nowPlayingMotion(isPlaying: Bool) -> some View {
        modifier(NowPlayingMotion(isPlaying: isPlaying))
    }
}

private struct NowPlayingMotion: ViewModifier {
    let isPlaying: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.symbolEffect(.variableColor.iterative.dimInactiveLayers, options: .repeating, isActive: isPlaying && !reduceMotion)
    }
}

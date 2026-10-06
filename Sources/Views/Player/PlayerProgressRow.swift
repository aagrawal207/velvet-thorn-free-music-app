import SwiftUI
import UIKit

/// Bar geometry shared by the drawing, the touch mapping and the unit tests: touches map linearly across the whole
/// row width, while the stroke keeps its round caps inside the row.
enum PlayerProgressBar {
    static let lineWidth: CGFloat = 3.5
    /// Layout height of the row; the seek target is taller and overhangs it evenly.
    static let rowHeight: CGFloat = 32
    static let hitHeight: CGFloat = 44
    static let markerDiameter: CGFloat = 10

    /// Progress for a touch at `x` in row coordinates, clamped to the row.
    static func progress(atX x: CGFloat, width: CGFloat) -> CGFloat {
        guard x.isFinite, width.isFinite, width > 0 else { return 0 }
        return clamp(x / width)
    }

    /// Inverse of `progress(atX:width:)`.
    static func x(forProgress progress: CGFloat, width: CGFloat) -> CGFloat {
        guard width.isFinite, width > 0 else { return 0 }
        return clamp(progress) * width
    }

    /// Leading edge of the accent stroke for `progress`, along the inset stroke path.
    static func strokeX(forProgress progress: CGFloat, width: CGFloat) -> CGFloat {
        let start = strokeStart(width: width)
        return start + clamp(progress) * (strokeEnd(width: width) - start)
    }

    static func strokeStart(width: CGFloat) -> CGFloat {
        guard width.isFinite, width > 0 else { return 0 }
        return min(lineWidth / 2, width / 2)
    }

    static func strokeEnd(width: CGFloat) -> CGFloat {
        guard width.isFinite, width > 0 else { return 0 }
        return max(strokeStart(width: width), width - lineWidth / 2)
    }

    static func clamp(_ value: CGFloat) -> CGFloat {
        value.isFinite ? min(max(value, 0), 1) : 0
    }
}

/// Full-width progress bar: a 3.5-point track with the accent progress on top and a marker while scrubbing.
@MainActor
struct PlayerProgressRow: View {
    @Environment(\.colorSchemeContrast) private var contrast
    let position: TimeInterval
    let duration: TimeInterval
    let isScrubbing: Bool
    let onEditingChanged: (Bool, TimeInterval) -> Void
    let onValueChanged: (TimeInterval) -> Void
    let onCancel: () -> Void
    let onAccessibilitySeek: (TimeInterval) -> Void

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let progress = duration > 0 ? PlayerProgressBar.clamp(position / duration) : 0
            seekArea(size: size, progress: progress)
                .overlay(alignment: .topLeading) {
                    if isScrubbing {
                        Circle()
                            .fill(AppTheme.primaryText)
                            .overlay(Circle().strokeBorder(AppTheme.accent, lineWidth: 1.5))
                            .frame(width: PlayerProgressBar.markerDiameter, height: PlayerProgressBar.markerDiameter)
                            .position(x: PlayerProgressBar.strokeX(forProgress: progress, width: size.width), y: size.height / 2)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
        }
        // The visible row is shorter; the target overhangs it evenly so a thumb still lands on the bar.
        .frame(height: PlayerProgressBar.hitHeight)
    }

    private var stroke: StrokeStyle {
        StrokeStyle(lineWidth: PlayerProgressBar.lineWidth, lineCap: .round, lineJoin: .round)
    }

    private var trackColor: Color {
        AppTheme.artworkSecondaryText.opacity(contrast == .increased ? 0.6 : 0.35)
    }

    private func barPath(to x: CGFloat, in size: CGSize) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: PlayerProgressBar.strokeStart(width: size.width), y: size.height / 2))
        path.addLine(to: CGPoint(x: x, y: size.height / 2))
        return path
    }

    private func seekArea(size: CGSize, progress: CGFloat) -> some View {
        let width = size.width
        return ZStack {
            barPath(to: PlayerProgressBar.strokeEnd(width: width), in: size).stroke(trackColor, style: stroke)
            barPath(to: PlayerProgressBar.strokeX(forProgress: progress, width: width), in: size).stroke(AppTheme.accent, style: stroke)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(PlayerSeekPanGesture(
            onChanged: { x in
                guard duration > 0, x.isFinite else { return }
                onEditingChanged(true, position)
                onValueChanged(duration * PlayerProgressBar.progress(atX: x, width: width))
            },
            onEnded: { x in
                guard duration > 0, x.isFinite else {
                    onCancel()
                    return
                }
                onEditingChanged(false, duration * PlayerProgressBar.progress(atX: x, width: width))
            },
            onCancel: onCancel
        ))
        .onTapGesture { location in
            guard duration > 0 else { return }
            onEditingChanged(true, position)
            onEditingChanged(false, duration * PlayerProgressBar.progress(atX: location.x, width: width))
        }
        .opacity(duration > 0 ? 1 : 0.45)
        .accessibilityRepresentation {
            // Accessibility adjustments seek explicitly; layout must not write back to the player.
            Slider(value: .constant(position), in: 0...max(duration, 1)) {
                Text("Playback position").appFont(.body)
            }
            .frame(minHeight: 44)
            .accessibilityValue("\(TimeText.duration(position)) of \(duration > 0 ? TimeText.duration(duration) : "unknown duration")")
            .accessibilityIdentifier("player.seek")
            .accessibilityAdjustableAction { direction in
                guard duration > 0 else { return }
                switch direction {
                case .increment: onAccessibilitySeek(min(position + 10, duration))
                case .decrement: onAccessibilitySeek(max(position - 10, 0))
                @unknown default: break
                }
            }
            .disabled(duration <= 0)
        }
        .disabled(duration <= 0)
    }
}

@MainActor
private struct PlayerSeekPanGesture: UIGestureRecognizerRepresentable {
    let onChanged: (CGFloat) -> Void
    let onEnded: (CGFloat) -> Void
    let onCancel: () -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.maximumNumberOfTouches = 1
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        switch recognizer.state {
        case .began, .changed: onChanged(context.converter.localLocation.x)
        case .ended: onEnded(context.converter.localLocation.x)
        case .cancelled, .failed: onCancel()
        case .possible: break
        @unknown default: onCancel()
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let translation = pan.translation(in: pan.view?.window)
            // Only deliberate horizontal pans should change the playback position.
            return abs(translation.x) > abs(translation.y)
        }
    }
}

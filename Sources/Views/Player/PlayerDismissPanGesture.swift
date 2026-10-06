import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

@MainActor
struct PlayerDismissPanGesture: UIGestureRecognizerRepresentable {
    let isEnabled: Bool
    let onChanged: (CGFloat) -> Void
    let onEnded: (CGFloat, CGPoint) -> Void
    let onCancel: () -> Void

    func makeUIGestureRecognizer(context: Context) -> PlayerDismissPanRecognizer {
        let recognizer = PlayerDismissPanRecognizer()
        recognizer.maximumNumberOfTouches = 1
        recognizer.cancelsTouchesInView = true
        recognizer.delaysTouchesEnded = false
        recognizer.delegate = context.coordinator
        recognizer.isEnabled = isEnabled
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: PlayerDismissPanRecognizer, context: Context) {
        if recognizer.isEnabled != isEnabled { recognizer.isEnabled = isEnabled }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func handleUIGestureRecognizerAction(_ recognizer: PlayerDismissPanRecognizer, context: Context) {
        // Window coordinates stay fixed while the player follows the finger.
        let translation = recognizer.translation(in: recognizer.view?.window)
        switch recognizer.state {
        case .began, .changed:
            recognizer.captureFlickVelocity()
            onChanged(translation.y)
        case .ended: onEnded(translation.y, recognizer.releaseVelocity)
        case .cancelled, .failed: onCancel()
        case .possible: break
        @unknown default: onCancel()
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let translation = pan.translation(in: pan.view?.window)
            // Lock direction by travel, so slow drags work and horizontal seeks stay horizontal.
            return abs(translation.y) > abs(translation.x) * 1.15
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

/// An upward pan over the artwork or heading, installed on the player's hosting view so a swipe that starts on the
/// heart or artist line is seen before their presses claim the touch; it acts only once the finger lifts.
@MainActor
struct PlayerSwipeUpRegion: UIViewRepresentable {
    static let minimumDistance: CGFloat = 60
    static let minimumFlickVelocity: CGFloat = 900
    let isEnabled: Bool
    let onSwipeUp: () -> Void

    func makeUIView(context: Context) -> RegionView { RegionView() }

    func updateUIView(_ uiView: RegionView, context: Context) {
        uiView.onSwipeUp = onSwipeUp
        uiView.isSwipeEnabled = isEnabled
    }

    static func dismantleUIView(_ uiView: RegionView, coordinator: ()) {
        uiView.uninstall(releasingTarget: true)
    }

    static func qualifies(translation: CGPoint, velocity: CGPoint) -> Bool {
        guard abs(translation.x) < abs(translation.y), translation.y < 0 else { return false }
        return translation.y <= -minimumDistance || (velocity.y <= -minimumFlickVelocity && abs(velocity.x) < abs(velocity.y))
    }

    @MainActor
    final class RegionView: UIView, UIGestureRecognizerDelegate {
        var onSwipeUp: () -> Void = {}
        var isSwipeEnabled = true {
            didSet { recognizer.isEnabled = isSwipeEnabled }
        }
        private lazy var recognizer: UIPanGestureRecognizer = {
            let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handle(_:)))
            recognizer.maximumNumberOfTouches = 1
            recognizer.delaysTouchesEnded = false
            recognizer.delegate = self
            recognizer.isEnabled = isSwipeEnabled
            return recognizer
        }()

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isAccessibilityElement = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        /// Touches over the region belong to the SwiftUI content; the recognizer sees them through the hosting view.
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            uninstall()
            guard window != nil, let host = hostingView else { return }
            host.addGestureRecognizer(recognizer)
        }

        func uninstall(releasingTarget: Bool = false) {
            recognizer.view?.removeGestureRecognizer(recognizer)
            // The recognizer outlives the region only through the host; dropping the target ends the pair for good.
            if releasingTarget { recognizer.removeTarget(nil, action: nil) }
        }

        /// The nearest view controller's view: the cover's hosting view, which receives the touches for every
        /// SwiftUI control on the player and none of the touches inside a presented sheet.
        private var hostingView: UIView? {
            var responder: UIResponder? = next
            while let current = responder {
                if let controller = current as? UIViewController { return controller.view }
                responder = current.next
            }
            return nil
        }

        @objc private func handle(_ recognizer: UIPanGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            let translation = recognizer.translation(in: window)
            let velocity = recognizer.velocity(in: window)
            guard PlayerSwipeUpRegion.qualifies(translation: translation, velocity: velocity) else { return }
            onSwipeUp()
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            bounds.contains(touch.location(in: self))
        }

        // UIView already declares this hook for its own recognizers; the delegate call for the hosted pan lands here too.
        override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let translation = pan.translation(in: window)
            return translation.y < 0 && abs(translation.y) > abs(translation.x) * 1.15
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

@MainActor
final class PlayerDismissPanRecognizer: UIPanGestureRecognizer {
    static let minimumFlickDistance: CGFloat = 24
    static let minimumFlickVelocity: CGFloat = 550
    private var origin: CGPoint?
    private var velocitySample: (point: CGPoint, time: TimeInterval)?
    private var recentFlick: (velocity: CGPoint, time: TimeInterval)?
    private var maximumTravel: CGFloat = 0
    private var currentTravel: CGFloat = 0
    private var latestTouchTime: TimeInterval = 0
    private var lastForwardTime: TimeInterval = 0

    var releaseVelocity: CGPoint {
        let current = velocity(in: view?.window)
        guard current.y > -Self.minimumFlickVelocity else { return current }
        // Release may report zero speed; retain actual recent motion, but expire a held or reversed flick.
        guard let recentFlick, latestTouchTime - recentFlick.time <= 0.2 else {
            return CGPoint(x: current.x, y: min(current.y, 0))
        }
        return recentFlick.velocity
    }

    func captureFlickVelocity() {
        guard lastForwardTime == latestTouchTime else { return }
        qualifyFlick(velocity(in: view?.window), at: latestTouchTime)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        if let touch = touches.first {
            let point = touch.location(in: view?.window)
            origin = point
            velocitySample = (point, touch.timestamp)
            maximumTravel = 0
            currentTravel = 0
            latestTouchTime = touch.timestamp
            lastForwardTime = 0
            recentFlick = nil
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if let touch = touches.first {
            for sample in event.coalescedTouches(for: touch) ?? [touch] { record(sample) }
            record(touch)
        }
        super.touchesMoved(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if let touch = touches.first { record(touch) }
        super.touchesEnded(touches, with: event)
    }

    override func reset() {
        super.reset()
        origin = nil
        velocitySample = nil
        recentFlick = nil
        maximumTravel = 0
        currentTravel = 0
        latestTouchTime = 0
        lastForwardTime = 0
    }

    private func record(_ touch: UITouch) {
        guard let origin, touch.timestamp >= latestTouchTime else { return }
        let point = touch.location(in: view?.window)
        latestTouchTime = touch.timestamp
        if point.y - origin.y > currentTravel { lastForwardTime = touch.timestamp }
        currentTravel = point.y - origin.y
        if currentTravel <= maximumTravel - 8 {
            recentFlick = nil
            maximumTravel = currentTravel
        } else {
            maximumTravel = max(maximumTravel, currentTravel)
        }
        guard let previous = velocitySample, touch.timestamp > previous.time else { return }
        let delta = CGPoint(x: point.x - previous.point.x, y: point.y - previous.point.y)
        if delta == .zero {
            velocitySample = (point, touch.timestamp)
        } else if max(abs(delta.x), abs(delta.y)) >= 4 {
            let duration = CGFloat(touch.timestamp - previous.time)
            // Touch timestamps survive main-thread delays; callback arrival times do not measure finger speed.
            qualifyFlick(CGPoint(x: delta.x / duration, y: delta.y / duration), at: touch.timestamp)
            velocitySample = (point, touch.timestamp)
        }
    }

    private func qualifyFlick(_ velocity: CGPoint, at time: TimeInterval) {
        if velocity.y <= -Self.minimumFlickVelocity { recentFlick = nil }
        guard currentTravel >= Self.minimumFlickDistance,
              velocity.y >= Self.minimumFlickVelocity, velocity.y > abs(velocity.x) else { return }
        recentFlick = (velocity, time)
    }
}

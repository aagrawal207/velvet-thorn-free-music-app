import AVKit
import SwiftUI
import UIKit

/// The visible AVKit button owns route presentation and the iPad popover anchor.
@MainActor
final class PlayerAirPlayTrigger: NSObject, @MainActor AVRoutePickerViewDelegate {
    var onPresentationChanged: (Bool) -> Void = { _ in }
    /// AVKit draws its glyph as an 18-point layer, not a symbol image; scaling the button's sublayers brings it to
    /// the 20-point Lyrics and Queue symbols while every view frame, and so every accessibility frame, stays put.
    static let glyphScale: CGFloat = 1.15

    func attach(to picker: AVRoutePickerView) {
        picker.delegate = self
        picker.layoutIfNeeded()
        guard let button = Self.button(in: picker) else { return }
        button.accessibilityLabel = "AirPlay and audio output"
        button.accessibilityIdentifier = "player.airplay"
        let scale = CATransform3DMakeScale(Self.glyphScale, Self.glyphScale, 1)
        if !CATransform3DEqualToTransform(button.layer.sublayerTransform, scale) {
            button.layer.sublayerTransform = scale
        }
    }

    func routePickerViewWillBeginPresentingRoutes(_ routePickerView: AVRoutePickerView) {
        onPresentationChanged(true)
    }

    func routePickerViewDidEndPresentingRoutes(_ routePickerView: AVRoutePickerView) {
        onPresentationChanged(false)
    }

    private static func button(in view: UIView) -> UIButton? {
        for subview in view.subviews {
            if let button = subview as? UIButton { return button }
            if let nested = button(in: subview) { return nested }
        }
        return nil
    }
}

@MainActor
struct PlayerAirPlayPicker: UIViewRepresentable {
    let accentColor: Color
    let onPresentationChanged: (Bool) -> Void

    func makeCoordinator() -> PlayerAirPlayTrigger { PlayerAirPlayTrigger() }

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        // Audio-only: a TV is an AirPlay audio route here, since `PlaybackAudioRoute.makePlayer()` forbids URL handoff.
        view.prioritizesVideoDevices = false
        view.backgroundColor = .clear
        view.accessibilityIdentifier = "player.airplay.anchor"
        updateUIView(view, context: context)
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.tintColor = UIColor(AppTheme.artworkSecondaryText)
        uiView.activeTintColor = UIColor(accentColor)
        context.coordinator.onPresentationChanged = onPresentationChanged
        context.coordinator.attach(to: uiView)
    }

    static func dismantleUIView(_ uiView: AVRoutePickerView, coordinator: PlayerAirPlayTrigger) {
        uiView.delegate = nil
    }
}

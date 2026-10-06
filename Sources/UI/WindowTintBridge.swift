import SwiftUI
import UIKit

/// UIKit alerts, confirmation dialogs, menus and share sheets take their tint from the window, not from SwiftUI.
struct WindowTintBridge: UIViewRepresentable {
    let color: UIColor

    func makeUIView(context: Context) -> TintView {
        let view = TintView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ uiView: TintView, context: Context) {
        uiView.color = color
    }

    final class TintView: UIView {
        var color: UIColor? { didSet { apply() } }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            apply()
        }

        private func apply() {
            guard let window, let color, window.tintColor != color else { return }
            window.tintColor = color
        }
    }
}

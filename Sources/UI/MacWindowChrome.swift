import SwiftUI
import UIKit

/// Mac window sizing and title bar; a no-op on iPhone and iPad.
struct MacWindowChrome: UIViewRepresentable {
    static let minimumSize = CGSize(width: 820, height: 620)

    func makeUIView(context: Context) -> ChromeView {
        let view = ChromeView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ uiView: ChromeView, context: Context) {}

    final class ChromeView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            #if targetEnvironment(macCatalyst)
            guard let scene = window?.windowScene else { return }
            scene.sizeRestrictions?.minimumSize = MacWindowChrome.minimumSize
            // The sidebar and each page already name the place; a repeated window title only takes height.
            scene.titlebar?.titleVisibility = .hidden
            scene.titlebar?.toolbarStyle = .unified
            #endif
        }
    }
}

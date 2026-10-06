import SwiftUI
import UIKit

extension EnvironmentValues {
    /// Height of the floating mini-player in this tab, zero while it is hidden.
    @Entry var miniPlayerClearance: CGFloat = 0
}

extension View {
    /// For a NavigationStack's root page: lends the mini-player's height to the stack's navigation controller, whose
    /// safe area every page inherits, including pages pushed later.
    func miniPlayerClearanceProbe() -> some View {
        modifier(MiniPlayerClearanceProbe())
    }
}

private struct MiniPlayerClearanceProbe: ViewModifier {
    @Environment(\.miniPlayerClearance) private var clearance

    func body(content: Content) -> some View {
        content.background {
            NavigationControllerBottomInset(height: clearance)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }
}

/// UIKit owns the navigation stack's safe area; setting it there reaches the root and every pushed page alike.
private struct NavigationControllerBottomInset: UIViewControllerRepresentable {
    let height: CGFloat

    func makeUIViewController(context: Context) -> Probe { Probe() }

    func updateUIViewController(_ probe: Probe, context: Context) {
        probe.height = height
    }

    final class Probe: UIViewController {
        var height: CGFloat = 0 {
            didSet { if oldValue != height { apply() } }
        }

        override func loadView() {
            let view = UIView()
            view.isUserInteractionEnabled = false
            view.isHidden = true
            self.view = view
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            apply()
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            apply()
        }

        private func apply() {
            // Sheets opened from a tab inherit the clearance, but nothing floats over them.
            guard let navigation = navigationController, navigation.presentingViewController == nil,
                  navigation.additionalSafeAreaInsets.bottom != height else { return }
            navigation.additionalSafeAreaInsets.bottom = height
        }
    }
}

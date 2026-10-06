import SwiftUI
import UIKit

@MainActor
final class TVLyricsSceneDelegate: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?
    private let connectionID = UUID()

    nonisolated override init() { super.init() }

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard session.role == .windowExternalDisplayNonInteractive,
              let windowScene = scene as? UIWindowScene else { return }
        let runtime = TVLyricsRuntime.shared
        runtime.connect(connectionID, active: scene.activationState == .foregroundActive)
        let window = UIWindow(windowScene: windowScene)
        window.backgroundColor = .black
        let host = UIHostingController(rootView: TVLyricsExternalRoot(runtime: runtime, connectionID: connectionID))
        host.view.backgroundColor = .black
        window.rootViewController = host
        self.window = window
        window.isHidden = false
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        TVLyricsRuntime.shared.setActive(connectionID, active: true)
    }

    func sceneWillResignActive(_ scene: UIScene) {
        TVLyricsRuntime.shared.setActive(connectionID, active: false)
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        TVLyricsRuntime.shared.setActive(connectionID, active: false)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        TVLyricsRuntime.shared.disconnect(connectionID)
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
    }
}

private struct TVLyricsExternalRoot: View {
    let runtime: TVLyricsRuntime
    let connectionID: UUID

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let controller = runtime.controller, controller.canDisplayOnExternalScene(connectionID) {
                TVLyricsView(controller: controller, surface: .externalDisplay)
            }
        }
        .preferredColorScheme(.dark)
    }
}

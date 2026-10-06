import Observation
import SwiftUI
import UIKit

@MainActor @Observable
final class TVLyricsRuntime {
    static let shared = TVLyricsRuntime()
    private(set) var controller: TVLyricsController?
    @ObservationIgnored private var scenes: [UUID: Bool] = [:]

    func install(_ controller: TVLyricsController) {
        guard self.controller !== controller else { return }
        retireController()
        self.controller = controller
        for (id, active) in scenes { controller.connectExternalScene(id, active: active) }
    }

    func uninstall() {
        retireController()
        controller = nil
    }

    func connect(_ id: UUID, active: Bool) {
        scenes[id] = active
        controller?.connectExternalScene(id, active: active)
    }

    func setActive(_ id: UUID, active: Bool) {
        guard scenes[id] != nil else { return }
        scenes[id] = active
        controller?.setExternalSceneActive(id, active: active)
    }

    func disconnect(_ id: UUID) {
        scenes.removeValue(forKey: id)
        controller?.disconnectExternalScene(id)
    }

    private func retireController() {
        controller?.stop(reason: .runtimeReplaced)
        for id in scenes.keys { controller?.disconnectExternalScene(id) }
    }
}

@MainActor
enum TVLyricsSceneConfiguration {
    static let name = "TV Lyrics"

    static func configuration(for role: UISceneSession.Role) -> UISceneConfiguration? {
        guard role == .windowExternalDisplayNonInteractive else { return nil }
        let configuration = UISceneConfiguration(name: name, sessionRole: role)
        configuration.sceneClass = UIWindowScene.self
        configuration.delegateClass = TVLyricsSceneDelegate.self
        return configuration
    }
}

/// Install on the phone window so an active external scene cannot mask the phone's suspension.
struct TVLyricsPhoneLifecycle: ViewModifier {
    let controller: TVLyricsController
    @Environment(\.scenePhase) private var phase

    func body(content: Content) -> some View {
        content
            .onChange(of: phase, initial: true) { _, phase in
                controller.setPhoneSceneActive(phase == .active)
                if phase == .background { controller.stop(reason: .suspended) }
            }
    }
}

import CarPlay
import UIKit

@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var session: CarPlaySessionController?
    private weak var connectedInterface: CPInterfaceController?

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        session?.disconnect()
        connectedInterface = interfaceController
        let session = CarPlaySessionController(interface: CarPlayNativeInterface(interfaceController))
        self.session = session
        session.connect()
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        guard connectedInterface === interfaceController else { return }
        session?.disconnect()
        session = nil
        connectedInterface = nil
    }
}

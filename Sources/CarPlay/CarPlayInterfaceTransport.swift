import CarPlay
import Foundation

@MainActor
protocol CarPlayInterfaceTransport: AnyObject {
    var delegate: (any CPInterfaceControllerDelegate)? { get set }
    var templates: [CPTemplate] { get }
    var topTemplate: CPTemplate? { get }

    func setRoot(_ template: CPTemplate, completion: @escaping CarPlayInterfaceCompletion)
    func push(_ template: CPTemplate, completion: @escaping CarPlayInterfaceCompletion)
    func pop(to template: CPTemplate, completion: @escaping CarPlayInterfaceCompletion)
    func popToRoot(completion: @escaping CarPlayInterfaceCompletion)
}

typealias CarPlayInterfaceCompletion = @MainActor @Sendable (Bool, String?) -> Void

@MainActor
final class CarPlayNativeInterface: CarPlayInterfaceTransport {
    let controller: CPInterfaceController

    init(_ controller: CPInterfaceController) { self.controller = controller }

    var delegate: (any CPInterfaceControllerDelegate)? {
        get { controller.delegate }
        set { controller.delegate = newValue }
    }

    var templates: [CPTemplate] { controller.templates }
    var topTemplate: CPTemplate? { controller.topTemplate }

    func setRoot(_ template: CPTemplate, completion: @escaping CarPlayInterfaceCompletion) {
        controller.setRootTemplate(template, animated: false, completion: Self.callback(completion))
    }

    func push(_ template: CPTemplate, completion: @escaping CarPlayInterfaceCompletion) {
        controller.pushTemplate(template, animated: true, completion: Self.callback(completion))
    }

    func pop(to template: CPTemplate, completion: @escaping CarPlayInterfaceCompletion) {
        controller.pop(to: template, animated: true, completion: Self.callback(completion))
    }

    func popToRoot(completion: @escaping CarPlayInterfaceCompletion) {
        controller.popToRootTemplate(animated: true, completion: Self.callback(completion))
    }

    nonisolated static func callback(_ completion: @escaping CarPlayInterfaceCompletion) -> @Sendable (Bool, Error?) -> Void {
        // Unlike list selections, interface completion blocks have no documented main-queue guarantee.
        { @Sendable success, error in
            let message = error?.localizedDescription
            Task { @MainActor in completion(success, message) }
        }
    }
}

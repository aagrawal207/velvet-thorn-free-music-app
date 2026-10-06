import CarPlay
import Foundation

@MainActor
final class CarPlayTemplateNavigator {
    static let maximumDepth = 5

    private struct Destination: Sendable {
        let id = UUID()
        let template: CPTemplate
        let onFailure: @MainActor @Sendable (String) -> Void
    }

    private let interface: any CarPlayInterfaceTransport
    private var generation = UUID()
    private var operation: UUID?
    private var destination: Destination?
    private var rootIsReady = false
    private(set) var isConnected = false
    var isChangingTemplates: Bool { operation != nil }

    init(interface: any CarPlayInterfaceTransport) { self.interface = interface }

    func installRoot(_ template: CPTemplate, onFailure: @escaping @MainActor @Sendable (String) -> Void) {
        generation = UUID()
        isConnected = true
        rootIsReady = false
        destination = nil
        let connection = generation
        let work = UUID()
        operation = work
        interface.setRoot(template) { [weak self] success, message in
            guard let self, self.isConnected, self.generation == connection, self.operation == work else { return }
            self.operation = nil
            self.rootIsReady = success
            if success { self.advance() }
            else { onFailure(message ?? "CarPlay couldn’t open Velvet Thorn.") }
        }
    }

    func show(_ template: CPTemplate, onFailure: @escaping @MainActor @Sendable (String) -> Void) {
        guard isConnected else { return }
        destination = Destination(template: template, onFailure: onFailure)
        advance()
    }

    func userChangedNavigation() {
        destination = nil
    }

    func disconnect() {
        isConnected = false
        generation = UUID()
        operation = nil
        destination = nil
        rootIsReady = false
    }

    private func advance() {
        guard isConnected, rootIsReady, operation == nil, let destination else { return }
        if interface.topTemplate === destination.template {
            self.destination = nil
            return
        }
        let stack = interface.templates
        if stack.contains(where: { $0 === destination.template }) {
            perform(destination, finishesDestination: true) { completion in
                interface.pop(to: destination.template, completion: completion)
            }
        } else if stack.count >= Self.maximumDepth {
            // Up Next and playback errors must remain reachable without exceeding CarPlay's stack limit.
            perform(destination, finishesDestination: false) { completion in
                interface.popToRoot(completion: completion)
            }
        } else {
            perform(destination, finishesDestination: true) { completion in
                interface.push(destination.template, completion: completion)
            }
        }
    }

    private func perform(_ target: Destination, finishesDestination: Bool,
                         submit: (@escaping CarPlayInterfaceCompletion) -> Void) {
        let connection = generation
        let work = UUID()
        operation = work
        submit { [weak self] success, message in
            guard let self, self.isConnected, self.generation == connection, self.operation == work else { return }
            self.operation = nil
            if self.destination?.id == target.id {
                if !success {
                    self.destination = nil
                    target.onFailure(message ?? "CarPlay couldn’t open this screen. Try again.")
                } else if finishesDestination {
                    self.destination = nil
                }
            }
            // A native operation already in flight can finish, but only the newest intent continues navigation.
            self.advance()
        }
    }
}

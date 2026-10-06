// CarPlay templates exist only on iPhone; Mac Catalyst links the framework but cannot host its scenes.
#if !targetEnvironment(macCatalyst)
import CarPlay
import Foundation
import XCTest
@testable import GanaBajana

@MainActor
final class CarPlayTestInterface: CarPlayInterfaceTransport {
    enum Operation: Equatable { case root, push, pop, popToRoot }

    private struct Pending {
        let operation: Operation
        let template: CPTemplate?
        let tab: ObjectIdentifier?
        let completion: CarPlayInterfaceCompletion
    }

    weak var delegate: (any CPInterfaceControllerDelegate)?
    var automaticallyCompletes = true
    private(set) var root: CPTemplate?
    private(set) var operations: [Operation] = []
    private(set) var pushed: [CPTemplate] = []
    private(set) var buttonsAtRootInstallation: [Int] = []
    private(set) var upNextAtRootInstallation: [Bool] = []
    private var stacks: [ObjectIdentifier: [CPTemplate]] = [:]
    private var selectedRoot: CPTemplate?
    private var pending: [Pending] = []

    var templates: [CPTemplate] {
        guard let selectedRoot else { return [] }
        return stacks[ObjectIdentifier(selectedRoot)] ?? []
    }
    var topTemplate: CPTemplate? { templates.last }
    var pendingCount: Int { pending.count }

    func setRoot(_ template: CPTemplate, completion: @escaping CarPlayInterfaceCompletion) {
        buttonsAtRootInstallation.append(CPNowPlayingTemplate.shared.nowPlayingButtons.count)
        upNextAtRootInstallation.append(CPNowPlayingTemplate.shared.isUpNextButtonEnabled)
        submit(.root, template: template, completion: completion)
    }

    func push(_ template: CPTemplate, completion: @escaping CarPlayInterfaceCompletion) {
        pushed.append(template)
        submit(.push, template: template, completion: completion)
    }

    func pop(to template: CPTemplate, completion: @escaping CarPlayInterfaceCompletion) {
        submit(.pop, template: template, completion: completion)
    }

    func popToRoot(completion: @escaping CarPlayInterfaceCompletion) {
        submit(.popToRoot, template: nil, completion: completion)
    }

    func completeNext(success: Bool = true, message: String? = nil) throws {
        let call = try XCTUnwrap(pending.first)
        pending.removeFirst()
        if success { apply(call) }
        call.completion(success, message)
    }

    func selectTab(at index: Int) throws {
        let tabs = try XCTUnwrap(root as? CPTabBarTemplate)
        XCTAssertTrue(tabs.templates.indices.contains(index))
        let list = tabs.templates[index]
        selectedRoot = list
        tabs.delegate?.tabBarTemplate(tabs, didSelect: list)
        notifyAppearance()
    }

    func back() {
        guard let selectedRoot, templates.count > 1 else { return }
        stacks[ObjectIdentifier(selectedRoot)] = Array(templates.dropLast())
        notifyAppearance()
    }

    private func submit(_ operation: Operation, template: CPTemplate?, completion: @escaping CarPlayInterfaceCompletion) {
        operations.append(operation)
        let call = Pending(operation: operation, template: template,
                           tab: selectedRoot.map(ObjectIdentifier.init), completion: completion)
        if automaticallyCompletes {
            apply(call)
            completion(true, nil)
        } else {
            pending.append(call)
        }
    }

    private func apply(_ call: Pending) {
        if call.operation == .root, let root = call.template {
            self.root = root
            let roots = (root as? CPTabBarTemplate)?.templates ?? [root]
            stacks = Dictionary(uniqueKeysWithValues: roots.map { (ObjectIdentifier($0), [$0]) })
            selectedRoot = roots.first
            notifyAppearance()
            return
        }
        guard let tab = call.tab, var stack = stacks[tab] else { return }
        switch call.operation {
        case .root: break
        case .push:
            if let template = call.template { stack.append(template) }
        case .pop:
            if let index = stack.firstIndex(where: { $0 === call.template }) { stack = Array(stack.prefix(index + 1)) }
        case .popToRoot: stack = Array(stack.prefix(1))
        }
        stacks[tab] = stack
        if selectedRoot.map(ObjectIdentifier.init) == tab { notifyAppearance() }
    }

    private func notifyAppearance() {
        guard let topTemplate else { return }
        delegate?.templateWillAppear?(topTemplate, animated: false)
        delegate?.templateDidAppear?(topTemplate, animated: false)
    }
}

@MainActor
final class CarPlayCompletionCount {
    var value = 0
}

@MainActor
class CarPlayTestCase: XCTestCase {
    func makeContext(snapshot: PlaybackSnapshot = PlaybackSnapshot(), resolver: (any StreamResolving)? = nil) throws -> AppModelTestContext {
        let context = try AppModelTestContext(snapshot: snapshot, resolver: resolver)
        addTeardownBlock { @MainActor in
            context.model.cancelPendingRadio()
            try await context.close()
        }
        return context
    }

    func makeSession(context: AppModelTestContext, interface: CarPlayTestInterface,
                     limits: CarPlayTemplateLimits = CarPlayTemplateLimits(tabs: 4, items: 200, sections: 1)) -> CarPlaySessionController {
        let playback = CompanionPlaybackController(model: context.model)
        let session = CarPlaySessionController(interface: interface, limits: limits, playbackProvider: { playback })
        addTeardownBlock { @MainActor in session.disconnect() }
        session.connect()
        return session
    }

    func rootList(_ session: CarPlaySessionController, at index: Int) throws -> CPListTemplate {
        let tabs = try XCTUnwrap(session.rootTemplate as? CPTabBarTemplate)
        return try XCTUnwrap(tabs.templates[index] as? CPListTemplate)
    }

    func rows(_ template: CPListTemplate) -> [CPListItem] {
        template.sections.flatMap(\.items).compactMap { $0 as? CPListItem }
    }

    @discardableResult
    func select(_ row: CPListItem, file: StaticString = #filePath, line: UInt = #line) throws -> CarPlayCompletionCount {
        let handler = try XCTUnwrap(row.handler, file: file, line: line)
        let count = CarPlayCompletionCount()
        handler(row) { count.value += 1 }
        XCTAssertEqual(count.value, 1, "List selections must finish synchronously, including errors and retired callbacks.", file: file, line: line)
        return count
    }

    func retryRow(_ list: CPListTemplate) throws -> CPListItem {
        try XCTUnwrap(rows(list).first { $0.text == "Retry" })
    }

    func waitForRows(_ count: Int, in list: CPListTemplate) async throws {
        try await AppModelFixtures.eventually { self.rows(list).count == count }
    }
}
#endif

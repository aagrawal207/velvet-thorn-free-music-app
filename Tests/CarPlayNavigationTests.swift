// CarPlay templates exist only on iPhone; Mac Catalyst links the framework but cannot host its scenes.
#if !targetEnvironment(macCatalyst)
import CarPlay
import XCTest
@testable import GanaBajana

@MainActor
final class CarPlayNavigationTests: CarPlayTestCase {
    func testNewestDestinationWinsWithoutOverlappingInterfaceOperations() throws {
        let interface = CarPlayTestInterface()
        let navigator = CarPlayTemplateNavigator(interface: interface)
        let root = CPListTemplate(title: "Library", sections: [])
        navigator.installRoot(root) { _ in XCTFail("Root should succeed") }
        interface.automaticallyCompletes = false
        let old = CPListTemplate(title: "Old selection", sections: [])
        let new = CPListTemplate(title: "New selection", sections: [])
        navigator.show(old) { _ in XCTFail("Obsolete navigation errors must not replace the latest intent") }
        navigator.show(new) { _ in XCTFail("Latest navigation should succeed") }
        XCTAssertEqual(interface.pendingCount, 1)
        try interface.completeNext(success: false, message: "Old operation failed")
        XCTAssertEqual(interface.pendingCount, 1)
        XCTAssertTrue(interface.pushed.last === new)
        try interface.completeNext()
        XCTAssertTrue(interface.topTemplate === new)
        XCTAssertEqual(interface.pendingCount, 0)
    }

    func testExistingNowPlayingIsPoppedToInsteadOfDuplicated() {
        let interface = CarPlayTestInterface()
        let navigator = CarPlayTemplateNavigator(interface: interface)
        navigator.installRoot(CPListTemplate(title: "Library", sections: [])) { _ in XCTFail() }
        let playing = CPNowPlayingTemplate.shared
        navigator.show(playing) { _ in XCTFail() }
        navigator.show(CPListTemplate(title: "Queue", sections: [])) { _ in XCTFail() }
        navigator.show(playing) { _ in XCTFail() }
        XCTAssertEqual(interface.operations.last, .pop)
        XCTAssertEqual(interface.templates.filter { $0 === playing }.count, 1)
        XCTAssertTrue(interface.topTemplate === playing)
    }

    func testDepthLimitPopsToRootBeforeShowingTheLatestDestination() throws {
        let interface = CarPlayTestInterface()
        let navigator = CarPlayTemplateNavigator(interface: interface)
        navigator.installRoot(CPListTemplate(title: "Library", sections: [])) { _ in XCTFail() }
        for index in 0..<4 {
            navigator.show(CPListTemplate(title: "Page \(index)", sections: [])) { _ in XCTFail() }
        }
        XCTAssertEqual(interface.templates.count, 5)
        interface.automaticallyCompletes = false
        let queue = CPListTemplate(title: "Queue", sections: [])
        navigator.show(queue) { _ in XCTFail() }
        XCTAssertEqual(interface.operations.last, .popToRoot)
        XCTAssertEqual(interface.pendingCount, 1)
        try interface.completeNext()
        XCTAssertEqual(interface.templates.count, 1)
        XCTAssertEqual(interface.operations.last, .push)
        try interface.completeNext()
        XCTAssertEqual(interface.templates.count, 2)
        XCTAssertTrue(interface.topTemplate === queue)
    }

    func testNewIntentDuringDepthResetSupersedesTheOldDestination() throws {
        let interface = CarPlayTestInterface()
        let navigator = CarPlayTemplateNavigator(interface: interface)
        navigator.installRoot(CPListTemplate(title: "Library", sections: [])) { _ in XCTFail() }
        for index in 0..<4 { navigator.show(CPListTemplate(title: "Page \(index)", sections: [])) { _ in XCTFail() } }
        interface.automaticallyCompletes = false
        let abandoned = CPListTemplate(title: "Old queue", sections: [])
        navigator.show(abandoned) { _ in XCTFail() }
        navigator.show(CPNowPlayingTemplate.shared) { _ in XCTFail() }
        try interface.completeNext()
        XCTAssertFalse(interface.pushed.contains { $0 === abandoned })
        try interface.completeNext()
        XCTAssertTrue(interface.topTemplate === CPNowPlayingTemplate.shared)
    }

    func testDisconnectRetiresPendingRootAndNavigationCallbacks() throws {
        let interface = CarPlayTestInterface()
        interface.automaticallyCompletes = false
        let navigator = CarPlayTemplateNavigator(interface: interface)
        navigator.installRoot(CPListTemplate(title: "Library", sections: [])) { _ in XCTFail("Disconnected root callback") }
        navigator.show(CPNowPlayingTemplate.shared) { _ in XCTFail("Disconnected navigation callback") }
        navigator.disconnect()
        try interface.completeNext(success: false, message: "Disconnected")
        XCTAssertEqual(interface.operations, [.root])
        XCTAssertFalse(navigator.isChangingTemplates)

        interface.automaticallyCompletes = true
        navigator.installRoot(CPListTemplate(title: "Reconnected", sections: [])) { _ in XCTFail() }
        interface.automaticallyCompletes = false
        navigator.show(CPNowPlayingTemplate.shared) { _ in XCTFail("Disconnected push callback") }
        navigator.disconnect()
        try interface.completeNext(success: false, message: "Disconnected")
        XCTAssertEqual(interface.pendingCount, 0)
    }

    func testNativeTabSelectionRetiresAnInflightNavigationContinuation() throws {
        let interface = CarPlayTestInterface()
        let navigator = CarPlayTemplateNavigator(interface: interface)
        navigator.installRoot(CPListTemplate(title: "Library", sections: [])) { _ in XCTFail() }
        interface.automaticallyCompletes = false
        navigator.show(CPNowPlayingTemplate.shared) { _ in XCTFail("User already changed tabs") }
        navigator.userChangedNavigation()
        try interface.completeNext(success: false, message: "Obsolete")
        XCTAssertEqual(interface.pendingCount, 0)
        XCTAssertEqual(interface.operations, [.root, .push])
    }

    func testCurrentNavigationFailureIsDeliveredOnce() throws {
        let interface = CarPlayTestInterface()
        let navigator = CarPlayTemplateNavigator(interface: interface)
        navigator.installRoot(CPListTemplate(title: "Library", sections: [])) { _ in XCTFail() }
        interface.automaticallyCompletes = false
        let errors = CarPlayNavigationErrors()
        navigator.show(CPNowPlayingTemplate.shared) { errors.messages.append($0) }
        try interface.completeNext(success: false, message: "Vehicle unavailable")
        XCTAssertEqual(errors.messages, ["Vehicle unavailable"])
        XCTAssertEqual(interface.pendingCount, 0)
    }

    func testNativeCompletionFromABackgroundExecutorIsDeliveredOnMainActor() async throws {
        let result = CarPlayNavigationErrors()
        let callback = CarPlayNativeInterface.callback { success, message in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertFalse(success)
            result.messages.append(message ?? "Missing error")
        }
        await Task.detached {
            callback(false, NSError(domain: "CarPlayTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Vehicle unavailable"]))
        }.value
        try await AppModelFixtures.eventually { !result.messages.isEmpty }
        XCTAssertEqual(result.messages, ["Vehicle unavailable"])
    }
}

@MainActor
private final class CarPlayNavigationErrors {
    var messages: [String] = []
}
#endif

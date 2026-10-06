// CarPlay templates exist only on iPhone; Mac Catalyst links the framework but cannot host its scenes.
#if !targetEnvironment(macCatalyst)
import CarPlay
import XCTest
@testable import GanaBajana

@MainActor
final class CarPlaySceneDelegateTests: XCTestCase {
    func testAudioSceneCallbacksAreAvailableToTheObjectiveCRuntime() {
        let delegate = CarPlaySceneDelegate()
        XCTAssertTrue(delegate.responds(to: NSSelectorFromString("templateApplicationScene:didConnectInterfaceController:")))
        XCTAssertTrue(delegate.responds(to: NSSelectorFromString("templateApplicationScene:didDisconnectInterfaceController:")))
    }
}
#endif

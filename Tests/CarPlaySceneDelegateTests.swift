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

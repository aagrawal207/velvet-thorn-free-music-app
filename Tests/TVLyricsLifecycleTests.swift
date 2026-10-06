import XCTest
import UIKit
@testable import GanaBajana

@MainActor
final class TVLyricsLifecycleTests: XCTestCase {
    func testConnectionAloneNeverOptsInAndOptOutBlanksEveryScene() {
        let playback = TVLyricsTestPlayback()
        let controller = playback.controller()
        let first = UUID(), second = UUID()
        controller.setPhoneSceneActive(true)
        controller.connectExternalScene(first, active: true)
        controller.connectExternalScene(second, active: true)
        XCTAssertTrue(controller.hasExternalDisplay)
        XCTAssertFalse(controller.canDisplayOnExternalScene(first))
        XCTAssertFalse(playback.idleDisabled)
        XCTAssertTrue(controller.start())
        XCTAssertTrue(controller.canDisplayOnExternalScene(first))
        XCTAssertTrue(controller.canDisplayOnExternalScene(second))
        XCTAssertTrue(playback.idleDisabled)
        controller.stop()
        XCTAssertFalse(controller.canDisplayOnExternalScene(first))
        XCTAssertFalse(controller.canDisplayOnExternalScene(second))
        XCTAssertFalse(playback.idleDisabled)
    }

    func testOptInBeforeConnectDisconnectAndReconnectKeepPhonePresentation() {
        let playback = TVLyricsTestPlayback()
        let controller = playback.controller()
        let scene = UUID()
        controller.setPhoneSceneActive(true)
        XCTAssertTrue(controller.start())
        XCTAssertFalse(controller.hasExternalDisplay)
        XCTAssertFalse(playback.idleDisabled)
        controller.phonePresentationVisibilityChanged(true)
        XCTAssertTrue(playback.idleDisabled)
        controller.connectExternalScene(scene, active: true)
        controller.disconnectExternalScene(scene)
        XCTAssertTrue(controller.isPhonePresented)
        XCTAssertTrue(playback.idleDisabled)
        XCTAssertFalse(controller.hasExternalDisplay)
        controller.connectExternalScene(scene, active: false)
        XCTAssertFalse(controller.canDisplayOnExternalScene(scene))
        controller.setExternalSceneActive(scene, active: true)
        XCTAssertTrue(controller.canDisplayOnExternalScene(scene))
        controller.stop()
    }

    func testInactivePhoneBlanksExternalContentAndRestoresIdleTimerUntilForeground() {
        let playback = TVLyricsTestPlayback()
        let controller = playback.controller()
        let scene = UUID()
        controller.connectExternalScene(scene, active: true)
        XCTAssertFalse(controller.start())
        controller.setPhoneSceneActive(true)
        XCTAssertTrue(controller.start())
        controller.setPhoneSceneActive(false)
        XCTAssertFalse(controller.isContentVisible)
        XCTAssertFalse(controller.canDisplayOnExternalScene(scene))
        XCTAssertFalse(playback.idleDisabled)
        XCTAssertTrue(controller.isEnabled)
        controller.setPhoneSceneActive(true)
        XCTAssertTrue(controller.canDisplayOnExternalScene(scene))
        XCTAssertTrue(playback.idleDisabled)
        controller.stop(reason: .suspended)
        controller.setPhoneSceneActive(true)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertFalse(playback.idleDisabled)
    }

    func testInactiveOrDisconnectedLastSurfaceReleasesIdleLease() {
        let playback = TVLyricsTestPlayback()
        let controller = playback.controller()
        let first = UUID(), second = UUID()
        controller.setPhoneSceneActive(true)
        XCTAssertTrue(controller.start())
        controller.connectExternalScene(first, active: true)
        controller.connectExternalScene(second, active: true)
        controller.setExternalSceneActive(first, active: false)
        XCTAssertTrue(playback.idleDisabled)
        controller.disconnectExternalScene(second)
        XCTAssertFalse(playback.idleDisabled)
        controller.phonePresentationVisibilityChanged(true)
        XCTAssertTrue(playback.idleDisabled)
        controller.phonePresentationVisibilityChanged(false)
        XCTAssertFalse(playback.idleDisabled)
        controller.stop()
    }

    func testIdleTimerRestoresOriginalTrueAndDoesNotRecaptureOnRepeatedUpdates() {
        let playback = TVLyricsTestPlayback()
        playback.idleDisabled = true
        let controller = playback.controller()
        controller.setPhoneSceneActive(true)
        XCTAssertTrue(controller.start())
        controller.phonePresentationVisibilityChanged(true)
        controller.phonePresentationVisibilityChanged(true)
        controller.setPhoneSceneActive(true)
        XCTAssertEqual(playback.idleWrites, [true])
        controller.setPhoneSceneActive(false)
        XCTAssertEqual(playback.idleWrites, [true, true])
        controller.stop()
        XCTAssertEqual(playback.idleWrites, [true, true])
        XCTAssertTrue(playback.idleDisabled)
    }

    func testIdleTimerRecapturesPolicyAfterSuspension() {
        let playback = TVLyricsTestPlayback()
        let controller = playback.controller()
        controller.setPhoneSceneActive(true)
        XCTAssertTrue(controller.start())
        controller.phonePresentationVisibilityChanged(true)
        controller.setPhoneSceneActive(false)
        XCTAssertEqual(playback.idleWrites, [true, false])
        playback.idleDisabled = true
        controller.setPhoneSceneActive(true)
        controller.stop()
        XCTAssertEqual(playback.idleWrites, [true, false, true, true])
    }

    func testLateRuntimeInstallReplacementAndUninstallWithConnectedScene() {
        let runtime = TVLyricsRuntime()
        let scene = UUID()
        runtime.connect(scene, active: true)
        let firstPlayback = TVLyricsTestPlayback()
        let first = firstPlayback.controller()
        first.setPhoneSceneActive(true)
        runtime.install(first)
        XCTAssertTrue(first.start())
        XCTAssertTrue(first.canDisplayOnExternalScene(scene))
        let secondPlayback = TVLyricsTestPlayback()
        let second = secondPlayback.controller()
        second.setPhoneSceneActive(true)
        runtime.install(second)
        XCTAssertFalse(first.isEnabled)
        XCTAssertFalse(first.hasExternalDisplay)
        XCTAssertFalse(firstPlayback.idleDisabled)
        XCTAssertTrue(second.hasExternalDisplay)
        XCTAssertFalse(second.canDisplayOnExternalScene(scene))
        XCTAssertTrue(second.start())
        runtime.setActive(scene, active: false)
        XCTAssertFalse(second.canDisplayOnExternalScene(scene))
        runtime.setActive(scene, active: true)
        XCTAssertTrue(second.canDisplayOnExternalScene(scene))
        runtime.uninstall()
        XCTAssertNil(runtime.controller)
        XCTAssertFalse(second.isEnabled)
        XCTAssertFalse(secondPlayback.idleDisabled)
        runtime.disconnect(scene)
    }

    func testOnlyNoninteractiveExternalSceneRoleUsesLyricsDelegate() throws {
        let config = try XCTUnwrap(TVLyricsSceneConfiguration.configuration(for: .windowExternalDisplayNonInteractive))
        XCTAssertEqual(config.role, .windowExternalDisplayNonInteractive)
        XCTAssertEqual(ObjectIdentifier(try XCTUnwrap(config.delegateClass)), ObjectIdentifier(TVLyricsSceneDelegate.self))
        XCTAssertEqual(ObjectIdentifier(try XCTUnwrap(config.sceneClass)), ObjectIdentifier(UIWindowScene.self))
        XCTAssertNil(TVLyricsSceneConfiguration.configuration(for: .windowApplication))
        XCTAssertNil(TVLyricsSceneConfiguration.configuration(for: .init(rawValue: "CPTemplateApplicationSceneSessionRoleApplication")))
    }

    func testLyricsOptionsKeepsSeparateDisplayAndReceivesNewVariant() throws {
        let playback = TVLyricsTestPlayback()
        let controller = playback.controller()
        controller.setPhoneSceneActive(true)
        let scene = UUID()
        controller.connectExternalScene(scene, active: true)
        XCTAssertTrue(controller.start())
        controller.phonePresentationVisibilityChanged(true)
        controller.returnToLyrics()
        XCTAssertFalse(controller.isPhonePresented)
        XCTAssertTrue(controller.isEnabled)
        XCTAssertTrue(controller.canDisplayOnExternalScene(scene))
        XCTAssertTrue(playback.idleDisabled)
        let token = try XCTUnwrap(controller.beginSelection(for: try XCTUnwrap(playback.track?.id)))
        XCTAssertTrue(controller.select(playback.document(kind: .plain, plain: "Selected romanized text"),
                                        token: token, label: "Romanized"))
        XCTAssertEqual(controller.manualPage, "Selected romanized text")
        controller.stop()
        XCTAssertFalse(controller.canDisplayOnExternalScene(scene))
        XCTAssertFalse(playback.idleDisabled)
    }
}

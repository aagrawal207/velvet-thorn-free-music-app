import Foundation
import XCTest

@MainActor
final class GanaBajanaReleaseNotificationUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 300
    }

    func testColdLaunchOpensNotifiedAlbumWithoutStartingPlayback() throws {
        let ui = AppUITestDriver(testCase: self, prefix: "release-cold")
        defer { ui.finish() }
        try ui.launch(additionalArguments: ["--release-notification-fixture", "--release-notification-on-launch"])
        try expectAlbum(ui)
        XCTAssertFalse(ui.app.buttons["player.close"].exists)
        ui.capture("release-cold-album")
        try ui.tap(ui.app.navigationBars.buttons.firstMatch)
        try ui.requireHittable(ui.app.buttons["library.likes"])
        XCUIDevice.shared.press(.home)
        ui.app.activate()
        try ui.requireHittable(ui.app.buttons["library.likes"])
        XCTAssertFalse(ui.app.buttons["collection.play"].exists, "Returning must not replay the notification route")
    }

    func testWarmTapDismissesPlayerAndSettingsAndReplacesLibraryDestination() throws {
        let ui = AppUITestDriver(testCase: self, prefix: "release-warm")
        defer { ui.finish() }
        try ui.launch(additionalArguments: ["--release-notification-fixture", "--cache-fixture", "--player", "--light"])
        try ui.expectCurrentTrack(AppUIFixture.tumHiHo)
        try ui.expectPosition(32)
        tapNotification()
        try expectAlbum(ui)
        XCTAssertFalse(ui.app.buttons["player.close"].exists)
        try ui.openPlayer()
        try ui.expectCurrentTrack(AppUIFixture.tumHiHo)
        try ui.expectPosition(32)
        try ui.expectLabel(ui.app.buttons["player.playPause"], "Play")
        try ui.closePlayer()

        try ui.openSettings()
        tapNotification()
        try expectAlbum(ui)
        XCTAssertFalse(ui.app.buttons["settings.done"].exists)
        try ui.tap(ui.app.navigationBars.buttons.firstMatch)
        try ui.tap(ui.app.buttons["library.likes"])
        try ui.requireHittable(ui.app.buttons["library.likes.autoDownload"])
        tapNotification()
        try expectAlbum(ui)
        ui.capture("release-warm-album")
    }

    func testTappingSystemBannerFromBackgroundOpensAlbumWithoutCrashing() throws {
        let ui = AppUITestDriver(testCase: self, prefix: "release-system")
        defer { ui.finish() }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        try ui.launch(additionalArguments: ["--release-notification-fixture", "--release-notification-system"])
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 4) { allow.tap() }
        XCUIDevice.shared.press(.home)
        let banner = springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "Notification Album")).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 30), "The scheduled release banner must appear")
        banner.tap()
        try expectAlbum(ui)
        // The system completion runs after routing; a wrong-thread completion terminates the app here.
        Thread.sleep(forTimeInterval: 3)
        XCTAssertEqual(ui.app.state, .runningForeground)
        ui.capture("release-system-album")
    }

    private func expectAlbum(_ ui: AppUITestDriver) throws {
        try ui.requireHittable(ui.app.buttons["collection.play"], timeout: 20)
        XCTAssertTrue(ui.app.staticTexts["ALBUM"].exists)
        XCTAssertTrue(ui.app.staticTexts["Evening favorites"].exists)
    }

    private func tapNotification() {
        let name = CFNotificationName(rawValue: "com.agraabhi.ganabajana.uitests.release.tap" as CFString)
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), name, nil, nil, true)
    }
}

import SwiftUI
import UIKit
import XCTest
@testable import GanaBajana

@MainActor
final class AdaptiveLayoutTests: XCTestCase {
    // iPhone 17 Pro portrait/landscape, iPad mini and 11-inch portrait, 13-inch landscape.
    private let phonePortrait: CGFloat = 402
    private let phoneLandscape: CGFloat = 874
    private let miniPortrait: CGFloat = 744
    private let padPortrait: CGFloat = 820
    private let padLandscape13: CGFloat = 1376

    func testCompactColumnKeepsThePhoneCapAndRegularWidens() {
        XCTAssertEqual(AppLayout.contentMaxWidth(for: .compact), 760)
        XCTAssertEqual(AppLayout.contentMaxWidth(for: nil), 760)
        XCTAssertEqual(AppLayout.contentMaxWidth(for: .regular), 1000)
        XCTAssertFalse(AppLayout.isRegularWidth(.compact))
        XCTAssertFalse(AppLayout.isRegularWidth(nil))
        XCTAssertTrue(AppLayout.isRegularWidth(.regular))
    }

    func testFloatingControlsAreUnconstrainedInCompactAndCenteredInRegular() {
        XCTAssertNil(AppLayout.floatingMaxWidth(for: .compact))
        XCTAssertNil(AppLayout.floatingMaxWidth(for: nil))
        XCTAssertEqual(AppLayout.floatingMaxWidth(for: .regular), 640)
    }

    func testColumnWidthClampsToTheContainerAndTheSizeClassCap() {
        XCTAssertEqual(AppLayout.columnWidth(in: phonePortrait, sizeClass: .compact), phonePortrait)
        XCTAssertEqual(AppLayout.columnWidth(in: phoneLandscape, sizeClass: .compact), 760)
        XCTAssertEqual(AppLayout.columnWidth(in: phoneLandscape, sizeClass: .regular), phoneLandscape)
        XCTAssertEqual(AppLayout.columnWidth(in: padLandscape13, sizeClass: .regular), 1000)
        XCTAssertEqual(AppLayout.columnWidth(in: -10, sizeClass: .regular), 0)
        XCTAssertEqual(AppLayout.columnWidth(in: .infinity, sizeClass: .regular), 0)
        XCTAssertEqual(AppLayout.columnWidth(in: .nan, sizeClass: .compact), 0)
    }

    func testCarouselsNeverBleedInCompactWidthAndReachTheWindowEdgeOnWideIPads() {
        XCTAssertEqual(AppLayout.carouselBleed(in: phoneLandscape, sizeClass: .compact), 0)
        XCTAssertEqual(AppLayout.carouselBleed(in: padLandscape13, sizeClass: nil), 0)
        XCTAssertEqual(AppLayout.carouselBleed(in: padPortrait, sizeClass: .regular), 0)
        XCTAssertEqual(AppLayout.carouselBleed(in: padLandscape13, sizeClass: .regular), 188)
        XCTAssertEqual(AppLayout.carouselBleed(in: .infinity, sizeClass: .regular), 0)
        let bleed = AppLayout.carouselBleed(in: padLandscape13, sizeClass: .regular)
        XCTAssertEqual(AppLayout.columnWidth(in: padLandscape13, sizeClass: .regular) + 2 * bleed, padLandscape13)
    }

    func testCompactShelfMetricsMatchTheShippedPhoneLayout() {
        let portrait = HomeShelfMetrics(containerWidth: phonePortrait, sizeClass: .compact, isAccessibilitySize: false)
        XCTAssertEqual(portrait.columnWidth, phonePortrait)
        XCTAssertEqual(portrait.cardSize, phonePortrait * 0.36, accuracy: 1e-6)
        XCTAssertEqual(portrait.tileSize, (phonePortrait - 54) / 2, accuracy: 1e-6)
        XCTAssertEqual(portrait.carouselBleed, 0)

        let landscape = HomeShelfMetrics(containerWidth: phoneLandscape, sizeClass: .compact, isAccessibilitySize: false)
        XCTAssertEqual(landscape.columnWidth, 760)
        XCTAssertEqual(landscape.cardSize, 150)
        XCTAssertEqual(landscape.tileSize, 230)
        XCTAssertEqual(landscape.carouselBleed, 0)

        let accessible = HomeShelfMetrics(containerWidth: phonePortrait, sizeClass: .compact, isAccessibilitySize: true)
        XCTAssertEqual(accessible.cardSize, 200)
        XCTAssertEqual(accessible.tileSize, phonePortrait - 40)

        let unmeasured = HomeShelfMetrics(containerWidth: .nan, sizeClass: .compact, isAccessibilitySize: false)
        XCTAssertEqual(unmeasured.columnWidth, 0)
        XCTAssertEqual(unmeasured.cardSize, 124)
        XCTAssertEqual(unmeasured.tileSize, 140)
    }

    func testRegularShelfMetricsScaleCardsAndTilesWithinTheirBands() {
        let mini = HomeShelfMetrics(containerWidth: miniPortrait, sizeClass: .regular, isAccessibilitySize: false)
        XCTAssertEqual(mini.columnWidth, miniPortrait)
        XCTAssertEqual(mini.cardSize, 160)
        XCTAssertEqual(mini.tileSize, (miniPortrait - 68) / 3, accuracy: 1e-6)
        XCTAssertEqual(mini.carouselBleed, 0)

        let portrait = HomeShelfMetrics(containerWidth: padPortrait, sizeClass: .regular, isAccessibilitySize: false)
        XCTAssertEqual(portrait.cardSize, 160)
        XCTAssertEqual(portrait.tileSize, (padPortrait - 68) / 3, accuracy: 1e-6)

        let landscape = HomeShelfMetrics(containerWidth: padLandscape13, sizeClass: .regular, isAccessibilitySize: false)
        XCTAssertEqual(landscape.columnWidth, 1000)
        XCTAssertEqual(landscape.cardSize, 180)
        XCTAssertEqual(landscape.tileSize, 260)
        XCTAssertEqual(landscape.carouselBleed, 188)

        let accessible = HomeShelfMetrics(containerWidth: padLandscape13, sizeClass: .regular, isAccessibilitySize: true)
        XCTAssertEqual(accessible.cardSize, 200)
        XCTAssertEqual(accessible.tileSize, 420)

        for width in stride(from: CGFloat(678), through: 1400, by: 1) {
            let metrics = HomeShelfMetrics(containerWidth: width, sizeClass: .regular, isAccessibilitySize: false)
            XCTAssertTrue((CGFloat(160)...180).contains(metrics.cardSize), "card at \(width)")
            XCTAssertTrue((CGFloat(200)...260).contains(metrics.tileSize), "tile at \(width)")
            XCTAssertLessThanOrEqual(68 + 3 * metrics.tileSize, metrics.columnWidth + 1e-6, "three tiles fit at \(width)")
            XCTAssertEqual(metrics.columnWidth + 2 * metrics.carouselBleed, width, accuracy: 1e-6, "bleed fills the window at \(width)")
        }
    }

    func testCompactWidthHidesTabBarAndMiniPlayerForAnyLocalKeyboard() {
        for height in [CGFloat(0), 55, 336, .nan] {
            let hiding = KeyboardChromeHiding(keyboardHeight: height, isRegularWidth: false, isMacDesignedForIPad: false)
            XCTAssertTrue(hiding.hidesTabBar, "height \(height)")
            XCTAssertTrue(hiding.hidesMiniPlayer, "height \(height)")
        }
    }

    func testRegularWidthKeepsTheTabBarAndYieldsTheMiniPlayerOnlyToAnOnScreenKeyboard() {
        let shortcutBar = KeyboardChromeHiding(keyboardHeight: 55, isRegularWidth: true, isMacDesignedForIPad: false)
        XCTAssertEqual(shortcutBar, .nothing)
        let unmeasured = KeyboardChromeHiding(keyboardHeight: .nan, isRegularWidth: true, isMacDesignedForIPad: false)
        XCTAssertEqual(unmeasured, .nothing)
        let threshold = KeyboardChromeHiding(keyboardHeight: KeyboardChromeHiding.onScreenKeyboardMinimumHeight,
                                             isRegularWidth: true, isMacDesignedForIPad: false)
        XCTAssertEqual(threshold, KeyboardChromeHiding(hidesTabBar: false, hidesMiniPlayer: true))
        let software = KeyboardChromeHiding(keyboardHeight: 336, isRegularWidth: true, isMacDesignedForIPad: false)
        XCTAssertEqual(software, KeyboardChromeHiding(hidesTabBar: false, hidesMiniPlayer: true))
    }

    func testMacDesignedForIPadNeverHidesChromeForItsHardwareKeyboard() {
        for regular in [false, true] {
            for height in [CGFloat(0), 55, 336] {
                let hiding = KeyboardChromeHiding(keyboardHeight: height, isRegularWidth: regular, isMacDesignedForIPad: true)
                XCTAssertEqual(hiding, .nothing, "regular \(regular), height \(height)")
            }
        }
    }

    func testKeyboardNoticeReadsLocalityAndEndFrameHeight() {
        XCTAssertTrue(KeyboardNotice.isLocal(nil))
        XCTAssertTrue(KeyboardNotice.isLocal([:]))
        XCTAssertTrue(KeyboardNotice.isLocal([UIResponder.keyboardIsLocalUserInfoKey: true]))
        XCTAssertFalse(KeyboardNotice.isLocal([UIResponder.keyboardIsLocalUserInfoKey: false]))
        XCTAssertFalse(KeyboardNotice.isLocal([UIResponder.keyboardIsLocalUserInfoKey: NSNumber(value: false)]))

        XCTAssertEqual(KeyboardNotice.endFrameHeight(nil), 0)
        XCTAssertEqual(KeyboardNotice.endFrameHeight([:]), 0)
        let frame = CGRect(x: 0, y: 800, width: 1024, height: 336)
        XCTAssertEqual(KeyboardNotice.endFrameHeight([UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: frame)]), 336)
        XCTAssertEqual(KeyboardNotice.endFrameHeight([UIResponder.keyboardFrameEndUserInfoKey: frame]), 336)
        let shortcutBar = CGRect(x: 0, y: 1311, width: 1024, height: 55)
        XCTAssertEqual(KeyboardNotice.endFrameHeight([UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: shortcutBar)]), 55)
        XCTAssertEqual(KeyboardNotice.endFrameHeight([UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: .null)]), 0)
        XCTAssertEqual(KeyboardNotice.endFrameHeight([UIResponder.keyboardFrameEndUserInfoKey: "not a frame"]), 0)
    }

    func testSimulatorRunsAreNotMacDesignedForIPad() {
        #if targetEnvironment(simulator)
        XCTAssertFalse(AppPlatform.isMacDesignedForIPad)
        #endif
    }
}

import SwiftUI
import UIKit
import XCTest
@testable import GanaBajana

@MainActor
final class AdaptiveLayoutTests: XCTestCase {
    // iPhone 17 Pro portrait/landscape, iPhone SE and Slide Over, iPad mini and 11-inch portrait, 13-inch landscape.
    private let phonePortrait: CGFloat = 402
    private let phoneLandscape: CGFloat = 874
    private let smallPhone: CGFloat = 375
    private let slideOver: CGFloat = 320
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

    func testCompactShelfMetricsFitThreeCardsAndAboutTwoAndAHalfTilesOnAPhone() {
        let portrait = HomeShelfMetrics(containerWidth: phonePortrait, sizeClass: .compact, isAccessibilitySize: false)
        XCTAssertEqual(portrait.columnWidth, phonePortrait)
        XCTAssertEqual(portrait.cardSize, 116.58, accuracy: 1e-6)
        XCTAssertEqual(portrait.tileSize, 139.166_667, accuracy: 1e-6)
        XCTAssertEqual(portrait.carouselBleed, 0)
        // Home's 20-point leading inset and 16-point card gaps.
        XCTAssertLessThanOrEqual(20 + 3 * portrait.cardSize + 2 * 16, phonePortrait + 1e-6, "three song cards fit across an iPhone 17 Pro")

        let small = HomeShelfMetrics(containerWidth: smallPhone, sizeClass: .compact, isAccessibilitySize: false)
        XCTAssertEqual(small.cardSize, 108.75, accuracy: 1e-6)
        XCTAssertEqual(small.tileSize, 127.916_667, accuracy: 1e-6)

        let landscape = HomeShelfMetrics(containerWidth: phoneLandscape, sizeClass: .compact, isAccessibilitySize: false)
        XCTAssertEqual(landscape.columnWidth, 760)
        XCTAssertEqual(landscape.cardSize, 124)
        XCTAssertEqual(landscape.tileSize, 170)
        XCTAssertEqual(landscape.carouselBleed, 0)

        let narrow = HomeShelfMetrics(containerWidth: slideOver, sizeClass: .compact, isAccessibilitySize: false)
        XCTAssertEqual(narrow.cardSize, 104)
        XCTAssertEqual(narrow.tileSize, 120)

        let accessible = HomeShelfMetrics(containerWidth: phonePortrait, sizeClass: .compact, isAccessibilitySize: true)
        XCTAssertEqual(accessible.cardSize, 200)
        XCTAssertEqual(accessible.tileSize, phonePortrait - 40)

        let unmeasured = HomeShelfMetrics(containerWidth: .nan, sizeClass: .compact, isAccessibilitySize: false)
        XCTAssertEqual(unmeasured.columnWidth, 0)
        XCTAssertEqual(unmeasured.cardSize, 104)
        XCTAssertEqual(unmeasured.tileSize, 120)

        for width in stride(from: CGFloat(300), through: 1000, by: 1) {
            let metrics = HomeShelfMetrics(containerWidth: width, sizeClass: .compact, isAccessibilitySize: false)
            XCTAssertTrue((CGFloat(104)...124).contains(metrics.cardSize), "card at \(width)")
            XCTAssertTrue((CGFloat(120)...170).contains(metrics.tileSize), "tile at \(width)")
            XCTAssertLessThan(metrics.cardSize, metrics.tileSize, "song cards stay smaller than mix tiles at \(width)")
            // The leading inset, two tiles and two 14-point gaps leave room for a third tile to begin on screen.
            XCTAssertLessThan(20 + 2 * metrics.tileSize + 2 * 14, metrics.columnWidth, "a third tile starts on screen at \(width)")
            XCTAssertEqual(metrics.carouselBleed, 0, "compact never bleeds at \(width)")
        }
    }

    func testRegularShelfMetricsScaleCardsAndTilesWithinTheirBands() {
        let mini = HomeShelfMetrics(containerWidth: miniPortrait, sizeClass: .regular, isAccessibilitySize: false)
        XCTAssertEqual(mini.columnWidth, miniPortrait)
        XCTAssertEqual(mini.cardSize, 132)
        XCTAssertEqual(mini.tileSize, 170)
        XCTAssertEqual(mini.carouselBleed, 0)

        let portrait = HomeShelfMetrics(containerWidth: padPortrait, sizeClass: .regular, isAccessibilitySize: false)
        XCTAssertEqual(portrait.cardSize, 132)
        XCTAssertEqual(portrait.tileSize, 188, accuracy: 1e-6)

        let landscape = HomeShelfMetrics(containerWidth: padLandscape13, sizeClass: .regular, isAccessibilitySize: false)
        XCTAssertEqual(landscape.columnWidth, 1000)
        XCTAssertEqual(landscape.cardSize, 150)
        XCTAssertEqual(landscape.tileSize, 210)
        XCTAssertEqual(landscape.carouselBleed, 188)

        let accessible = HomeShelfMetrics(containerWidth: padLandscape13, sizeClass: .regular, isAccessibilitySize: true)
        XCTAssertEqual(accessible.cardSize, 200)
        XCTAssertEqual(accessible.tileSize, 420)

        for width in stride(from: CGFloat(678), through: 1400, by: 1) {
            let metrics = HomeShelfMetrics(containerWidth: width, sizeClass: .regular, isAccessibilitySize: false)
            XCTAssertTrue((CGFloat(132)...150).contains(metrics.cardSize), "card at \(width)")
            XCTAssertTrue((CGFloat(170)...210).contains(metrics.tileSize), "tile at \(width)")
            XCTAssertLessThan(metrics.cardSize, metrics.tileSize, "album cards stay smaller than mix tiles at \(width)")
            XCTAssertLessThanOrEqual(68 + 3 * metrics.tileSize, metrics.columnWidth + 1e-6, "three tiles fit at \(width)")
            if metrics.columnWidth >= miniPortrait {
                // The 20-point leading inset, four tiles and their three 14-point gaps.
                XCTAssertLessThanOrEqual(20 + 4 * metrics.tileSize + 3 * 14, metrics.columnWidth + 1e-6, "four tiles fit at \(width)")
            }
            XCTAssertEqual(metrics.columnWidth + 2 * metrics.carouselBleed, width, accuracy: 1e-6, "bleed fills the window at \(width)")
        }
    }

    func testMadeForYouGridIsTwoAcrossOnPhonesFourAcrossOnIPadsAndOneAtAccessibilitySizes() {
        func metrics(_ width: CGFloat, _ sizeClass: UserInterfaceSizeClass?, accessible: Bool = false) -> HomeShelfMetrics {
            HomeShelfMetrics(containerWidth: width, sizeClass: sizeClass, isAccessibilitySize: accessible)
        }
        XCTAssertEqual(metrics(phonePortrait, .compact).mixGridColumns, 2)
        XCTAssertEqual(metrics(phonePortrait, .compact).mixCardWidth, 176)
        XCTAssertEqual(metrics(smallPhone, .compact).mixGridColumns, 2)
        XCTAssertEqual(metrics(smallPhone, .compact).mixCardWidth, 162.5)
        XCTAssertEqual(metrics(phoneLandscape, .compact).mixGridColumns, 2)
        XCTAssertEqual(metrics(phoneLandscape, .compact).mixCardWidth, 355)
        XCTAssertEqual(metrics(phoneLandscape, nil).mixGridColumns, 2, "an unknown size class keeps the phone grid")
        XCTAssertEqual(metrics(slideOver, .compact).mixGridColumns, 1, "two cards would be narrower than the minimum")
        XCTAssertEqual(metrics(slideOver, .compact).mixCardWidth, 280)

        XCTAssertEqual(metrics(miniPortrait, .regular).mixGridColumns, 4)
        XCTAssertEqual(metrics(miniPortrait, .regular).mixCardWidth, 168.5)
        XCTAssertEqual(metrics(padPortrait, .regular).mixGridColumns, 4)
        XCTAssertEqual(metrics(padPortrait, .regular).mixCardWidth, 187.5)
        XCTAssertEqual(metrics(padLandscape13, .regular).mixGridColumns, 4)
        XCTAssertEqual(metrics(padLandscape13, .regular).mixCardWidth, 232.5)
        XCTAssertEqual(metrics(678, .regular).mixGridColumns, 2, "a narrow regular window shows two by two, never three over one")
        XCTAssertEqual(metrics(678, .regular).mixCardWidth, 314)

        for (width, sizeClass) in [(phonePortrait, UserInterfaceSizeClass.compact), (padLandscape13, UserInterfaceSizeClass.regular)] {
            let accessible = metrics(width, sizeClass, accessible: true)
            XCTAssertEqual(accessible.mixGridColumns, 1, "\(sizeClass) accessibility sizes stack the cards")
            XCTAssertEqual(accessible.mixCardWidth, accessible.columnWidth - 40, "\(sizeClass) cards span the column")
        }

        let unmeasured = metrics(.nan, .compact)
        XCTAssertEqual(unmeasured.mixGridColumns, 1)
        XCTAssertEqual(unmeasured.mixCardWidth, 0)

        for sizeClass in [UserInterfaceSizeClass.compact, .regular] {
            for width in stride(from: CGFloat(300), through: 1400, by: 1) {
                let grid = metrics(width, sizeClass)
                let columns = CGFloat(grid.mixGridColumns)
                XCTAssertTrue((sizeClass == .regular ? [1, 2, 4] : [1, 2]).contains(grid.mixGridColumns), "\(sizeClass) columns at \(width)")
                // Cards and gaps fill the column inside its 20-point insets exactly, so nothing scrolls sideways.
                XCTAssertEqual(columns * grid.mixCardWidth + (columns - 1) * HomeShelfMetrics.mixGridSpacing,
                               grid.columnWidth - 40, accuracy: 1e-6, "\(sizeClass) grid width at \(width)")
                if grid.mixGridColumns > 1 {
                    XCTAssertGreaterThanOrEqual(grid.mixCardWidth + 1e-6, HomeShelfMetrics.mixCardMinimumWidth, "\(sizeClass) card at \(width)")
                }
                if sizeClass == .compact, grid.columnWidth >= smallPhone {
                    XCTAssertEqual(grid.mixGridColumns, 2, "every phone shows the mixes two by two at \(width)")
                }
                if sizeClass == .regular, grid.columnWidth >= miniPortrait {
                    XCTAssertEqual(grid.mixGridColumns, 4, "iPad columns show the mixes in one row at \(width)")
                }
            }
        }
    }

    func testGridRowsFillLeftToRightAndLeaveTheLastRowShort() {
        let mixes = ["discoverWeekly", "dailyMix", "dailyMix2", "dailyMix3"]
        XCTAssertEqual(HomeShelfMetrics.gridRows(mixes, columns: 2), [["discoverWeekly", "dailyMix"], ["dailyMix2", "dailyMix3"]])
        XCTAssertEqual(HomeShelfMetrics.gridRows(Array(mixes.prefix(3)), columns: 2), [["discoverWeekly", "dailyMix"], ["dailyMix2"]])
        XCTAssertEqual(HomeShelfMetrics.gridRows(mixes, columns: 4), [mixes])
        XCTAssertEqual(HomeShelfMetrics.gridRows(Array(mixes.prefix(2)), columns: 4), [["discoverWeekly", "dailyMix"]])
        XCTAssertEqual(HomeShelfMetrics.gridRows(mixes, columns: 1), mixes.map { [$0] })
        XCTAssertEqual(HomeShelfMetrics.gridRows([String](), columns: 2), [])
        XCTAssertEqual(HomeShelfMetrics.gridRows(mixes, columns: 0), mixes.map { [$0] }, "a degenerate count still lists every mix once")
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

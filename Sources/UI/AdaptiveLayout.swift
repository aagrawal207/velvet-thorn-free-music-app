import SwiftUI
import UIKit

/// Width arithmetic shared by the tab roots. Compact width is the phone layout and must not move; regular width
/// (full-screen iPad, wide Split View, Mac) widens the column so 11-13 inch windows do not read as a boxed phone.
enum AppLayout {
    static let compactColumnMaxWidth: CGFloat = 760
    static let regularColumnMaxWidth: CGFloat = 1000
    /// Mini-player and banner column in regular width; a window-wide capsule strands transport far from artwork.
    static let regularFloatingMaxWidth: CGFloat = 640

    static func isRegularWidth(_ sizeClass: UserInterfaceSizeClass?) -> Bool {
        sizeClass == .regular
    }

    static func contentMaxWidth(for sizeClass: UserInterfaceSizeClass?) -> CGFloat {
        isRegularWidth(sizeClass) ? regularColumnMaxWidth : compactColumnMaxWidth
    }

    /// Nil leaves `.frame(maxWidth:)` unconstrained, so compact width keeps its full-width capsule and banner.
    static func floatingMaxWidth(for sizeClass: UserInterfaceSizeClass?) -> CGFloat? {
        isRegularWidth(sizeClass) ? regularFloatingMaxWidth : nil
    }

    /// Width the centered column occupies inside a measured container; unmeasured geometry collapses to zero.
    static func columnWidth(in containerWidth: CGFloat, sizeClass: UserInterfaceSizeClass?) -> CGFloat {
        guard containerWidth.isFinite else { return 0 }
        return min(max(0, containerWidth), contentMaxWidth(for: sizeClass))
    }

    /// Distance a Home shelf may extend past the column on each side. Compact never bleeds; wide iPad windows let
    /// carousels run to the window edge while headers stay in the column.
    static func carouselBleed(in containerWidth: CGFloat, sizeClass: UserInterfaceSizeClass?) -> CGFloat {
        guard isRegularWidth(sizeClass), containerWidth.isFinite else { return 0 }
        return max(0, (containerWidth - columnWidth(in: containerWidth, sizeClass: sizeClass)) / 2)
    }
}

/// Home shelf geometry for one measured width, kept pure so the numbers are tested rather than eyeballed.
struct HomeShelfMetrics: Equatable {
    let columnWidth: CGFloat
    let cardSize: CGFloat
    let tileSize: CGFloat
    let carouselBleed: CGFloat

    init(containerWidth: CGFloat, sizeClass: UserInterfaceSizeClass?, isAccessibilitySize: Bool) {
        let width = AppLayout.columnWidth(in: containerWidth, sizeClass: sizeClass)
        columnWidth = width
        carouselBleed = AppLayout.carouselBleed(in: containerWidth, sizeClass: sizeClass)
        if AppLayout.isRegularWidth(sizeClass) {
            cardSize = isAccessibilitySize ? 200 : min(180, max(160, width * 0.18))
            // Three tiles per row after 20-point column padding and 14-point gaps; a column-wide tile is a 960-point square.
            tileSize = isAccessibilitySize ? min(420, max(0, width - 40)) : min(260, max(200, (width - 68) / 3))
        } else {
            cardSize = isAccessibilitySize ? 200 : min(150, max(124, width * 0.36))
            tileSize = isAccessibilitySize ? max(0, width - 40) : min(230, max(140, (width - 54) / 2))
        }
    }
}

/// Which chrome a keyboard takes with it. Compact width keeps the phone behavior; regular width keeps its top tab
/// bar and yields the mini-player only to an on-screen keyboard, never to a hardware keyboard's shortcut bar.
struct KeyboardChromeHiding: Equatable, Sendable {
    static let nothing = KeyboardChromeHiding(hidesTabBar: false, hidesMiniPlayer: false)
    /// Hardware shortcut bars report about 55 points; the smallest floating iPad keyboard is well above this.
    static let onScreenKeyboardMinimumHeight: CGFloat = 100

    var hidesTabBar: Bool
    var hidesMiniPlayer: Bool

    init(hidesTabBar: Bool, hidesMiniPlayer: Bool) {
        self.hidesTabBar = hidesTabBar
        self.hidesMiniPlayer = hidesMiniPlayer
    }

    init(keyboardHeight: CGFloat, isRegularWidth: Bool, isMacDesignedForIPad: Bool) {
        if isMacDesignedForIPad {
            hidesTabBar = false
            hidesMiniPlayer = false
        } else if !isRegularWidth {
            hidesTabBar = true
            hidesMiniPlayer = true
        } else {
            hidesTabBar = false
            hidesMiniPlayer = keyboardHeight.isFinite && keyboardHeight >= Self.onScreenKeyboardMinimumHeight
        }
    }
}

/// Reads the parts of a keyboard notification the layout depends on.
@MainActor
enum KeyboardNotice {
    /// Split View delivers the neighbouring app's keyboard notifications too; only this app's keyboard moves chrome.
    static func isLocal(_ userInfo: [AnyHashable: Any]?) -> Bool {
        (userInfo?[UIResponder.keyboardIsLocalUserInfoKey] as? Bool) ?? true
    }

    static func endFrameHeight(_ userInfo: [AnyHashable: Any]?) -> CGFloat {
        let value = userInfo?[UIResponder.keyboardFrameEndUserInfoKey]
        guard let frame = (value as? CGRect) ?? (value as? NSValue)?.cgRectValue, frame.height.isFinite else { return 0 }
        return max(0, frame.height)
    }
}

enum AppPlatform {
    /// The iPad binary on Apple silicon Macs: no on-screen keyboard, no alternate icons, always a hardware keyboard.
    static var isMacDesignedForIPad: Bool {
        ProcessInfo.processInfo.isiOSAppOnMac
    }
}

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
    /// Gap between Made for You cards, across and down.
    static let mixGridSpacing: CGFloat = 10
    /// Rows sit further apart than columns because each card ends in two lines of text.
    static let mixGridRowSpacing: CGFloat = 18
    /// Narrowest Made for You card that still fits its collage, a two-line title and a readable caption.
    static let mixCardMinimumWidth: CGFloat = 160

    let columnWidth: CGFloat
    let cardSize: CGFloat
    let tileSize: CGFloat
    let carouselBleed: CGFloat
    /// Made for You never scrolls sideways: two cards per row on phones and four across an iPad column, halved
    /// while a card would be narrower than `mixCardMinimumWidth`, and one per row at accessibility sizes.
    let mixGridColumns: Int
    let mixCardWidth: CGFloat

    init(containerWidth: CGFloat, sizeClass: UserInterfaceSizeClass?, isAccessibilitySize: Bool) {
        let width = AppLayout.columnWidth(in: containerWidth, sizeClass: sizeClass)
        let isRegular = AppLayout.isRegularWidth(sizeClass)
        columnWidth = width
        carouselBleed = AppLayout.carouselBleed(in: containerWidth, sizeClass: sizeClass)
        if isRegular {
            cardSize = isAccessibilitySize ? 200 : min(150, max(132, width * 0.15))
            // Four tiles across the column after the 20-point inset and 14-point gaps; a column-wide tile is a 960-point square.
            tileSize = isAccessibilitySize ? min(420, max(0, width - 40)) : min(210, max(170, (width - 68) / 4))
        } else {
            cardSize = isAccessibilitySize ? 200 : min(124, max(104, width * 0.29))
            // About 2.4 tiles across, so the third one peeks in and shows that the shelf scrolls.
            tileSize = isAccessibilitySize ? max(0, width - 40) : min(170, max(120, (width - 68) / 2.4))
        }
        let gridWidth = max(0, width - 40)
        var columns = isAccessibilitySize ? 1 : isRegular ? 4 : 2
        // Halving rather than dropping one keeps four mixes in full rows (4 by 1, 2 by 2), never three over one.
        while columns > 1, Self.gridCardWidth(gridWidth, columns: columns) < Self.mixCardMinimumWidth { columns /= 2 }
        mixGridColumns = columns
        mixCardWidth = Self.gridCardWidth(gridWidth, columns: columns)
    }

    /// Rows in reading order; the last row stays short so its cards line up under the columns above.
    static func gridRows<Item>(_ items: [Item], columns: Int) -> [[Item]] {
        let columns = max(1, columns)
        return stride(from: 0, to: items.count, by: columns).map { Array(items[$0..<min($0 + columns, items.count)]) }
    }

    private static func gridCardWidth(_ gridWidth: CGFloat, columns: Int) -> CGFloat {
        max(0, (gridWidth - CGFloat(columns - 1) * mixGridSpacing) / CGFloat(columns))
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
    /// Any Mac build, Catalyst or the iPad binary: no on-screen keyboard, no alternate icons, always a hardware keyboard.
    static var isMacDesignedForIPad: Bool {
        ProcessInfo.processInfo.isiOSAppOnMac || isMacCatalyst
    }

    static var isMacCatalyst: Bool {
        #if targetEnvironment(macCatalyst)
        true
        #else
        false
        #endif
    }
}

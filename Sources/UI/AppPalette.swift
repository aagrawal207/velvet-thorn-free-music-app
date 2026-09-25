import SwiftUI
import UIKit

enum AppTheme {
    // RootView supplies the accent; adaptive colors resolve against each surface's own appearance.
    static var accent: Color { .accentColor }
    static let gold = adaptive(light: 0xA87400, dark: 0xF7C948)
    static let violet = adaptive(light: 0x6858D6, dark: 0xA78BFA)
    static let background = adaptive(light: 0xFFFFFF, dark: 0x000000)
    // Opaque accent fills pair with the page color, including brighter dark-mode accents.
    static let onAccent = background
    static let surface = adaptive(light: 0xF4F4F7, dark: 0x121214)
    static let raised = adaptive(light: 0xE8E8EE, dark: 0x1E1E22)
    static let primaryText = adaptive(light: 0x0B0B10, dark: 0xFFFFFF)
    static let secondaryText = adaptive(light: 0x6D6D78, dark: 0x9A9AA3)
    // Artwork surfaces need stronger text so their colour can remain visible behind scrolling content.
    static let artworkSecondaryText = adaptive(light: 0x3F3F49, dark: 0xEFEFF4)

    fileprivate static func adaptive(light: UInt, dark: UInt) -> Color {
        Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 255) / 255,
                           green: CGFloat((hex >> 8) & 255) / 255,
                           blue: CGFloat(hex & 255) / 255, alpha: 1)
        })
    }
}

extension AppAccent {
    var color: Color {
        switch self {
        case .coral: AppTheme.adaptive(light: 0xDC3159, dark: 0xFF5A7A)
        case .mint: AppTheme.adaptive(light: 0x007A59, dark: 0x4DE0B0)
        case .ocean: AppTheme.adaptive(light: 0x086BCE, dark: 0x64B5FF)
        case .violet: AppTheme.adaptive(light: 0x7446D1, dark: 0xB79AFF)
        case .amber: AppTheme.adaptive(light: 0x936000, dark: 0xFFC15A)
        case .rose: AppTheme.adaptive(light: 0xB93080, dark: 0xFF83BB)
        case .teal: AppTheme.adaptive(light: 0x007A83, dark: 0x53D7E0)
        }
    }
}

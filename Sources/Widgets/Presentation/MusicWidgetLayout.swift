import SwiftUI
import UIKit
import WidgetKit

@MainActor
struct MusicWidgetLayout {
    // Pixel-aligned accessibility bounds can lose a fraction of a point from the layout frame.
    static let minimumActionHeight: CGFloat = 46

    let family: WidgetFamily
    let contentSize: CGSize
    let isAccessibilitySize: Bool
    let titlePointSize: CGFloat
    let captionPointSize: CGFloat
    let headingPointSize: CGFloat
    let rowTitleLineLimit: Int
    let rowHeight: CGFloat
    let maximumTrackRows: Int
    let smallArtworkSide: CGFloat
    let smallTitleLineLimit: Int
    let mixArtworkSide: CGFloat
    let mixShowsCount: Bool
    let mixHeaderHeight: CGFloat
    let emptyTitleLineLimit: Int
    let emptyMessageLineLimit: Int

    let padding: CGFloat = 12
    let spacing: CGFloat = 4
    let columnSpacing: CGFloat = 12
    let headerHeight: CGFloat = MusicWidgetLayout.minimumActionHeight

    var isSmall: Bool { family == .systemSmall }
    var isLarge: Bool { family == .systemLarge }
    var smallHeaderHeight: CGFloat { Self.lineHeight(headingPointSize) * 2 }
    var emptyHeaderHeight: CGFloat { isSmall ? smallHeaderHeight : Self.lineHeight(headingPointSize) }
    var emptyTitlePointSize: CGFloat { min(titlePointSize + 3, 27) }

    init(size: CGSize, family: WidgetFamily, dynamicTypeSize: DynamicTypeSize,
         scaledTitle: CGFloat = 14, scaledCaption: CGFloat = 11) {
        self.family = family
        isAccessibilitySize = dynamicTypeSize.isAccessibilitySize
        let width = size.width.isFinite ? max(0, size.width - 24) : 0
        let height = size.height.isFinite ? max(0, size.height - 24) : 0
        contentSize = CGSize(width: width, height: height)
        // Fixed widget canvases trade rows and artwork for larger type before reaching these readable caps.
        titlePointSize = min(max(14, scaledTitle.isFinite ? scaledTitle : 14), 24)
        captionPointSize = min(max(11, scaledCaption.isFinite ? scaledCaption : 11), 19)
        headingPointSize = family == .systemSmall ? min(captionPointSize, 14) : min(titlePointSize + 1, 20)

        let titleLine = Self.lineHeight(titlePointSize)
        let captionLine = Self.lineHeight(captionPointSize)
        let headingLine = Self.lineHeight(headingPointSize)
        rowTitleLineLimit = family == .systemLarge && dynamicTypeSize.isAccessibilitySize ? 2 : 1
        rowHeight = max(Self.minimumActionHeight, titleLine * CGFloat(rowTitleLineLimit) + captionLine + 6)
        maximumTrackRows = family == .systemSmall ? 1
            : Int(min(CGFloat(WidgetLibrarySnapshot.maximumTracksPerList), max(0, (height - Self.minimumActionHeight) / (rowHeight + 4))))

        let artworkRoom = floor(min(64, height - headingLine * 2 - titleLine - captionLine - 12))
        smallArtworkSide = artworkRoom >= 32 && !dynamicTypeSize.isAccessibilitySize ? artworkRoom : 0
        smallTitleLineLimit = smallArtworkSide > 0 ? 1
            : Int(min(2, max(1, (height - headingLine * 2 - captionLine - 8) / titleLine)))

        mixHeaderHeight = max(Self.minimumActionHeight, headingLine * (dynamicTypeSize.isAccessibilitySize ? 2 : 1))
        if family == .systemLarge {
            mixShowsCount = height >= 2 * Self.minimumActionHeight + captionLine + 24
            mixArtworkSide = max(0, floor(min(200, width * 0.68, height - 2 * Self.minimumActionHeight - captionLine - 24)))
        } else if family == .systemMedium {
            mixShowsCount = height >= mixHeaderHeight + Self.minimumActionHeight + captionLine + 8
            mixArtworkSide = max(0, floor(min(height, width * 0.38)))
        } else {
            mixShowsCount = true
            mixArtworkSide = smallArtworkSide
        }

        let emptyHeader = family == .systemSmall ? headingLine * 2 : headingLine
        let emptyTitle = Self.lineHeight(min(titlePointSize + 3, 27))
        emptyTitleLineLimit = Int(min(2, max(1, (height - emptyHeader - captionLine - 8) / emptyTitle)))
        let messageRoom = height - emptyHeader - emptyTitle * CGFloat(emptyTitleLineLimit) - captionLine - 12
        emptyMessageLineLimit = Int(min(family == .systemLarge ? 4 : 2, max(0, messageRoom / captionLine)))
    }

    private static func lineHeight(_ pointSize: CGFloat) -> CGFloat {
        ceil(UIFont.systemFont(ofSize: pointSize).lineHeight)
    }
}

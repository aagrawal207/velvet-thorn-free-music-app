import ImageIO
import SwiftUI
import UIKit
import WidgetKit

@MainActor
struct MusicWidgetArtwork: View {
    let data: Data?
    let side: CGFloat
    var cornerRadius: CGFloat = 4

    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        ZStack {
            renderingMode == .fullColor ? AppTheme.raised : Color.primary.opacity(0.08)
            if let image = thumbnail {
                Image(uiImage: image)
                    .resizable()
                    .widgetAccentedRenderingMode(.desaturated)
                    .scaledToFill()
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: max(12, min(32, side * 0.34)), weight: .medium))
                    .foregroundStyle(renderingMode == .fullColor ? AppTheme.accent : .primary)
                    .widgetAccentable()
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .privacySensitive()
        .accessibilityHidden(true)
    }

    private var thumbnail: UIImage? {
        guard let data, WidgetLibrarySnapshot.isValidArtwork(data),
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: WidgetLibrarySnapshot.maximumArtworkPixels,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}

@MainActor
struct MusicWidgetCollage: View {
    let tracks: [Track]
    let artwork: [String: Data]
    let side: CGFloat

    var body: some View {
        Group {
            if tracks.count >= 4 {
                VStack(spacing: 1) {
                    HStack(spacing: 1) { tile(0); tile(1) }
                    HStack(spacing: 1) { tile(2); tile(3) }
                }
            } else {
                MusicWidgetArtwork(data: tracks.first.flatMap { artwork[$0.id] }, side: side, cornerRadius: 6)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .privacySensitive()
        .accessibilityHidden(true)
    }

    private func tile(_ index: Int) -> some View {
        MusicWidgetArtwork(data: artwork[tracks[index].id], side: max(0, (side - 1) / 2), cornerRadius: 0)
    }
}

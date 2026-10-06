import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

enum AudioExportArtwork {
    static let maximumPixels = 1_024
    static let maximumBytes = 512 << 10
    static let maximumInputBytes = 12 << 20

    // This accepts the loader's large image without using the widget-limited cachedThumbnail path.
    static func jpeg(from image: UIImage) throws -> Data {
        try Task.checkCancellation()
        guard image.size.width.isFinite, image.size.height.isFinite,
              image.size.width > 0, image.size.height > 0 else { throw AudioExportError.invalidArtwork }
        let width = image.size.width * image.scale
        let height = image.size.height * image.scale
        for pixels in [maximumPixels, 768, 512, 256] {
            let scale = min(1, CGFloat(pixels) / max(width, height))
            let size = CGSize(width: max(1, floor(width * scale)), height: max(1, floor(height * scale)))
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let renderer = UIGraphicsImageRenderer(size: size, format: format)
            let rendered = renderer.image { context in
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: size))
                image.draw(in: CGRect(origin: .zero, size: size))
            }
            for quality in [0.9, 0.75, 0.6, 0.4] {
                try Task.checkCancellation()
                if let data = rendered.jpegData(compressionQuality: CGFloat(quality)), isValid(data) { return data }
            }
        }
        throw AudioExportError.invalidArtwork
    }

    static func prepare(_ data: Data) throws -> Data {
        try Task.checkCancellation()
        guard !data.isEmpty, data.count <= maximumInputBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetStatus(source) == .statusComplete,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixels,
                kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else { throw AudioExportError.invalidArtwork }
        if isValid(data) { return data }
        return try jpeg(from: UIImage(cgImage: image))
    }

    static func isValid(_ data: Data) -> Bool {
        guard !data.isEmpty, data.count <= maximumBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == UTType.jpeg.identifier,
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetStatus(source) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...maximumPixels).contains(width), (1...maximumPixels).contains(height),
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else { return false }
        return true
    }
}

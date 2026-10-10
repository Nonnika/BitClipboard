import Foundation
import CoreGraphics
import ImageIO

/// Decode only the pixels needed by a card, without loading the full-resolution image.
public struct ImageThumbnail {
    public let image: CGImage
    public let originalSize: CGSize

    public static func load(from url: URL, maximumPixelSize: Int = 800) -> ImageThumbnail? {
        guard maximumPixelSize > 0,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let rotated = (5...8).contains(orientation)
        let size = CGSize(width: rotated ? height.doubleValue : width.doubleValue,
                          height: rotated ? width.doubleValue : height.doubleValue)
        return ImageThumbnail(image: image, originalSize: size)
    }
}

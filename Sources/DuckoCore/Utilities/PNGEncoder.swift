import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Re-encodes a picture as PNG, the form XEP-0084 identifies an avatar by.
enum PNGEncoder {
    struct Image {
        let data: Data
        let width: Int
        let height: Int
    }

    /// The longest side a published avatar keeps: sharp at avatar sizes on Retina, and small enough that a camera photo
    /// stays far below the avatar byte cap once it is PNG.
    static let maxPixelSize = 512

    /// The first image in `data` as PNG, upright and scaled down to ``maxPixelSize``, or nil when `data` is not a
    /// picture ImageIO can read.
    static func encode(_ data: Data) -> Image? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        // The thumbnail path applies the picture's orientation, which the PNG would otherwise lose.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(max(width, height, 1), maxPixelSize)
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

        let png = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return Image(data: png as Data, width: image.width, height: image.height)
    }
}

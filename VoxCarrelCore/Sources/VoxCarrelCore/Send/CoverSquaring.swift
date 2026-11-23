import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Makes a cover square for players that show artwork in a square, by adding to it:
/// nothing of the cover is ever cut off.
public enum CoverSquaring {
    /// The longest side, in pixels, of a cover this makes.
    static let maxSide = 1400

    /// Whether a picture of this size is square, or within 2% of it.
    static func isSquare(width: Int, height: Int) -> Bool {
        guard width > 0, height > 0 else { return false }
        return abs(width - height) * 100 <= 2 * max(width, height)
    }

    /// Whether the cover is square (within 2%); nil when it cannot be read as a picture.
    static func isSquare(_ cover: CoverImage) -> Bool? {
        guard let source = CGImageSourceCreateWithData(cover.data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0
        else { return nil }
        return isSquare(width: width, height: height)
    }

    /// The cover centred on a square whose side is the cover's longer side (at most
    /// `maxSide` pixels: a larger cover is scaled down), the bars beside or above and
    /// below it filled with the average colour of the cover's outer edge. A JPEG.
    ///
    /// Nil when the cover is square already (within 2%) or cannot be read as a picture.
    public static func squared(_ cover: CoverImage) -> CoverImage? {
        guard isSquare(cover) == false,
              let source = CGImageSourceCreateWithData(cover.data as CFData, nil)
        else { return nil }
        // The picture the right way up, and no larger than the limit.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
        ]
        let whole = CGImageSourceCreateImageAtIndex(source, 0, nil)
        let fits = whole.map { max($0.width, $0.height) <= maxSide } ?? false
        let turned = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])?[kCGImagePropertyOrientation]
            .flatMap { $0 as? Int }.map { $0 != 1 } ?? false
        guard let picture = fits && !turned ? whole : CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              picture.width > 0, picture.height > 0, !isSquare(width: picture.width, height: picture.height),
              let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        let width = picture.width, height = picture.height
        let side = max(width, height)
        guard let edge = edgeColour(of: picture, space: space),
              let canvas = CGContext(
                data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        canvas.setFillColor(CGColor(
            colorSpace: space,
            components: [CGFloat(edge.0) / 255, CGFloat(edge.1) / 255, CGFloat(edge.2) / 255, 1]) ?? .white)
        canvas.fill(CGRect(x: 0, y: 0, width: side, height: side))
        canvas.interpolationQuality = .high
        canvas.draw(picture, in: CGRect(x: (side - width) / 2, y: (side - height) / 2, width: width, height: height))

        let data = NSMutableData()
        guard let made = canvas.makeImage(),
              let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, made, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return CoverImage(data: data as Data, mime: "image/jpeg")
    }

    /// The average colour of the picture's outermost pixels, all the way round. A
    /// picture that is partly see-through is taken as lying on white.
    private static func edgeColour(of picture: CGImage, space: CGColorSpace) -> (Int, Int, Int)? {
        let width = picture.width, height = picture.height
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            context.setFillColor(.white)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(picture, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var sums = (0, 0, 0), count = 0
        func add(_ x: Int, _ y: Int) {
            let at = (y * width + x) * 4
            sums.0 += Int(pixels[at])
            sums.1 += Int(pixels[at + 1])
            sums.2 += Int(pixels[at + 2])
            count += 1
        }
        for x in 0..<width {
            add(x, 0)
            add(x, height - 1)
        }
        for y in 0..<height {
            add(0, y)
            add(width - 1, y)
        }
        guard count > 0 else { return nil }
        return (sums.0 / count, sums.1 / count, sums.2 / count)
    }
}

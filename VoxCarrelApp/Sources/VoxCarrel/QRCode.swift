import AppKit
import CoreImage

/// Draws the QR code for a piece of text the model gives. Nothing here decides what the
/// code holds, and the text is kept nowhere.
enum QRCode {
    /// The blank border a QR code needs around it to be read, in modules.
    private static let quietZone = 4

    /// The code as black modules on a white square with a blank border, so that a camera
    /// reads it whatever is behind it (a dark window, say). Each module is a whole number
    /// of pixels, scaled without smoothing: the edges stay sharp.
    ///
    /// - Parameter pixels: The side the image should at least have, in pixels.
    /// - Returns: Nil when no code can be made of the text.
    static func image(for text: String, pixels: Int) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage, !output.extent.isEmpty,
              let code = CIContext(options: [.useSoftwareRenderer: true])
                  .createCGImage(output, from: output.extent)
        else { return nil }

        let modules = code.width + 2 * quietZone
        let scale = max(1, Int((Double(pixels) / Double(modules)).rounded(.up)))
        let side = modules * scale
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.interpolationQuality = .none
        context.setShouldAntialias(false)
        let inset = quietZone * scale
        context.draw(code, in: CGRect(x: inset, y: inset, width: code.width * scale, height: code.height * scale))
        guard let drawn = context.makeImage() else { return nil }
        return NSImage(cgImage: drawn, size: NSSize(width: side, height: side))
    }
}

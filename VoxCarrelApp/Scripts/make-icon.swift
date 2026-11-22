// Draws the app icon and writes Resources/AppIcon.icns.
// Usage, from VoxCarrelApp/: swift Scripts/make-icon.swift
// The icon is books on a shelf whose heights read as sound levels.
import AppKit

func colour(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// Draws the icon on a 1024-point canvas, scaled to `pixels` square.
func iconPNG(pixels: Int) -> Data {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)

    let plate = rounded(CGRect(x: 100, y: 100, width: 824, height: 824), 185)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * CGFloat(pixels) / 1024),
                  blur: 24 * CGFloat(pixels) / 1024, color: colour(0x000000, 0.35))
    ctx.addPath(plate)
    ctx.setFillColor(colour(0x121829))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.addPath(plate)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: nil, colors: [colour(0x26335A), colour(0x121829)] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    let heights: [CGFloat] = [170, 260, 350, 450, 310, 400, 240, 320, 190]
    let spines: [UInt32] = [0xF2E6CF, 0xE8A33D, 0xD2603A, 0xF2E6CF, 0x4FA3A0,
                            0xE8A33D, 0xF2E6CF, 0xD2603A, 0x4FA3A0]
    let width: CGFloat = 52, gap: CGFloat = 10, base: CGFloat = 322
    var x = (1024 - (CGFloat(heights.count) * width + CGFloat(heights.count - 1) * gap)) / 2
    for (index, height) in heights.enumerated() {
        ctx.setFillColor(colour(spines[index]))
        ctx.addPath(rounded(CGRect(x: x, y: base, width: width, height: height), 9))
        ctx.fillPath()
        ctx.setFillColor(colour(0x121829, 0.28))
        ctx.fill(CGRect(x: x, y: base + height - 58, width: width, height: 12))
        ctx.fill(CGRect(x: x, y: base + 34, width: width, height: 12))
        x += width + gap
    }
    ctx.setFillColor(colour(0xC89B5A))
    ctx.addPath(rounded(CGRect(x: 205, y: 296, width: 614, height: 30), 8))
    ctx.fillPath()

    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = fm.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: iconset) }
for points in [16, 32, 128, 256, 512] {
    try iconPNG(pixels: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try iconPNG(pixels: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
let tool = Process()
tool.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
tool.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try tool.run()
tool.waitUntilExit()
guard tool.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote Resources/AppIcon.icns")

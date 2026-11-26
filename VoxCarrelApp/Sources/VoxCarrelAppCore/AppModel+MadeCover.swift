import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers
import VoxCarrelCore

/// The cover made for a book that has none, as a picture: so that it can be saved as
/// the book's cover, written into its files and go wherever the book goes.
public enum MadeCover {
    /// The command, in the Book menu and a book's context menu.
    public static let commandTitle = "Save Made Cover into Book"

    /// What the window says while covers are saved.
    public static func busy(count: Int) -> String {
        count == 1 ? "Saving the made cover…" : "Saving \(count) made covers…"
    }

    /// How saving went. Nil when nothing was tried.
    /// - Parameters:
    ///   - saved: Books that now have the cover.
    ///   - appOnly: Of those, books whose files could not all take it: it is kept in the app.
    ///   - failed: Books that could not be saved, by title, with why.
    public static func result(saved: Int, appOnly: Int, failed: [(title: String, reason: String)]) -> String? {
        guard saved + failed.count > 0 else { return nil }
        var parts: [String] = []
        if saved == 1 {
            parts.append("The made cover is now the book's cover.")
        } else if saved > 1 {
            parts.append("The made covers are now the covers of \(saved) books.")
        }
        if appOnly == 1 {
            parts.append(saved == 1
                ? "Its files cannot all hold a cover, so it is kept in VoxCarrel as well."
                : "One book's files cannot all hold a cover, so it is kept in VoxCarrel as well.")
        } else if appOnly > 1 {
            parts.append("The files of \(appOnly) books cannot all hold a cover, so theirs are kept in VoxCarrel as well.")
        }
        if !failed.isEmpty {
            let list = failed.map { "“\($0.title)” (\($0.reason))" }.joined(separator: ", ")
            parts.append("Not saved: \(list).")
        }
        return parts.joined(separator: " ")
    }

    /// The picture's size in pixels: as a paperback, two to three.
    public static let size = (width: 1000, height: 1500)

    /// A colour of the given hue, as red, green and blue from 0 to 1.
    static func rgb(hue: Double, saturation: Double, brightness: Double) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        let h = (hue - hue.rounded(.down)) * 6
        let sector = Int(h) % 6
        let f = h - Double(Int(h))
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - saturation * f)
        let t = brightness * (1 - saturation * (1 - f))
        let (r, g, b): (Double, Double, Double)
        switch sector {
        case 0: (r, g, b) = (brightness, t, p)
        case 1: (r, g, b) = (q, brightness, p)
        case 2: (r, g, b) = (p, brightness, t)
        case 3: (r, g, b) = (p, q, brightness)
        case 4: (r, g, b) = (t, p, brightness)
        default: (r, g, b) = (brightness, p, q)
        }
        return (CGFloat(r), CGFloat(g), CGFloat(b))
    }

    /// The made cover as a JPEG: the title above a short rule and the author below it,
    /// in white on the title's own colour, as the app shows it. Nil when the book has
    /// no title to put on it, or the picture could not be made.
    public static func image(wording: PlaceholderCover.Wording, hue: Double) -> CoverImage? {
        guard !wording.title.isEmpty else { return nil }
        let width = CGFloat(size.width), height = CGFloat(size.height)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }

        // The ground: lighter at the top, as the app draws it.
        let top = rgb(hue: hue, saturation: 0.38, brightness: 0.70)
        let bottom = rgb(hue: hue, saturation: 0.50, brightness: 0.48)
        let colors = [
            CGColor(colorSpace: space, components: [top.r, top.g, top.b, 1])!,
            CGColor(colorSpace: space, components: [bottom.r, bottom.g, bottom.b, 1])!,
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
            context.drawLinearGradient(
                gradient, start: CGPoint(x: 0, y: height), end: CGPoint(x: 0, y: 0), options: [])
        }

        let white = CGColor(colorSpace: space, components: [1, 1, 1, 1])!
        let soft = CGColor(colorSpace: space, components: [1, 1, 1, 0.9])!
        let textWidth = width * 0.84

        /// The text set centred in lines no wider than `textWidth`, in the largest size
        /// from `largest` down that keeps it within `maxHeight`.
        func fitted(_ text: String, font name: String, largest: CGFloat, smallest: CGFloat, maxHeight: CGFloat, color: CGColor)
            -> (setter: CTFramesetter, size: CGSize) {
            var pointSize = largest
            while true {
                let font = CTFontCreateWithName(name as CFString, pointSize, nil)
                var alignment = CTTextAlignment.center
                var spacing: CGFloat = pointSize * 0.12
                let paragraph = withUnsafePointer(to: &alignment) { alignmentPointer in
                    withUnsafePointer(to: &spacing) { spacingPointer in
                        CTParagraphStyleCreate([
                            CTParagraphStyleSetting(
                                spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: alignmentPointer),
                            CTParagraphStyleSetting(
                                spec: .lineSpacingAdjustment, valueSize: MemoryLayout<CGFloat>.size, value: spacingPointer),
                        ], 2)
                    }
                }
                let attributes: [CFString: Any] = [
                    kCTFontAttributeName: font, kCTForegroundColorAttributeName: color,
                    kCTParagraphStyleAttributeName: paragraph,
                ]
                let string = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary)!
                let setter = CTFramesetterCreateWithAttributedString(string)
                let needed = CTFramesetterSuggestFrameSizeWithConstraints(
                    setter, CFRange(location: 0, length: 0), nil,
                    CGSize(width: textWidth, height: .greatestFiniteMagnitude), nil)
                if needed.height <= maxHeight || pointSize <= smallest {
                    return (setter, CGSize(width: textWidth, height: min(needed.height, maxHeight)))
                }
                pointSize -= 4
            }
        }

        func draw(_ block: (setter: CTFramesetter, size: CGSize), top: CGFloat) {
            // Core Text counts from the bottom of the picture.
            let box = CGRect(x: (width - textWidth) / 2, y: height - top - block.size.height, width: textWidth, height: block.size.height)
            let frame = CTFramesetterCreateFrame(block.setter, CFRange(location: 0, length: 0), CGPath(rect: box, transform: nil), nil)
            CTFrameDraw(frame, context)
        }

        let title = fitted(
            wording.title, font: "Georgia-Bold", largest: 104, smallest: 48, maxHeight: height * 0.52, color: white)
        let author = wording.author.isEmpty ? nil : fitted(
            wording.author, font: "Georgia", largest: 60, smallest: 36, maxHeight: height * 0.12, color: soft)
        let gap = height * 0.035
        let ruleHeight: CGFloat = 3
        let whole = title.size.height + gap + ruleHeight + (author.map { gap + $0.size.height } ?? 0)
        var y = (height - whole) / 2
        draw(title, top: y)
        y += title.size.height + gap
        context.setFillColor(CGColor(colorSpace: space, components: [1, 1, 1, 0.55])!)
        context.fill(CGRect(x: (width - width * 0.16) / 2, y: height - y - ruleHeight, width: width * 0.16, height: ruleHeight))
        y += ruleHeight + gap
        if let author { draw(author, top: y) }

        guard let picture = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(
            destination, picture, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return CoverImage(data: data as Data, mime: "image/jpeg")
    }
}

extension BookRow {
    /// Whether the made cover is what the book is shown with, so that it can be saved
    /// as the book's own: it has no cover, and a title to put on one.
    public var canKeepMadeCover: Bool {
        coverURL == nil && !madeCoverWording.title.isEmpty
    }
}

extension AppModel {
    /// Saves the made cover of each of these books that has no cover as the book's own
    /// cover: written into its files where they can hold one, and kept with the book.
    /// It is an edit like any other, and Undo takes it back. A book among them that has
    /// a cover is passed over.
    public func keepMadeCovers(for ids: Set<Int64>) async {
        guard commands(for: ids).keepMadeCover, filesCanChange else { return }
        let offered = rows.filter { ids.contains($0.id) && $0.canKeepMadeCover }
        var edits: [BookEdit] = []
        for row in offered {
            guard let image = MadeCover.image(wording: row.madeCoverWording, hue: row.placeholderHue) else { continue }
            edits.append(BookEdit(book: row.book, cover: .set(image)))
        }
        guard !edits.isEmpty else { return }
        let titles = Dictionary(offered.map { ($0.id, $0.book.title) }) { first, _ in first }
        let toSave = edits
        await perform(MadeCover.busy(count: edits.count)) { worker in
            let outcomes = try await worker.save(toSave)
            var saved = 0, appOnly = 0
            var failed: [(title: String, reason: String)] = []
            for outcome in outcomes {
                switch outcome {
                case .saved(_, _, let appOnlyFields, _):
                    saved += 1
                    if appOnlyFields.contains(.cover) { appOnly += 1 }
                case .failed(let bookId, let reason):
                    failed.append((titles[bookId] ?? "", reason))
                }
            }
            // One that went well needs no saying: the cover is there to see.
            if appOnly > 0 || !failed.isEmpty {
                self.alert = MadeCover.result(saved: saved, appOnly: appOnly, failed: failed)
            }
        }
    }
}

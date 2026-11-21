import SwiftUI
import VoxCarrelAppCore

/// A book's cover, fitted (never cropped) into the space it is given; for a book with no
/// cover, a tinted upright box with the title's initials.
struct CoverView: View {
    let row: BookRow
    /// The longest side the cover is ever shown at here, in points. The cover is shrunk
    /// to this, so that a list of small covers does not hold large images.
    let maxSide: CGFloat
    var cornerRadius: CGFloat = 4

    @Environment(\.displayScale) private var displayScale
    /// The outcome of the last read: the request it was for, and the image if there was one.
    @State private var loaded: (request: CoverThumbnails.Request, image: CGImage?)?

    private var request: CoverThumbnails.Request? {
        row.coverURL.map {
            CoverThumbnails.Request(
                url: $0, modified: row.coverModified, maxPixel: Int((maxSide * displayScale).rounded(.up)))
        }
    }

    var body: some View {
        let request = request
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        Group {
            if let request {
                if let image = image(for: request) {
                    Image(decorative: image, scale: displayScale)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .clipShape(shape)
                        .overlay(shape.strokeBorder(.primary.opacity(0.15), lineWidth: 0.5))
                } else if loaded?.request == request {
                    // The file is there and is not a picture.
                    CoverPlaceholder(row: row, side: maxSide, cornerRadius: cornerRadius)
                } else {
                    // Being read: a quiet box, so that scrolling does not flash initials.
                    shape.fill(.quaternary)
                        .aspectRatio(CoverPlaceholder.aspectRatio, contentMode: .fit)
                }
            } else {
                CoverPlaceholder(row: row, side: maxSide, cornerRadius: cornerRadius)
            }
        }
        .task(id: request) {
            guard let request else { return }
            let image = await CoverThumbnails.shared.image(for: request)
            if !Task.isCancelled { loaded = (request, image) }
        }
    }

    /// What was read for this request, or what is in memory from an earlier time it was shown.
    private func image(for request: CoverThumbnails.Request) -> CGImage? {
        if let loaded, loaded.request == request { return loaded.image }
        return CoverThumbnails.shared.cached(request)
    }
}

/// G1: what stands in for a cover: the title's initials on a tint of the title's own.
struct CoverPlaceholder: View {
    /// Width to height, as a paperback.
    static let aspectRatio: CGFloat = 2.0 / 3.0

    let initials: String
    /// The tint, from 0 up to 1.
    let hue: Double
    /// The longest side it is shown at, which sizes the letters.
    let side: CGFloat
    var cornerRadius: CGFloat = 4

    init(initials: String, hue: Double, side: CGFloat, cornerRadius: CGFloat = 4) {
        self.initials = initials
        self.hue = hue
        self.side = side
        self.cornerRadius = cornerRadius
    }

    init(row: BookRow, side: CGFloat, cornerRadius: CGFloat = 4) {
        self.init(initials: row.coverInitials, hue: row.placeholderHue, side: side, cornerRadius: cornerRadius)
    }

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color(hue: hue, saturation: 0.38, brightness: 0.70),
                        Color(hue: hue, saturation: 0.50, brightness: 0.48),
                    ],
                    startPoint: .top, endPoint: .bottom)
            )
            .aspectRatio(Self.aspectRatio, contentMode: .fit)
            .overlay {
                // Too small to read in a list's thumbnail.
                if side >= 60 {
                    Text(initials)
                        .font(.system(size: side * 0.2, weight: .semibold, design: .serif))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.4)
                        .padding(side * 0.06)
                }
            }
            .accessibilityHidden(true)
    }
}

/// A cover that is not a file of the library: one chosen and not yet saved, or one found
/// in a file that is about to be imported. Drawn from its data.
struct DataCover: View, Equatable {
    let data: Data
    let cornerRadius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .clipShape(shape)
                .overlay(shape.strokeBorder(.primary.opacity(0.15), lineWidth: 0.5))
        } else {
            shape.fill(.quaternary)
                .aspectRatio(CoverPlaceholder.aspectRatio, contentMode: .fit)
        }
    }
}

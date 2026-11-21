import AppKit
import ImageIO

/// G6: covers shrunk to the size they are shown at, and kept in memory.
///
/// A cover is read and shrunk off the main thread the first time it is asked for. What
/// is kept is named by the file's path, when it was last written and the size asked for,
/// so a cover that has been replaced is read again and never shown stale. The cache
/// gives memory back when the system is short of it, and holds no more than its limit.
@MainActor
final class CoverThumbnails {
    static let shared = CoverThumbnails()

    /// One cover at one size.
    struct Request: Hashable, Sendable {
        var url: URL
        /// When the file was last written, as the book's row has it.
        var modified: Date?
        /// The longest side wanted, in pixels: points × the screen's scale.
        var maxPixel: Int

        fileprivate var key: NSString {
            "\(url.path)|\(modified?.timeIntervalSinceReferenceDate ?? 0)|\(maxPixel)" as NSString
        }
    }

    private final class Entry {
        let image: CGImage

        init(_ image: CGImage) {
            self.image = image
        }
    }

    private let cache = NSCache<NSString, Entry>()
    /// Covers being read now, so that two views asking for the same one read it once.
    private var loading: [Request: Task<CGImage?, Never>] = [:]

    init() {
        // Pixels held, as bytes. A grid cover on a Retina screen is about a megabyte.
        cache.totalCostLimit = 192 * 1024 * 1024
    }

    /// The cover if it is in memory already. Does not touch the disk.
    func cached(_ request: Request) -> CGImage? {
        cache.object(forKey: request.key)?.image
    }

    /// The cover, read and shrunk if it is not in memory; nil when the file is not an image.
    func image(for request: Request) async -> CGImage? {
        if let image = cached(request) { return image }
        if let task = loading[request] { return await task.value }
        let task = Task.detached(priority: .userInitiated) { Self.shrink(request) }
        loading[request] = task
        let image = await task.value
        loading[request] = nil
        if let image {
            cache.setObject(Entry(image), forKey: request.key, cost: image.bytesPerRow * image.height)
        }
        return image
    }

    /// Reads the file and makes a decoded image no longer than `maxPixel` on either side.
    private nonisolated static func shrink(_ request: Request) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(request.url as CFURL, sourceOptions) else { return nil }
        let options =
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: max(1, request.maxPixel),
            ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }
}

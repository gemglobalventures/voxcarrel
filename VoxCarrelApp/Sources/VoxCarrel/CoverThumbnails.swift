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

    // MARK: Covers that are data, not files

    /// One cover held as data, at one size. Named by how long the data is and a sample
    /// of it, so that telling two apart does not mean reading megabytes.
    struct DataRequest: Hashable, Sendable {
        let data: Data
        let maxPixel: Int
        private let sample: Int

        init(data: Data, maxPixel: Int) {
            self.data = data
            self.maxPixel = maxPixel
            var hasher = Hasher()
            hasher.combine(data.count)
            // The start of every JPEG is alike: the middle and the end are sampled too.
            let step = max(1, data.count / 64)
            for offset in stride(from: 0, to: data.count, by: step) { hasher.combine(data[data.startIndex + offset]) }
            hasher.combine(data.suffix(256))
            sample = hasher.finalize()
        }

        static func == (a: DataRequest, b: DataRequest) -> Bool {
            a.maxPixel == b.maxPixel && a.sample == b.sample && a.data.count == b.data.count
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(maxPixel)
            hasher.combine(sample)
        }

        fileprivate var key: NSString { "data|\(data.count)|\(sample)|\(maxPixel)" as NSString }
    }

    private var loadingData: [DataRequest: Task<CGImage?, Never>] = [:]

    func cached(_ request: DataRequest) -> CGImage? {
        cache.object(forKey: request.key)?.image
    }

    /// The cover, shrunk off the main thread if it is not in memory; nil when the data is not an image.
    func image(for request: DataRequest) async -> CGImage? {
        if let image = cached(request) { return image }
        if let task = loadingData[request] { return await task.value }
        let task = Task.detached(priority: .userInitiated) {
            let options = [kCGImageSourceShouldCache: false] as CFDictionary
            return CGImageSourceCreateWithData(request.data as CFData, options).flatMap {
                Self.thumbnail(of: $0, maxPixel: request.maxPixel)
            }
        }
        loadingData[request] = task
        let image = await task.value
        loadingData[request] = nil
        if let image {
            cache.setObject(Entry(image), forKey: request.key, cost: image.bytesPerRow * image.height)
        }
        return image
    }

    private nonisolated static func thumbnail(of source: CGImageSource, maxPixel: Int) -> CGImage? {
        let options =
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixel),
            ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
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

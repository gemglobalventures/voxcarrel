import Foundation

/// One cover image per book, kept beside the database.
public struct CoverStore: Sendable {
    private let layout: LibraryLayout

    /// Every extension a stored cover can have. A book normally has one of them; when an
    /// older one could not be removed, the newest file is the cover.
    private static let extensions = ["jpg", "png", "img"]

    public init(layout: LibraryLayout) {
        self.layout = layout
    }

    private func location(_ bookId: Int64, _ ext: String) -> URL {
        layout.coversFolder.appendingPathComponent("\(bookId).\(ext)", isDirectory: false)
    }

    /// The stored cover, or nil. Of several files for one book, the most recently written.
    public func url(for bookId: Int64) -> URL? {
        var newest: (url: URL, date: Date)?
        for url in Self.extensions.map({ location(bookId, $0) })
        where FileManager.default.fileExists(atPath: url.path) {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if newest == nil || date > newest!.date { newest = (url, date) }
        }
        return newest?.url
    }

    /// Every stored cover, by book: where it is and when it was last changed. The
    /// covers folder is read once, however many covers it holds; for a book with more
    /// than one file there, the newest, as `url(for:)` gives.
    public func all() -> [Int64: (url: URL, modified: Date)] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: layout.coversFolder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        else { return [:] }
        var found: [Int64: (url: URL, modified: Date)] = [:]
        for url in files where Self.extensions.contains(url.pathExtension) {
            guard let id = Int64(url.deletingPathExtension().lastPathComponent) else { continue }
            let date = (try? url.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast
            // The same place `url(for:)` names for it, so that the two always agree.
            let place = location(id, url.pathExtension)
            if let kept = found[id] {
                // Two of one age: the kind `url(for:)` comes to first.
                let rank = { (ext: String) in Self.extensions.firstIndex(of: ext) ?? .max }
                if kept.modified > date || (kept.modified == date && rank(kept.url.pathExtension) <= rank(url.pathExtension)) { continue }
            }
            found[id] = (place, date)
        }
        return found
    }

    /// The stored cover's bytes, typed by what they are, or nil when there is none.
    public func image(for bookId: Int64) -> CoverImage? {
        guard let url = url(for: bookId), let data = try? Data(contentsOf: url) else { return nil }
        return CoverImage.stored(data)
    }

    /// Replaces any existing cover for the book. The file extension follows the image type.
    ///
    /// The new image is written first, so a failed write leaves the previous cover in place.
    /// Removing a previous cover of another extension is best effort: if it cannot be
    /// removed the call still succeeds, and the new file, being the newest, is the cover.
    public func set(_ image: CoverImage, for bookId: Int64) throws {
        let ext: String
        switch CoverImage.sniffedMIME(image.data) {
        case "image/jpeg": ext = "jpg"
        case "image/png": ext = "png"
        default: ext = "img"
        }
        try FileManager.default.createDirectory(
            at: layout.coversFolder, withIntermediateDirectories: true)
        try image.data.write(to: location(bookId, ext), options: .atomic)
        try? removeCovers(of: bookId, except: ext)
    }

    public func remove(for bookId: Int64) throws {
        try removeCovers(of: bookId, except: nil)
    }

    private func removeCovers(of bookId: Int64, except kept: String?) throws {
        // Every file is tried; the first failure is reported once all have been.
        var failure: Error?
        for ext in Self.extensions where ext != kept {
            let url = location(bookId, ext)
            if FileManager.default.fileExists(atPath: url.path) {
                do { try FileManager.default.removeItem(at: url) } catch { failure = failure ?? error }
            }
        }
        if let failure { throw failure }
    }
}

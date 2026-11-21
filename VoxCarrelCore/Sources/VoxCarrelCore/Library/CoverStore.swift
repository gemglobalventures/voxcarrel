import Foundation

/// One cover image per book, kept beside the database.
public struct CoverStore: Sendable {
    private let layout: LibraryLayout

    /// Every extension a stored cover can have; a book has at most one of them.
    private static let extensions = ["jpg", "png", "img"]

    public init(layout: LibraryLayout) {
        self.layout = layout
    }

    private func location(_ bookId: Int64, _ ext: String) -> URL {
        layout.coversFolder.appendingPathComponent("\(bookId).\(ext)", isDirectory: false)
    }

    /// The stored cover, or nil.
    public func url(for bookId: Int64) -> URL? {
        Self.extensions.map { location(bookId, $0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The stored cover's bytes, typed by what they are, or nil when there is none.
    public func image(for bookId: Int64) -> CoverImage? {
        guard let url = url(for: bookId), let data = try? Data(contentsOf: url) else { return nil }
        return CoverImage.stored(data)
    }

    /// Replaces any existing cover for the book. The file extension follows the image type.
    ///
    /// The new image is written first, so a failed write leaves the previous cover in place.
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
        try removeCovers(of: bookId, except: ext)
    }

    public func remove(for bookId: Int64) throws {
        try removeCovers(of: bookId, except: nil)
    }

    private func removeCovers(of bookId: Int64, except kept: String?) throws {
        for ext in Self.extensions where ext != kept {
            let url = location(bookId, ext)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }
}

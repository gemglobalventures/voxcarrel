import Foundation

/// Guesses a title and author from file and folder names.
public enum FilenameParser {
    /// Folder names (lowercased) that are places, not authors or books.
    static let genericFolders: Set<String> = [
        "downloads", "desktop", "documents", "audiobooks", "ebooks", "books",
    ]

    /// - Parameters:
    ///   - url: A book file, or the folder that is the book.
    ///   - isFolder: True when `url` is a folder (its name keeps any dots).
    ///   - parentIsBookFolder: True when `url` is a file whose folder holds just
    ///     this one book, so the author is the folder above that one. A file in a
    ///     folder with its own name is treated this way without being told.
    public static func guess(
        from url: URL, isFolder: Bool, parentIsBookFolder: Bool = false
    ) -> (title: String, author: String?) {
        let name = isFolder ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        var title = name.trimmingCharacters(in: .whitespaces)

        if let range = name.range(of: " - ") {
            let before = name[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            let after = name[range.upperBound...].trimmingCharacters(in: .whitespaces)
            if !before.isEmpty, !after.isEmpty {
                // "01 - Chapter One" is a part or series number, not an author.
                guard before.allSatisfy(\.isWholeNumber) else { return (after, before) }
                title = after
            }
        }

        var authorFolder = url.deletingLastPathComponent()
        if !isFolder,
           parentIsBookFolder || authorFolder.lastPathComponent.lowercased() == name.lowercased() {
            authorFolder = authorFolder.deletingLastPathComponent()
        }
        let parent = authorFolder.lastPathComponent
        let author: String? =
            parent.isEmpty || parent == "/" || genericFolders.contains(parent.lowercased())
            ? nil : parent
        return (title, author)
    }
}

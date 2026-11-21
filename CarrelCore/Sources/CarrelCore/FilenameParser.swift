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
    public static func guess(from url: URL, isFolder: Bool) -> (title: String, author: String?) {
        let name = isFolder ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent

        if let range = name.range(of: " - ") {
            let author = name[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            let title = name[range.upperBound...].trimmingCharacters(in: .whitespaces)
            if !author.isEmpty, !title.isEmpty {
                return (title, author)
            }
        }

        let parent = url.deletingLastPathComponent().lastPathComponent
        let author: String? =
            parent.isEmpty || parent == "/" || genericFolders.contains(parent.lowercased())
            ? nil : parent
        return (name.trimmingCharacters(in: .whitespaces), author)
    }
}

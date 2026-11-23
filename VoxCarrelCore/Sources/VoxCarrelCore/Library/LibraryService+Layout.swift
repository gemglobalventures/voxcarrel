import Foundation
import os

extension LibraryService {
    /// The pattern the library files its books by: the one stored in its catalogue, or
    /// the standard pattern when none is stored.
    ///
    /// A stored pattern that cannot be read (written by a newer version, or damaged)
    /// reads as the standard pattern too. That is logged, once for each text, and
    /// never thrown: only a catalogue that cannot be read at all throws.
    public func folderPattern() throws -> FolderPattern {
        guard let text = try store.folderPatternText() else { return .standard }
        do {
            return try FolderPattern(text)
        } catch {
            if unreadablePatternLogged != text {
                unreadablePatternLogged = text
                Self.layoutLog.error(
                    "The library's folder pattern cannot be read, so the standard one is used: \(text, privacy: .public)")
            }
            return .standard
        }
    }

    private static let layoutLog = Logger(subsystem: "VoxCarrelCore", category: "FolderLayout")

    /// What the library's folder pattern needs and this book lacks, in pattern order;
    /// empty for a book that can be filed. A book with no files is never filed, so it
    /// lacks nothing.
    public func tokensMissingForFiling(_ book: Book, files: [BookFile]) throws -> [FolderToken] {
        guard !files.isEmpty else { return [] }
        return try folderPattern().missingTokens(for: Self.patternValues(of: book, files: files))
    }

    /// Why the library's folder pattern cannot file this book, as a sentence ("No
    /// narrator, which the folder layout needs."); nil when it can, and for a book with
    /// no files, which is never filed.
    /// - Throws: `LibraryError.bookNotFound` for an unknown id.
    public func unfiledReason(for bookId: Int64) throws -> String? {
        guard let book = try store.book(id: bookId) else { throw LibraryError.bookNotFound(bookId) }
        let files = try store.files(bookId: bookId)
        guard !files.isEmpty else { return nil }
        return try folderPattern().unfiledReason(for: Self.patternValues(of: book, files: files))
    }

    /// What a book gives a folder pattern: its details, and whether any of its files is audio.
    static func patternValues(of book: Book, files: [BookFile]) -> FolderPatternValues {
        FolderPatternValues(metadata: book.metadata, hasAudio: files.contains { $0.role == .audio })
    }
}

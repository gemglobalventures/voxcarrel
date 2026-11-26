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

    /// Whether the library has a folder pattern stored that this code cannot read
    /// (written by a newer version, or damaged). Its books are then filed by the
    /// standard pattern (`folderPattern`), until a pattern that can be read is stored.
    public func storedFolderPatternIsUnreadable() throws -> Bool {
        guard let text = try store.folderPatternText() else { return false }
        return (try? FolderPattern(text)) == nil
    }

    private static let layoutLog = Logger(subsystem: "VoxCarrelCore", category: "FolderLayout")

    /// What the library's folder pattern needs and this book lacks, in pattern order;
    /// empty for a book that can be filed. A book with no files is never filed, so it
    /// lacks nothing.
    public func tokensMissingForFiling(_ book: Book, files: [BookFile]) throws -> [FolderToken] {
        guard !files.isEmpty else { return [] }
        return try folderPattern().missingTokens(for: Self.patternValues(of: book, files: files))
    }

    /// Why this book is not, and cannot now be, filed where the library's folder pattern
    /// files it, as a sentence: what the pattern needs and the book lacks ("No narrator,
    /// which the folder layout needs."), or that the folder it belongs in is another
    /// book's ("Another book uses the folder this book belongs in."). Nil when nothing
    /// stands in its way, and for a book with no files, which is never filed.
    /// - Throws: `LibraryError.bookNotFound` for an unknown id.
    public func unfiledReason(for bookId: Int64) throws -> String? {
        guard let book = try store.book(id: bookId) else { throw LibraryError.bookNotFound(bookId) }
        let files = try store.files(bookId: bookId)
        guard !files.isEmpty else { return nil }
        let pattern = try folderPattern()
        if let reason = unfiledReason(
            for: book.metadata, hasAudio: files.contains { $0.role == .audio }, pattern: pattern) {
            return reason
        }
        // FP41
        var owners: FolderOwners?
        guard let folder = bookFolder(
            for: book.metadata, hasAudio: files.contains { $0.role == .audio }, pattern: pattern,
            titleSuffix: book.editionSuffix),
            isAnotherBooksFolder(folder, for: bookId, owners: &owners)
        else { return nil }
        return Self.folderTakenReason
    }

    /// What a book gives a folder pattern: its details, and whether any of its files is audio.
    static func patternValues(of book: Book, files: [BookFile]) -> FolderPatternValues {
        FolderPatternValues(
            metadata: book.metadata, hasAudio: files.contains { $0.role == .audio }, titleSuffix: book.editionSuffix)
    }
}

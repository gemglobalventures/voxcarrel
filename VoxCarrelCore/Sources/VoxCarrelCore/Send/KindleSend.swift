import Foundation

/// What of a book can be sent to a Kindle.
public enum KindleSendChoice: Equatable, Sendable {
    /// This file as it is: an EPUB or a PDF, which a Kindle takes.
    case file(BookFile)
    /// Nothing as it is, but an EPUB could be made of this file and sent.
    case convertFirst(BookFile)
    /// The book has no ebook on this Mac.
    case nothing
}

/// Why a copy could not be made to send to a Kindle.
public enum KindleSendError: Error, Equatable {
    /// Something that is not a folder of this user's own has the name of the folder the
    /// copies are made in.
    case stagingFolderIsNotOurs
    /// The file to copy is a link, a folder or something else that is not a plain file.
    case notARegularFile(String)
}

extension LibraryService {
    /// The folder, in a temporary folder, that every copy made to send to a Kindle is in.
    public static let kindleStagingFolderName = "VoxCarrelKindle"

    /// KS1: what of a book to send to a Kindle: its first EPUB; without one its first
    /// PDF; without either, the first ebook an EPUB can be made of, to convert first.
    ///
    /// Only the book's ebooks count, never an extra, and only files that are on this
    /// Mac: one that is missing, or kept in iCloud and not downloaded, is passed over.
    /// A book that is only owned elsewhere has no files, and so nothing to send.
    /// Only reads.
    public func kindleChoice(ofBook bookId: Int64) throws -> KindleSendChoice {
        guard try store.book(id: bookId) != nil else { throw LibraryError.bookNotFound(bookId) }
        let ebooks = try store.files(bookId: bookId).filter { file in
            guard file.role == .ebook else { return false }
            let url = store.url(for: file)
            return SendPackage.isRegularFile(url) && BookScanner.isOnThisMac(url)
        }
        if let epub = ebooks.first(where: { $0.format == .epub }) { return .file(epub) }
        if let pdf = ebooks.first(where: { $0.format == .pdf }) { return .file(pdf) }
        if let other = ebooks.first(where: { $0.format.convertsToEPUB }) { return .convertFirst(other) }
        return .nothing
    }

    /// KS2: copies a file of the library to a new folder of its own in a temporary
    /// folder, named by the book's title, and returns the copy.
    ///
    /// The copy is what is handed to Amazon's app or to the mail program: Amazon's app
    /// shows a book under the name of its file, and nothing outside VoxCarrel is ever
    /// handed a file that is inside the library. The library's file is only read.
    /// Every copy made earlier is removed first, so that they do not pile up.
    ///
    /// - Parameter root: The temporary folder to make VoxCarrel's own folder of
    ///   copies in. Tests give one of their own.
    public func stageForKindle(
        _ file: BookFile, title: String, under root: URL = FileManager.default.temporaryDirectory
    ) throws -> URL {
        let source = store.url(for: file)
        guard SendPackage.isRegularFile(source) else {
            throw KindleSendError.notARegularFile(source.lastPathComponent)
        }
        let fm = FileManager.default
        let parent = root.appendingPathComponent(Self.kindleStagingFolderName, isDirectory: true)
        var info = stat()
        if lstat(parent.path, &info) != 0 {
            try fm.createDirectory(
                at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        // A link of that name could lead anywhere, and what is in it is about to be removed.
        guard lstat(parent.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid() else {
            throw KindleSendError.stagingFolderIsNotOurs
        }
        for earlier in (try? fm.contentsOfDirectory(atPath: parent.path)) ?? [] {
            try? fm.removeItem(at: parent.appendingPathComponent(earlier))
        }
        let folder = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        let copy = folder.appendingPathComponent(
            Self.kindleFileName(title: title, extension: source.pathExtension), isDirectory: false)
        do {
            try fm.copyItem(at: source, to: copy)
        } catch {
            try? fm.removeItem(at: folder)
            throw error
        }
        // The copy can be read and removed whatever the original allows.
        try? fm.setAttributes([.immutable: false], ofItemAtPath: copy.path)
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: copy.path)
        return copy
    }

    /// The name a book of this title is sent to a Kindle under.
    static func kindleFileName(title: String, extension ext: String) -> String {
        var base = PathBuilder.sanitise(title)
        // A file name is at most 255 bytes on disk, and letters can take several each.
        while base.utf8.count > 240 { base.removeLast() }
        while let last = base.last, last == "." || last == " " { base.removeLast() }
        if base.isEmpty { base = "Book" }
        return ext.isEmpty ? base : "\(base).\(ext)"
    }
}

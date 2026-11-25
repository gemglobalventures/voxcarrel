import Foundation

/// Why an ebook was not converted. Nothing was changed.
public enum ConversionError: Error, Equatable {
    /// No converter is installed on this Mac.
    case noConverter
    /// The book has no ebook file of a kind that can be converted, or has an EPUB already.
    case nothingToConvert
    /// The file is protected against copying, and so cannot be read to be converted.
    case protected
    /// The converter ran and gave up; the last thing it said.
    case failed(String)
    /// The converter took longer than it is given.
    case tookTooLong
    /// What the converter made is not an EPUB that can be read.
    case notAnEPUB
}

/// Something that turns an ebook file into an EPUB.
public protocol EbookConverter: Sendable {
    /// Whether it can be used on this Mac now.
    var isAvailable: Bool { get }
    /// Makes an EPUB of `source` at `destination`. The source is only read.
    func convert(_ source: URL, to destination: URL) throws
}

/// The converter that comes with calibre, run as a program of its own when calibre is
/// installed. VoxCarrel holds none of calibre's code: it asks calibre to do the work,
/// as running `ebook-convert` in Terminal would.
public struct CalibreConverter: EbookConverter {
    /// Where calibre's converter is looked for.
    public static var usualPlaces: [URL] {
        ["/Applications/calibre.app", NSHomeDirectory() + "/Applications/calibre.app"].map {
            URL(fileURLWithPath: $0).appendingPathComponent("Contents/MacOS/ebook-convert")
        }
    }

    let places: [URL]
    /// How long a conversion may take, in seconds.
    let limit: TimeInterval

    public init(places: [URL] = CalibreConverter.usualPlaces, limit: TimeInterval = 600) {
        self.places = places
        self.limit = limit
    }

    var tool: URL? {
        places.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public var isAvailable: Bool { tool != nil }

    public func convert(_ source: URL, to destination: URL) throws {
        guard let tool else { throw ConversionError.noConverter }
        let process = Process()
        process.executableURL = tool
        process.arguments = [source.path, destination.path]
        // What it says is kept in a file, not a pipe: a pipe nobody reads fills up and
        // stops the program that writes to it.
        let log = destination.deletingPathExtension().appendingPathExtension("log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: log) }
        guard let output = try? FileHandle(forWritingTo: log) else { throw ConversionError.failed("No log could be kept.") }
        defer { try? output.close() }
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { throw ConversionError.failed(error.localizedDescription) }

        let deadline = Date().addingTimeInterval(limit)
        while process.isRunning {
            if Date() > deadline {
                process.terminate()
                process.waitUntilExit()
                try? FileManager.default.removeItem(at: destination)
                throw ConversionError.tookTooLong
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: destination.path) else {
            let said = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            try? FileManager.default.removeItem(at: destination)
            throw Self.error(from: said)
        }
    }

    /// What went wrong, from what the converter said.
    static func error(from said: String) -> ConversionError {
        if said.range(of: "DRM", options: .caseInsensitive) != nil { return .protected }
        let last = said.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty }
        return .failed(String((last ?? "The converter stopped without saying why.").prefix(300)))
    }
}

/// What converting a book did.
public struct EbookConversion: Equatable, Sendable {
    /// The EPUB that was added to the book.
    public var file: BookFile
    /// The file it was made from, which is still the book's.
    public var source: BookFile
}

extension FileFormat {
    /// True for the kinds of ebook an EPUB can be made of. A PDF is left out: its pages
    /// are pictures of pages, and what comes of converting one is seldom worth having.
    public var convertsToEPUB: Bool {
        switch self {
        case .mobi, .azw3, .azw, .prc, .fb2, .lit, .chm, .djvu: true
        case .epub, .pdf, .m4b, .m4a, .mp3: false
        }
    }
}

extension LibraryService {
    /// The file of a book that an EPUB would be made from: its first ebook of a kind
    /// that converts, when the book has no EPUB yet and has a folder of its own.
    public func fileToConvert(ofBook bookId: Int64) throws -> BookFile? {
        guard let book = try store.book(id: bookId), book.folderPath != nil else { return nil }
        let files = try store.files(bookId: bookId)
        guard !files.contains(where: { $0.format == .epub }) else { return nil }
        return files.first { $0.role == .ebook && $0.format.convertsToEPUB }
    }

    /// Makes an EPUB of a book's ebook and adds it to the book, beside the file it was
    /// made from, which is neither changed nor removed.
    ///
    /// The EPUB is made in a folder of its own on the library's disk. Before anything
    /// of the library is touched it is read back as an EPUB, and the book's details
    /// and cover are written into it. Then it is moved into the book's folder under the
    /// book's title and added to the catalogue. A failure at any point leaves the book
    /// and its folder exactly as they were.
    ///
    /// Not undoable through VoxCarrel: remove the file to undo it. If the last
    /// recorded operation involved this book, it can no longer be undone and is forgotten.
    public func convertToEPUB(bookId: Int64, with converter: any EbookConverter) throws -> EbookConversion {
        try refuseWhileLayoutChangeIsInterrupted()
        guard converter.isAvailable else { throw ConversionError.noConverter }
        guard let book = try store.book(id: bookId) else { throw LibraryError.bookNotFound(bookId) }
        guard let source = try fileToConvert(ofBook: bookId), let folderPath = book.folderPath else {
            throw ConversionError.nothingToConvert
        }
        let fm = FileManager.default
        let sourceURL = store.url(for: source)
        let work = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: store.libraryRoot, create: true)
        defer { try? fm.removeItem(at: work) }
        let staged = work.appendingPathComponent("converted.epub")
        try converter.convert(sourceURL, to: staged)
        guard fm.fileExists(atPath: staged.path), (try? metadataIO.read(staged)) != nil else { throw ConversionError.notAnEPUB }
        let cover = covers.image(for: bookId)
        _ = try metadataIO.write(book.metadata, cover: cover.map { .set($0) } ?? .keep, to: staged)
        guard (try? metadataIO.read(staged)) != nil else { throw ConversionError.notAnEPUB }

        let folder = store.url(forFolder: folderPath)
        let taken = Set(((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).map { $0.lowercased() })
        let stem = PathBuilder.sanitise(book.title)
        var name = "\(stem).epub"
        var count = 2
        while taken.contains(name.lowercased()) {
            name = "\(stem) \(count).epub"
            count += 1
        }
        let destination = folder.appendingPathComponent(name)
        let rows = try store.files(bookId: bookId)
        try fm.moveItem(at: staged, to: destination)
        do {
            var added = BookFile(path: "\(folderPath)/\(name)", format: .epub, role: .ebook, position: rows.count)
            added.contentPrint = ContentPrint.of(destination)
            let newRows = rows + [added]
            var updated = book
            updated.appOnlyFields = keepingCoverMembership(
                of: book, in: Self.appOnlyFields(files: workingFiles(for: newRows), hasStoredCover: false))
            var change = LibraryChange()
            change.writes = [.init(book: updated, files: newRows)]
            change.clearsJournal = try lastBatchInvolves(bookId: bookId, files: rows.map { store.url(for: $0) })
            try beforeCommit?()
            try store.apply(change)
            if change.clearsJournal { forgetUndoData() }
        } catch {
            try? fm.removeItem(at: destination)
            throw error
        }
        guard let file = try store.files(bookId: bookId).last(where: { $0.format == .epub }) else {
            throw ConversionError.notAnEPUB
        }
        return EbookConversion(file: file, source: source)
    }
}

import Foundation

extension LibraryService {
    /// The size over which a send is warned of as large: a gigabyte, as the Finder counts.
    static let largeSendBytes: Int64 = 1_000_000_000

    /// The audio formats the phone's player takes.
    static let sendableFormats: Set<FileFormat> = [.m4b, .m4a, .mp3]

    /// The name of the zip a book of this title is sent as.
    static func sendPackageName(title: String) -> String {
        var base = PathBuilder.sanitise(title)
        // A file name is at most 255 bytes on disk, and letters can take several each.
        while base.utf8.count > 240 { base.removeLast() }
        while let last = base.last, last == "." || last == " " { base.removeLast() }
        return (base.isEmpty ? "Audiobook" : base) + ".zip"
    }

    /// Whether a book can be sent to the phone, what the owner should be warned of, and
    /// exactly which files would go, with the fingerprint a send of them is recorded under.
    ///
    /// Only reads: nothing on disk and nothing in the catalogue is changed. Refused, like
    /// other operations, while an interrupted change of folder layout is unresolved.
    public func sendCheck(for bookId: Int64) throws -> SendCheck {
        try refuseWhileLayoutChangeIsInterrupted()
        guard let book = try store.book(id: bookId) else { throw LibraryError.bookNotFound(bookId) }
        let rows = try store.files(bookId: bookId)
        // SP1: the rows come in position order, which is the order the book plays in.
        let audio = rows.filter { $0.role == .audio }
        let urls = audio.map { store.url(for: $0) }
        let packageName = Self.sendPackageName(title: book.title)

        // SP2
        var blockers: [SendBlocker] = []
        if audio.isEmpty { blockers.append(.noAudio) }
        for url in urls where !Self.isFileOnDisk(url) {
            blockers.append(.missingFile(url.lastPathComponent))
        }
        for (row, url) in zip(audio, urls) where !Self.sendableFormats.contains(row.format) {
            blockers.append(.unsupportedFormat(url.lastPathComponent))
        }
        if !rows.isEmpty, book.folderPath == nil { blockers.append(.notFiled) }
        guard blockers.isEmpty else {
            return SendCheck(
                blockers: blockers, warnings: [], files: [], totalBytes: 0, needsPackage: false,
                packageName: packageName, fingerprint: SendFingerprint(files: []))
        }

        // SP4
        var entries: [SentFile] = []
        var anyCover = false
        for url in urls {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            let contents = try? metadataIO.read(url)
            if contents?.cover != nil { anyCover = true }
            entries.append(SentFile(
                name: url.lastPathComponent, bytes: size, seconds: contents?.metadata.durationSeconds,
                chapters: (contents?.chapters ?? []).map { SentChapter(start: $0.start, title: $0.title) }))
        }
        let totalBytes = entries.reduce(0) { $0 + $1.bytes }

        // SP3
        var warnings: [SendWarning] = []
        let wrongLength = audio.filter { $0.lengthProblem != nil }.count
        if wrongLength > 0 { warnings.append(.wrongLengthHeader(files: wrongLength)) }
        let notWritten = audio.filter { $0.writeProblem != nil }.count
        if notWritten > 0 { warnings.append(.tagsNotWritten(files: notWritten)) }
        if !anyCover { warnings.append(.noCoverInFile) }
        if let last = try store.sentRecords(bookId: bookId).first { warnings.append(.sentBefore(last.sentAt)) }
        if totalBytes > sendLargeOver { warnings.append(.large(bytes: totalBytes)) }

        return SendCheck(
            blockers: [], warnings: warnings, files: urls, totalBytes: totalBytes, needsPackage: urls.count > 1,
            packageName: packageName, fingerprint: SendFingerprint(files: entries))
    }

    /// Whether something that is not a folder is at `url`.
    private static func isFileOnDisk(_ url: URL) -> Bool {
        var isFolder: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) && !isFolder.boolValue
    }

    /// The one file to send for a checked book: the audio file itself, untouched, when
    /// there is one; for several, a zip of them that this writes into `folder`
    /// (`SendCheck.packageName`), uncompressed, the files at its top level under their own
    /// names in playing order.
    ///
    /// Nothing is ever written into the library, and no library file is changed: `folder`
    /// must be outside the library (`SendError.folderInsideLibrary`). It must exist, and
    /// must not already hold something of the package's name. A zip that fails part-way
    /// leaves nothing behind.
    public func makeSendPackage(for check: SendCheck, in folder: URL) throws -> URL {
        try refuseWhileLayoutChangeIsInterrupted()
        guard check.blockers.isEmpty, !check.files.isEmpty else { throw SendError.nothingToSend }
        let name = check.packageName
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw SendError.badPackageName
        }
        let destination = folder.appendingPathComponent(name, isDirectory: false)
        guard layout.relativeComponents(of: destination) == nil,
              LibraryLayout(root: LibraryLayout.canonicalFolder(layout.root))
                  .relativeComponents(of: LibraryLayout.canonicalFolder(folder).appendingPathComponent(name)) == nil
        else { throw SendError.folderInsideLibrary }

        if check.files.count == 1 { return check.files[0] }
        return try SendPackage.write(check.files, named: name, in: folder)
    }

    /// Records that a book was sent. Not an operation: it is not journaled, cannot be
    /// undone, and leaves what undo would reverse as it was.
    public func recordSent(bookId: Int64, method: SendMethod, fingerprint: SendFingerprint, at date: Date) throws {
        guard try store.book(id: bookId) != nil else { throw LibraryError.bookNotFound(bookId) }
        try store.insertSentRecord(
            SentRecord(bookId: bookId, sentAt: date, method: method, fingerprint: fingerprint))
    }

    /// Every recorded sending of a book, newest first. A book that is removed takes its
    /// records with it.
    public func sentRecords(for bookId: Int64) throws -> [SentRecord] {
        try store.sentRecords(bookId: bookId)
    }
}

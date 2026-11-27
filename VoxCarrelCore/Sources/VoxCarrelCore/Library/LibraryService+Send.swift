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

    /// The files of a book that can go with its audiobook when it is shared: its ebook
    /// files, and the PDFs kept with it as extras (a companion booklet, maps, charts).
    /// Only those that are on the disk now. Only reads.
    public func sendCompanions(for bookId: Int64) throws -> SendCompanions {
        let rows = try store.files(bookId: bookId)
        func present(_ wanted: [BookFile]) -> [URL] {
            wanted.map { store.url(for: $0) }.filter { Self.isFileOnDisk($0) }
        }
        return SendCompanions(
            ebooks: present(rows.filter { $0.role == .ebook }),
            pdfs: present(rows.filter { $0.role == .extra && $0.format == .pdf }))
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
        var firstCover: CoverImage?
        for url in urls {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            let contents = try? metadataIO.read(url)
            if contents?.cover != nil { anyCover = true }
            if firstCover == nil { firstCover = contents?.cover }
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
            packageName: packageName, fingerprint: SendFingerprint(files: entries),
            // SP11
            coverIsSquare: firstCover.flatMap(CoverSquaring.isSquare))
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
        try checkSendDestination(for: check, in: folder)
        if check.files.count == 1 { return check.files[0] }
        return try SendPackage.write(check.files, named: check.packageName, in: folder)
    }

    /// Refuses a send that cannot be made at all: while a layout change is unresolved, a
    /// check with blockers or no file, a package name that is not a plain name, or a
    /// folder that is the library or inside it.
    private func checkSendDestination(for check: SendCheck, in folder: URL) throws {
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
    }

    /// As `prepareSend`, giving only the file to send.
    public func makeSendPackage(for check: SendCheck, options: SendOptions, in folder: URL) throws -> URL {
        try prepareSend(for: check, options: options, in: folder).file
    }

    /// The one file to send for a checked book, with what the owner chose.
    ///
    /// With `squareCover` off, or a cover that is square already, or no cover, this is
    /// `makeSendPackage(for:in:)` and the check's own fingerprint. Otherwise the files
    /// are COPIED into `folder` and the squared cover is put into each copy with the
    /// verified tag writer, which changes nothing else in it; one file is sent as its
    /// copy, several as a zip of the copies. A copy that will not take the cover is sent
    /// exactly as the original is, and counted in `coversNotSquared`: never a reason to
    /// refuse. The library's own files are only read.
    public func prepareSend(for check: SendCheck, options: SendOptions, in folder: URL) throws -> PreparedSend {
        try checkSendDestination(for: check, in: folder)
        guard options.squareCover, let squared = squaredCover(for: check.files) else {
            return PreparedSend(
                file: try makeSendPackage(for: check, in: folder), fingerprint: check.fingerprint,
                coversSquared: 0, coversNotSquared: 0)
        }
        let fm = FileManager.default
        let single = check.files.count == 1
        let result = single ? check.files[0].lastPathComponent : check.packageName
        var info = stat()
        guard lstat(folder.appendingPathComponent(result).path, &info) != 0 else {
            throw SendError.packageExists(result)
        }
        // One file's copy is what is sent; several are copied to a folder of their own
        // that is gone again once the zip is made.
        let work = single ? folder : folder.appendingPathComponent(".copies-\(UUID().uuidString)", isDirectory: true)
        var made: [URL] = []
        defer { if !single { try? fm.removeItem(at: work) } }
        do {
            if !single { try fm.createDirectory(at: work, withIntermediateDirectories: false) }
            let write = sendCoverWriter ?? { try AudioTagIO.setCover($0, in: $1) }
            var entries = check.fingerprint.files
            var taken = 0, notTaken = 0
            var names = Set<String>()
            for (index, file) in check.files.enumerated() {
                let name = file.lastPathComponent
                guard names.insert(name.precomposedStringWithCanonicalMapping.lowercased()).inserted else {
                    throw SendError.nameClash(name)
                }
                guard SendPackage.isRegularFile(file) else { throw SendError.notARegularFile(name) }
                let copy = work.appendingPathComponent(name, isDirectory: false)
                try Self.copyForSending(file, to: copy)
                made.append(copy)
                do {
                    try write(squared, copy)
                    taken += 1
                } catch {
                    // Whatever became of the copy, what is sent is the original's bytes.
                    try? fm.removeItem(at: copy)
                    try Self.copyForSending(file, to: copy)
                    notTaken += 1
                }
                if index < entries.count, let size = try fm.attributesOfItem(atPath: copy.path)[.size] as? Int64 {
                    entries[index].bytes = size
                }
            }
            let file = single ? made[0] : try SendPackage.write(made, named: check.packageName, in: folder)
            return PreparedSend(
                file: file, fingerprint: SendFingerprint(files: entries), coversSquared: taken,
                coversNotSquared: notTaken)
        } catch {
            if single { made.forEach { try? fm.removeItem(at: $0) } }
            throw error
        }
    }

    /// The squared form of the cover of the first of these files that holds one; nil
    /// when none does, or it is square already, or it cannot be read.
    private func squaredCover(for files: [URL]) -> CoverImage? {
        for file in files {
            if let cover = (try? metadataIO.read(file))?.cover { return CoverSquaring.squared(cover) }
        }
        return nil
    }

    /// A copy of a library file that can be changed whatever the original allows.
    private static func copyForSending(_ file: URL, to copy: URL) throws {
        let fm = FileManager.default
        try fm.copyItem(at: file, to: copy)
        try? fm.setAttributes([.immutable: false], ofItemAtPath: copy.path)
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: copy.path)
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

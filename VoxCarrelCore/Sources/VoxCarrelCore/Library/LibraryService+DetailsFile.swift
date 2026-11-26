import Foundation

extension LibraryService {
    /// Brings the details files beside each book up to date with the catalogue,
    /// writing only those that are absent or say something else: `metadata.opf` for
    /// every book, and `metadata.json`, which Audiobookshelf reads, for a book that
    /// has an audiobook. A `metadata.json` written here beside a book that no longer
    /// has an audiobook is taken away.
    ///
    /// A book has one when it is filed in a folder of its own inside the library and
    /// that folder exists. A book that is not filed, has no files, or shares its folder
    /// with another book has none. A `metadata.opf` that was not written here is never
    /// overwritten. Nothing here can fail an operation: a file that cannot be written
    /// is left for the next time.
    /// - Parameter ids: The books to look at; nil for every book.
    /// - Returns: How many files were written.
    @discardableResult
    public func refreshDetailsFiles(ofBooks ids: [Int64]? = nil) -> Int {
        guard writesDetailsFiles else { return 0 }
        // Every book, whether or not hidden ones are being shown.
        let books: [Book]
        let owners: FolderOwners
        var withAudio = Set<Int64>()
        do {
            if let ids {
                guard !ids.isEmpty else { return 0 }
                books = try Set(ids).sorted().compactMap { try store.book(id: $0) }
            } else {
                books = try store.books()
            }
            guard books.contains(where: { $0.folderPath != nil }) else { return 0 }
            owners = try folderOwners()
            for file in try store.allFiles() where file.role == .audio {
                if let id = file.bookId { withAudio.insert(id) }
            }
        } catch {
            return 0
        }
        var written = 0
        let fm = FileManager.default
        for book in books {
            guard let id = book.id, let path = book.folderPath, let key = owners.folder(of: id),
                  !key.isEmpty, !owners.isUsed(key, byOtherThan: id)
            else { continue }
            let folder = store.url(forFolder: path)
            let hasCover = fm.fileExists(atPath: folder.appendingPathComponent(DetailsFile.coverName).path)
            let opf = Data(DetailsFile.text(for: book, hasCoverBeside: hasCover).utf8)
            if put(opf, marked: DetailsFile.mark, named: DetailsFile.fileName, in: folder) { written += 1 }
            if withAudio.contains(id) {
                let json = DetailsFile.audiobookData(for: book)
                if put(json, marked: DetailsFile.audiobookMark, named: DetailsFile.audiobookFileName, in: folder) {
                    written += 1
                }
            } else {
                let left = folder.appendingPathComponent(DetailsFile.audiobookFileName, isDirectory: false)
                if DetailsFile.isOurs(at: left) { try? fm.removeItem(at: left) }
            }
        }
        return written
    }

    /// Writes a details file into a book's folder when it is absent or says something
    /// else. One that lacks `mark` is somebody else's and is left as it is.
    /// - Returns: Whether the file was written.
    private func put(_ wanted: Data, marked mark: String, named name: String, in folder: URL) -> Bool {
        let fm = FileManager.default
        let file = folder.appendingPathComponent(name, isDirectory: false)
        // Read once: most often it is there and says what it should.
        if let existing = try? Data(contentsOf: file) {
            if existing == wanted { return false }
            guard existing.range(of: Data(mark.utf8)) != nil else { return false }
        } else {
            // Something that cannot be read is not replaced; and no folder is made.
            var isFolder: ObjCBool = false
            guard !fm.fileExists(atPath: file.path),
                  fm.fileExists(atPath: folder.path, isDirectory: &isFolder), isFolder.boolValue
            else { return false }
        }
        return (try? wanted.write(to: file, options: .atomic)) != nil
    }
}

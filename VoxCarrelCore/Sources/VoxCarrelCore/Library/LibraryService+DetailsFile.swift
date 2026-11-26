import Foundation

extension LibraryService {
    /// Brings the details file (`metadata.opf`) beside each book up to date with the
    /// catalogue, writing only those that are absent or say something else.
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
        do {
            if let ids {
                guard !ids.isEmpty else { return 0 }
                books = try Set(ids).sorted().compactMap { try store.book(id: $0) }
            } else {
                books = try store.books()
            }
            guard books.contains(where: { $0.folderPath != nil }) else { return 0 }
            owners = try folderOwners()
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
            let file = folder.appendingPathComponent(DetailsFile.fileName, isDirectory: false)
            let hasCover = fm.fileExists(atPath: folder.appendingPathComponent(DetailsFile.coverName).path)
            let wanted = Data(DetailsFile.text(for: book, hasCoverBeside: hasCover).utf8)
            // Read once: most often it is there and says what it should.
            if let existing = try? Data(contentsOf: file) {
                if existing == wanted { continue }
                guard existing.range(of: Data(DetailsFile.mark.utf8)) != nil else { continue }
            } else {
                // Something that cannot be read is not replaced; and no folder is made.
                var isFolder: ObjCBool = false
                guard !fm.fileExists(atPath: file.path),
                      fm.fileExists(atPath: folder.path, isDirectory: &isFolder), isFolder.boolValue
                else { continue }
            }
            if (try? wanted.write(to: file, options: .atomic)) != nil { written += 1 }
        }
        return written
    }
}

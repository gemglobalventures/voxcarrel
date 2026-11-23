import Foundation

extension LibraryService {
    /// One file to be filed: where it is now, and what it is to its book.
    struct FilingSource {
        var url: URL
        var role: FileRole
        /// For an extra: the name to file it under instead of the name it has now.
        var extraName: String? = nil
    }

    /// Where a book's files belong, and the moves needed to get them there.
    struct FilingPlan {
        /// The book's folder, in the capitalisation it has (or will have) on disk.
        var folder: URL
        /// One per file, in order: where the file is once the moves are made.
        var locations: [URL]
        /// Only the moves that are needed, each with the index of its file.
        var moves: [(index: Int, move: PlannedMove)]
    }

    /// The one place destinations are planned, for importing, adding to a book, saving
    /// and changing a role alike.
    ///
    /// Names come from `PathBuilder.fileNames` over the whole list; each destination uses
    /// the capitalisation of folders that already exist; and a file whose destination
    /// differs from where it is in nothing but capitalisation is not moved (the
    /// capitalisation decision): it stays exactly where and as it is spelled.
    func filingPlan(for files: [FilingSource], title: String, folder: URL) -> FilingPlan {
        let names = PathBuilder.fileNames(
            title: title,
            files: files.map { file in
                let named = file.role == .extra
                    ? file.extraName.map { file.url.deletingLastPathComponent().appendingPathComponent($0) }
                    : nil
                return CandidateFile(url: named ?? file.url, role: file.role)
            })
        var plan = FilingPlan(folder: folder, locations: [], moves: [])
        for (index, (file, name)) in zip(files, names).enumerated() {
            let destination = layout.adoptingExistingCapitalisation(folder.appendingPathComponent(name))
            if LibraryLayout.samePathIgnoringCase(
                LibraryLayout.canonical(file.url), LibraryLayout.canonical(destination)) {
                plan.locations.append(file.url)
            } else {
                plan.locations.append(destination)
                plan.moves.append((index, PlannedMove(from: file.url, to: destination)))
            }
        }
        return plan
    }

    /// The one place a book's folder is decided: where `pattern` files a book with this
    /// metadata, in the capitalisation of the folders that already exist. Nil when the
    /// book lacks something the pattern needs (under the standard pattern, a usable
    /// title or first author).
    /// - Parameters:
    ///   - hasAudio: Whether the book has any audio file once the operation asking is
    ///     done: what `{Kind}` goes by.
    ///   - names: For a caller that asks about many books while nothing on disk
    ///     changes: what the folders hold is then looked up once.
    func bookFolder(
        for metadata: BookMetadata, hasAudio: Bool, pattern: FolderPattern, names: FolderNames? = nil
    ) -> URL? {
        let values = FolderPatternValues(metadata: metadata, hasAudio: hasAudio)
        guard let relative = PathBuilder.bookFolder(values: values, pattern: pattern) else { return nil }
        // The folder is the last component of nothing that is moved, so it is adopted
        // as the parent of a stand-in file name.
        return layout.adoptingExistingCapitalisation(
            layout.root.appendingPathComponent(relative, isDirectory: true).appendingPathComponent("x"),
            remembering: names
        ).deletingLastPathComponent()
    }

    /// As `filingPlan(for:title:folder:)`, in the folder `pattern` files a book with
    /// this metadata and these files in (`files` is the whole book as it will be, so it
    /// says whether the book has audio). Nil when the book cannot be filed.
    func filingPlan(for files: [FilingSource], metadata: BookMetadata, pattern: FolderPattern) -> FilingPlan? {
        let hasAudio = files.contains { $0.role == .audio }
        guard let folder = bookFolder(for: metadata, hasAudio: hasAudio, pattern: pattern) else { return nil }
        return filingPlan(for: files, title: metadata.title, folder: folder)
    }

    // MARK: Whose folder is whose

    /// Which book has which folder, with names compared as the library's volume
    /// compares them.
    struct FolderOwners {
        private var owners: [[String]: Set<Int64>] = [:]
        private var folders: [Int64: [String]] = [:]

        /// The book's folder, as a key; nil when it has none inside the library.
        func folder(of bookId: Int64) -> [String]? { folders[bookId] }

        func isUsed(_ folder: [String], byOtherThan bookId: Int64?) -> Bool {
            owners[folder]?.contains { $0 != bookId } ?? false
        }

        /// Records that the book's folder is now `folder` (nil for none).
        mutating func set(_ folder: [String]?, for bookId: Int64) {
            if let old = folders.removeValue(forKey: bookId) {
                owners[old]?.remove(bookId)
                if owners[old]?.isEmpty == true { owners[old] = nil }
            }
            guard let folder else { return }
            folders[bookId] = folder
            owners[folder, default: []].insert(bookId)
        }
    }

    /// A folder inside the library in the form folders are compared in; nil for one
    /// that is not inside it.
    func folderKey(_ folder: URL) -> [String]? {
        layout.relativeComponents(of: folder).map(volumeNaming.key)
    }

    /// Every book's folder, as the catalogue has them now.
    func folderOwners() throws -> FolderOwners {
        var owners = FolderOwners()
        for (bookId, path) in try store.bookFolders() {
            owners.set(folderKey(store.url(forFolder: path)), for: bookId)
        }
        return owners
    }

    /// FP41: whether filing the book in `folder` would put it in another book's
    /// folder. A book is never filed there: it stays where it is and is flagged. A book
    /// that is in the folder already is not being filed into it.
    /// - Parameter owners: Read from the catalogue when first needed. An operation that
    ///   moves books keeps it up to date (`FolderOwners.set`) as it goes.
    func isAnotherBooksFolder(_ folder: URL, for bookId: Int64?, owners: inout FolderOwners?) -> Bool {
        guard let key = folderKey(folder) else { return false }
        if owners == nil { owners = try? folderOwners() }
        guard let owners else { return false }
        if let bookId, owners.folder(of: bookId) == key { return false }
        return owners.isUsed(key, byOtherThan: bookId)
    }

    /// A path in the form used to compare locations ignoring capitalisation and however
    /// the path is spelled.
    static func comparablePath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
    }
}

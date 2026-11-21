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

    /// As `filingPlan(for:title:folder:)`, in the folder a book with this metadata is
    /// filed in. Nil when the metadata cannot be filed (no usable title or first author).
    func filingPlan(for files: [FilingSource], metadata: BookMetadata) -> FilingPlan? {
        guard let relative = PathBuilder.bookFolder(metadata: metadata) else { return nil }
        // The folder is the last component of nothing that is moved, so it is adopted
        // as the parent of a stand-in file name.
        let folder = layout.adoptingExistingCapitalisation(
            layout.root.appendingPathComponent(relative, isDirectory: true).appendingPathComponent("x")
        ).deletingLastPathComponent()
        return filingPlan(for: files, title: metadata.title, folder: folder)
    }

    /// A path in the form used to compare locations ignoring capitalisation and however
    /// the path is spelled.
    static func comparablePath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
    }
}

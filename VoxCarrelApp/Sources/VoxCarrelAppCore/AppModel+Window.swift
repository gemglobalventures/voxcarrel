import Foundation
import VoxCarrelCore

extension BrowseField {
    /// The browse fields in the order the sidebar shows them.
    public static let sidebarOrder: [BrowseField] = [.authors, .series, .narrators, .genre]

    /// The field's heading in the sidebar.
    public var title: String {
        switch self {
        case .authors: "Authors"
        case .series: "Series"
        case .narrators: "Narrators"
        case .genre: "Genres"
        }
    }
}

/// Which of the Book menu's commands apply to the selection as it is now.
public struct SelectionCommands: Equatable, Sendable {
    /// Exactly one book is selected, and it has an audiobook or an ebook to open.
    public var open = false
    /// Exactly one book is selected, and it has audio.
    public var listen = false
    /// Exactly one book is selected, and it has an ebook.
    public var read = false
    public var reveal = false
    /// Mark as unread, in progress or finished.
    public var mark = false
    public var addToCollection = false
    public var rewriteTags = false
    public var remove = false

    public init() {}
}

extension AppModel {
    // MARK: Names

    /// What the sidebar and the window's title call this item.
    public func title(of item: SidebarItem) -> String {
        switch item {
        case .allBooks: "All Books"
        case .audiobooks: "Audiobooks"
        case .ebooks: "Ebooks"
        case .unread: "Unread"
        case .inProgress: "In Progress"
        case .finished: "Finished"
        case .needsAttention: "Needs Attention"
        case .browse(_, let value): value
        case .collection(let id): sidebar.collections.first { $0.id == id }?.name ?? "Collection"
        }
    }

    /// The selected sidebar item's name.
    public var windowTitle: String {
        title(of: sidebarSelection)
    }

    /// How many books are shown: "128 books".
    public var windowSubtitle: String {
        switch rows.count {
        case 0: "No books"
        case 1: "1 book"
        default: "\(rows.count) books"
        }
    }

    // MARK: Library folder

    /// The folder chosen as the library, whether or not it is there now.
    public var libraryFolder: URL? {
        switch status {
        case .notChosen: nil
        case .unavailable(let folder), .available(let folder): folder
        }
    }

    /// Shows the library folder in the Finder.
    public func revealLibraryFolder() {
        guard let libraryFolder else { return }
        opener.reveal([libraryFolder])
    }

    // MARK: Which commands apply

    /// Whether an import can be begun: a library is open, nothing is running and no
    /// import is being reviewed.
    public var canImport: Bool {
        isLibraryOpen && busyLabel == nil && review == nil
    }

    public var canUndo: Bool {
        isLibraryOpen && busyLabel == nil && undoLabel != nil
    }

    /// The Undo menu item's title: "Undo Import 12 books".
    public var undoMenuTitle: String {
        undoLabel.map { "Undo \($0)" } ?? "Undo"
    }

    /// For the Book menu.
    public var selectionCommands: SelectionCommands {
        commands(for: selection)
    }

    /// Which commands apply to these books: for a context menu, which may be for books
    /// other than the selection.
    public func commands(for ids: Set<Int64>) -> SelectionCommands {
        var commands = SelectionCommands()
        guard isLibraryOpen, !ids.isEmpty else { return commands }
        let shown = rows.first { ids.contains($0.id) }
        if ids.count == 1, let book = shown {
            commands.open = book.hasAudio || book.hasEbook
            commands.listen = book.hasAudio
            commands.read = book.hasEbook
        }
        // Showing a book in the Finder changes nothing, so it does not wait for an operation.
        commands.reveal = true
        guard busyLabel == nil else { return commands }
        commands.mark = true
        commands.addToCollection = !sidebar.collections.isEmpty
        commands.rewriteTags = true
        // Only books that are shown can be removed.
        commands.remove = shown != nil
        return commands
    }

    // MARK: Acting on the selection

    /// Opens the one selected book: its audiobook if it has one, otherwise its ebook.
    public func openSelection() {
        openOne(of: selection)
    }

    /// Opens the book when there is exactly one; several books are not opened at once.
    /// For a double-click or Return in the list, and for menus.
    public func openOne(of ids: Set<Int64>) {
        guard ids.count == 1, let id = ids.first else { return }
        open(id)
    }

    public func listenOne(of ids: Set<Int64>) {
        guard ids.count == 1, let id = ids.first else { return }
        listen(id)
    }

    public func readOne(of ids: Set<Int64>) {
        guard ids.count == 1, let id = ids.first else { return }
        read(id)
    }

    // MARK: The grid and the list

    /// Why there are no books to show; nil when there are some, or it is not known yet.
    public var emptyState: EmptyState? {
        guard isLibraryOpen, rowsLoaded, rows.isEmpty, let all = sidebar.counts[.allBooks] else { return nil }
        return all == 0 ? .emptyLibrary : .noMatches
    }

    /// What the middle of the window shows: nothing until the open library's books have
    /// been read, then the books, or why there are none.
    public var booksContent: BooksContent {
        guard isLibraryOpen, rowsLoaded else { return .notLoaded }
        return emptyState.map(BooksContent.empty) ?? .books
    }

    /// `sort` as the list's column headers show it. Setting it, as a click on a header
    /// does, sets `sort`; an order that is not one of the sorts changes nothing.
    public var tableSortOrder: [KeyPathComparator<BookRow>] {
        get { sort.tableSortOrder }
        set {
            guard let sort = BookSort(tableSortOrder: newValue) else { return }
            self.sort = sort
        }
    }

    public func listenSelection() {
        listenOne(of: selection)
    }

    public func readSelection() {
        readOne(of: selection)
    }
}

/// What the middle of the library window shows.
public enum BooksContent: Equatable, Sendable {
    /// The books have not been read yet: nothing, not even an empty grid or list.
    case notLoaded
    case empty(EmptyState)
    /// The grid or the list, by `AppModel.viewMode`.
    case books
}

/// Why the grid or the list has nothing in it.
public enum EmptyState: Equatable, Sendable {
    /// The library has no books at all.
    case emptyLibrary
    /// The library has books, and none is in the chosen part of the sidebar or matches the search.
    case noMatches

    public var title: String {
        switch self {
        case .emptyLibrary: "No books yet"
        case .noMatches: "No books match"
        }
    }

    public var message: String {
        switch self {
        case .emptyLibrary: "Drag files or folders here, or choose Import."
        case .noMatches: "Try another search, or choose something else in the sidebar."
        }
    }
}

extension PendingPrompt {
    /// The question, as the dialog's heading.
    public var title: String {
        switch self {
        case .unsavedChanges:
            return "Do you want to save your changes?"
        case .removeBooks(_, let titles):
            guard titles.count == 1 else { return "Remove \(titles.count) books from the library?" }
            guard let title = titles[0].trimmedOrNil else { return "Remove this book from the library?" }
            return "Remove \"\(title)\" from the library?"
        case .chooseFolderWithFiles(let folder, _, _):
            return "Use \"\(folder.lastPathComponent)\" as your library?"
        }
    }

    /// What the answer will mean, under the heading.
    public var message: String {
        switch self {
        case .unsavedChanges:
            return "Your changes will be lost if you do not save them."
        case .removeBooks:
            return "You can move the files to the Trash as well, or leave them where they are."
        case .chooseFolderWithFiles(_, let count, let bookFiles):
            let items = count == 1 ? "1 item" : "\(count) items"
            guard bookFiles > 0 else {
                return "This folder already holds \(items), none of them audiobooks or ebooks. They will be left "
                    + "as they are. An empty folder just for your library is the tidier choice."
            }
            let files: String
            if bookFiles > LibraryLocation.bookFileLimit {
                files = "more than \(LibraryLocation.bookFileLimit.formatted(.number.locale(Locale(identifier: "en_US")))) audiobook and ebook files"
            } else {
                files = bookFiles == 1 ? "1 audiobook or ebook file" : "\(bookFiles) audiobook and ebook files"
            }
            return "This folder already holds \(items), including \(files). VoxCarrel will list those files when "
                + "the library opens and, only if you then choose Import, move and rename them into its own "
                + "layout. To keep them as they are, choose an empty folder instead and import with Copy."
        }
    }
}

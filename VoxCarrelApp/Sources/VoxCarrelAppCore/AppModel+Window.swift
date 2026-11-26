import Foundation
import VoxCarrelCore

extension BrowseField {
    /// The browse fields in the order the sidebar shows them.
    /// G34: genres are not among them: they are a tree of their own (`AppModel.genreTree`).
    public static let sidebarOrder: [BrowseField] = [.authors, .series, .narrators]

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
    /// Exactly one book is selected, and it has audio: a file, or the audiobook on Audible.
    public var listen = false
    /// Exactly one book is selected, and it has an ebook.
    public var read = false
    public var reveal = false
    /// Mark as unread, in progress or finished.
    public var mark = false
    public var addToCollection = false
    /// A collection is what the sidebar shows, so the books can be taken out of it.
    public var removeFromCollection = false
    public var rewriteTags = false
    /// One of the books has a file whose wrong length header can be repaired.
    public var repairLengthHeaders = false
    /// One of the books has an ebook an EPUB can be made of, and no EPUB yet.
    public var convertToEPUB = false
    /// One of the books has no cover, and is shown with one made for it.
    public var keepMadeCover = false
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
        case .onAudible: "On Audible"
        case .onKindle: "On Kindle"
        case .highlights: "Highlights"
        case .unread: "Unread"
        case .inProgress: "In Progress"
        case .finished: "Finished"
        case .needsAttention: "Needs Attention"
        case .browse(_, let value): value
        case .genreGroup(let group): group.title
        case .noGenre: "No genre"
        case .collection(let id): sidebar.collections.first { $0.id == id }?.name ?? "Collection"
        case .inbox: "Inbox"
        case .hidden: "Hidden"
        case .upNext: "Up Next"
        case .shelf(let id): sidebar.shelves.first { $0.id == id }?.name ?? "Shelf"
        case .tidy(let check): check.title
        }
    }

    /// The selected sidebar item's name.
    public var windowTitle: String {
        title(of: sidebarSelection)
    }

    /// How many books are shown: "128 books".
    public var windowSubtitle: String {
        if sidebarSelection == .inbox { return inboxSubtitle }
        // SV6: the books of the library; not the rows for books it does not have.
        let count = rows.filter { !$0.isMissing }.count
        switch count {
        case 0: return "No books"
        case 1: return "1 book"
        default: return "\(count) books"
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
    ///
    /// FL8, FL12: nor while a change of folder layout is previewed, or one that was
    /// interrupted has not been put right.
    public var canImport: Bool {
        isLibraryOpen && busyLabel == nil && review == nil && filesCanChange
    }

    public var canUndo: Bool {
        isLibraryOpen && busyLabel == nil && undoLabel != nil && filesCanChange
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
    ///
    /// SV7: none applies when any of them is a row that stands for a book the library
    /// does not have.
    public func commands(for ids: Set<Int64>) -> SelectionCommands {
        var commands = SelectionCommands()
        guard isLibraryOpen, !ids.isEmpty, !holdsMissing(ids) else { return commands }
        let shown = rows.first { ids.contains($0.id) }
        if ids.count == 1, let book = shown {
            // A book that is only on Kindle, with no ID to open it by, has nothing to read.
            commands.open = book.hasAudio || book.canRead
            commands.listen = book.hasAudio
            commands.read = book.canRead
        }
        // R5: books that have no files have nothing to show in the Finder, and no tags
        // to write. A book that is not shown is taken to have files.
        let chosen = rows.filter { ids.contains($0.id) }
        let someHaveFiles = chosen.count < ids.count || chosen.contains(where: \.hasFiles)
        // Showing a book in the Finder changes nothing, so it does not wait for an operation.
        commands.reveal = someHaveFiles
        // FL8: nor does anything else while a change of folder layout is previewed.
        // PH28: nor while Send to Phone is open. MG7: nor Merge Books.
        guard busyLabel == nil, layoutPreview == nil, sendSession == nil, mergeSession == nil
        else { return commands }
        commands.mark = true
        commands.addToCollection = !sidebar.collections.isEmpty
        commands.removeFromCollection = shownCollection != nil
        // FL12: what the library refuses while an interrupted change of layout is unresolved.
        guard !layoutChangeIsUnresolved else { return commands }
        commands.rewriteTags = someHaveFiles
        commands.repairLengthHeaders = chosen.contains { $0.repairableLengthFiles > 0 }
        // Decided from the rows as they were last read: the library is not asked.
        commands.convertToEPUB = chosen.contains(where: \.canConvertToEPUB)
        commands.keepMadeCover = chosen.contains(where: \.canKeepMadeCover)
        // Only books that are shown can be removed, and removing asks first: not while
        // another question is waiting (A24).
        commands.remove = shown != nil && prompt == nil
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
        // WF24: the Inbox has its own words for when nothing is waiting.
        guard sidebarSelection != .inbox else { return nil }
        // R10
        if sidebarSelection == .onAudible, sidebar.counts[.onAudible] == 0 { return .noAudibleBooks }
        if sidebarSelection == .hidden, sidebar.hiddenCount == 0 { return .noHiddenBooks }
        if all == 0 { return .emptyLibrary }
        // Nothing is being read, begun or waiting: not a search that found nothing.
        if sidebarSelection == .upNext, searchText.trimmed.isEmpty { return .nothingUpNext }
        return .noMatches
    }

    /// What the middle of the window shows: nothing until the open library's books have
    /// been read, then the books, or why there are none.
    public var booksContent: BooksContent {
        guard isLibraryOpen, rowsLoaded else { return .notLoaded }
        // WF24
        if sidebarSelection == .inbox { return .inbox }
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

    /// The same for the list as a table of items (`items`): a click on a header sets
    /// `sort` exactly as it does in a table of books.
    public var itemTableSortOrder: [KeyPathComparator<LibraryItem>] {
        get { sort.itemSortOrder }
        set {
            guard let sort = BookSort(itemSortOrder: newValue) else { return }
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
    /// The Inbox is what the sidebar shows: the arrivals (`AppModel.inboxRows`), no books.
    case inbox
}

/// Why the grid or the list has nothing in it.
public enum EmptyState: Equatable, Sendable {
    /// The library has no books at all.
    case emptyLibrary
    /// The library has books, and none is in the chosen part of the sidebar or matches the search.
    case noMatches
    /// On Audible is what the sidebar shows, and no book is marked as on Audible.
    case noAudibleBooks
    /// Up Next is what the sidebar shows, and it has no lines.
    case nothingUpNext
    /// The Hidden list is what the sidebar shows, and no book is hidden.
    case noHiddenBooks

    public var title: String {
        switch self {
        case .emptyLibrary: "No books yet"
        case .noMatches: "No books match"
        case .noAudibleBooks: "No Audible books yet"
        case .nothingUpNext: "Nothing up next"
        case .noHiddenBooks: "No hidden books"
        }
    }

    public var message: String {
        switch self {
        case .emptyLibrary: "Drag files or folders here, or choose Import."
        case .noMatches: "Try another search, or choose something else in the sidebar."
        case .noAudibleBooks: "Choose Book ▸ Add Audible Book…"
        case .nothingUpNext:
            "Books you are reading, the next book of a series you have begun, and books you add here will be listed."
        case .noHiddenBooks: "To hide books, select them and choose Book ▸ Hide."
        }
    }
}

extension PendingPrompt {
    /// R6: what the button that removes the books and sends their files to the Trash
    /// says; nil when that is not a choice: none of the books has a file, or this is
    /// not the question about removing books.
    public var removeTrashTitle: String? {
        guard case .removeBooks(let ids, _, _, let withoutFiles) = self, withoutFiles < ids.count else { return nil }
        return "Move Files to Trash"
    }

    /// R6: what the button that only takes the books out of the library says: the one
    /// button there is when none of them has a file. Nil for any other question.
    public var removeOnlyTitle: String? {
        guard case .removeBooks(let ids, _, _, let withoutFiles) = self else { return nil }
        return withoutFiles < ids.count ? "Remove from Library Only" : "Remove from Library"
    }

    /// FL13: what the button that gives up on an interrupted change of folder layout
    /// says; nil for any other question.
    public var stopLayoutRecoveryTitle: String? {
        self == .stopLayoutRecovery || self == .stopMergeRecovery ? "Stop Trying" : nil
    }

    /// What the button that deletes a smart shelf says; nil for any other question.
    public var deleteShelfTitle: String? {
        if case .deleteShelf = self { "Delete" } else { nil }
    }

    /// What the button that unlinks the Audible account says; nil for any other question.
    public var unlinkAudibleTitle: String? {
        if case .unlinkAudible = self { "Unlink" } else { nil }
    }

    /// The question, as the dialog's heading.
    public var title: String {
        switch self {
        case .unsavedChanges:
            return "Do you want to save your changes?"
        case .removeBooks(_, let titles, _, _):
            guard titles.count == 1 else { return "Remove \(titles.count) books from the library?" }
            guard let title = titles[0].trimmedOrNil else { return "Remove this book from the library?" }
            return "Remove “\(title)” from the library?"
        case .chooseFolderWithFiles(let folder, _, _):
            return "Use \"\(folder.lastPathComponent)\" as your library?"
        case .stopLayoutRecovery:
            return "Stop trying to put the folders back?"
        case .stopMergeRecovery:
            return "Stop trying to put the files back?"
        case .deleteShelf(_, let name):
            return "Delete the shelf \"\(name)\"?"
        case .unlinkAudible:
            return "Unlink your Audible account?"
        }
    }

    /// What the answer will mean, under the heading.
    public var message: String {
        switch self {
        case .unsavedChanges:
            return "Your changes will be lost if you do not save them."
        case .removeBooks(let ids, _, let outside, let withoutFiles):
            // R6: nothing to choose when none of the books has a file.
            guard withoutFiles < ids.count else {
                return ids.count == 1
                    ? "This book has no files on this Mac, so nothing goes to the Trash."
                    : "These books have no files on this Mac, so nothing goes to the Trash."
            }
            var choice = "You can move the files to the Trash as well, or leave them where they are."
            if withoutFiles > 0 {
                choice += " \(withoutFiles) of the \(ids.count) books "
                    + (withoutFiles == 1 ? "has no files on this Mac and is" : "have no files on this Mac and are")
                    + " only removed from the library."
            }
            guard !outside.isEmpty else { return choice }
            // A long list is cut short: the question has to fit on the screen.
            var lines = Array(outside.prefix(5))
            if outside.count > lines.count { lines.append("and \(outside.count - lines.count) more") }
            return choice + "\n\nThese files are not in the library folder: moving them to the Trash takes "
                + "them from where they are now.\n" + lines.joined(separator: "\n")
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
        case .stopLayoutRecovery:
            return "VoxCarrel will stop trying to put the folders back. Books whose folders moved will show as "
                + "missing until you move the folders back or locate the files yourself. Nothing is deleted."
        case .stopMergeRecovery:
            return "VoxCarrel will stop trying to put the files of the interrupted merge back. Books whose files "
                + "moved will show as missing until you move the files back or locate them yourself. Nothing "
                + "is deleted."
        case .deleteShelf:
            return "The books on it stay in the library."
        case .unlinkAudible(let deviceName):
            let device = deviceName?.trimmedOrNil.map { "the device \"\($0)\"" } ?? "the device"
            return "VoxCarrel asks Amazon to remove \(device) from your account, and forgets its keys. The "
                + "books already brought in stay in your library."
        }
    }
}

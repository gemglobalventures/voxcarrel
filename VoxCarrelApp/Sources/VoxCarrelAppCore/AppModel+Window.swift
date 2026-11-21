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

    public var selectionCommands: SelectionCommands {
        var commands = SelectionCommands()
        guard isLibraryOpen, !selection.isEmpty else { return commands }
        let selected = rows.filter { selection.contains($0.id) }
        if selection.count == 1, let book = selected.first {
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
        commands.remove = !selected.isEmpty
        return commands
    }

    // MARK: Acting on the selection

    /// The one selected book; nil when none or several are selected.
    private var onlySelected: Int64? {
        selection.count == 1 ? selection.first : nil
    }

    /// Opens the one selected book: its audiobook if it has one, otherwise its ebook.
    public func openSelection() {
        guard let id = onlySelected else { return }
        open(id)
    }

    public func listenSelection() {
        guard let id = onlySelected else { return }
        listen(id)
    }

    public func readSelection() {
        guard let id = onlySelected else { return }
        read(id)
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
        case .chooseFolderWithFiles(let folder, _):
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
        case .chooseFolderWithFiles(_, let count):
            let items = count == 1 ? "1 item" : "\(count) items"
            return
                "This folder already holds \(items). VoxCarrel will offer to file the audiobooks and ebooks it finds there."
        }
    }
}

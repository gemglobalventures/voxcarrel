import SwiftUI
import VoxCarrelAppCore
import VoxCarrelCore

/// V6: the commands that act on books. The Book menu's items, where they act on the
/// selection, and a context menu's (`BookContextMenu`), where they act on the books the
/// menu was opened on.
struct BookCommandItems: View {
    let model: AppModel
    /// The books to act on; nil for the selection.
    var ids: Set<Int64>?
    /// Keyboard shortcuts belong to the Book menu; a context menu repeats none of them.
    var showsShortcuts = true

    var body: some View {
        let books = ids ?? model.selection
        let applies = model.commands(for: books)

        Button("Open") { model.openOne(of: books) }
            .keyboardShortcut(shortcut("o", .command))
            .disabled(!applies.open)
            .accessibilityIdentifier("\(prefix).open")
        Button("Listen") { model.listenOne(of: books) }
            .disabled(!applies.listen)
            .accessibilityIdentifier("\(prefix).listen")
        Button("Read") { model.readOne(of: books) }
            .disabled(!applies.read)
            .accessibilityIdentifier("\(prefix).read")
        Button("Reveal in Finder") { model.reveal(books) }
            .keyboardShortcut(shortcut("r", [.command, .shift]))
            .disabled(!applies.reveal)
            .accessibilityIdentifier("\(prefix).reveal")

        Divider()

        Menu("Mark as") {
            ForEach(ReadStatus.allCases, id: \.self) { status in
                Button(status.title) {
                    Task { await model.setReadStatus(status, for: books) }
                }
                .accessibilityIdentifier("\(prefix).markAs.\(status.rawValue)")
            }
        }
        .disabled(!applies.mark)
        .accessibilityIdentifier("\(prefix).markAs")

        Menu("Add to Collection") {
            ForEach(model.sidebar.collections) { collection in
                if let id = collection.id {
                    Button(collection.name) {
                        Task { await model.add(books, toCollection: id) }
                    }
                    .accessibilityIdentifier("\(prefix).addToCollection.\(collection.name)")
                }
            }
        }
        .disabled(!applies.addToCollection)
        .accessibilityIdentifier("\(prefix).addToCollection")

        if let title = model.removeFromCollectionTitle {
            Button(title) {
                Task { await model.removeFromShownCollection(books) }
            }
            .disabled(!applies.removeFromCollection)
            .accessibilityIdentifier("\(prefix).removeFromCollection")
        }

        Button("Rewrite Tags") {
            Task { await model.rewriteTags(for: books) }
        }
        .disabled(!applies.rewriteTags)
        .accessibilityIdentifier("\(prefix).rewriteTags")

        Divider()

        // No key of its own here: ⌘⌫ in a menu would take it from a text field that is
        // being typed in. The grid and the list answer Delete themselves.
        Button("Remove…") { model.requestRemove(books) }
            .disabled(!applies.remove)
            .accessibilityIdentifier("\(prefix).remove")
    }

    /// The start of each item's accessibility identifier.
    private var prefix: String {
        showsShortcuts ? "menu.book" : "contextMenu.book"
    }

    private func shortcut(_ key: KeyEquivalent, _ modifiers: EventModifiers) -> KeyboardShortcut? {
        showsShortcuts ? KeyboardShortcut(key, modifiers: modifiers) : nil
    }
}

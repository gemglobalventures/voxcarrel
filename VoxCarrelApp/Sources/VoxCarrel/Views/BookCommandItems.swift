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

        if ids == nil {
            // Plan 6, V4: adds a book, so it is the Book menu's alone.
            Button("Add Audible Book…") { model.beginAddAudibleBook() }
                .keyboardShortcut(shortcut("a", [.command, .shift]))
                .disabled(!model.canAddAudibleBook)
                .help(model.addAudibleBookHelp)
                .accessibilityIdentifier("\(prefix).addAudible")

            Divider()
        }

        Button("Open") { model.openOne(of: books) }
            .keyboardShortcut(shortcut("o", .command))
            .disabled(!applies.open)
            .accessibilityIdentifier("\(prefix).open")
        Button(model.listenTitle(for: books)) { model.listenOne(of: books) }
            .disabled(!applies.listen)
            .accessibilityIdentifier("\(prefix).listen")
        Button("Read") { model.readOne(of: books) }
            .disabled(!applies.read)
            .accessibilityIdentifier("\(prefix).read")
        Button("Reveal in Finder") { model.reveal(books) }
            .keyboardShortcut(shortcut("r", [.command, .shift]))
            .disabled(!applies.reveal)
            .accessibilityIdentifier("\(prefix).reveal")
        if ids == nil {
            // V1: for the book in the inspector, so the Book menu's alone.
            Button("Look Up…") { model.beginLookup() }
                .keyboardShortcut(shortcut("l", .command))
                .disabled(!model.canLookUp)
                .help(model.lookUpHelp)
                .accessibilityIdentifier("\(prefix).lookup")
            // Plan 9: for the series the sidebar shows, so the Book menu's alone.
            Button("Check Series") {
                Task { await model.checkSeries() }
            }
            .disabled(model.seriesHeader?.canCheck != true)
            .accessibilityIdentifier("\(prefix).checkSeries")
        }

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

        // Plan 6, V4: "Mark as on Audible", or "Unmark as on Audible" when they all are.
        Button(model.markOnAudibleTitle(for: books)) {
            Task { await model.toggleOnAudible(for: books) }
        }
        .disabled(!model.canMarkOnAudible(for: books))
        .accessibilityIdentifier("\(prefix).markOnAudible")

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
        Button("Repair Length Headers") {
            Task { await model.repairLengthHeaders(for: books) }
        }
        .disabled(!applies.repairLengthHeaders)
        .accessibilityIdentifier("\(prefix).repairLength")
        // Plan 7, K8: one lookup for each audiobook; only its edition is changed.
        Button(model.checkEditionTitle) {
            Task { await model.checkEdition(for: books) }
        }
        .disabled(!model.canCheckEdition(for: books))
        .help(model.checkEditionHelp)
        .accessibilityIdentifier("\(prefix).checkEdition")

        Divider()

        // Send to phone plan: for one audiobook; the sheet says what stands in the way.
        Button("Send to Phone…") {
            Task { await model.beginSendToPhone(for: books) }
        }
        .disabled(!model.canSendToPhone(books))
        .accessibilityIdentifier("\(prefix).sendToPhone")

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

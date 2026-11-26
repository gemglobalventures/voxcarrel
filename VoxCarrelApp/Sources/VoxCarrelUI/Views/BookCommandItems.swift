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
        Button(model.readTitle(for: books)) { model.readOne(of: books) }
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

        // Put on Up Next by hand, and taken off: only a book put there by hand comes off.
        Button(model.addToUpNextTitle) {
            Task { await model.addToUpNext(books) }
        }
        .disabled(!model.canAddToUpNext(books))
        .accessibilityIdentifier("\(prefix).addToUpNext")
        Button(model.removeFromUpNextTitle) {
            Task { await model.removeFromUpNext(books) }
        }
        .disabled(!model.canRemoveFromUpNext(books))
        .accessibilityIdentifier("\(prefix).removeFromUpNext")

        // "Hide", or "Unhide" in the Hidden list.
        Button(model.hideTitle(for: books)) {
            Task { await model.toggleHidden(for: books) }
        }
        .disabled(!model.canHide(books))
        .accessibilityIdentifier("\(prefix).hide")

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
        // An EPUB made with calibre's converter, beside the ebook it is made of.
        Button(ConversionText.commandTitle) {
            Task { await model.convertToEPUB(for: books) }
        }
        .disabled(!applies.convertToEPUB)
        .accessibilityIdentifier("\(prefix).convertToEPUB")
        // The cover made for a book that has none, saved as the book's own.
        Button(MadeCover.commandTitle) {
            Task { await model.keepMadeCovers(for: books) }
        }
        .disabled(!applies.keepMadeCover)
        .accessibilityIdentifier("\(prefix).keepMadeCover")
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
        // For one book with an ebook on this Mac: handed to Amazon's own app, or put in
        // a message to the Kindle's address. An alert says what stands in the way.
        Button(KindleText.commandTitle) {
            Task { await model.sendToKindle(for: books) }
        }
        .disabled(!model.canSendToKindle(books))
        .accessibilityIdentifier("\(prefix).sendToKindle")

        // Merge books plan: entries that are one book become one. Always in the Book
        // menu; in a context menu when it is for several books.
        if ids == nil || model.offersMergeBooks(for: books) {
            Button("Merge Books…") {
                Task { await model.beginMergeBooks(for: books) }
            }
            .disabled(!model.canMergeBooks(books))
            .accessibilityIdentifier("\(prefix).mergeBooks")
        }

        // Editions: the same book in another language or another reading stays an
        // entry of its own, and is linked to the others.
        if ids == nil || model.offersMergeBooks(for: books) {
            Button(AppModel.linkEditionsTitle) {
                Task { await model.linkEditions(for: books) }
            }
            .disabled(!model.canLinkEditions(books))
            .accessibilityIdentifier("\(prefix).linkEditions")
        }
        if model.canUnlinkEdition(books) {
            Button(AppModel.unlinkEditionTitle) {
                Task { await model.unlinkEdition(for: books) }
            }
            .accessibilityIdentifier("\(prefix).unlinkEdition")
        }

        Divider()

        // No key of its own here: ⌘⌫ in a menu would take it from a text field that is
        // being typed in. The grid and the list answer Delete themselves.
        Button("Remove…") { model.requestRemove(books) }
            .disabled(!applies.remove)
            .accessibilityIdentifier("\(prefix).remove")

        // EX2: the commands extensions have added, when there are any. Which they are,
        // what they are called and whether they apply is the model's to say.
        let added = model.extensionCommands(for: books)
        if !added.isEmpty {
            Divider()

            ForEach(added) { command in
                Button(command.title) { model.runExtensionCommand(command.id, for: books) }
                    .disabled(!command.isEnabled)
                    .accessibilityIdentifier("\(prefix).\(command.id)")
            }
        }
    }

    /// The start of each item's accessibility identifier.
    private var prefix: String {
        showsShortcuts ? "menu.book" : "contextMenu.book"
    }

    private func shortcut(_ key: KeyEquivalent, _ modifiers: EventModifiers) -> KeyboardShortcut? {
        showsShortcuts ? KeyboardShortcut(key, modifiers: modifiers) : nil
    }
}

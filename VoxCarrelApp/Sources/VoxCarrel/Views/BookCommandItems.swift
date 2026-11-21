import SwiftUI
import VoxCarrelAppCore
import VoxCarrelCore

/// V6: the commands that act on the selected books. The Book menu's items.
struct BookCommandItems: View {
    let model: AppModel

    var body: some View {
        let applies = model.selectionCommands

        Button("Open") { model.openSelection() }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(!applies.open)
            .accessibilityIdentifier("menu.book.open")
        Button("Listen") { model.listenSelection() }
            .disabled(!applies.listen)
            .accessibilityIdentifier("menu.book.listen")
        Button("Read") { model.readSelection() }
            .disabled(!applies.read)
            .accessibilityIdentifier("menu.book.read")
        Button("Reveal in Finder") { model.reveal(model.selection) }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(!applies.reveal)
            .accessibilityIdentifier("menu.book.reveal")

        Divider()

        Menu("Mark as") {
            ForEach(ReadStatus.allCases, id: \.self) { status in
                Button(status.title) {
                    Task { await model.setReadStatus(status, for: model.selection) }
                }
                .accessibilityIdentifier("menu.book.markAs.\(status.rawValue)")
            }
        }
        .disabled(!applies.mark)
        .accessibilityIdentifier("menu.book.markAs")

        Menu("Add to Collection") {
            ForEach(model.sidebar.collections) { collection in
                if let id = collection.id {
                    Button(collection.name) {
                        Task { await model.add(model.selection, toCollection: id) }
                    }
                    .accessibilityIdentifier("menu.book.addToCollection.\(collection.name)")
                }
            }
        }
        .disabled(!applies.addToCollection)
        .accessibilityIdentifier("menu.book.addToCollection")

        Button("Rewrite Tags") {
            Task { await model.rewriteTags() }
        }
        .disabled(!applies.rewriteTags)
        .accessibilityIdentifier("menu.book.rewriteTags")

        Divider()

        Button("Remove…") { model.requestRemove(model.selection) }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(!applies.remove)
            .accessibilityIdentifier("menu.book.remove")
    }
}

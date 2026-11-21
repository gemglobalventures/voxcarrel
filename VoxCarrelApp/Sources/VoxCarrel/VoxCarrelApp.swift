import SwiftUI
import VoxCarrelAppCore

@main
struct VoxCarrelApp: App {
    @State private var model = AppModel(location: LibraryLocation(), opener: SystemFileOpener())

    var body: some Scene {
        // One window on the one model: a second would show the same selection and edits.
        Window("VoxCarrel", id: "main") {
            RootView()
                .environment(model)
                // Runs each time the window opens; the library is opened only the first time.
                .task { await model.startIfNeeded() }
        }
        .defaultSize(width: 1100, height: 700)
        .commands { AppCommands(model: model) }

        Settings {
            SettingsView().environment(model)
        }
    }
}

/// The menus. Each group's items are a view of their own, so that they follow the model.
struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        // The standard Undo and Redo stay: they belong to whatever text field is being typed in.
        CommandGroup(after: .undoRedo) { UndoCommand(model: model) }
        CommandGroup(replacing: .newItem) { ImportCommand(model: model) }
        CommandGroup(before: .toolbar) { ViewModeCommands(model: model) }
        SidebarCommands()
        InspectorCommands()
        CommandMenu("Book") { BookCommandItems(model: model) }
    }
}

/// V4: undoing the last change to the library, apart from the undo of typing.
private struct UndoCommand: View {
    let model: AppModel

    var body: some View {
        Button(model.undoMenuTitle) {
            Task { await model.undo() }
        }
        .keyboardShortcut("z", modifiers: [.command, .option])
        .disabled(!model.canUndo)
        .accessibilityIdentifier("menu.edit.undo")
    }
}

private struct ImportCommand: View {
    let model: AppModel

    var body: some View {
        Button("Import…") {
            Panels.importFiles(into: model)
        }
        .keyboardShortcut("i", modifiers: .command)
        .disabled(!model.canImport)
        .accessibilityIdentifier("menu.file.import")
    }
}

/// View ▸ as Grid, as List: the one in use is ticked.
private struct ViewModeCommands: View {
    let model: AppModel

    var body: some View {
        Toggle("as Grid", isOn: isMode(.grid))
            .keyboardShortcut("1", modifiers: .command)
            .accessibilityIdentifier("menu.view.asGrid")
        Toggle("as List", isOn: isMode(.list))
            .keyboardShortcut("2", modifiers: .command)
            .accessibilityIdentifier("menu.view.asList")
        Divider()
    }

    /// Choosing an item switches to its mode; choosing the one in use changes nothing.
    private func isMode(_ mode: ViewMode) -> Binding<Bool> {
        Binding(get: { model.viewMode == mode }, set: { _ in model.viewMode = mode })
    }
}

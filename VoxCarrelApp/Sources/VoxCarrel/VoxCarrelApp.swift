import SwiftUI
import VoxCarrelAppCore

@main
struct VoxCarrelApp: App {
    @State private var model = AppModel(location: LibraryLocation(), opener: SystemFileOpener())

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { await model.start() }
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
        CommandGroup(replacing: .undoRedo) { UndoCommand(model: model) }
        CommandGroup(replacing: .newItem) { ImportCommand(model: model) }
        CommandGroup(before: .toolbar) { ViewModeCommands(model: model) }
        SidebarCommands()
        InspectorCommands()
        CommandMenu("Book") { BookCommandItems(model: model) }
    }
}

/// V4
private struct UndoCommand: View {
    let model: AppModel

    var body: some View {
        Button(model.undoMenuTitle) {
            Task { await model.undo() }
        }
        .keyboardShortcut("z", modifiers: .command)
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

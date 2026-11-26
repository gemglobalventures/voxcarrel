import AppKit
import SwiftUI
import VoxCarrelAppCore

/// How the app is started: by this package's own program with nothing added, and by a
/// package that adds features with its extensions.
public enum VoxCarrelMain {
    /// What the app was started with. The system makes the `App` itself, so this is
    /// where its `init` finds them.
    @MainActor static var extensions = AppExtensions()

    /// Starts the app, and returns only by ending the process.
    ///
    /// - Parameter extensions: What has been added to the app; nothing for the app by itself.
    @MainActor
    public static func run(extensions: AppExtensions = AppExtensions()) -> Never {
        self.extensions = extensions
        VoxCarrelApp.main()
        exit(0)
    }
}

struct VoxCarrelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel

    init() {
        let model = AppModel(
            location: LibraryLocation(), opener: SystemFileOpener(), extensions: VoxCarrelMain.extensions)
        _model = State(initialValue: model)
        // The delegate is made by the system; this is how it is given the model.
        AppDelegate.model = model
    }

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
        CommandGroup(after: .appInfo) { ExtensionAppCommandItems(model: model) }
        CommandGroup(after: .undoRedo) { UndoCommand(model: model) }
        CommandGroup(replacing: .newItem) { ImportCommand(model: model) }
        CommandGroup(replacing: .saveItem) { SaveCommand(model: model) }
        CommandGroup(before: .toolbar) { ViewModeCommands(model: model) }
        SidebarCommands()
        InspectorCommands()
        CommandMenu("Book") { BookCommandItems(model: model) }
        CommandMenu("Library") {
            GenreCommandItems(model: model, updateTitle: "Update Genre Tags in Files…", prefix: "menu.library")
            Divider()
            AudibleCommandItem(model: model)
            KindleCommandItem(model: model)
            HighlightsCommandItem(model: model)
        }
        CommandGroup(after: .help) {
            Button(DemoLibraryText.commandTitle) { Task { await model.openDemoLibrary() } }
                .disabled(!model.canOpenDemoLibrary)
                .accessibilityIdentifier("menu.help.openDemoLibrary")
            Button("Export Diagnostics…") { Panels.exportDiagnostics(for: model) }
                .disabled(!model.canExportDiagnostics)
                .accessibilityIdentifier("menu.help.exportDiagnostics")
        }
    }
}

/// What extensions add to the app's own menu, under About. Nothing when there are none.
private struct ExtensionAppCommandItems: View {
    let model: AppModel

    var body: some View {
        ForEach(model.extensionAppCommands) { item in
            Button(item.title) {
                model.performExtensionAppCommand(item.id)
            }
            .disabled(!item.isEnabled)
            .accessibilityIdentifier("menu.app.\(item.id)")
        }
    }
}

/// Bringing in the library of the linked Audible account; linking one, while none is, so
/// that the way in can be found. Which it is, and whether it applies, is the model's to say.
private struct AudibleCommandItem: View {
    let model: AppModel

    var body: some View {
        Button(model.audibleMenuTitle) {
            model.audibleMenuCommand()
        }
        .disabled(!model.canUseAudibleMenu)
        .accessibilityIdentifier("menu.library.audibleImport")
    }
}

/// Bringing in the Kindle library of the linked account. It is read with the link made
/// for Audible, so it applies only while an account is linked.
private struct KindleCommandItem: View {
    let model: AppModel

    var body: some View {
        Button(model.kindleMenuTitle) {
            model.beginKindleImport()
        }
        .disabled(!model.canImportKindleLibrary)
        .accessibilityIdentifier("menu.library.kindleImport")
    }
}

/// Bringing in highlights from Readwise and the marks made on Audible. With neither set
/// up its sheet says what is needed, so that the way in can be found.
private struct HighlightsCommandItem: View {
    let model: AppModel

    var body: some View {
        Button("Import Highlights…") {
            model.beginHighlightsImport()
        }
        .disabled(!model.canImportHighlights)
        .accessibilityIdentifier("menu.library.importHighlights")
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

/// File ▸ Save: saves the inspector's draft, whether or not the inspector is showing.
private struct SaveCommand: View {
    let model: AppModel

    var body: some View {
        Button("Save") {
            Task { await model.save() }
        }
        .keyboardShortcut("s", modifiers: .command)
        .disabled(!model.canSave)
        .accessibilityIdentifier("menu.file.save")
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
        Button(AppModel.calibreImportMenuTitle) {
            Panels.importCalibreLibrary(into: model)
        }
        .disabled(!model.canImport)
        .accessibilityIdentifier("menu.file.importCalibre")
        // The selected arrivals, or all of them when none is selected.
        Button("Review Inbox…") {
            Task { await model.reviewInbox() }
        }
        .disabled(!model.canReviewInbox)
        .accessibilityIdentifier("menu.file.reviewInbox")
    }
}

/// View ▸ as Grid, as List: the one in use is ticked. Under them, Group by Series,
/// ticked while it is on.
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
        Toggle("Group by Series", isOn: groupsBySeries)
            .accessibilityIdentifier("menu.view.groupBySeries")
        Divider()
        // "Show Hidden Books…", which asks for Touch ID or the Mac's password first;
        // "Stop Showing Hidden Books" while they are shown.
        Button(model.hiddenBooksMenuTitle) {
            Task { await model.toggleHiddenBooks() }
        }
        .disabled(!model.canToggleHiddenBooks)
        .accessibilityIdentifier("menu.view.hiddenBooks")
        Divider()
    }

    private var groupsBySeries: Binding<Bool> {
        Binding(get: { model.groupsBySeries }, set: { model.groupsBySeries = $0 })
    }

    /// Choosing an item switches to its mode; choosing the one in use changes nothing.
    private func isMode(_ mode: ViewMode) -> Binding<Bool> {
        Binding(get: { model.viewMode == mode }, set: { _ in model.viewMode = mode })
    }
}

/// How the main window is brought in front of the user from outside it: by the Settings
/// window when the model has a question, and when the app is asked to quit.
@MainActor
enum MainWindow {
    /// Opens the window, or brings it forward when it is open. Set by the windows' views.
    static var open: (() -> Void)?

    static func show() {
        NSApp.activate()
        open?()
    }
}

/// Asks the model before the app quits, and hands it the files the app is asked to open.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var model: AppModel?

    /// Files and folders dropped on the Dock icon, or opened with the app from the
    /// Finder: imported like a drop on the window, which is where the review is shown.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let model = Self.model else { return }
        MainWindow.show()
        Task { await model.openFiles(urls) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = Self.model else { return .terminateNow }
        let answer = model.requestQuit { quit in
            NSApp.reply(toApplicationShouldTerminate: quit)
        }
        switch answer {
        case .now:
            return .terminateNow
        case .later:
            // The question is the window's to show.
            MainWindow.show()
            return .terminateLater
        case .cancel:
            MainWindow.show()
            return .terminateCancel
        }
    }

    /// With unsaved changes the app stays open when its window is closed, so that they
    /// are still there when the window is opened again.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !(Self.model?.hasUnsavedChanges ?? false)
    }
}

import AppKit
import VoxCarrelAppCore

/// The open panels, and handing what was chosen in them to the model.
@MainActor
enum Panels {
    /// Asks for a folder (a new one can be made in the panel) and makes it the library.
    static func chooseLibrary(for model: AppModel) {
        let panel = NSOpenPanel()
        panel.identifier = NSUserInterfaceItemIdentifier("panel.chooseLibrary")
        panel.title = "Choose Library Folder"
        panel.message = "Choose the folder to keep your books in, or make a new one."
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        Task { await model.chooseLibrary(folder) }
    }

    /// Asks for files and folders and begins importing them.
    static func importFiles(into model: AppModel) {
        let panel = NSOpenPanel()
        panel.identifier = NSUserInterfaceItemIdentifier("panel.import")
        panel.title = "Import"
        panel.message = "Choose audiobooks, ebooks, or folders of them."
        panel.prompt = "Import"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await model.beginImport(urls) }
    }
}

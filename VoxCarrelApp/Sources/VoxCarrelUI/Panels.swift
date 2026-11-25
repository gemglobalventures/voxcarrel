import AppKit
import UniformTypeIdentifiers
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

    /// Asks for one folder and has the library watch it. A folder that cannot be watched
    /// is refused by the model, which says why.
    static func addWatchFolder(for model: AppModel) {
        let panel = NSOpenPanel()
        panel.identifier = NSUserInterfaceItemIdentifier("panel.addWatchFolder")
        panel.title = "Add Watch Folder"
        panel.message = "Choose a folder to watch for books that arrive."
        panel.prompt = "Watch"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        Task { await model.addWatchFolder(folder) }
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

    /// Asks for a calibre library's folder and begins importing its books. The panel
    /// opens at the folder calibre makes for a library unless told otherwise, when
    /// there is one.
    static func importCalibreLibrary(into model: AppModel) {
        let panel = NSOpenPanel()
        panel.identifier = NSUserInterfaceItemIdentifier("panel.importCalibre")
        panel.title = "Import Calibre Library"
        panel.message = "Choose your calibre library's folder. Its books are copied; the calibre library is left as it is."
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        let usual = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Calibre Library", isDirectory: true)
        if FileManager.default.fileExists(atPath: usual.path) { panel.directoryURL = usual }
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        Task { await model.beginCalibreImport(folder) }
    }

    /// I5: asks for an image and makes it the inspected book's cover, not yet saved.
    static func chooseCover(for model: AppModel) {
        let panel = NSOpenPanel()
        panel.identifier = NSUserInterfaceItemIdentifier("panel.chooseCover")
        panel.title = "Choose Cover Image"
        panel.message = "Choose a JPEG or PNG image to use as the cover."
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.jpeg, .png]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.setCover(from: url) }
    }

    /// I6: asks for the file to use in place of one that is missing; only a file of the
    /// same type can be chosen.
    static func locate(_ file: FileRow, for model: AppModel) {
        let panel = NSOpenPanel()
        panel.identifier = NSUserInterfaceItemIdentifier("panel.locate")
        panel.title = "Locate File"
        panel.message = "Choose the file to use in place of \"\(file.name)\". It will be moved into the library."
        panel.prompt = "Use This File"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: file.url.pathExtension)].compactMap { $0 }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.locate(fileId: file.id, at: url) }
    }
}

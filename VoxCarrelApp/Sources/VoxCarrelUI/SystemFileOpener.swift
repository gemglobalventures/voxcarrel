import AppKit
import VoxCarrelAppCore

/// Hands files to the Finder and to the applications that open them.
struct SystemFileOpener: FileOpener {
    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func reveal(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func openWeb(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}

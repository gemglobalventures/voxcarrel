import Foundation

/// Hands files to the rest of the Mac. The app's own implementation uses the workspace;
/// tests use one that only records what it was asked.
public protocol FileOpener: Sendable {
    /// Opens the file in the application that handles it.
    func open(_ url: URL)
    /// Shows the files or folders in the Finder.
    func reveal(_ urls: [URL])
}

import Foundation
@testable import VoxCarrelCore

/// A file manager whose moves and copies can be made to fail on chosen destinations.
final class FailingFileManager: FileManager, @unchecked Sendable {
    /// Destination paths for which `moveItem` throws without moving.
    var failMovesTo: Set<String> = []
    /// Destination paths for which `copyItem` writes half a file and then throws.
    var partialCopiesTo: Set<String> = []

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        if failMovesTo.contains(dstURL.path) { throw CocoaError(.fileWriteUnknown) }
        try super.moveItem(at: srcURL, to: dstURL)
    }

    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        if partialCopiesTo.contains(dstURL.path) {
            try Data("par".utf8).write(to: dstURL)
            throw CocoaError(.fileWriteOutOfSpace)
        }
        try super.copyItem(at: srcURL, to: dstURL)
    }
}

/// Every path below `root`, relative to it, sorted. The details files the library
/// keeps beside its books are left out: they follow from the catalogue, and have
/// tests of their own (`treeWithDetailsFiles`).
func tree(_ root: URL) -> [String] {
    treeWithDetailsFiles(root).filter { ($0 as NSString).lastPathComponent != DetailsFile.fileName }
}

/// Every path below `root`, relative to it, sorted.
func treeWithDetailsFiles(_ root: URL) -> [String] {
    ((FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String]) ?? []).sorted()
}

func read(_ url: URL) throws -> String {
    try String(contentsOf: url, encoding: .utf8)
}

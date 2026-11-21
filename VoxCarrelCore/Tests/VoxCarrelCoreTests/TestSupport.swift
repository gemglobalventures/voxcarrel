import Foundation

/// Creates a unique empty directory under the system temp folder, or under the folder
/// named by the environment variable `VOXCARREL_TEST_TMP` when it is set (to run the
/// suite on another volume, such as a case-sensitive one).
func makeTempDir() throws -> URL {
    let parent = ProcessInfo.processInfo.environment["VOXCARREL_TEST_TMP"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
    let url = parent
        .appendingPathComponent("voxcarrel-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Creates a small file (and any missing parent folders) and returns its URL.
@discardableResult
func touch(_ url: URL, _ contents: String = "x") throws -> URL {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(contents.utf8).write(to: url)
    return url
}

func exists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
}

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

/// Every path below `root`, relative to it, sorted.
func tree(_ root: URL) -> [String] {
    ((FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String]) ?? []).sorted()
}

func read(_ url: URL) throws -> String {
    try String(contentsOf: url, encoding: .utf8)
}

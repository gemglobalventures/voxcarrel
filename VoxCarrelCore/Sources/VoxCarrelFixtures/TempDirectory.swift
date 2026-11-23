import Foundation

/// The one folder that everything this process makes with `makeTempDir` goes into.
///
/// It is made the first time it is needed, named with the process id so that a run's
/// folder can be told from another's, and removed with all that is in it when the
/// process ends: a run of the tests leaves nothing behind in the temporary folder,
/// whether its tests pass or fail. Folders that tests make beside one of their own
/// (a sibling of a library, say) are inside it too, and go with it.
public enum TemporaryRunFolder {
    /// What the name of every run's folder starts with.
    public static let prefix = "voxcarrel-run-"

    /// The folder; made, and its removal arranged, when first asked for.
    public static let url: URL = {
        let parent = ProcessInfo.processInfo.environment["VOXCARREL_TEST_TMP"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
        let folder = parent.appendingPathComponent(
            "\(prefix)\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        path = folder.path
        atexit {
            TemporaryRunFolder.remove()
        }
        return folder
    }()

    /// The folder's path once it has been made; nil before.
    nonisolated(unsafe) private static var path: String?

    /// Removes the folder, if it was made.
    static func remove() {
        guard let path, URL(fileURLWithPath: path).lastPathComponent.hasPrefix(prefix) else { return }
        try? FileManager.default.removeItem(atPath: path)
    }
}

/// Creates a unique empty directory inside this run's own folder (`TemporaryRunFolder`),
/// which is under the system temp folder, or under the folder named by the environment
/// variable `VOXCARREL_TEST_TMP` when it is set (to run the suite on another volume, such
/// as a case-sensitive one). The directory is removed, with the rest of the run's folder,
/// when the process ends.
public func makeTempDir() throws -> URL {
    let url = TemporaryRunFolder.url
        .appendingPathComponent("voxcarrel-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Creates a small file (and any missing parent folders) and returns its URL.
@discardableResult
public func touch(_ url: URL, _ contents: String = "x") throws -> URL {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(contents.utf8).write(to: url)
    return url
}

public func exists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
}

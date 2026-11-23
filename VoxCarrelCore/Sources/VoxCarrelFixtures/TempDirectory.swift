import Foundation

/// The one folder that everything this process makes with `makeTempDir` goes into.
///
/// It is made the first time it is needed, named with the process id so that a run's
/// folder can be told from another's, and removed with all that is in it when the
/// process ends: a run of the tests leaves nothing behind in the temporary folder,
/// whether its tests pass or fail. A run that is killed, or crashes, cannot remove its
/// folder; the next run of any of the tests removes it (`removeFoldersOfEndedRuns`).
/// Folders that tests make beside one of their own (a sibling of a library, say) are
/// inside it too, and go with it.
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
        // What runs that ended without getting that far left behind goes now, on the side.
        DispatchQueue.global(qos: .utility).async {
            TemporaryRunFolder.removeFoldersOfEndedRuns(in: parent)
        }
        return folder
    }()

    /// The folder's path once it has been made; nil before.
    nonisolated(unsafe) private static var path: String?

    /// The id of the process whose folder has this name ("voxcarrel-run-<id>-<UUID>");
    /// nil for any other name.
    static func processOfRun(named name: String) -> Int32? {
        guard name.hasPrefix(prefix) else { return nil }
        let parts = name.dropFirst(prefix.count).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[0].utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
              let process = Int32(parts[0]), process > 1, UUID(uuidString: String(parts[1])) != nil
        else { return nil }
        return process
    }

    /// Removes, from `parent`, the folders of runs whose process has ended: a run that
    /// crashed or was stopped never removed its own. Only a folder itself (never a link
    /// or a file) that is named as a run's is taken, and only when no process has the
    /// id in its name any more; this run's own is left, like any other that is going.
    static func removeFoldersOfEndedRuns(in parent: URL) {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: parent.path)) ?? [] {
            guard let process = processOfRun(named: name), process != ProcessInfo.processInfo.processIdentifier,
                  kill(process, 0) == -1, errno == ESRCH
            else { continue }
            let folder = parent.appendingPathComponent(name, isDirectory: true)
            var info = stat()
            guard lstat(folder.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid() else {
                continue
            }
            try? fm.removeItem(at: folder)
        }
    }

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

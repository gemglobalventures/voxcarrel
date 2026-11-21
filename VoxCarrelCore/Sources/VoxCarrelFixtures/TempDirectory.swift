import Foundation

/// Creates a unique empty directory under the system temp folder, or under the folder
/// named by the environment variable `VOXCARREL_TEST_TMP` when it is set (to run the
/// suite on another volume, such as a case-sensitive one).
public func makeTempDir() throws -> URL {
    let parent = ProcessInfo.processInfo.environment["VOXCARREL_TEST_TMP"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
    let url = parent
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

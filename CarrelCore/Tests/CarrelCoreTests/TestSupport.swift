import Foundation

/// Creates a unique empty directory under the system temp folder.
func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("carrel-\(UUID().uuidString)", isDirectory: true)
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

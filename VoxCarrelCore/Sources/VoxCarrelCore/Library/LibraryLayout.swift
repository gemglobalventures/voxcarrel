import Foundation

/// Where VoxCarrel keeps its own data inside a library, and path rules that depend on the disk.
public struct LibraryLayout: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// `<root>/.voxcarrel`
    public var hiddenFolder: URL {
        root.appendingPathComponent(".voxcarrel", isDirectory: true)
    }

    /// `<root>/.voxcarrel/covers`
    public var coversFolder: URL {
        hiddenFolder.appendingPathComponent("covers", isDirectory: true)
    }

    /// `<root>/.voxcarrel/undo`
    public var undoFolder: URL {
        hiddenFolder.appendingPathComponent("undo", isDirectory: true)
    }

    /// Rewrites the folders of a path inside the library to the capitalisation that
    /// already exists on disk, component by component from the root. Components that
    /// do not exist yet, and the last component (the file name), are returned as given.
    ///
    /// Only reads directory listings. A URL that is not below the root is returned unchanged.
    public func adoptingExistingCapitalisation(_ url: URL) -> URL {
        let rootParts = root.standardizedFileURL.pathComponents
        let parts = url.standardizedFileURL.pathComponents
        guard parts.count > rootParts.count, Array(parts.prefix(rootParts.count)) == rootParts
        else { return url }

        let relative = Array(parts.dropFirst(rootParts.count))
        let fileManager = FileManager.default
        var current = root
        // False once a component was not found: nothing below it can exist either.
        var onDisk = true
        for name in relative.dropLast() {
            var adopted = name
            if onDisk {
                if let existing = Self.existingFolderName(matching: name, in: current, fileManager) {
                    adopted = existing
                } else {
                    onDisk = false
                }
            }
            current = current.appendingPathComponent(adopted, isDirectory: true)
        }
        return current.appendingPathComponent(relative[relative.count - 1], isDirectory: url.hasDirectoryPath)
    }

    /// The name, as spelled on disk, of the folder in `parent` that `name` refers to once
    /// capitalisation is ignored. An exact match wins; nil when there is no such folder.
    private static func existingFolderName(
        matching name: String, in parent: URL, _ fileManager: FileManager
    ) -> String? {
        guard let names = try? fileManager.contentsOfDirectory(atPath: parent.path) else { return nil }
        func isFolder(_ candidate: String) -> Bool {
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(
                atPath: parent.appendingPathComponent(candidate).path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
        if names.contains(name), isFolder(name) { return name }
        return names.sorted().first { sameNameIgnoringCase($0, name) && isFolder($0) }
    }

    private static func sameNameIgnoringCase(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: [.caseInsensitive]) == .orderedSame
    }

    /// True when both URLs name the same location once capitalisation is ignored.
    public static func samePathIgnoringCase(_ a: URL, _ b: URL) -> Bool {
        let partsA = a.standardizedFileURL.pathComponents
        let partsB = b.standardizedFileURL.pathComponents
        return partsA.count == partsB.count
            && zip(partsA, partsB).allSatisfy { sameNameIgnoringCase($0, $1) }
    }
}

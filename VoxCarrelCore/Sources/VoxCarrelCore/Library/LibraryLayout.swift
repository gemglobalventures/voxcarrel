import Foundation

/// What folders were found to hold, kept for the length of one piece of work during
/// which nothing on disk changes (planning a change of folder layout over a whole library).
final class FolderNames {
    struct Asked: Hashable {
        var folder: String
        var name: String
    }

    /// The names in each folder listed so far; nil for one that could not be listed.
    var listings: [String: [String]?] = [:]
    /// The folder name found for each name asked about; nil when there is none.
    var answers: [Asked: String?] = [:]
}

/// Where VoxCarrel keeps its own data inside a library, and path rules that depend on the disk.
public struct LibraryLayout: Sendable {
    public let root: URL
    /// Where the catalogue and the covers are kept when they are kept apart from the
    /// books, on this Mac; nil when they are inside the library's own folder.
    public let home: URL?

    public init(root: URL, home: URL? = nil) {
        self.root = root
        self.home = home
    }

    /// `<root>/.voxcarrel`
    public var hiddenFolder: URL {
        root.appendingPathComponent(".voxcarrel", isDirectory: true)
    }

    /// `<root>/.voxcarrel/covers`, or `covers` beside a catalogue kept apart from the
    /// books: the covers are shown whether or not the books' drive is there.
    public var coversFolder: URL {
        (home ?? hiddenFolder).appendingPathComponent("covers", isDirectory: true)
    }

    /// `<root>/.voxcarrel/undo`
    public var undoFolder: URL {
        hiddenFolder.appendingPathComponent("undo", isDirectory: true)
    }

    /// `<root>/.voxcarrel/moving`: where book folders are set aside for a moment while
    /// folders that are in each other's way change places. Empty, and absent, at rest.
    public var movingFolder: URL {
        hiddenFolder.appendingPathComponent("moving", isDirectory: true)
    }

    /// A folder's location in the one form used to compare paths: no `.` or `..`, and no
    /// symbolic links (so `/private/tmp/x` and `/tmp/x` come out the same), spelled as
    /// the disk spells it. The folder should exist; one that does not is treated as
    /// `canonical(_:)` treats a file.
    public static func canonicalFolder(_ folder: URL) -> URL {
        let standard = folder.standardizedFileURL
        guard FileManager.default.fileExists(atPath: standard.path) else { return canonical(standard) }
        return standard.resolvingSymlinksInPath()
    }

    /// A file's location in the form used to compare paths: the folders above it are
    /// resolved as far as they exist (`canonicalFolder`, so in the disk's spelling), and
    /// the names below the deepest existing folder are kept as given. The last component
    /// is never resolved, so a file that is itself a symbolic link stays where it is.
    /// Two spellings of one location give the same answer, apart from capitalisation,
    /// whether or not the file exists.
    static func canonical(_ url: URL) -> URL {
        let standard = url.standardizedFileURL
        guard standard.pathComponents.count > 1 else { return standard }
        var names = [standard.lastPathComponent]
        var folder = standard.deletingLastPathComponent()
        while folder.pathComponents.count > 1, !FileManager.default.fileExists(atPath: folder.path) {
            names.insert(folder.lastPathComponent, at: 0)
            folder = folder.deletingLastPathComponent()
        }
        var result = folder.resolvingSymlinksInPath()
        for name in names.dropLast() { result.appendPathComponent(name, isDirectory: true) }
        result.appendPathComponent(names[names.count - 1], isDirectory: url.hasDirectoryPath)
        return result
    }

    /// The names leading from the library root down to `url`, exactly as `url` spells
    /// them, or nil when it is not strictly inside the library.
    ///
    /// Decided by path components, never by comparing path text, and it does not matter
    /// how the part of the path that leads to the library is spelled (`/private/tmp` or
    /// `/tmp`, through a link, with `..`) or whether `url` exists yet.
    public func relativeComponents(of url: URL) -> [String]? {
        let parts = url.standardizedFileURL.pathComponents
        let rootParts = root.standardizedFileURL.pathComponents
        if parts.count > rootParts.count, Array(parts.prefix(rootParts.count)) == rootParts {
            return Array(parts.dropFirst(rootParts.count))
        }
        // Spelled differently: find the folder on the way down that is the library.
        let canonicalRoot = Self.canonicalFolder(root).pathComponents
        var folder = URL(fileURLWithPath: "/", isDirectory: true)
        for (index, name) in parts.enumerated().dropFirst().dropLast() {
            folder.appendPathComponent(name, isDirectory: true)
            guard FileManager.default.fileExists(atPath: folder.path) else { return nil }
            if Self.canonicalFolder(folder).pathComponents == canonicalRoot {
                return Array(parts.dropFirst(index + 1))
            }
        }
        return nil
    }

    /// Rewrites the folders of a path inside the library to the capitalisation that
    /// already exists on disk, component by component from the root. Components that
    /// do not exist yet, and the last component (the file name), are returned as given.
    ///
    /// Only reads directory listings. A URL that is not below the root is returned unchanged.
    public func adoptingExistingCapitalisation(_ url: URL) -> URL {
        adoptingExistingCapitalisation(url, remembering: nil)
    }

    /// As `adoptingExistingCapitalisation(_:)`, for a piece of work that asks about many
    /// paths while nothing on disk changes: what each folder holds, and which name was
    /// found for each one asked about, is looked up once and kept in `names`.
    func adoptingExistingCapitalisation(_ url: URL, remembering names: FolderNames?) -> URL {
        guard let relative = relativeComponents(of: url) else { return url }
        let fileManager = FileManager.default
        var current = root
        // False once a component was not found: nothing below it can exist either.
        var onDisk = true
        for name in relative.dropLast() {
            var adopted = name
            if onDisk {
                if let existing = Self.existingFolderName(matching: name, in: current, fileManager, names) {
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
        matching name: String, in parent: URL, _ fileManager: FileManager, _ remembered: FolderNames?
    ) -> String? {
        guard let remembered else { return findFolderName(matching: name, in: parent, fileManager) }
        let asked = FolderNames.Asked(folder: parent.path, name: name)
        if let answer = remembered.answers[asked] { return answer }
        let answer = findFolderName(matching: name, in: parent, fileManager, listing: remembered)
        remembered.answers[asked] = .some(answer)
        return answer
    }

    private static func findFolderName(
        matching name: String, in parent: URL, _ fileManager: FileManager, listing remembered: FolderNames? = nil
    ) -> String? {
        let listed: [String]?
        if let remembered, let kept = remembered.listings[parent.path] {
            listed = kept
        } else {
            listed = try? fileManager.contentsOfDirectory(atPath: parent.path)
            remembered?.listings[parent.path] = .some(listed)
        }
        guard let names = listed else { return nil }
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

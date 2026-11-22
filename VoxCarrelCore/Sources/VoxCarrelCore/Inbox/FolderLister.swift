import Foundation

/// One file found under a watch folder, with what tells one state of it from another.
public struct ListedFile: Hashable, Sendable {
    public var url: URL
    public var size: Int64
    public var modifiedAt: Date

    public init(url: URL, size: Int64, modifiedAt: Date) {
        self.url = url
        self.size = size
        self.modifiedAt = modifiedAt
    }
}

/// Whether a watch folder could be looked into.
public enum FolderAvailability: Equatable, Sendable {
    case available
    /// Nothing is at the path, or what is there is not a folder: a drive not plugged
    /// in, a folder moved or deleted.
    case missing
    /// The folder is there and the system would not let it be read.
    case notAllowed
}

/// What listing a watch folder found.
public struct FolderListing: Sendable {
    public var availability: FolderAvailability
    /// Sorted by path. Empty unless the folder is available.
    public var files: [ListedFile]

    public init(availability: FolderAvailability, files: [ListedFile]) {
        self.availability = availability
        self.files = files
    }
}

/// Finds the book files under a watch folder. Reads names and attributes only: no
/// file is opened, changed or, when it is kept in iCloud, downloaded.
public struct FolderLister: Sendable {
    /// Whether a file's contents are on this Mac. A test seam: a placeholder for a
    /// file kept elsewhere cannot be made in a temporary folder.
    var isDownloaded: @Sendable (URL) -> Bool = { FolderLister.isDownloaded($0) }

    public init() {}

    /// The supported book files anywhere under `folder`: regular files with content,
    /// of a format the importer takes, PDFs only when `includePDFs`.
    ///
    /// Left out: hidden files and everything under a hidden folder; everything inside a
    /// package or a folder named like a book file; symbolic links, which are not
    /// followed; empty files; files not downloaded. A sub-folder that cannot be read is
    /// passed over.
    ///
    /// Each path is `folder`'s own path with the names below it added, so one folder
    /// given the same way lists an unchanged file the same way every time.
    public func list(_ folder: URL, includePDFs: Bool) -> FolderListing {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: folder.path, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return FolderListing(availability: .missing, files: [])
        }

        let keys: [URLResourceKey] = [
            .isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
        ]
        func children(of directory: URL) throws -> [URL] {
            try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        }

        var files: [ListedFile] = []
        /// Folders still to look into, each with its own path built from `root`.
        var waiting: [(found: [URL], path: URL)]
        do {
            waiting = [(try children(of: root), root)]
        } catch {
            // Gone between the two looks, or there and closed to us.
            let gone = (error as? CocoaError)?.code == .fileReadNoSuchFile
            return FolderListing(availability: gone ? .missing : .notAllowed, files: [])
        }

        while let (found, path) = waiting.popLast() {
            for child in found {
                let name = child.lastPathComponent
                let format = FileFormat(url: child)
                guard let values = try? child.resourceValues(forKeys: Set(keys)), values.isSymbolicLink != true
                else { continue }

                if values.isDirectory == true {
                    // As the importer sees it: a package, or a folder named like a
                    // book file, is one item and not a folder of books.
                    guard format == nil,
                        (try? child.resourceValues(forKeys: [.isPackageKey]))?.isPackage != true,
                        let inside = try? children(of: child)
                    else { continue }
                    waiting.append((inside, path.appendingPathComponent(name, isDirectory: true)))
                    continue
                }

                guard let format, includePDFs || format != .pdf,
                    values.isRegularFile == true,
                    let size = values.fileSize, size > 0,
                    let modifiedAt = values.contentModificationDate,
                    isDownloaded(child)
                else { continue }
                files.append(ListedFile(
                    url: path.appendingPathComponent(name, isDirectory: false), size: Int64(size),
                    modifiedAt: modifiedAt))
            }
        }
        files.sort { $0.url.path < $1.url.path }
        return FolderListing(availability: .available, files: files)
    }

    /// Whether the file's contents are on this Mac, found without touching them: the
    /// answer comes from the file's attributes, and asking for those downloads nothing.
    /// A file that cannot be asked about is taken as not downloaded.
    static func isDownloaded(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        let status = (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?
            .ubiquitousItemDownloadingStatus
        return isDownloaded(status: status, flags: info.st_flags)
    }

    /// - Parameters:
    ///   - status: What iCloud says of the file; nil for a file iCloud does not keep.
    ///   - flags: The file's flags as `lstat` reports them. `SF_DATALESS` marks a file
    ///     whose contents are kept elsewhere, by iCloud or any other file provider.
    static func isDownloaded(status: URLUbiquitousItemDownloadingStatus?, flags: UInt32) -> Bool {
        if let status, status != .current { return false }
        return flags & UInt32(SF_DATALESS) == 0
    }
}

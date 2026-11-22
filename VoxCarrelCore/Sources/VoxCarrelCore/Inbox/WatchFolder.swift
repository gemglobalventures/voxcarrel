import Foundation

/// What reviewing a book from a watch folder does with its files unless the owner says otherwise.
public enum WatchFolderMode: String, Codable, Sendable { case move, copy }

/// A folder the library watches for books that arrive.
public struct WatchFolder: Identifiable, Equatable, Sendable {
    public var id: Int64
    /// Absolute and standardised, with symbolic links resolved and no trailing slash.
    /// A path on this Mac: on another it may lead nowhere.
    public var path: String
    public var mode: WatchFolderMode
    public var isEnabled: Bool
    public var includesPDFs: Bool
    public var addedAt: Date

    public init(
        id: Int64, path: String, mode: WatchFolderMode = .move, isEnabled: Bool = true,
        includesPDFs: Bool = false, addedAt: Date
    ) {
        self.id = id
        self.path = path
        self.mode = mode
        self.isEnabled = isEnabled
        self.includesPDFs = includesPDFs
        self.addedAt = addedAt
    }

    /// The folder itself.
    public var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
}

/// Why a folder cannot be watched.
public enum WatchFolderProblem: Error, Equatable, Sendable {
    /// Nothing is there, or what is there is not a folder.
    case notAFolder
    case isLibrary
    case insideLibrary
    case containsLibrary
    /// It is the same as, inside or around another watch folder, whose path this is.
    case overlaps(existing: String)
}

/// Why a watch folder could not be changed.
public enum WatchFolderError: Error, Equatable, Sendable {
    /// No watch folder has this id.
    case notFound(Int64)
}

/// A book that has arrived in a watch folder and waits to be reviewed.
public struct InboxArrival: Identifiable, Equatable, Sendable {
    /// The path of its first file: the same from check to check while that file stays
    /// where it is.
    public var id: String
    public var folderId: Int64
    /// The book as the scanner groups and names it.
    public var candidate: CandidateBook
    /// The candidate's files, all under the one watch folder.
    public var files: [URL]
    /// The latest modification date among its files.
    public var arrivedAt: Date

    public init(id: String, folderId: Int64, candidate: CandidateBook, files: [URL], arrivedAt: Date) {
        self.id = id
        self.folderId = folderId
        self.candidate = candidate
        self.files = files
        self.arrivedAt = arrivedAt
    }
}

/// A watch folder and whether it could be looked into at the last check.
public struct WatchFolderStatus: Equatable, Sendable {
    public var folder: WatchFolder
    /// A folder that is not enabled is not looked at, and is given as available. So is
    /// one that overlaps the library.
    public var availability: FolderAvailability

    public init(folder: WatchFolder, availability: FolderAvailability) {
        self.folder = folder
        self.availability = availability
    }
}

/// What a check of the inbox found.
public struct InboxReport: Equatable, Sendable {
    /// Newest first, then by id.
    public var arrivals: [InboxArrival]
    /// Every watch folder, enabled or not, oldest first.
    public var folders: [WatchFolderStatus]
    /// Whether some file was seen that has not yet settled: another check, a settle
    /// interval on, may find more.
    public var hasUnsettled: Bool

    public init(arrivals: [InboxArrival], folders: [WatchFolderStatus], hasUnsettled: Bool) {
        self.arrivals = arrivals
        self.folders = folders
        self.hasUnsettled = hasUnsettled
    }
}

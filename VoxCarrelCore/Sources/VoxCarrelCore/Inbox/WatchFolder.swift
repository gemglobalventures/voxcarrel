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

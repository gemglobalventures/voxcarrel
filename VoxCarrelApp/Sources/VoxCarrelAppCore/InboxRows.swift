import Foundation
import VoxCarrelCore

/// A book waiting in the Inbox, as its table shows it.
public struct InboxRow: Identifiable, Equatable, Sendable {
    public var id: String
    /// The book's title; when its files give none, the first file's name.
    public var title: String
    /// Empty when unknown.
    public var author: String
    /// "Audiobook", "Ebook" or "Audiobook and ebook".
    public var kind: String
    /// "1 file", "12 files".
    public var files: String
    /// The name of the watch folder it arrived in.
    public var folder: String
    public var arrived: Date

    public init(
        id: String, title: String, author: String, kind: String, files: String, folder: String, arrived: Date
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.kind = kind
        self.files = files
        self.folder = folder
        self.arrived = arrived
    }
}

/// A watch folder, as Settings lists it.
public struct WatchFolderRow: Identifiable, Equatable, Sendable {
    public var id: Int64
    /// Where the folder is, with `~` for the home folder.
    public var path: String
    public var mode: WatchFolderMode
    public var isEnabled: Bool
    public var includesPDFs: Bool
    /// Why the folder is not being watched; nil when it is.
    public var note: String?

    public init(id: Int64, path: String, mode: WatchFolderMode, isEnabled: Bool, includesPDFs: Bool, note: String?) {
        self.id = id
        self.path = path
        self.mode = mode
        self.isEnabled = isEnabled
        self.includesPDFs = includesPDFs
        self.note = note
    }
}

/// The words of the Inbox and of the watch folder settings.
public enum InboxText {
    public static let folderMissing = "Folder not found. It will be watched again when it returns."
    public static let folderNotAllowed =
        "VoxCarrel is not allowed to read this folder. Allow it in System Settings ▸ Privacy & Security ▸ Files and Folders."
    public static let folderOverlapsLibrary = "This folder overlaps your library, so it is not being watched."
    public static let folderOff = "Off"
    public static let couldNotCheck = "The inbox could not be checked."

    /// WF14
    public static func row(for arrival: InboxArrival, folder: WatchFolder?) -> InboxRow {
        let files = arrival.candidate.files
        let firstName = (files.first?.url ?? arrival.files.first)?.deletingPathExtension().lastPathComponent
        let hasAudio = files.contains { $0.role == .audio }
        let hasEbook = files.contains { $0.role == .ebook }
        return InboxRow(
            id: arrival.id,
            title: arrival.candidate.metadata.title.trimmedOrNil ?? firstName ?? "",
            author: arrival.candidate.metadata.authors.compactMap(\.trimmedOrNil).joined(separator: ", "),
            kind: hasAudio && hasEbook ? "Audiobook and ebook" : hasAudio ? "Audiobook" : "Ebook",
            files: files.count == 1 ? "1 file" : "\(files.count) files",
            folder: folder?.url.lastPathComponent ?? "",
            arrived: arrival.arrivedAt)
    }

    /// WF14, WF15. `home`: the home folder, shown as `~`.
    public static func row(for status: WatchFolderStatus, home: String = NSHomeDirectory()) -> WatchFolderRow {
        let folder = status.folder
        return WatchFolderRow(
            id: folder.id, path: abbreviated(folder.path, home: home), mode: folder.mode,
            isEnabled: folder.isEnabled, includesPDFs: folder.includesPDFs, note: note(for: status))
    }

    /// WF15: why the folder is not being watched; nil when it is.
    public static func note(for status: WatchFolderStatus) -> String? {
        // A folder that is off is not looked at, so nothing else is known about it.
        guard status.folder.isEnabled else { return folderOff }
        switch status.availability {
        case .available: return nil
        case .missing: return folderMissing
        case .notAllowed: return folderNotAllowed
        case .overlapsLibrary: return folderOverlapsLibrary
        }
    }

    /// WF14: the path with `~` in place of the home folder when it is the home folder
    /// or inside it. Decided name by name: `/Users/samantha` is not inside `/Users/sam`.
    public static func abbreviated(_ path: String, home: String = NSHomeDirectory()) -> String {
        let parts = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        let homeParts = URL(fileURLWithPath: home).standardizedFileURL.pathComponents
        guard homeParts.count > 1, parts.count >= homeParts.count, Array(parts.prefix(homeParts.count)) == homeParts
        else { return path }
        return (["~"] + parts.dropFirst(homeParts.count)).joined(separator: "/")
    }

    /// The path a row shows, as a path again.
    public static func expanded(_ path: String, home: String = NSHomeDirectory()) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        return home + path.dropFirst()
    }
}

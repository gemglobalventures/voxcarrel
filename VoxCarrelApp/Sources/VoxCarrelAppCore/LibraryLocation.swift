import Foundation
import VoxCarrelCore

/// Whether there is a library to open.
public enum LibraryStatus: Equatable, Sendable {
    /// No folder has been chosen yet.
    case notChosen
    /// A folder was chosen, but it is not there now or cannot be written to.
    case unavailable(URL)
    case available(URL)
}

/// What choosing a folder as the library would mean.
public enum FolderKind: Equatable, Sendable {
    /// Contains VoxCarrel.sqlite.
    case existingLibrary
    /// Nothing but hidden files such as .DS_Store.
    case empty
    /// `count`: the visible items directly inside. `bookFiles`: the audiobook and ebook
    /// files anywhere inside, counted up to `LibraryLocation.bookFileLimit`; one more
    /// than the limit means "more than the limit".
    case hasOtherFiles(count: Int, bookFiles: Int)
    /// Not a folder, not writable, or a place that must not become a library (the home
    /// folder, a folder inside another library, …). The text says which, and what to do.
    case notUsable(String)
}

/// A place whose files a service keeps in step with other machines, and may keep
/// elsewhere and not on this Mac.
public struct SyncedPlace: Equatable, Sendable {
    /// "iCloud Drive", "Dropbox", "OneDrive", "Google Drive", or "a cloud service".
    public var name: String

    public init(name: String) {
        self.name = name
    }

    /// The synced place a folder lies in, by where it is; nil for a folder in none.
    ///
    /// iCloud Drive keeps its files under `~/Library/Mobile Documents`, and the other
    /// services under `~/Library/CloudStorage/<Service>-…`. A Desktop or Documents
    /// folder kept in iCloud is found by asking the system (`isInICloud`).
    /// - Parameter isInICloud: Whether the system says the folder is kept in iCloud.
    public static func of(
        _ folder: URL,
        isInICloud: (URL) -> Bool = { (try? $0.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true }
    ) -> SyncedPlace? {
        let real = folder.resolvingSymlinksInPath().standardizedFileURL
        let parts = real.pathComponents
        for (index, part) in parts.enumerated() where part == "Library" && index + 1 < parts.count {
            if parts[index + 1] == "Mobile Documents" { return SyncedPlace(name: "iCloud Drive") }
            if parts[index + 1] == "CloudStorage" {
                let service = index + 2 < parts.count ? parts[index + 2] : ""
                let known = [("Dropbox", "Dropbox"), ("OneDrive", "OneDrive"), ("GoogleDrive", "Google Drive"), ("Box", "Box")]
                let name = known.first { service.hasPrefix($0.0) }?.1 ?? "a cloud service"
                return SyncedPlace(name: name)
            }
        }
        return isInICloud(real) ? SyncedPlace(name: "iCloud Drive") : nil
    }

    /// Said once, when such a folder is chosen as the library.
    public var warning: String {
        "This folder is kept in step with other machines by \(name). VoxCarrel works there, with two risks. "
            + "If the library is open on two Macs at once, or is synced while VoxCarrel is writing, its catalogue "
            + "can be damaged. And books may be kept in the cloud and not on this Mac: VoxCarrel leaves those "
            + "alone until you open them. A folder that is not synced is safer."
    }

    /// Said under the library folder in Settings for as long as it is one.
    public var note: String {
        "This folder is synced by \(name). Do not open the library on two Macs at once. "
            + "Books kept in the cloud and not on this Mac are left alone until you open them."
    }
}

/// Which folder is the library, remembered in the app's preferences, and whether it is there.
public struct LibraryLocation {
    public static let defaultsKey = "libraryPath"

    private let defaults: UserDefaults

    /// A folder shown as the library until the app is quit or a library is chosen,
    /// without being remembered. Shared by every copy of this location.
    private final class ForNow: @unchecked Sendable {
        var url: URL?
    }

    private let forNow = ForNow()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Shows `folder` as the library for now: until the app is quit, or a library is
    /// chosen. The remembered library is not changed.
    public func showForNow(_ folder: URL) {
        forNow.url = folder
    }

    /// True while the library shown is one that is not remembered (`showForNow`).
    public var isShownForNow: Bool { forNow.url != nil }

    /// Whether a library has been chosen and is remembered, whatever is shown for now.
    public var hasRemembered: Bool {
        !(defaults.string(forKey: Self.defaultsKey) ?? "").isEmpty
    }

    /// The chosen library folder; nil when none has been chosen. Setting nil forgets it.
    /// Setting it ends a folder shown for now.
    public var url: URL? {
        get {
            if let shown = forNow.url { return shown }
            guard let path = defaults.string(forKey: Self.defaultsKey), !path.isEmpty else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        nonmutating set {
            forNow.url = nil
            if let newValue {
                defaults.set(newValue.path, forKey: Self.defaultsKey)
            } else {
                defaults.removeObject(forKey: Self.defaultsKey)
            }
        }
    }

    public func status() -> LibraryStatus {
        guard let url else { return .notChosen }
        if Self.isWritableFolder(url) { return .available(url) }
        // The books' drive is away, but the catalogue is on this Mac: the library can
        // still be opened and looked through.
        return CatalogueHome.find(forRoot: url, in: CatalogueHome.standardFolder) != nil ? .available(url) : .unavailable(url)
    }

    /// The most book files `inspect` counts.
    public static let bookFileLimit = 1000

    /// What choosing this folder as the library would mean.
    ///
    /// Looks inside the folder, but not far: a library below it is looked for four
    /// folders down at most, and book files are counted up to `bookFileLimit`.
    public static func inspect(_ folder: URL, places: ProtectedPlaces = .system) -> FolderKind {
        let fm = FileManager.default
        let name = folder.lastPathComponent
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .notUsable("\"\(name)\" is not a folder.")
        }
        if let why = places.refusal(for: folder) {
            return .notUsable(why)
        }
        guard fm.isWritableFile(atPath: folder.path) else {
            return .notUsable("VoxCarrel cannot make changes in \"\(name)\".")
        }
        if let outer = libraryAbove(folder) {
            return .notUsable(
                "\"\(name)\" is inside the VoxCarrel library \"\(outer.lastPathComponent)\", so it cannot be a "
                    + "library itself. Choose that library's folder, or a folder outside it.")
        }
        if CatalogueHome.isLibraryFolder(folder) {
            return .existingLibrary
        }
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else {
            return .notUsable("\"\(name)\" cannot be opened.")
        }
        let visible = names.filter { !$0.hasPrefix(".") }
        if visible.isEmpty { return .empty }
        if let inner = libraryBelow(folder) {
            return .notUsable(
                "\"\(name)\" already holds a VoxCarrel library, in \"\(inner)\". Using the folder around it "
                    + "would take that library's books away from it. Choose that library's folder, or another folder.")
        }
        return .hasOtherFiles(count: visible.count, bookFiles: bookFileCount(in: folder, limit: bookFileLimit))
    }

    /// The library folder this folder is inside, if any: the nearest folder above it
    /// that holds a catalogue.
    private static func libraryAbove(_ folder: URL) -> URL? {
        let fm = FileManager.default
        var current = folder.resolvingSymlinksInPath().standardizedFileURL
        while current.path != "/" {
            let parent = current.deletingLastPathComponent()
            guard parent.path != current.path else { return nil }
            if CatalogueHome.isLibraryFolder(parent) {
                return parent
            }
            current = parent
        }
        return nil
    }

    /// Where a library lies below this folder, as a path from it; nil when none was
    /// found. Looks at most `depth` folders down and into at most `folderLimit`
    /// folders; hidden folders and packages are not looked inside.
    private static func libraryBelow(_ folder: URL, depth: Int = 4, folderLimit: Int = 2000) -> String? {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .isHiddenKey]
        var visited = 0
        // Level by level, so that a library near the top is found before the limit is spent.
        var level: [(url: URL, path: [String])] = [(folder, [])]
        for _ in 0..<depth {
            var next: [(url: URL, path: [String])] = []
            for (url, path) in level {
                guard let children = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: keys) else {
                    continue
                }
                for child in children {
                    guard let values = try? child.resourceValues(forKeys: Set(keys)),
                          values.isDirectory == true, values.isSymbolicLink != true, values.isPackage != true,
                          values.isHidden != true, !child.lastPathComponent.hasPrefix(".")
                    else { continue }
                    let childPath = path + [child.lastPathComponent]
                    if fm.fileExists(atPath: child.appendingPathComponent(LibraryStore.databaseFileName).path) {
                        return childPath.joined(separator: "/")
                    }
                    visited += 1
                    if visited >= folderLimit { return nil }
                    next.append((child, childPath))
                }
            }
            level = next
        }
        return nil
    }

    /// How many audiobook and ebook files are anywhere inside the folder, as the launch
    /// check would find them: hidden files and folders, packages and links are passed
    /// over. Stops at one more than `limit`, and after looking at `entryLimit` items.
    public static func bookFileCount(in folder: URL, limit: Int, entryLimit: Int = 100_000) -> Int {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return 0 }
        var count = 0
        var seen = 0
        for case let url as URL in walker {
            seen += 1
            if seen > entryLimit { break }
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isSymbolicLink == true || values.isPackage == true {
                walker.skipDescendants()
                continue
            }
            if values.isDirectory == true {
                if FileFormat(url: url) != nil { walker.skipDescendants() }
                continue
            }
            if values.isRegularFile == true, FileFormat(url: url) != nil {
                count += 1
                if count > limit { break }
            }
        }
        return count
    }

    private static func isWritableFolder(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue && FileManager.default.isWritableFile(atPath: url.path)
    }
}

/// The folders that must not be made a library, because everything in them would be
/// offered for filing: the home folder, the folders macOS puts in it, the system's own
/// folders and the top level of any disk. A folder inside one of them is fine.
public struct ProtectedPlaces: Sendable {
    /// The folders macOS makes in a home folder.
    public static let standardFolderNames = [
        "Desktop", "Documents", "Downloads", "Music", "Movies", "Pictures", "Library", "Public", "Applications",
    ]

    public var home: URL
    public var systemFolders: [URL]
    /// Whether a folder is the top level of a disk.
    public var isVolumeRoot: @Sendable (URL) -> Bool

    public init(home: URL, systemFolders: [URL], isVolumeRoot: @escaping @Sendable (URL) -> Bool) {
        self.home = home
        self.systemFolders = systemFolders
        self.isVolumeRoot = isVolumeRoot
    }

    /// This Mac's.
    public static let system = ProtectedPlaces(
        home: FileManager.default.homeDirectoryForCurrentUser,
        systemFolders: [
            "/Users", "/Users/Shared", "/System", "/Applications", "/Library", "/Volumes", "/private", "/usr",
            "/bin", "/sbin", "/opt", "/cores", "/etc", "/var", "/tmp", "/Network",
        ].map { URL(fileURLWithPath: $0, isDirectory: true) },
        isVolumeRoot: { folder in
            let path = Self.comparable(folder)
            if path == "/" || (path as NSString).deletingLastPathComponent == "/volumes" { return true }
            guard let volume = try? folder.resourceValues(forKeys: [.volumeURLKey]).volume else { return false }
            return Self.comparable(volume) == path
        })

    private static let advice =
        "Choose or create a folder just for your library, such as Documents/VoxCarrel Library."

    /// Why this folder must not be a library, as a sentence with what to do instead;
    /// nil when it may be one.
    public func refusal(for folder: URL) -> String? {
        let path = Self.comparable(folder)
        let name = folder.standardizedFileURL.lastPathComponent
        if path == Self.comparable(home) {
            return "Your home folder cannot be the library: VoxCarrel would offer to file every audio file and "
                + "PDF in it. " + Self.advice
        }
        if Self.standardFolderNames.contains(where: { Self.comparable(home.appendingPathComponent($0)) == path }) {
            return "\"\(name)\" itself cannot be the library: VoxCarrel would offer to file every audio file and "
                + "PDF in it. " + Self.advice
        }
        if isVolumeRoot(folder) {
            return "The top level of a disk cannot be the library. Choose or create a folder on it just for "
                + "your library, such as \"VoxCarrel Library\"."
        }
        if systemFolders.contains(where: { Self.comparable($0) == path }) {
            return "\"\(name)\" belongs to macOS and cannot be the library. " + Self.advice
        }
        return nil
    }

    /// A folder's path however it was spelled, for comparing.
    private static func comparable(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
    }
}

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
    case hasOtherFiles(count: Int)
    /// Not a folder, or not writable. The text says which.
    case notUsable(String)
}

/// Which folder is the library, remembered in the app's preferences, and whether it is there.
public struct LibraryLocation {
    public static let defaultsKey = "libraryPath"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The chosen library folder; nil when none has been chosen. Setting nil forgets it.
    public var url: URL? {
        get {
            guard let path = defaults.string(forKey: Self.defaultsKey), !path.isEmpty else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        nonmutating set {
            if let newValue {
                defaults.set(newValue.path, forKey: Self.defaultsKey)
            } else {
                defaults.removeObject(forKey: Self.defaultsKey)
            }
        }
    }

    public func status() -> LibraryStatus {
        guard let url else { return .notChosen }
        return Self.isWritableFolder(url) ? .available(url) : .unavailable(url)
    }

    /// What choosing this folder as the library would mean.
    public static func inspect(_ folder: URL) -> FolderKind {
        let fm = FileManager.default
        let name = folder.lastPathComponent
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .notUsable("\"\(name)\" is not a folder.")
        }
        guard fm.isWritableFile(atPath: folder.path) else {
            return .notUsable("VoxCarrel cannot make changes in \"\(name)\".")
        }
        if fm.fileExists(atPath: folder.appendingPathComponent(LibraryStore.databaseFileName).path) {
            return .existingLibrary
        }
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else {
            return .notUsable("\"\(name)\" cannot be opened.")
        }
        let visible = names.filter { !$0.hasPrefix(".") }
        return visible.isEmpty ? .empty : .hasOtherFiles(count: visible.count)
    }

    private static func isWritableFolder(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue && FileManager.default.isWritableFile(atPath: url.path)
    }
}

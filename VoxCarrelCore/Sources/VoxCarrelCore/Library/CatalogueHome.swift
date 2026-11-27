import Foundation

/// A library's catalogue kept on this Mac, apart from the books.
///
/// A library's books may be on a NAS, an external drive or a synced folder. Kept
/// inside that folder, the catalogue goes away when the drive does, and a synced
/// folder may damage it. Kept here, in `<libraries>/<library id>/`, with the covers
/// beside it, the library can be opened and looked through whether or not the books
/// can be reached.
///
/// Two small records tie the two together. `library.json`, beside the catalogue, says
/// which folder the books are in. `catalogue-on-mac.json`, in the books' own hidden
/// folder, says which library the folder is, so that it is known again when the drive
/// comes back under another name or path.
public enum CatalogueHome {
    static let recordName = "library.json"
    static let markerName = "catalogue-on-mac.json"
    /// What the catalogue that was inside the books' folder is called once it has been
    /// moved: kept, in the hidden folder, as the way back should it ever be needed.
    static let leftBehindName = "catalogue-before-move.sqlite"

    /// What is kept beside a catalogue on this Mac.
    public struct Record: Codable, Equatable, Sendable {
        public var id: String
        /// The folder the books are in, as it was last known.
        public var root: String
        public var moved: Date
    }

    struct Marker: Codable, Equatable {
        var id: String
    }

    public enum Problem: Error, Equatable {
        /// The books' folder cannot be reached, so nothing can be moved.
        case booksNotReachable
        /// The library's catalogue is already where it was to be moved to.
        case alreadyThere
        /// The folder holds no catalogue to move.
        case noCatalogue
    }

    /// `Libraries` in the app's own folder on this Mac. A program that is running
    /// tests is given a temporary folder: a test must not write among the owner's libraries.
    public static let standardFolder: URL = {
        let process = ProcessInfo.processInfo
        let isTesting = NSClassFromString("XCTestCase") != nil || process.processName.contains("xctest")
            || process.processName.contains("swiftpm-testing") || process.environment["XCTestConfigurationFilePath"] != nil
        if isTesting {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("voxcarrel-test-libraries-\(UUID().uuidString)", isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("VoxCarrel/Libraries", isDirectory: true)
    }()

    static func record(in home: URL) -> Record? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: home.appendingPathComponent(recordName))).flatMap { try? decoder.decode(Record.self, from: $0) }
    }

    static func write(_ record: Record, in home: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: home.appendingPathComponent(recordName), options: .atomic)
    }

    static func markerURL(inRoot root: URL) -> URL {
        LibraryLayout(root: root).hiddenFolder.appendingPathComponent(markerName)
    }

    /// The library a books' folder says it is; nil when it says nothing, or cannot be reached.
    static func markedId(inRoot root: URL) -> String? {
        (try? Data(contentsOf: markerURL(inRoot: root))).flatMap { try? JSONDecoder().decode(Marker.self, from: $0) }?.id
    }

    /// Every catalogue kept under `libraries`, with where it is.
    public static func all(in libraries: URL) -> [(home: URL, record: Record)] {
        // In the disk's own spelling, as the folders found inside it are.
        let libraries = LibraryLayout.canonicalFolder(libraries)
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: libraries, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return folders.compactMap { home in
            guard let record = record(in: home),
                  FileManager.default.fileExists(atPath: home.appendingPathComponent(LibraryStore.databaseFileName).path)
            else { return nil }
            return (home, record)
        }
    }

    /// Where the catalogue of the library whose books are in `root` is kept on this
    /// Mac; nil when it is not kept apart from them.
    ///
    /// A folder that holds a catalogue of its own is never looked up: that catalogue
    /// is the library's. Otherwise the folder's own marker says which library it is,
    /// when it can be read; and when the folder cannot be reached, the library whose
    /// record names this path is the one. A record whose path has changed is brought
    /// up to date as it is found.
    public static func find(forRoot root: URL, in libraries: URL) -> URL? {
        let canonical = LibraryLayout.canonicalFolder(root)
        if FileManager.default.fileExists(atPath: canonical.appendingPathComponent(LibraryStore.databaseFileName).path) {
            return nil
        }
        let known = all(in: libraries)
        if let id = markedId(inRoot: canonical), let match = known.first(where: { $0.record.id == id }) {
            if match.record.root != canonical.path {
                var record = match.record
                record.root = canonical.path
                try? write(record, in: match.home)
            }
            return match.home
        }
        return known.first { $0.record.root == canonical.path }?.home
    }

    /// Whether a folder is a library's: it holds a catalogue, or says that its
    /// catalogue is kept on a Mac.
    public static func isLibraryFolder(_ folder: URL) -> Bool {
        let files = FileManager.default
        return files.fileExists(atPath: folder.appendingPathComponent(LibraryStore.databaseFileName).path)
            || files.fileExists(atPath: markerURL(inRoot: folder).path)
    }

    // MARK: Moving

    private static func copyFolder(_ from: URL, to: URL) throws {
        let files = FileManager.default
        guard files.fileExists(atPath: from.path) else { return }
        if files.fileExists(atPath: to.path) { try files.removeItem(at: to) }
        try files.copyItem(at: from, to: to)
    }

    /// Moves the catalogue of the library at `root` to this Mac, with its covers. The
    /// library must not be open. Nothing of the books is touched.
    ///
    /// The catalogue is copied whole and checked before the one inside the books'
    /// folder is set aside (`catalogue-before-move.sqlite`, in the hidden folder): it
    /// is renamed, never deleted. If anything fails before then, the library is as it was.
    ///
    /// - Returns: The folder the catalogue is now in.
    @discardableResult
    public static func moveToMac(libraryAt root: URL, libraries: URL, now: Date = Date()) throws -> URL {
        let root = LibraryLayout.canonicalFolder(root)
        let files = FileManager.default
        var isDirectory: ObjCBool = false
        guard files.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw Problem.booksNotReachable
        }
        let inside = root.appendingPathComponent(LibraryStore.databaseFileName)
        guard files.fileExists(atPath: inside.path) else {
            throw find(forRoot: root, in: libraries) == nil ? Problem.noCatalogue : Problem.alreadyThere
        }
        let layout = LibraryLayout(root: root)
        let home: URL
        do {
            // Opened as it is, which also folds in anything waiting in its log.
            let store = try LibraryStore(libraryRoot: root)
            let id = try store.libraryId()
            try files.createDirectory(at: libraries, withIntermediateDirectories: true)
            home = LibraryLayout.canonicalFolder(libraries).appendingPathComponent(id, isDirectory: true)
            try files.createDirectory(at: home, withIntermediateDirectories: true)
            let making = home.appendingPathComponent(".making-\(UUID().uuidString).sqlite")
            defer { try? files.removeItem(at: making) }
            try store.copyCatalogue(to: making)
            guard CatalogueBackups.bookCount(of: making) == (try store.books().count) else { throw Problem.noCatalogue }
            let placed = home.appendingPathComponent(LibraryStore.databaseFileName)
            for extra in ["", "-wal", "-shm"] { try? files.removeItem(atPath: placed.path + extra) }
            try files.moveItem(at: making, to: placed)
            try copyFolder(layout.coversFolder, to: LibraryLayout(root: root, home: home).coversFolder)
            try write(Record(id: id, root: root.path, moved: now), in: home)
            try files.createDirectory(at: layout.hiddenFolder, withIntermediateDirectories: true)
            try JSONEncoder().encode(Marker(id: id)).write(to: markerURL(inRoot: root), options: .atomic)
        }
        // The store above is closed: its catalogue can be set aside now.
        let aside = layout.hiddenFolder.appendingPathComponent(leftBehindName)
        try? files.removeItem(at: aside)
        do {
            try files.moveItem(at: inside, to: aside)
        } catch {
            // Not set aside: the library is still the one inside its folder.
            try? files.removeItem(at: markerURL(inRoot: root))
            try? files.removeItem(at: home)
            throw error
        }
        for extra in ["-wal", "-shm", "-journal"] { try? files.removeItem(atPath: inside.path + extra) }
        // As it is found from now on, so that every spelling of the folder is the same one.
        return find(forRoot: root, in: libraries) ?? home
    }

    /// Moves the catalogue of the library whose books are in `root` back inside that
    /// folder, with its covers, and removes it from this Mac. The library must not be
    /// open, and the books' folder must be reachable.
    public static func moveBack(libraryAt root: URL, libraries: URL) throws {
        let root = LibraryLayout.canonicalFolder(root)
        let files = FileManager.default
        var isDirectory: ObjCBool = false
        guard files.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw Problem.booksNotReachable
        }
        guard let home = find(forRoot: root, in: libraries) else {
            throw files.fileExists(atPath: root.appendingPathComponent(LibraryStore.databaseFileName).path)
                ? Problem.alreadyThere : Problem.noCatalogue
        }
        let layout = LibraryLayout(root: root)
        let inside = root.appendingPathComponent(LibraryStore.databaseFileName)
        do {
            let store = try LibraryStore(libraryRoot: root, catalogueIn: home)
            let making = root.appendingPathComponent(".making-\(UUID().uuidString).sqlite")
            defer { try? files.removeItem(at: making) }
            try store.copyCatalogue(to: making)
            guard CatalogueBackups.bookCount(of: making) == (try store.books().count) else { throw Problem.noCatalogue }
            try copyFolder(LibraryLayout(root: root, home: home).coversFolder, to: layout.coversFolder)
            try files.moveItem(at: making, to: inside)
        }
        try? files.removeItem(at: markerURL(inRoot: root))
        try? files.removeItem(at: layout.hiddenFolder.appendingPathComponent(leftBehindName))
        try? files.removeItem(at: home)
    }
}

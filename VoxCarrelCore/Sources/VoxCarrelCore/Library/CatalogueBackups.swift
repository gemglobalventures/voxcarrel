import Foundation
import GRDB

/// One dated copy of a library's catalogue.
public struct CatalogueBackup: Equatable, Identifiable, Sendable {
    public var url: URL
    /// When it was made.
    public var date: Date
    public var bytes: Int64
    /// How many books the catalogue held then; nil when the copy cannot be read.
    public var bookCount: Int?
    /// Why it was made, when it was not an ordinary one: "before restore", "before layout".
    public var reason: String?

    public var id: String { url.lastPathComponent }
}

public enum CatalogueBackupError: Error, Equatable {
    /// The file is not a catalogue that can be read.
    case notACatalogue
    /// The backup is of another library.
    case anotherLibrary
}

/// Dated copies of a library's catalogue, kept in a folder away from the library: on
/// the Mac itself, so that they are there when the drive the books are on is not.
///
/// A backup is the catalogue alone: every book's details, series, collections,
/// shelves, highlights and history. The books' files and their covers are not in it.
public enum CatalogueBackups {
    /// How many are kept.
    public static let kept = 14
    static let prefix = "catalogue-"

    static func stamp(_ date: Date) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.calendar = Calendar(identifier: .gregorian)
        format.timeZone = TimeZone(identifier: "UTC")
        format.dateFormat = "yyyyMMdd-HHmmss"
        return format.string(from: date)
    }

    /// The date and the reason a backup's name states; nil for a file that is not one.
    static func parse(name: String) -> (date: Date, reason: String?)? {
        guard name.hasPrefix(prefix), name.hasSuffix(".sqlite") else { return nil }
        let middle = name.dropFirst(prefix.count).dropLast(".sqlite".count)
        guard middle.count >= 15 else { return nil }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.calendar = Calendar(identifier: .gregorian)
        format.timeZone = TimeZone(identifier: "UTC")
        format.dateFormat = "yyyyMMdd-HHmmss"
        guard let date = format.date(from: String(middle.prefix(15))) else { return nil }
        let rest = middle.dropFirst(15)
        let reason = rest.hasPrefix("-") ? String(rest.dropFirst()).replacingOccurrences(of: "-", with: " ") : nil
        return (date, reason?.isEmpty == false ? reason : nil)
    }

    /// The backups in a folder, newest first. A folder that is not there has none.
    public static func list(in folder: URL) -> [CatalogueBackup] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])) ?? []
        return files.compactMap { url -> CatalogueBackup? in
            guard let named = parse(name: url.lastPathComponent) else { return nil }
            let bytes = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            return CatalogueBackup(url: url, date: named.date, bytes: bytes, bookCount: bookCount(of: url), reason: named.reason)
        }.sorted { $0.date > $1.date }
    }

    private static func readOnly(_ url: URL) throws -> DatabaseQueue {
        var configuration = Configuration()
        configuration.readonly = true
        return try DatabaseQueue(path: url.path, configuration: configuration)
    }

    static func bookCount(of url: URL) -> Int? {
        guard let queue = try? readOnly(url) else { return nil }
        return try? queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM book") }
    }

    /// The id of the library a catalogue file is of; nil when it states none or cannot be read.
    static func libraryId(of url: URL) -> String? {
        guard let queue = try? readOnly(url) else { return nil }
        return try? queue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM librarySetting WHERE key = ?", arguments: [LibraryStore.libraryIdSetting])
        }
    }

    /// Deletes the oldest ordinary backups beyond `keeping`. Those made for a reason
    /// (before a restore, before a change of layout) are counted apart, and the same
    /// number of them is kept, so that a run of daily backups never pushes them out.
    @discardableResult
    public static func prune(in folder: URL, keeping: Int = kept) -> Int {
        let all = list(in: folder)
        var removed = 0
        for group in [all.filter { $0.reason == nil }, all.filter { $0.reason != nil }] {
            for old in group.dropFirst(max(keeping, 1)) where (try? FileManager.default.removeItem(at: old.url)) != nil {
                removed += 1
            }
        }
        return removed
    }
}

extension LibraryStore {
    static let libraryIdSetting = "libraryId"

    /// What this library is known by, wherever its folder is and whatever it is called:
    /// made the first time it is asked for, and kept in the catalogue.
    public func libraryId() throws -> String {
        try dbQueue.write { db in
            if let kept = try String.fetchOne(
                db, sql: "SELECT value FROM librarySetting WHERE key = ?", arguments: [Self.libraryIdSetting]), !kept.isEmpty {
                return kept
            }
            let made = UUID().uuidString
            try db.execute(
                sql: "INSERT INTO librarySetting (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                arguments: [Self.libraryIdSetting, made])
            return made
        }
    }

    /// Writes a whole copy of the catalogue to `url`, which must not exist.
    func copyCatalogue(to url: URL) throws {
        try dbQueue.writeWithoutTransaction { db in try Self.copyWhole(db, to: url.path) }
    }
}

extension LibraryService {
    /// Makes a backup of the catalogue in `folder` now, and deletes the oldest beyond
    /// those kept. `reason` is a word or two for one that is not an ordinary backup.
    @discardableResult
    public func backUpCatalogue(to folder: URL, now: Date = Date(), reason: String? = nil) throws -> CatalogueBackup {
        _ = try store.libraryId()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let tail = reason.map { "-" + $0.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: "-") } ?? ""
        var date = now
        var url = folder.appendingPathComponent(CatalogueBackups.prefix + CatalogueBackups.stamp(date) + tail + ".sqlite")
        // Two in one second: the later is named a second on.
        while FileManager.default.fileExists(atPath: url.path) {
            date = date.addingTimeInterval(1)
            url = folder.appendingPathComponent(CatalogueBackups.prefix + CatalogueBackups.stamp(date) + tail + ".sqlite")
        }
        // Made under another name first, so that a copy cut short is never taken for a backup.
        let making = folder.appendingPathComponent(".making-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: making) }
        try store.copyCatalogue(to: making)
        try FileManager.default.moveItem(at: making, to: url)
        CatalogueBackups.prune(in: folder)
        guard let made = CatalogueBackups.list(in: folder).first(where: { $0.url.lastPathComponent == url.lastPathComponent }) else {
            throw CatalogueBackupError.notACatalogue
        }
        return made
    }

    /// Makes a backup when none has been made on this day; nil when one has.
    @discardableResult
    public func backUpCatalogueIfDue(to folder: URL, now: Date = Date(), calendar: Calendar = .current) throws -> CatalogueBackup? {
        if let newest = CatalogueBackups.list(in: folder).first(where: { $0.reason == nil }),
           calendar.isDate(newest.date, inSameDayAs: now) {
            return nil
        }
        return try backUpCatalogue(to: folder, now: now)
    }
}

extension CatalogueBackups {
    /// Puts a backup in the place of the catalogue of the library at `root`. The
    /// library must not be open: nothing may hold its catalogue while this runs.
    ///
    /// The catalogue as it is now is first copied into `folder` as a backup of its own
    /// ("before restore"), so that the restore can be taken back. A backup of another
    /// library is refused, and so is a file that is no catalogue; nothing changes then.
    /// The books' files are not touched: those moved or added since the backup was made
    /// are found by the library's check afterwards.
    public static func restore(_ backup: URL, toLibraryAt root: URL, backups folder: URL, now: Date = Date()) throws {
        guard bookCount(of: backup) != nil else { throw CatalogueBackupError.notACatalogue }
        let root = LibraryLayout.canonicalFolder(root)
        let catalogue = root.appendingPathComponent(LibraryStore.databaseFileName)
        let files = FileManager.default
        if files.fileExists(atPath: catalogue.path) {
            // Opened as it is, which also folds in anything waiting in its log.
            let store = try LibraryStore(libraryRoot: root)
            let own = try store.libraryId()
            if let other = libraryId(of: backup), other != own { throw CatalogueBackupError.anotherLibrary }
            try LibraryService(store: store).backUpCatalogue(to: folder, now: now, reason: "before restore")
        }
        // A copy is put in place, not the backup itself: the backup stays where it is.
        let incoming = root.appendingPathComponent(".restoring-\(UUID().uuidString).sqlite")
        defer { try? files.removeItem(at: incoming) }
        try files.copyItem(at: backup, to: incoming)
        for extra in ["-wal", "-shm"] { try? files.removeItem(atPath: catalogue.path + extra) }
        if files.fileExists(atPath: catalogue.path) {
            _ = try files.replaceItemAt(catalogue, withItemAt: incoming)
        } else {
            try files.moveItem(at: incoming, to: catalogue)
        }
    }
}

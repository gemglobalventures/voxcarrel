import Foundation
import VoxCarrelCore

// Backups of the catalogue. A dated copy is made the first time a library is opened
// each day, before a change of folder layout, and whenever the owner asks. They are
// kept on this Mac, in the app's own folder, by library: there whether or not the
// drive the books are on is. A backup is the catalogue alone, not the books.

/// One backup as Settings lists it.
public struct BackupLine: Equatable, Identifiable, Sendable {
    /// The backup's file name.
    public var id: String
    /// "27 November 2026 at 12:45 · 14 books · 1.2 MB", and why it was made when it
    /// was not an ordinary one.
    public var text: String
    /// When it was made.
    public var date: Date
}

public enum BackupText {
    public static let heading = "Backups"
    public static let intro =
        "A copy of the catalogue (every book's details, series, shelves, highlights and history) is kept on this "
        + "Mac each day the library is opened, and before a change of folder layout. The last \(CatalogueBackups.kept) "
        + "are kept. The books' own files are not in a backup."
    public static let none = "No backup has been made yet."
    public static let demo = "The demo library is not backed up."
    public static let backUpNowTitle = "Back Up Now"
    public static let restoreTitle = "Restore…"
    public static let showTitle = "Show in Finder"
    public static let workingLabel = "Backing up…"
    public static let restoringLabel = "Restoring the catalogue…"
    public static let confirmTitle = "Restore the catalogue from this backup?"
    public static let confirmButton = "Restore"
    public static let confirmMessage =
        "Every book's details, series, shelves, highlights and history go back to what they were then. The catalogue "
        + "as it is now is kept as a backup first, so this can be taken back. No file is moved or changed: books "
        + "imported, moved or renamed since the backup will be found by the library's check as files it does not know."

    public static func last(_ line: BackupLine) -> String { "Last backup: \(line.text)" }

    public static func restored(_ line: BackupLine) -> String {
        "The catalogue is as it was at the backup of \(BackupText.when(line.date)). Run the library's check to find "
            + "any files that were moved or added since."
    }

    public static func when(_ date: Date) -> String {
        date.formatted(date: .long, time: .shortened)
    }

    public static func line(_ backup: CatalogueBackup) -> BackupLine {
        var parts = [when(backup.date)]
        if let count = backup.bookCount { parts.append(count == 1 ? "1 book" : "\(count) books") }
        parts.append(ByteCountFormatter.string(fromByteCount: backup.bytes, countStyle: .file))
        if let reason = backup.reason { parts.append(reason) }
        return BackupLine(id: backup.id, text: parts.joined(separator: " · "), date: backup.date)
    }
}

extension LibraryWorker {
    /// Where this library's backups are kept, under the folder all backups are in.
    public func backupsFolder(in all: URL) throws -> URL {
        all.appendingPathComponent(try withService { try $0.store.libraryId() }, isDirectory: true)
    }

    public func backups(in all: URL) throws -> [CatalogueBackup] {
        CatalogueBackups.list(in: try backupsFolder(in: all))
    }

    @discardableResult
    public func backUp(in all: URL, reason: String? = nil, now: Date = Date()) throws -> CatalogueBackup {
        let folder = try backupsFolder(in: all)
        return try withService { try $0.backUpCatalogue(to: folder, now: now, reason: reason) }
    }

    @discardableResult
    public func backUpIfDue(in all: URL, now: Date = Date()) throws -> CatalogueBackup? {
        let folder = try backupsFolder(in: all)
        return try withService { try $0.backUpCatalogueIfDue(to: folder, now: now) }
    }
}

extension AppModel {
    /// The folder every library's backups are kept under: `Backups` in the app's own
    /// folder on this Mac. Tests set a folder of their own before a model is made.
    ///
    /// A program that is running tests never gets the app's own folder, whether or not
    /// it set one: a test must not be able to write among the owner's backups.
    nonisolated(unsafe) static var backupsFolderByDefault: URL = {
        let process = ProcessInfo.processInfo
        let isTesting = NSClassFromString("XCTestCase") != nil || process.processName.contains("xctest")
            || process.processName.contains("swiftpm-testing") || process.environment["XCTestConfigurationFilePath"] != nil
        if isTesting {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("voxcarrel-test-backups-\(UUID().uuidString)", isDirectory: true)
        }
        return FileAudibleKeyStore.standardURL.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true)
    }()

    /// Whether this library is backed up: one that is open and is not the demo.
    public var keepsBackups: Bool { isLibraryOpen && !isShowingDemoLibrary }

    /// What Settings says of the backups: the newest, or that there is none.
    public var backupStatusText: String {
        if isShowingDemoLibrary { return BackupText.demo }
        return backups.first.map(BackupText.last) ?? BackupText.none
    }

    public var canBackUp: Bool { keepsBackups && busyLabel == nil }

    /// Whether a restore can be begun: nothing is running, no sheet is up, and no edit
    /// is waiting to be saved.
    public var canRestoreBackup: Bool {
        keepsBackups && !backups.isEmpty && canShowExtensionSheet && !hasUnsavedChanges
    }

    /// Reads the list of backups again.
    func readBackups() async {
        guard keepsBackups, let worker else {
            backups = []
            return
        }
        let folder = backupsFolder
        backups = ((try? await worker.backups(in: folder)) ?? []).map(BackupText.line)
    }

    /// The day's backup, when it has not been made: quietly, as the library opens.
    /// One that cannot be made says nothing here; Settings shows that there is none.
    func backUpIfDue() async {
        guard keepsBackups, let worker else { return }
        let folder = backupsFolder
        _ = try? await worker.backUpIfDue(in: folder)
        await readBackups()
    }

    /// A backup before something that moves much at once. Quiet, like the day's own.
    func backUpBefore(_ reason: String, with worker: LibraryWorker) async {
        guard !isShowingDemoLibrary else { return }
        let folder = backupsFolder
        _ = try? await worker.backUp(in: folder, reason: reason)
    }

    /// Makes a backup now. One that cannot be made says why in `alert`.
    public func backUpNow() async {
        guard canBackUp else { return }
        let folder = backupsFolder
        await perform(BackupText.workingLabel) { worker in
            try await worker.backUp(in: folder)
        }
        await readBackups()
    }

    /// Shows the folder this library's backups are in.
    public func revealBackups() {
        guard keepsBackups, let worker else { return }
        let folder = backupsFolder
        Task {
            if let own = try? await worker.backupsFolder(in: folder) { opener.reveal([own]) }
        }
    }

    /// Puts the catalogue back as the backup with this id has it, and opens the library
    /// again. The catalogue as it is now is kept as a backup first. A backup that
    /// cannot be restored says why in `alert`, and the library is opened as it was.
    public func restoreBackup(_ id: String) async {
        guard canRestoreBackup, let line = backups.first(where: { $0.id == id }), case .available(let root) = status
        else { return }
        let all = backupsFolder
        // The worker is not kept hold of here: nothing may hold the catalogue below.
        guard let own = try? await self.worker?.backupsFolder(in: all) else { return }
        busyLabel = BackupText.restoringLabel
        // Nothing may hold the catalogue while it is replaced.
        self.worker = nil
        var failure: Error?
        do {
            try await Task.detached {
                try CatalogueBackups.restore(own.appendingPathComponent(id), toLibraryAt: root, backups: own)
            }.value
        } catch {
            failure = error
        }
        busyLabel = nil
        await openLibrary()
        if let failure {
            alert = failure as? CatalogueBackupError == .anotherLibrary
                ? "That backup is of another library, so it was not restored."
                : "The backup could not be restored. \(UserMessage.text(for: failure))"
        } else {
            alert = BackupText.restored(line)
        }
    }
}

import Foundation
import Testing
@testable import VoxCarrelCore
import VoxCarrelFixtures

/// The ledger is not to be lost: an entry goes only when its file is known to have
/// gone or changed, never because a listing happened to leave the file out. And a
/// folder that has come to overlap the library is not looked into.
@Suite struct InboxLedgerKeepingTests {
    typealias F = LibraryFixture

    final class Clock {
        var now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        func later(_ seconds: TimeInterval = 11) -> Date {
            now += seconds
            return now
        }
    }

    private func settled(_ f: F, _ clock: Clock) throws -> InboxReport {
        _ = try f.service.checkInbox(now: clock.later())
        return try f.service.checkInbox(now: clock.later())
    }

    private func entries(_ f: F, _ folder: WatchFolder) throws -> [InboxEntryRecord] {
        try f.store.inboxEntries(folderId: folder.id)
    }

    private func identity(_ url: URL) throws -> ListedFile {
        let values = try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return ListedFile(
            url: url, size: Int64(try #require(values.fileSize)),
            modifiedAt: try #require(values.contentModificationDate))
    }

    /// Lists as the real lister does, leaving out files whose name begins "cloud"
    /// while `away` says so: files kept elsewhere and not downloaded.
    private func leaveOutCloudFiles(_ f: F, while away: @escaping () -> Bool) {
        f.service.listWatchFolder = { folder, includePDFs in
            var listing = FolderLister().list(folder, includePDFs: includePDFs)
            if away() { listing.files.removeAll { $0.url.lastPathComponent.hasPrefix("cloud") } }
            return listing
        }
    }

    // MARK: IB34: gone means gone, not merely unlisted

    /// IB14, IB34: a sub-folder that cannot be read for a while is passed over; what
    /// the ledger holds of it is kept, so its files do not arrive when it can be read again.
    @Test func IB34_entriesUnderASubFolderThatCannotBeReadAreKept() throws {
        let f = try F()
        let clock = Clock()
        let fm = FileManager.default
        try touch(f.inbox.appendingPathComponent("Sub/old1.m4b"))
        try touch(f.inbox.appendingPathComponent("Sub/old2.m4b"))
        let added = try f.service.addWatchFolder(f.inbox, now: clock.now)
        let ledger = try entries(f, added)
        #expect(ledger.count == 2)

        let sub = f.inbox.appendingPathComponent("Sub", isDirectory: true)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: sub.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sub.path) }
        #expect(try settled(f, clock).arrivals.isEmpty)
        #expect(try entries(f, added) == ledger)

        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sub.path)
        #expect(try settled(f, clock).arrivals.isEmpty)
        #expect(try entries(f, added) == ledger)
    }

    /// IB12, IB34: a file whose contents the system has put away (so that it is no
    /// longer listed) is still there: its entry is kept, and it does not arrive when
    /// it is downloaded again.
    @Test func IB34_anEntryForAFileNoLongerDownloadedIsKept() throws {
        let f = try F()
        let clock = Clock()
        try touch(f.inbox.appendingPathComponent("cloud.m4b"))
        try touch(f.inbox.appendingPathComponent("here.m4b"))
        let added = try f.service.addWatchFolder(f.inbox, now: clock.now)
        let ledger = try entries(f, added)
        #expect(ledger.count == 2)

        var away = true
        leaveOutCloudFiles(f) { away }
        #expect(try settled(f, clock).arrivals.isEmpty)
        #expect(try entries(f, added) == ledger)

        away = false
        #expect(try settled(f, clock).arrivals.isEmpty)
        #expect(try entries(f, added) == ledger)
    }

    /// IB34, IB40: turning PDFs off stops them being listed, not being remembered: one
    /// that was dismissed is still dismissed afterwards.
    @Test func IB34_aDismissedPDFStaysDismissedWhilePDFsAreOff() throws {
        let f = try F()
        let clock = Clock()
        var added = try f.service.addWatchFolder(f.inbox, now: clock.now)
        added.includesPDFs = true
        try f.service.updateWatchFolder(added)
        _ = try f.makePDF("manual.pdf")
        let arrival = try #require(try settled(f, clock).arrivals.first)
        try f.service.dismissArrivals(ids: [arrival.id])
        #expect(try entries(f, added).map(\.state) == [.dismissed])

        added.includesPDFs = false
        try f.service.updateWatchFolder(added)
        #expect(try settled(f, clock).arrivals.isEmpty)

        #expect(try entries(f, added).map(\.state) == [.dismissed])
    }

    /// IB34: the folder went away between being listed and the ledger being tidied
    /// (a drive unplugged in the middle of a check): nothing is known to be gone.
    @Test func IB34_nothingIsForgottenWhenTheFolderGoesDuringACheck() throws {
        let f = try F()
        let clock = Clock()
        let url = f.base.appendingPathComponent("Drive", isDirectory: true)
        try touch(url.appendingPathComponent("old.m4b"))
        let added = try f.service.addWatchFolder(url, now: clock.now)
        let ledger = try entries(f, added)
        #expect(ledger.count == 1)

        let away = f.base.appendingPathComponent("Away", isDirectory: true)
        f.service.listWatchFolder = { _, _ in
            // Listed in part, and then it is gone.
            try? FileManager.default.moveItem(at: url, to: away)
            return .found([])
        }
        _ = try f.service.checkInbox(now: clock.later())

        #expect(try entries(f, added) == ledger)
    }

    // MARK: IB3, IB40: the baseline holds files that are not downloaded

    /// IB3, IB12: a file that is in the folder when it is added, kept elsewhere and
    /// not downloaded, is part of the baseline: it does not arrive when it is downloaded.
    @Test func IB3_theBaselineHoldsFilesThatAreNotDownloaded() throws {
        let f = try F()
        let clock = Clock()
        let cloud = try touch(f.inbox.appendingPathComponent("Sub/cloud.m4b"))
        try touch(f.inbox.appendingPathComponent("here.m4b"))
        var away = true
        leaveOutCloudFiles(f) { away }
        f.service.listNotDownloaded = { [self] folder, _ in
            [try? identity(folder.appendingPathComponent("Sub/cloud.m4b"))].compactMap { $0 }
        }

        let added = try f.service.addWatchFolder(f.inbox, now: clock.now)

        #expect(try entries(f, added).map(\.path).sorted() == [added.path + "/Sub/cloud.m4b", added.path + "/here.m4b"])
        #expect(try entries(f, added).allSatisfy { $0.state == .baseline })
        #expect(exists(cloud))

        // It is downloaded.
        away = false
        f.service.listNotDownloaded = { _, _ in [] }
        #expect(try settled(f, clock).arrivals.isEmpty)
    }

    /// IB40, IB12: so is a PDF that is not downloaded when PDFs are turned on.
    @Test func IB40_turningPDFsOnRecordsPDFsThatAreNotDownloaded() throws {
        let f = try F()
        let clock = Clock()
        _ = try f.makePDF("cloud.pdf")
        var added = try f.service.addWatchFolder(f.inbox, now: clock.now)
        var away = true
        leaveOutCloudFiles(f) { away }
        var asked: [Bool] = []
        f.service.listNotDownloaded = { [self] folder, includePDFs in
            asked.append(includePDFs)
            return [try? identity(folder.appendingPathComponent("cloud.pdf"))].compactMap { $0 }
        }

        added.includesPDFs = true
        try f.service.updateWatchFolder(added)

        #expect(asked == [true])
        #expect(try entries(f, added).map(\.path) == [added.path + "/cloud.pdf"])
        away = false
        f.service.listNotDownloaded = { _, _ in [] }
        #expect(try settled(f, clock).arrivals.isEmpty)
    }

    // MARK: Names spelled two ways

    /// IB3, IB36: accented names, composed and decomposed, in the baseline and when
    /// dismissed: each file is known again at every later check.
    @Test func IB30_filesWithAccentedNamesAreKnownAgain() throws {
        let f = try F()
        let clock = Clock()
        let composed = "Caf\u{00E9}"
        let decomposed = "Cafe\u{0301}"
        try touch(f.inbox.appendingPathComponent("\(composed) old.m4b"))
        try touch(f.inbox.appendingPathComponent("\(decomposed) Sub/\(decomposed) older.m4b"))
        let added = try f.service.addWatchFolder(f.inbox, now: clock.now)
        #expect(try entries(f, added).count == 2)
        #expect(try settled(f, clock).arrivals.isEmpty)

        try touch(f.inbox.appendingPathComponent("\(decomposed) new.epub"))
        try touch(f.inbox.appendingPathComponent("\(composed) Sub/\(composed) newer.epub"))
        let arrivals = try settled(f, clock).arrivals
        #expect(arrivals.count == 2)
        try f.service.dismissArrivals(ids: arrivals.map(\.id))

        #expect(try settled(f, clock).arrivals.isEmpty)
        #expect(try entries(f, added).map(\.state) == [.baseline, .baseline, .dismissed, .dismissed])
    }

    /// IB2: a folder is the same folder however its name is spelled: composed or
    /// decomposed, in capitals or not.
    @Test func IB2_aFolderSpelledAnotherWayIsTheSameFolder() throws {
        let f = try F()
        let clock = Clock()
        let url = f.base.appendingPathComponent("Caf\u{00E9}", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let added = try f.service.addWatchFolder(url, now: clock.now)

        for spelling in ["Cafe\u{0301}", "CAF\u{00C9}", "cafe\u{0301}/Sub"] {
            let other = f.base.appendingPathComponent(spelling, isDirectory: true)
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
            #expect(throws: WatchFolderProblem.overlaps(existing: added.path)) {
                try f.service.addWatchFolder(other, now: clock.now)
            }
        }
        #expect(try f.service.watchFolders() == [added])
    }

    // MARK: IB2 at every check: a folder that overlaps the library

    /// IB2, IB30: the library has been moved into a watch folder since the folder was
    /// added. Nothing in that folder is offered: the library's own books would be.
    @Test func IB30_aWatchFolderThatHasComeToHoldTheLibraryOffersNothing() throws {
        let f = try F()
        let clock = Clock()
        let around = LibraryLayout.canonicalFolder(f.base)
        _ = try f.store.insertWatchFolder(path: around.path, addedAt: clock.now, baseline: []) { _ in }
        try touch(f.root.appendingPathComponent("Author/Book/book.m4b"))
        try touch(f.base.appendingPathComponent("loose.m4b"))
        var asked = 0
        f.service.listWatchFolder = { folder, includePDFs in
            asked += 1
            return FolderLister().list(folder, includePDFs: includePDFs)
        }

        let report = try settled(f, clock)

        #expect(report.arrivals.isEmpty)
        #expect(!report.hasUnsettled)
        #expect(asked == 0)
        #expect(report.folders.map(\.folder.path) == [around.path])
    }

    /// IB2, IB30: nor is anything offered from a watch folder that is now inside the
    /// library, or is the library; and what the ledger holds for it is kept.
    @Test func IB30_aWatchFolderNowInsideTheLibraryOffersNothingAndKeepsItsLedger() throws {
        let f = try F()
        let clock = Clock()
        let inside = f.root.appendingPathComponent("Incoming", isDirectory: true)
        try touch(inside.appendingPathComponent("book.m4b"))
        let root = LibraryLayout.canonicalFolder(f.root)
        let folder = try f.store.insertWatchFolder(
            path: LibraryLayout.canonicalFolder(inside).path, addedAt: clock.now,
            baseline: [ListedFile(url: inside.appendingPathComponent("never.m4b"), size: 1, modifiedAt: clock.now)]
        ) { _ in }

        #expect(try settled(f, clock).arrivals.isEmpty)
        #expect(try entries(f, folder).count == 1)

        try f.service.removeWatchFolder(id: folder.id)
        _ = try f.store.insertWatchFolder(path: root.path, addedAt: clock.now, baseline: []) { _ in }
        #expect(try settled(f, clock).arrivals.isEmpty)
    }

    // MARK: IB30: slow disks and files still being copied

    /// IB20, IB30: a book on a network disk arrives after sixty seconds unchanged, not
    /// ten; and one the Finder is still copying does not arrive at all.
    @Test func IB30_aBookOnANetworkDiskOrStillBeingCopiedWaits() throws {
        let f = try F()
        let clock = Clock()
        let added = try f.service.addWatchFolder(f.inbox, now: clock.now)
        try touch(f.inbox.appendingPathComponent("far.m4b"))
        try touch(f.inbox.appendingPathComponent("Copying/part.m4b"))
        var copying = true
        f.service.listWatchFolder = { folder, includePDFs in
            var listing = FolderLister().list(folder, includePDFs: includePDFs)
            for index in listing.files.indices {
                if listing.files[index].url.lastPathComponent == "far.m4b" {
                    listing.files[index].isOnLocalVolume = false
                } else {
                    listing.files[index].isBeingWritten = copying
                }
            }
            return listing
        }

        let early = try settled(f, clock)
        #expect(early.arrivals.isEmpty)
        #expect(early.hasUnsettled)

        _ = try f.service.checkInbox(now: clock.later(30))
        let late = try f.service.checkInbox(now: clock.later(30))
        #expect(late.arrivals.map(\.id) == [added.path + "/far.m4b"])
        #expect(late.hasUnsettled)

        copying = false
        #expect(try settled(f, clock).arrivals.count == 2)
    }
}

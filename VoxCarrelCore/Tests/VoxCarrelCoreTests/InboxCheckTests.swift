import Foundation
import GRDB
import Testing
@testable import VoxCarrelCore
import VoxCarrelFixtures

/// Checking the inbox (rules IB30–IB42). The fixture's `inbox` folder is the watch
/// folder in most tests, so the fixture's own file makers drop books into it.
@Suite struct InboxCheckTests {
    typealias F = LibraryFixture

    /// The time, moved on by hand: no test waits.
    final class Clock {
        var now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        func later(_ seconds: TimeInterval = 11) -> Date {
            now += seconds
            return now
        }
    }

    /// Two checks a settle interval apart; what the second reports.
    private func settled(_ f: F, _ clock: Clock) throws -> InboxReport {
        _ = try f.service.checkInbox(now: clock.later())
        return try f.service.checkInbox(now: clock.later())
    }

    private func watch(_ f: F, _ clock: Clock, _ url: URL? = nil) throws -> WatchFolder {
        try f.service.addWatchFolder(url ?? f.inbox, now: clock.now)
    }

    private func folder(_ f: F, _ name: String) throws -> URL {
        let url = f.base.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func entries(_ f: F, _ folder: WatchFolder) throws -> [InboxEntryRecord] {
        try f.store.inboxEntries(folderId: folder.id)
    }

    private func setModified(_ url: URL, _ seconds: TimeInterval) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceReferenceDate: seconds)], ofItemAtPath: url.path)
    }

    private func identity(_ url: URL) throws -> ListedFile {
        let values = try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return ListedFile(
            url: url, size: Int64(try #require(values.fileSize)),
            modifiedAt: try #require(values.contentModificationDate))
    }

    /// A candidate as text, for comparing two ways of arriving at it.
    /// The system may spell a temporary folder with or without `/private` in front;
    /// that difference is left out.
    private func shape(_ c: CandidateBook) -> String {
        func path(_ url: URL) -> String {
            url.path.hasPrefix("/private/") ? String(url.path.dropFirst("/private".count)) : url.path
        }
        let files = c.files.map { "\(path($0.url))=\($0.role)" }.joined(separator: ",")
        return "\(files)|\(c.metadata.title)|\(c.metadata.authors)|\(c.sourceFolder.map(path) ?? "-")"
    }

    /// Counts the tag reads the check makes.
    private func countReads(_ f: F) -> () -> [String] {
        final class Box { var paths: [String] = [] }
        let box = Box()
        let io = FileMetadataIO()
        f.service.readInboxTags = { url in
            box.paths.append(url.lastPathComponent)
            return try io.readMetadata(at: url)
        }
        return { box.paths }
    }

    // MARK: The whole story

    @Test func IB30_theWholeStory() throws {
        let f = try F()
        let clock = Clock()
        let old = try f.makeM4B("old.m4b", tags: F.meta("Old Book", "Old Author"))
        let added = try watch(f, clock)

        // What was there is not queued, however long we look.
        #expect(try settled(f, clock).arrivals.isEmpty)

        // A book is dropped: nothing at the first look, one arrival once it has settled.
        let spy = try f.makeM4B("spy.m4b", tags: F.meta("A Perfect Spy", "John le Carré"))
        let first = try f.service.checkInbox(now: clock.later())
        #expect(first.arrivals.isEmpty)
        #expect(first.hasUnsettled)
        let second = try f.service.checkInbox(now: clock.later())
        #expect(!second.hasUnsettled)
        let arrival = try #require(second.arrivals.first)
        #expect(second.arrivals.count == 1)
        #expect(arrival.id == added.path + "/spy.m4b")
        #expect(arrival.folderId == added.id)
        #expect(arrival.files.map(\.path) == [added.path + "/spy.m4b"])
        #expect(arrival.candidate.metadata.title == "A Perfect Spy")
        #expect(arrival.candidate.metadata.authors == ["John le Carré"])
        #expect(arrival.candidate.files.map(\.role) == [.audio])
        #expect(arrival.arrivedAt == (try identity(spy)).modifiedAt)
        #expect(second.folders == [WatchFolderStatus(folder: added, availability: .available)])

        // Still there at the next look.
        #expect(try f.service.checkInbox(now: clock.later()).arrivals == [arrival])

        // Dismissed: gone, and stays gone.
        try f.service.dismissArrivals(ids: [arrival.id])
        #expect(try f.service.checkInbox(now: clock.later()).arrivals.isEmpty)
        #expect(try settled(f, clock).arrivals.isEmpty)

        // The file changes: it is another file, and comes back once settled.
        try setModified(spy, 700_000_000)
        #expect(try f.service.checkInbox(now: clock.later()).arrivals.isEmpty)
        let back = try f.service.checkInbox(now: clock.later())
        #expect(back.arrivals.map(\.id) == [arrival.id])

        // Nothing was moved or changed on the way.
        #expect(f.inboxTree() == ["old.m4b", "spy.m4b"])
        #expect(exists(old))
    }

    // MARK: IB30

    @Test func IB30_arrivalsAreGroupedAsTheScannerGroupsADrop() throws {
        let f = try F()
        let clock = Clock()
        let added = try watch(f, clock)
        _ = try f.makeM4B("Solo.m4b", tags: F.meta("Solo", "Han"))
        _ = try f.makeEPUB("Solo.epub")
        _ = try f.makeMP3Parts(folder: "Parts Book", tags: F.meta("In Parts", "Part Author"), count: 3)
        _ = try f.makeM4B("Pair/Thing.m4b", tags: F.meta("Thing", "Someone"))
        _ = try f.makeEPUB("Pair/Other.epub")
        _ = try f.makeEPUB("Deep/Deeper/loose.epub")

        let report = try settled(f, clock)

        let dropped = try FileManager.default.contentsOfDirectory(at: added.url, includingPropertiesForKeys: nil)
            .sorted { $0.path < $1.path }
        let expected = f.service.scan(dropped).candidates
        #expect(expected.count == 4)
        #expect(report.arrivals.map { shape($0.candidate) }.sorted() == expected.map(shape).sorted())
        // Each group is one arrival, named by its first file, holding the group's files.
        for arrival in report.arrivals {
            #expect(arrival.id == arrival.candidate.files[0].url.path)
            #expect(arrival.files == arrival.candidate.files.map(\.url))
            #expect(arrival.folderId == added.id)
        }
        let parts = try #require(report.arrivals.first { $0.candidate.sourceFolder != nil })
        #expect(parts.files.map(\.lastPathComponent) == ["part1.mp3", "part2.mp3", "part3.mp3"])
        #expect(parts.candidate.metadata.title == "In Parts")
    }

    /// Loose audio files at the top of a watch folder are books of their own, whatever
    /// the folder is called: they are grouped as files dropped together, not as a folder of parts.
    @Test func IB30_looseFilesAtTheTopAreNotOneBook() throws {
        let f = try F()
        let clock = Clock()
        _ = try watch(f, clock)
        _ = try f.makeMP3("one.mp3", tags: F.meta("One", "A"))
        _ = try f.makeMP3("two.mp3", tags: F.meta("Two", "B"))

        let report = try settled(f, clock)

        #expect(report.arrivals.map(\.candidate.metadata.title).sorted() == ["One", "Two"])
        #expect(report.arrivals.allSatisfy { $0.candidate.sourceFolder == nil })
    }

    @Test func IB30_aBookInPartsArrivesWholeOnceEveryPartHasSettled() throws {
        let f = try F()
        let clock = Clock()
        _ = try watch(f, clock)
        let parts = try f.makeMP3Parts(folder: "Book", tags: F.meta("In Parts", "Part Author"), count: 3)
        _ = try f.service.checkInbox(now: clock.later())

        // The last part is still being written.
        try setModified(parts[2], 700_000_000)
        let early = try f.service.checkInbox(now: clock.later())
        #expect(early.arrivals.isEmpty)
        #expect(early.hasUnsettled)

        let report = try f.service.checkInbox(now: clock.later())
        #expect(report.arrivals.count == 1)
        #expect(report.arrivals.first?.files.count == 3)
        #expect(!report.hasUnsettled)
    }

    @Test func IB30_eachFolderIsListedWithItsOwnPDFSetting() throws {
        let f = try F()
        let clock = Clock()
        let plain = try watch(f, clock)
        var withPDFs = try watch(f, clock, try folder(f, "Papers"))
        withPDFs.includesPDFs = true
        try f.service.updateWatchFolder(withPDFs)
        var asked: [String: Bool] = [:]
        f.service.listWatchFolder = { folder, includePDFs in
            asked[folder.path] = includePDFs
            return FolderLister().list(folder, includePDFs: includePDFs)
        }

        _ = try f.service.checkInbox(now: clock.later())

        #expect(asked == [plain.path: false, withPDFs.path: true])
    }

    @Test func IB30_arrivalsAreNewestFirstThenById() throws {
        let f = try F()
        let clock = Clock()
        let added = try watch(f, clock)
        for name in ["b.m4b", "a.m4b", "c.m4b", "d.m4b"] {
            try touch(f.inbox.appendingPathComponent(name), name)
        }
        try setModified(f.inbox.appendingPathComponent("a.m4b"), 700_000_100)
        try setModified(f.inbox.appendingPathComponent("b.m4b"), 700_000_100)
        try setModified(f.inbox.appendingPathComponent("c.m4b"), 700_000_300)
        try setModified(f.inbox.appendingPathComponent("d.m4b"), 700_000_000)

        let report = try settled(f, clock)

        #expect(report.arrivals.map(\.id) == ["c.m4b", "a.m4b", "b.m4b", "d.m4b"].map { added.path + "/" + $0 })
        #expect(report.arrivals.first?.arrivedAt == Date(timeIntervalSinceReferenceDate: 700_000_300))
    }

    /// An arrival's date is the latest among its files.
    @Test func IB30_anArrivalIsDatedByItsNewestFile() throws {
        let f = try F()
        let clock = Clock()
        _ = try watch(f, clock)
        let parts = try f.makeMP3Parts(folder: "Book", tags: F.meta("In Parts", "Part Author"), count: 3)
        try setModified(parts[0], 700_000_100)
        try setModified(parts[1], 700_000_900)
        try setModified(parts[2], 700_000_500)

        let report = try settled(f, clock)

        #expect(report.arrivals.map(\.arrivedAt) == [Date(timeIntervalSinceReferenceDate: 700_000_900)])
    }

    @Test func IB30_withNoWatchFoldersTheReportIsEmpty() throws {
        let f = try F()
        let report = try f.service.checkInbox(now: Clock().now)
        #expect(report == InboxReport(arrivals: [], folders: [], hasUnsettled: false))
    }

    /// The scanner's own part in it: only the files it is given count, and a file
    /// that is not under the folder is passed over.
    @Test func IB30_theScannerGroupsOnlyTheFilesItIsGiven() throws {
        let f = try F()
        let parts = try f.makeMP3Parts(folder: "Book", tags: F.meta("In Parts", "Part Author"), count: 3)
        let beside = try f.makeEPUB("Book/extra.epub")
        let outside = try touch(f.base.appendingPathComponent("Inbox2/near.m4b"))

        let result = BookScanner(reader: f.io).scan(files: [parts[0], parts[2], outside], under: f.inbox)

        #expect(result.skipped == [outside])
        #expect(result.candidates.count == 1)
        #expect(result.candidates.first?.files.map(\.url) == [parts[0], parts[2]])
        #expect(result.candidates.first?.sourceFolder?.path == f.inbox.appendingPathComponent("Book").path)
        #expect(exists(beside))
        #expect(BookScanner().scan(files: [], under: f.inbox) == ScanResult())
    }

    // MARK: IB31

    @Test func IB31_aDisabledFolderIsNotListedAndStillAppears() throws {
        let f = try F()
        let clock = Clock()
        var added = try watch(f, clock)
        let other = try watch(f, clock, try folder(f, "Other"))
        try touch(f.inbox.appendingPathComponent("new.m4b"))
        try touch(other.url.appendingPathComponent("also.m4b"))
        #expect(try settled(f, clock).arrivals.count == 2)

        added.isEnabled = false
        try f.service.updateWatchFolder(added)
        var asked: [String] = []
        f.service.listWatchFolder = { folder, includePDFs in
            asked.append(folder.path)
            return FolderLister().list(folder, includePDFs: includePDFs)
        }
        let report = try settled(f, clock)

        #expect(Set(asked) == [other.path])
        #expect(report.arrivals.map(\.id) == [other.path + "/also.m4b"])
        #expect(report.folders.map(\.folder) == [added, other])
        #expect(!report.hasUnsettled)

        // Enabled again, its file settles afresh and arrives.
        added.isEnabled = true
        try f.service.updateWatchFolder(added)
        #expect(try f.service.checkInbox(now: clock.later()).arrivals.count == 1)
        #expect(try f.service.checkInbox(now: clock.later()).arrivals.count == 2)
    }

    // MARK: IB32

    @Test func IB32_aMissingFolderKeepsItsLedgerAndContributesNothing() throws {
        let f = try F()
        let clock = Clock()
        let url = try folder(f, "Drive")
        try touch(url.appendingPathComponent("old.m4b"))
        let added = try watch(f, clock, url)
        try touch(url.appendingPathComponent("no.m4b"))
        let arrival = try #require(try settled(f, clock).arrivals.first)
        try f.service.dismissArrivals(ids: [arrival.id])
        let ledger = try entries(f, added)
        #expect(ledger.map(\.state) == [.baseline, .dismissed])

        // The drive is unplugged.
        let away = f.base.appendingPathComponent("Away", isDirectory: true)
        try FileManager.default.moveItem(at: url, to: away)
        let report = try settled(f, clock)
        #expect(report.arrivals.isEmpty)
        #expect(report.folders == [WatchFolderStatus(folder: added, availability: .missing)])
        #expect(!report.hasUnsettled)
        #expect(try entries(f, added) == ledger)

        // And plugged in again: what was hidden still is.
        try FileManager.default.moveItem(at: away, to: url)
        let returned = try settled(f, clock)
        #expect(returned.arrivals.isEmpty)
        #expect(returned.folders.map(\.availability) == [.available])
        #expect(try entries(f, added) == ledger)
    }

    @Test func IB32_aFolderThatMayNotBeReadKeepsItsLedgerAndContributesNothing() throws {
        let f = try F()
        let clock = Clock()
        try touch(f.inbox.appendingPathComponent("old.m4b"))
        let added = try watch(f, clock)
        let other = try watch(f, clock, try folder(f, "Other"))
        try touch(other.url.appendingPathComponent("new.m4b"))
        let ledger = try entries(f, added)
        #expect(ledger.count == 1)
        f.service.listWatchFolder = { folder, includePDFs in
            folder.path == added.path
                ? FolderListing(availability: .notAllowed, files: [])
                : FolderLister().list(folder, includePDFs: includePDFs)
        }

        let report = try settled(f, clock)

        #expect(report.folders == [
            WatchFolderStatus(folder: added, availability: .notAllowed),
            WatchFolderStatus(folder: other, availability: .available),
        ])
        // The folder beside it is checked as ever.
        #expect(report.arrivals.map(\.id) == [other.path + "/new.m4b"])
        #expect(try entries(f, added) == ledger)
    }

    // MARK: IB33

    @Test func IB33_anEntryForAnotherStateOfTheFileDoesNotHideItAndIsDeleted() throws {
        let f = try F()
        let clock = Clock()
        let bySize = try touch(f.inbox.appendingPathComponent("size.m4b"), "short")
        let byDate = try touch(f.inbox.appendingPathComponent("date.m4b"), "same")
        try touch(f.inbox.appendingPathComponent("kept.m4b"), "kept")
        let added = try watch(f, clock)
        #expect(try entries(f, added).count == 3)

        try setModified(bySize, 700_000_000)
        try setModified(byDate, 700_000_000)
        try touch(bySize, "rather longer")
        try setModified(bySize, 700_000_000)
        let afterOne = try f.service.checkInbox(now: clock.later())

        // The stale entries go at once; the files arrive when they have settled.
        #expect(afterOne.arrivals.isEmpty)
        #expect(try entries(f, added).map(\.path) == [added.path + "/kept.m4b"])
        let report = try f.service.checkInbox(now: clock.later())
        #expect(report.arrivals.map(\.id).sorted() == [added.path + "/date.m4b", added.path + "/size.m4b"])
    }

    // MARK: IB34

    @Test func IB34_entriesForFilesThatAreGoneAreDeleted() throws {
        let f = try F()
        let clock = Clock()
        let gone = try touch(f.inbox.appendingPathComponent("Sub/gone.m4b"))
        try touch(f.inbox.appendingPathComponent("stays.m4b"))
        let added = try watch(f, clock)
        let other = try watch(f, clock, try folder(f, "Other"))
        try f.store.recordInboxEntries(
            [ListedFile(url: other.url.appendingPathComponent("never.m4b"), size: 1, modifiedAt: clock.now)],
            state: .imported, folderId: other.id)
        #expect(try entries(f, added).count == 2)

        try FileManager.default.removeItem(at: gone)
        _ = try f.service.checkInbox(now: clock.later())

        #expect(try entries(f, added).map(\.path) == [added.path + "/stays.m4b"])
        #expect(try entries(f, other).isEmpty)

        // A file of the same name that turns up later is new.
        try touch(gone)
        #expect(try settled(f, clock).arrivals.map(\.id) == [added.path + "/Sub/gone.m4b"])
    }

    /// A disabled folder is not looked at, so nothing is known to be gone from it.
    @Test func IB34_aDisabledFoldersEntriesAreLeftAlone() throws {
        let f = try F()
        let clock = Clock()
        let gone = try touch(f.inbox.appendingPathComponent("gone.m4b"))
        var added = try watch(f, clock)
        added.isEnabled = false
        try f.service.updateWatchFolder(added)
        try FileManager.default.removeItem(at: gone)

        _ = try settled(f, clock)

        #expect(try entries(f, added).count == 1)
    }

    // MARK: IB35

    @Test func IB35_tagsAreReadOncePerFileIdentity() throws {
        let f = try F()
        let clock = Clock()
        _ = try watch(f, clock)
        let reads = countReads(f)
        let spy = try f.makeM4B("spy.m4b", tags: F.meta("A Perfect Spy", "John le Carré"))
        _ = try f.makeMP3Parts(folder: "Book", tags: F.meta("In Parts", "Part Author"), count: 3)
        try touch(f.inbox.appendingPathComponent("broken.m4b"), "not audio")

        let first = try settled(f, clock)
        #expect(first.arrivals.count == 3)
        // One read for each book: of its audio file, or the first of its parts.
        #expect(reads().sorted() == ["broken.m4b", "part1.mp3", "spy.m4b"])

        // Nothing changed: nothing is read, the file that could not be read included.
        let again = try settled(f, clock)
        #expect(again.arrivals == first.arrivals)
        #expect(reads().count == 3)

        // One file changes: that one is read again, once.
        try f.io.write(F.meta("A Legacy of Spies", "John le Carré"), to: spy)
        let changed = try settled(f, clock)
        #expect(reads().sorted() == ["broken.m4b", "part1.mp3", "spy.m4b", "spy.m4b"])
        #expect(changed.arrivals.map(\.candidate.metadata.title).sorted() == ["A Legacy of Spies", "In Parts", "broken"])
        _ = try settled(f, clock)
        #expect(reads().count == 4)
    }

    @Test func IB35_whatIsCachedForAFileNoLongerListedIsDropped() throws {
        let f = try F()
        let clock = Clock()
        _ = try watch(f, clock)
        let reads = countReads(f)
        let spy = try f.makeM4B("spy.m4b", tags: F.meta("A Perfect Spy", "John le Carré"))
        let was = try identity(spy)
        _ = try settled(f, clock)
        #expect(reads() == ["spy.m4b"])

        // Taken away for one look, then back exactly as it was.
        let aside = f.base.appendingPathComponent("aside.m4b")
        try FileManager.default.moveItem(at: spy, to: aside)
        #expect(try f.service.checkInbox(now: clock.later()).arrivals.isEmpty)
        #expect(f.service.inboxTags.isEmpty)
        try FileManager.default.moveItem(at: aside, to: spy)
        #expect(try identity(spy) == was)

        #expect(try settled(f, clock).arrivals.count == 1)
        #expect(reads() == ["spy.m4b", "spy.m4b"])
    }

    // MARK: IB36

    @Test func IB36_dismissedArrivalsAreRecordedAndDoNotReturn() throws {
        let f = try F()
        let clock = Clock()
        let added = try watch(f, clock)
        let parts = try f.makeMP3Parts(folder: "Book", tags: F.meta("In Parts", "Part Author"), count: 2)
        _ = try f.makeM4B("keep.m4b", tags: F.meta("Kept", "Someone"))
        let report = try settled(f, clock)
        let book = try #require(report.arrivals.first { $0.files.count == 2 })
        let kept = try #require(report.arrivals.first { $0.files.count == 1 })

        // The files are recorded as they are when dismissed, not as they were when listed.
        try setModified(parts[1], 700_000_000)
        try f.service.dismissArrivals(ids: [book.id, "/no/such/arrival"])

        let ledger = try entries(f, added)
        #expect(ledger.map(\.path) == [added.path + "/Book/part1.mp3", added.path + "/Book/part2.mp3"])
        #expect(ledger.allSatisfy { $0.state == .dismissed })
        #expect(ledger.map(\.size) == (try parts.map { try identity($0).size }))
        #expect(ledger.map(\.modifiedAt) == (try parts.map { try identity($0).modifiedAt }))
        #expect(try f.service.checkInbox(now: clock.later()).arrivals == [kept])
        #expect(try settled(f, clock).arrivals == [kept])
        #expect(f.inboxTree() == ["Book", "Book/part1.mp3", "Book/part2.mp3", "keep.m4b"])
    }

    @Test func IB36_dismissingTwiceOrWithNothingKnownDoesNothingMore() throws {
        let f = try F()
        let clock = Clock()
        let added = try watch(f, clock)
        // Before any check there are no arrivals to dismiss.
        try f.service.dismissArrivals(ids: [added.path + "/a.m4b"])
        try f.service.dismissArrivals(ids: [])
        #expect(try entries(f, added).isEmpty)

        let file = try touch(f.inbox.appendingPathComponent("a.m4b"))
        let arrival = try #require(try settled(f, clock).arrivals.first)
        try f.service.dismissArrivals(ids: [arrival.id])
        try setModified(file, 700_000_000)
        try f.service.dismissArrivals(ids: [arrival.id, arrival.id])

        // One entry, for the file as it last was.
        let ledger = try entries(f, added)
        #expect(ledger.count == 1)
        #expect(ledger.first?.modifiedAt == Date(timeIntervalSinceReferenceDate: 700_000_000))
        #expect(try settled(f, clock).arrivals.isEmpty)
    }

    /// A file of a dismissed arrival that has gone is passed over.
    @Test func IB36_aFileThatHasGoneIsNotRecorded() throws {
        let f = try F()
        let clock = Clock()
        let added = try watch(f, clock)
        let parts = try f.makeMP3Parts(folder: "Book", tags: F.meta("In Parts", "Part Author"), count: 2)
        let arrival = try #require(try settled(f, clock).arrivals.first)
        try FileManager.default.removeItem(at: parts[0])

        try f.service.dismissArrivals(ids: [arrival.id])

        #expect(try entries(f, added).map(\.path) == [added.path + "/Book/part2.mp3"])
    }

    // MARK: IB37

    @Test func IB37_importedFilesThatRemainAreRecordedAndDoNotReturn() throws {
        let f = try F()
        let clock = Clock()
        let added = try watch(f, clock)
        var disabled = try watch(f, clock, try folder(f, "Off"))
        disabled.isEnabled = false
        try f.service.updateWatchFolder(disabled)
        try touch(f.inbox.appendingPathComponent("copied.m4b"))
        try touch(f.inbox.appendingPathComponent("Sub/also.epub"))
        try touch(f.inbox.appendingPathComponent("other.m4b"))
        let inOff = try touch(disabled.url.appendingPathComponent("off.m4b"))
        let outside = try touch(f.base.appendingPathComponent("Elsewhere/out.m4b"))
        let nearMiss = try touch(f.base.appendingPathComponent("Inbox2/near.m4b"))
        let arrivals = try settled(f, clock).arrivals
        #expect(arrivals.count == 3)
        let copied = try #require(arrivals.first { $0.id.hasSuffix("copied.m4b") })
        let also = try #require(arrivals.first { $0.id.hasSuffix("also.epub") })

        try f.service.recordImported(
            copied.files + also.files + [
                inOff, outside, nearMiss,
                added.url.appendingPathComponent("moved-away.m4b"),
                f.base.appendingPathComponent("nowhere/at/all.m4b"),
                added.url,
            ])

        let ledger = try entries(f, added)
        #expect(ledger.map(\.path) == [added.path + "/copied.m4b", added.path + "/Sub/also.epub"])
        #expect(ledger.allSatisfy { $0.state == .imported })
        #expect(ledger.first?.modifiedAt == (try identity(copied.files[0])).modifiedAt)
        #expect(ledger.first?.size == 1)
        // Any watch folder counts, watched just now or not.
        #expect(try entries(f, disabled).map(\.path) == [disabled.path + "/off.m4b"])
        #expect(try f.service.checkInbox(now: clock.later()).arrivals.map(\.id) == [added.path + "/other.m4b"])
        #expect(try settled(f, clock).arrivals.map(\.id) == [added.path + "/other.m4b"])
    }

    /// Recorded under the folder's own spelling of the path, however the file was named,
    /// and over any entry the file already had.
    @Test func IB37_aFileNamedAnotherWayOrAlreadyInTheLedgerIsStillRecorded() throws {
        let f = try F()
        let clock = Clock()
        let file = try touch(f.inbox.appendingPathComponent("Sub/a.m4b"))
        let added = try watch(f, clock)
        #expect(try entries(f, added).map(\.state) == [.baseline])
        try setModified(file, 700_000_000)
        let roundabout = URL(fileURLWithPath: f.inbox.path + "/Sub/../Sub/a.m4b")

        try f.service.recordImported([roundabout, file])

        let ledger = try entries(f, added)
        #expect(ledger.map(\.path) == [added.path + "/Sub/a.m4b"])
        #expect(ledger.map(\.state) == [.imported])
        #expect(ledger.map(\.modifiedAt) == [Date(timeIntervalSinceReferenceDate: 700_000_000)])
        #expect(try settled(f, clock).arrivals.isEmpty)
    }

    @Test func IB37_withNoWatchFoldersNothingIsRecorded() throws {
        let f = try F()
        try f.service.recordImported([try touch(f.inbox.appendingPathComponent("a.m4b"))])
        try f.service.recordImported([])
        let count = try f.store.dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM inboxEntry") }
        #expect(count == 0)
    }

    // MARK: IB38

    /// The scanner skips what is not a plain file when it comes to look. Here the
    /// listing names a file that is not there, which only a listing that has gone
    /// stale between the two looks can do.
    @Test func IB38_aFileTheScannerSkipsIsNotAnArrivalAndIsNotTriedAgain() throws {
        let f = try F()
        let clock = Clock()
        let added = try watch(f, clock)
        try touch(f.inbox.appendingPathComponent("fine.m4b"))
        let ghost = added.url.appendingPathComponent("ghost.m4b")
        var ghostListed = ListedFile(url: ghost, size: 5, modifiedAt: Date(timeIntervalSinceReferenceDate: 700_000_000))
        f.service.listWatchFolder = { folder, includePDFs in
            var listing = FolderLister().list(folder, includePDFs: includePDFs)
            listing.files.removeAll { $0.url.path == ghost.path }
            listing.files.append(ghostListed)
            listing.files.sort { $0.url.path < $1.url.path }
            return listing
        }

        let report = try settled(f, clock)
        #expect(report.arrivals.map(\.id) == [added.path + "/fine.m4b"])
        #expect(!report.hasUnsettled)

        // The file is there now, and the listing says nothing has changed: not tried again.
        try touch(ghost, "ghost")
        #expect(try settled(f, clock).arrivals.map(\.id) == [added.path + "/fine.m4b"])

        // Its identity changes: it is looked at again, and arrives.
        ghostListed.modifiedAt = Date(timeIntervalSinceReferenceDate: 700_000_500)
        #expect(try settled(f, clock).arrivals.map(\.id) == [added.path + "/fine.m4b", added.path + "/ghost.m4b"])
    }

    /// A file whose tags cannot be read is a candidate all the same, named from its
    /// file name: that is what the scanner makes of it at import too.
    @Test func IB38_aFileWhoseTagsCannotBeReadArrivesNamedFromItsFile() throws {
        let f = try F()
        let clock = Clock()
        _ = try watch(f, clock)
        try touch(f.inbox.appendingPathComponent("Some Author - Some Book.m4b"), "not audio")

        let report = try settled(f, clock)

        #expect(report.arrivals.count == 1)
        #expect(report.arrivals.first?.candidate.metadata.title.isEmpty == false)
    }

    // MARK: IB39

    @Test func IB39_anArrivalsFilesAllBelongToOneWatchFolder() throws {
        let f = try F()
        let clock = Clock()
        let audio = try watch(f, clock)
        let ebooks = try watch(f, clock, try folder(f, "Ebooks In"))
        // The same book in both: dropped together the scanner would make one book of them.
        _ = try f.makeM4B("book.m4b", tags: F.meta("Original Title", "First Author"))
        let epub = try MediaFixtures.makeEPUB3(in: ebooks.url, name: "book.epub")
        let together = f.service.scan([audio.url.appendingPathComponent("book.m4b"), epub]).candidates
        #expect(together.count == 1)

        let report = try settled(f, clock)

        #expect(report.arrivals.count == 2)
        #expect(Set(report.arrivals.map(\.folderId)) == [audio.id, ebooks.id])
        for arrival in report.arrivals {
            let home = arrival.folderId == audio.id ? audio : ebooks
            #expect(arrival.files.allSatisfy { $0.path.hasPrefix(home.path + "/") })
        }
    }

    @Test func IB39_anArrivalKeepsItsIdWhileItsFirstFileStaysPut() throws {
        let f = try F()
        let clock = Clock()
        let added = try watch(f, clock)
        let parts = try f.makeMP3Parts(folder: "Book", tags: F.meta("In Parts", "Part Author"), count: 2)
        let first = try settled(f, clock).arrivals
        #expect(first.map(\.id) == [added.path + "/Book/part1.mp3"])

        // Another part arrives and a tag changes: the same arrival, grown.
        _ = try f.makeMP3("Book/part3.mp3", tags: F.meta("In Parts", "Part Author"))
        try f.io.write(F.meta("Renamed", "Part Author"), to: parts[0])
        let second = try settled(f, clock).arrivals

        #expect(second.map(\.id) == first.map(\.id))
        #expect(second.first?.files.count == 3)
        #expect(second.first?.candidate.metadata.title == "Renamed")
    }

    // MARK: IB40

    @Test func IB40_turningPDFsOnRecordsThePDFsThereAsBaseline() throws {
        let f = try F()
        let clock = Clock()
        _ = try f.makePDF("old.pdf")
        _ = try f.makePDF("Sub/older.pdf")
        var added = try watch(f, clock)
        #expect(try entries(f, added).isEmpty)
        #expect(try settled(f, clock).arrivals.isEmpty)

        added.includesPDFs = true
        try f.service.updateWatchFolder(added)

        let ledger = try entries(f, added)
        #expect(ledger.map(\.path).sorted() == [added.path + "/Sub/older.pdf", added.path + "/old.pdf"])
        #expect(ledger.allSatisfy { $0.state == .baseline })
        #expect(try settled(f, clock).arrivals.isEmpty)

        // A PDF added afterwards arrives.
        _ = try f.makePDF("new.pdf")
        #expect(try settled(f, clock).arrivals.map(\.id) == [added.path + "/new.pdf"])
        #expect(try entries(f, added) == ledger)
    }

    /// Only the change from off to on records anything, and only PDFs.
    @Test func IB40_otherChangesRecordNothing() throws {
        let f = try F()
        let clock = Clock()
        var added = try watch(f, clock)
        added.includesPDFs = true
        try f.service.updateWatchFolder(added)
        _ = try f.makePDF("new.pdf")
        try touch(f.inbox.appendingPathComponent("new.m4b"))

        // PDFs already on: changing something else does not make a baseline of what is there.
        added.mode = .copy
        try f.service.updateWatchFolder(added)
        #expect(try entries(f, added).isEmpty)

        // Off, then on again: the PDF is baseline now, the audiobook is not.
        added.includesPDFs = false
        try f.service.updateWatchFolder(added)
        #expect(try entries(f, added).isEmpty)
        #expect(try settled(f, clock).arrivals.map(\.id) == [added.path + "/new.m4b"])
        added.includesPDFs = true
        try f.service.updateWatchFolder(added)
        #expect(try entries(f, added).map(\.path) == [added.path + "/new.pdf"])
        #expect(try settled(f, clock).arrivals.map(\.id) == [added.path + "/new.m4b"])
    }

    /// A PDF the ledger already knows keeps its entry as it is.
    @Test func IB40_aPDFAlreadyInTheLedgerKeepsItsEntry() throws {
        let f = try F()
        let clock = Clock()
        var added = try watch(f, clock)
        let pdf = try f.makePDF("seen.pdf")
        let was = ListedFile(url: added.url.appendingPathComponent("seen.pdf"), size: 1, modifiedAt: clock.now)
        try f.store.recordInboxEntries([was], state: .dismissed, folderId: added.id)

        added.includesPDFs = true
        try f.service.updateWatchFolder(added)

        let ledger = try entries(f, added)
        #expect(ledger.map(\.state) == [.dismissed])
        #expect(ledger.map(\.size) == [1])
        #expect(exists(pdf))
    }

    @Test func IB40_turningPDFsOnForAnUnknownFolderThrowsAndRecordsNothing() throws {
        let f = try F()
        let clock = Clock()
        _ = try f.makePDF("old.pdf")
        let added = try watch(f, clock)
        var unknown = added
        unknown.id = 999
        unknown.includesPDFs = true

        #expect(throws: WatchFolderError.notFound(999)) { try f.service.updateWatchFolder(unknown) }

        #expect(try entries(f, added).isEmpty)
    }

    // MARK: IB41

    @Test func IB41_checkingJournalsNothingAndLeavesUndoAsItWas() throws {
        let f = try F()
        let clock = Clock()
        let book = try f.makeM4B("Start/spy.m4b", tags: F.meta("A Perfect Spy", "John le Carré"))
        _ = try f.importNew([book], F.meta("A Perfect Spy", "John le Carré"))
        let label = try #require(try f.service.undoLabel())
        let batch = try #require(try f.store.lastBatch())
        let hidden = f.hiddenTree()
        let library = f.libraryTree()
        func expectUntouched(sourceLocation: SourceLocation = #_sourceLocation) throws {
            #expect(try f.service.undoLabel() == label, sourceLocation: sourceLocation)
            #expect(try f.store.lastBatch() == batch, sourceLocation: sourceLocation)
            #expect(f.hiddenTree() == hidden, sourceLocation: sourceLocation)
            #expect(f.libraryTree() == library, sourceLocation: sourceLocation)
        }

        _ = try watch(f, clock)
        _ = try f.makeM4B("one.m4b", tags: F.meta("One", "A"))
        _ = try f.makeM4B("two.m4b", tags: F.meta("Two", "B"))
        let arrivals = try settled(f, clock).arrivals
        #expect(arrivals.count == 2)
        try expectUntouched()
        try f.service.dismissArrivals(ids: [arrivals[0].id])
        try expectUntouched()
        try f.service.recordImported(arrivals[1].files)
        try expectUntouched()
        #expect(try settled(f, clock).arrivals.isEmpty)
        try expectUntouched()
        #expect(try f.store.books().count == 1)
    }

    // MARK: IB42

    @Test func IB42_aCheckOverTwoThousandSettledCachedFilesIsQuick() throws {
        let f = try F()
        let clock = Clock()
        _ = try watch(f, clock)
        let mp3 = MediaFixtures.makeSilentMP3(seconds: 1, id3v23Title: "A Part")
        let fm = FileManager.default
        for book in 0..<10 {
            let dir = f.inbox.appendingPathComponent("Book \(book)", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for part in 0..<100 {
                try mp3.write(to: dir.appendingPathComponent(String(format: "part%03d.mp3", part)))
            }
        }
        for loose in 0..<1000 {
            try mp3.write(to: f.inbox.appendingPathComponent("loose \(loose).mp3"))
        }
        let reads = countReads(f)
        let first = try settled(f, clock)
        #expect(first.arrivals.count == 1010)
        #expect(first.arrivals.reduce(0) { $0 + $1.files.count } == 2000)
        let readsBefore = reads().count
        #expect(readsBefore == 1010)

        let started = Date()
        let report = try f.service.checkInbox(now: clock.later())
        let took = Date().timeIntervalSince(started)

        #expect(report.arrivals == first.arrivals)
        #expect(reads().count == readsBefore)
        #expect(took < 20)
    }
}

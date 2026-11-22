import DemoContent
import Foundation
import Testing
import VoxCarrelCore
import VoxCarrelFixtures

@testable import VoxCarrelAppCore

/// WF10–WF24: watch folders and the Inbox in the model. Nothing here waits: the
/// watcher is fired by hand, the ticker's actions are run by hand, and the time is the
/// harness's clock.
@MainActor
@Suite struct AppModelInboxTests {
    private struct CheckFailed: Error {}

    // MARK: Setting up

    /// A started model on an empty library that watches one new, empty folder.
    private func watching() async throws -> (Harness, URL) {
        let h = try await Harness.empty()
        await h.model.settle()
        let folder = try makeTempDir()
        await h.model.addWatchFolder(folder)
        await h.model.settle()
        return (h, folder)
    }

    /// Puts one of the demo inbox's sample books into `folder`: an ebook of poems by
    /// "Quiet Rivers.epub", a folder of four parts by "Night Train to Vostok".
    @discardableResult
    private func drop(_ name: String, into folder: URL) throws -> URL {
        let to = folder.appendingPathComponent(name)
        try FileManager.default.moveItem(at: try Harness.inbox().appendingPathComponent(name), to: to)
        return to
    }

    private static let ebook = "Quiet Rivers.epub"
    private static let parts = "Night Train to Vostok"

    /// The watcher reports; then a settle interval passes and the second look is taken.
    private func arrive(_ h: Harness) async {
        h.watcher.fire()
        await h.model.settle()
        await later(h)
    }

    /// A settle interval passes, and the check that was scheduled for then is made.
    private func later(_ h: Harness) async {
        h.clock.now += 11
        #expect(h.ticker.run(delay: 11), "no check was scheduled 11 seconds on")
        await h.model.settle()
    }

    /// How many actions the ticker holds with this delay.
    private func pending(_ h: Harness, _ delay: TimeInterval) -> Int {
        h.ticker.pending.filter { $0.delay == delay }.count
    }

    /// The folder as the system itself spells it.
    private func real(_ url: URL) -> String {
        (try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.canonicalPathKey]).canonicalPath) ?? url.path
    }

    private func storedFolders(_ h: Harness) throws -> [WatchFolder] {
        try LibraryService(store: try h.store()).watchFolders()
    }

    private func id(_ h: Harness, _ folder: URL) throws -> Int64 {
        let row = try #require(h.model.watchFolderRows.first { real(URL(fileURLWithPath: $0.path)) == real(folder) })
        return row.id
    }

    private func arrivalId(_ h: Harness, _ title: String) throws -> String {
        try #require(h.model.inboxRows.first { $0.title == title }, "no arrival titled \(title)").id
    }

    // MARK: WF10 Opening and closing

    /// WF10: a library with a watch folder, opened: the folders are loaded, the watcher is started and a
    /// check is made. What arrived while the app was closed is found a settle interval later.
    @Test func openingALibraryLoadsItsFoldersStartsTheWatcherAndChecks() async throws {
        let (h, folder) = try await watching()
        try drop(Self.ebook, into: folder)

        let watcher = FakeFolderWatcher()
        let ticker = FakeTicker()
        let model = h.relaunched(watcher: watcher, ticker: ticker)
        #expect(!model.showsInbox)
        #expect(!watcher.isWatching)

        await model.start()
        await model.settle()
        #expect(model.showsInbox)
        #expect(model.watchFolderRows.count == 1)
        #expect(watcher.folders.map(real) == [real(folder)])
        #expect(model.inboxCheckCount == 1)
        #expect(model.inboxCount == 0)
        // The regular check, and one a settle interval on because a file was seen for the first time.
        #expect(ticker.pending.map(\.delay).sorted() == [11, 60])

        h.clock.now += 11
        ticker.run(delay: 11)
        await model.settle()
        #expect(model.inboxRows.map(\.title) == ["Quiet Rivers"])
    }

    /// WF10: only the folders that are on are watched.
    @Test func openingWatchesOnlyTheEnabledFolders() async throws {
        let (h, first) = try await watching()
        let second = try makeTempDir()
        await h.model.addWatchFolder(second)
        await h.model.setWatchFolder(try id(h, first), enabled: false)
        await h.model.settle()

        let watcher = FakeFolderWatcher()
        let model = h.relaunched(watcher: watcher)
        await model.start()
        await model.settle()
        #expect(model.watchFolderRows.count == 2)
        #expect(watcher.folders.map(real) == [real(second)])
    }

    /// WF10: a library with no watch folders is checked once and then left alone.
    @Test func aLibraryWithNoWatchFoldersWatchesNothing() async throws {
        let h = try await Harness.empty()
        await h.model.settle()
        #expect(!h.model.showsInbox)
        #expect(!h.watcher.isWatching)
        #expect(h.ticker.pending.isEmpty)
        #expect(h.model.inboxCount == 0)
    }

    /// WF10: another library is chosen: nothing of the inbox shown before is left, and nothing is watched.
    @Test func choosingAnotherLibraryStopsTheWatcherAndEmptiesTheInbox() async throws {
        let (h, folder) = try await watching()
        try drop(Self.ebook, into: folder)
        await arrive(h)
        h.model.inboxSelection = [try arrivalId(h, "Quiet Rivers")]
        #expect(h.model.inboxCount == 1)
        #expect(h.watcher.isWatching)
        let cancels = h.ticker.cancelCount

        await h.model.chooseLibrary(try makeTempDir())
        await h.model.settle()
        #expect(h.model.isLibraryOpen)
        #expect(h.model.inboxCount == 0)
        #expect(h.model.inboxRows.isEmpty)
        #expect(h.model.inboxSelection.isEmpty)
        #expect(!h.model.showsInbox)
        #expect(h.model.watchFolderRows.isEmpty)
        #expect(!h.watcher.isWatching)
        #expect(h.watcher.folders.isEmpty)
        #expect(h.ticker.cancelCount > cancels)
        #expect(h.ticker.pending.isEmpty)
    }

    /// WF10: the library goes away (its folder cannot be found): the same.
    @Test func aLibraryThatClosesStopsTheWatcherAndEmptiesTheInbox() async throws {
        let (h, folder) = try await watching()
        try drop(Self.ebook, into: folder)
        await arrive(h)
        #expect(h.model.inboxCount == 1)

        try FileManager.default.removeItem(at: h.root)
        await h.model.retryLibrary()
        await h.model.settle()
        #expect(!h.model.isLibraryOpen)
        #expect(h.model.inboxCount == 0)
        #expect(!h.model.showsInbox)
        #expect(!h.watcher.isWatching)
        #expect(h.ticker.pending.isEmpty)
    }

    /// WF10: the model owns its watcher and its ticker, and neither keeps it alive: when the model goes,
    /// nothing that was watching or waiting holds on to it.
    @Test func theWatcherAndTheTickerDoNotKeepTheModelAlive() async throws {
        let (h, _) = try await watching()
        let watcher = FakeFolderWatcher()
        let ticker = FakeTicker()
        var model: AppModel? = h.relaunched(watcher: watcher, ticker: ticker)
        await model?.start()
        await model?.settle()
        #expect(watcher.isWatching)
        #expect(!ticker.pending.isEmpty)

        weak var gone = model
        model = nil
        #expect(gone == nil)
        // What was left waiting does nothing.
        watcher.fire()
        while ticker.runNext() {}
    }

    // MARK: WF11 When checks run

    /// WF11
    @Test func aWatcherReportRunsACheck() async throws {
        let (h, _) = try await watching()
        let before = h.model.inboxCheckCount
        h.watcher.fire()
        await h.model.settle()
        #expect(h.model.inboxCheckCount == before + 1)
    }

    /// WF11: one check every 60 seconds, each tick scheduling the next and no more than the next.
    @Test func aCheckRunsEverySixtySecondsWhileAFolderIsEnabled() async throws {
        let (h, _) = try await watching()
        #expect(pending(h, 60) == 1)
        for _ in 1...3 {
            let before = h.model.inboxCheckCount
            h.clock.now += 60
            #expect(h.ticker.run(delay: 60))
            await h.model.settle()
            #expect(h.model.inboxCheckCount == before + 1)
            #expect(pending(h, 60) == 1)
        }
        // Whatever else asks for a check, there is still the one tick.
        h.watcher.fire()
        await h.model.addWatchFolder(try makeTempDir())
        await h.model.settle()
        #expect(pending(h, 60) == 1)
    }

    /// WF11: with every folder off, the tick that was waiting checks nothing and is the last.
    @Test func noTickRunsWhileNoFolderIsEnabled() async throws {
        let (h, folder) = try await watching()
        let folderId = try id(h, folder)
        await h.model.setWatchFolder(folderId, enabled: false)
        await h.model.settle()

        let before = h.model.inboxCheckCount
        h.ticker.run(delay: 60)
        await h.model.settle()
        #expect(h.model.inboxCheckCount == before)
        #expect(pending(h, 60) == 0)

        await h.model.setWatchFolder(folderId, enabled: true)
        await h.model.settle()
        #expect(pending(h, 60) == 1)
    }

    /// WF11: files seen for the first time bring one more check 11 seconds on, however many checks see them.
    @Test func unsettledFilesBringOneCheckElevenSecondsLater() async throws {
        let (h, folder) = try await watching()
        #expect(pending(h, 11) == 0)
        try drop(Self.ebook, into: folder)

        h.watcher.fire()
        await h.model.settle()
        #expect(h.model.inboxCount == 0)
        #expect(pending(h, 11) == 1)
        h.clock.now += 1
        h.watcher.fire()
        await h.model.settle()
        #expect(pending(h, 11) == 1)

        await later(h)
        #expect(h.model.inboxCount == 1)
        #expect(pending(h, 11) == 0)
        #expect(pending(h, 60) == 1)
    }

    /// WF11: requests that come while a check runs make one more check when it ends, not one each.
    @Test func checksNeverOverlapAndRequestsDuringOneRunOnceMore() async throws {
        let (h, _) = try await watching()
        let before = h.model.inboxCheckCount
        let gate = Gate()
        h.model.beforeInboxCheck = { await gate.wait() }

        h.watcher.fire()
        await gate.arrival()
        h.watcher.fire()
        h.watcher.fire()
        h.ticker.run(delay: 60)
        #expect(h.model.inboxCheckCount == before + 1)

        await gate.release()
        await h.model.settle()
        #expect(h.model.inboxCheckCount == before + 2)
    }

    // MARK: WF12 Checks and operations

    /// WF12: a check is not an operation: nothing is shown as busy, and importing is not held up.
    @Test func aCheckSetsNoBusyLabelAndBlocksNothing() async throws {
        let (h, _) = try await watching()
        h.recordBusyLabels()
        let gate = Gate()
        h.model.beforeInboxCheck = { await gate.wait() }

        h.watcher.fire()
        await gate.arrival()
        #expect(h.model.busyLabel == nil)
        #expect(h.model.canImport)
        // An import can be begun while the check is on its way.
        let inbox = try Harness.inbox()
        async let importing: Void = h.model.beginImport([inbox.appendingPathComponent(Self.ebook)])
        await gate.release()
        await importing
        await h.model.settle()
        #expect(h.model.review?.entries.count == 1)
        #expect(h.busyLabels == ["Reading files…"])
    }

    /// WF12: while an operation holds the library no check is made; one is made when the operation ends.
    @Test func aCheckAskedForDuringAnOperationRunsWhenItEnds() async throws {
        let (h, _) = try await watching()
        let gate = Gate()
        h.model.beforeOperation = { await gate.wait() }
        let operation = Task { await h.model.undo() }
        await gate.arrival()
        #expect(h.model.busyLabel != nil)

        let before = h.model.inboxCheckCount
        h.watcher.fire()
        h.watcher.fire()
        await h.model.settle()
        #expect(h.model.inboxCheckCount == before)

        await gate.release()
        await operation.value
        await h.model.settle()
        #expect(h.model.busyLabel == nil)
        #expect(h.model.inboxCheckCount == before + 1)
    }

    /// WF12: an operation that ends when no check was asked for brings none.
    @Test func anOperationThatEndsBringsNoCheckOfItsOwn() async throws {
        let (h, _) = try await watching()
        let before = h.model.inboxCheckCount
        await h.model.undo()
        await h.model.settle()
        #expect(h.model.inboxCheckCount == before)
    }

    // MARK: WF13 The sidebar

    /// WF13
    @Test func theInboxIsShownExactlyWhileThereIsAWatchFolder() async throws {
        let h = try await Harness.empty()
        await h.model.settle()
        #expect(!h.model.showsInbox)

        let folder = try makeTempDir()
        await h.model.addWatchFolder(folder)
        await h.model.settle()
        #expect(h.model.showsInbox)

        // Off is still a watch folder.
        let folderId = try id(h, folder)
        await h.model.setWatchFolder(folderId, enabled: false)
        #expect(h.model.showsInbox)

        await h.model.removeWatchFolder(folderId)
        await h.model.settle()
        #expect(!h.model.showsInbox)
    }

    /// WF13: the Inbox is not one of the items every library has, and has a name.
    @Test func theInboxIsNotAFixedItem() async throws {
        let h = try await Harness.empty()
        #expect(!SidebarItem.fixed.contains(.inbox))
        #expect(h.model.title(of: .inbox) == "Inbox")
        #expect(h.model.sidebar.counts[.inbox] == nil)
    }

    /// WF13
    @Test func theInboxCountIsTheNumberOfArrivals() async throws {
        let (h, folder) = try await watching()
        #expect(h.model.inboxCount == 0)
        try drop(Self.ebook, into: folder)
        try drop(Self.parts, into: folder)
        await arrive(h)
        #expect(h.model.inboxCount == 2)
        #expect(h.model.inboxRows.count == 2)
    }

    /// WF13: the last watch folder is removed while the Inbox is what the sidebar shows.
    @Test func whenTheInboxStopsBeingShownAllBooksIsSelected() async throws {
        let h = try await Harness.demo()
        let folder = try makeTempDir()
        await h.model.addWatchFolder(folder)
        h.model.sidebarSelection = .inbox
        await h.model.settle()
        #expect(h.model.sidebarSelection == .inbox)
        #expect(h.model.windowTitle == "Inbox")

        await h.model.removeWatchFolder(try id(h, folder))
        await h.model.settle()
        #expect(h.model.sidebarSelection == .allBooks)
        #expect(h.model.rows.count == 12)
    }

    /// WF13: the Inbox stays selected through an operation that reads everything again.
    @Test func theInboxStaysSelectedWhenTheLibraryIsReadAgain() async throws {
        let h = try await Harness.demo()
        await h.model.addWatchFolder(try makeTempDir())
        h.model.sidebarSelection = .inbox
        await h.model.settle()

        await h.model.undo()
        await h.model.settle()
        #expect(h.model.sidebarSelection == .inbox)
        #expect(h.model.rows.isEmpty)
    }

    // MARK: WF14, WF15 Rows

    /// WF14: the arrivals as rows, newest first as the check gives them.
    @Test func arrivalsAreShownAsRows() async throws {
        let (h, folder) = try await watching()
        try drop(Self.ebook, into: folder)
        try drop(Self.parts, into: folder)
        await arrive(h)

        let train = try #require(h.model.inboxRows.first { $0.title == "Night Train to Vostok" })
        #expect(train.author == "Mikhail Orlov")
        #expect(train.kind == "Audiobook")
        #expect(train.files == "4 files")
        #expect(train.folder == folder.lastPathComponent)
        let rivers = try #require(h.model.inboxRows.first { $0.title == "Quiet Rivers" })
        #expect(rivers.author == "Amara Okafor")
        #expect(rivers.kind == "Ebook")
        #expect(rivers.files == "1 file")
        #expect(h.model.windowSubtitle == "No books")
        h.model.sidebarSelection = .inbox
        await h.model.settle()
        #expect(h.model.windowSubtitle == "2 books waiting")
    }

    /// WF14, WF15: a folder as Settings lists it.
    @Test func watchFoldersAreShownAsRows() async throws {
        let (h, folder) = try await watching()
        let row = try #require(h.model.watchFolderRows.first)
        #expect(real(URL(fileURLWithPath: row.path)) == real(folder))
        #expect(row.mode == .move)
        #expect(row.isEnabled)
        #expect(!row.includesPDFs)
        #expect(row.note == nil)
    }

    /// WF15: a folder that has gone is said to be missing at the next check, and watched again when it returns.
    @Test func aMissingFolderHasANoteUntilItReturns() async throws {
        let (h, folder) = try await watching()
        try FileManager.default.removeItem(at: folder)
        h.watcher.fire()
        await h.model.settle()
        #expect(h.model.watchFolderRows.first?.note == "Folder not found. It will be watched again when it returns.")
        #expect(h.model.inboxNotices.count == 1)
        #expect(h.model.showsInbox)

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        h.ticker.run(delay: 60)
        await h.model.settle()
        #expect(h.model.watchFolderRows.first?.note == nil)
        #expect(h.model.inboxNotices.isEmpty)
    }

    /// WF15: a folder that is off says so, even when it is missing too.
    @Test func aFolderThatIsOffSaysOff() async throws {
        let (h, folder) = try await watching()
        await h.model.setWatchFolder(try id(h, folder), enabled: false)
        await h.model.settle()
        #expect(h.model.watchFolderRows.first?.note == "Off")
        try FileManager.default.removeItem(at: folder)
        h.watcher.fire()
        await h.model.settle()
        #expect(h.model.watchFolderRows.first?.note == "Off")
        // Nothing about a folder that is off is said on the Inbox.
        #expect(h.model.inboxNotices.isEmpty)
    }

    // MARK: WF16 Adding a folder

    /// WF16
    @Test func addingAFolderSavesItRestartsTheWatcherAndChecks() async throws {
        let h = try await Harness.empty()
        await h.model.settle()
        let checks = h.model.inboxCheckCount
        let folder = try makeTempDir()

        await h.model.addWatchFolder(folder)
        await h.model.settle()
        #expect(h.model.alert == nil)
        #expect(try storedFolders(h).map { real($0.url) } == [real(folder)])
        #expect(h.watcher.watchCount == 1)
        #expect(h.watcher.folders.map(real) == [real(folder)])
        #expect(h.model.inboxCheckCount == checks + 1)
        #expect(h.busyLabels.isEmpty)

        let second = try makeTempDir()
        await h.model.addWatchFolder(second)
        await h.model.settle()
        #expect(h.watcher.watchCount == 2)
        #expect(h.watcher.folders.map(real) == [real(folder), real(second)])
    }

    /// WF16: what is already in a folder when it is added does not arrive.
    @Test func whatIsAlreadyInAFolderDoesNotArrive() async throws {
        let h = try await Harness.empty()
        let folder = try makeTempDir()
        try drop(Self.ebook, into: folder)
        await h.model.addWatchFolder(folder)
        await h.model.settle()
        await later(h)
        #expect(h.model.inboxCount == 0)
    }

    /// WF16: each refusal is one plain sentence, and nothing is saved.
    @Test func aFolderThatCannotBeWatchedIsRefusedWithASentence() async throws {
        // The watched folder has a folder of its own around it, which holds nothing else.
        let h = try await Harness.empty()
        let around = try makeTempDir()
        let watched = around.appendingPathComponent("Arrivals", isDirectory: true)
        try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
        await h.model.addWatchFolder(watched)
        await h.model.settle()
        let inside = h.root.appendingPathComponent("Arrivals", isDirectory: true)
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        let within = watched.appendingPathComponent("Later", isDirectory: true)
        try FileManager.default.createDirectory(at: within, withIntermediateDirectories: true)
        let watchedName = try #require(h.model.watchFolderRows.first).path

        let refusals: [(URL, String)] = [
            (watched.appendingPathComponent("nothing here"), "That folder could not be found. Choose a folder that is there."),
            (h.root, "That folder is your library. Choose a folder outside it."),
            (inside, "That folder is inside your library. Choose a folder outside it."),
            (h.root.deletingLastPathComponent(), "That folder contains your library. Choose a folder that does not."),
            (watched, "That folder is already watched."),
            (within, "That folder is inside “\(watchedName)”, which is already watched. Choose a folder that is apart from it."),
            (
                around,
                "That folder contains “\(watchedName)”, which is already watched. Choose a folder that is apart from it."
            ),
        ]
        let watches = h.watcher.watchCount
        for (folder, sentence) in refusals {
            h.model.alert = nil
            await h.model.addWatchFolder(folder)
            await h.model.settle()
            #expect(h.model.alert == sentence)
        }
        #expect(try storedFolders(h).count == 1)
        #expect(h.model.watchFolderRows.count == 1)
        #expect(h.watcher.watchCount == watches)
    }

    /// WF16: a file is not a folder.
    @Test func aFileIsRefusedAsAWatchFolder() async throws {
        let h = try await Harness.empty()
        let file = try touch(try makeTempDir().appendingPathComponent("book.epub"))
        await h.model.addWatchFolder(file)
        #expect(h.model.alert == "That folder could not be found. Choose a folder that is there.")
        #expect(!h.model.showsInbox)
    }

    // MARK: WF17 Settings

    /// WF17: Move or Copy is saved at once and a check is made; the watched folders are the same, so the
    /// watcher is left running.
    @Test func changingTheModeIsSavedAndChecksWithoutRestartingTheWatcher() async throws {
        let (h, folder) = try await watching()
        let (watches, stops, checks) = (h.watcher.watchCount, h.watcher.stopCount, h.model.inboxCheckCount)

        await h.model.setWatchFolder(try id(h, folder), mode: .copy)
        await h.model.settle()
        #expect(try storedFolders(h).first?.mode == .copy)
        #expect(h.model.watchFolderRows.first?.mode == .copy)
        #expect(h.watcher.watchCount == watches)
        #expect(h.watcher.stopCount == stops)
        #expect(h.model.inboxCheckCount == checks + 1)
        #expect(h.model.alert == nil)
    }

    /// WF17: turning a folder off and on changes what is watched, so the watcher is restarted.
    @Test func turningAFolderOffAndOnRestartsTheWatcher() async throws {
        let (h, first) = try await watching()
        let second = try makeTempDir()
        await h.model.addWatchFolder(second)
        await h.model.settle()
        let (watches, checks) = (h.watcher.watchCount, h.model.inboxCheckCount)
        let firstId = try id(h, first)

        await h.model.setWatchFolder(firstId, enabled: false)
        await h.model.settle()
        #expect(try storedFolders(h).first?.isEnabled == false)
        #expect(h.watcher.watchCount == watches + 1)
        #expect(h.watcher.folders.map(real) == [real(second)])
        #expect(h.model.inboxCheckCount == checks + 1)

        await h.model.setWatchFolder(try id(h, second), enabled: false)
        await h.model.settle()
        #expect(!h.watcher.isWatching)

        await h.model.setWatchFolder(firstId, enabled: true)
        await h.model.settle()
        #expect(h.watcher.folders.map(real) == [real(first)])
        #expect(h.model.watchFolderRows.map(\.isEnabled) == [true, false])
    }

    /// WF17: a folder that is turned off takes its arrivals with it.
    @Test func turningAFolderOffEmptiesItsArrivals() async throws {
        let (h, folder) = try await watching()
        try drop(Self.ebook, into: folder)
        await arrive(h)
        #expect(h.model.inboxCount == 1)
        await h.model.setWatchFolder(try id(h, folder), enabled: false)
        await h.model.settle()
        #expect(h.model.inboxCount == 0)
    }

    /// WF17: PDFs: saved at once; the PDFs already there do not arrive, one that comes afterwards does.
    @Test func includingPDFsIsSavedAndTakesEffectAtTheNextCheck() async throws {
        let (h, folder) = try await watching()
        MediaFixtures.makePDF(at: folder.appendingPathComponent("Old Manual.pdf"))
        let (watches, checks) = (h.watcher.watchCount, h.model.inboxCheckCount)

        await h.model.setWatchFolder(try id(h, folder), includesPDFs: true)
        await h.model.settle()
        #expect(try storedFolders(h).first?.includesPDFs == true)
        #expect(h.model.watchFolderRows.first?.includesPDFs == true)
        #expect(h.watcher.watchCount == watches)
        #expect(h.model.inboxCheckCount == checks + 1)

        MediaFixtures.makePDF(at: folder.appendingPathComponent("New Manual.pdf"))
        h.clock.now += 1
        await arrive(h)
        #expect(h.model.inboxArrivals.map { $0.files.map(\.lastPathComponent) } == [["New Manual.pdf"]])
    }

    /// WF17: two changes made one straight after the other both hold.
    @Test func twoSettingsChangedTogetherBothHold() async throws {
        let (h, folder) = try await watching()
        let folderId = try id(h, folder)
        async let mode: Void = h.model.setWatchFolder(folderId, mode: .copy)
        async let pdfs: Void = h.model.setWatchFolder(folderId, includesPDFs: true)
        _ = await (mode, pdfs)
        await h.model.settle()
        let stored = try #require(try storedFolders(h).first)
        #expect(stored.mode == .copy)
        #expect(stored.includesPDFs)
        #expect(h.model.watchFolderRows.first?.mode == .copy)
        #expect(h.model.watchFolderRows.first?.includesPDFs == true)
    }

    /// WF17: removing a folder forgets it and its arrivals; its files are left alone.
    @Test func removingAFolderStopsWatchingItAndLeavesItsFiles() async throws {
        let (h, folder) = try await watching()
        let book = try drop(Self.ebook, into: folder)
        await arrive(h)
        #expect(h.model.inboxCount == 1)
        h.model.inboxSelection = [try arrivalId(h, "Quiet Rivers")]

        await h.model.removeWatchFolder(try id(h, folder))
        await h.model.settle()
        #expect(try storedFolders(h).isEmpty)
        #expect(h.model.watchFolderRows.isEmpty)
        #expect(h.model.inboxCount == 0)
        #expect(h.model.inboxSelection.isEmpty)
        #expect(!h.watcher.isWatching)
        #expect(exists(book))
    }

    /// WF17: Scan Existing Files lets what was there when the folder was added arrive.
    @Test func scanningExistingFilesLetsThemArrive() async throws {
        let h = try await Harness.empty()
        let folder = try makeTempDir()
        try drop(Self.ebook, into: folder)
        await h.model.addWatchFolder(folder)
        await h.model.settle()
        await later(h)
        #expect(h.model.inboxCount == 0)
        let checks = h.model.inboxCheckCount

        await h.model.scanExisting(inWatchFolder: try id(h, folder))
        await h.model.settle()
        #expect(h.model.inboxCheckCount == checks + 1)
        #expect(h.model.inboxRows.map(\.title) == ["Quiet Rivers"])
    }

    // MARK: WF18 Reviewing

    /// WF18: with nothing selected, every arrival is reviewed, in the import's own sheet.
    @Test func reviewingWithNothingSelectedReviewsEveryArrival() async throws {
        let (h, folder) = try await watching()
        try drop(Self.ebook, into: folder)
        try drop(Self.parts, into: folder)
        await arrive(h)
        h.recordBusyLabels()

        await h.model.reviewInbox()
        let review = try #require(h.model.review)
        #expect(Set(review.entries.map(\.candidate.metadata.title)) == ["Quiet Rivers", "Night Train to Vostok"])
        #expect(review.isFromInbox)
        #expect(review.skipped.isEmpty)
        #expect(review.entries.allSatisfy { $0.included && $0.cover != nil })
        #expect(review.entriesNeedingDestination.isEmpty)
        #expect(review.entries.allSatisfy { $0.destination != nil })
        #expect(review.canImport)
        #expect(h.busyLabels == ["Reading files…"])
        #expect(h.model.busyLabel == nil)
        // Nothing has moved, and the arrivals are still arrivals.
        #expect(h.model.rows.isEmpty)
        #expect(h.model.inboxCount == 2)
        #expect(exists(folder.appendingPathComponent(Self.ebook)))
    }

    /// WF18: with a selection, only the selected arrivals are reviewed.
    @Test func reviewingReviewsTheSelection() async throws {
        let (h, folder) = try await watching()
        try drop(Self.ebook, into: folder)
        try drop(Self.parts, into: folder)
        await arrive(h)
        h.model.inboxSelection = [try arrivalId(h, "Quiet Rivers")]

        await h.model.reviewInbox()
        #expect(h.model.review?.entries.map(\.candidate.metadata.title) == ["Quiet Rivers"])
    }

    /// WF18: a folder of parts is one book in the review, as it is one row in the Inbox: the arrival's own
    /// grouping is reviewed, not its files scanned again one by one.
    @Test func aFolderOfPartsReviewedFromTheInboxIsOneBook() async throws {
        let (h, folder) = try await watching()
        try drop(Self.parts, into: folder)
        await arrive(h)
        #expect(h.model.inboxRows.map(\.files) == ["4 files"])

        await h.model.reviewInbox()
        let review = try #require(h.model.review)
        #expect(review.entries.count == 1)
        let entry = try #require(review.entries.first)
        #expect(entry.candidate.metadata.title == "Night Train to Vostok")
        #expect(entry.candidate.files.count == 4)
        #expect(entry.candidate.files.allSatisfy { $0.role == .audio })
        #expect(entry.candidate.files.map(\.url.lastPathComponent) == (1...4).map { "Night Train to Vostok - Part \($0).mp3" })
    }

    /// WF18: one row is reviewed by itself (a double-click), whatever is selected.
    @Test func oneArrivalCanBeReviewedByItself() async throws {
        let (h, folder) = try await watching()
        try drop(Self.ebook, into: folder)
        try drop(Self.parts, into: folder)
        await arrive(h)
        h.model.inboxSelection = [try arrivalId(h, "Quiet Rivers")]

        await h.model.reviewInbox(only: try arrivalId(h, "Night Train to Vostok"))
        #expect(h.model.review?.entries.map(\.candidate.metadata.title) == ["Night Train to Vostok"])
    }

    /// WF18: a book the library has already is offered to it, as in any import.
    @Test func anArrivalIsMatchedToTheLibrarysBook() async throws {
        let h = try await Harness.demo()
        let folder = try makeTempDir()
        await h.model.addWatchFolder(folder)
        await h.model.settle()
        try drop(Self.ebook, into: folder)
        await arrive(h)

        await h.model.reviewInbox()
        let entry = try #require(h.model.review?.entries.first)
        #expect(entry.existingMatch?.id == (try h.id("Quiet Rivers")))
    }

    /// WF18: nothing happens while a review is open, or while an operation runs.
    @Test func reviewingDoesNothingWhileAReviewIsOpenOrAnOperationRuns() async throws {
        let (h, folder) = try await watching()
        try drop(Self.ebook, into: folder)
        try drop(Self.parts, into: folder)
        await arrive(h)
        h.model.inboxSelection = [try arrivalId(h, "Quiet Rivers")]
        await h.model.reviewInbox()
        let open = try #require(h.model.review)

        h.model.inboxSelection = []
        h.recordBusyLabels()
        await h.model.reviewInbox()
        #expect(h.model.review == open)
        #expect(h.busyLabels.isEmpty)
        #expect(!h.model.canReviewInbox)

        h.model.cancelImport()
        #expect(h.model.canReviewInbox)
        let gate = Gate()
        h.model.beforeOperation = { await gate.wait() }
        let operation = Task { await h.model.undo() }
        await gate.arrival()
        #expect(!h.model.canReviewInbox)
        await h.model.reviewInbox()
        #expect(h.model.review == nil)
        await gate.release()
        await operation.value
    }

    /// WF18: with nothing waiting there is nothing to review.
    @Test func reviewingAnEmptyInboxDoesNothing() async throws {
        let (h, _) = try await watching()
        h.recordBusyLabels()
        #expect(!h.model.canReviewInbox)
        await h.model.reviewInbox()
        #expect(h.model.review == nil)
        #expect(h.busyLabels.isEmpty)
        #expect(h.model.alert == nil)
    }

    /// WF18: an arrival whose files have gone since the last check is not reviewed; the Inbox is checked again.
    @Test func anArrivalWhoseFilesHaveGoneIsNotReviewed() async throws {
        let (h, folder) = try await watching()
        let book = try drop(Self.ebook, into: folder)
        await arrive(h)
        try FileManager.default.removeItem(at: book)

        await h.model.reviewInbox()
        await h.model.settle()
        #expect(h.model.review == nil)
        #expect(h.model.alert == "Those files are no longer in the watch folder, so there is nothing to review.")
        #expect(h.model.busyLabel == nil)
        #expect(h.model.inboxCount == 0)
    }

    /// WF18: the words of the Inbox's Review button.
    @Test func theReviewButtonSaysAllWhenNothingIsSelected() async throws {
        let (h, folder) = try await watching()
        try drop(Self.ebook, into: folder)
        await arrive(h)
        #expect(h.model.reviewInboxTitle == "Review All…")
        #expect(!h.model.canDismissInbox)
        h.model.inboxSelection = [try arrivalId(h, "Quiet Rivers")]
        #expect(h.model.reviewInboxTitle == "Review…")
        #expect(h.model.canDismissInbox)
        #expect(h.model.canReviewInbox)
    }

    // MARK: WF19 Move or Copy

    /// WF19: a Move folder: the tick is off, whatever the app's own setting is.
    @Test func aReviewFromAMoveFolderIsPresetToMove() async throws {
        let (h, folder) = try await watching()
        h.model.copyOnImport = true
        try drop(Self.ebook, into: folder)
        await arrive(h)

        await h.model.reviewInbox()
        let review = try #require(h.model.review)
        #expect(review.copyInsteadOfMove == false)
        #expect(review.offersCopy)
        #expect(review.inboxNote == nil)
    }

    /// WF19: a Copy folder: the tick is on.
    @Test func aReviewFromACopyFolderIsPresetToCopy() async throws {
        let (h, folder) = try await watching()
        await h.model.setWatchFolder(try id(h, folder), mode: .copy)
        try drop(Self.ebook, into: folder)
        await arrive(h)

        await h.model.reviewInbox()
        let review = try #require(h.model.review)
        #expect(review.copyInsteadOfMove == true)
        #expect(review.inboxNote == nil)
    }

    /// WF19: folders that do not agree: Copy, which cannot surprise, and a line saying why. The owner can
    /// still change it.
    @Test func aReviewFromMoveAndCopyFoldersIsPresetToCopyAndSaysWhy() async throws {
        let (h, moving) = try await watching()
        let copying = try makeTempDir()
        await h.model.addWatchFolder(copying)
        await h.model.setWatchFolder(try id(h, copying), mode: .copy)
        await h.model.settle()
        try drop(Self.ebook, into: moving)
        try drop(Self.parts, into: copying)
        await arrive(h)

        await h.model.reviewInbox()
        let review = try #require(h.model.review)
        #expect(review.entries.count == 2)
        #expect(review.copyInsteadOfMove == true)
        #expect(review.inboxNote == "These books come from folders set to Move and to Copy, so Copy is ticked.")

        h.model.updateReview { $0.copyInsteadOfMove = false }
        #expect(h.model.review?.copyInsteadOfMove == false)
        #expect(h.model.review?.options.mode == .move)
        h.model.cancelImport()

        // Only the one from the Move folder: nothing to explain.
        h.model.inboxSelection = [try arrivalId(h, "Quiet Rivers")]
        await h.model.reviewInbox()
        #expect(h.model.review?.copyInsteadOfMove == false)
        #expect(h.model.review?.inboxNote == nil)
    }

    /// WF19: the tick of a review from the Inbox began as the folder's setting, so changing it there does
    /// not change what the app remembers for imports of its own.
    @Test func changingTheTickInAnInboxReviewLeavesTheAppsSettingAlone() async throws {
        let (h, folder) = try await watching()
        try drop(Self.ebook, into: folder)
        await arrive(h)
        #expect(h.model.copyOnImport == false)

        await h.model.reviewInbox()
        h.model.updateReview { $0.copyInsteadOfMove = true }
        await h.model.confirmImport()
        await h.model.settle()
        #expect(h.model.copyOnImport == false)
        #expect(exists(folder.appendingPathComponent(Self.ebook)))
        #expect(h.titles == ["Quiet Rivers"])
    }

    // MARK: WF20 After the review

    /// WF20: imported by Move: the book is filed, its file has left the folder, and the Inbox is checked.
    @Test func aConfirmedMoveFilesTheBookAndEmptiesTheInbox() async throws {
        let (h, folder) = try await watching()
        let book = try drop(Self.ebook, into: folder)
        await arrive(h)
        let checks = h.model.inboxCheckCount

        await h.model.reviewInbox()
        await h.model.confirmImport()
        await h.model.settle()
        #expect(h.titles == ["Quiet Rivers"])
        #expect(!exists(book))
        #expect(h.model.inboxCheckCount == checks + 1)
        #expect(h.model.inboxCount == 0)
        #expect(h.model.review == nil)
        #expect(h.model.busyLabel == nil)
    }

    /// WF20: imported by Copy: the originals stay in the folder and are remembered as imported, so they do
    /// not come back, at this check or after the app is opened again.
    @Test func aConfirmedCopyIsRememberedSoTheOriginalsDoNotComeBack() async throws {
        let (h, folder) = try await watching()
        await h.model.setWatchFolder(try id(h, folder), mode: .copy)
        let parts = try drop(Self.parts, into: folder)
        await arrive(h)
        let checks = h.model.inboxCheckCount

        await h.model.reviewInbox()
        await h.model.confirmImport()
        await h.model.settle()
        #expect(h.titles == ["Night Train to Vostok"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: parts.path).count == 4)
        #expect(h.model.inboxCheckCount == checks + 1)
        #expect(h.model.inboxCount == 0)

        h.clock.now += 60
        h.watcher.fire()
        await h.model.settle()
        #expect(h.model.inboxCount == 0)

        let ticker = FakeTicker()
        let model = h.relaunched(ticker: ticker)
        await model.start()
        await model.settle()
        h.clock.now += 11
        ticker.run(delay: 11)
        await model.settle()
        #expect(model.inboxCount == 0)
    }

    /// WF20: a book that was left out of the import is still waiting afterwards.
    @Test func anArrivalLeftOutOfTheImportStaysInTheInbox() async throws {
        let (h, folder) = try await watching()
        await h.model.setWatchFolder(try id(h, folder), mode: .copy)
        try drop(Self.ebook, into: folder)
        try drop(Self.parts, into: folder)
        await arrive(h)

        await h.model.reviewInbox()
        let rivers = try #require(h.model.review?.entries.first { $0.candidate.metadata.title == "Quiet Rivers" })
        h.model.updateReview { review in
            guard let index = review.entries.firstIndex(where: { $0.id == rivers.id }) else { return }
            review.entries[index].included = false
        }
        await h.model.confirmImport()
        await h.model.settle()
        #expect(h.titles == ["Night Train to Vostok"])
        #expect(h.model.inboxRows.map(\.title) == ["Quiet Rivers"])
    }

    /// WF20: a cancelled review records nothing: the arrivals are still there, now and at the next check.
    @Test func aCancelledReviewLeavesTheArrivals() async throws {
        let (h, folder) = try await watching()
        await h.model.setWatchFolder(try id(h, folder), mode: .copy)
        let book = try drop(Self.ebook, into: folder)
        await arrive(h)

        await h.model.reviewInbox()
        h.model.cancelImport()
        await h.model.settle()
        #expect(h.model.review == nil)
        #expect(h.model.inboxCount == 1)
        h.watcher.fire()
        await h.model.settle()
        #expect(h.model.inboxCount == 1)
        #expect(exists(book))
        #expect(h.model.rows.isEmpty)
    }

    /// WF20: an import that did not come from the Inbox records nothing there, even of files in a watch folder.
    @Test func anImportByHandAfterACancelledInboxReviewIsNotTakenForOne() async throws {
        let (h, folder) = try await watching()
        try drop(Self.ebook, into: folder)
        await arrive(h)
        await h.model.reviewInbox()
        h.model.cancelImport()

        let other = try Harness.inbox().appendingPathComponent("The Lighthouse Keeper.m4b")
        await h.model.beginImport([other])
        #expect(h.model.review?.isFromInbox == false)
        let checks = h.model.inboxCheckCount
        await h.model.confirmImport()
        await h.model.settle()
        #expect(h.titles == ["The Lighthouse Keeper"])
        #expect(h.model.inboxCheckCount == checks)
        #expect(h.model.inboxCount == 1)
    }

    // MARK: WF21 Dismissing

    /// WF21: the selected arrivals leave the Inbox for good; their files are not touched.
    @Test func dismissingTakesTheSelectionOutOfTheInbox() async throws {
        let (h, folder) = try await watching()
        let book = try drop(Self.ebook, into: folder)
        try drop(Self.parts, into: folder)
        await arrive(h)
        h.model.inboxSelection = [try arrivalId(h, "Quiet Rivers")]
        let checks = h.model.inboxCheckCount
        h.recordBusyLabels()

        await h.model.dismissInbox()
        await h.model.settle()
        #expect(h.model.inboxRows.map(\.title) == ["Night Train to Vostok"])
        #expect(h.model.inboxSelection.isEmpty)
        #expect(h.model.inboxCheckCount == checks + 1)
        #expect(exists(book))
        #expect(h.busyLabels.isEmpty)

        h.clock.now += 60
        h.ticker.run(delay: 60)
        await h.model.settle()
        #expect(h.model.inboxRows.map(\.title) == ["Night Train to Vostok"])
    }

    /// WF21
    @Test func dismissingWithNothingSelectedDoesNothing() async throws {
        let (h, folder) = try await watching()
        try drop(Self.ebook, into: folder)
        await arrive(h)
        let checks = h.model.inboxCheckCount

        await h.model.dismissInbox()
        await h.model.settle()
        #expect(h.model.inboxCount == 1)
        #expect(h.model.inboxCheckCount == checks)
    }

    // MARK: WF22 The selection

    /// WF22
    @Test func theSelectionDropsArrivalsThatHaveGone() async throws {
        let (h, folder) = try await watching()
        let book = try drop(Self.ebook, into: folder)
        try drop(Self.parts, into: folder)
        await arrive(h)
        let train = try arrivalId(h, "Night Train to Vostok")
        h.model.inboxSelection = [try arrivalId(h, "Quiet Rivers"), train]

        try FileManager.default.removeItem(at: book)
        h.watcher.fire()
        await h.model.settle()
        #expect(h.model.inboxSelection == [train])
    }

    // MARK: WF23 A check that fails

    /// WF23: the Inbox stays as it was, with a note and no alert; the next good check clears the note.
    @Test func aCheckThatFailsLeavesTheInboxAndSaysSoOnTheInbox() async throws {
        let (h, folder) = try await watching()
        try drop(Self.ebook, into: folder)
        await arrive(h)
        let rows = h.model.inboxRows
        let folders = h.model.watchFolderRows
        #expect(h.model.inboxProblem == nil)

        h.model.beforeInboxCheck = { throw CheckFailed() }
        h.watcher.fire()
        await h.model.settle()
        #expect(h.model.inboxRows == rows)
        #expect(h.model.watchFolderRows == folders)
        #expect(h.model.alert == nil)
        #expect(h.model.inboxProblem == "The inbox could not be checked.")
        #expect(h.model.inboxNotices == ["The inbox could not be checked."])

        h.model.beforeInboxCheck = nil
        h.watcher.fire()
        await h.model.settle()
        #expect(h.model.inboxProblem == nil)
        #expect(h.model.inboxNotices.isEmpty)
        #expect(h.model.inboxRows == rows)
    }

    // MARK: WF24 Showing the Inbox

    /// WF24: the Inbox shows no books and no inspector, and says so in place of the grid or the list.
    @Test func selectingTheInboxShowsNoBooksAndNoInspector() async throws {
        let h = try await Harness.demo()
        await h.model.addWatchFolder(try makeTempDir())
        try await h.select("Quiet Rivers")
        #expect(h.detail != nil)

        h.model.sidebarSelection = .inbox
        await h.model.settle()
        #expect(h.model.rows.isEmpty)
        #expect(h.model.selection.isEmpty)
        #expect(h.model.inspecting == .nothing)
        #expect(h.model.booksContent == .inbox)
        #expect(h.model.emptyState == nil)
        #expect(h.model.windowTitle == "Inbox")
        #expect(h.model.windowSubtitle == "Nothing waiting")

        h.model.sidebarSelection = .allBooks
        await h.model.settle()
        #expect(h.model.rows.count == 12)
        #expect(h.model.booksContent == .books)
    }

    /// WF24: the library is not asked for the Inbox's books: it has none to give.
    @Test func theLibraryHasNoRowsForTheInbox() async throws {
        let h = try await Harness.demo()
        let worker = try LibraryWorker(libraryRoot: h.root)
        #expect(try await worker.rows(for: .inbox, search: "").isEmpty)
        // A search does not bring books into the Inbox either.
        await h.model.addWatchFolder(try makeTempDir())
        h.model.sidebarSelection = .inbox
        h.model.searchText = "Rivers"
        await h.model.settle()
        #expect(h.model.rows.isEmpty)
        #expect(h.model.booksContent == .inbox)
    }

    /// WF24: with unsaved changes, going to the Inbox asks first, as going anywhere else does.
    @Test func goingToTheInboxWithUnsavedChangesAsksFirst() async throws {
        let h = try await Harness.demo()
        await h.model.addWatchFolder(try makeTempDir())
        try await h.edit("Quiet Rivers", newTitle: "Quieter Rivers")

        h.model.sidebarSelection = .inbox
        await h.model.settle()
        #expect(h.model.prompt == .unsavedChanges)
        await h.model.resolveUnsaved(.cancel)
        #expect(h.model.sidebarSelection == .allBooks)
        #expect(h.model.rows.count == 12)
    }
}

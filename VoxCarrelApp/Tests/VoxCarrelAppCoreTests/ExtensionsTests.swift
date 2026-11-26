import Foundation
import SwiftUI
import Testing
import VoxCarrelCore
import VoxCarrelFixtures

@testable import VoxCarrelAppCore

/// EX1 onwards: what a package that adds features is given to add them with, as the
/// app's model decides it. The extensions here are fakes of this file's own.
@MainActor
@Suite struct ExtensionsTests {
    /// Gives the model a view for every `FakeSheet`, and for no other sheet.
    private func giveSheetView(to model: AppModel) {
        model.extensions.sheetViews.append { sheet in
            sheet is FakeSheet ? AnyView(EmptyView()) : nil
        }
    }

    // MARK: Nothing added

    @Test func EX1_withNoExtensionsNothingIsAddedAndEveryFeatureIsLocked() async throws {
        let h = try await Harness.demo()
        let books = try h.ids(["The Lighthouse Keeper"])
        let join = ExtensionFeature(id: "join", title: "Join Parts")

        #expect(h.model.extensions.bookCommands.isEmpty)
        #expect(h.model.extensions.sheetViews.isEmpty)
        #expect(h.model.extensions.settingsPanes.isEmpty)
        #expect(h.model.extensions.onStart.isEmpty)
        #expect(h.model.extensionCommands(for: books).isEmpty)
        #expect(h.model.extensionCommands(for: []).isEmpty)
        #expect(!h.model.extensions.entitlements.isUnlocked(join))
        #expect(!NoEntitlements().isUnlocked(join))
        #expect(h.model.extensionSheet == nil)
        #expect(h.model.windowSheet(progressDue: false) == nil)
        // Running a command that is not there does nothing.
        h.model.runExtensionCommand("join", for: books)
        #expect(h.model.alert == nil && h.model.busyLabel == nil)

        // An extension's own entitlements answer for themselves.
        h.model.extensions.entitlements = OneFeature(unlocked: "join")
        #expect(h.model.extensions.entitlements.isUnlocked(join))
        #expect(!h.model.extensions.entitlements.isUnlocked(ExtensionFeature(id: "other", title: "Other")))
    }

    // MARK: Book commands

    // EX7: a command added to the app's own menu is shown by its title, enabled by its
    // own answer each time it is asked, and run only while it is enabled. It needs no library.
    @Test func EX7_anAppCommandIsShownEnabledByItsOwnAnswerAndRunOnlyThen() async throws {
        let h = try await Harness.demo(start: false)
        let extensions = AppExtensions()
        var allowed = false
        var runs = 0
        extensions.appCommands.append(
            ExtensionAppCommand(id: "tidy", title: "Tidy Up…", isEnabled: { allowed }, perform: { runs += 1 }))
        extensions.appCommands.append(ExtensionAppCommand(id: "always", title: "Always", perform: {}))
        let model = h.relaunched(extensions: extensions)
        #expect(model.extensionAppCommands == [
            ExtensionCommandItem(id: "tidy", title: "Tidy Up…", isEnabled: false),
            ExtensionCommandItem(id: "always", title: "Always", isEnabled: true),
        ])
        model.performExtensionAppCommand("tidy")
        #expect(runs == 0)
        allowed = true
        #expect(model.extensionAppCommands.first?.isEnabled == true)
        model.performExtensionAppCommand("tidy")
        model.performExtensionAppCommand("no such command")
        #expect(runs == 1)
        // With none added, the menu has nothing more.
        #expect(h.model.extensionAppCommands.isEmpty)
    }

    @Test func EX2_aBookCommandIsShownEnabledByItsOwnAnswerAndRunWithTheBooks() async throws {
        let h = try await Harness.demo()
        let one = try h.ids(["The Lighthouse Keeper"])
        let two = try h.ids(["The Lighthouse Keeper", "Quiet Rivers"])
        let join = FakeCommand(id: "join")
        let other = FakeCommand(id: "other")
        h.model.extensions.bookCommands = [join, other]

        // In the order they were added, each titled for the books asked about.
        #expect(h.model.extensionCommands(for: one) == [
            ExtensionCommandItem(id: "join", title: "Join Parts", isEnabled: true),
            ExtensionCommandItem(id: "other", title: "Join Parts", isEnabled: true),
        ])
        #expect(h.model.extensionCommands(for: two).map(\.title) == [
            "Join Parts of 2 Books", "Join Parts of 2 Books",
        ])

        // Enabled by its own answer.
        join.enabled = false
        #expect(h.model.extensionCommands(for: one).map(\.isEnabled) == [false, true])
        h.model.runExtensionCommand("join", for: one)
        #expect(join.ran.isEmpty)
        #expect(h.model.extensionCommands(for: []).map(\.isEnabled) == [false, false])

        // Run with the books it was chosen for, which need not be the selection.
        join.enabled = true
        h.model.runExtensionCommand("join", for: two)
        h.model.runExtensionCommand("join", for: one)
        #expect(join.ran == [two, one])
        #expect(other.ran.isEmpty)
        h.model.runExtensionCommand("nothing", for: one)
        #expect(join.ran.count == 2 && other.ran.isEmpty)

        // A row that stands for a book the library does not have is no book's: no
        // command is enabled for it, and none is run on it.
        let withMissing = one.union([-1])
        #expect(h.model.extensionCommands(for: withMissing).map(\.isEnabled) == [false, false])
        h.model.runExtensionCommand("join", for: withMissing)
        #expect(join.ran.count == 2)
    }

    @Test func EX2b_noBookCommandIsEnabledWhileNoLibraryIsOpen() async throws {
        let h = try Harness(root: try makeTempDir(), choose: false)
        await h.model.start()
        let join = FakeCommand(id: "join")
        h.model.extensions.bookCommands = [join]

        #expect(!h.model.isLibraryOpen)
        #expect(h.model.extensionCommands(for: [1]) == [
            ExtensionCommandItem(id: "join", title: "Join Parts", isEnabled: false)
        ])
        h.model.runExtensionCommand("join", for: [1])
        #expect(join.ran.isEmpty)
    }

    // MARK: Sheets

    @Test func EX3_anExtensionSheetIsTheWindowsSheetAndKeepsTheOthersOut() async throws {
        let h = try await Harness.demo()
        try h.link(AudibleSamples.account(.uk))
        giveSheetView(to: h.model)
        #expect(h.model.canShowExtensionSheet)
        #expect(h.model.canBeginShelf && h.model.canManageGenres && h.model.canFillInGenres)
        #expect(h.model.canImportAudibleLibrary && h.model.canImportKindleLibrary)

        let sheet = FakeSheet()
        h.model.extensionSheet = sheet
        #expect(h.model.extensionSheet === sheet)
        #expect(h.model.windowSheet(progressDue: false) == .extension(ExtensionSheetShown(sheet)))
        #expect(h.model.windowSheet(progressDue: false)?.id == "extension.fake")
        // One sheet at a time: nothing else that needs a sheet can begin.
        #expect(!h.model.canShowExtensionSheet)
        #expect(!h.model.canBeginShelf && !h.model.canManageGenres && !h.model.canFillInGenres)
        #expect(!h.model.canUpdateGenreFiles)
        #expect(!h.model.canImportAudibleLibrary && !h.model.canImportKindleLibrary)
        h.model.beginNewShelf()
        h.model.beginManageGenres()
        h.model.beginKindleImport()
        #expect(h.model.shelfEditor == nil && h.model.genreManager == nil && h.model.kindleImport == nil)
        #expect(h.model.windowSheet(progressDue: false) == .extension(ExtensionSheetShown(sheet)))

        // Another sheet of the same kind is the same kind of sheet, with another state.
        let second = FakeSheet()
        h.model.extensionSheet = second
        #expect(h.model.windowSheet(progressDue: false) == .extension(ExtensionSheetShown(second)))
        #expect(h.model.windowSheet(progressDue: false) != .extension(ExtensionSheetShown(sheet)))
        #expect(h.model.windowSheet(progressDue: false)?.id == "extension.fake")

        // Taken down by the extension itself: it is not told what it already knows.
        h.model.extensionSheet = nil
        #expect(h.model.windowSheet(progressDue: false) == nil)
        #expect(sheet.timesClosed == 0 && second.timesClosed == 0)
        #expect(h.model.canShowExtensionSheet && h.model.canBeginShelf && h.model.canManageGenres)
        #expect(h.model.canImportKindleLibrary)
    }

    @Test func EX3b_openingAnotherLibraryClosesAnExtensionSheetAndTellsIt() async throws {
        let h = try await Harness.demo()
        giveSheetView(to: h.model)
        let sheet = FakeSheet()
        h.model.extensionSheet = sheet
        #expect(sheet.timesClosed == 0)

        await h.model.chooseLibrary(try makeTempDir())

        #expect(h.model.extensionSheet == nil)
        #expect(h.model.windowSheet(progressDue: false) == nil)
        #expect(sheet.timesClosed == 1)
        // Once: opening a library again has nothing to close.
        await h.model.chooseLibrary(try makeTempDir())
        #expect(sheet.timesClosed == 1)
    }

    @Test func EX3c_aSheetThatNothingHasAViewForIsNotKept() async throws {
        let h = try await Harness.demo()
        // No factory at all.
        let unknown = FakeSheet(id: "unknown")
        h.model.extensionSheet = unknown
        #expect(h.model.extensionSheet == nil)
        #expect(h.model.windowSheet(progressDue: false) == nil)
        #expect(unknown.timesClosed == 1)
        #expect(h.model.canBeginShelf)

        // A factory, which answers only for its own sheets.
        h.model.extensions.sheetViews.append { sheet in
            sheet.id == "fake" ? AnyView(EmptyView()) : nil
        }
        let shown = FakeSheet()
        h.model.extensionSheet = shown
        #expect(h.model.extensionSheet === shown)
        #expect(h.model.extensions.sheetView(for: shown) != nil)
        #expect(h.model.extensions.sheetView(for: unknown) == nil)
        // Asking for a sheet with no view in its place leaves no sheet up. The one that
        // was up is not told: it was the extension that asked for another.
        h.model.extensionSheet = unknown
        #expect(h.model.extensionSheet == nil)
        #expect(unknown.timesClosed == 2 && shown.timesClosed == 0)
    }

    // MARK: Starting

    @Test func EX4_onStartRunsOnceWithTheModel() async throws {
        let h = try await Harness.demo(start: false)
        var started: [AppModel] = []
        let extensions = AppExtensions()
        extensions.onStart.append { started.append($0) }
        let join = FakeCommand(id: "join")
        extensions.bookCommands = [join]

        let model = h.relaunched(extensions: extensions)
        // As soon as the model exists, before any library is opened.
        #expect(started.count == 1 && started.first === model)
        #expect(model.extensions === extensions)

        await model.start()
        await model.retryLibrary()
        #expect(started.count == 1)
        #expect(model.extensionCommands(for: try h.ids(["Quiet Rivers"])).map(\.id) == ["join"])
    }

    // MARK: Working on the library

    @Test func EX5_extensionWorkRunsAsAnOperationAndWhatIsShownIsReadAgain() async throws {
        let h = try await Harness.demo()
        #expect(h.model.libraryRoot?.standardizedFileURL == h.root.standardizedFileURL)
        let id = try h.id("Quiet Rivers")
        #expect(h.model.rows.first { $0.id == id }?.book.metadata.title == "Quiet Rivers")

        // The work is handed the worker, under the label, and reaches the engine.
        var labelSeen: String?
        let ran = await h.model.performExtensionWork("Joining parts…") { worker in
            labelSeen = h.model.busyLabel
            try await worker.withService { service in
                var book = try #require(try service.store.book(id: id))
                book.metadata.title = "Quieter Rivers"
                try service.store.update(book)
            }
        }
        #expect(ran)
        #expect(labelSeen == "Joining parts…")
        #expect(h.model.busyLabel == nil && h.model.alert == nil)
        // Read again when it ended.
        #expect(h.model.rows.first { $0.id == id }?.book.metadata.title == "Quieter Rivers")

        // An error is shown as a sentence, and the operation still ends.
        struct Failure: LocalizedError {
            var errorDescription: String? { "The parts could not be joined." }
        }
        let failed = await h.model.performExtensionWork("Joining parts…") { _ in throw Failure() }
        #expect(!failed)
        #expect(h.model.alert == "The parts could not be joined.")
        #expect(h.model.busyLabel == nil)
    }

    @Test func EX5b_extensionWorkIsNotRunWithoutALibrary() async throws {
        let h = try Harness(root: try makeTempDir(), choose: false)
        await h.model.start()
        #expect(h.model.libraryRoot == nil)
        var wasRun = false
        let ran = await h.model.performExtensionWork("Joining parts…") { _ in wasRun = true }
        #expect(!ran && !wasRun)
        #expect(h.model.busyLabel == nil && h.model.alert == nil)
    }

    @Test func EX6_withServiceReachesTheLibrarysEngine() async throws {
        let root = try makeTempDir()
        let worker = try LibraryWorker(libraryRoot: root)
        let store = try LibraryStore(libraryRoot: root)
        try store.insert(Book(metadata: BookMetadata(title: "One", authors: ["Ann Author"])), files: [])

        let titles = try await worker.withService { service in
            try service.store.books().map(\.metadata.title)
        }
        #expect(titles == ["One"])
        let folder = await worker.withService { $0.store.libraryRoot }
        #expect(folder == root)
        // What the closure throws comes back.
        struct Failure: Error {}
        await #expect(throws: Failure.self) {
            try await worker.withService { _ in throw Failure() }
        }
    }
}

// MARK: Fakes

/// A book command that answers what it is told to, and notes what it was run with.
@MainActor
private final class FakeCommand: BookCommandExtension {
    let id: String
    var enabled = true
    var ran: [Set<Int64>] = []

    init(id: String) {
        self.id = id
    }

    func title(for books: Set<Int64>, in model: AppModel) -> String {
        books.count == 1 ? "Join Parts" : "Join Parts of \(books.count) Books"
    }

    func isEnabled(for books: Set<Int64>, in model: AppModel) -> Bool {
        enabled && !books.isEmpty
    }

    func run(for books: Set<Int64>, in model: AppModel) {
        ran.append(books)
    }
}

/// A sheet that counts how often the window closed it.
@MainActor @Observable
private final class FakeSheet: ExtensionSheet {
    let id: String
    var timesClosed = 0

    init(id: String = "fake") {
        self.id = id
    }

    func closed() {
        timesClosed += 1
    }
}

/// Entitlements that unlock one feature.
private struct OneFeature: Entitlements {
    let unlocked: String

    func isUnlocked(_ feature: ExtensionFeature) -> Bool {
        feature.id == unlocked
    }
}

extension Harness {
    /// As `relaunched()`, with these extensions: a second model over the same
    /// preferences, which reaches nothing real.
    func relaunched(extensions: AppExtensions) -> AppModel {
        let clock = clock
        AppModel.countsWordsBehindByDefault = false
        AppModel.asksWikidataByDefault = false
        let model = AppModel(
            location: LibraryLocation(defaults: defaults), opener: opener, defaults: defaults,
            lookupService: lookup.service(for:),
            watcher: FakeFolderWatcher(), ticker: FakeTicker(), inboxNow: { clock.now },
            phoneLink: phoneLink, sleepGuard: sleepGuard, audibleKeys: audibleKeys, audibleTransport: audible,
            readwiseTokens: readwiseTokens, ownerCheck: ownerCheck, ebookConverter: converter,
            kindleSender: kindleSender, extensions: extensions)
        model.network = network
        model.sendTempRoot = sendTemp
        model.audibleLinkFile = audibleLinkFile
        model.readwiseTokenFile = readwiseTokenFile
        model.readwiseWait = { _ in }
        let clipboard = clipboard
        let covers = covers
        let writer = clipboardWriter
        model.audibleClipboard = { clipboard.read() }
        model.audibleCoverFetch = { await covers.fetch($0) }
        model.writeClipboard = { writer.write($0) }
        return model
    }
}

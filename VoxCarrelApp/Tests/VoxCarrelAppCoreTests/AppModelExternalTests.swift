import DemoContent
import Foundation
import Testing
import VoxCarrelCore
import VoxCarrelFixtures

@testable import VoxCarrelAppCore

private let glassASIN = "B0GLASSTID"

/// Books owned on Audible, with or without files here (plan 6, Task 3). R1–R10.
@MainActor
@Suite struct AppModelExternalTests {
    private func glassTide() -> BookMetadata {
        var metadata = BookMetadata(title: "The Glass Tide", authors: ["Ines Calloway"])
        metadata.narrators = ["Marcus Lindqvist"]
        metadata.series = "Tidewater Chronicles"
        metadata.seriesNumber = "4"
        metadata.durationSeconds = 10 * 3600
        return metadata
    }

    /// A demo library that also has "The Glass Tide", which is on Audible (the United
    /// Kingdom's) and has no files here.
    private func demoWithGlassTide(
        copy: ExternalCopy = ExternalCopy(kind: .audible, form: .audio, store: "uk", itemId: glassASIN),
        _ change: (inout BookMetadata) -> Void = { _ in }
    ) async throws -> (h: Harness, glass: Int64) {
        let h = try await Harness.demo(start: false)
        var metadata = glassTide()
        change(&metadata)
        let outcome = try LibraryService(store: try h.store()).addExternalBook(
            metadata: metadata, cover: nil, copy: copy)
        guard case .added(let id) = outcome else {
            Issue.record("the book was not added")
            return (h, -1)
        }
        await h.model.start()
        return (h, id)
    }

    private func mark(_ h: Harness, _ title: String, store: String? = "uk", itemId: String? = nil) throws -> Int64 {
        let id = try h.id(title)
        try LibraryService(store: try h.store()).setExternalCopies(
            [ExternalCopy(kind: .audible, form: .audio, store: store, itemId: itemId)], for: id)
        return id
    }

    private func row(_ h: Harness, _ id: Int64) throws -> BookRow {
        try #require(h.model.rows.first { $0.id == id })
    }

    // MARK: The demo library as it is made for trying the app

    /// The library the demo tool makes, Audible books and all: it opens, every list
    /// counts what it should, and the launch check has nothing to say.
    @Test func theWholeDemoLibraryOpensCleanly() async throws {
        let root = try makeTempDir()
        try DemoContent.makeLibrary(at: root)
        let h = try Harness(root: root)
        await h.model.start()

        #expect(h.model.isLibraryOpen)
        #expect(h.model.alert == nil)
        #expect(h.model.libraryCheck == nil)
        #expect(h.model.rows.count == 14)
        #expect(h.model.sidebar.counts[.allBooks] == 14)
        #expect(h.model.sidebar.counts[.onAudible] == 3)
        #expect(h.model.sidebar.counts[.audiobooks] == 11)
        #expect(h.model.sidebar.counts[.needsAttention] == 1)
        #expect(h.model.rows.filter { !$0.hasFiles }.map(\.book.title).sorted()
            == ["Letters from the Ice Shelf", "The Glass Tide"])
        #expect(h.model.rows.filter { !$0.hasFiles }.allSatisfy { $0.isOnAudible && !$0.book.needsAttention })
        for item in SidebarItem.fixed {
            h.model.sidebarSelection = item
            await h.model.settle()
            #expect(h.model.rows.count == h.model.sidebar.counts[item])
        }
        #expect(h.model.alert == nil)
    }

    // MARK: R1 Lists

    /// R1
    @Test func R1_onAudibleIsAFixedItemAfterEbooks() async throws {
        #expect(
            SidebarItem.fixed == [
                .allBooks, .audiobooks, .ebooks, .onAudible, .unread, .inProgress, .finished, .needsAttention,
            ])
        let (h, _) = try await demoWithGlassTide()
        #expect(h.model.title(of: .onAudible) == "On Audible")
        h.model.sidebarSelection = .onAudible
        await h.model.settle()
        #expect(h.model.windowTitle == "On Audible")
        #expect(h.titles == ["The Glass Tide"])
    }

    /// R1: the count, the list, and the Audiobooks list (M3).
    @Test func R1_theSidebarCountsAndListsBooksOnAudible() async throws {
        let (h, glass) = try await demoWithGlassTide()
        #expect(h.model.sidebar.counts[.onAudible] == 1)
        #expect(h.model.sidebar.counts[.allBooks] == 13)
        #expect(h.model.sidebar.counts[.audiobooks] == 10)
        #expect(h.model.sidebar.counts[.ebooks] == 4)
        // The launch check has nothing to say about a book with no files.
        #expect(h.model.libraryCheck == nil)
        #expect(h.model.sidebar.counts[.needsAttention] == 1)

        h.model.sidebarSelection = .audiobooks
        await h.model.settle()
        #expect(h.model.rows.count == 10)
        #expect(h.model.rows.contains { $0.id == glass })
        #expect(h.model.rows.allSatisfy { $0.hasAudio })

        // A book with files that is marked is listed too.
        let salt = try mark(h, "Salt Road")
        await h.model.retryLibrary()
        #expect(h.model.sidebar.counts[.onAudible] == 2)
        h.model.sidebarSelection = .onAudible
        await h.model.settle()
        #expect(Set(h.model.rows.map(\.id)) == [glass, salt])
    }

    /// R1: a library with none.
    @Test func R1_aLibraryWithNoneCountsZero() async throws {
        let h = try await Harness.demo()
        #expect(h.model.sidebar.counts[.onAudible] == 0)
        h.model.sidebarSelection = .onAudible
        await h.model.settle()
        #expect(h.model.rows.isEmpty)
    }

    // MARK: R2 Rows

    /// R2
    @Test func R2_aRowSaysWhereTheBookIs() async throws {
        let (h, glass) = try await demoWithGlassTide()
        let salt = try mark(h, "Salt Road", itemId: "B0SALTROAD")
        await h.model.retryLibrary()

        let onlyThere = try row(h, glass)
        #expect(onlyThere.hasAudio)
        #expect(!onlyThere.hasEbook)
        #expect(onlyThere.formats.isEmpty)
        #expect(!onlyThere.hasFiles)
        #expect(onlyThere.isOnAudible)
        #expect(onlyThere.opensOnAudible)
        #expect(
            onlyThere.externalCopies
                == [ExternalCopy(kind: .audible, form: .audio, store: "uk", itemId: glassASIN)])
        #expect(onlyThere.whereaboutsText == "On Audible, not on this Mac")
        #expect(onlyThere.lengthText == "10h 0m")
        #expect(!onlyThere.hasWriteProblem)
        #expect(onlyThere.outsideFiles.isEmpty)

        let both = try row(h, salt)
        #expect(both.hasAudio)
        #expect(both.formats == [.m4b])
        #expect(both.hasFiles)
        #expect(both.isOnAudible)
        #expect(!both.opensOnAudible)
        #expect(both.whereaboutsText == "Also on Audible")

        let local = try row(h, try h.id("Quiet Rivers"))
        #expect(!local.hasAudio)
        #expect(local.hasEbook)
        #expect(local.hasFiles)
        #expect(!local.isOnAudible)
        #expect(!local.opensOnAudible)
        #expect(local.externalCopies.isEmpty)
        #expect(local.whereaboutsText == nil)
    }

    /// R2: the inspector's row is the list's.
    @Test func R2_theDetailOfABookWithNoFiles() async throws {
        let (h, glass) = try await demoWithGlassTide()
        h.model.click(glass, modifiers: [])
        await h.model.settle()
        let detail = try #require(h.detail)
        #expect(detail.row == (try row(h, glass)))
        #expect(detail.files.isEmpty)
        #expect(detail.chapterCount == 0)
        #expect(detail.audioSummaryText == "10h 0m")
    }

    /// V3, V4: what the Listen button and menu item say: for a book that is listened to
    /// on Audible, that it opens there.
    @Test func V3_listenSaysWhereItOpens() async throws {
        let (h, glass) = try await demoWithGlassTide()
        let salt = try mark(h, "Salt Road", itemId: "B0SALTROAD")
        await h.model.retryLibrary()

        let onlyThere = try row(h, glass)
        #expect(onlyThere.listenTitle == "Open on Audible")
        #expect(onlyThere.listenHelpText == "Open this book’s page on the Audible website")
        let both = try row(h, salt)
        #expect(both.listenTitle == "Listen")
        #expect(both.listenHelpText == "Open the audiobook")

        #expect(h.model.listenTitle(for: [glass]) == "Open on Audible")
        #expect(h.model.listenTitle(for: [salt]) == "Listen")
        // Several books are not opened at once, and a book that is not shown is not known.
        #expect(h.model.listenTitle(for: [glass, salt]) == "Listen")
        #expect(h.model.listenTitle(for: []) == "Listen")
        #expect(h.model.listenTitle(for: [-5]) == "Listen")
    }

    /// V3: what the inspector's Files section says of a book that has none.
    @Test func V3_theFilesSectionOfABookWithNoFiles() async throws {
        let (h, glass) = try await demoWithGlassTide()
        h.model.click(glass, modifiers: [])
        await h.model.settle()
        #expect(h.detail?.noFilesText == "This book has no files on this Mac.")
        try await h.select("Salt Road")
        #expect(try #require(h.detail).noFilesText == nil)
    }

    // MARK: R4 Opening

    /// R4
    @Test func R4_aBookOnAudibleOnlyOpensItsPageInItsStore() async throws {
        let (h, glass) = try await demoWithGlassTide()
        h.model.audibleStore = .de
        h.model.open(glass)
        await h.model.settle()
        let page = try #require(URL(string: "https://www.audible.co.uk/pd/B0GLASSTID"))
        #expect(h.opener.openedWeb == [page])
        h.model.listen(glass)
        await h.model.settle()
        #expect(h.opener.openedWeb == [page, page])
        #expect(h.opener.opened.isEmpty)
        #expect(h.model.alert == nil)

        // For menus and the list: the one selected book.
        h.model.openOne(of: [glass])
        h.model.listenOne(of: [glass])
        await h.model.settle()
        #expect(h.opener.openedWeb.count == 4)
    }

    /// R4: a copy that names no store, or one this version does not know, is looked for
    /// in the store of the settings; one with no ID of its own uses the book's ASIN.
    @Test func R4_theSettingsStoreAndTheBooksASINFillIn() async throws {
        let (h, glass) = try await demoWithGlassTide(copy: ExternalCopy(kind: .audible, form: .audio)) {
            $0.asin = "B0FROMBOOK"
        }
        h.model.audibleStore = .de
        h.model.open(glass)
        await h.model.settle()
        #expect(h.opener.openedWeb == [try #require(URL(string: "https://www.audible.de/pd/B0FROMBOOK"))])

        let unknown = try await demoWithGlassTide(
            copy: ExternalCopy(kind: .audible, form: .audio, store: "atlantis", itemId: glassASIN))
        unknown.h.model.audibleStore = .au
        unknown.h.model.listen(unknown.glass)
        await unknown.h.model.settle()
        #expect(
            unknown.h.opener.openedWeb
                == [try #require(URL(string: "https://www.audible.com.au/pd/B0GLASSTID"))])
    }

    /// R4: the page that opens follows the ASIN: saving another one for a book with no
    /// files changes its Audible copy, so the right page opens.
    @Test func R4_savingAnotherASINOpensThatPage() async throws {
        let (h, glass) = try await demoWithGlassTide { $0.asin = glassASIN }
        h.model.sidebarSelection = .onAudible
        await h.model.settle()
        h.model.click(glass, modifiers: [])
        await h.model.settle()
        h.model.updateDraft { $0.asin = "B0RIGHTONE" }
        await h.model.save()
        #expect(h.model.alert == nil)
        #expect(try h.book(glass).asin == "B0RIGHTONE")
        #expect(try h.book(glass).externalCopies.map(\.itemId) == ["B0RIGHTONE"])
        h.model.open(glass)
        await h.model.settle()
        #expect(h.opener.openedWeb == [try #require(URL(string: "https://www.audible.co.uk/pd/B0RIGHTONE"))])
    }

    /// R4: with no ASIN at all, a search of the store for the title and author.
    @Test func R4_withNoASINItSearchesTheStore() async throws {
        let (h, glass) = try await demoWithGlassTide(copy: ExternalCopy(kind: .audible, form: .audio, store: "fr"))
        h.model.open(glass)
        await h.model.settle()
        let search = AudibleStore.fr.webAddress(asin: nil, title: "The Glass Tide", author: "Ines Calloway")
        #expect(search.host == "www.audible.fr")
        #expect(search.path == "/search")
        #expect(h.opener.openedWeb == [search])
    }

    /// R4: a book that has the audio file opens the file, marked or not.
    @Test func R4_aBookWithAnAudioFileOpensTheFile() async throws {
        let h = try await Harness.demo(start: false)
        let salt = try mark(h, "Salt Road", itemId: "B0SALTROAD")
        await h.model.start()
        let file = try #require(try h.fileURLs(salt).first)
        h.model.open(salt)
        h.model.listen(salt)
        await h.model.settle()
        #expect(h.opener.opened.map(\.lastPathComponent) == [file.lastPathComponent, file.lastPathComponent])
        #expect(h.opener.openedWeb.isEmpty)
    }

    /// R4: a file here comes first. An ebook that is also on Audible opens its ebook
    /// file (double-click, Return, Open); Listen goes to Audible; Read reads the file.
    @Test func R4_anEbookThatIsOnAudibleOpensItsFileAndListensOnAudible() async throws {
        let h = try await Harness.demo(start: false)
        let rivers = try mark(h, "Quiet Rivers", itemId: "B0QUIETRIV")
        await h.model.start()
        h.model.open(rivers)
        await h.model.settle()
        #expect(h.opener.openedWeb.isEmpty)
        #expect(h.opener.opened.map(\.pathExtension) == ["epub"])
        h.model.listen(rivers)
        await h.model.settle()
        #expect(h.opener.openedWeb == [try #require(URL(string: "https://www.audible.co.uk/pd/B0QUIETRIV"))])
        #expect(h.opener.opened.count == 1)
        h.model.read(rivers)
        await h.model.settle()
        #expect(h.opener.opened.map(\.pathExtension) == ["epub", "epub"])
        #expect(h.opener.openedWeb.count == 1)
        #expect(h.model.alert == nil)
        // The Listen button says where it goes.
        #expect(try row(h, rivers).listenTitle == "Open on Audible")
    }

    /// R4: reading is as it was: there is no ebook.
    @Test func R4_readingABookWithNoFilesSaysThereIsNoEbook() async throws {
        let (h, glass) = try await demoWithGlassTide()
        h.model.read(glass)
        await h.model.settle()
        #expect(h.model.alert == "This book has no ebook file.")
        #expect(h.opener.openedWeb.isEmpty)
        #expect(h.opener.opened.isEmpty)
    }

    /// R4: owned somewhere as an ebook only (not offered yet): there is nothing to open.
    @Test func R4_aBookWithNoFilesAndNoAudioCopyHasNothingToOpen() async throws {
        let (h, glass) = try await demoWithGlassTide(copy: ExternalCopy(kind: .audible, form: .ebook, store: "uk"))
        h.model.open(glass)
        await h.model.settle()
        #expect(h.model.alert == "This book has no files on this Mac.")
        h.model.alert = nil
        h.model.listen(glass)
        await h.model.settle()
        #expect(h.model.alert == "This book has no files on this Mac.")
        #expect(h.opener.openedWeb.isEmpty)
        #expect(h.opener.opened.isEmpty)
    }

    // MARK: R5 Commands

    /// R5
    @Test func R5_commandsForBooksWithNoFiles() async throws {
        let (h, glass) = try await demoWithGlassTide()
        let only = h.model.commands(for: [glass])
        #expect(only.open)
        #expect(only.listen)
        #expect(!only.read)
        #expect(!only.reveal)
        #expect(!only.rewriteTags)
        #expect(only.mark)
        #expect(only.remove)

        let salt = try h.id("Salt Road")
        let mixed = h.model.commands(for: [glass, salt])
        #expect(mixed.reveal)
        #expect(mixed.rewriteTags)
        #expect(!mixed.listen)

        let local = h.model.commands(for: [salt])
        #expect(local.reveal)
        #expect(local.rewriteTags)
        #expect(local.listen)

        // The Book menu follows the selection.
        h.model.click(glass, modifiers: [])
        await h.model.settle()
        #expect(h.model.selectionCommands == only)
    }

    /// R5: revealing or rewriting a book with no files, asked for anyway, does nothing.
    @Test func R5_revealingAndRewritingABookWithNoFilesDoesNothing() async throws {
        let (h, glass) = try await demoWithGlassTide()
        h.model.reveal([glass])
        await h.model.settle()
        #expect(h.opener.revealed.isEmpty)
        await h.model.rewriteTags(for: [glass])
        #expect(h.model.alert == nil)
        #expect(h.model.result == nil)
        #expect(h.model.undoLabel == Harness.demoUndoLabel)
    }

    // MARK: R6 Removing

    private func withATrash(_ h: Harness) throws -> () -> [String] {
        let trash = try makeTempDir()
        h.model.trashItem = { url in
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent))
        }
        return { (try? FileManager.default.contentsOfDirectory(atPath: trash.path).sorted()) ?? [] }
    }

    /// R6
    @Test func R6_removingABookWithNoFilesOffersOneButton() async throws {
        let h = try await Harness.demo(start: false)
        let trashed = try withATrash(h)
        let added = try LibraryService(store: try h.store()).addExternalBook(
            metadata: glassTide(), cover: nil,
            copy: ExternalCopy(kind: .audible, form: .audio, store: "uk", itemId: glassASIN))
        guard case .added(let glass) = added else { return }
        await h.model.start()

        h.model.requestRemove([glass])
        let prompt = try #require(h.model.prompt)
        #expect(prompt == .removeBooks(ids: [glass], titles: ["The Glass Tide"], outsideFiles: [], withoutFiles: 1))
        #expect(prompt.title == "Remove “The Glass Tide” from the library?")
        #expect(prompt.message == "This book has no files on this Mac, so nothing goes to the Trash.")
        #expect(prompt.removeTrashTitle == nil)
        #expect(prompt.removeOnlyTitle == "Remove from Library")

        // Whatever the answer says about the Trash, there is nothing to send there.
        await h.model.confirmRemove(moveFilesToTrash: true)
        #expect(h.model.prompt == nil)
        #expect(try h.store().book(id: glass) == nil)
        #expect(trashed().isEmpty)
        #expect(h.model.result == nil)
        #expect(h.model.alert == nil)
        #expect(h.model.sidebar.counts[.onAudible] == 0)
    }

    /// R6: the words for several.
    @Test func R6_theQuestionForSeveralBooksWithNoFiles() {
        let several = PendingPrompt.removeBooks(ids: [1, 2], titles: ["A", "B"], outsideFiles: [], withoutFiles: 2)
        #expect(several.title == "Remove 2 books from the library?")
        #expect(several.message == "These books have no files on this Mac, so nothing goes to the Trash.")
        #expect(several.removeTrashTitle == nil)
        #expect(several.removeOnlyTitle == "Remove from Library")

        let local = PendingPrompt.removeBooks(ids: [1, 2], titles: ["A", "B"])
        #expect(local.removeTrashTitle == "Move Files to Trash")
        #expect(local.removeOnlyTitle == "Remove from Library Only")
        #expect(local.message == "You can move the files to the Trash as well, or leave them where they are.")
        #expect(PendingPrompt.unsavedChanges.removeTrashTitle == nil)
        #expect(PendingPrompt.unsavedChanges.removeOnlyTitle == nil)

        let oneOfThree = PendingPrompt.removeBooks(
            ids: [1, 2, 3], titles: ["A", "B", "C"], outsideFiles: [], withoutFiles: 1)
        #expect(oneOfThree.removeTrashTitle == "Move Files to Trash")
        #expect(oneOfThree.removeOnlyTitle == "Remove from Library Only")
        #expect(
            oneOfThree.message
                == "You can move the files to the Trash as well, or leave them where they are. "
                + "1 of the 3 books has no files on this Mac and is only removed from the library.")
        let twoOfThree = PendingPrompt.removeBooks(
            ids: [1, 2, 3], titles: ["A", "B", "C"], outsideFiles: ["/elsewhere/c.m4b"], withoutFiles: 2)
        #expect(
            twoOfThree.message.hasPrefix(
                "You can move the files to the Trash as well, or leave them where they are. "
                    + "2 of the 3 books have no files on this Mac and are only removed from the library.\n\n"))
        #expect(twoOfThree.message.hasSuffix("/elsewhere/c.m4b"))
    }

    /// R6: a mixed selection asks as before; the Trash is for the books that have files.
    @Test func R6_aMixedSelectionTrashesOnlyTheFilesThereAre() async throws {
        let h = try await Harness.demo(start: false)
        let trashed = try withATrash(h)
        let added = try LibraryService(store: try h.store()).addExternalBook(
            metadata: glassTide(), cover: nil,
            copy: ExternalCopy(kind: .audible, form: .audio, store: "uk", itemId: glassASIN))
        guard case .added(let glass) = added else { return }
        await h.model.start()
        let salt = try h.id("Salt Road")
        let files = try h.fileURLs(salt)

        h.model.requestRemove([glass, salt])
        let prompt = try #require(h.model.prompt)
        guard case .removeBooks(let ids, _, _, let withoutFiles) = prompt else {
            Issue.record("not the remove question")
            return
        }
        #expect(Set(ids) == [glass, salt])
        #expect(withoutFiles == 1)
        #expect(prompt.removeTrashTitle == "Move Files to Trash")
        #expect(prompt.message.contains("1 of the 2 books has no files on this Mac"))

        await h.model.confirmRemove(moveFilesToTrash: true)
        #expect(try h.store().book(id: glass) == nil)
        #expect(try h.store().book(id: salt) == nil)
        #expect(trashed() == files.map(\.lastPathComponent).sorted())
        #expect(h.model.result == nil)
    }

    // MARK: R7 Inspector

    /// R7
    @Test func R7_theInspectorOfABookWithNoFiles() async throws {
        let (h, glass) = try await demoWithGlassTide()
        // Whatever the entry says, a book with no files has no file that "cannot hold" a field.
        var book = try h.book(glass)
        book.appOnlyFields = [.title, .narrators]
        book.needsAttention = true
        book.authors = []
        try h.store().update(book)
        await h.model.retryLibrary()

        h.model.click(glass, modifiers: [])
        await h.model.settle()
        let detail = try #require(h.detail)
        #expect(!detail.row.hasFiles)
        #expect(h.model.appOnlyMarkers.isEmpty)
        #expect(detail.attentionReasons.isEmpty)
        #expect(!detail.showsRewriteTags)
        #expect(h.model.inspectorOwnershipText == "On Audible (United Kingdom) · not on this Mac")
        #expect(h.model.inspectorIsOnAudible)
    }

    /// R7: a book with files: marked, and not.
    @Test func R7_ownershipOfBooksWithFiles() async throws {
        let h = try await Harness.demo(start: false)
        let salt = try mark(h, "Salt Road", store: "au")
        let rivers = try mark(h, "Quiet Rivers", store: nil)
        await h.model.start()

        h.model.click(salt, modifiers: [])
        await h.model.settle()
        #expect(h.model.inspectorOwnershipText == "On Audible (Australia)")
        #expect(h.model.inspectorIsOnAudible)

        // No store named: none is claimed.
        h.model.click(rivers, modifiers: [])
        await h.model.settle()
        #expect(h.model.inspectorOwnershipText == "On Audible")
        #expect(h.model.inspectorIsOnAudible)

        try await h.select("The Drowned Bell")
        #expect(h.model.inspectorOwnershipText == nil)
        #expect(!h.model.inspectorIsOnAudible)

        // Several books, or none: nothing to say.
        try await h.select(["Salt Road", "Quiet Rivers"])
        #expect(h.model.inspectorOwnershipText == nil)
        #expect(!h.model.inspectorIsOnAudible)
        h.model.select([])
        await h.model.settle()
        #expect(h.model.inspectorOwnershipText == nil)
    }

    /// R7: the words, without a library.
    @Test func R7_ownershipTextOfADetail() {
        func detail(_ copies: [ExternalCopy], files: Bool) -> BookDetail {
            var book = Book(metadata: BookMetadata(title: "Atlas", authors: ["Ann Author"]))
            book.id = 1
            book.externalCopies = copies
            return BookDetail(
                row: BookRow(
                    id: 1, book: book, hasAudio: true, hasEbook: false, formats: files ? [.m4b] : [], coverURL: nil,
                    hasWriteProblem: false, hasFiles: files),
                files: [], chapterCount: 0, collectionIds: [])
        }
        let uk = ExternalCopy(kind: .audible, form: .audio, store: "uk", itemId: "B000000001")
        #expect(detail([uk], files: false).ownershipText == "On Audible (United Kingdom) · not on this Mac")
        #expect(detail([uk], files: true).ownershipText == "On Audible (United Kingdom)")
        #expect(
            detail([ExternalCopy(kind: .audible, form: .audio, store: "atlantis")], files: false).ownershipText
                == "On Audible · not on this Mac")
        #expect(detail([], files: true).ownershipText == nil)
    }

    // MARK: R8 Marking

    /// R8
    @Test func R8_markingAddsAnAudibleCopyFromTheSettingAndTheBooksASIN() async throws {
        let h = try await Harness.demo(start: false)
        var salt = try h.book(try h.id("Salt Road"))
        salt.asin = "B0SALTROAD"
        try h.store().update(salt)
        await h.model.start()
        h.model.audibleStore = .ca
        let saltId = try h.id("Salt Road")
        let rivers = try h.id("Quiet Rivers")
        let files = try h.fileURLs(saltId)
        let modified = try files.map { try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        h.recordBusyLabels()

        await h.model.setOnAudible(true, for: [saltId, rivers])
        #expect(h.busyLabels == ["Updating…"])
        #expect(h.model.busyLabel == nil)
        #expect(h.model.alert == nil)
        #expect(
            try h.book(saltId).externalCopies
                == [ExternalCopy(kind: .audible, form: .audio, store: "ca", itemId: "B0SALTROAD")])
        #expect(try h.book(rivers).externalCopies == [ExternalCopy(kind: .audible, form: .audio, store: "ca")])
        // Shown at once.
        #expect(h.model.sidebar.counts[.onAudible] == 2)
        #expect(try row(h, saltId).isOnAudible)
        #expect(try row(h, rivers).hasAudio)
        // Not an operation to undo, and no file is touched.
        #expect(h.model.undoLabel == Harness.demoUndoLabel)
        #expect(try h.fileURLs(saltId) == files)
        #expect(
            try files.map { try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
                == modified)

        // A book that is marked already is left exactly as it is.
        h.model.audibleStore = .jp
        await h.model.setOnAudible(true, for: [saltId])
        #expect(
            try h.book(saltId).externalCopies
                == [ExternalCopy(kind: .audible, form: .audio, store: "ca", itemId: "B0SALTROAD")])

        // Off again, for a book with files.
        await h.model.setOnAudible(false, for: [saltId, rivers])
        #expect(try h.book(saltId).externalCopies.isEmpty)
        #expect(try h.book(rivers).externalCopies.isEmpty)
        #expect(h.model.sidebar.counts[.onAudible] == 0)
        #expect(h.model.alert == nil)
        // The ASIN is the book's own, and stays.
        #expect(try h.book(saltId).asin == "B0SALTROAD")

        await h.model.setOnAudible(true, for: [])
        #expect(h.busyLabels.count == 3)
    }

    /// R8: a book with no files would vanish.
    @Test func R8_unmarkingABookWithNoFilesIsRefusedInPlainWords() async throws {
        let (h, glass) = try await demoWithGlassTide()
        let before = try h.book(glass)
        await h.model.setOnAudible(false, for: [glass])
        #expect(
            h.model.alert
                == "“The Glass Tide” has no files, so it would vanish from the library. Remove it instead.")
        #expect(try h.book(glass) == before)
        #expect(h.model.sidebar.counts[.onAudible] == 1)

        // With others: they are unmarked, and the one that cannot be is named.
        h.model.alert = nil
        let salt = try mark(h, "Salt Road")
        await h.model.retryLibrary()
        await h.model.setOnAudible(false, for: [glass, salt])
        #expect(
            h.model.alert
                == "“The Glass Tide” has no files, so it would vanish from the library. Remove it instead.")
        #expect(try h.book(salt).externalCopies.isEmpty)
        #expect(try h.book(glass) == before)
    }

    /// R8: several that would vanish are counted.
    @Test func R8_severalBooksThatWouldVanishAreCounted() async throws {
        let (h, glass) = try await demoWithGlassTide()
        let other = try LibraryService(store: try h.store()).addExternalBook(
            metadata: BookMetadata(title: "Another Tide", authors: ["Ines Calloway"]), cover: nil,
            copy: ExternalCopy(kind: .audible, form: .audio, store: "uk"))
        guard case .added(let second) = other else { return }
        await h.model.retryLibrary()
        await h.model.setOnAudible(false, for: [glass, second])
        #expect(
            h.model.alert
                == "2 books have no files, so they would vanish from the library. Remove them instead.")
        #expect(h.model.sidebar.counts[.onAudible] == 2)
    }

    /// R8: applied at once, and unsaved edits stay (as for read status).
    @Test func R8_markingKeepsUnsavedEdits() async throws {
        let h = try await Harness.demo()
        let id = try await h.edit("Salt Road", newTitle: "Salt Roads")
        await h.model.setOnAudible(true, for: [id])
        #expect(try h.book(id).isOwned(on: .audible))
        #expect(try h.book(id).title == "Salt Road")
        #expect(h.draft?.title == "Salt Roads")
        #expect(h.model.hasUnsavedChanges)
        #expect(h.detail?.row.isOnAudible == true)
        #expect(h.model.inspectorIsOnAudible)
        #expect(h.model.selection == [id])

        // Saving afterwards keeps the mark.
        await h.model.save()
        #expect(try h.book(id).title == "Salt Roads")
        #expect(try h.book(id).isOwned(on: .audible))
    }

    /// R8: the menu item, for the selection and for a context menu's books.
    @Test func R8_theMenuItemSaysWhatItWillDo() async throws {
        let (h, glass) = try await demoWithGlassTide()
        let salt = try h.id("Salt Road")
        #expect(!h.model.canMarkOnAudible)
        #expect(h.model.markOnAudibleTitle == "Mark as on Audible")

        h.model.click(salt, modifiers: [])
        await h.model.settle()
        #expect(h.model.canMarkOnAudible)
        #expect(h.model.markOnAudibleTitle == "Mark as on Audible")
        #expect(h.model.markOnAudibleTitle(for: [glass]) == "Unmark as on Audible")
        // Some are, some are not: marking is what is offered.
        #expect(h.model.markOnAudibleTitle(for: [glass, salt]) == "Mark as on Audible")

        await h.model.toggleOnAudible()
        #expect(try h.book(salt).isOwned(on: .audible))
        #expect(h.model.markOnAudibleTitle == "Unmark as on Audible")
        #expect(h.model.markOnAudibleTitle(for: [glass, salt]) == "Unmark as on Audible")
        await h.model.toggleOnAudible(for: [salt])
        #expect(try !h.book(salt).isOwned(on: .audible))

        // Not while something runs.
        let gate = Gate()
        h.model.beforeOperation = { await gate.wait() }
        let running = Task { await h.model.setOnAudible(true, for: [salt]) }
        await gate.arrival()
        #expect(!h.model.canMarkOnAudible)
        #expect(!h.model.canMarkOnAudible(for: [glass]))
        await gate.release()
        await running.value
        #expect(h.model.canMarkOnAudible)
    }

    // MARK: R9 Importing the files of a book that is on Audible

    /// R9
    @Test func R9_filesOfABookOnAudibleAreOfferedToItsEntry() async throws {
        let h = try Harness(root: try makeTempDir())
        let service = LibraryService(store: try h.store())
        var metadata = BookMetadata(title: "The Lighthouse Keeper", authors: ["Eleanor Marsh"])
        metadata.series = "Rocks"
        metadata.seriesNumber = "2"
        let added = try service.addExternalBook(
            metadata: metadata, cover: nil, copy: ExternalCopy(kind: .audible, form: .audio, store: "uk"))
        guard case .added(let keeper) = added else { return }
        await h.model.start()
        let inbox = try Harness.inbox()

        await h.model.beginImport([inbox.appendingPathComponent("The Lighthouse Keeper.m4b")])
        await h.model.settle()
        let review = try #require(h.model.review)
        let entry = try #require(review.entries.first)
        #expect(entry.existingMatch?.id == keeper)
        #expect(entry.isAddedToExisting)
        #expect(entry.existingMatchText == "Add to “The Lighthouse Keeper”, which is on Audible")
        // The folder the book will be filed in, from the book's own details (its series), not the file's.
        let planned = try #require(service.plannedFolder(for: try h.book(keeper).metadata))
        #expect(planned.contains("Rocks"))
        #expect(entry.destination == planned)
        #expect(review.destinationText(of: entry.id) == "Will be filed in: \(planned)")
        #expect(review.entriesNeedingMatchDestination.isEmpty)
        #expect(review.canImport)

        // As a book of its own it goes where its own details say.
        h.model.updateReview { $0.update(entry.id) { $0.addToExisting = false } }
        await h.model.settle()
        let apart = try #require(h.model.review?.entry(entry.id))
        #expect(apart.destination == service.plannedFolder(for: apart.candidate.metadata))
        #expect(apart.destination != planned)
        h.model.updateReview { $0.update(entry.id) { $0.addToExisting = true } }
        await h.model.settle()
        #expect(h.model.review?.entry(entry.id)?.destination == planned)

        await h.model.confirmImport()
        #expect(h.model.result == nil)
        #expect(h.model.alert == nil)
        let book = try h.book(keeper)
        #expect(book.folderPath == planned)
        #expect(book.isOwned(on: .audible))
        #expect(try h.fileURLs(keeper).count == 1)
        #expect(try h.store().books().count == 1)
        let row = try row(h, keeper)
        #expect(row.hasFiles)
        #expect(row.whereaboutsText == "Also on Audible")
    }

    /// R9: a book typed by hand, with no author, takes what it lacks from its files: the
    /// review says where it will go and that nothing the files say is lost, and the
    /// import does as it says.
    @Test func R9_aBookTypedByHandIsFilledInFromItsFiles() async throws {
        let h = try Harness(root: try makeTempDir())
        let service = LibraryService(store: try h.store())
        let added = try service.addExternalBook(
            metadata: BookMetadata(title: "The Lighthouse Keeper", authors: ["Eleanor Marsh"]), cover: nil,
            copy: ExternalCopy(kind: .audible, form: .audio, store: "uk"))
        guard case .added(let keeper) = added else { return }
        await h.model.start()
        let inbox = try Harness.inbox()
        let file = inbox.appendingPathComponent("The Lighthouse Keeper.m4b")
        var inFile = try FileMetadataIO().readMetadata(at: file)
        inFile.durationSeconds = nil
        #expect(!inFile.narrators.isEmpty)

        await h.model.beginImport([file])
        await h.model.settle()
        let review = try #require(h.model.review)
        let entry = try #require(review.entries.first)
        #expect(entry.existingMatch?.id == keeper)
        #expect(entry.existingMatchText == "Add to “The Lighthouse Keeper”, which is on Audible")
        #expect(
            review.keptDetailsNote(of: entry.id)
                == "These files join “The Lighthouse Keeper”, which keeps its own details. "
                + "What it lacks is filled in from the files, and nothing in them is lost.")
        // Where it will go is worked out with what the files add.
        let planned = try #require(
            service.plannedFolder(for: try h.book(keeper).metadata, firstFiles: entry.candidate.files))
        #expect(entry.destination == planned)
        #expect(review.destinationText(of: entry.id) == "Will be filed in: \(planned)")

        await h.model.confirmImport()
        #expect(h.model.result == nil)
        #expect(h.model.alert == nil)
        let book = try h.book(keeper)
        #expect(book.folderPath == planned)
        #expect(book.narrators == inFile.narrators)
        #expect(book.isOwned(on: .audible))
        // The file says all it said before.
        var after = try FileMetadataIO().readMetadata(at: try #require(try h.fileURLs(keeper).first))
        after.durationSeconds = nil
        #expect(after == inFile)
    }

    /// R9: an entry whose details are changed is matched again: by title and first
    /// author, or by the Audible ID alone, whatever its title.
    @Test func R9_changedDetailsFindTheBookOnAudible() async throws {
        let (h, glass) = try await demoWithGlassTide()
        let inbox = try Harness.inbox()
        await h.model.beginImport([inbox.appendingPathComponent("The Lighthouse Keeper.m4b")])
        await h.model.settle()
        let entry = try #require(h.model.review?.entries.first)
        let keeper = try h.id("The Lighthouse Keeper")
        #expect(entry.existingMatch?.id == keeper)
        #expect(entry.existingMatchText == "Add to the existing book \"The Lighthouse Keeper\"")
        #expect(entry.destination == (try h.book(keeper).folderPath))

        h.model.updateReview {
            $0.setText("The Glass Tide", for: .title, of: entry.id)
            $0.setText("Ines Calloway", for: .authors, of: entry.id)
        }
        await h.model.settle()
        let changed = try #require(h.model.review?.entry(entry.id))
        #expect(changed.existingMatch?.id == glass)
        #expect(changed.existingMatchText == "Add to “The Glass Tide”, which is on Audible")
        let planned = LibraryService(store: try h.store()).plannedFolder(for: try h.book(glass).metadata)
        #expect(planned != nil)
        #expect(changed.destination == planned)

        // Back to a title the library has as files, and then only the Audible ID.
        h.model.updateReview {
            $0.setText("The Lighthouse Keeper", for: .title, of: entry.id)
            $0.setText("Eleanor Marsh", for: .authors, of: entry.id)
        }
        await h.model.settle()
        #expect(h.model.review?.entry(entry.id)?.existingMatch?.id == keeper)
        h.model.updateReview { $0.update(entry.id) { $0.candidate.metadata.asin = " b0glasstid " } }
        await h.model.settle()
        let byId = try #require(h.model.review?.entry(entry.id))
        #expect(byId.existingMatch?.id == glass)
        #expect(byId.destination == planned)
    }

    // MARK: R10 Nothing to show

    /// R10
    @Test func R10_onAudibleWithNoBooksSaysHowToAddOne() async throws {
        let h = try await Harness.demo()
        h.model.sidebarSelection = .onAudible
        await h.model.settle()
        #expect(h.model.emptyState == .noAudibleBooks)
        #expect(h.model.booksContent == .empty(.noAudibleBooks))
        #expect(EmptyState.noAudibleBooks.title == "No Audible books yet")
        #expect(EmptyState.noAudibleBooks.message == "Choose Book ▸ Add Audible Book…")

        // In a library with nothing in it at all, too.
        let empty = try await Harness.empty()
        #expect(empty.model.emptyState == .emptyLibrary)
        empty.model.sidebarSelection = .onAudible
        await empty.model.settle()
        #expect(empty.model.emptyState == .noAudibleBooks)
    }

    /// R10: with Audible books, a search that finds none says so as anywhere else.
    @Test func R10_aSearchThatFindsNoneIsNoMatches() async throws {
        let (h, _) = try await demoWithGlassTide()
        h.model.sidebarSelection = .onAudible
        await h.model.settle()
        #expect(h.model.emptyState == nil)
        h.model.searchText = "zzzz"
        await h.model.settle()
        #expect(h.model.emptyState == .noMatches)
    }
}

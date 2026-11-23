import Foundation
import Testing
import VoxCarrelCore
import VoxCarrelFixtures

@testable import VoxCarrelAppCore

/// MG1–MG7: merging entries that are one book, in the app model.
@MainActor
@Suite struct AppModelMergeTests {
    typealias L = MergeLibrary

    /// An ebook "Dune" and a PDF "Dune Notes", both by Frank Herbert.
    private func ebookAndNotes() async throws -> (h: Harness, ebook: Int64, notes: Int64) {
        let (h, books) = try await Harness.merging { library in
            (try library.epub("Dune", "Frank Herbert"), try library.pdf("Dune Notes", "Frank Herbert"))
        }
        return (h, books.0, books.1)
    }

    /// The same with the merge sheet open on the two.
    private func merging() async throws -> (h: Harness, ebook: Int64, notes: Int64) {
        let (h, ebook, notes) = try await ebookAndNotes()
        await h.select(ids: [ebook, notes])
        await h.model.beginMergeBooks()
        #expect(h.model.mergeSheet != nil)
        return (h, ebook, notes)
    }

    private func bookIds(_ h: Harness) throws -> [Int64] {
        try h.store().books().compactMap(\.id).sorted()
    }

    // MARK: MG1 Whether books can be merged

    @Test func mg1_twoOrMoreSelectedLibraryBooksCanBeMerged() async throws {
        let (h, ebook, notes) = try await ebookAndNotes()
        #expect(!h.model.canMergeBooks)

        await h.select(ids: [ebook])
        #expect(!h.model.canMergeBooks)
        // A context menu may be for books other than the selection.
        #expect(h.model.canMergeBooks([ebook, notes]))
        #expect(!h.model.canMergeBooks([]))

        await h.select(ids: [ebook, notes])
        #expect(h.model.canMergeBooks)
    }

    @Test func mg1_notWithARowForABookTheLibraryDoesNotHave() async throws {
        let (h, ebook, notes) = try await ebookAndNotes()
        #expect(!h.model.canMergeBooks([ebook, -3]))
        #expect(!h.model.canMergeBooks([ebook, notes, 0]))
        h.recordBusyLabels()

        await h.model.beginMergeBooks(for: [ebook, -3])

        #expect(h.model.mergeSheet == nil)
        #expect(h.busyLabels.isEmpty)
        #expect(h.model.worker?.strayIds.withLock { $0 } == [])
    }

    @Test func mg1_notWithoutALibrary() async throws {
        let h = try Harness(root: try makeTempDir(), choose: false)
        await h.model.start()
        #expect(!h.model.canMergeBooks([1, 2]))
        await h.model.beginMergeBooks(for: [1, 2])
        #expect(h.model.mergeSheet == nil)
    }

    @Test func mg1_notWhileAnOperationASheetAQuestionUnsavedEditsOrAnUnresolvedLayoutChangeIsInTheWay() async throws {
        let (h, ebook, notes) = try await ebookAndNotes()
        await h.select(ids: [ebook, notes])
        #expect(h.model.canMergeBooks)

        h.model.busyLabel = "Working…"
        #expect(!h.model.canMergeBooks)
        h.model.busyLabel = nil

        h.model.result = ResultSummary(headline: "Done", problems: [], isClean: false)
        #expect(!h.model.canMergeBooks)
        h.model.result = nil

        h.model.prompt = .stopLayoutRecovery
        #expect(!h.model.canMergeBooks)
        h.model.prompt = nil

        h.model.layoutChangeIsUnresolved = true
        #expect(!h.model.canMergeBooks)
        h.model.layoutChangeIsUnresolved = false

        h.model.chooseLayout(AppModelLayoutTests.authorTitle)
        await h.model.previewLayoutChange()
        #expect(h.model.layoutPreview != nil)
        #expect(!h.model.canMergeBooks)
        h.model.cancelLayoutChange()

        await h.model.beginImport([try Harness.inbox()])
        #expect(h.model.review != nil)
        #expect(!h.model.canMergeBooks)
        h.model.cancelImport()

        // Unsaved edits: the merge would take the edited books away.
        h.model.setBulkText("Science Fiction", for: .genre)
        #expect(h.model.hasUnsavedChanges)
        #expect(!h.model.canMergeBooks)
        h.recordBusyLabels()
        await h.model.beginMergeBooks()
        #expect(h.model.mergeSheet == nil)
        #expect(h.busyLabels.isEmpty)
        h.model.discardChanges()

        #expect(h.model.canMergeBooks)
        await h.model.beginMergeBooks()
        // The sheet that is open is itself in the way of another.
        #expect(h.model.mergeSheet != nil)
        #expect(!h.model.canMergeBooks)
    }

    // MARK: MG2 Beginning

    @Test func mg2_beginningPlansOnTheWorkerAndFillsTheSheet() async throws {
        let (h, books) = try await Harness.merging { try $0.ownersCase() }
        await h.select(ids: [books.audio, books.pdf, books.companion])
        let before = h.libraryFiles()
        h.recordBusyLabels()

        await h.model.beginMergeBooks()

        #expect(h.busyLabels == ["Reading the books…"])
        #expect(h.model.busyLabel == nil)
        #expect(h.model.alert == nil)
        let sheet = try #require(h.model.mergeSheet)
        // In the order the rows show them, with the one that has the audio kept.
        #expect(sheet.entries.map(\.id) == h.model.rows.map(\.id))
        #expect(Set(sheet.entries.map(\.id)) == [books.audio, books.pdf, books.companion])
        #expect(sheet.entries.filter(\.isKept).map(\.id) == [books.audio])
        let audio = try #require(sheet.entries.first { $0.id == books.audio })
        #expect(audio.title == L.title)
        #expect(audio.author == L.author)
        #expect(audio.contents == "Audiobook, 1 file")
        #expect(sheet.entries.first { $0.id == books.pdf }?.contents == "Ebook, 1 file")
        // The kept entry's files first.
        #expect(sheet.files.map(\.role) == [.audio, .ebook, .extra])
        #expect(sheet.files.map(\.name) == ["\(L.title) (Unabridged).m4b", "\(L.title).pdf", "\(L.companion).pdf"])
        #expect(sheet.files.map(\.entryTitle) == [L.title, L.title, L.companion])
        #expect(sheet.files.map(\.allowedRoles) == [[.audio], [.ebook, .extra], [.ebook, .extra]])
        // The companion was its own entry's ebook: the guess is not a change the owner made.
        #expect(sheet.files.map(\.isChanged) == [false, false, false])
        #expect(sheet.blockers.isEmpty)
        #expect(sheet.summary == "2 files will move into “\(L.title)”. 2 entries will be removed. "
            + "The book will be filed in “\(L.folder)”.")
        #expect(!sheet.willNeedAttention)
        #expect(sheet.canMerge)
        #expect(sheet.canChange)
        #expect(sheet.busyText == nil)
        // Planning changes nothing.
        #expect(h.libraryFiles() == before)
        #expect(try bookIds(h) == [books.audio, books.pdf, books.companion].sorted())
        #expect(h.model.undoLabel != "Merge Books")
    }

    @Test func mg2_eachBlockerIsOnePlainSentenceAndStopsTheMerge() async throws {
        let (h, books) = try await Harness.merging { library in
            (try library.audiobook("Dune"), try library.audiobook("Dune (Abridged)"))
        }
        await h.select(ids: [books.0, books.1])
        await h.model.beginMergeBooks()

        let sheet = try #require(h.model.mergeSheet)
        #expect(sheet.blockers == [
            "“Dune” and “Dune (Abridged)” both have audiobook files, so they are treated as two editions "
                + "and cannot be merged.",
        ])
        #expect(!sheet.canMerge)
        h.recordBusyLabels()
        await h.model.confirmMerge()
        #expect(h.busyLabels.isEmpty)
        #expect(try bookIds(h) == [books.0, books.1].sorted())
    }

    @Test func mg2_blockersAreWordedAsSentences() {
        let titles: [Int64: String] = [1: "A", 2: "B", 3: ""]
        #expect(MergeText.blocker(.bothHaveAudio([1, 2]), titles: titles)
            == "“A” and “B” both have audiobook files, so they are treated as two editions and cannot be merged.")
        #expect(MergeText.blocker(.bothHaveAudio([1, 2, 3]), titles: titles)
            == "“A”, “B” and “Untitled book” all have audiobook files, so they are treated as separate editions "
            + "and cannot be merged.")
        #expect(MergeText.blocker(.needsTwoBooks, titles: titles)
            == "Merging needs two or more entries that are in the library.")
        #expect(MergeText.blocker(.fileMissing("a.pdf"), titles: titles)
            == "The file \"a.pdf\" could not be found, so it cannot be moved.")
        #expect(MergeText.blocker(.nameClash("a.pdf"), titles: titles)
            == "Something else is already where \"a.pdf\" would go, and nothing is ever replaced.")
    }

    @Test func mg2_theSummaryCountsInTheSingularAndThePluralAndSaysWhereTheBookWillBe() {
        func summary(_ incoming: Int, _ removed: Int, folder: String? = "Ann/Atlas", _ attention: MergeAttention? = nil) -> String {
            MergeText.summary(incoming: incoming, title: "Atlas", removed: removed, folder: folder, attention: attention)
        }
        #expect(summary(1, 1) == "1 file will move into “Atlas”. 1 entry will be removed. The book will be filed in “Ann/Atlas”.")
        #expect(summary(3, 2) == "3 files will move into “Atlas”. 2 entries will be removed. The book will be filed in “Ann/Atlas”.")
        #expect(summary(0, 1, folder: nil) == "No files need to move into “Atlas”. 1 entry will be removed.")
        #expect(MergeText.summary(incoming: 1, title: " ", removed: 1, folder: nil, attention: nil)
            == "1 file will move into “Untitled book”. 1 entry will be removed.")
        // The book will stay flagged: said plainly, with why.
        #expect(summary(1, 1, folder: "Ann/Old", .folderTaken)
            == "1 file will move into “Atlas”. 1 entry will be removed. Another book uses the folder this book "
            + "belongs in, so it will stay in “Ann/Old” and will still need attention.")
        #expect(summary(1, 1, folder: nil, .cannotBeFiled)
            == "1 file will move into “Atlas”. 1 entry will be removed. The folder layout cannot file this book "
            + "yet, so it will stay where it is and will still need attention.")
        #expect(summary(1, 1, folder: "Ann/Atlas", .fileMissing)
            == "1 file will move into “Atlas”. 1 entry will be removed. Some of this book's files are missing, "
            + "so it will stay in “Ann/Atlas” and will still need attention.")
        #expect(summary(0, 1, folder: nil, .asBefore)
            == "No files need to move into “Atlas”. 1 entry will be removed. The book will still need attention.")
    }

    @Test func mg2_theSummaryWarnsWhenAThirdBookHasTheFolder() async throws {
        let (h, books) = try await Harness.merging { try $0.ownersCase() }
        // The PDF entry is no part of this merge: the folder is still its own.
        await h.select(ids: [books.audio, books.companion])
        await h.model.beginMergeBooks()

        let sheet = try #require(h.model.mergeSheet)
        #expect(sheet.blockers.isEmpty)
        #expect(sheet.canMerge)
        #expect(sheet.willNeedAttention)
        #expect(sheet.summary == "1 file will move into “\(L.title)”. 1 entry will be removed. Another book uses "
            + "the folder this book belongs in, so it will stay in “\(L.audioFolder)” and will still need attention.")

        await h.model.confirmMerge()
        #expect(try h.book(books.audio).needsAttention)
        #expect(try h.book(books.audio).folderPath == L.audioFolder)
    }

    // MARK: MG3 Changing the plan

    @Test func mg3_choosingAnotherEntryToKeepPlansAgain() async throws {
        let (h, ebook, notes) = try await merging()
        var sheet = try #require(h.model.mergeSheet)
        #expect(sheet.entries.filter(\.isKept).map(\.id) == [ebook])
        #expect(sheet.files.map(\.name) == ["Dune.epub", "Dune Notes.pdf"])
        #expect(sheet.summary == "1 file will move into “Dune”. 1 entry will be removed. "
            + "The book will be filed in “Frank Herbert/Dune”.")
        h.recordBusyLabels()

        await h.model.setMergeKeep(notes)

        #expect(h.busyLabels == ["Reading the books…"])
        sheet = try #require(h.model.mergeSheet)
        #expect(sheet.entries.map(\.id) == [ebook, notes])
        #expect(sheet.entries.filter(\.isKept).map(\.id) == [notes])
        #expect(sheet.files.map(\.name) == ["Dune Notes.pdf", "Dune.epub"])
        #expect(sheet.summary == "1 file will move into “Dune Notes”. 1 entry will be removed. "
            + "The book will be filed in “Frank Herbert/Dune Notes”.")

        // An entry that is not one of them, or the one kept already, changes nothing.
        await h.model.setMergeKeep(9_999)
        await h.model.setMergeKeep(notes)
        #expect(h.busyLabels == ["Reading the books…"])
        #expect(h.model.mergeSheet == sheet)
        #expect(h.model.alert == nil)
    }

    @Test func mg3_aRoleTheOwnerSetsIsKeptAndTheGuessesItDoesNotOverrideFollow() async throws {
        let (h, books) = try await Harness.merging { library in
            (try library.epub("Dune", "Frank Herbert"), try library.pdf("Dune Text", "Frank Herbert"),
             try library.pdf("Dune Text Two", "Frank Herbert"))
        }
        await h.select(ids: [books.0, books.1, books.2])
        await h.model.beginMergeBooks()
        var sheet = try #require(h.model.mergeSheet)
        // The first PDF is taken for the ebook, so the second is an extra.
        #expect(sheet.files.map(\.name) == ["Dune.epub", "Dune Text.pdf", "Dune Text Two.pdf"])
        #expect(sheet.files.map(\.role) == [.ebook, .ebook, .extra])
        #expect(sheet.files.map(\.isChanged) == [false, false, false])
        let first = sheet.files[1].id
        let second = sheet.files[2].id
        h.recordBusyLabels()

        // Made an extra by the owner, the first PDF is no ebook: the second is guessed to be it.
        await h.model.setMergeRole(.extra, forFile: first)
        #expect(h.busyLabels == ["Reading the books…"])
        sheet = try #require(h.model.mergeSheet)
        #expect(sheet.files.map(\.role) == [.ebook, .extra, .ebook])
        #expect(sheet.files.map(\.isChanged) == [false, true, false])

        // The owner's choice for the second stays whatever is guessed for it later.
        await h.model.setMergeRole(.extra, forFile: second)
        sheet = try #require(h.model.mergeSheet)
        #expect(sheet.files.map(\.role) == [.ebook, .extra, .extra])
        #expect(sheet.files.map(\.isChanged) == [false, true, true])
        await h.model.setMergeRole(.ebook, forFile: first)
        sheet = try #require(h.model.mergeSheet)
        #expect(sheet.files.map(\.role) == [.ebook, .ebook, .extra])
        #expect(sheet.files.map(\.isChanged) == [false, false, false])

        // A role the file cannot have, and a file that is none of theirs, change nothing.
        let labels = h.busyLabels
        await h.model.setMergeRole(.audio, forFile: first)
        await h.model.setMergeRole(.extra, forFile: 9_999)
        #expect(h.busyLabels == labels)
        #expect(h.model.mergeSheet == sheet)
        #expect(h.model.alert == nil)

        // The roles chosen are the roles the merge is made with.
        await h.model.setMergeRole(.extra, forFile: first)
        await h.model.setMergeRole(.ebook, forFile: second)
        await h.model.confirmMerge()
        let files = try h.store().files(bookId: books.0)
        #expect(files.map(\.role) == [.ebook, .ebook, .extra])
        #expect(files.map { ($0.path as NSString).lastPathComponent } == ["Dune.epub", "Dune.pdf", "Dune Text.pdf"])
    }

    @Test func mg3_aRoleChangeCanBringABlockerAndTakeItAway() async throws {
        let (h, ebook, notes) = try await merging()
        _ = notes
        // The kept entry's own file is missing: it may stay so, unless it is asked to move.
        try FileManager.default.removeItem(at: try h.fileURLs(ebook)[0])
        await h.model.setMergeKeep(notes)
        await h.model.setMergeKeep(ebook)
        var sheet = try #require(h.model.mergeSheet)
        #expect(sheet.blockers.isEmpty)
        #expect(sheet.willNeedAttention)

        await h.model.setMergeRole(.extra, forFile: sheet.files[0].id)
        sheet = try #require(h.model.mergeSheet)
        #expect(sheet.blockers == ["The file \"Dune.epub\" could not be found, so it cannot be moved."])
        #expect(!sheet.canMerge)

        await h.model.setMergeRole(.ebook, forFile: sheet.files[0].id)
        sheet = try #require(h.model.mergeSheet)
        #expect(sheet.blockers.isEmpty)
        #expect(sheet.canMerge)
    }

    // MARK: MG4 Merging

    @Test func mg4_confirmingMergesSelectsTheKeptBookAndClosesTheSheet() async throws {
        let (h, ebook, notes) = try await merging()
        let before = h.libraryFiles()
        #expect(before == ["Frank Herbert/Dune Notes/Dune Notes.pdf", "Frank Herbert/Dune/Dune.epub"])
        h.recordBusyLabels()

        await h.model.confirmMerge()

        #expect(h.busyLabels == ["Merging books…"])
        #expect(h.model.busyLabel == nil)
        #expect(h.model.alert == nil)
        #expect(h.model.mergeSheet == nil)
        #expect(try bookIds(h) == [ebook])
        #expect(h.model.rows.map(\.id) == [ebook])
        #expect(h.model.selection == [ebook])
        #expect(h.detail?.row.id == ebook)
        #expect(h.detail?.files.map(\.name) == ["Dune.epub", "Dune.pdf"])
        #expect(h.libraryFiles() == ["Frank Herbert/Dune/Dune.epub", "Frank Herbert/Dune/Dune.pdf"])
        #expect(h.model.undoLabel == "Merge Books")
        #expect(h.model.undoMenuTitle == "Undo Merge Books")
        #expect(h.model.canUndo)

        await h.model.undo()
        #expect(try bookIds(h) == [ebook, notes].sorted())
        #expect(h.libraryFiles() == before)
    }

    @Test func mg4_theKeptBookIsSelectedWhenItWasNotTheOneKeptAtFirst() async throws {
        let (h, ebook, notes) = try await merging()
        _ = ebook
        await h.model.setMergeKeep(notes)
        await h.model.confirmMerge()
        #expect(try bookIds(h) == [notes])
        #expect(h.model.selection == [notes])
        #expect(h.detail?.row.id == notes)
        #expect(h.detail?.row.book.title == "Dune Notes")
    }

    @Test func mg4_theKeptBookIsSelectedThoughItWasNotSelectedBefore() async throws {
        let (h, books) = try await Harness.merging { try $0.ownersCase() }
        await h.select(ids: [books.audio])
        await h.model.beginMerge(with: books.pdf)
        await h.model.setMergeKeep(books.pdf)

        await h.model.confirmMerge()

        // The audiobook that was selected is gone; the book that took its files is selected.
        #expect(try bookIds(h) == [books.pdf, books.companion].sorted())
        #expect(h.model.selection == [books.pdf])
        #expect(h.detail?.row.id == books.pdf)
        #expect(h.detail?.files.map(\.file.role) == [.audio, .ebook])
    }

    @Test func mg4_aFailureChangesNothingAndShowsTheEnginesReason() async throws {
        let (h, ebook, notes) = try await merging()
        // Gone since the sheet was filled: the merge is refused when it is planned again.
        let lost = try h.fileURLs(notes)[0]
        let bytes = try Data(contentsOf: lost)
        try FileManager.default.removeItem(at: lost)
        let before = h.libraryFiles()
        let undo = h.model.undoLabel

        await h.model.confirmMerge()

        #expect(h.model.alert
            == "The file \"Dune Notes.pdf\" could not be found, so it cannot be moved. Nothing was changed.")
        #expect(h.model.busyLabel == nil)
        #expect(try bookIds(h) == [ebook, notes].sorted())
        #expect(h.libraryFiles() == before)
        #expect(h.model.undoLabel == undo)
        // The sheet stays, and now says what is in the way.
        var sheet = try #require(h.model.mergeSheet)
        #expect(sheet.blockers == ["The file \"Dune Notes.pdf\" could not be found, so it cannot be moved."])
        #expect(!sheet.canMerge)
        #expect(h.model.selection == [ebook, notes])

        // Put back, the merge can be made after all: any change plans again.
        h.model.alert = nil
        try bytes.write(to: lost)
        await h.model.setMergeKeep(notes)
        sheet = try #require(h.model.mergeSheet)
        #expect(sheet.canMerge)
        await h.model.confirmMerge()
        #expect(h.model.alert == nil)
        #expect(try bookIds(h) == [notes])
    }

    @Test func mg4_cancellingClosesTheSheetAndChangesNothing() async throws {
        let (h, ebook, notes) = try await merging()
        let before = h.libraryFiles()
        // Not in the middle of something.
        h.model.busyLabel = "Merging books…"
        #expect(h.model.mergeSheet?.busyText == "Merging books…")
        #expect(h.model.mergeSheet?.canMerge == false)
        #expect(h.model.mergeSheet?.canChange == false)
        h.model.cancelMerge()
        #expect(h.model.mergeSheet != nil)
        h.model.busyLabel = nil

        h.model.cancelMerge()
        #expect(h.model.mergeSheet == nil)
        #expect(try bookIds(h) == [ebook, notes].sorted())
        #expect(h.libraryFiles() == before)
        #expect(h.model.selection == [ebook, notes])
        #expect(h.model.canMergeBooks)
    }

    // MARK: MG5 The offer on a book whose folder is another book's

    /// The case that prompted merging.
    @Test func mg5_theOwnersCaseFromTheOfferToOneUnflaggedBook() async throws {
        let (h, books) = try await Harness.merging { try $0.ownersCase() }
        #expect(try h.book(books.audio).needsAttention)
        #expect(try h.book(books.audio).folderPath == L.audioFolder)
        #expect(h.libraryFiles() == [
            "\(L.audioFolder)/\(L.title) (Unabridged).m4b",
            "James Dalton/\(L.companion)/\(L.companion).pdf",
            "\(L.folder)/\(L.title).pdf",
        ].sorted())

        // The inspector on the audiobook says why it is flagged, and offers the merge.
        await h.select(ids: [books.audio])
        #expect(h.detail?.attentionReasons == ["Another book uses the folder this book belongs in."])
        let offer = try #require(h.model.mergeOffer)
        #expect(offer.bookId == books.pdf)
        #expect(offer.title == L.title)
        #expect(offer.actionTitle == "Merge with “\(L.title)”…")
        #expect(h.model.canAcceptMergeOffer)

        // Accepting opens the sheet for the two, keeping the one with audio.
        await h.model.beginMerge(with: offer.bookId)
        var sheet = try #require(h.model.mergeSheet)
        #expect(sheet.entries.map(\.id) == [books.audio, books.pdf])
        #expect(sheet.entries.filter(\.isKept).map(\.id) == [books.audio])
        #expect(sheet.files.map(\.role) == [.audio, .ebook])
        #expect(sheet.canMerge)
        #expect(!sheet.willNeedAttention)
        h.model.cancelMerge()
        #expect(h.model.mergeSheet == nil)

        // The third comes in through a selection of all three.
        await h.select(ids: [books.audio, books.pdf, books.companion])
        #expect(h.model.mergeOffer == nil)
        #expect(h.model.canMergeBooks)
        await h.model.beginMergeBooks()
        sheet = try #require(h.model.mergeSheet)
        #expect(sheet.entries.filter(\.isKept).map(\.id) == [books.audio])
        #expect(sheet.files.map(\.role) == [.audio, .ebook, .extra])
        #expect(sheet.files.map(\.role.title) == ["Audiobook", "Ebook", "Extra"])

        await h.model.confirmMerge()

        #expect(h.model.alert == nil)
        #expect(h.model.mergeSheet == nil)
        #expect(try bookIds(h) == [books.audio])
        #expect(h.model.rows.map(\.id) == [books.audio])
        #expect(h.model.selection == [books.audio])
        let detail = try #require(h.detail)
        #expect(detail.row.id == books.audio)
        #expect(!detail.row.book.needsAttention)
        #expect(detail.attentionReasons.isEmpty)
        #expect(detail.row.book.folderPath == L.folder)
        #expect(detail.files.map(\.file.role) == [.audio, .ebook, .extra])
        #expect(h.model.mergeOffer == nil)
        #expect(h.libraryFiles() == [
            "\(L.folder)/Extras/\(L.companion).pdf", "\(L.folder)/\(L.title).m4b", "\(L.folder)/\(L.title).pdf",
        ].sorted())
        #expect(h.model.undoMenuTitle == "Undo Merge Books")
    }

    @Test func mg5_theOfferIsOnlyForOneBookFlaggedBecauseAnotherHasItsFolder() async throws {
        let (h, books) = try await Harness.merging { library in
            let owners = try library.ownersCase()
            // Flagged for another reason: it has no author, so it cannot be filed.
            return (owners, try library.pdf("Loose Notes", nil))
        }
        let (owners, loose) = books
        #expect(h.model.mergeOffer == nil)

        await h.select(ids: [owners.pdf])
        #expect(h.detail?.row.book.needsAttention == false)
        #expect(h.model.mergeOffer == nil)

        await h.select(ids: [loose])
        #expect(h.detail?.row.book.needsAttention == true)
        #expect(h.detail?.attentionReasons == ["Add an author to file this book"])
        #expect(h.model.mergeOffer == nil)

        await h.select(ids: [owners.audio])
        #expect(h.model.mergeOffer?.bookId == owners.pdf)

        await h.select(ids: [owners.audio, owners.pdf])
        #expect(h.model.mergeOffer == nil)
    }

    @Test func mg5_theOfferCannotBeAcceptedWhileSomethingIsInTheWay() async throws {
        let (h, books) = try await Harness.merging { try $0.ownersCase() }
        await h.select(ids: [books.audio])
        #expect(h.model.canAcceptMergeOffer)

        // With unsaved edits the offer still stands, but waits for them to be saved.
        h.model.updateDraft { $0.genre = "Trading" }
        #expect(h.model.mergeOffer?.bookId == books.pdf)
        #expect(!h.model.canAcceptMergeOffer)
        h.recordBusyLabels()
        await h.model.beginMerge(with: books.pdf)
        #expect(h.model.mergeSheet == nil)
        #expect(h.busyLabels.isEmpty)
        h.model.discardChanges()

        h.model.busyLabel = "Working…"
        #expect(!h.model.canAcceptMergeOffer)
        h.model.busyLabel = nil

        // Not with itself, nor with a row that is no book's.
        await h.model.beginMerge(with: books.audio)
        await h.model.beginMerge(with: -2)
        #expect(h.model.mergeSheet == nil)
        #expect(h.busyLabels.isEmpty)

        #expect(h.model.canAcceptMergeOffer)
        await h.model.beginMerge(with: books.pdf)
        #expect(h.model.mergeSheet != nil)
        #expect(!h.model.canAcceptMergeOffer)
    }

    // MARK: MG6 Swap Title and Author

    @Test func mg6_swappingExchangesTheDraftsTitleWithItsFirstAuthor() {
        var draft = BookDraft(book: bareBook(title: "James Dalton"))
        #expect(!draft.canSwapTitleAndAuthor)
        let untouched = draft
        draft.swapTitleAndAuthor()
        #expect(draft == untouched)

        // The title was the whole of what was in authors: the old title is the only author.
        draft.authors = "Mind Over Markets"
        #expect(draft.canSwapTitleAndAuthor)
        draft.swapTitleAndAuthor()
        #expect(draft.title == "Mind Over Markets")
        #expect(draft.authors == "James Dalton")
        #expect(draft.isDirty)
        #expect(draft.makeEdit()?.metadata.title == "Mind Over Markets")
        #expect(draft.makeEdit()?.metadata.authors == ["James Dalton"])

        // Other authors stay after it.
        var several = BookDraft(book: fullBook(title: "Terry Pratchett"))
        several.authors = " Good Omens ;Neil Gaiman; Eric Jones"
        several.swapTitleAndAuthor()
        #expect(several.title == "Good Omens")
        #expect(several.authors == "Terry Pratchett; Neil Gaiman; Eric Jones")

        // Twice is back where it began.
        several.swapTitleAndAuthor()
        #expect(several.title == "Terry Pratchett")
        #expect(several.authors == "Good Omens; Neil Gaiman; Eric Jones")

        // Nothing to exchange with: no title, or no author.
        var blank = BookDraft(book: fullBook())
        blank.title = "  "
        #expect(!blank.canSwapTitleAndAuthor)
        blank.title = "Good Omens"
        blank.authors = " ; "
        #expect(!blank.canSwapTitleAndAuthor)
        let before = blank
        blank.swapTitleAndAuthor()
        #expect(blank == before)
    }

    @Test func mg6_swappingInTheInspectorMarksTheBookEditedAndIsSavedLikeAnyChange() async throws {
        let (h, book) = try await Harness.merging { try $0.pdf("James Dalton", "Mind Over Markets") }
        #expect(!h.model.canSwapTitleAndAuthor)
        h.model.swapTitleAndAuthor()

        await h.select(ids: [book])
        #expect(h.model.canSwapTitleAndAuthor)
        #expect(!h.model.hasUnsavedChanges)

        h.model.swapTitleAndAuthor()

        #expect(h.draft?.title == "Mind Over Markets")
        #expect(h.draft?.authors == "James Dalton")
        #expect(h.model.hasUnsavedChanges)
        #expect(h.model.editedBookIds == [book])
        #expect(h.model.inspectorEditedText == "Edited · not saved")
        // Nothing is written until it is saved.
        #expect(try h.book(book).title == "James Dalton")

        await h.model.save()
        #expect(h.model.alert == nil)
        #expect(try h.book(book).title == "Mind Over Markets")
        #expect(try h.book(book).authors == ["James Dalton"])
        #expect(try h.book(book).folderPath == "James Dalton/Mind Over Markets")
        #expect(!h.model.hasUnsavedChanges)

        // Not for several books.
        let (many, ebook, notes) = try await ebookAndNotes()
        await many.select(ids: [ebook, notes])
        #expect(!many.model.canSwapTitleAndAuthor)
    }

    @Test func mg6_swappingAnImportEntryExchangesItsTitleWithItsFirstAuthor() {
        func file(_ name: String) -> CandidateFile {
            CandidateFile(url: URL(fileURLWithPath: "/inbox/\(name)"), role: .ebook)
        }
        var review = ImportReview(
            seeds: [
                ImportSeed(
                    candidate: CandidateBook(
                        files: [file("a.epub")],
                        metadata: BookMetadata(title: "Terry Pratchett", authors: ["Good Omens", "Neil Gaiman"])),
                    cover: nil, existingMatch: nil),
                ImportSeed(
                    candidate: CandidateBook(files: [file("b.epub")], metadata: BookMetadata(title: "No Author")),
                    cover: nil, existingMatch: nil),
            ], skipped: [], copyInsteadOfMove: false)
        let first = review.entries[0].id
        let second = review.entries[1].id
        #expect(review.canSwapTitleAndAuthor(of: first))
        #expect(!review.canSwapTitleAndAuthor(of: second))
        #expect(!review.canSwapTitleAndAuthor(of: UUID()))

        review.swapTitleAndAuthor(for: first)
        #expect(review.text(for: .title, of: first) == "Good Omens")
        #expect(review.text(for: .authors, of: first) == "Terry Pratchett; Neil Gaiman")

        let before = review
        review.swapTitleAndAuthor(for: second)
        review.swapTitleAndAuthor(for: UUID())
        #expect(review == before)

        // Its folder and its match were worked out for the details it had.
        #expect(review.entriesNeedingDestination.contains(first))
        #expect(review.entriesNeedingMatch.contains(first))
    }

    @Test func mg6_swappingAnImportEntryWorksItsDestinationAndItsMatchOutAgain() async throws {
        let h = try await Harness.demo()
        let inbox = try Harness.inbox()
        await h.model.beginImport([inbox.appendingPathComponent("Quiet Rivers.epub")])
        let id = try #require(h.model.review?.entries.first?.id)
        let library = try h.id("Quiet Rivers")
        #expect(h.model.review?.entry(id)?.existingMatch?.id == library)
        // As a badly tagged file has them: each in the other's place.
        h.model.updateReview { review in
            review.setText("Amara Okafor", for: .title, of: id)
            review.setText("Quiet Rivers", for: .authors, of: id)
        }
        await h.model.settle()
        var entry = try #require(h.model.review?.entry(id))
        #expect(entry.existingMatch == nil)
        #expect(entry.destination == "Quiet Rivers/Amara Okafor")
        #expect(h.model.canSwapReviewTitleAndAuthor(for: id))

        h.model.swapReviewTitleAndAuthor(for: id)
        // The change itself is immediate; the folder and the match follow.
        #expect(h.model.review?.text(for: .title, of: id) == "Quiet Rivers")
        #expect(h.model.review?.text(for: .authors, of: id) == "Amara Okafor")
        await h.model.settle()

        entry = try #require(h.model.review?.entry(id))
        #expect(entry.existingMatch?.id == library)
        #expect(entry.destination == (try h.book(library).folderPath))
        #expect(h.model.review?.entriesNeedingDestination.isEmpty == true)
        #expect(h.model.review?.entriesNeedingMatch.isEmpty == true)
        #expect(!h.model.canSwapReviewTitleAndAuthor(for: UUID()))
    }

    // MARK: What the views are told

    @Test func mg2_anEntrysSecondLineIsItsAuthorAndWhatItHas() {
        var row = MergeEntryRow(id: 1, title: "Dune", author: "Frank Herbert", contents: "Ebook, 1 file", isKept: true)
        #expect(row.subtitle == "Frank Herbert · Ebook, 1 file")
        row.author = ""
        #expect(row.subtitle == "Ebook, 1 file")
    }

    @Test func mg2_aFileSaysWhichEntryItComesFrom() {
        let row = MergeFileRow(
            id: 1, name: "Dune.pdf", entryTitle: "Dune Notes", role: .extra, allowedRoles: [.ebook, .extra],
            isChanged: false)
        #expect(row.sourceText == "From “Dune Notes”")
    }

    @Test func mg2_whatAnEntryHasIsSaidInWords() {
        #expect(MergeText.contents(roles: []) == "No files")
        #expect(MergeText.contents(roles: [.audio]) == "Audiobook, 1 file")
        #expect(MergeText.contents(roles: [.audio, .audio, .ebook]) == "Audiobook and ebook, 3 files")
        #expect(MergeText.contents(roles: [.ebook, .extra]) == "Ebook, 2 files")
        #expect(MergeText.contents(roles: [.extra, .extra]) == "Extras only, 2 files")
    }

    @Test func mg1_aContextMenuOffersMergingForSeveralBooks() async throws {
        let (h, ebook, notes) = try await ebookAndNotes()
        #expect(!h.model.offersMergeBooks(for: []))
        #expect(!h.model.offersMergeBooks(for: [ebook]))
        #expect(h.model.offersMergeBooks(for: [ebook, notes]))
        // Offered, though it does not apply, while something is in the way.
        h.model.busyLabel = "Working…"
        #expect(h.model.offersMergeBooks(for: [ebook, notes]))
        #expect(!h.model.canMergeBooks([ebook, notes]))
        h.model.busyLabel = nil
    }

    @Test func mg5_theOfferStandsUnderItsOwnReasonLine() async throws {
        let (h, books) = try await Harness.merging { try $0.ownersCase() }
        await h.select(ids: [books.audio])
        var detail = try #require(h.detail)
        let taken = "Another book uses the folder this book belongs in."
        #expect(detail.attentionLines == [AttentionLine(text: taken, offer: MergeOffer(bookId: books.pdf, title: L.title))])
        #expect(detail.attentionLines.map(\.id) == [taken])

        // Under that reason and no other.
        try FileManager.default.removeItem(at: try h.fileURLs(books.audio)[0])
        await h.model.retryLibrary()
        h.model.dismissLibraryCheck()
        await h.select(ids: [books.audio])
        detail = try #require(h.detail)
        #expect(detail.attentionReasons == [taken, "Some files are missing"])
        #expect(detail.attentionLines.map(\.text) == detail.attentionReasons)
        #expect(detail.attentionLines.map(\.offer?.bookId) == [books.pdf, nil])

        // No offer: the reasons alone.
        await h.select(ids: [books.pdf])
        #expect(h.detail?.attentionLines.isEmpty == true)
        detail.mergeOffer = nil
        #expect(detail.attentionLines.map(\.offer) == [nil, nil])
    }

    // MARK: MG7 One sheet, and nothing else meanwhile

    @Test func mg7_theSheetIsOneOfTheWindowsSheetsAfterTheOthers() async throws {
        let (h, _, _) = try await merging()
        let sheet = try #require(h.model.mergeSheet)
        #expect(h.model.windowSheet(progressDue: false) == .mergeBooks(sheet))
        #expect(WindowSheet.mergeBooks(sheet).id == "mergeBooks")
        let others: [WindowSheet] = [
            .progress(""), .result(ResultSummary(headline: "", problems: [], isClean: true)), .seriesChoice([]),
        ]
        #expect(!others.map(\.id).contains("mergeBooks"))

        // A result comes first, and the sheet is back after it.
        let result = ResultSummary(headline: "Done", problems: [], isClean: false)
        h.model.result = result
        #expect(h.model.windowSheet(progressDue: false) == .result(result))
        h.model.result = nil
        #expect(h.model.windowSheet(progressDue: false) == .mergeBooks(sheet))

        // What the sheet itself is doing is shown in the sheet, not in place of it.
        h.model.busyLabel = "Merging books…"
        let working = try #require(h.model.mergeSheet)
        #expect(working.busyText == "Merging books…")
        #expect(h.model.windowSheet(progressDue: true) == .mergeBooks(working))
        h.model.busyLabel = nil

        // Closed, the window has no sheet.
        h.model.cancelMerge()
        #expect(h.model.windowSheet(progressDue: false) == nil)
    }

    @Test func mg7_whileTheSheetIsOpenNothingElseCanStart() async throws {
        let (h, ebook, notes) = try await merging()
        let statusBefore = try h.book(ebook).readStatus
        // Something for Undo to reverse.
        h.model.cancelMerge()
        await h.model.setReadStatus(.inProgress, for: [notes])
        let undo = try #require(h.model.undoLabel)
        #expect(h.model.canUndo)
        await h.model.beginMergeBooks()
        #expect(h.model.mergeSheet != nil)

        #expect(!h.model.canUndo)
        #expect(!h.model.canImport)
        #expect(!h.model.canSave)
        #expect(!h.model.canChangeLayout)
        #expect(!h.model.canChangeFiles)
        #expect(!h.model.canAddAudibleBook)
        #expect(!h.model.canSendToPhone([ebook]))
        #expect(!h.model.canChooseLibrary)
        let commands = h.model.commands(for: [ebook])
        #expect(!commands.mark)
        #expect(!commands.rewriteTags)
        #expect(!commands.remove)
        h.recordBusyLabels()

        await h.model.undo()
        await h.model.setReadStatus(.finished, for: [ebook])
        await h.model.rewriteTags(for: [ebook])
        await h.model.beginImport([try Harness.inbox()])
        await h.model.createCollection(name: "New", adding: [ebook])
        h.model.requestRemove([ebook])
        await h.model.previewLayoutChange()
        await h.model.beginSendToPhone(for: [ebook])
        h.model.beginAddAudibleBook()
        let elsewhere = try makeTempDir()
        await h.model.chooseLibrary(elsewhere)

        #expect(h.busyLabels.isEmpty)
        #expect(h.model.undoLabel == undo)
        #expect(h.model.review == nil)
        #expect(h.model.prompt == nil)
        #expect(h.model.layoutPreview == nil)
        #expect(h.model.sendSheet == nil)
        #expect(h.model.lookup == nil)
        #expect(try h.book(ebook).readStatus == statusBefore)
        #expect(h.model.libraryFolder?.standardizedFileURL.path == h.root.standardizedFileURL.path)
        #expect(h.model.alert == "Finish or cancel the merge first, then choose the library folder again.")
        h.model.alert = nil
        #expect(h.model.mergeSheet != nil)

        // When it has closed, everything can again.
        h.model.cancelMerge()
        #expect(h.model.canUndo)
        #expect(h.model.canImport)
        #expect(h.model.canChooseLibrary)
        #expect(h.model.commands(for: [ebook]).mark)
        await h.model.setReadStatus(.finished, for: [ebook])
        #expect(try h.book(ebook).readStatus == .finished)
    }

    @Test func mg7_filesTheAppIsAskedToOpenWaitUntilTheSheetHasClosed() async throws {
        let (h, _, _) = try await merging()
        let inbox = try Harness.inbox()

        await h.model.openFiles([inbox])
        await h.model.settle()
        #expect(h.model.review == nil)
        #expect(h.model.alert == nil)
        #expect(h.model.mergeSheet != nil)

        // Nor do they come in when the sheet plans again.
        await h.model.setMergeKeep(try #require(h.model.mergeSheet?.entries.last?.id))
        await h.model.settle()
        #expect(h.model.review == nil)
        #expect(h.model.mergeSheet != nil)

        h.model.cancelMerge()
        await h.model.settle()
        #expect(h.model.review != nil)
    }

    @Test func mg7_openingAnotherLibraryClosesTheSheet() async throws {
        let (h, _, _) = try await merging()
        await h.model.retryLibrary()
        #expect(h.model.mergeSheet == nil)
    }
}

import Foundation
import Testing
import VoxCarrelCore
import VoxCarrelFixtures

@testable import VoxCarrelAppCore

/// What the inspector asks of the model (plan Task 10). N1–N10.
@MainActor
@Suite struct AppModelInspectorTests {
    private func detail(
        _ book: Book, hasAudio: Bool = true, files: [FileRow] = [], chapters: Int = 0
    ) -> BookDetail {
        let row = BookRow(
            id: book.id ?? 1, book: book, hasAudio: hasAudio, hasEbook: !hasAudio, formats: [], coverURL: nil,
            hasWriteProblem: false)
        return BookDetail(row: row, files: files, chapterCount: chapters, collectionIds: [])
    }

    private func file(_ id: Int64, missing: Bool = false, problem: String? = nil) -> FileRow {
        var file = BookFile(path: "A/B/\(id).epub", format: .epub, role: .ebook, position: Int(id))
        file.id = id
        file.writeProblem = problem
        let url = URL(fileURLWithPath: "/library/A/B/\(id).epub")
        return FileRow(
            id: id, file: file, url: url, name: url.lastPathComponent, isMissing: missing,
            allowedRoles: FileRow.allowedRoles(for: .epub))
    }

    // MARK: N1 Saved in app only (I4)

    /// N1
    @Test func markersAreThoseOfTheInspectedBooksDraft() async throws {
        let h = try await Harness.demo()
        #expect(h.model.appOnlyMarkers.isEmpty)

        // Two ebooks, an EPUB and a PDF: neither holds a narrator.
        let id = try await h.select("The Cartographer's Daughter")
        var book = try h.book(id)
        book.appOnlyFields = [.narrators, .asin, .cover]
        try h.store().update(book)
        await h.model.reloadAll()

        // Empty fields have nothing to mark.
        let hasCover = h.detail?.row.coverURL != nil
        #expect(h.model.appOnlyMarkers == h.draft?.appOnlyMarkers(hasCover: hasCover))
        #expect(h.model.appOnlyMarkers.contains(.cover) == hasCover)
        h.model.updateDraft {
            $0.narrators = ""
            $0.asin = ""
        }
        #expect(h.model.appOnlyMarkers.isDisjoint(with: [.narrators, .asin]))
        h.model.updateDraft {
            $0.narrators = "Someone"
            $0.asin = "B000000001"
        }
        #expect(h.model.appOnlyMarkers.isSuperset(of: [.narrators, .asin]))
        // A cover that is to be removed is not marked.
        h.model.removeCover()
        #expect(!h.model.appOnlyMarkers.contains(.cover))

        h.model.discardChanges()
        try await h.select(["Salt Road", "Quiet Rivers"])
        #expect(h.bulkDraft != nil)
        #expect(h.model.appOnlyMarkers.isEmpty)
    }

    // MARK: N2 Needs attention (I7)

    /// N2
    @Test func attentionReasonsSayWhatIsWrongInPlainWords() {
        var flagged = bareBook()
        flagged.needsAttention = true
        #expect(detail(flagged, files: [file(1)]).attentionReasons == ["Add an author to file this book"])
        #expect(
            detail(flagged, files: [file(1), file(2, missing: true)]).attentionReasons
                == ["Add an author to file this book", "Some files are missing"])

        var withAuthor = fullBook()
        withAuthor.needsAttention = true
        #expect(detail(withAuthor, files: [file(1, missing: true)]).attentionReasons == ["Some files are missing"])
        // Flagged, and nothing known to be wrong yet (the files are still being read): nothing is said.
        #expect(detail(withAuthor).attentionReasons.isEmpty)
        // A blank author is no author.
        flagged.authors = ["  "]
        #expect(detail(flagged).attentionReasons == ["Add an author to file this book"])
        // A book that is in order.
        #expect(detail(fullBook(), files: [file(1)]).attentionReasons.isEmpty)
        // Not flagged, with no author: it is filed, and nothing is asked for.
        #expect(detail(bareBook(), files: [file(1)]).attentionReasons.isEmpty)
    }

    /// N2: on the demo library's book with no author, and a book whose file has gone.
    @Test func attentionReasonsOfLibraryBooks() async throws {
        let h = try await Harness.demo()
        try await h.select("Voices from the Attic")
        #expect(h.detail?.attentionReasons == ["Add an author to file this book"])

        let id = try h.id("Quiet Rivers")
        try FileManager.default.removeItem(at: try #require(try h.fileURLs(id).first))
        try await h.select("Quiet Rivers")
        #expect(h.detail?.attentionReasons == ["Some files are missing"])
    }

    // MARK: N3 The draft's cover (I5)

    /// N3
    @Test func draftCoverIsTheStoredOneANewOneOrNone() async throws {
        let h = try await Harness.demo()
        #expect(h.model.draftCover == .none)
        #expect(!h.model.canRemoveCover)

        try await h.select("Salt Road")
        #expect(h.detail?.row.coverURL != nil)
        #expect(h.model.draftCover == .stored)
        #expect(h.model.canRemoveCover)

        let png = MediaFixtures.makeImage(.png)
        h.model.setCover(data: png)
        #expect(h.model.draftCover == .chosen(png))
        #expect(h.model.canRemoveCover)

        h.model.removeCover()
        #expect(h.model.draftCover == .none)
        #expect(!h.model.canRemoveCover)

        h.model.discardChanges()
        #expect(h.model.draftCover == .stored)
    }

    /// N3: a book with no cover of its own.
    @Test func aBookWithNoCoverShowsNoneUntilOneIsChosen() async throws {
        let h = try await Harness.demo()
        let id = try await h.select("Salt Road")
        h.model.removeCover()
        await h.model.save()
        #expect(h.model.selection == [id])
        #expect(h.detail?.row.coverURL == nil)
        #expect(h.model.draftCover == .none)

        let jpeg = MediaFixtures.makeImage(.jpeg)
        h.model.setCover(data: jpeg)
        #expect(h.model.draftCover == .chosen(jpeg))
        // Taking it back leaves nothing to save.
        h.model.removeCover()
        #expect(h.model.draftCover == .none)
        #expect(!h.model.hasUnsavedChanges)
    }

    // MARK: N4 Rewrite Tags (I6)

    /// N4
    @Test func rewriteTagsIsOfferedWhenAFilesTagsWereNotWritten() {
        #expect(!detail(fullBook(), files: [file(1), file(2)]).showsRewriteTags)
        #expect(detail(fullBook(), files: [file(1), file(2, problem: "The file is locked.")]).showsRewriteTags)
        #expect(!detail(fullBook()).showsRewriteTags)
    }

    // MARK: N5 Length and chapters (I1)

    /// N5
    @Test func audioSummaryIsLengthAndChapters() {
        var book = fullBook()
        book.durationSeconds = 7 * 3600 + 42 * 60
        #expect(detail(book, chapters: 12).audioSummaryText == "7h 42m · 12 chapters")
        #expect(detail(book, chapters: 1).audioSummaryText == "7h 42m · 1 chapter")
        #expect(detail(book, chapters: 0).audioSummaryText == "7h 42m")
        book.durationSeconds = nil
        #expect(detail(book, chapters: 3).audioSummaryText == "3 chapters")
        #expect(detail(book, chapters: 0).audioSummaryText == nil)
        // Only for audio.
        book.durationSeconds = 600
        #expect(detail(book, hasAudio: false, chapters: 3).audioSummaryText == nil)
    }

    // MARK: N6 Read status dates (I1)

    /// N6
    @Test func readDatesAreWrittenOutForTheStatusTheyGoWith() throws {
        let locale = Locale(identifier: "en_GB")
        let utc = try #require(TimeZone(identifier: "UTC"))
        // 3 November 2026 and 20 November 2026, at noon.
        let started = Date(timeIntervalSince1970: 1_793_707_200)
        let finished = Date(timeIntervalSince1970: 1_795_176_000)

        var book = bareBook()
        #expect(book.readDateLines(locale: locale, timeZone: utc).isEmpty)

        book.readStatus = .inProgress
        book.dateStarted = started
        #expect(book.readDateLines(locale: locale, timeZone: utc) == ["Started 3 Nov 2026"])

        book.readStatus = .finished
        book.dateFinished = finished
        #expect(book.readDateLines(locale: locale, timeZone: utc) == ["Started 3 Nov 2026", "Finished 20 Nov 2026"])

        // Finished without ever being marked in progress.
        book.dateStarted = nil
        #expect(book.readDateLines(locale: locale, timeZone: utc) == ["Finished 20 Nov 2026"])

        // Dates that do not go with the status are not shown.
        book.readStatus = .inProgress
        book.dateStarted = started
        #expect(book.readDateLines(locale: locale, timeZone: utc) == ["Started 3 Nov 2026"])
        book.readStatus = .unread
        #expect(book.readDateLines(locale: locale, timeZone: utc).isEmpty)
    }

    // MARK: N7 Rating (I1)

    /// N7
    @Test func clickingAStarSetsTheRatingAndClickingItAgainClearsIt() {
        var draft = BookDraft(book: fullBook())
        #expect(draft.rating == 4)
        draft.clickStar(2)
        #expect(draft.rating == 2)
        #expect(draft.isDirty)
        draft.clickStar(2)
        #expect(draft.rating == 0)
        draft.clickStar(5)
        #expect(draft.rating == 5)
        draft.clickStar(9)
        #expect(draft.rating == 0)
        draft.clickStar(4)
        #expect(!draft.isDirty)
    }

    // MARK: N8 Bulk fields (I8)

    private func books() -> [Book] {
        var a = fullBook(id: 1, title: "A")
        var b = fullBook(id: 2, title: "B")
        a.language = "en"
        b.language = "en"
        a.publisher = "Gollancz"
        b.publisher = "Corgi"
        a.tags = ["funny"]
        b.tags = ["funny"]
        return [a, b]
    }

    /// N8
    @Test func aBulkFieldShowsTheSharedValueOrMixed() {
        var draft = BulkDraft(books: books())
        #expect(draft.text(for: .language) == "en")
        #expect(draft.placeholder(for: .language) == "")
        #expect(draft.text(for: .publisher) == "")
        #expect(draft.placeholder(for: .publisher) == "Mixed")
        #expect(draft.text(for: .authors) == "Terry Pratchett; Neil Gaiman")

        // What is typed is what is shown.
        draft.setText("Penguin", for: .publisher)
        #expect(draft.text(for: .publisher) == "Penguin")
        #expect(draft.note(for: .publisher) == nil)
        // Emptied again, a box whose books differ is as it was before anything was typed:
        // it never means "clear this on every book".
        draft.setText("", for: .publisher)
        #expect(draft.values[.publisher] == nil)
        #expect(draft.placeholder(for: .publisher) == "Mixed")
        #expect(!draft.isDirty)
        #expect(draft.makeEdits()?.map(\.metadata.publisher) == books().map(\.publisher))
    }

    /// N8: the same for a box of several names.
    @Test func anEmptiedBoxOfMixedNamesIsUntouched() {
        var (a, b) = (books()[0], books()[1])
        a.authors = ["Ann Lee"]
        b.authors = ["Bo Writer"]
        var draft = BulkDraft(books: [a, b])
        #expect(draft.placeholder(for: .authors) == "Mixed")
        draft.setText("x", for: .authors)
        #expect(draft.isDirty)
        for emptied in ["", "  ", " ; "] {
            draft.setText("x", for: .authors)
            draft.setText(emptied, for: .authors)
            #expect(!draft.isDirty, "[\(emptied)]")
            #expect(draft.makeEdits()?.map(\.metadata.authors) == [["Ann Lee"], ["Bo Writer"]])
        }
    }

    /// N8: clearing a value every book has does clear it on every book, and says so.
    @Test func clearingASharedValueSaysHowManyBooksItClears() {
        var draft = BulkDraft(books: books())
        #expect(draft.note(for: .language) == nil)
        draft.setText("e", for: .language)
        #expect(draft.note(for: .language) == nil)
        draft.setText("", for: .language)
        #expect(draft.values[.language] == "")
        #expect(draft.isDirty)
        #expect(draft.note(for: .language) == "Will be cleared on 2 books")
        #expect(draft.makeEdits()?.map(\.metadata.language) == [nil, nil])

        draft.setText("  ", for: .authors)
        #expect(draft.note(for: .authors) == "Will be cleared on 2 books")
        #expect(draft.makeEdits()?.map(\.metadata.authors) == [[], []])
        // Tags are only ever added.
        draft.setText("", for: .tags)
        #expect(draft.note(for: .tags) == nil)
    }

    /// N8: tags are added, so the box starts empty whatever the books have.
    @Test func theTagsBoxStartsEmpty() {
        var draft = BulkDraft(books: books())
        #expect(draft.text(for: .tags) == "")
        #expect(draft.placeholder(for: .tags) == "")
        draft.setText("signed", for: .tags)
        #expect(draft.text(for: .tags) == "signed")
        #expect(draft.isDirty)
        draft.setText("", for: .tags)
        #expect(draft.values[.tags] == nil)
        #expect(!draft.isDirty)
    }

    /// N8: typing a shared value back to what it was leaves nothing to save.
    @Test func textThatIsWhatEveryBookHasLeavesTheFieldUntouched() {
        var draft = BulkDraft(books: books())
        draft.setText("e", for: .language)
        #expect(draft.values[.language] == "e")
        #expect(draft.isDirty)
        draft.setText("en", for: .language)
        #expect(draft.values[.language] == nil)
        #expect(!draft.isDirty)

        // A shared value can be cleared.
        draft.setText("", for: .language)
        #expect(draft.values[.language] == "")
        #expect(draft.text(for: .language) == "")

        // Nothing typed into the empty box of a field whose books differ.
        draft = BulkDraft(books: books())
        draft.setText("", for: .publisher)
        #expect(draft.values[.publisher] == nil)
        #expect(draft.placeholder(for: .publisher) == "Mixed")
    }

    /// N8
    @Test func setBulkTextEditsTheBulkDraft() async throws {
        let h = try await Harness.demo()
        try await h.select(["Salt Road", "Quiet Rivers"])
        #expect(!h.model.hasUnsavedChanges)
        h.model.setBulkText("Travel", for: .publisher)
        #expect(h.bulkDraft?.values[.publisher] == "Travel")
        #expect(h.model.hasUnsavedChanges)

        // One book inspected: nothing to set.
        h.model.discardChanges()
        try await h.select("Salt Road")
        h.model.setBulkText("Travel", for: .publisher)
        #expect(!h.model.hasUnsavedChanges)
    }

    // MARK: N9, N10 Words

    /// N9
    @Test func bulkFieldsHaveLabelsAndTheHeadlineCountsTheBooks() {
        #expect(
            BulkField.allCases.map(\.title)
                == ["Author", "Narrator", "Series", "Year", "Publisher", "Language", "Add tags"])
        #expect(BulkField.allCases.filter(\.takesSeveral) == [.authors, .narrators, .tags])
        #expect(BulkDraft(books: books()).headline == "2 books selected")
        #expect(BulkDraft(books: [bareBook()]).headline == "1 book selected")
    }

    /// N10
    @Test func fileRolesHaveNames() {
        #expect(FileRole.allCases.map(\.title) == ["Audiobook", "Ebook", "Extra"])
    }

    // MARK: N11 Unsaved edits are marked

    /// N11: one book with unsaved edits is marked, in the inspector and by its id, until
    /// the edits are saved or discarded.
    @Test func aBookWithUnsavedEditsIsMarked() async throws {
        let h = try await Harness.demo()
        #expect(h.model.editedBookIds.isEmpty)
        #expect(h.model.inspectorEditedText == nil)
        #expect(h.model.editedBadgeHelp == "Has unsaved changes")

        let id = try await h.select("Salt Road")
        #expect(h.model.editedBookIds.isEmpty)
        #expect(h.model.inspectorEditedText == nil)

        h.model.updateDraft { $0.genres = ["Sea Stories"] }
        #expect(h.model.editedBookIds == [id])
        #expect(h.model.inspectorEditedText == "Edited · not saved")

        // Typed back to what it was: nothing to save, nothing to mark.
        h.model.updateDraft { $0.genres = $0.original.genres }
        #expect(h.model.editedBookIds.isEmpty)
        #expect(h.model.inspectorEditedText == nil)

        h.model.setCover(data: MediaFixtures.makeImage(.png))
        #expect(h.model.editedBookIds == [id])
        h.model.discardChanges()
        #expect(h.model.editedBookIds.isEmpty)
        #expect(h.model.inspectorEditedText == nil)

        h.model.updateDraft { $0.genres = ["Sea Stories"] }
        await h.model.save()
        #expect(h.model.editedBookIds.isEmpty)
        #expect(h.model.inspectorEditedText == nil)
    }

    /// N11: a save that does not go through leaves the book marked.
    @Test func aBookWhoseSaveDidNotGoThroughStaysMarked() async throws {
        let h = try await Harness.demo()
        let id = try await h.select("Salt Road")
        h.model.updateDraft { $0.title = " " }
        await h.model.save()
        #expect(h.model.alert != nil)
        #expect(h.model.editedBookIds == [id])
        #expect(h.model.inspectorEditedText == "Edited · not saved")
    }

    /// N11: with several books selected and a field changed, every one of them is marked.
    @Test func everyBookOfAnEditedSelectionIsMarked() async throws {
        let h = try await Harness.demo()
        let ids = try await h.select(["Salt Road", "Quiet Rivers"])
        #expect(h.model.editedBookIds.isEmpty)
        #expect(h.model.inspectorEditedText == nil)

        h.model.setBulkText("Travel", for: .publisher)
        #expect(h.model.editedBookIds == ids)
        #expect(h.model.inspectorEditedText == "Edited · not saved")

        h.model.discardChanges()
        #expect(h.model.editedBookIds.isEmpty)

        h.model.setBulkText("Travel", for: .publisher)
        await h.model.save()
        #expect(h.model.editedBookIds.isEmpty)
        #expect(h.model.inspectorEditedText == nil)
    }
}

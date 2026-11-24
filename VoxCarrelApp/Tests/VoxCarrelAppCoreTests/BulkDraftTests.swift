import Foundation
import Testing
import VoxCarrelAppCore
import VoxCarrelCore

@Suite struct BulkDraftTests {
    private func book(
        _ id: Int64, authors: [String] = ["Ann Lee"], narrators: [String] = [], series: String? = nil,
        number: String? = nil, genre: String? = nil, year: Int? = nil, publisher: String? = nil,
        language: String? = nil, tags: [String] = []
    ) -> Book {
        var book = fullBook(id: id, title: "Book \(id)")
        book.authors = authors
        book.narrators = narrators
        book.series = series
        book.seriesNumber = number
        book.genres = genre.map { [$0] } ?? []
        book.year = year
        book.publisher = publisher
        book.language = language
        book.tags = tags
        return book
    }

    /// K1
    @Test func sharedReportsTheCommonValue() {
        let draft = BulkDraft(books: [
            book(1, authors: ["Ann Lee", "Bo"], narrators: ["N"], series: "Saga", genre: "SF", year: 2001,
                 publisher: "Ace", language: "en", tags: ["x", "y"]),
            book(2, authors: ["ann lee", "BO"], narrators: ["N"], series: "Saga", genre: "SF", year: 2001,
                 publisher: "Ace", language: "en", tags: ["X", "y"]),
        ])
        #expect(draft.shared(.authors) == .same("Ann Lee; Bo"))
        #expect(draft.shared(.narrators) == .same("N"))
        #expect(draft.shared(.series) == .same("Saga"))
        #expect(draft.shared(.year) == .same("2001"))
        #expect(draft.shared(.publisher) == .same("Ace"))
        #expect(draft.shared(.language) == .same("en"))
        #expect(draft.shared(.tags) == .same("x; y"))
    }

    /// K1
    @Test func sharedIsMixedWhenAnyBookDiffers() {
        let draft = BulkDraft(books: [
            book(1, authors: ["Ann Lee", "Bo"], narrators: ["N"], series: "Saga", genre: "SF", year: 2001,
                 publisher: "Ace", language: "en", tags: ["x", "y"]),
            book(2, authors: ["Bo", "Ann Lee"], narrators: [], series: nil, genre: "Fantasy", year: 2002,
                 publisher: nil, language: "fr", tags: ["x"]),
            book(3, authors: ["Ann Lee", "Bo"], narrators: ["N"], series: "Saga", genre: "SF", year: 2001,
                 publisher: "Ace", language: "en", tags: ["x", "y"]),
        ])
        for field in BulkField.allCases {
            #expect(draft.shared(field) == .mixed, "\(field)")
        }
    }

    /// K1: a field every book lacks is the same, and empty.
    @Test func sharedIsSameEmptyWhenNoBookHasAValue() {
        let draft = BulkDraft(books: [book(1, authors: []), book(2, authors: [])])
        for field in BulkField.allCases {
            #expect(draft.shared(field) == .same(""), "\(field)")
        }
    }

    /// K2
    @Test func changesOnlyTheFieldsWithValues() throws {
        let books = [
            book(1, authors: ["Ann Lee"], narrators: ["N1"], series: "S1", number: "1", genre: "SF", year: 2001,
                 publisher: "Ace", language: "en", tags: ["x"]),
            book(2, authors: ["Bo"], narrators: ["N2"], series: "S2", number: "2", genre: "Crime", year: 2002,
                 publisher: "Tor", language: "fr", tags: ["y"]),
        ]
        var draft = BulkDraft(books: books)
        draft.values[.publisher] = " Faber "
        draft.values[.authors] = "Cy Dee; Le Guin, Ursula K."
        #expect(draft.isDirty)
        #expect(draft.problems.isEmpty)

        let edits = try #require(draft.makeEdits())
        #expect(edits.count == 2)
        for (edit, original) in zip(edits, books) {
            var expected = BookEdit(book: original)
            expected.metadata.publisher = "Faber"
            expected.metadata.authors = ["Cy Dee", "Le Guin, Ursula K."]
            expectSame(edit, expected)
        }
    }

    /// K2: every replacing field replaces.
    @Test func everyReplacingFieldIsApplied() throws {
        var draft = BulkDraft(books: [book(1), book(2, authors: ["Bo"], year: 1950)])
        draft.values = [
            .authors: "A One", .narrators: "N One; N Two", .series: "Saga", .year: " 1999 ",
            .publisher: "Ace", .language: "en",
        ]
        let edits = try #require(draft.makeEdits())
        for edit in edits {
            #expect(edit.metadata.authors == ["A One"])
            #expect(edit.metadata.narrators == ["N One", "N Two"])
            #expect(edit.metadata.series == "Saga")
            #expect(edit.metadata.year == 1999)
            #expect(edit.metadata.publisher == "Ace")
            #expect(edit.metadata.language == "en")
            #expect(edit.cover == .keep)
        }
        #expect(edits.map(\.bookId) == [1, 2])
    }

    /// K3
    @Test func tagsAreAddedNotReplaced() throws {
        let books = [book(1, tags: ["funny", "Long"]), book(2, tags: []), book(3, tags: ["NEW"])]
        var draft = BulkDraft(books: books)
        draft.values[.tags] = "long; new; signed; Signed"
        #expect(draft.isDirty)
        let edits = try #require(draft.makeEdits())
        #expect(edits.map(\.tags) == [["funny", "Long", "new", "signed"], ["long", "new", "signed"], ["NEW", "long", "signed"]])
        // Nothing else moves.
        for (edit, original) in zip(edits, books) {
            #expect(edit.metadata == original.metadata)
            #expect(edit.rating == original.rating)
        }
    }

    /// K3
    @Test func anEmptyTagsValueChangesNothing() throws {
        let books = [book(1, tags: ["funny"]), book(2, tags: [])]
        var draft = BulkDraft(books: books)
        draft.values[.tags] = "  "
        #expect(!draft.isDirty)
        let edits = try #require(draft.makeEdits())
        for (edit, original) in zip(edits, books) {
            expectSame(edit, BookEdit(book: original))
        }
    }

    /// K4
    @Test func anEmptyValueClearsTheField() throws {
        let books = [
            book(1, authors: ["Ann Lee"], narrators: ["N1"], series: "S1", number: "1", genre: "SF", year: 2001,
                 publisher: "Ace", language: "en", tags: ["x"]),
            book(2, authors: ["Bo"], narrators: ["N2"], series: "S2", number: "2", genre: "Crime", year: 2002,
                 publisher: "Tor", language: "fr", tags: ["y"]),
        ]
        var draft = BulkDraft(books: books)
        for field in BulkField.allCases where field != .tags {
            draft.values[field] = ""
        }
        #expect(draft.isDirty)
        #expect(draft.problems.isEmpty)
        let edits = try #require(draft.makeEdits())
        for (edit, original) in zip(edits, books) {
            #expect(edit.metadata.authors.isEmpty)  // K4: clearing authors is allowed
            #expect(edit.metadata.narrators.isEmpty)
            #expect(edit.metadata.series == nil)
            // Genres are added and removed one at a time, never cleared with a field.
            #expect(edit.metadata.genres == original.genres)
            #expect(edit.metadata.year == nil)
            #expect(edit.metadata.publisher == nil)
            #expect(edit.metadata.language == nil)
            #expect(edit.tags == original.tags)
            #expect(edit.metadata.title == original.title)
        }
    }

    /// K5
    @Test(arguments: ["0", "10000", "198x", "19.84", "-1"])
    func aBadYearIsAProblem(_ text: String) {
        var draft = BulkDraft(books: [book(1), book(2)])
        draft.values[.year] = text
        draft.values[.publisher] = "Ace"
        #expect(draft.problems == ["Year must be a number such as 1984."])
        #expect(draft.makeEdits() == nil)
    }

    /// K5
    @Test func settingSeriesLeavesSeriesNumberAlone() throws {
        var draft = BulkDraft(books: [book(1, series: "Old", number: "1"), book(2, series: nil, number: "7")])
        draft.values[.series] = "New"
        var edits = try #require(draft.makeEdits())
        #expect(edits.map(\.metadata.series) == ["New", "New"])
        #expect(edits.map(\.metadata.seriesNumber) == ["1", "7"])

        draft.values[.series] = ""
        edits = try #require(draft.makeEdits())
        #expect(edits.map(\.metadata.series) == [nil, nil])
        #expect(edits.map(\.metadata.seriesNumber) == ["1", "7"])
    }

    /// K6
    @Test func aDraftWithNoValuesChangesNothing() throws {
        let books = [book(1, tags: ["x"]), fullBook(id: 2), bareBook(id: 3)]
        let draft = BulkDraft(books: books)
        #expect(draft.values.isEmpty)
        #expect(!draft.isDirty)
        #expect(draft.problems.isEmpty)
        let edits = try #require(draft.makeEdits())
        #expect(edits.count == 3)
        for (edit, original) in zip(edits, books) {
            expectSame(edit, BookEdit(book: original))
        }
    }

    /// K2, D6: what describes the files is carried through untouched.
    @Test func keepsDurationAndPageCount() throws {
        var draft = BulkDraft(books: [fullBook(id: 1)])
        draft.values[.publisher] = "Ace"
        let edits = try #require(draft.makeEdits())
        #expect(edits[0].metadata.durationSeconds == 45_000)
        #expect(edits[0].metadata.pageCount == 412)
    }

    // MARK: Genres (G21)

    private func genreBooks() -> [Book] {
        var a = book(1)
        var b = book(2)
        var c = book(3)
        a.genres = ["Fantasy", "Humour"]
        b.genres = ["Humour", "History", "Fantasy"]
        c.genres = ["fantasy"]
        return [a, b, c]
    }

    /// GH21: a genre every selected book has is shown plain, one only some have as mixed.
    @Test func GH21_genresAllBooksHaveArePlainAndTheRestMixed() {
        let draft = BulkDraft(books: genreBooks())
        #expect(draft.genres.map(\.name) == ["Fantasy", "Humour", "History"])
        #expect(draft.genres.map(\.isMixed) == [false, true, true])
        #expect(draft.genres.map(\.detail) == [nil, "2 of 3 books", "1 of 3 books"])
        #expect(!draft.isDirty)
        // Nothing to show when no book has a genre.
        #expect(BulkDraft(books: [book(1), book(2)]).genres.isEmpty)
    }

    /// GH21: Add puts the genre at the end on the books that lack it, and nowhere else.
    @Test func GH21_addPutsAGenreOnTheBooksThatLackIt() throws {
        let books = genreBooks()
        var draft = BulkDraft(books: books)
        draft.addGenre("Humour")
        #expect(draft.isDirty)
        #expect(draft.genres.map(\.name) == ["Fantasy", "Humour", "History"])
        #expect(draft.genres.map(\.isMixed) == [false, false, true])
        draft.addGenre("Romance")
        #expect(draft.genres.map(\.name) == ["Fantasy", "Humour", "History", "Romance"])
        #expect(draft.genres.map(\.isMixed) == [false, false, true, false])

        let edits = try #require(draft.makeEdits())
        #expect(edits.map(\.metadata.genres) == [
            ["Fantasy", "Humour", "Romance"],
            ["Humour", "History", "Fantasy", "Romance"],
            ["fantasy", "Humour", "Romance"],
        ])
        // Nothing else of a book changes.
        for (edit, original) in zip(edits, books) {
            var expected = BookEdit(book: original)
            expected.metadata.genres = edit.metadata.genres
            expectSame(edit, expected)
        }

        // A genre every book has already is nothing to add.
        var same = BulkDraft(books: books)
        same.addGenre("FANTASY")
        #expect(!same.isDirty)
        #expect(try #require(same.makeEdits()).map(\.metadata.genres) == books.map(\.genres))
    }

    /// GH21: Remove takes the genre from the books that have it; the rest of each
    /// book's list stays as it is, in its order.
    @Test func GH21_removeTakesAGenreFromTheBooksThatHaveIt() throws {
        let books = genreBooks()
        var draft = BulkDraft(books: books)
        draft.removeGenre("fantasy")
        #expect(draft.isDirty)
        #expect(draft.genres.map(\.name) == ["Humour", "History"])
        let edits = try #require(draft.makeEdits())
        #expect(edits.map(\.metadata.genres) == [["Humour"], ["Humour", "History"], []])

        // A genre no book has is nothing to remove.
        var none = BulkDraft(books: books)
        none.removeGenre("Romance")
        #expect(!none.isDirty)
    }

    /// GH21: adding what was removed, and removing what was added, take each other back.
    @Test func GH21_addAndRemoveUndoEachOther() throws {
        let books = genreBooks()
        var draft = BulkDraft(books: books)
        draft.addGenre("Romance")
        draft.removeGenre("Romance")
        #expect(!draft.isDirty)

        draft.removeGenre("History")
        draft.addGenre("History")
        // Asked for on every book now, not only the one that had it.
        #expect(draft.genres.first { $0.name == "History" }?.isMixed == false)
        #expect(try #require(draft.makeEdits()).map(\.metadata.genres) == [
            ["Fantasy", "Humour", "History"], ["Humour", "History", "Fantasy"], ["fantasy", "History"],
        ])
    }

    /// GH21: a text field and the genres are saved together.
    @Test func GH21_genresGoWithTheOtherFields() throws {
        var draft = BulkDraft(books: genreBooks())
        draft.values[.publisher] = "Ace"
        draft.removeGenre("Humour")
        let edits = try #require(draft.makeEdits())
        #expect(edits.map(\.metadata.publisher) == ["Ace", "Ace", "Ace"])
        #expect(edits.map(\.metadata.genres) == [["Fantasy"], ["History", "Fantasy"], ["fantasy"]])
    }
}

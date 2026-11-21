import Foundation
import Testing
import VoxCarrelAppCore
import VoxCarrelCore

@Suite struct BookDraftTests {
    @Test func startsWithTheBooksValuesAsText() {
        let draft = BookDraft(book: fullBook())
        #expect(draft.title == "Good Omens")
        #expect(draft.subtitle == "The Nice and Accurate Prophecies")
        #expect(draft.authors == "Terry Pratchett; Neil Gaiman")
        #expect(draft.narrators == "Martin Jarvis")
        #expect(draft.series == "Standalones")
        #expect(draft.seriesNumber == "1.5")
        #expect(draft.genre == "Fantasy")
        #expect(draft.year == "1990")
        #expect(draft.publisher == "Gollancz")
        #expect(draft.summary == "The world will end on Saturday.")
        #expect(draft.language == "en")
        #expect(draft.isbn == "9780575048003")
        #expect(draft.asin == "B0012345")
        #expect(draft.tags == "funny; apocalypse")
        #expect(draft.rating == 4)
        #expect(draft.cover == .keep)

        let bare = BookDraft(book: bareBook())
        #expect(bare.subtitle == "")
        #expect(bare.authors == "")
        #expect(bare.year == "")
        #expect(bare.tags == "")
    }

    /// D1
    @Test func untouchedDraftChangesNothing() {
        for book in [fullBook(), bareBook()] {
            let draft = BookDraft(book: book)
            #expect(!draft.isDirty)
            #expect(draft.problems.isEmpty)
            expectSame(draft.makeEdit(), BookEdit(book: book))
        }
    }

    /// D1: values the text fields could not round-trip are still left exactly as they were.
    @Test func untouchedDraftKeepsValuesTheFieldsCannotRoundTrip() {
        var book = fullBook()
        book.title = " Good Omens "
        book.authors = ["Pratchett; Gaiman", "pratchett; gaiman", ""]
        book.tags = ["a", "A"]
        book.subtitle = ""
        book.year = 12_000
        let draft = BookDraft(book: book)
        #expect(!draft.isDirty)
        #expect(draft.problems.isEmpty)
        expectSame(draft.makeEdit(), BookEdit(book: book))
    }

    /// D2
    @Test func surroundingSpacesAreNotAChange() {
        let book = fullBook()
        var draft = BookDraft(book: book)
        draft.title += " "
        draft.subtitle = "  " + draft.subtitle
        draft.authors = "Terry Pratchett ;Neil Gaiman; "
        draft.year = " 1990 "
        draft.summary += "\n"
        draft.tags = "funny;apocalypse"
        #expect(!draft.isDirty)
        expectSame(draft.makeEdit(), BookEdit(book: book))
    }

    /// D2
    @Test func aChangedFieldMakesItDirty() {
        let book = fullBook()
        var changes: [(BookDraft) -> BookDraft] = []
        func change(_ body: @escaping (inout BookDraft) -> Void) {
            changes.append { var draft = $0; body(&draft); return draft }
        }
        change { $0.title = "Better Omens" }
        change { $0.subtitle = "" }
        change { $0.authors = "Terry Pratchett" }
        change { $0.narrators = "Martin Jarvis; Someone Else" }
        change { $0.series = "Other" }
        change { $0.seriesNumber = "2" }
        change { $0.genre = "Comedy" }
        change { $0.year = "1991" }
        change { $0.publisher = "Corgi" }
        change { $0.summary = "Different." }
        change { $0.language = "fr" }
        change { $0.isbn = "" }
        change { $0.asin = "B0" }
        change { $0.tags = "funny" }
        change { $0.rating = 5 }
        for change in changes {
            #expect(change(BookDraft(book: book)).isDirty)
        }
    }

    /// D2
    @Test func settingOrRemovingTheCoverMakesItDirty() throws {
        let book = fullBook()
        let image = CoverImage(data: Data([1, 2, 3]), mime: "image/png")
        var draft = BookDraft(book: book)
        draft.cover = .set(image)
        #expect(draft.isDirty)
        let edit = try #require(draft.makeEdit())
        #expect(edit.cover == .set(image))
        #expect(edit.metadata == book.metadata)

        draft.cover = .remove
        #expect(draft.isDirty)
        #expect(draft.makeEdit()?.cover == .remove)
    }

    @Test func makeEditCarriesEveryChangedField() throws {
        var draft = BookDraft(book: bareBook(id: 3))
        draft.title = "  New Title "
        draft.subtitle = "Sub"
        draft.authors = "Le Guin, Ursula K.; Someone ; someone"
        draft.narrators = "N One"
        draft.series = "Hainish"
        draft.seriesNumber = "2.5"
        draft.genre = "SF"
        draft.year = "1969"
        draft.publisher = "Ace"
        draft.summary = "Line one.\nLine two.\n"
        draft.language = "en"
        draft.isbn = "123"
        draft.asin = "B01"
        draft.tags = "classic; Classic; winter"
        draft.rating = 3
        #expect(draft.isDirty)

        let edit = try #require(draft.makeEdit())
        #expect(edit.bookId == 3)
        var expected = BookMetadata(title: "New Title", authors: ["Le Guin, Ursula K.", "Someone"])
        expected.subtitle = "Sub"
        expected.narrators = ["N One"]
        expected.series = "Hainish"
        expected.seriesNumber = "2.5"
        expected.genre = "SF"
        expected.year = 1969
        expected.publisher = "Ace"
        expected.summary = "Line one.\nLine two."
        expected.language = "en"
        expected.isbn = "123"
        expected.asin = "B01"
        #expect(edit.metadata == expected)
        #expect(edit.tags == ["classic", "winter"])
        #expect(edit.rating == 3)
        #expect(edit.cover == .keep)
    }

    /// D3
    @Test func blankTextBecomesNilForOptionalFields() throws {
        var draft = BookDraft(book: fullBook())
        draft.subtitle = "  "
        draft.series = ""
        draft.seriesNumber = " "
        draft.genre = ""
        draft.year = "  "
        draft.publisher = ""
        draft.summary = "\n"
        draft.language = ""
        draft.isbn = ""
        draft.asin = ""
        draft.narrators = " ; "
        draft.tags = ""
        #expect(draft.problems.isEmpty)
        let metadata = try #require(draft.makeEdit()).metadata
        #expect(metadata.subtitle == nil)
        #expect(metadata.series == nil)
        #expect(metadata.seriesNumber == nil)
        #expect(metadata.genre == nil)
        #expect(metadata.year == nil)
        #expect(metadata.publisher == nil)
        #expect(metadata.summary == nil)
        #expect(metadata.language == nil)
        #expect(metadata.isbn == nil)
        #expect(metadata.asin == nil)
        #expect(metadata.narrators.isEmpty)
        #expect(draft.makeEdit()?.tags == [])
    }

    /// D3
    @Test(arguments: ["1", "1984", "9999", " 2001 "])
    func acceptsAWholeYear(_ text: String) throws {
        var draft = BookDraft(book: bareBook())
        draft.year = text
        #expect(draft.problems.isEmpty)
        let year = try #require(draft.makeEdit()).metadata.year
        #expect(year == Int(text.trimmingCharacters(in: .whitespaces)))
    }

    /// D3
    @Test(arguments: ["0", "10000", "-5", "19.84", "198x", "nineteen", "1 984", "+1984"])
    func rejectsAnythingElseAsAYear(_ text: String) {
        var draft = BookDraft(book: fullBook())
        draft.year = text
        #expect(draft.problems == ["Year must be a number such as 1984."])
        #expect(draft.makeEdit() == nil)
    }

    /// D4
    @Test func aBlankTitleIsAProblem() {
        var draft = BookDraft(book: fullBook())
        draft.title = "   "
        #expect(draft.problems == ["A book needs a title."])
        #expect(draft.makeEdit() == nil)

        draft.year = "soon"
        #expect(draft.problems == ["A book needs a title.", "Year must be a number such as 1984."])
    }

    /// D4
    @Test func aBlankAuthorIsNotAProblem() throws {
        var draft = BookDraft(book: fullBook())
        draft.authors = ""
        #expect(draft.problems.isEmpty)
        let edit = try #require(draft.makeEdit())
        #expect(edit.metadata.authors.isEmpty)
    }

    /// D5
    @Test func ratingIsClamped() {
        var draft = BookDraft(book: fullBook())
        draft.rating = 9
        #expect(draft.makeEdit()?.rating == 5)
        draft.rating = -2
        #expect(draft.makeEdit()?.rating == 0)
        draft.rating = 2
        #expect(draft.makeEdit()?.rating == 2)

        // Clamped before comparing: 9 on a five-star book is no change.
        var top = fullBook()
        top.rating = 5
        var unchanged = BookDraft(book: top)
        unchanged.rating = 9
        #expect(!unchanged.isDirty)
    }

    /// D6
    @Test func keepsDurationAndPageCount() throws {
        var draft = BookDraft(book: fullBook())
        draft.title = "Changed"
        draft.year = "2000"
        let metadata = try #require(draft.makeEdit()).metadata
        #expect(metadata.durationSeconds == 45_000)
        #expect(metadata.pageCount == 412)
    }

    /// D7
    @Test func appOnlyMarkersSkipEmptyFields() {
        var book = fullBook()
        book.appOnlyFields = [.subtitle, .series, .seriesNumber, .narrators, .year, .cover]
        var draft = BookDraft(book: book)
        #expect(draft.appOnlyMarkers(hasCover: true) == [.subtitle, .series, .seriesNumber, .narrators, .year, .cover])

        draft.subtitle = " "
        draft.narrators = " ; "
        draft.year = ""
        #expect(draft.appOnlyMarkers(hasCover: true) == [.series, .seriesNumber, .cover])
    }

    /// D7
    @Test func appOnlyMarkersNeverAddFieldsTheBookDoesNotList() {
        var book = fullBook()
        book.appOnlyFields = [.series]
        #expect(BookDraft(book: book).appOnlyMarkers(hasCover: true) == [.series])
        #expect(BookDraft(book: fullBook()).appOnlyMarkers(hasCover: true).isEmpty)
    }

    /// D7
    @Test func coverMarkerOnlyWhenThereIsACover() {
        var book = fullBook()
        book.appOnlyFields = [.cover, .title]
        var draft = BookDraft(book: book)
        #expect(draft.appOnlyMarkers(hasCover: true) == [.cover, .title])
        #expect(draft.appOnlyMarkers(hasCover: false) == [.title])
        // A cover about to be removed has nothing to mark.
        draft.cover = .remove
        #expect(draft.appOnlyMarkers(hasCover: true) == [.title])
    }

    /// D7: every field can be marked when it has a value, and none when the book is empty.
    @Test func everyFieldIsMarkedOnlyWhenFilled() {
        var full = fullBook()
        full.appOnlyFields = MetadataField.allCases
        #expect(BookDraft(book: full).appOnlyMarkers(hasCover: true) == Set(MetadataField.allCases))

        var bare = bareBook(title: "")
        bare.appOnlyFields = MetadataField.allCases
        #expect(BookDraft(book: bare).appOnlyMarkers(hasCover: false).isEmpty)
    }
}

import Foundation
import Testing
import VoxCarrelCore

@testable import VoxCarrelAppCore

/// What the series view shows of Audible's list, worked out from plain values (plan 9,
/// Task 4). SV2, SV3, SV5, SV11.
@Suite struct SeriesRowsTests {
    private let london = TimeZone(identifier: "Europe/London")!
    private let british = Locale(identifier: "en_GB")

    private func entry(
        _ id: Int64, _ title: String, number: String?, hidden: Bool = false, minutes: Int? = 480
    ) -> MissingEntry {
        let edition = AudibleSeriesEdition(
            asin: "B0ENTRY00\(id)", title: title, number: number, sort: Double(id), authors: ["Ann Author", "B. Other"],
            narrators: ["Ned Narrator"], minutes: minutes, isAbridged: false,
            releaseDate: Date(timeIntervalSince1970: 1_500_000_000))
        return MissingEntry(
            id: id, entry: SeriesEntry(number: number, sort: Double(id), preferred: edition, asins: [edition.asin], titles: [title]),
            isHidden: hidden)
    }

    private func link(store: AudibleStore = .us) -> SeriesLink {
        // The 23rd of November 2026, at noon in London.
        SeriesLink(
            seriesName: "My Saga", audibleSeriesId: "B0SERIES01", audibleSeriesTitle: "A Saga Novel (publication order)",
            store: store, checkedAt: Date(timeIntervalSince1970: 1_795_435_200))
    }

    private func completeness(
        owned: Int = 9, missing: [MissingEntry] = [], differences: [Int64: String] = [:], notInList: [Int64] = [],
        store: AudibleStore = .us
    ) -> SeriesCompleteness {
        SeriesCompleteness(
            link: link(store: store), ownedCount: owned, totalCount: owned + missing.filter { !$0.isHidden }.count,
            missing: missing, numberDifferences: differences, notInList: notInList)
    }

    private func header(
        _ completeness: SeriesCompleteness?, canCheck: Bool = true, canChange: Bool = true, hasEdits: Bool = false,
        showsHidden: Bool = false
    ) -> SeriesHeader {
        SeriesRows.header(
            completeness, canCheck: canCheck, canChange: canChange, hasEdits: hasEdits, showsHidden: showsHidden,
            locale: british, timeZone: london)
    }

    // MARK: SV11 The header's words

    /// SV1, SV11: a series that has not been checked.
    @Test func aSeriesThatIsNotLinked() {
        let said = header(nil, showsHidden: true)
        #expect(said.summary == "Not checked against Audible")
        #expect(said.source == nil)
        #expect(said.notes == [])
        #expect(said.canCheck)
        #expect(!said.canUseAudibleNumbers)
        #expect(!said.canUnlink)
        #expect(!said.isLinked)
        #expect(said.hiddenCount == 0)
        #expect(said.showsHidden)
        #expect(!header(nil, canCheck: false).canCheck)
    }

    /// SV11: the count is of entries, hidden ones left out; the source names the
    /// Audible series, the store and the day it was checked.
    @Test func theSummaryAndTheSource() {
        let missing = (1...18).map { entry(Int64($0), "Book \($0)", number: String($0)) }
        let said = header(completeness(owned: 9, missing: missing + [entry(40, "Hidden", number: "40", hidden: true)]))
        #expect(said.summary == "9 of 27 on Audible's list")
        #expect(said.source == "A Saga Novel (publication order) · Audible US · checked 23 Nov 2026")
        #expect(said.isLinked)
        #expect(said.canUnlink)
        #expect(header(completeness(store: .uk)).source?.contains("· Audible UK ·") == true)
        #expect(header(completeness(store: .au)).source?.contains("· Audible Australia ·") == true)
        #expect(header(completeness(owned: 1)).summary == "1 of 1 on Audible's list")
    }

    /// SV11: a note is there only when its count is above zero, in the singular or the plural.
    @Test func theNotes() {
        #expect(header(completeness()).notes == [])
        #expect(header(completeness(differences: [1: "2"])).notes == ["1 book is numbered differently on Audible."])
        #expect(
            header(completeness(differences: [1: "2", 2: "3", 3: "4"])).notes
                == ["3 books are numbered differently on Audible."])
        #expect(header(completeness(notInList: [7])).notes == ["1 book is not on Audible's list."])
        #expect(header(completeness(notInList: [7, 8])).notes == ["2 books are not on Audible's list."])
        let hidden = [entry(1, "One", number: "1", hidden: true), entry(2, "Two", number: "2", hidden: true)]
        #expect(header(completeness(missing: hidden)).notes == ["2 hidden"])
        #expect(header(completeness(missing: [hidden[0]])).notes == ["1 hidden"])
        #expect(header(completeness(missing: hidden)).hiddenCount == 2)
        let all = header(completeness(missing: hidden, differences: [1: "2"], notInList: [7, 8]))
        #expect(
            all.notes == [
                "1 book is numbered differently on Audible.", "2 books are not on Audible's list.", "2 hidden",
            ])
    }

    /// SV10: Audible's numbers can be used only when a number differs, nothing is in
    /// the way, and no book of the series has unsaved edits.
    @Test func whenAudiblesNumbersCanBeUsed() {
        let differs = completeness(differences: [1: "2"])
        #expect(header(differs).canUseAudibleNumbers)
        #expect(!header(completeness()).canUseAudibleNumbers)
        #expect(!header(differs, hasEdits: true).canUseAudibleNumbers)
        #expect(!header(differs, canChange: false).canUseAudibleNumbers)
        #expect(!header(differs, canChange: false).canUnlink)
        // Unsaved edits do not stop a check or an unlinking.
        #expect(header(differs, hasEdits: true).canUnlink)
        #expect(header(differs, hasEdits: true).canCheck)
    }

    // MARK: SV5 Rows

    /// SV5: a missing entry's row: a negative id of its own, and a book built from the
    /// entry under the owner's series name, with nothing of a library book about it.
    @Test func aRowForAMissingEntry() {
        let missing = entry(12, "The Lost Book", number: "7")
        let row = SeriesRows.row(for: missing, link: link())
        #expect(row.id == -12)
        #expect(row.id == SeriesRows.rowId(forEntry: 12))
        #expect(row.missing == missing)
        #expect(row.isMissing)
        #expect(row.book.id == nil)
        #expect(row.book.title == "The Lost Book")
        #expect(row.book.series == "My Saga")
        #expect(row.book.seriesNumber == "7")
        #expect(row.book.authors == ["Ann Author", "B. Other"])
        #expect(row.book.narrators == ["Ned Narrator"])
        #expect(row.book.asin == "B0ENTRY0012")
        #expect(row.book.durationSeconds == 28_800)
        #expect(row.book.dateAdded == link().checkedAt)
        #expect(row.book.readStatus == .unread)
        #expect(row.book.externalCopies.isEmpty)
        #expect(!row.book.needsAttention)
        #expect(!row.hasFiles && !row.hasAudio && !row.hasEbook)
        #expect(row.formats.isEmpty && row.outsideFiles.isEmpty)
        #expect(row.coverURL == nil && row.coverModified == nil)
        #expect(!row.hasWriteProblem)
        #expect(row.lengthProblemFiles == 0 && row.repairableLengthFiles == 0 && row.unmeasuredLengthFiles == 0)

        #expect(SeriesRows.row(for: entry(3, "No Length", number: nil, minutes: nil), link: link()).book.durationSeconds == nil)
        #expect(SeriesRows.row(for: entry(3, "No Number", number: nil), link: link()).book.seriesNumber == nil)
        // A library book's row is not a missing one.
        let book = BookRow(
            id: 5, book: Book(metadata: BookMetadata(title: "Mine")), hasAudio: true, hasEbook: false, formats: [.m4b],
            coverURL: nil, hasWriteProblem: false)
        #expect(!book.isMissing && book.missing == nil)
    }

    /// SV8: a missing entry in the words the inspector shows.
    @Test func aMissingEntryInWords() {
        let info = SeriesRows.info(for: entry(12, "The Lost Book", number: "7", minutes: 615), link: link(), canChange: true)
        #expect(info.title == "The Lost Book")
        #expect(info.seriesText == "My Saga #7")
        #expect(info.authorsText == "Ann Author, B. Other")
        #expect(info.narratorsText == "Ned Narrator")
        #expect(info.lengthText == "10h 15m")
        #expect(info.storeText == "Audible US")
        #expect(info.note == "This book is on Audible's list for the series and is not in your library.")
        #expect(!info.isHidden)
        #expect(info.canChange)

        let bare = SeriesRows.info(
            for: entry(3, "Bare", number: nil, hidden: true, minutes: nil), link: link(store: .uk), canChange: false)
        #expect(bare.seriesText == "My Saga")
        #expect(bare.lengthText == "")
        #expect(bare.storeText == "Audible UK")
        #expect(bare.isHidden)
        #expect(!bare.canChange)
    }

    /// The buttons' words: a checked series is checked again, a hidden book is shown.
    @Test func theButtonsWords() {
        #expect(header(nil).checkTitle == "Check Series")
        #expect(header(completeness()).checkTitle == "Check Again")
        let shown = SeriesRows.info(for: entry(1, "One", number: "1"), link: link(), canChange: true)
        let hidden = SeriesRows.info(for: entry(2, "Two", number: "2", hidden: true), link: link(), canChange: true)
        #expect(shown.hideTitle == "Hide")
        #expect(hidden.hideTitle == "Show")
    }

    /// A missing row says that it is one, in a word and in full; a book's row does not.
    @Test func aMissingRowSaysSo() {
        let row = SeriesRows.row(for: entry(12, "The Lost Book", number: "7"), link: link())
        #expect(row.missingLabel == "Missing")
        #expect(row.missingText == "On Audible's list, not in your library")
        #expect(row.summaryText.contains("On Audible's list, not in your library"))
        let book = BookRow(
            id: 4, book: Book(metadata: BookMetadata(title: "Here")), hasAudio: true, hasEbook: false, formats: [.m4b], coverURL: nil,
            hasWriteProblem: false)
        #expect(book.missingLabel == nil)
        #expect(book.missingText == nil)
        #expect(!book.summaryText.contains("Audible's list"))
    }

    /// SV5: the hidden entries have rows only while hidden entries are shown; a series
    /// that is not linked has none.
    @Test func rowsForTheEntriesThatAreNotHidden() {
        let list = completeness(missing: [
            entry(1, "One", number: "1"), entry(2, "Two", number: "2", hidden: true), entry(3, "Three", number: "3"),
        ])
        #expect(SeriesRows.rows(of: list, showingHidden: false).map(\.id) == [-1, -3])
        #expect(SeriesRows.rows(of: list, showingHidden: true).map(\.id) == [-1, -2, -3])
        #expect(SeriesRows.rows(of: nil, showingHidden: true).isEmpty)
    }

    /// SV5: in a series' own order missing rows fall in place by number; under any
    /// other sort they follow the library's books, in series order.
    @Test func missingRowsAreSortedIntoTheSeries() {
        func book(_ id: Int64, _ title: String, number: String?, seconds: Double) -> BookRow {
            var metadata = BookMetadata(title: title, authors: ["Zed"])
            metadata.series = "My Saga"
            metadata.seriesNumber = number
            metadata.durationSeconds = seconds
            var book = Book(metadata: metadata, dateAdded: Date(timeIntervalSinceReferenceDate: Double(id)))
            book.id = id
            return BookRow(id: id, book: book, hasAudio: true, hasEbook: false, formats: [.m4b], coverURL: nil, hasWriteProblem: false)
        }
        let series = SidebarItem.browse(.series, "My Saga")
        let rows = [
            book(1, "Zulu", number: "1", seconds: 100), book(2, "Alpha", number: "3", seconds: 300),
            book(3, "Mike", number: nil, seconds: 200),
            SeriesRows.row(for: entry(4, "Bravo", number: "2"), link: link()),
            SeriesRows.row(for: entry(5, "Yankee", number: "10"), link: link()),
            SeriesRows.row(for: entry(6, "Charlie", number: "2.5"), link: link()),
            SeriesRows.row(for: entry(7, "Delta", number: nil), link: link()),
        ]
        for order in [rows, rows.reversed()] {
            #expect(BookSort().sorted(order, showing: series).map(\.id) == [1, -4, -6, 2, -5, -7, 3])
            #expect(BookSort(key: .title, ascending: false).sorted(order, showing: series).map(\.id) == [-5, 2, -6, -4, 1, 3, -7])
            // The library's books by the sort; then the missing ones in series order, whichever way the sort runs.
            #expect(BookSort(key: .length).sorted(order, showing: series).map(\.id) == [1, 3, 2, -4, -6, -5, -7])
            #expect(BookSort(key: .length, ascending: false).sorted(order, showing: series).map(\.id) == [2, 3, 1, -4, -6, -5, -7])
            #expect(BookSort(key: .author).sorted(order, showing: series).map(\.id) == [2, 3, 1, -4, -6, -5, -7])
            #expect(BookSort(key: .dateAdded, ascending: false).sorted(order, showing: series).map(\.id) == [3, 2, 1, -4, -6, -5, -7])
        }
    }

    /// What is said when a list cannot be stored or changed: plain words.
    @Test func whyAListCouldNotBeChanged() {
        #expect(
            UserMessage.text(for: SeriesListError.emptyList)
                == "Audible has no books listed for that series, so nothing was changed.")
        #expect(UserMessage.text(for: SeriesListError.noBooks) == "No book in your library is in that series any more.")
        #expect(
            UserMessage.text(for: SeriesListError.entryNotFound(4))
                == "That book is no longer on the list. Check the series again.")
    }

    // MARK: SV2 Which books are asked about

    private func asked(_ id: Int64, number: String?, asin: String? = nil) -> SeriesCheckBook {
        SeriesCheckBook(id: id, title: "Book \(id)", author: "Ann Author", number: number, asin: asin)
    }

    /// SV2: up to five books: those with an Audible ID first, then by number.
    @Test func theBooksToAskAbout() {
        let books = [
            asked(1, number: "10"), asked(2, number: "2"), asked(3, number: nil), asked(4, number: "7", asin: "B0ASIN0004"),
            asked(5, number: "1"), asked(6, number: "3", asin: "B0ASIN0006"), asked(7, number: "4"), asked(8, number: "2"),
        ]
        #expect(SeriesRows.booksToAsk(books).map(\.id) == [6, 4, 5, 2, 8])
        #expect(SeriesRows.booksToAsk(books.reversed()).map(\.id) == [6, 4, 5, 2, 8])
        #expect(SeriesRows.booksToAsk(Array(books.prefix(3))).map(\.id) == [2, 1, 3])
        #expect(SeriesRows.booksToAsk([]).isEmpty)
    }

    private func ref(_ id: String, _ title: String? = nil, number: String? = nil, store: AudibleStore = .us) -> AudibleSeriesRef {
        AudibleSeriesRef(id: id, title: title ?? "Series \(id)", number: number, store: store)
    }

    /// SV2: the asking stops once two books have been found in a series and every
    /// answer that found one names the same single series.
    @Test func whenTheAnswersAgree() {
        let a = SeriesAnswer(refs: [ref("B0SERIES0A", number: "1")])
        let a2 = SeriesAnswer(refs: [ref("B0SERIES0A", number: "2")])
        let b = SeriesAnswer(refs: [ref("B0SERIES0B")])
        let both = SeriesAnswer(refs: [ref("B0SERIES0A"), ref("B0SERIES0B")])
        let none = SeriesAnswer(refs: [])
        #expect(!SeriesRows.agree([]))
        // One answer is not yet agreement: the first book may be the odd one out.
        #expect(!SeriesRows.agree([a]))
        #expect(SeriesRows.agree([a, a2]))
        #expect(SeriesRows.agree([a, none, a2]))
        #expect(!SeriesRows.agree([a, none]))
        #expect(!SeriesRows.agree([a, b]))
        #expect(!SeriesRows.agree([a, both]))
        #expect(!SeriesRows.agree([both, both]))
        // The same ID in another store is another series.
        #expect(!SeriesRows.agree([a, SeriesAnswer(refs: [ref("B0SERIES0A", store: .uk)])]))
    }

    // MARK: SV3 Which series

    /// SV3: every series found, the one with the most books first, with the numbers
    /// the books found in it have there: Audible's, not the owner's own.
    @Test func theSeriesFoundAreCounted() {
        let answers = [
            SeriesAnswer(refs: [ref("B0SERIES0B", "Beta", number: "1")]),
            SeriesAnswer(refs: [ref("B0SERIES0A", "Alpha", number: "1"), ref("B0SERIES0C", "Gamma", number: "4")]),
            SeriesAnswer(refs: [ref("B0SERIES0A", "Alpha", number: "2"), ref("B0SERIES0C", "Gamma", number: "5")]),
            SeriesAnswer(refs: []),
        ]
        let found = SeriesRows.tally(answers)
        #expect(found.map(\.ref.id) == ["B0SERIES0A", "B0SERIES0C", "B0SERIES0B"])
        #expect(found.map(\.count) == [2, 2, 1])
        #expect(found.map(\.numbers) == [["1", "2"], ["4", "5"], ["1"]])
        // A book Audible gives no number in a series has none there.
        let unnumbered = SeriesRows.tally([
            SeriesAnswer(refs: [ref("B0SERIES0A", number: " 2 ")]), SeriesAnswer(refs: [ref("B0SERIES0A")]),
            SeriesAnswer(refs: [ref("B0SERIES0A", number: "  ")]),
        ])
        #expect(unnumbered.map(\.numbers) == [["2", nil, nil]])
        // The series itself: no one book's number in it.
        #expect(found.allSatisfy { $0.ref.number == nil })
        #expect(SeriesRows.tally(answers.reversed()) == found)
        #expect(SeriesRows.tally([]).isEmpty)
    }

    /// SV3: one series is used without asking only when it alone holds the most books.
    @Test func whenOneSeriesIsClearlyTheOne() {
        func found(_ id: String, _ count: Int) -> SeriesFound {
            SeriesFound(ref: ref(id), count: count, numbers: Array(repeating: "1", count: count))
        }
        #expect(SeriesRows.clearChoice([found("B0SERIES0A", 1)])?.id == "B0SERIES0A")
        #expect(SeriesRows.clearChoice([found("B0SERIES0A", 3), found("B0SERIES0B", 2)])?.id == "B0SERIES0A")
        #expect(SeriesRows.clearChoice([found("B0SERIES0A", 2), found("B0SERIES0B", 2)]) == nil)
        #expect(SeriesRows.clearChoice([found("B0SERIES0A", 2), found("B0SERIES0B", 2), found("B0SERIES0C", 1)]) == nil)
        #expect(SeriesRows.clearChoice([]) == nil)
    }

    /// SV3: a choice says where it is listed and which of the owner's books are in it.
    @Test func aChoiceInWords() {
        func choice(_ numbers: [String?], store: AudibleStore = .us) -> SeriesChoice {
            SeriesRows.choice(
                for: SeriesFound(ref: ref("B0SERIES0A", "Alpha", store: store), count: numbers.count, numbers: numbers))
        }
        #expect(choice(["1", "2", "6"]).detail == "Audible US · your books are numbers 1, 2 and 6 here")
        #expect(choice(["2", "10"]).detail == "Audible US · your books are numbers 2 and 10 here")
        // Two copies of one book are one number.
        #expect(choice(["1", "1", "2"]).detail == "Audible US · your books are numbers 1 and 2 here")
        #expect(choice(["3", "3"]).detail == "Audible US · your books are number 3 here")
        #expect(choice(["6"], store: .uk).detail == "Audible UK · your book is number 6 here")
        #expect(choice(["6", nil]).detail == "Audible US · 2 of your books are here")
        #expect(choice([nil]).detail == "Audible US · 1 of your books is here")
        #expect(choice(["1"]).title == "Alpha")
        #expect(choice(["1"]).id == SeriesRows.choiceId(ref("B0SERIES0A")))
        // The same ID in two stores is two choices.
        #expect(choice(["1"]).id != choice(["1"], store: .uk).id)
    }
}

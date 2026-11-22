import Foundation
import VoxCarrelCore

// What the view of one series shows of Audible's list of it (plan 9, Task 4). SV2, SV3,
// SV5, SV11. Everything here is worked out from plain values: nothing is read or asked.

/// What is said above the books of a series about Audible's list of it.
public struct SeriesHeader: Equatable, Sendable {
    /// "9 of 27 on Audible's list", or "Not checked against Audible". Empty for the
    /// moment between choosing a series and its books being read.
    public var summary: String
    /// "A Jack Ryan Novel (publication order) · Audible US · checked 23 Nov 2026"; nil
    /// for a series that has not been checked.
    public var source: String?
    /// Each a line: "3 books are numbered differently on Audible.", "1 book is not on
    /// Audible's list.", "2 hidden". Only those there is something to say for.
    public var notes: [String]
    /// Whether Check Series applies: Audible is on as a lookup source, a library is
    /// open, and nothing is running or in the way.
    public var canCheck: Bool
    /// Whether the books numbered differently can be given Audible's numbers now.
    public var canUseAudibleNumbers: Bool
    public var canUnlink: Bool
    /// Whether the hidden entries are shown among the missing ones (`AppModel.showsHiddenMissing`).
    public var showsHidden: Bool
    /// Whether the series has been checked: there is a list to check again or unlink.
    public var isLinked: Bool
    /// How many entries of the list are hidden: whether there is anything for
    /// "Show Hidden" to show.
    public var hiddenCount: Int

    /// What the button that asks Audible says: a series that has a list is checked again.
    public var checkTitle: String {
        isLinked ? "Check Again" : "Check Series"
    }
}

/// One of the Audible series the owner is asked to choose between.
public struct SeriesChoice: Identifiable, Equatable, Sendable {
    /// The store and the series' own ID: what `AppModel.chooseSeries` is given.
    public var id: String
    public var title: String
    /// "Audible US · your books are numbers 1, 2 and 6 here"
    public var detail: String
}

/// What the inspector shows of the one selected book that the library does not have.
public struct MissingBookInfo: Equatable, Sendable {
    public var title: String
    /// "Tidewater Chronicles #4": the owner's name for the series, with Audible's number.
    public var seriesText: String
    /// "Ines Calloway, A. N. Other"; empty when Audible names none.
    public var authorsText: String
    public var narratorsText: String
    /// "10h 15m"; empty when Audible gives no length.
    public var lengthText: String
    /// Where the list came from: "Audible US".
    public var storeText: String
    /// Why the book is shown at all.
    public var note: String
    /// Whether the owner has hidden it: Hide is then Show.
    public var isHidden: Bool
    /// Whether it can be added or hidden now: nothing is running or in the way.
    public var canChange: Bool

    /// What the action that hides it says: a hidden book is shown again.
    public var hideTitle: String {
        isHidden ? "Show" : "Hide"
    }
}

/// The three things that can be done with a book the library does not have, as a
/// context menu offers them.
public struct MissingActions: Equatable, Sendable {
    /// Add as Audible Book.
    public var canAdd: Bool
    /// Show on Audible.
    public var canShow: Bool
    /// Hide, or Show.
    public var canSetHidden: Bool
    /// "Hide", or "Show" for a book that is hidden.
    public var hideTitle: String
    /// Whether the book is hidden now.
    public var isHidden: Bool
}

/// A book of a library series, as Check Series asks Audible about it.
public struct SeriesCheckBook: Equatable, Sendable {
    public var id: Int64
    public var title: String
    /// The book's first author; nil when it has none.
    public var author: String?
    /// The owner's number for it in the series.
    public var number: String?
    /// Its Audible ID, when it has one: its own ASIN, or that of an Audible copy.
    public var asin: String?

    public init(id: Int64, title: String, author: String?, number: String?, asin: String?) {
        self.id = id
        self.title = title
        self.author = author
        self.number = number
        self.asin = asin
    }
}

/// The series the rows are the books of, and what the catalogue holds about it.
public struct ShownSeries: Equatable, Sendable {
    /// The series' name, exactly as the sidebar has it.
    public var name: String
    /// Nil when the series has not been checked against Audible.
    public var completeness: SeriesCompleteness?
    /// Every library book of the series, whatever a search has narrowed the rows to.
    public var bookIds: Set<Int64>

    public init(name: String, completeness: SeriesCompleteness?, bookIds: Set<Int64>) {
        self.name = name
        self.completeness = completeness
        self.bookIds = bookIds
    }
}

/// The library's books for a sidebar item and, when the item is one series, what the
/// catalogue holds about that series: read together, so that they agree.
public struct ShownBooks: Equatable, Sendable {
    public var rows: [BookRow]
    public var series: ShownSeries?

    public init(rows: [BookRow], series: ShownSeries?) {
        self.rows = rows
        self.series = series
    }
}

/// What Audible answered for one book that was asked about.
struct SeriesAnswer: Equatable, Sendable {
    /// The owner's number for the book.
    var number: String?
    /// The series Audible lists the book in; empty when it lists none, or not the book.
    var refs: [AudibleSeriesRef]
}

/// An Audible series that some of the books asked about are in.
struct SeriesFound: Equatable, Sendable {
    /// The series; its `number` is nil.
    var ref: AudibleSeriesRef
    /// How many of the books asked about are in it.
    var count: Int
    /// The owner's numbers of those books, in series order; nil for a book with none.
    var numbers: [String?]
}

/// The series the owner is being asked to choose between, and what they are for.
struct PendingSeriesChoice: Equatable, Sendable {
    /// The library series that was being checked.
    var name: String
    var found: [SeriesFound]
}

enum SeriesRows {
    // MARK: SV5 Rows

    /// The id of the row that stands for a stored entry: the entry's own id, negative,
    /// so that it is no book's and no other entry's.
    static func rowId(forEntry id: Int64) -> Int64 {
        -abs(id)
    }

    /// The details a missing entry would have as a book of the library: Audible's
    /// title, authors, narrators, length and ID, under the owner's own name for the
    /// series, with Audible's number.
    static func metadata(for entry: SeriesEntry, link: SeriesLink) -> BookMetadata {
        var metadata = BookMetadata(title: entry.preferred.title, authors: entry.preferred.authors)
        metadata.narrators = entry.preferred.narrators
        metadata.series = link.seriesName
        metadata.seriesNumber = entry.number?.trimmedOrNil
        metadata.asin = entry.preferred.asin.trimmedOrNil
        metadata.durationSeconds = entry.preferred.minutes.map { Double($0) * 60 }
        return metadata
    }

    /// The row that stands for a missing entry: a book with no files, no cover and no
    /// copies anywhere, which is in no library.
    static func row(for missing: MissingEntry, link: SeriesLink) -> BookRow {
        // Dated when the list was checked: the same every time the row is made.
        let book = Book(metadata: metadata(for: missing.entry, link: link), dateAdded: link.checkedAt)
        return BookRow(
            id: rowId(forEntry: missing.id), book: book, hasAudio: false, hasEbook: false, formats: [], coverURL: nil,
            hasWriteProblem: false, hasFiles: false, missing: missing)
    }

    /// One row for each missing entry that is not hidden, and for the hidden ones too
    /// when they are shown, in the list's order. None for a series that is not linked.
    static func rows(of completeness: SeriesCompleteness?, showingHidden: Bool) -> [BookRow] {
        guard let completeness else { return [] }
        return completeness.missing
            .filter { showingHidden || !$0.isHidden }
            .map { row(for: $0, link: completeness.link) }
    }

    static let missingNote = "This book is on Audible's list for the series and is not in your library."

    /// SV8: a missing entry in the words the inspector shows.
    static func info(for missing: MissingEntry, link: SeriesLink, canChange: Bool) -> MissingBookInfo {
        let row = row(for: missing, link: link)
        return MissingBookInfo(
            title: row.book.title, seriesText: row.seriesText, authorsText: row.authorsText,
            narratorsText: row.book.narrators.joined(separator: ", "), lengthText: row.lengthText,
            storeText: storeName(link.store), note: missingNote, isHidden: missing.isHidden, canChange: canChange)
    }

    // MARK: SV11 The header

    static let notChecked = "Not checked against Audible"

    /// What is said while the series' books are still being read: nothing yet.
    static func loadingHeader(showsHidden: Bool) -> SeriesHeader {
        SeriesHeader(
            summary: "", source: nil, notes: [], canCheck: false, canUseAudibleNumbers: false, canUnlink: false,
            showsHidden: showsHidden, isLinked: false, hiddenCount: 0)
    }

    /// - Parameters:
    ///   - completeness: What the catalogue holds for the series; nil when it is not linked.
    ///   - canCheck: Whether Audible may be asked now.
    ///   - canChange: Whether the library may be changed now: nothing is running or in the way.
    ///   - hasEdits: Whether a book of the series has edits that are not saved.
    static func header(
        _ completeness: SeriesCompleteness?, canCheck: Bool, canChange: Bool, hasEdits: Bool, showsHidden: Bool,
        locale: Locale = .current, timeZone: TimeZone = .current
    ) -> SeriesHeader {
        guard let completeness else {
            return SeriesHeader(
                summary: notChecked, source: nil, notes: [], canCheck: canCheck, canUseAudibleNumbers: false,
                canUnlink: false, showsHidden: showsHidden, isLinked: false, hiddenCount: 0)
        }
        let link = completeness.link
        let day = link.checkedAt.formatted(
            Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale, timeZone: timeZone))
        let hidden = completeness.missing.filter(\.isHidden).count
        var notes: [String] = []
        let differing = completeness.numberDifferences.count
        if differing > 0 {
            notes.append(
                differing == 1
                    ? "1 book is numbered differently on Audible."
                    : "\(differing) books are numbered differently on Audible.")
        }
        let unlisted = completeness.notInList.count
        if unlisted > 0 {
            notes.append(
                unlisted == 1 ? "1 book is not on Audible's list." : "\(unlisted) books are not on Audible's list.")
        }
        if hidden > 0 { notes.append("\(hidden) hidden") }
        return SeriesHeader(
            summary: "\(completeness.ownedCount) of \(completeness.totalCount) on Audible's list",
            source: "\(link.audibleSeriesTitle) · \(storeName(link.store)) · checked \(day)",
            notes: notes, canCheck: canCheck,
            // SV10
            canUseAudibleNumbers: canChange && differing > 0 && !hasEdits,
            canUnlink: canChange, showsHidden: showsHidden, isLinked: true, hiddenCount: hidden)
    }

    /// "Audible US", "Audible UK", "Audible Australia"
    static func storeName(_ store: AudibleStore) -> String {
        "Audible \(store.shortTitle)"
    }

    // MARK: SV2 Asking

    /// The most books of a series that Audible is asked about.
    static let askLimit = 5

    /// SV2: the books to ask about, in the order to ask: those with an Audible ID
    /// first, then by the owner's number, then by id. No more than `askLimit`.
    static func booksToAsk(_ books: [SeriesCheckBook]) -> [SeriesCheckBook] {
        let ordered = books.sorted { a, b in
            let known = (a.asin?.trimmedOrNil != nil, b.asin?.trimmedOrNil != nil)
            if known.0 != known.1 { return known.0 }
            let byNumber = BookSort.compareSeriesNumbers(a.number, b.number)
            if byNumber != .orderedSame { return byNumber == .orderedAscending }
            return a.id < b.id
        }
        return Array(ordered.prefix(askLimit))
    }

    /// What tells one Audible series from another: its store and its own ID. Also a
    /// choice's id.
    static func choiceId(_ ref: AudibleSeriesRef) -> String {
        "\(ref.store.rawValue):\(ref.id)"
    }

    /// SV2: whether the answers so far agree on one series, so that no more books need
    /// be asked about: at least two books were found in a series, and every answer
    /// that found any names the same single one. (One answer alone is not agreement:
    /// the first book asked about may be the one Audible files somewhere else.)
    static func agree(_ answers: [SeriesAnswer]) -> Bool {
        let found = answers.filter { !$0.refs.isEmpty }
        guard found.count >= 2, found.allSatisfy({ $0.refs.count == 1 }) else { return false }
        return Set(found.flatMap { $0.refs.map(choiceId) }).count == 1
    }

    // MARK: SV3 Which series

    /// SV3: every series found, the one that holds the most of the books first; then
    /// by title, then by store and ID. The same whatever order the answers came in.
    static func tally(_ answers: [SeriesAnswer]) -> [SeriesFound] {
        var found: [String: SeriesFound] = [:]
        for answer in answers {
            // A series named twice for one book holds that book once.
            var seen: Set<String> = []
            for ref in answer.refs where seen.insert(choiceId(ref)).inserted {
                var series = ref
                series.number = nil
                var entry = found[choiceId(ref)] ?? SeriesFound(ref: series, count: 0, numbers: [])
                // Of two spellings of its title, the one that sorts first: no order of answers decides.
                if series.title < entry.ref.title { entry.ref.title = series.title }
                entry.count += 1
                entry.numbers.append(answer.number?.trimmedOrNil)
                found[choiceId(ref)] = entry
            }
        }
        return found.values
            .map { entry in
                var entry = entry
                entry.numbers.sort { BookSort.compareSeriesNumbers($0, $1) == .orderedAscending }
                return entry
            }
            .sorted { a, b in
                if a.count != b.count { return a.count > b.count }
                let byTitle = a.ref.title.localizedStandardCompare(b.ref.title)
                if byTitle != .orderedSame { return byTitle == .orderedAscending }
                return choiceId(a.ref) < choiceId(b.ref)
            }
    }

    /// SV3: the series to use without asking: the one that alone holds the most of the
    /// books asked about. Nil when two tie for that, and when none was found.
    /// `found` is in `tally`'s order.
    static func clearChoice(_ found: [SeriesFound]) -> AudibleSeriesRef? {
        guard let first = found.first else { return nil }
        if found.count > 1, found[1].count >= first.count { return nil }
        return first.ref
    }

    /// SV3: a series as the owner is offered it, with which of their books are in it.
    static func choice(for found: SeriesFound) -> SeriesChoice {
        let numbers = found.numbers.compactMap { $0 }
        let books: String
        if numbers.count < found.numbers.count || numbers.isEmpty {
            books = found.count == 1 ? "1 of your books is here" : "\(found.count) of your books are here"
        } else if numbers.count == 1 {
            books = "your book is number \(numbers[0]) here"
        } else {
            books = "your books are numbers \(AppModel.list(numbers)) here"
        }
        return SeriesChoice(
            id: choiceId(found.ref), title: found.ref.title, detail: "\(storeName(found.ref.store)) · \(books)")
    }
}

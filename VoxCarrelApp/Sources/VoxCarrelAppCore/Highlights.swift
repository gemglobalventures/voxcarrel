import Foundation
import VoxCarrelCore

/// What is said of a highlight's place and day.
enum HighlightText {
    private static let american = Locale(identifier: "en_US")

    static func number(_ value: Int) -> String {
        value.formatted(.number.locale(american))
    }

    /// "12 highlights", "1 highlight", "No highlights".
    static func count(_ count: Int) -> String {
        switch count {
        case ..<1: "No highlights"
        case 1: "1 highlight"
        default: "\(number(count)) highlights"
        }
    }

    /// "Location 1,204", "Page 87", "at 16 h 54 min", and for a clip with an end
    /// "at 16 h 54 min, 30 seconds long". Nil when there is no place to name: none
    /// given, or only the highlight's turn in its source's own order.
    static func place(location: Double?, end: Double?, kind: HighlightLocationKind?) -> String? {
        guard let location, location.isFinite, location >= 0, let kind else { return nil }
        switch kind {
        case .location: return "Location \(number(Int(location.rounded())))"
        case .page: return "Page \(number(Int(location.rounded())))"
        case .order: return nil
        case .time:
            let at = "at \(time(location))"
            guard let end, end.isFinite, let long = length(end - location) else { return at }
            return "\(at), \(long) long"
        }
    }

    /// A time into an audiobook, to the minute: "16 h 54 min", "54 min"; in the first
    /// minute, "42 sec". Never later than it is.
    static func time(_ seconds: Double) -> String {
        let whole = Int(seconds)
        let (hours, minutes) = (whole / 3600, whole % 3600 / 60)
        if hours > 0 { return "\(hours) h \(minutes) min" }
        return minutes > 0 ? "\(minutes) min" : "\(whole) sec"
    }

    /// How long a clip is: "30 seconds", "1 second", "2 min 30 sec", "2 min". Nil for
    /// one of no length.
    static func length(_ seconds: Double) -> String? {
        let whole = Int(seconds.rounded())
        guard whole > 0 else { return nil }
        if whole < 60 { return whole == 1 ? "1 second" : "\(whole) seconds" }
        return whole % 60 == 0 ? "\(whole / 60) min" : "\(whole / 60) min \(whole % 60) sec"
    }

    /// The day, as the locale writes a date of middling length: "4 May 2016".
    static func date(_ date: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        date.formatted(
            Date.FormatStyle(
                date: .abbreviated, time: .omitted, locale: locale, calendar: calendar, timeZone: calendar.timeZone))
    }

    static let emptyMark = "Marked while listening"
}

/// One highlight as the inspector and the sheet show it.
public struct HighlightRow: Identifiable, Equatable, Sendable {
    public var id: Int64
    /// The passage; empty for a note alone, and for a bare mark.
    public var text: String
    public var note: String?
    /// Where in the book it is; nil when that is not known.
    public var placeText: String?
    /// The day it was made; nil when that is not known.
    public var dateText: String?
    /// "Readwise", "Audible", "Added here".
    public var sourceText: String
    /// The highlight's own page at its source, when it has one that is safe to open.
    public var link: URL?
    /// Whether the owner added it here.
    public var isOwn: Bool
    /// True for a mark with no words and no note: a place in an audiobook, and no more.
    public var isEmptyMark: Bool
    var source: HighlightSource

    public init(_ highlight: Highlight, calendar: Calendar = .current, locale: Locale = .current) {
        id = highlight.id ?? 0
        text = highlight.text.trimmed
        note = highlight.note?.trimmedOrNil
        placeText = HighlightText.place(
            location: highlight.location, end: highlight.endLocation, kind: highlight.locationKind)
        dateText = highlight.madeAt.map { HighlightText.date($0, calendar: calendar, locale: locale) }
        source = highlight.source
        sourceText = highlight.source.title
        link = highlight.link.flatMap(URL.init(string:)).flatMap { $0.scheme?.lowercased() == "https" ? $0 : nil }
        isOwn = highlight.source == .own
        isEmptyMark = text.isEmpty && note == nil
    }

    /// Where and when, on one line: "Location 1,204 · 4 May 2016". Nil when neither is known.
    public var captionText: String? {
        let parts = [placeText, dateText].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The same with where it came from, which is always known: "Page 87 · Readwise".
    public var sourcedCaptionText: String {
        [placeText, dateText, sourceText].compactMap { $0 }.joined(separator: " · ")
    }

    /// What the command that opens the highlight at its source says: "Open in
    /// Readwise". Nil when it has no page there to open.
    public var openTitle: String? {
        link == nil ? nil : "Open in \(sourceText)"
    }

    /// What stands in for the words of a bare mark; nil for any other highlight.
    public var markText: String? {
        isEmptyMark ? HighlightText.emptyMark : nil
    }

    /// What Copy puts on the clipboard: the passage, and the note on a line after it
    /// when there is one. Nil when there are no words at all.
    var copyText: String? {
        let parts = [text.trimmedOrNil, note].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    /// Whether the passage or the note holds every one of these words, whatever their case.
    func holds(_ words: [String]) -> Bool {
        let said = text + "\n" + (note ?? "")
        return words.allSatisfy { said.localizedCaseInsensitiveContains($0) }
    }
}

/// What the inspector says of the one inspected book's highlights.
public struct HighlightsSummary: Equatable, Sendable {
    /// "12 highlights", "1 highlight", "No highlights".
    public var countText: String
    /// The first three, in the order of the book.
    public var first: [HighlightRow]
    /// Whether the book has more than those.
    public var hasMore: Bool

    static let shown = 3

    public init(count: Int, highlights: [Highlight]) {
        countText = HighlightText.count(count)
        first = highlights.prefix(Self.shown).map { HighlightRow($0) }
        hasMore = count > first.count
    }
}

extension BookRow {
    /// For the list's Highlights column: how many, and nothing for none.
    public var highlightCountText: String {
        highlightCount > 0 ? HighlightText.number(highlightCount) : ""
    }
}

// Highlights on the books of the library: counted on the rows, shown in the inspector,
// and listed, added to and tidied in a sheet. A highlight is kept in the catalogue only:
// no file is opened or written, and none of this is something Undo reverses.

extension AppModel {
    // MARK: Counts

    /// How many highlights a book has, as last read with the rows.
    public func highlightCount(for bookId: Int64) -> Int {
        highlightCounts[bookId] ?? 0
    }

    /// Whether the sidebar shows Highlights: some book has one.
    public var showsHighlights: Bool {
        sidebar.highlightedCount > 0
    }

    /// How many books have a highlight.
    public var highlightedBookCount: Int {
        sidebar.highlightedCount
    }

    // MARK: The inspector

    /// The highlights of the one inspected book; nil when one book of the library is
    /// not what is inspected.
    public var inspectedHighlights: HighlightsSummary? {
        guard case .one(let detail, _) = inspecting else { return nil }
        // Until the book's own have been read, how many is known from its row.
        let count = detail.highlights.isEmpty ? highlightCount(for: detail.row.id) : detail.highlights.count
        return HighlightsSummary(count: count, highlights: detail.highlights)
    }

    /// Whether the inspected book's highlights can be shown now: one book of the
    /// library is inspected, nothing is running, no question is waiting, and no sheet
    /// of the window is up. One sheet at a time.
    public var canShowHighlights: Bool {
        guard case .one = inspecting else { return false }
        return isLibraryOpen && busyLabel == nil && storedPrompt == nil && windowSheet(progressDue: false) == nil
    }

    /// Whether a highlight can be added now: to the one inspected book of the library.
    public var canAddHighlight: Bool {
        canShowHighlights
    }

    /// Opens the sheet of the inspected book's highlights; with `adding`, at its form
    /// for a new one.
    public func beginHighlights(adding: Bool = false) {
        guard canShowHighlights, case .one(let detail, _) = inspecting, let worker else { return }
        let session = HighlightsSession(
            model: self, worker: worker, bookId: detail.row.id,
            title: detail.row.book.title.trimmedOrNil ?? "Untitled book", highlights: detail.highlights)
        if adding { session.beginAdd() }
        highlights = session
        session.read()
    }

    public func closeHighlights() {
        highlights = nil
    }
}

/// The state of the sheet of one book's highlights. It decides everything the sheet shows.
@MainActor @Observable
public final class HighlightsSession {
    @ObservationIgnored private unowned let model: AppModel
    @ObservationIgnored private let worker: LibraryWorker
    @ObservationIgnored let bookId: Int64
    /// The reading of the book's highlights that is running, or the last that ran.
    /// Tests wait for it.
    @ObservationIgnored var reading: Task<Void, Never>?

    init(model: AppModel, worker: LibraryWorker, bookId: Int64, title: String, highlights: [Highlight]) {
        self.model = model
        self.worker = worker
        self.bookId = bookId
        self.title = title
        all = highlights.map { HighlightRow($0) }
    }

    /// The book's title.
    public let title: String
    /// Every highlight of the book, in the order of the book.
    private var all: [HighlightRow]
    /// Narrows `rows` to the highlights whose passage or note holds its words.
    public var filterText = ""

    /// The highlights shown: all of them, or those the filter leaves.
    public var rows: [HighlightRow] {
        let words = filterText.split(whereSeparator: \.isWhitespace).map(String.init)
        return words.isEmpty ? all : all.filter { $0.holds(words) }
    }

    /// "12 highlights": all the book has, whatever the filter.
    public var countText: String {
        HighlightText.count(all.count)
    }

    /// What is said in place of the list when it is empty; nil when it is not.
    public var emptyText: String? {
        if all.isEmpty { return "This book has no highlights yet." }
        return rows.isEmpty ? "No highlights match." : nil
    }

    /// Reads the book's highlights as they are now.
    func read() {
        reading = Task { [weak self] in await self?.reload() }
    }

    private func reload() async {
        guard let read = try? await worker.highlights(forBook: bookId) else { return }
        all = read.map { HighlightRow($0) }
    }

    /// One change to the book's highlights, as an operation of the model's: everything
    /// is read again when it ends. Returns whether it was made.
    private func change(_ label: String, _ work: (LibraryWorker) async throws -> Void) async -> Bool {
        guard model.highlights === self, model.busyLabel == nil else { return false }
        var done = false
        await model.perform(label) { worker in
            try await work(worker)
            done = true
        }
        await reload()
        return done
    }

    // MARK: Copying and opening

    public func canCopy(_ row: HighlightRow) -> Bool {
        row.copyText != nil
    }

    /// Puts the passage on the clipboard, and the note on a line after it when there is one.
    public func copy(_ row: HighlightRow) {
        guard let text = row.copyText else { return }
        model.writeClipboard(text)
    }

    /// Opens the highlight's own page at its source, when it has one.
    public func open(_ row: HighlightRow) {
        guard let link = row.link else { return }
        model.opener.openWeb(link)
    }

    // MARK: Adding

    /// Whether the form for a new highlight is shown.
    public private(set) var isAdding = false
    /// The passage of the new highlight.
    public var newText = ""
    /// The note of the new highlight.
    public var newNote = ""

    public func beginAdd() {
        isAdding = true
    }

    /// Puts the form away, with what was typed in it.
    public func cancelAdd() {
        isAdding = false
        newText = ""
        newNote = ""
    }

    /// A highlight needs a passage, a note, or both.
    public var canAdd: Bool {
        isAdding && (newText.trimmedOrNil != nil || newNote.trimmedOrNil != nil) && model.busyLabel == nil
    }

    public func add() async {
        guard canAdd else { return }
        let (text, note, bookId) = (newText, newNote, bookId)
        let added = await change("Adding highlight…") { worker in
            try await worker.addHighlight(text: text, note: note, toBook: bookId)
        }
        if added { cancelAdd() }
    }

    // MARK: The note

    /// The highlight whose note is being written; nil when none is.
    public private(set) var editing: HighlightRow?
    /// The note as it is being written.
    public var noteDraft = ""

    public func editNote(_ row: HighlightRow) {
        editing = row
        noteDraft = row.note ?? ""
    }

    public func cancelEditNote() {
        editing = nil
        noteDraft = ""
    }

    /// Keeps the note as written; a blank one takes the note away.
    public func saveNote() async {
        guard let row = editing else { return }
        let note = noteDraft
        let saved = await change("Saving note…") { worker in
            try await worker.setNote(note, onHighlight: row.id)
        }
        if saved { cancelEditNote() }
    }

    // MARK: Deleting

    /// The highlight the owner is being asked about deleting; nil when none is.
    public private(set) var deleting: HighlightRow?
    public let deleteTitle = "Delete this highlight?"

    /// What deleting will mean, under the question; nil while nothing is asked.
    public var deleteMessage: String? {
        guard let row = deleting else { return nil }
        return row.isOwn
            ? "It is one you added here, and cannot be brought back."
            : "It will come back the next time highlights are imported from \(row.source.title)."
    }

    /// Asks whether to delete the highlight. Nothing is done until `confirmDelete`.
    public func delete(_ row: HighlightRow) {
        deleting = row
    }

    public func cancelDelete() {
        deleting = nil
    }

    public func confirmDelete() async {
        guard let row = deleting else { return }
        deleting = nil
        _ = await change("Deleting highlight…") { worker in
            try await worker.deleteHighlight(id: row.id)
        }
    }

    // MARK: Closing

    public func close() {
        guard model.highlights === self else { return }
        model.closeHighlights()
    }
}

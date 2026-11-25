import Foundation
import Observation
import VoxCarrelCore

/// A book of the library that is owned on Audible, as its marks are asked for.
public struct AudibleMarkedBook: Equatable, Sendable {
    public var title: String
    public var authors: [String]
    /// The book's Audible ID.
    public var asin: String
}

/// Everything Import Highlights says about what it reads, would do, and did.
enum HighlightsImportText {
    /// The most titles a list shows.
    static let mostTitles = 500
    /// The most titles named in a line.
    static let mostNamed = 3

    static let readwiseSource = "Readwise (your Kindle highlights)"
    static let audibleSource = "Audible (marks you made while listening)"
    static let noSource = "Add a Readwise token or link your Audible account in Settings first."
    static let readingReadwise = "Reading from Readwise…"
    static let nothingToDo = "Everything is already here."
    static let note = "No file is added or changed."

    static func readingMarks(_ index: Int, of count: Int) -> String {
        "Reading marks from Audible, \(index) of \(count)…"
    }

    private static func number(_ count: Int) -> String {
        HighlightText.number(count)
    }

    private static func books(_ count: Int) -> String {
        count == 1 ? "1 book" : "\(number(count)) books"
    }

    private static func highlights(_ count: Int) -> String {
        count == 1 ? "1 highlight" : "\(number(count)) highlights"
    }

    /// "751 highlights on 86 books.": what was read, and that there is nothing to do
    /// when there is not.
    static func summary(highlights count: Int, books: Int, report: HighlightsReport) -> String {
        guard count > 0 else { return "No highlights were found." }
        let sentence = "\(highlights(count)) on \(self.books(books))."
        return report.changesNothing ? "\(sentence) \(nothingToDo)" : sentence
    }

    /// What importing would do, a line for each thing that is not nothing.
    static func lines(for report: HighlightsReport) -> [String] {
        var lines: [String] = []
        let added = report.booksAdded.count
        if added > 0 {
            lines.append(
                "\(books(added)) will be added as \(added == 1 ? "a book" : "books") you own on Kindle.")
        }
        if report.booksGaining > 0 {
            lines.append("\(books(report.booksGaining)) you already have will get highlights.")
        }
        // Said only where some of what was read is here already: otherwise all of it is new.
        if report.added > 0, report.unchanged + report.changed > 0 {
            lines.append("\(highlights(report.added)) \(report.added == 1 ? "is" : "are") new.")
        }
        if report.joined > 0 {
            lines.append(
                "\(highlights(report.joined)) \(report.joined == 1 ? "is" : "are") already here from another source and "
                    + "will not be added twice.")
        }
        if report.changed > 0 {
            lines.append(
                "\(highlights(report.changed)) \(report.changed == 1 ? "has" : "have") changed and will be updated.")
        }
        if report.removed > 0 {
            lines.append(
                "\(highlights(report.removed)) \(report.removed == 1 ? "was" : "were") deleted at the source and "
                    + "will be removed.")
        }
        let left = report.booksLeftOut
        if !left.isEmpty {
            var named = left.prefix(mostNamed).joined(separator: ", ")
            if left.count > mostNamed { named += " and \(number(left.count - mostNamed)) more" }
            lines.append(
                left.count == 1
                    ? "1 book is owned nowhere VoxCarrel knows and is left out: \(named)."
                    : "\(books(left.count)) are owned nowhere VoxCarrel knows and are left out: \(named).")
        }
        return lines
    }

    /// What importing did: "Added 751 highlights and 86 books. Updated 12 highlights."
    static func outcome(of report: HighlightsReport) -> String {
        var sentences: [String] = []
        var added: [String] = []
        if report.added > 0 { added.append(highlights(report.added)) }
        if !report.booksAdded.isEmpty { added.append(books(report.booksAdded.count)) }
        if !added.isEmpty { sentences.append("Added \(added.joined(separator: " and ")).") }
        if report.changed > 0 { sentences.append("Updated \(highlights(report.changed)).") }
        if report.removed > 0 { sentences.append("Removed \(highlights(report.removed)).") }
        return sentences.isEmpty ? nothingToDo : sentences.joined(separator: " ")
    }

    /// The titles a list shows: the first of a long one.
    static func shown(_ titles: [String]) -> [String] {
        Array(titles.prefix(mostTitles))
    }

    /// "and 120 more" under a list that was cut short; nil under one that was not.
    static func more(_ titles: [String]) -> String? {
        titles.count > mostTitles ? "and \(titles.count - mostTitles) more" : nil
    }

    /// Said in the review when the marks made on Audible could not be read.
    static func marksNotRead(_ why: String) -> String {
        "Your marks on Audible were not read: \(why)"
    }
}

extension UserMessage {
    /// Why highlights could not be read from Readwise.
    public static func highlightsProblem(_ error: Error) -> String {
        switch error as? ReadwiseError {
        case .refused: "Readwise did not accept the token. Check it in Settings."
        case .notReachable: "Readwise could not be reached. Check your internet connection."
        case .busy: "Readwise asked to be left alone for a while. Try again in a few minutes."
        default: "Your highlights could not be read."
        }
    }

    /// Why the marks made on Audible could not be read.
    static func audibleMarksProblem(_ error: Error) -> String {
        switch error as? AudibleAccountError {
        case .refused: "Audible no longer accepts this link. Unlink the account in Settings and link it again."
        case .notReachable: "Audible could not be reached. Check your internet connection."
        default: "Audible gave no answer that could be read."
        }
    }

    public static let readwiseTokenNotKept =
        "The Readwise token could not be kept on this Mac, so it was not saved. Try again."
}

/// The state of Import Highlights. It decides everything the sheet shows.
///
/// Nothing is asked of anyone until `start()`. Then the highlights are read from
/// Readwise, and the marks made while listening from Audible, and what bringing them in
/// would do is worked out and shown. Nothing in this library changes until `apply()`,
/// and nothing at Readwise or Audible changes at all.
@MainActor @Observable
public final class HighlightsImportSession {
    public enum Phase: Equatable, Sendable {
        /// What will be read is shown; nothing has been asked yet.
        case ready
        /// The highlights are being read.
        case reading
        /// What bringing them in would do is shown.
        case review
        /// The highlights could not be read: `problem` says why.
        case failed
    }

    @ObservationIgnored private unowned let model: AppModel
    @ObservationIgnored private let worker: LibraryWorker
    /// The owner's Readwise token; nil when none is saved. Shown nowhere.
    @ObservationIgnored private let token: String?
    @ObservationIgnored private let account: AudibleAccount?
    /// The books as the sources gave them, with their highlights.
    @ObservationIgnored private var books: [HighlightedBook] = []
    /// The reading that is running, or the last that ran. Tests wait for it.
    @ObservationIgnored var reading: Task<Void, Never>?

    init(model: AppModel, worker: LibraryWorker, token: String?, account: AudibleAccount?) {
        self.model = model
        self.worker = worker
        self.token = token
        self.account = account
        var sources: [String] = []
        if token != nil { sources.append(HighlightsImportText.readwiseSource) }
        if account != nil { sources.append(HighlightsImportText.audibleSource) }
        self.sources = sources
        problem = sources.isEmpty ? HighlightsImportText.noSource : nil
    }

    public let title = "Import Highlights"
    public let startTitle = "Read Highlights"
    public let importTitle = "Import"
    public let addTitle = "To be added"
    public let sourcesTitle = "Highlights will be read from:"
    public let note = HighlightsImportText.note
    /// What will be read, a line for each source there is.
    public let sources: [String]

    public private(set) var phase = Phase.ready
    /// Why there is nothing to read, or why it could not be read; nil otherwise.
    public private(set) var problem: String?
    /// What is being read now; nil while nothing is.
    public private(set) var progressText: String?
    /// What bringing the highlights in would do; nil until it has been worked out.
    private var report: HighlightsReport?
    /// Why the marks made on Audible were not read, when the rest was; nil otherwise.
    private var audibleProblem: String?

    // MARK: Reading

    public var canStart: Bool {
        phase == .ready && !sources.isEmpty
    }

    /// Reads the highlights from each source, then asks this library what bringing
    /// them in would do. The library is not kept waiting while the sources answer.
    public func start() {
        guard canStart, model.highlightsImport === self else { return }
        phase = .reading
        progressText = token == nil ? nil : HighlightsImportText.readingReadwise
        let (token, account, worker) = (token, account, worker)
        let transport = model.audibleTransport
        let wait = model.readwiseWait
        reading = Task { [weak self] in
            var books: [HighlightedBook] = []
            var audibleProblem: String?
            do {
                if let token {
                    books = try await ReadwiseReader.books(token: token, transport: transport, wait: wait)
                }
                guard !Task.isCancelled else { return }
                if let account {
                    let owned = try await worker.audibleBooksForMarks()
                    var failures: [Error] = []
                    for (index, book) in owned.enumerated() {
                        // One book at a time, and no further once the sheet has closed.
                        guard !Task.isCancelled, self?.phase == .reading else { return }
                        self?.progressText = HighlightsImportText.readingMarks(index + 1, of: owned.count)
                        do {
                            let marks = try await AudibleMarksReader.marks(
                                asin: book.asin, account: account, transport: transport)
                            guard !marks.isEmpty else { continue }
                            var marked = HighlightedBook(
                                title: book.title, authors: book.authors, source: .audible, highlights: marks)
                            marked.itemId = book.asin
                            marked.ownedOn = .audible
                            books.append(marked)
                        } catch let error as AudibleAccountError {
                            // Refused for one book is refused for all: the rest are not asked.
                            if case .refused = error {
                                audibleProblem = UserMessage.audibleMarksProblem(error)
                                break
                            }
                            failures.append(error)
                        } catch {
                            // One book's marks that cannot be had are passed over.
                            failures.append(error)
                        }
                    }
                    // Not one book answered: that is Audible, not the books.
                    if audibleProblem == nil, !owned.isEmpty, failures.count == owned.count, let last = failures.last {
                        audibleProblem = UserMessage.audibleMarksProblem(last)
                    }
                }
                guard !Task.isCancelled else { return }
                let report = try await worker.highlightsReport(books, apply: false)
                guard let self, !Task.isCancelled, self.phase == .reading else { return }
                self.books = books
                self.report = report
                self.audibleProblem = audibleProblem
                self.progressText = nil
                self.phase = .review
            } catch {
                guard let self, !Task.isCancelled, self.phase == .reading else { return }
                self.problem = UserMessage.highlightsProblem(error)
                self.progressText = nil
                self.phase = .failed
            }
        }
    }

    /// Stops a reading that is running: its answer is not wanted.
    func stopReading() {
        reading?.cancel()
    }

    // MARK: The review

    /// The highlights that were read and are not deleted at their source.
    private var live: [[IncomingHighlight]] {
        books.map { $0.highlights.filter { !$0.isDeleted } }.filter { !$0.isEmpty }
    }

    /// "751 highlights on 86 books."; nil until the highlights have been read.
    public var summary: String? {
        report.map {
            HighlightsImportText.summary(highlights: live.reduce(0) { $0 + $1.count }, books: live.count, report: $0)
        }
    }

    public var lines: [String] {
        guard let report else { return [] }
        return HighlightsImportText.lines(for: report)
            + (audibleProblem.map { [HighlightsImportText.marksNotRead($0)] } ?? [])
    }

    /// The titles of the books that would be added: the first of a long list.
    public var titlesToAdd: [String] {
        HighlightsImportText.shown(report?.booksAdded ?? [])
    }

    public var moreToAdd: String? {
        HighlightsImportText.more(report?.booksAdded ?? [])
    }

    /// Nothing to import when the highlights could not be read, or are all here already.
    public var canImport: Bool {
        guard phase == .review, let report else { return false }
        return !report.changesNothing && model.busyLabel == nil
    }

    // MARK: Importing and closing

    /// Brings the highlights in, closes the sheet, and says what was done. Then the
    /// covers of the books that have none are fetched, behind everything else.
    public func apply() async {
        guard canImport, model.highlightsImport === self else { return }
        let books = books
        let worker = worker
        let model = model
        model.highlightsImport = nil
        var done = false
        await model.perform("Importing highlights…") { worker in
            let report = try await worker.highlightsReport(books, apply: true)
            done = true
            model.alert = HighlightsImportText.outcome(of: report)
        }
        guard done, model.worker === worker else { return }
        var addresses: [String: URL] = [:]
        for book in books {
            if let id = book.itemId?.trimmedOrNil, let url = book.coverURL { addresses[id.uppercased()] = url }
        }
        model.fetchHighlightCovers(addresses, with: worker)
    }

    /// "Cancel" while there is, or may be, something to import; "Close" when there is not.
    public var closeTitle: String {
        switch phase {
        case .ready: sources.isEmpty ? "Close" : "Cancel"
        case .reading: "Cancel"
        case .review: report?.changesNothing == true ? "Close" : "Cancel"
        case .failed: "Close"
        }
    }

    /// Closes the sheet. Nothing is brought in.
    public func cancel() {
        guard model.highlightsImport === self else { return }
        model.closeHighlightsImport()
    }
}

// The Readwise token, and Import Highlights.
//
// The token is the owner's own, made on Readwise's site and typed into Settings. It is
// kept in the Mac's Keychain, sent to Readwise alone, and shown nowhere once saved.

extension AppModel {
    // MARK: The token

    public var readwiseSavedText: String { "A Readwise token is saved." }

    /// What the settings say while no token is saved.
    public var readwiseSettingsText: String {
        "Readwise holds the highlights you make on a Kindle. To bring them in, paste your access token from "
            + "readwise.io/access_token. It is kept on this Mac and sent only to Readwise."
    }

    public var useReadwiseTokenTitle: String { "Use the token already on this Mac" }

    /// Reads whether a token is saved from where it is kept.
    func readReadwiseToken() {
        hasReadwiseToken = readwiseTokens.load() != nil
    }

    /// Whether what is typed could be a token.
    public var canSaveReadwiseToken: Bool {
        ReadwiseTokenFile.isPlausible(readwiseTokenDraft.trimmed)
    }

    /// Keeps the token that was typed, and empties the field: it is not shown again.
    public func saveReadwiseToken() {
        guard canSaveReadwiseToken else { return }
        keepReadwiseToken(readwiseTokenDraft.trimmed)
    }

    private func keepReadwiseToken(_ token: String) {
        do {
            try readwiseTokens.save(token)
            readwiseTokenDraft = ""
            hasReadwiseToken = true
        } catch {
            alert = UserMessage.readwiseTokenNotKept
        }
    }

    /// Not while Import Highlights is open: it is reading with the token.
    public var canRemoveReadwiseToken: Bool {
        hasReadwiseToken && highlightsImport == nil
    }

    public func removeReadwiseToken() {
        guard canRemoveReadwiseToken else { return }
        readwiseTokens.remove()
        hasReadwiseToken = false
    }

    /// Whether a token put on this Mac earlier is there to be used: only while none is saved.
    public var offersReadwiseTokenOnThisMac: Bool {
        !hasReadwiseToken && ReadwiseTokenFile.token(at: readwiseTokenFile) != nil
    }

    /// Saves the token put on this Mac earlier. The file it is in is left as it is.
    public func useReadwiseTokenOnThisMac() {
        guard !hasReadwiseToken, let token = ReadwiseTokenFile.token(at: readwiseTokenFile) else { return }
        keepReadwiseToken(token)
    }

    // MARK: Importing

    /// Whether Import Highlights can be opened now: a library is open, nothing is
    /// running, no question is waiting, and no sheet of the window is up. With no
    /// token and no account it opens all the same, and says what is needed.
    public var canImportHighlights: Bool {
        isLibraryOpen && busyLabel == nil && storedPrompt == nil && windowSheet(progressDue: false) == nil
    }

    /// Opens Import Highlights. Nothing is asked of Readwise or Audible by opening it.
    public func beginHighlightsImport() {
        guard canImportHighlights, let worker else { return }
        highlightsImport = HighlightsImportSession(
            model: self, worker: worker, token: readwiseTokens.load()?.trimmedOrNil, account: audibleAccount)
    }

    public func closeHighlightsImport() {
        highlightsImport?.stopReading()
        highlightsImport = nil
    }

    // MARK: Covers

    /// Fetches, behind everything else, the covers of the books owned elsewhere that
    /// have none, from the addresses their source gave for them.
    ///
    /// - Parameter addresses: The cover's address for each book's ID where it is owned, in capitals.
    func fetchHighlightCovers(_ addresses: [String: URL], with worker: LibraryWorker) {
        guard !addresses.isEmpty else { return }
        fetchCovers(addresses, hosts: AudibleCoverDownload.highlightHosts, with: worker) { worker in
            try? await worker.booksOwnedElsewhereWithoutCover()
        }
    }
}

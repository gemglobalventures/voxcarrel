import Foundation
import Observation
import VoxCarrelCore

/// Everything Import Audible Library says about what it would do, and did.
enum AudibleImportText {
    /// The most titles a list shows.
    static let mostTitles = 500

    private static func books(_ count: Int) -> String {
        count == 1 ? "1 book" : "\(count) books"
    }

    /// "217 books in your Audible library.", and that there is nothing to do when
    /// there is not.
    static func summary(total: Int, report: AudibleLibraryReport) -> String {
        guard total > 0 else { return "Your Audible library has no books." }
        let sentence = "\(books(total)) in your Audible library."
        return report.changesNothing ? "\(sentence) \(nothingToDo)" : sentence
    }

    static let nothingToDo = "Everything is already in your library."

    /// What bringing the library in would do, a line for each thing that is not nothing.
    static func lines(for report: AudibleLibraryReport) -> [String] {
        var lines: [String] = []
        let added = report.added.count
        if added > 0 {
            lines.append("\(added) will be added as \(added == 1 ? "a book" : "books") you own on Audible.")
        }
        let marked = report.marked.count
        if marked > 0 { lines.append("\(books(marked)) you already have will be marked as on Audible.") }
        let there = report.alreadyThere
        if there > 0 { lines.append("\(there) \(there == 1 ? "is" : "are") already marked.") }
        let status = report.statusChanged
        if status > 0 {
            lines.append(
                "\(status) will have \(status == 1 ? "its" : "their") reading status set from Audible "
                    + "(finished, or being read).")
        }
        return lines
    }

    /// What bringing the library in did: "Added 190 books and marked 20 as on Audible."
    static func outcome(of report: AudibleLibraryReport) -> String {
        let added = report.added.count
        let marked = report.marked.count
        switch (added > 0, marked > 0) {
        case (true, true): return "Added \(books(added)) and marked \(marked) as on Audible."
        case (true, false): return "Added \(books(added))."
        case (false, true): return "Marked \(books(marked)) as on Audible."
        case (false, false):
            guard report.statusChanged > 0 else { return nothingToDo }
            return "Set the reading status of \(books(report.statusChanged)) from Audible."
        }
    }

    /// The titles a list shows: the first of a long one.
    static func shown(_ titles: [String]) -> [String] {
        Array(titles.prefix(mostTitles))
    }

    /// "and 120 more" under a list that was cut short; nil under one that was not.
    static func more(_ titles: [String]) -> String? {
        titles.count > mostTitles ? "and \(titles.count - mostTitles) more" : nil
    }

    static let note =
        "No file is added or changed. Books that are added have no files; if you import their files later, "
        + "they join these entries."
}

/// The state of Import Audible Library. It decides everything the sheet shows.
///
/// The account's library is read from Audible as soon as the sheet opens, and what
/// bringing it in would do is worked out and shown. Nothing in this library changes
/// until `apply()`, and nothing at Audible changes at all.
@MainActor @Observable
public final class AudibleImportSession {
    public enum Phase: Equatable, Sendable {
        /// The account's library is being read from Audible.
        case reading
        /// What bringing it in would do is shown.
        case review
        /// The library could not be read: `problem` says why.
        case failed
    }

    @ObservationIgnored private unowned let model: AppModel
    @ObservationIgnored private let account: AudibleAccount
    @ObservationIgnored private let worker: LibraryWorker
    /// The books as Audible listed them.
    @ObservationIgnored private var books: [AudibleOwnedBook] = []
    /// The reading that is running, or the last that ran. Tests wait for it.
    @ObservationIgnored var reading: Task<Void, Never>?

    init(model: AppModel, account: AudibleAccount, worker: LibraryWorker) {
        self.model = model
        self.account = account
        self.worker = worker
    }

    public let title = "Import Audible Library"
    public let readingText = "Reading your Audible library…"
    public let importTitle = "Import"
    public let addTitle = "To be added"
    public let markTitle = "To be marked as on Audible"
    public let note = AudibleImportText.note

    public private(set) var phase = Phase.reading
    /// Why the library could not be read, as a sentence; nil when it could.
    public private(set) var problem: String?
    /// What bringing the library in would do; nil until it has been worked out.
    private var report: AudibleLibraryReport?

    // MARK: Reading

    /// Reads the account's library, then asks this library what bringing it in would
    /// do. The library is not kept waiting while Audible answers.
    func read() {
        guard reading == nil else { return }
        let account = account
        let worker = worker
        let transport = model.audibleTransport
        reading = Task { [weak self] in
            do {
                let books = try await AudibleLibraryReader.books(of: account, transport: transport)
                guard !Task.isCancelled else { return }
                let report = try await worker.audibleLibraryReport(books, store: account.store, apply: false)
                guard let self, !Task.isCancelled, self.phase == .reading else { return }
                self.books = books
                self.report = report
                self.phase = .review
            } catch {
                guard let self, !Task.isCancelled, self.phase == .reading else { return }
                self.problem = UserMessage.audibleLibraryProblem(error)
                self.phase = .failed
            }
        }
    }

    /// Stops a reading that is running: its answer is not wanted.
    func stopReading() {
        reading?.cancel()
    }

    // MARK: The review

    /// "217 books in your Audible library."; nil until the library has been read.
    public var summary: String? {
        report.map { AudibleImportText.summary(total: books.count, report: $0) }
    }

    public var lines: [String] {
        report.map(AudibleImportText.lines) ?? []
    }

    /// The titles of the books that would be added: the first of a long list.
    public var titlesToAdd: [String] {
        AudibleImportText.shown(report?.added ?? [])
    }

    public var moreToAdd: String? {
        AudibleImportText.more(report?.added ?? [])
    }

    /// The titles of the books this library has that would be marked as on Audible.
    public var titlesToMark: [String] {
        AudibleImportText.shown(report?.marked ?? [])
    }

    public var moreToMark: String? {
        AudibleImportText.more(report?.marked ?? [])
    }

    /// Nothing to import when the library could not be read, or has it all already.
    public var canImport: Bool {
        guard phase == .review, let report else { return false }
        return !report.changesNothing && model.busyLabel == nil
    }

    // MARK: Importing and closing

    /// Brings the library in, closes the sheet, and says what was done. Then the
    /// covers of the books that have none are fetched, behind everything else.
    public func apply() async {
        guard canImport, model.audibleImport === self else { return }
        let books = books
        let store = account.store
        let worker = worker
        let model = model
        model.audibleImport = nil
        var done = false
        await model.perform("Importing your Audible library…") { worker in
            let report = try await worker.audibleLibraryReport(books, store: store, apply: true)
            done = true
            model.alert = AudibleImportText.outcome(of: report)
        }
        guard done, model.worker === worker else { return }
        var addresses: [String: URL] = [:]
        for book in books {
            if let url = book.coverURL { addresses[book.asin.uppercased()] = url }
        }
        model.fetchAudibleCovers(addresses, with: worker)
    }

    /// "Cancel" while there is something to import, "Close" when there is not.
    public var closeTitle: String {
        phase == .failed || (phase == .review && report?.changesNothing == true) ? "Close" : "Cancel"
    }

    /// Closes the sheet. Nothing is brought in.
    public func cancel() {
        guard model.audibleImport === self else { return }
        model.closeAudibleImport()
    }
}

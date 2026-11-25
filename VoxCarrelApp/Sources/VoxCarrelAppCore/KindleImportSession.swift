import Foundation
import Observation
import VoxCarrelCore

/// Everything Import Kindle Library says about what it would do, and did.
enum KindleImportText {
    private static func books(_ count: Int) -> String {
        count == 1 ? "1 book" : "\(count) books"
    }

    /// "673 books in your Kindle library.", and that there is nothing to do when
    /// there is not.
    static func summary(total: Int, report: KindleLibraryReport) -> String {
        guard total > 0 else { return "Your Kindle library has no books." }
        let sentence = "\(books(total)) in your Kindle library."
        return report.changesNothing ? "\(sentence) \(nothingToDo)" : sentence
    }

    static let nothingToDo = AudibleImportText.nothingToDo

    /// What bringing the library in would do, a line for each thing that is not nothing.
    static func lines(for report: KindleLibraryReport) -> [String] {
        var lines: [String] = []
        let added = report.added.count
        if added > 0 {
            lines.append("\(added) will be added as \(added == 1 ? "a book" : "books") you own on Kindle.")
        }
        let marked = report.marked.count
        if marked > 0 { lines.append("\(books(marked)) you already have will be marked as owned on Kindle.") }
        let there = report.alreadyThere
        if there > 0 { lines.append("\(there) \(there == 1 ? "is" : "are") already here.") }
        return lines
    }

    /// What bringing the library in did: "Added 597 books and marked 20 as owned on Kindle."
    static func outcome(of report: KindleLibraryReport) -> String {
        let added = report.added.count
        let marked = report.marked.count
        switch (added > 0, marked > 0) {
        case (true, true): return "Added \(books(added)) and marked \(marked) as owned on Kindle."
        case (true, false): return "Added \(books(added))."
        case (false, true): return "Marked \(books(marked)) as owned on Kindle."
        case (false, false): return nothingToDo
        }
    }

    /// Where the list comes from, said under the sheet's title.
    static let source =
        "Read from Amazon's Kindle web reader, using your Audible link. Nothing is changed at Amazon."

    static let note = "No file is added or changed. Books that are added have no files."
}

/// The state of Import Kindle Library. It decides everything the sheet shows.
///
/// The account's Kindle library is read from Amazon as soon as the sheet opens, and
/// what bringing it in would do is worked out and shown. Nothing in this library
/// changes until `apply()`, and nothing at Amazon changes at all.
@MainActor @Observable
public final class KindleImportSession {
    public enum Phase: Equatable, Sendable {
        /// The account's Kindle library is being read from Amazon.
        case reading
        /// What bringing it in would do is shown.
        case review
        /// The library could not be read: `problem` says why.
        case failed
    }

    @ObservationIgnored private unowned let model: AppModel
    @ObservationIgnored private let account: AudibleAccount
    @ObservationIgnored private let worker: LibraryWorker
    /// The books as Amazon listed them.
    @ObservationIgnored private var books: [KindleOwnedBook] = []
    /// The reading that is running, or the last that ran. Tests wait for it.
    @ObservationIgnored var reading: Task<Void, Never>?

    init(model: AppModel, account: AudibleAccount, worker: LibraryWorker) {
        self.model = model
        self.account = account
        self.worker = worker
    }

    public let title = "Import Kindle Library"
    public let source = KindleImportText.source
    public let readingText = "Reading your Kindle library…"
    public let importTitle = "Import"
    public let addTitle = "To be added"
    public let markTitle = "To be marked as owned on Kindle"
    public let note = KindleImportText.note

    public private(set) var phase = Phase.reading
    /// Why the library could not be read, as a sentence; nil when it could.
    public private(set) var problem: String?
    /// What bringing the library in would do; nil until it has been worked out.
    private var report: KindleLibraryReport?

    // MARK: Reading

    /// Reads the account's Kindle library, then asks this library what bringing it in
    /// would do. The library is not kept waiting while Amazon answers.
    func read() {
        guard reading == nil else { return }
        let account = account
        let worker = worker
        let transport = model.audibleTransport
        reading = Task { [weak self] in
            do {
                let books = try await KindleLibraryReader.books(of: account, transport: transport)
                guard !Task.isCancelled else { return }
                let report = try await worker.kindleLibraryReport(books, apply: false)
                guard let self, !Task.isCancelled, self.phase == .reading else { return }
                self.books = books
                self.report = report
                self.phase = .review
            } catch {
                guard let self, !Task.isCancelled, self.phase == .reading else { return }
                self.problem = UserMessage.kindleLibraryProblem(error)
                self.phase = .failed
            }
        }
    }

    /// Stops a reading that is running: its answer is not wanted.
    func stopReading() {
        reading?.cancel()
    }

    // MARK: The review

    /// "673 books in your Kindle library."; nil until the library has been read.
    public var summary: String? {
        report.map { KindleImportText.summary(total: books.count, report: $0) }
    }

    public var lines: [String] {
        report.map(KindleImportText.lines) ?? []
    }

    /// The titles of the books that would be added: the first of a long list.
    public var titlesToAdd: [String] {
        AudibleImportText.shown(report?.added ?? [])
    }

    public var moreToAdd: String? {
        AudibleImportText.more(report?.added ?? [])
    }

    /// The titles of the books this library has that would be marked as owned on Kindle.
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
        guard canImport, model.kindleImport === self else { return }
        let books = books
        let worker = worker
        let model = model
        model.kindleImport = nil
        var done = false
        await model.perform("Importing your Kindle library…") { worker in
            let report = try await worker.kindleLibraryReport(books, apply: true)
            done = true
            model.alert = KindleImportText.outcome(of: report)
        }
        guard done, model.worker === worker else { return }
        var addresses: [String: URL] = [:]
        for book in books {
            if let url = book.coverURL { addresses[book.asin.uppercased()] = url }
        }
        model.fetchKindleCovers(addresses, with: worker)
    }

    /// "Cancel" while there is something to import, "Close" when there is not.
    public var closeTitle: String {
        phase == .failed || (phase == .review && report?.changesNothing == true) ? "Close" : "Cancel"
    }

    /// Closes the sheet. Nothing is brought in.
    public func cancel() {
        guard model.kindleImport === self else { return }
        model.closeKindleImport()
    }
}

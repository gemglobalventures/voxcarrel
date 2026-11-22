import Foundation
import VoxCarrelCore

// Series completeness (plan 9, Task 4). SV1–SV14.
//
// For the series the sidebar shows, Audible's own list of that series is fetched when the
// owner asks (Check Series) and kept in the catalogue. The books of the list that the
// library lacks are shown among the series' books as rows of their own (`BookRow.missing`),
// with negative ids: they are no books of the library, so no book command applies to them
// and the library is never asked about them. Nothing is sent to Audible except by Check
// Series, and nothing at all while Audible is off as a lookup source. A check never
// changes the owner's own numbers.

extension AppModel {
    // MARK: SV1 The header

    /// The series the sidebar shows, by its name exactly as the sidebar has it; nil
    /// when it shows anything else.
    var selectedSeriesName: String? {
        if case .browse(.series, let name) = sidebarSelection { return name }
        return nil
    }

    /// Whether nothing is running, asked or shown that a change to the series' list
    /// would get in the way of.
    private var isQuietForSeries: Bool {
        isQuietForLookup && seriesChoice == nil && review == nil && result == nil && libraryCheck == nil
    }

    /// SV1: what is said above the books about Audible's list of the series; not nil
    /// exactly while one series under Browse ▸ Series is what the sidebar shows.
    public var seriesHeader: SeriesHeader? {
        guard let name = selectedSeriesName else { return nil }
        // The rows are still those of what was shown before.
        guard let shown = shownSeries, shown.name == name else {
            return SeriesRows.loadingHeader(showsHidden: showsHiddenMissing)
        }
        return SeriesRows.header(
            shown.completeness, canCheck: isQuietForSeries && lookupSources.contains(.audible),
            canChange: isQuietForSeries,
            // SV10
            hasEdits: !editedBookIds.isDisjoint(with: shown.bookIds), showsHidden: showsHiddenMissing)
    }

    /// SV3: the Audible series to choose between; not nil while the owner is being asked.
    public var seriesChoices: [SeriesChoice]? {
        seriesChoice?.found.map(SeriesRows.choice)
    }

    // MARK: SV2–SV4 Checking

    static let checkingSeriesLabel = "Checking the series…"
    static let noSeriesListed = "Audible does not list a series for these books."

    /// SV2: asks Audible which series the books of the series shown are in: up to five
    /// of them, one after another, until the answers agree. SV3: when one series holds
    /// the most of them its list is fetched and stored at once (SV4); otherwise
    /// `seriesChoices` offers every series found, and nothing more is asked until one
    /// is chosen.
    ///
    /// An operation: `busyLabel` says "Checking the series…", and nothing happens while
    /// another runs. Does nothing unless `seriesHeader.canCheck`: nothing is ever sent
    /// while Audible is off. When Audible cannot be reached `alert` says so, as a
    /// lookup does, and what is stored stays as it was.
    public func checkSeries() async {
        guard seriesHeader?.canCheck == true, let name = selectedSeriesName,
              let worker = await begin(Self.checkingSeriesLabel)
        else { return }
        do {
            var answers: [SeriesAnswer] = []
            for book in SeriesRows.booksToAsk(try await worker.seriesCheckBooks(named: name)) {
                let refs = try await worker.audibleSeries(ofBookWithASIN: book.asin, title: book.title, author: book.author)
                answers.append(SeriesAnswer(refs: refs))
                if SeriesRows.agree(answers) { break }
            }
            let found = SeriesRows.tally(answers)
            if found.isEmpty {
                alert = Self.noSeriesListed
            } else if let series = SeriesRows.clearChoice(found) {
                try await fetchList(of: series, forSeries: name, with: worker)
            } else {
                // SV3: nothing has changed, so there is nothing to read again.
                seriesChoice = PendingSeriesChoice(name: name, found: found)
                busyLabel = nil
                return
            }
        } catch {
            showSeriesFailure(error)
        }
        await finish()
    }

    /// SV3, SV4: the owner's answer to `seriesChoices`: fetches and stores the list of
    /// the series with this id, for the library series that was being checked. An id
    /// that was not offered does nothing.
    ///
    /// When Audible has been turned off as a lookup source since the choice was
    /// offered, nothing is sent: the choice closes and `alert` says why.
    public func chooseSeries(_ id: String) async {
        guard let asked = seriesChoice,
              let series = asked.found.first(where: { SeriesRows.choiceId($0.ref) == id })?.ref
        else { return }
        guard lookupSources.contains(.audible) else {
            seriesChoice = nil
            alert = Self.noAudibleReason
            return
        }
        guard let worker = await begin(Self.checkingSeriesLabel) else { return }
        seriesChoice = nil
        do {
            try await fetchList(of: series, forSeries: asked.name, with: worker)
        } catch {
            showSeriesFailure(error)
        }
        await finish()
    }

    /// SV3: closes the choice. Nothing was fetched, and nothing is changed.
    public func cancelSeriesChoice() {
        seriesChoice = nil
    }

    /// SV4: fetches the series' list and stores it for the library series `name`, in
    /// place of any it had. Part of an operation that is already running.
    private func fetchList(of series: AudibleSeriesRef, forSeries name: String, with worker: LibraryWorker) async throws {
        let list = try await worker.audibleSeriesList(series)
        // Dated by the model's clock, which a test moves by hand.
        try await worker.saveSeriesList(list, forSeries: name, now: inboxNow())
        // The stored entries have new ids: a missing row that was selected is let go,
        // so that nothing stays selected under an id that may now be another entry's.
        selection = selection.filter { $0 > 0 }
    }

    /// SV4: Audible did not answer: said as a lookup says it. Anything else as it is.
    private func showSeriesFailure(_ error: Error) {
        if let error = error as? LookupError {
            alert = UserMessage.text(for: error, source: .audible)
        } else {
            show(error)
        }
    }

    // MARK: SV10 Audible's numbers

    /// SV10: gives the books of the series that Audible numbers differently Audible's
    /// numbers: an ordinary save of those books, which writes their tags, is reversed
    /// by Undo, and shows the usual result sheet for a book that could not be saved.
    /// Does nothing unless `seriesHeader.canUseAudibleNumbers`.
    public func useAudibleNumbers() async {
        guard seriesHeader?.canUseAudibleNumbers == true, let name = selectedSeriesName,
              let worker = await begin("Saving…")
        else { return }
        do {
            let edits = try await worker.editsUsingAudibleNumbers(forSeries: name)
            if !edits.isEmpty {
                if edits.count > 1 { busyLabel = "Saving \(edits.count) books…" }
                _ = await write(edits, with: worker)
            }
        } catch {
            show(error)
        }
        await finish()
    }

    // MARK: SV12 Unlinking

    /// SV12: forgets Audible's list of the series shown. The missing rows go, and the
    /// header is as it was before the series was checked. Does nothing unless
    /// `seriesHeader.canUnlink`.
    public func unlinkSeries() async {
        guard seriesHeader?.canUnlink == true, let name = selectedSeriesName else { return }
        await perform("Updating…") { worker in
            try await worker.unlinkSeries(named: name)
        }
    }

    // MARK: SV8 One missing book

    /// The one missing row that is selected, with the series it is missing from; nil
    /// when anything else is selected.
    private var selectedMissing: (entry: MissingEntry, link: SeriesLink)? {
        guard selection.count == 1, case .missing(let entry) = inspecting, let link = shownSeries?.completeness?.link
        else { return nil }
        return (entry, link)
    }

    /// The missing row these ids are, with the series it is missing from; nil unless
    /// they are exactly one row that is shown now and stands for a book the library
    /// does not have.
    private func shownMissing(_ ids: Set<Int64>) -> (entry: MissingEntry, link: SeriesLink)? {
        guard ids.count == 1, let id = ids.first, let entry = rows.first(where: { $0.id == id })?.missing,
              let link = shownSeries?.completeness?.link
        else { return nil }
        return (entry, link)
    }

    /// SV8: the one selected missing book in the words the inspector shows; nil when
    /// anything else is selected. While it is not nil the three actions are for it:
    /// `showMissingOnAudible` at any time, the other two while its `canChange` is true.
    public var missingBook: MissingBookInfo? {
        guard let (entry, link) = selectedMissing else { return nil }
        return SeriesRows.info(for: entry, link: link, canChange: isQuietForSeries)
    }

    /// SV8: what a context menu opened on these rows offers in place of the book
    /// commands; nil when none of them is a row for a book the library does not have,
    /// and the book commands are the ones to show.
    ///
    /// The actions are for the one missing row the menu was opened on, whether or not
    /// it is selected (`addMissingAsAudibleBook(for:)` and the others that take the
    /// rows): all are off unless these are exactly one missing row that is shown.
    public func missingActions(for ids: Set<Int64>) -> MissingActions? {
        guard holdsMissing(ids) else { return nil }
        guard let (entry, link) = shownMissing(ids) else {
            return MissingActions(canAdd: false, canShow: false, canSetHidden: false, hideTitle: "Hide", isHidden: false)
        }
        let info = SeriesRows.info(for: entry, link: link, canChange: isQuietForSeries)
        return MissingActions(
            canAdd: info.canChange, canShow: true, canSetHidden: info.canChange, hideTitle: info.hideTitle,
            isHidden: info.isHidden)
    }

    /// SV8: adds the one selected missing book to the library as a book that is on
    /// Audible and has no files here, as Add Audible Book adds one: with the entry's
    /// title, authors, narrators and Audible ID, in the store the list came from, under
    /// the owner's own name for the series with Audible's number. The book is then
    /// selected. Nothing is asked of Audible, and no cover is fetched.
    ///
    /// SV9: the entry is then one the library has, and the header's count rises.
    /// When the library has the book already, that book is marked as also on Audible
    /// and `alert` says so.
    public func addMissingAsAudibleBook() async {
        guard let (entry, link) = selectedMissing else { return }
        await addAsAudibleBook(entry, link: link)
    }

    /// The same for the row a context menu was opened on, selected or not. Does
    /// nothing unless `ids` is exactly one missing row that is shown.
    public func addMissingAsAudibleBook(for ids: Set<Int64>) async {
        guard let (entry, link) = shownMissing(ids) else { return }
        await addAsAudibleBook(entry, link: link)
    }

    private func addAsAudibleBook(_ entry: MissingEntry, link: SeriesLink) async {
        guard isQuietForSeries, let worker = await begin("Adding book…") else { return }
        let metadata = SeriesRows.metadata(for: entry.entry, link: link)
        let copy = ExternalCopy(kind: .audible, form: .audio, store: link.store.rawValue, itemId: metadata.asin)
        var outcome: ExternalBookOutcome?
        do {
            outcome = try await worker.addExternalBook(metadata: metadata, cover: nil, copy: copy)
        } catch {
            show(error)
        }
        await reloadAll()
        if let outcome { await showAdded(outcome, with: worker) }
        busyLabel = nil
    }

    /// SV8: opens the one selected missing book's page in the store the list came
    /// from, in the browser.
    public func showMissingOnAudible() {
        guard let (entry, link) = selectedMissing else { return }
        showOnAudible(entry, link: link)
    }

    /// The same for the row a context menu was opened on, selected or not. Does
    /// nothing unless `ids` is exactly one missing row that is shown.
    public func showMissingOnAudible(for ids: Set<Int64>) {
        guard let (entry, link) = shownMissing(ids) else { return }
        showOnAudible(entry, link: link)
    }

    private func showOnAudible(_ entry: MissingEntry, link: SeriesLink) {
        let book = entry.entry.preferred
        opener.openWeb(
            link.store.webAddress(
                asin: book.asin, title: book.title, author: book.authors.lazy.compactMap(\.trimmedOrNil).first ?? ""))
    }

    /// SV8: hides the one selected missing book, or shows it again: a hidden entry is
    /// not counted and has no row, unless hidden entries are shown.
    public func setSelectedMissingHidden(_ hidden: Bool) async {
        guard let (entry, _) = selectedMissing else { return }
        await setHidden(hidden, entry)
    }

    /// The same for the row a context menu was opened on, selected or not. Does
    /// nothing unless `ids` is exactly one missing row that is shown.
    public func setMissingHidden(_ hidden: Bool, for ids: Set<Int64>) async {
        guard let (entry, _) = shownMissing(ids) else { return }
        await setHidden(hidden, entry)
    }

    private func setHidden(_ hidden: Bool, _ entry: MissingEntry) async {
        guard entry.isHidden != hidden, isQuietForSeries else { return }
        await perform("Updating…") { worker in
            try await worker.setMissingEntry(id: entry.id, hidden: hidden)
        }
    }
}

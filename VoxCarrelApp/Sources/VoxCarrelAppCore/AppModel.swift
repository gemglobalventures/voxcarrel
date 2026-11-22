import Foundation
import Observation
import VoxCarrelCore

public enum ViewMode: String, Sendable {
    case grid, list
}

/// What the inspector is showing.
public enum Inspecting: Equatable {
    case nothing
    case one(BookDetail, BookDraft)
    case many(BulkDraft)
}

/// A question the window must put to the user before the model goes on.
public enum PendingPrompt: Equatable {
    /// Save, Discard or Cancel: answered with `AppModel.resolveUnsaved`.
    case unsavedChanges
    /// Answered with `AppModel.confirmRemove`, or dismissed by setting `prompt` to nil.
    /// `outsideFiles`: where those of the books' files are that are not in the library folder.
    /// `withoutFiles`: how many of the books have no files (they are owned elsewhere):
    /// there is nothing of theirs to send to the Trash.
    case removeBooks(ids: [Int64], titles: [String], outsideFiles: [String] = [], withoutFiles: Int = 0)
    /// Answered with `AppModel.confirmChooseLibrary`, or dismissed by setting `prompt` to nil.
    case chooseFolderWithFiles(URL, count: Int, bookFiles: Int)
}

public enum UnsavedChoice: Sendable {
    case save, discard, cancel
}

/// Everything the window shows and does. Views read it and call its methods; they decide
/// nothing themselves.
///
/// The library engine runs on a `LibraryWorker`, off the main thread. Anything that
/// changes the library is an `async` method that sets `busyLabel` while it runs; while it
/// is set, every such method returns at once without doing anything. Setting
/// `sidebarSelection` or `searchText`, and selecting, take effect a moment later, when
/// the worker has answered.
@MainActor @Observable
public final class AppModel {
    @ObservationIgnored let location: LibraryLocation
    @ObservationIgnored let opener: FileOpener
    @ObservationIgnored let defaults: UserDefaults
    /// The folders that may not be made a library. Another set is given by tests.
    @ObservationIgnored var places = ProtectedPlaces.system
    /// How a removed book's file is sent to the Trash; nil for the system's Trash. Read
    /// when a library is opened. Tests give a folder of their own.
    @ObservationIgnored var trashItem: (@Sendable (URL) throws -> Void)?
    /// Nil until a library is open.
    @ObservationIgnored var worker: LibraryWorker? {
        didSet { isLibraryOpen = worker != nil }
    }

    /// - Parameters:
    ///   - lookupService: Makes what books are looked up with, from the lookup
    ///     sources that are on and the Audible stores to search; nil for the real sources
    ///     over the network. Tests give fakes.
    ///   - watcher: Says when something changes in a watch folder. Tests give one they
    ///     fire by hand.
    ///   - ticker: Runs the inbox's later checks. Tests give one that never waits.
    ///   - inboxNow: The time, as the inbox checks are told it. Tests move it by hand.
    public init(
        location: LibraryLocation, opener: FileOpener, defaults: UserDefaults = .standard,
        lookupService: ((LookupConfiguration) -> LookupService)? = nil,
        watcher: FolderWatching = FSEventsFolderWatcher(), ticker: Ticking = TimerTicker(),
        inboxNow: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.location = location
        self.opener = opener
        self.defaults = defaults
        self.watcher = watcher
        self.ticker = ticker
        self.inboxNow = inboxNow
        makeLookupService = lookupService ?? { LookupService.standard($0) }
        storedAudibleStore = defaults.string(forKey: Keys.audibleStore).flatMap(AudibleStore.init)
            ?? AudibleStore.forRegion(Locale.current.region?.identifier)
        // A8c: the Library of Congress is off until the user turns it on.
        storedLookupSources = (defaults.array(forKey: Keys.lookupSources) as? [String])
            .map { Set($0.compactMap(LookupSource.init)) } ?? Self.defaultLookupSources
        storedOtherStores = (defaults.array(forKey: Keys.audibleStores) as? [String])
            .map { Set($0.compactMap(AudibleStore.init)) } ?? Self.defaultOtherStores
        status = location.status()
        storedViewMode = defaults.string(forKey: Keys.viewMode).flatMap(ViewMode.init) ?? .grid
        storedSort = BookSort(
            key: defaults.string(forKey: Keys.sortKey).flatMap(BookSortKey.init) ?? .title,
            ascending: defaults.object(forKey: Keys.sortAscending) as? Bool ?? true)
        storedCopyOnImport = defaults.object(forKey: Keys.copyOnImport) as? Bool ?? false
    }

    private enum Keys {
        static let viewMode = "viewMode"
        static let sortKey = "sortKey"
        static let sortAscending = "sortAscending"
        static let copyOnImport = "copyOnImport"
        static let audibleStore = "audibleStore"
        static let lookupSources = "lookupSources"
        static let audibleStores = "audibleStores"
    }

    // MARK: Library

    public private(set) var status: LibraryStatus
    /// The library folder is there but would not open: why, as a sentence.
    public private(set) var openFailure: String?
    /// True once the library has been opened; false again while another is being opened.
    public private(set) var isLibraryOpen = false

    /// Opens the stored library and runs the launch check.
    public func start() async {
        guard busyLabel == nil else { return }
        await openLibrary()
    }

    /// As `start()` the first time it is called, and nothing after that: for the window,
    /// which may be closed and opened again while the app runs.
    public func startIfNeeded() async {
        guard !hasStarted else { return }
        hasStarted = true
        await start()
    }

    @ObservationIgnored private var hasStarted = false

    /// Looks for the stored library again, and opens it if it is there now.
    public func retryLibrary() async {
        guard busyLabel == nil else { return }
        await openLibrary()
    }

    /// Whether a library folder can be chosen now: nothing is running and no question
    /// is waiting for an answer.
    public var canChooseLibrary: Bool {
        busyLabel == nil && storedPrompt == nil
    }

    /// Makes `folder` the library. A folder that already holds other files is not taken
    /// without asking: `prompt` becomes `.chooseFolderWithFiles`.
    ///
    /// While something is running or a question is waiting, the folder is not taken and
    /// `alert` says why: it was picked in a panel, so doing nothing would look like a fault.
    public func chooseLibrary(_ folder: URL) async {
        guard busyLabel == nil else {
            alert = "VoxCarrel is busy. Choose the library folder again when it has finished."
            return
        }
        guard storedPrompt == nil else {
            alert = "Answer the question in the VoxCarrel window first, then choose the library folder again."
            return
        }
        // A4
        if hasUnsavedChanges {
            ask(about: .library(folder))
            return
        }
        switch LibraryLocation.inspect(folder, places: places) {
        case .existingLibrary, .empty:
            await adopt(folder)
        case .hasOtherFiles(let count, let bookFiles):
            raise(.chooseFolderWithFiles(folder, count: count, bookFiles: bookFiles))
        case .notUsable(let why):
            alert = why
        }
    }

    /// The answer "use it anyway" to `.chooseFolderWithFiles`, for the folder that was asked about.
    public func confirmChooseLibrary(_ folder: URL) async {
        guard busyLabel == nil, case .chooseFolderWithFiles(let asked, _, _) = storedPrompt, asked == folder
        else { return }
        storedPrompt = nil
        if case .notUsable(let why) = LibraryLocation.inspect(folder, places: places) {
            alert = why
            return
        }
        await adopt(folder)
    }

    /// A3: nothing of the library shown before is left showing.
    private func adopt(_ folder: URL) async {
        location.url = folder
        storedSearchText = ""
        storedSidebarSelection = .allBooks
        result = nil
        await openLibrary()
    }

    /// A1
    private func openLibrary() async {
        // A26: files the app was asked to open meanwhile are imported, or refused, now.
        defer {
            hasTriedLibrary = true
            importHeldFiles()
        }
        worker = nil
        // WF10: the inbox was the inbox of the library shown before.
        closeInbox()
        openFailure = nil
        sidebar = SidebarData(counts: [:], browse: [:], collections: [])
        rows = []
        rowsLoaded = false
        selection = []
        anchor = nil
        inspecting = .nothing
        undoLabel = nil
        libraryCheck = nil
        missingFileTitles = []
        review = nil
        reviewIsOfUntracked = false
        // A5: a lookup was for a book or an import of the library shown before.
        closeLookup()
        strandedNames = [:]
        sentDraft = nil
        // A25: a request to quit that was waiting for an answer is called off.
        if case .quit = pending { answerQuit(false) }
        pending = nil
        // A24: a question or a message about the library shown before is not about this one.
        storedPrompt = nil
        alert = nil
        result = nil
        // Anything still on its way from the library shown before is not wanted.
        rowsGeneration += 1
        inspectorGeneration += 1
        shown = (storedSidebarSelection, storedSearchText)

        status = location.status()
        guard case .available(let folder) = status else { return }

        busyLabel = "Opening library…"
        defer { busyLabel = nil }
        do {
            // Opening reads the disk and may create or migrate the catalogue: not on the main thread.
            let trashItem = trashItem
            let lookup = makeLookupService(lookupConfiguration)
            worker = try await Task.detached {
                try LibraryWorker(libraryRoot: folder, trashItem: trashItem, lookup: lookup)
            }.value
        } catch {
            openFailure =
                "The library in \"\(folder.lastPathComponent)\" could not be opened. \(UserMessage.text(for: error))"
            return
        }
        await reloadAll()

        guard let worker else { return }
        do {
            let report = try await worker.reconcile()
            // The check flags books with missing files and clears the flag of books that are whole
            // again, corrects the length of books whose files stated the wrong one, and marks
            // files it finds to state the wrong length.
            if !report.booksWithMissingFiles.isEmpty || !report.booksRecovered.isEmpty
                || report.correctedLengths > 0 || report.filesWithWrongLength > 0 {
                await reloadAll()
            }
            // A2
            let worthTelling = !report.booksWithMissingFiles.isEmpty || !report.untrackedFiles.isEmpty
                || !report.strandedFiles.isEmpty || report.correctedLengths > 0
                || report.filesWithWrongLength > 0
            if !report.booksWithMissingFiles.isEmpty {
                // Q10: named now, so that the check can list them whatever the window shows later.
                let missing = Set(report.booksWithMissingFiles)
                missingFileTitles = try await worker.rows(for: .needsAttention, search: "")
                    .filter { missing.contains($0.id) }
                    .map(\.book.title)
                    .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            }
            strandedNames = try await worker.likelyNames(ofStranded: report.strandedFiles)
            libraryCheck = worthTelling ? report : nil
        } catch {
            show(error)
        }
        // WF10: the launch check is over.
        await openInbox()
    }

    // MARK: Browsing

    public private(set) var sidebar = SidebarData(counts: [:], browse: [:], collections: [])

    /// Setting it reloads `rows`.
    public var sidebarSelection: SidebarItem {
        get { storedSidebarSelection }
        set {
            guard newValue != storedSidebarSelection else { return }
            storedSidebarSelection = newValue
            browseChanged()
        }
    }

    /// Setting it reloads `rows`.
    public var searchText: String {
        get { storedSearchText }
        set {
            guard newValue != storedSearchText else { return }
            storedSearchText = newValue
            browseChanged()
        }
    }

    /// Remembered.
    public var viewMode: ViewMode {
        get { storedViewMode }
        set {
            storedViewMode = newValue
            defaults.set(newValue.rawValue, forKey: Keys.viewMode)
        }
    }

    /// Remembered. Setting it re-orders `rows` at once.
    public var sort: BookSort {
        get { storedSort }
        set {
            storedSort = newValue
            defaults.set(newValue.key.rawValue, forKey: Keys.sortKey)
            defaults.set(newValue.ascending, forKey: Keys.sortAscending)
            rows = newValue.sorted(rows, showing: shown.0)
        }
    }

    /// Whether an import copies files and leaves the originals. Remembered.
    public var copyOnImport: Bool {
        get { storedCopyOnImport }
        set {
            storedCopyOnImport = newValue
            defaults.set(newValue, forKey: Keys.copyOnImport)
        }
    }

    /// Already sorted.
    public private(set) var rows: [BookRow] = [] {
        didSet {
            if !RowsChange.isSmall(from: oldValue.map(\.id), to: rows.map(\.id)) { rowsVersion += 1 }
        }
    }
    /// Changes whenever `rows` becomes a very different list (`RowsChange`): the list
    /// view makes its table again then, in place of having it work out what moved.
    public private(set) var rowsVersion = 0
    /// False until the open library's books have been read once: `rows` is empty before
    /// then because nothing is known yet, not because there are no books.
    private(set) var rowsLoaded = false
    public internal(set) var selection: Set<Int64> = []

    /// The book the list should scroll to when it has been made again (`rowsVersion`):
    /// the first of the selected books that is shown; nil when none is.
    public var scrollTarget: Int64? {
        rows.first { selection.contains($0.id) }?.id
    }

    /// A click in the grid.
    public func click(_ id: Int64, modifiers: SelectionLogic.Modifiers) {
        let clicked = SelectionLogic.click(
            id, modifiers: modifiers, order: rows.map(\.id), selection: selection, anchor: anchor)
        requestSelection(clicked.selection, anchor: clicked.anchor)
    }

    /// Selects exactly these books (those of them that are shown): for the list view and the keyboard.
    public func select(_ ids: Set<Int64>) {
        let shownIds = ids.intersection(rows.map(\.id))
        var newAnchor = anchor.flatMap { shownIds.contains($0) ? $0 : nil }
        if shownIds.count == 1 { newAnchor = shownIds.first }
        requestSelection(shownIds, anchor: newAnchor)
    }

    public func selectAll() {
        requestSelection(Set(rows.map(\.id)), anchor: anchor)
    }

    /// An arrow key in the grid, which shows the rows in `columns` columns: selects only
    /// the book the arrow leads to (`SelectionLogic.move`). Returns that book when it is
    /// now the selection, for the grid to scroll to; nil when there are no books, or the
    /// move is waiting for an answer about unsaved changes.
    @discardableResult
    public func moveSelection(_ direction: SelectionLogic.Direction, columns: Int) -> Int64? {
        guard
            let id = SelectionLogic.move(
                direction, columns: columns, order: rows.map(\.id), selection: selection, anchor: anchor)
        else { return nil }
        requestSelection([id], anchor: id)
        return selection == [id] ? id : nil
    }

    /// The books a context menu opened on this book is for: the selection when the book
    /// is part of it, otherwise the book alone.
    public func contextTarget(for id: Int64) -> Set<Int64> {
        selection.contains(id) ? selection : [id]
    }

    /// A context menu is being opened on this book: a book that is not selected becomes
    /// the selection, so that what the menu acts on is what is seen to be selected.
    /// While there are unsaved changes the selection is left alone, and no question is
    /// asked; the menu still acts on `contextTarget(for:)`.
    public func contextClick(_ id: Int64) {
        guard !selection.contains(id), !hasUnsavedChanges, rows.contains(where: { $0.id == id }) else { return }
        applySelection([id], anchor: id)
    }

    private var storedSidebarSelection = SidebarItem.allBooks
    private var storedSearchText = ""
    private var storedViewMode: ViewMode
    private var storedSort: BookSort
    private var storedCopyOnImport: Bool
    /// Where a shift-click's range starts.
    @ObservationIgnored private var anchor: Int64?
    /// What `rows` holds the books of. Differs from the stored values while a reload is
    /// on its way, or is waiting for an answer about unsaved changes.
    @ObservationIgnored private var shown: (item: SidebarItem, search: String) = (.allBooks, "")
    @ObservationIgnored private var rowsGeneration = 0
    @ObservationIgnored var inspectorGeneration = 0

    private func browseChanged() {
        latestReload = spawn { await self.reloadRows() }
    }

    /// The rows for the sidebar selection and search text as they are now. A5, A8.
    private func reloadRows() async {
        let item = storedSidebarSelection
        let search = storedSearchText
        guard let worker else {
            shown = (item, search)
            return
        }
        rowsGeneration += 1
        let generation = rowsGeneration
        do {
            // WF24: the inbox has no book rows, and the library is not asked for any.
            let fetched = item == .inbox ? [] : try await worker.rows(for: item, search: search)
            await beforeApplyingRows?(search)
            // A5: a newer reload has started (or finished) since; its answer is the one wanted.
            guard generation == rowsGeneration else { return }
            let ids = Set(fetched.map(\.id))
            // A8: showing these rows would take a book with unsaved edits out of the selection.
            if hasUnsavedChanges, !selection.isSubset(of: ids) {
                ask(about: .browse)
                return
            }
            rows = storedSort.sorted(fetched, showing: item)
            rowsLoaded = true
            shown = (item, search)
            if !selection.isSubset(of: ids) {
                setSelection(selection.intersection(ids), anchor: anchor)
                await refreshInspector()
            }
        } catch {
            show(error)
        }
    }

    /// Reads everything again after the library may have changed: sidebar, undo label,
    /// rows, and the inspector with fresh file ids. A11.
    ///
    /// A13: unsaved edits are carried over to the books as they are now, unless
    /// `keepEdits` is false. A book with unsaved edits that is no longer among the rows
    /// stays selected, and so stays in the inspector, until the edits are saved or
    /// discarded.
    func reloadAll(keepEdits: Bool = true) async {
        guard let worker else { return }
        rowsGeneration += 1
        let generation = rowsGeneration
        do {
            sidebar = try await worker.sidebar()
            undoLabel = try await worker.undoLabel()
            if generation == rowsGeneration {
                // A browse value or a collection that no longer exists has no books to show.
                if !sidebar.contains(storedSidebarSelection) { storedSidebarSelection = .allBooks }
                // WF13
                if storedSidebarSelection == .inbox, !showsInbox { storedSidebarSelection = .allBooks }
                let item = storedSidebarSelection
                let search = storedSearchText
                // WF24
                let fetched = item == .inbox ? [] : try await worker.rows(for: item, search: search)
                if generation == rowsGeneration {
                    rows = storedSort.sorted(fetched, showing: item)
                    rowsLoaded = true
                    shown = (item, search)
                    if !(keepEdits && hasUnsavedChanges) {
                        selection.formIntersection(fetched.map(\.id))
                    }
                }
            }
        } catch {
            show(error)
        }
        await refreshInspector(keepEdits: keepEdits)
    }

    // MARK: Selecting

    /// What was asked for while there were unsaved changes, kept until the user answers.
    enum PendingChange {
        case selection(Set<Int64>, anchor: Int64?)
        /// The sidebar selection and search text are already stored; `shown` has the old ones.
        case browse
        case library(URL)
        /// A25: the app was asked to quit; `quitReply` is waiting for the answer.
        case quit
    }

    @ObservationIgnored var pending: PendingChange?

    /// A8
    private func requestSelection(_ ids: Set<Int64>, anchor: Int64?) {
        guard ids != selection else {
            self.anchor = anchor
            return
        }
        if hasUnsavedChanges {
            ask(about: .selection(ids, anchor: anchor))
        } else {
            applySelection(ids, anchor: anchor)
        }
    }

    /// A24: puts a question to the user, unless one is waiting already: there is only
    /// ever one. Returns whether it was put.
    @discardableResult
    func raise(_ question: PendingPrompt) -> Bool {
        guard storedPrompt == nil else { return false }
        storedPrompt = question
        return true
    }

    /// Asks about unsaved changes before doing `change`.
    ///
    /// A24: while a question is waiting, no other is asked and `change` is forgotten;
    /// a change of sidebar selection or search text is taken back, so that what is
    /// stored is what the rows show. The one exception is a newer change of sidebar or
    /// search while the unsaved-changes question about an older one is up: the stored
    /// values are the newer ones already, and the answer applies those.
    private func ask(about change: PendingChange) {
        if raise(.unsavedChanges) {
            pending = change
            return
        }
        guard case .browse = change else { return }
        if storedPrompt == .unsavedChanges, case .browse = pending { return }
        storedSidebarSelection = shown.item
        storedSearchText = shown.search
    }

    /// Selects, shows what is already known about the selection, and fetches the rest.
    func applySelection(_ ids: Set<Int64>, anchor: Int64?) {
        setSelection(ids, anchor: anchor)
        latestInspectorRefresh = spawn { await self.refreshInspector() }
    }

    /// A9, as far as it can be done without asking the library: a single book is shown
    /// from its row, without files, until `refreshInspector` has its details.
    private func setSelection(_ ids: Set<Int64>, anchor: Int64?) {
        selection = ids
        self.anchor = anchor
        if ids.count == 1, let id = ids.first {
            if case .one(let detail, _) = inspecting, detail.row.id == id { return }
            if let row = rows.first(where: { $0.id == id }) {
                let detail = BookDetail(row: row, files: [], chapterCount: 0, collectionIds: [])
                inspecting = .one(detail, BookDraft(book: row.book))
            } else {
                inspecting = .nothing
            }
        } else if ids.isEmpty {
            inspecting = .nothing
        } else {
            inspecting = .many(BulkDraft(books: rows.filter { ids.contains($0.id) }.map(\.book)))
        }
    }

    /// Forgets what was asked for, and puts the sidebar selection and search text back
    /// to what the rows show.
    func cancelPending() {
        if case .browse = pending {
            storedSidebarSelection = shown.item
            storedSearchText = shown.search
        }
        if case .quit = pending { answerQuit(false) }
        pending = nil
    }

    /// Does what was asked for, now that there are no unsaved changes in the way.
    func applyPending(_ change: PendingChange?) async {
        switch change {
        case .selection(let ids, let anchor):
            applySelection(ids.intersection(rows.map(\.id)), anchor: anchor)
            await latestInspectorRefresh?.value
        case .browse:
            await reloadRows()
        case .library(let folder):
            await chooseLibrary(folder)
        case .quit:
            answerQuit(true)
        case nil:
            break
        }
    }

    // MARK: Activity

    /// Not nil while an operation runs: what to show beside the progress indicator.
    public internal(set) var busyLabel: String? {
        didSet {
            // A26
            if busyLabel == nil {
                importHeldFiles()
                // WF12: a check of the inbox that was put off while the operation ran.
                resumeInboxCheck()
            }
        }
    }
    /// A plain sentence, dismissed by the view.
    public var alert: String?
    /// Shown as a sheet when not clean.
    public var result: ResultSummary?

    /// The question waiting for an answer. Setting it to nil dismisses the question; for
    /// `.unsavedChanges` that is the same as answering Cancel.
    public var prompt: PendingPrompt? {
        get { storedPrompt }
        set {
            if storedPrompt == .unsavedChanges, newValue != .unsavedChanges { cancelPending() }
            storedPrompt = newValue
        }
    }

    /// The operation Undo would reverse, e.g. "Import 3 books"; nil when there is none.
    public private(set) var undoLabel: String?
    /// Not nil when the launch check found something to tell.
    public internal(set) var libraryCheck: ReconcileReport?

    /// A18: reverses the last import or edit. When the files cannot be put back nothing
    /// is changed, `alert` says why, and Undo can be tried again.
    public func undo() async {
        await perform("Undoing…") { worker in
            _ = try await worker.undoLast()
        }
        // WF20: an import from the Inbox that is undone leaves its books waiting again,
        // and a copy that is undone changes nothing in the watch folder for the watcher to see.
        if showsInbox { requestInboxCheck() }
    }

    public func dismissLibraryCheck() {
        libraryCheck = nil
    }

    /// The titles of the books the launch check found files missing from, in
    /// alphabetical order.
    var missingFileTitles: [String] = []
    /// For the launch check's half-moved files, the name each very likely had.
    var strandedNames: [URL: String] = [:]

    /// Q11: closes the launch check and shows the books that need attention, with no
    /// search in the way.
    public func showNeedsAttention() {
        libraryCheck = nil
        searchText = ""
        sidebarSelection = .needsAttention
    }

    var storedPrompt: PendingPrompt?

    /// True while there is a question or a message for the user: the window that shows
    /// them must be brought in front of whatever else is open (Settings, say), and
    /// opened again if it was closed.
    public var wantsToBeSeen: Bool {
        storedPrompt != nil || alert != nil
    }

    // MARK: Quitting

    /// What to tell the system when the app is asked to quit.
    public enum QuitAnswer: Sendable {
        /// Quit at once.
        case now
        /// A question has been put to the user; `reply` will be called with the answer.
        case later
        /// Do not quit.
        case cancel
    }

    /// A25: the app has been asked to quit.
    ///
    /// With unsaved changes the unsaved-changes question is asked, and `reply` is
    /// called once with whether to quit: true after Save (if the save went through) or
    /// Discard, false after Cancel. The app does not quit while an operation is running
    /// (it may be moving files), nor over another question that is waiting.
    public func requestQuit(reply: @escaping @MainActor (Bool) -> Void) -> QuitAnswer {
        guard busyLabel == nil else {
            alert = "VoxCarrel is still working. Quit when it has finished."
            return .cancel
        }
        guard hasUnsavedChanges else { return .now }
        guard storedPrompt == nil else { return .cancel }
        quitReply = reply
        ask(about: .quit)
        return .later
    }

    @ObservationIgnored private var quitReply: (@MainActor (Bool) -> Void)?

    private func answerQuit(_ quit: Bool) {
        let reply = quitReply
        quitReply = nil
        reply?(quit)
    }


    func show(_ error: Error) {
        alert = UserMessage.text(for: error)
    }

    /// Starts an operation: nil when one is already running or no library is open (A16).
    func begin(_ label: String) async -> LibraryWorker? {
        guard busyLabel == nil, let worker else { return nil }
        busyLabel = label
        await beforeOperation?()
        return worker
    }

    /// Ends an operation: everything is read again (A11), whether or not it succeeded (A17).
    func finish(keepEdits: Bool = true) async {
        await reloadAll(keepEdits: keepEdits)
        busyLabel = nil
    }

    /// Runs `work` as one operation. An error it throws is shown as a sentence.
    func perform(_ label: String, _ work: (LibraryWorker) async throws -> Void) async {
        guard let worker = await begin(label) else { return }
        do {
            try await work(worker)
        } catch {
            show(error)
        }
        await finish()
    }

    // MARK: Import

    /// The import being reviewed; not nil shows the sheet. Changed through
    /// `updateReview`, closed by `confirmImport` or `cancelImport`.
    public internal(set) var review: ImportReview? {
        didSet {
            // An import to review takes the window: a lookup for the inspected book, or
            // for an Audible book to add, closes, with nothing applied or added, so that
            // the import's books can be looked up.
            if oldValue == nil, review != nil {
                switch lookup?.target {
                case .book, .newAudibleBook: closeLookup()
                case .importEntry, nil: break
                }
            }
            closeLookupIfItsTargetHasGone()
        }
    }
    /// Whether the review began as a copy, to tell a choice the user made from the setting it began with.
    @ObservationIgnored var reviewBeganCopying = false
    /// Whether the review is of the files the launch check found loose in the library folder.
    @ObservationIgnored var reviewIsOfUntracked = false
    /// A26: true once the library has been looked for, whether or not it opened.
    @ObservationIgnored var hasTriedLibrary = false
    /// A26: files the app was asked to open that are waiting for the library to open, or
    /// for an operation to end.
    @ObservationIgnored var heldFiles: [URL] = []

    // MARK: Inbox

    @ObservationIgnored let watcher: FolderWatching
    @ObservationIgnored let ticker: Ticking
    /// The time an inbox check is told it is.
    @ObservationIgnored var inboxNow: @MainActor () -> Date
    /// The books waiting in the watch folders, as the last good check found them.
    var inboxArrivals: [InboxArrival] = []
    /// The watch folders, oldest first.
    var watchFolders: [WatchFolder] = []
    /// Whether each watch folder could be looked into at the last check, by its id.
    var watchFolderAvailability: [Int64: FolderAvailability] = [:]
    /// WF23: said on the Inbox when the last check failed; nil after a good one.
    public internal(set) var inboxProblem: String?
    /// The arrivals selected in the Inbox, by id. Ids that are no longer arrivals are
    /// dropped at each check.
    public var inboxSelection: Set<String> = []
    /// WF11: true from when a check is started until no further one is wanted.
    @ObservationIgnored var inboxCheckRunning = false
    /// WF11, WF12: a check was asked for while one ran or an operation held the library.
    @ObservationIgnored var inboxCheckWanted = false
    /// The regular check, and the one a settle interval after unsettled files were
    /// seen, are each waiting with the ticker.
    @ObservationIgnored var inboxTickScheduled = false
    @ObservationIgnored var inboxRecheckScheduled = false
    /// The folders the watcher was last started on; nil when it is stopped.
    @ObservationIgnored var watchedPaths: [String]?
    /// How many checks of the inbox have been made. For tests.
    @ObservationIgnored var inboxCheckCount = 0

    // MARK: Inspector

    /// What the inspector shows. Follows `selection`.
    public internal(set) var inspecting: Inspecting = .nothing {
        didSet { closeLookupIfItsTargetHasGone() }
    }
    /// While a save runs: the draft as it was when it was sent, to tell what has been
    /// typed since. Nil at any other time.
    @ObservationIgnored var sentDraft: Inspecting?

    /// A9: fetches what the selection needs and shows it. A13: edits not yet saved are
    /// carried over to the books as they are now, unless `keepEdits` is false.
    func refreshInspector(keepEdits: Bool = true) async {
        inspectorGeneration += 1
        let generation = inspectorGeneration
        guard let worker, !selection.isEmpty else {
            inspecting = .nothing
            return
        }
        do {
            if selection.count == 1, let id = selection.first {
                let detail = try await worker.detail(bookId: id)
                // The selection has changed since; a newer refresh is on its way.
                guard generation == inspectorGeneration else { return }
                guard let detail else {
                    // The book is no longer in the library.
                    selection = []
                    inspecting = .nothing
                    return
                }
                var draft = BookDraft(book: detail.row.book)
                // Read now, not before the wait: what was typed meanwhile is kept too.
                if case .one(let old, let oldDraft) = inspecting, old.row.id == id {
                    if keepEdits {
                        if oldDraft.isDirty { draft = oldDraft.reapplied(onto: detail.row.book) }
                    } else if case .one(_, let sent)? = sentDraft, sent.original.id == id, oldDraft != sent {
                        // A10: saved, but more was typed while the save ran.
                        draft = oldDraft.reapplied(changedSince: sent, onto: detail.row.book)
                    }
                }
                inspecting = .one(detail, draft)
            } else {
                // In row order; then any book that is selected only because it has unsaved edits.
                var books = rows.filter { selection.contains($0.id) }.map(\.book)
                var gone = Set<Int64>()
                for id in selection.subtracting(rows.map(\.id)).sorted() {
                    if let detail = try await worker.detail(bookId: id) {
                        books.append(detail.row.book)
                    } else {
                        gone.insert(id)
                    }
                }
                guard generation == inspectorGeneration else { return }
                if !gone.isEmpty {
                    selection.subtract(gone)
                    if selection.count < 2 {
                        await refreshInspector(keepEdits: false)
                        return
                    }
                }
                var draft = BulkDraft(books: books)
                if case .many(let old) = inspecting {
                    if keepEdits {
                        if old.isDirty { draft.values = old.values }
                    } else if case .many(let sent)? = sentDraft {
                        // A10: saved, but more was typed while the save ran.
                        draft.values = old.values.filter { sent.values[$0.key] != $0.value }
                    }
                }
                inspecting = .many(draft)
            }
        } catch {
            guard generation == inspectorGeneration else { return }
            show(error)
        }
    }

    /// The ids in the order the rows show them, then any that are not shown.
    func ordered(_ ids: Set<Int64>) -> [Int64] {
        let shownIds = rows.map(\.id)
        return shownIds.filter(ids.contains) + ids.subtracting(shownIds).sorted()
    }

    // MARK: Looking up online

    /// The lookup that is open; not nil shows its sheet, over the import sheet when its
    /// `target` is an import entry and over the window otherwise. Opened by
    /// `beginLookup` or `beginAddAudibleBook`, closed by `applyLookup`,
    /// `addLookupSelection`, `addAudibleBookByHand` or `cancelLookup`, and whenever what
    /// it was for has gone.
    public internal(set) var lookup: LookupSession?

    /// A7: the user's own Audible store: the one searched first, whose ASIN a result
    /// carries when the store lists it, and where a book marked as on Audible is taken
    /// to be. Remembered; the Mac's region's to begin with. Changing it rebuilds what
    /// the open library looks books up with.
    public var audibleStore: AudibleStore {
        get { storedAudibleStore }
        set {
            guard newValue != storedAudibleStore else { return }
            storedAudibleStore = newValue
            defaults.set(newValue.rawValue, forKey: Keys.audibleStore)
            lookupSettingsChanged()
        }
    }

    static let defaultLookupSources: Set<LookupSource> = [.openLibrary, .audible]
    static let defaultOtherStores: Set<AudibleStore> = [.us, .uk, .au]

    /// A8b: the lookup sources that are on. Remembered; Open Library and Audible to
    /// begin with (A8c: the Library of Congress is off until it is turned on). A source
    /// that is off is never contacted: changing this rebuilds what the open library
    /// looks books up with, from the sources that are on.
    public var lookupSources: Set<LookupSource> {
        get { storedLookupSources }
        set {
            guard newValue != storedLookupSources else { return }
            storedLookupSources = newValue
            defaults.set(LookupSource.allCases.filter(newValue.contains).map(\.rawValue), forKey: Keys.lookupSources)
            lookupSettingsChanged()
        }
    }

    /// A8: the Audible stores searched besides the user's own. Remembered; the United
    /// States, the United Kingdom and Australia to begin with.
    public var otherAudibleStores: Set<AudibleStore> {
        get { storedOtherStores }
        set {
            guard newValue != storedOtherStores else { return }
            storedOtherStores = newValue
            defaults.set(AudibleStore.allCases.filter(newValue.contains).map(\.rawValue), forKey: Keys.audibleStores)
            lookupSettingsChanged()
        }
    }

    /// A8: the Audible stores a lookup searches: the user's own first, then the others
    /// chosen, each once.
    public var audibleStores: [AudibleStore] {
        [storedAudibleStore] + AudibleStore.allCases.filter { $0 != storedAudibleStore && storedOtherStores.contains($0) }
    }

    /// What the lookup service is built from: the sources that are on, and the stores.
    var lookupConfiguration: LookupConfiguration {
        LookupConfiguration(sources: storedLookupSources, audibleStores: audibleStores)
    }

    /// A8b: whether there is any lookup source to ask.
    var canAskLookupSources: Bool {
        !storedLookupSources.isEmpty
    }

    /// The lookup service is built again from the settings as they are now.
    ///
    /// A lookup that is open is brought into line: a search that is running is for
    /// the sources as they were, and is cancelled, its answer never shown; the results
    /// of a source that is now off go, with their ticks; and the search is made again
    /// with the sources as they are. A lookup whose values are being applied is left
    /// to finish.
    private func lookupSettingsChanged() {
        worker?.setLookupService(makeLookupService(lookupConfiguration))
        guard var session = lookup else { return }
        guard session.phase != .applying else {
            session.sourcesChanged()
            lookup = session
            return
        }
        lookupSearch?.cancel()
        lookupDetailLoads.values.forEach { $0.cancel() }
        lookupDetailLoads = [:]
        // Whatever is still on its way was asked of the sources as they were.
        lookupGeneration += 1
        session.sourcesChanged(to: storedLookupSources)
        lookup = session
        startLookupSearch()
    }

    private var storedAudibleStore: AudibleStore
    private var storedLookupSources: Set<LookupSource>
    private var storedOtherStores: Set<AudibleStore>
    @ObservationIgnored private let makeLookupService: (LookupConfiguration) -> LookupService
    /// The two-letter code of the language results are preferred in: the Mac's own.
    /// Tests give another.
    @ObservationIgnored var lookupLanguage = Locale.current.language.languageCode?.identifier
    /// The search that is running, or the last that ran.
    @ObservationIgnored var lookupSearch: Task<Void, Never>?
    /// Changes whenever a lookup is opened or closed: an answer that arrives for a
    /// lookup that has closed is not for the one that is open now.
    @ObservationIgnored var lookupGeneration = 0
    /// V6: the covers of the open lookup's results, by address, and those on their way.
    @ObservationIgnored var lookupThumbnails: [URL: Data] = [:]
    @ObservationIgnored var lookupThumbnailLoads: [URL: Task<Data?, Never>] = [:]
    /// The requests for more about a result that are on their way, by the result's id.
    @ObservationIgnored var lookupDetailLoads: [String: Task<Void, Never>] = [:]
    /// The cover on its way for an Audible book that is being added; nil when none is.
    /// Closing the lookup cancels it and ends the add there and then.
    @ObservationIgnored var addCoverFetch: Task<CoverImage?, Never>?

    // MARK: Checking editions

    /// K8: true while Check Edition is looking books up: it can be cancelled.
    public internal(set) var isCheckingEdition = false
    /// The lookups of a Check Edition that is running.
    @ObservationIgnored var editionCheck: Task<EditionLookups?, Never>?
    // MARK: Work in the background

    @ObservationIgnored private var background: [UUID: Task<Void, Never>] = [:]
    /// The most recent reload of the rows that a change of sidebar selection or search text started.
    @ObservationIgnored var latestReload: Task<Void, Never>?
    @ObservationIgnored var latestInspectorRefresh: Task<Void, Never>?

    /// Starts work that a property setter or a plain method cannot wait for.
    @discardableResult
    func spawn(_ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let id = UUID()
        let task = Task { @MainActor in
            await work()
            self.background[id] = nil
        }
        background[id] = task
        return task
    }

    /// Returns when nothing started by `spawn` is still running. For tests.
    func settle() async {
        while let task = background.values.first {
            await task.value
        }
    }

    // MARK: Test seams

    /// Awaited by every operation just after `busyLabel` is set.
    @ObservationIgnored var beforeOperation: (@Sendable () async -> Void)?
    /// Awaited by a reload of the rows when the library has answered, before the answer
    /// is used. Given the search text the reload was for.
    @ObservationIgnored var beforeApplyingRows: (@Sendable (String) async -> Void)?
    /// Awaited when a cover's file has been read, before the cover is given to the draft.
    @ObservationIgnored var beforeUsingCover: (@Sendable () async -> Void)?
    /// Awaited by every check of the inbox before the library is asked. An error it
    /// throws is taken as the check failing.
    @ObservationIgnored var beforeInboxCheck: (@Sendable () async throws -> Void)?
}

extension SidebarData {
    /// Whether the sidebar has this item to show.
    func contains(_ item: SidebarItem) -> Bool {
        switch item {
        case .browse(let field, let value): browse[field]?.contains(value) ?? false
        case .collection(let id): collections.contains { $0.id == id }
        default: true
        }
    }
}

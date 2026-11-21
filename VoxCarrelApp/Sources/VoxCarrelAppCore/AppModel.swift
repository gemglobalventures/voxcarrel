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
    case removeBooks(ids: [Int64], titles: [String])
    /// Answered with `AppModel.confirmChooseLibrary`, or dismissed by setting `prompt` to nil.
    case chooseFolderWithFiles(URL, count: Int)
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
    /// Nil until a library is open.
    @ObservationIgnored var worker: LibraryWorker? {
        didSet { isLibraryOpen = worker != nil }
    }

    public init(location: LibraryLocation, opener: FileOpener, defaults: UserDefaults = .standard) {
        self.location = location
        self.opener = opener
        self.defaults = defaults
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

    /// Makes `folder` the library. A folder that already holds other files is not taken
    /// without asking: `prompt` becomes `.chooseFolderWithFiles`.
    public func chooseLibrary(_ folder: URL) async {
        guard busyLabel == nil else { return }
        // A4
        if hasUnsavedChanges {
            ask(about: .library(folder))
            return
        }
        switch LibraryLocation.inspect(folder) {
        case .existingLibrary, .empty:
            await adopt(folder)
        case .hasOtherFiles(let count):
            storedPrompt = .chooseFolderWithFiles(folder, count: count)
        case .notUsable(let why):
            alert = why
        }
    }

    /// The answer "use it anyway" to `.chooseFolderWithFiles`.
    public func confirmChooseLibrary(_ folder: URL) async {
        guard busyLabel == nil else { return }
        if case .chooseFolderWithFiles = storedPrompt { storedPrompt = nil }
        if case .notUsable(let why) = LibraryLocation.inspect(folder) {
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
        worker = nil
        openFailure = nil
        sidebar = SidebarData(counts: [:], browse: [:], collections: [])
        rows = []
        selection = []
        anchor = nil
        inspecting = .nothing
        undoLabel = nil
        libraryCheck = nil
        review = nil
        pending = nil
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
            worker = try await Task.detached { try LibraryWorker(libraryRoot: folder) }.value
        } catch {
            openFailure =
                "The library in \"\(folder.lastPathComponent)\" could not be opened. \(UserMessage.text(for: error))"
            return
        }
        await reloadAll()

        guard let worker else { return }
        do {
            let report = try await worker.reconcile()
            // The check flags books with missing files and clears the flag of books that are whole again.
            if !report.booksWithMissingFiles.isEmpty || !report.booksRecovered.isEmpty {
                await reloadAll()
            }
            // A2
            let worthTelling = !report.booksWithMissingFiles.isEmpty || !report.untrackedFiles.isEmpty
                || !report.strandedFiles.isEmpty
            libraryCheck = worthTelling ? report : nil
        } catch {
            show(error)
        }
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
            rows = newValue.sorted(rows)
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
    public private(set) var rows: [BookRow] = []
    public internal(set) var selection: Set<Int64> = []

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
            let fetched = try await worker.rows(for: item, search: search)
            await beforeApplyingRows?(search)
            // A5: a newer reload has started (or finished) since; its answer is the one wanted.
            guard generation == rowsGeneration else { return }
            let ids = Set(fetched.map(\.id))
            // A8: showing these rows would take a book with unsaved edits out of the selection.
            if hasUnsavedChanges, !selection.isSubset(of: ids) {
                ask(about: .browse)
                return
            }
            rows = storedSort.sorted(fetched)
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
                let item = storedSidebarSelection
                let search = storedSearchText
                let fetched = try await worker.rows(for: item, search: search)
                if generation == rowsGeneration {
                    rows = storedSort.sorted(fetched)
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

    private func ask(about change: PendingChange) {
        pending = change
        storedPrompt = .unsavedChanges
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
        case nil:
            break
        }
    }

    // MARK: Activity

    /// Not nil while an operation runs: what to show beside the progress indicator.
    public internal(set) var busyLabel: String?
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
    }

    public func dismissLibraryCheck() {
        libraryCheck = nil
    }

    var storedPrompt: PendingPrompt?

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
    public internal(set) var review: ImportReview?
    /// Whether the review began as a copy, to tell a choice the user made from the setting it began with.
    @ObservationIgnored var reviewBeganCopying = false

    // MARK: Inspector

    /// What the inspector shows. Follows `selection`.
    public internal(set) var inspecting: Inspecting = .nothing

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
                if keepEdits, case .one(let old, let oldDraft) = inspecting, old.row.id == id, oldDraft.isDirty {
                    draft = oldDraft.reapplied(onto: detail.row.book)
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
                if keepEdits, case .many(let old) = inspecting, old.isDirty { draft.values = old.values }
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

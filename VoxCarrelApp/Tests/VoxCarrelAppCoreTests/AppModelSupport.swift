import DemoContent
import Foundation
import Testing
import VoxCarrelCore
import VoxCarrelFixtures

@testable import VoxCarrelAppCore

/// A `FileOpener` that opens nothing and remembers what it was asked to do.
final class RecordingOpener: FileOpener, @unchecked Sendable {
    private let lock = NSLock()
    private var openedURLs: [URL] = []
    private var revealedURLs: [[URL]] = []
    private var webURLs: [URL] = []

    var opened: [URL] { lock.withLock { openedURLs } }
    /// The web addresses it was asked to open, in order.
    var openedWeb: [URL] { lock.withLock { webURLs } }
    var revealed: [[URL]] { lock.withLock { revealedURLs } }

    func open(_ url: URL) {
        lock.withLock { openedURLs.append(url) }
    }

    func reveal(_ urls: [URL]) {
        lock.withLock { revealedURLs.append(urls) }
    }

    func openWeb(_ url: URL) {
        lock.withLock { webURLs.append(url) }
    }
}

/// A `FolderWatching` that watches nothing: a test says when something changed, with `fire()`.
@MainActor
final class FakeFolderWatcher: FolderWatching {
    /// The folders it was last asked to watch; empty when stopped or never started.
    private(set) var folders: [URL] = []
    /// How many times `watch` and `stop` have been called.
    private(set) var watchCount = 0
    private(set) var stopCount = 0
    private var onChange: (@MainActor () -> Void)?

    /// Whether `watch` has been called since the last `stop`, even with no folders.
    var isWatching: Bool { onChange != nil }

    func watch(_ folders: [URL], onChange: @escaping @MainActor () -> Void) {
        watchCount += 1
        self.folders = folders
        self.onChange = onChange
    }

    func stop() {
        stopCount += 1
        folders = []
        onChange = nil
    }

    /// Reports a change, as the file system would. Does nothing when not watching.
    func fire() {
        onChange?()
    }
}

/// A `Ticking` that never waits: scheduled actions are kept until a test runs them.
@MainActor
final class FakeTicker: Ticking {
    struct Entry {
        /// The delay it was scheduled with.
        var delay: TimeInterval
        fileprivate var action: @MainActor () -> Void
    }

    /// The actions scheduled and neither run nor cancelled, in the order they were scheduled.
    private(set) var pending: [Entry] = []
    /// How many times `cancelAll` has been called.
    private(set) var cancelCount = 0

    func schedule(after seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) {
        pending.append(Entry(delay: seconds, action: action))
    }

    func cancelAll() {
        cancelCount += 1
        pending = []
    }

    /// Runs the pending action with the shortest delay (the earliest scheduled, if several
    /// share it), as if its time had come. Returns false when nothing is pending.
    @discardableResult
    func runNext() -> Bool {
        guard let shortest = pending.map(\.delay).min() else { return false }
        return run(delay: shortest)
    }

    /// Runs the earliest scheduled pending action with exactly this delay, leaving the
    /// others pending. Returns false when there is none.
    @discardableResult
    func run(delay: TimeInterval) -> Bool {
        guard let index = pending.firstIndex(where: { $0.delay == delay }) else { return false }
        pending.remove(at: index).action()
        return true
    }
}

/// The time as a model's inbox is told it: it moves only when a test moves it.
@MainActor
final class FakeClock {
    var now = Date(timeIntervalSinceReferenceDate: 800_000_000)
}

/// Holds whoever calls `wait()` until `release()`, and lets a test wait for them to arrive.
actor Gate {
    private var isOpen = false
    private var hasArrival = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var watching: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        hasArrival = true
        watching.forEach { $0.resume() }
        watching = []
        if isOpen { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    /// Returns once something is (or has been) held at the gate.
    func arrival() async {
        if hasArrival { return }
        await withCheckedContinuation { watching.append($0) }
    }

    func release() {
        isOpen = true
        waiting.forEach { $0.resume() }
        waiting = []
    }
}

/// An `AppModel` with throwaway preferences of its own (never `.standard`), a recording opener and,
/// usually, a temporary demo library.
@MainActor
final class Harness {
    let root: URL
    let defaults: UserDefaults
    let opener = RecordingOpener()
    /// What the model looks books up in, in place of the network.
    let lookup: FakeLookup
    /// What the model watches its watch folders with: nothing is reported until a test fires it.
    let watcher = FakeFolderWatcher()
    /// What the model schedules its later inbox checks with: none runs until a test runs it.
    let ticker = FakeTicker()
    /// The time the model's inbox checks are told it is.
    let clock = FakeClock()
    let model: AppModel

    /// `root` is stored as the library folder unless `choose` is false.
    init(root: URL, choose: Bool = true) throws {
        self.root = root
        // A suite named by a path keeps its file there, in a temporary folder, and puts
        // nothing in the user's Preferences folder.
        let suite = try makeTempDir().appendingPathComponent("preferences").path
        defaults = try #require(UserDefaults(suiteName: suite))
        let location = LibraryLocation(defaults: defaults)
        if choose { location.url = root }
        let lookup = FakeLookup()
        self.lookup = lookup
        let clock = clock
        model = AppModel(
            location: location, opener: opener, defaults: defaults, lookupService: lookup.service(for:),
            watcher: watcher, ticker: ticker, inboxNow: { clock.now })
        model.lookupLanguage = "en"
    }

    /// What Undo would reverse in a demo library nothing has been done to yet.
    static let demoUndoLabel = "Edit 7 books"

    /// The demo library, built once. Building it encodes audio, which is slow when many
    /// tests do it at the same moment; each test works on a copy of its own.
    private static let template = Result { () throws -> URL in
        let folder = try makeTempDir()
        try DemoContent.makeLibrary(at: folder, audible: false)
        return folder
    }

    /// A started model on a demo library of its own: 12 books, one needing attention,
    /// two collections.
    ///
    /// The library is a copy of one built earlier; `fresh` builds it in place instead.
    /// Either way the last thing done to it, which Undo would reverse, is `demoUndoLabel`.
    static func demo(start: Bool = true, fresh: Bool = false) async throws -> Harness {
        let root = try makeTempDir()
        if fresh {
            try DemoContent.makeLibrary(at: root, audible: false)
        } else {
            try FileManager.default.removeItem(at: root)
            try FileManager.default.copyItem(at: try template.get(), to: root)
        }
        let harness = try Harness(root: root)
        if start { await harness.model.start() }
        return harness
    }

    /// A started model on a new, empty library.
    static func empty() async throws -> Harness {
        let harness = try Harness(root: try makeTempDir())
        await harness.model.start()
        return harness
    }

    private static let inboxTemplate = Result { () throws -> URL in
        let folder = try makeTempDir()
        try DemoContent.makeInbox(at: folder)
        return folder
    }

    /// A folder of loose sample files of this test's own, not yet imported: the demo inbox.
    static func inbox() throws -> URL {
        let folder = try makeTempDir()
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.copyItem(at: try inboxTemplate.get(), to: folder)
        return folder
    }

    /// A second model over the same preferences, as after quitting and reopening the app.
    /// It watches nothing for real, and its later checks never run, unless a test gives
    /// it a watcher and a ticker to drive.
    func relaunched(watcher: FakeFolderWatcher? = nil, ticker: FakeTicker? = nil) -> AppModel {
        let clock = clock
        return AppModel(
            location: LibraryLocation(defaults: defaults), opener: opener, defaults: defaults,
            lookupService: lookup.service(for:),
            watcher: watcher ?? FakeFolderWatcher(), ticker: ticker ?? FakeTicker(), inboxNow: { clock.now })
    }

    // MARK: Looking at the library directly

    /// A second connection to the catalogue, for setting up and for checking.
    func store() throws -> LibraryStore {
        try LibraryStore(libraryRoot: root)
    }

    func id(_ title: String) throws -> Int64 {
        let book = try #require(try store().books().first { $0.title == title }, "no book titled \(title)")
        return try #require(book.id)
    }

    func ids(_ titles: [String]) throws -> Set<Int64> {
        Set(try titles.map { try id($0) })
    }

    func book(_ id: Int64) throws -> Book {
        try #require(try store().book(id: id))
    }

    func fileURLs(_ id: Int64) throws -> [URL] {
        let store = try store()
        return try store.files(bookId: id).map { store.url(for: $0) }
    }

    // MARK: Driving the model

    /// Clicks the book and waits for the inspector to catch up.
    @discardableResult
    func select(_ title: String) async throws -> Int64 {
        let id = try id(title)
        model.click(id, modifiers: [])
        await model.settle()
        return id
    }

    @discardableResult
    func select(_ titles: [String]) async throws -> Set<Int64> {
        let ids = try ids(titles)
        model.select(ids)
        await model.settle()
        return ids
    }

    /// Selects the book and types a new title into its draft, without saving.
    @discardableResult
    func edit(_ title: String, newTitle: String) async throws -> Int64 {
        let id = try await select(title)
        model.updateDraft { $0.title = newTitle }
        return id
    }

    var detail: BookDetail? {
        if case .one(let detail, _) = model.inspecting { return detail }
        return nil
    }

    var draft: BookDraft? {
        if case .one(_, let draft) = model.inspecting { return draft }
        return nil
    }

    var bulkDraft: BulkDraft? {
        if case .many(let draft) = model.inspecting { return draft }
        return nil
    }

    var titles: [String] { model.rows.map(\.book.title) }

    // MARK: Watching operations

    /// The `busyLabel` of each operation that ran since `recordBusyLabels()`, in order.
    private(set) var busyLabels: [String] = []

    func recordBusyLabels() {
        model.beforeOperation = { [weak self] in await self?.noteBusyLabel() }
    }

    private func noteBusyLabel() {
        busyLabels.append(model.busyLabel ?? "")
    }
}

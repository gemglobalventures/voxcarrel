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

    var opened: [URL] { lock.withLock { openedURLs } }
    var revealed: [[URL]] { lock.withLock { revealedURLs } }

    func open(_ url: URL) {
        lock.withLock { openedURLs.append(url) }
    }

    func reveal(_ urls: [URL]) {
        lock.withLock { revealedURLs.append(urls) }
    }
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

/// An `AppModel` with preferences of its own (never `.standard`), a recording opener and,
/// usually, a temporary demo library.
@MainActor
final class Harness {
    let root: URL
    let defaults: UserDefaults
    let opener = RecordingOpener()
    let model: AppModel
    private let suiteName: String

    /// `root` is stored as the library folder unless `choose` is false.
    init(root: URL, choose: Bool = true) throws {
        self.root = root
        suiteName = "voxcarrel-tests-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        let location = LibraryLocation(defaults: defaults)
        if choose { location.url = root }
        model = AppModel(location: location, opener: opener, defaults: defaults)
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }

    /// The demo library, built once. Building it encodes audio, which is slow when many
    /// tests do it at the same moment; each test works on a copy of its own.
    private static let template = Result { () throws -> URL in
        let folder = try makeTempDir()
        try DemoContent.makeLibrary(at: folder)
        return folder
    }

    /// A started model on a demo library of its own: 12 books, one needing attention,
    /// two collections.
    ///
    /// The library is a copy of one built earlier, so the operations that built it cannot
    /// be undone here (the engine does not undo into another folder) and `undoLabel`
    /// starts as nil. `fresh` builds the library in place instead.
    static func demo(start: Bool = true, fresh: Bool = false) async throws -> Harness {
        let root = try makeTempDir()
        if fresh {
            try DemoContent.makeLibrary(at: root)
        } else {
            try FileManager.default.removeItem(at: root)
            try FileManager.default.copyItem(at: try template.get(), to: root)
        }
        let harness = try Harness(root: root)
        if start { await harness.model.start() }
        return harness
    }

    /// A second model over the same preferences, as after quitting and reopening the app.
    func relaunched() -> AppModel {
        AppModel(location: LibraryLocation(defaults: defaults), opener: opener, defaults: defaults)
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
}

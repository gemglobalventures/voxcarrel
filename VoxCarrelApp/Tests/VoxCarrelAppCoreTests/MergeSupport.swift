import Foundation
import Testing
import VoxCarrelCore
import VoxCarrelFixtures

@testable import VoxCarrelAppCore

/// A library of a test's own, built book by book before a model opens it.
final class MergeLibrary {
    let root: URL
    private let inbox: URL
    private let service: LibraryService

    init() throws {
        root = try makeTempDir()
        inbox = try makeTempDir()
        service = LibraryService(store: try LibraryStore(libraryRoot: root))
    }

    static let author = "James Dalton"
    static let title = "Mind Over Markets"
    static let folder = "James Dalton/Mind Over Markets"
    static let audioFolder = "James Dalton/Mind Over Markets (Unabridged)"
    static let companion = "Mind Over Markets [B09WXN61GL]"

    private func add(_ file: URL, _ title: String, _ author: String?) throws -> Int64 {
        let role = FileFormat(url: file)?.defaultRole ?? .extra
        let candidate = CandidateBook(
            files: [CandidateFile(url: file, role: role)],
            metadata: BookMetadata(title: title, authors: author.map { [$0] } ?? []))
        let result = try service.importItems([ImportItem(candidate: candidate)], options: ImportOptions(mode: .move))
        switch try #require(result.outcomes.first) {
        case .imported(let id, _), .needsAttention(let id): return id
        case .failed(let reason): throw Failure(reason: reason)
        }
    }

    struct Failure: Error { var reason: String }

    /// A one-file audiobook.
    func audiobook(_ title: String, _ author: String? = MergeLibrary.author) throws -> Int64 {
        let url = inbox.appendingPathComponent("\(UUID().uuidString).m4b")
        try MediaFixtures.makeAAC(at: url, seconds: 1)
        return try add(url, title, author)
    }

    func pdf(_ title: String, _ author: String? = MergeLibrary.author) throws -> Int64 {
        let url = inbox.appendingPathComponent("\(UUID().uuidString).pdf")
        MediaFixtures.makePDF(at: url, pages: 2)
        return try add(url, title, author)
    }

    func epub(_ title: String, _ author: String? = MergeLibrary.author) throws -> Int64 {
        let name = "\(UUID().uuidString).epub"
        return try add(try MediaFixtures.makeEPUB3(in: inbox, name: name), title, author)
    }

    /// Saves another title for the book, as the inspector would.
    func retitle(_ id: Int64, to title: String) throws {
        var edit = BookEdit(book: try #require(try service.store.book(id: id)))
        edit.metadata.title = title
        _ = try service.save([edit])
    }

    /// The owner's case. `audio`: an audiobook titled "Mind Over Markets", its folder still
    /// "…/Mind Over Markets (Unabridged)", flagged because the folder it belongs in is
    /// `pdf`'s. `pdf`: a PDF "Mind Over Markets". `companion`: a PDF whose name holds
    /// "[B09WXN61GL]".
    func ownersCase() throws -> (audio: Int64, pdf: Int64, companion: Int64) {
        let audio = try audiobook("\(Self.title) (Unabridged)")
        let pdf = try pdf(Self.title)
        let companion = try self.pdf(Self.companion)
        try retitle(audio, to: Self.title)
        return (audio, pdf, companion)
    }
}

extension Harness {
    /// A started model on a library built by `build`, with what it returned.
    static func merging<Books>(_ build: (MergeLibrary) throws -> Books) async throws -> (h: Harness, books: Books) {
        let library = try MergeLibrary()
        let books = try build(library)
        let harness = try Harness(root: library.root)
        await harness.model.start()
        return (harness, books)
    }

    /// Selects these books and waits for the inspector to catch up.
    func select(ids: Set<Int64>) async {
        model.select(ids)
        await model.settle()
    }

    /// Every file in the library folder, by its path there, but for the catalogue and
    /// VoxCarrel's hidden folder.
    func libraryFiles() -> [String] {
        let fm = FileManager.default
        let base = root.resolvingSymlinksInPath().path
        var paths: [String] = []
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let path = String(url.resolvingSymlinksInPath().path.dropFirst(base.count + 1))
            if path.hasPrefix(".") || path.hasPrefix(LibraryStore.databaseFileName) { continue }
            paths.append(path)
        }
        return paths.sorted()
    }
}

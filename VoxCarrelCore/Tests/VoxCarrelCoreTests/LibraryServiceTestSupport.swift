import CTagBridge
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import VoxCarrelCore

/// A temp folder holding a library and an inbox of real generated files, with a service on the library.
final class LibraryFixture {
    let base: URL
    /// The library folder.
    let root: URL
    /// Where files wait to be imported.
    let inbox: URL
    let store: LibraryStore
    let service: LibraryService
    let io = FileMetadataIO()

    init(organiser: Organiser = Organiser()) throws {
        base = try makeTempDir()
        root = base.appendingPathComponent("Library", isDirectory: true)
        inbox = base.appendingPathComponent("Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        store = try LibraryStore(libraryRoot: root)
        service = LibraryService(store: store, metadataIO: FileMetadataIO(), organiser: organiser)
    }

    // MARK: Metadata

    static func meta(_ title: String, _ author: String) -> BookMetadata {
        BookMetadata(title: title, authors: [author])
    }

    /// Reviewed metadata with every field an audio file can hold.
    static func fullMeta(_ title: String, _ author: String) -> BookMetadata {
        var m = BookMetadata(title: title, authors: [author])
        m.subtitle = "A Novel"
        m.narrators = ["Ray Porter"]
        m.series = "The Series"
        m.seriesNumber = "2"
        m.genre = "Science Fiction"
        m.year = 2021
        m.publisher = "Audible Studios"
        m.summary = "What it is about."
        m.language = "en"
        m.isbn = "9780593135204"
        m.asin = "B08G9PRS1K"
        return m
    }

    static let jpeg = CoverImage(data: MediaFixtures.makeImage(.jpeg), mime: "image/jpeg")
    static let png = CoverImage(data: MediaFixtures.makeImage(.png), mime: "image/png")

    // MARK: Files in the inbox

    private func inboxURL(_ name: String) throws -> URL {
        let url = inbox.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return url
    }

    /// A real M4B (or M4A, by the name's extension) carrying `tags`, and a cover when given.
    func makeM4B(_ name: String, tags: BookMetadata, cover: CoverImage? = nil, seconds: Double = 1) throws -> URL {
        let url = try inboxURL(name)
        try MediaFixtures.makeAAC(at: url, seconds: seconds)
        try io.write(tags, cover: cover.map { .set($0) } ?? .keep, to: url)
        return url
    }

    /// A real MP3 carrying `tags` (track title equal to the book title, no track number).
    func makeMP3(_ name: String, tags: BookMetadata, seconds: Double = 1) throws -> URL {
        let url = try inboxURL(name)
        try MediaFixtures.makeSilentMP3(seconds: seconds).write(to: url)
        try io.write(tags, to: url)
        return url
    }

    /// A folder of MP3 parts, each tagged with `tags`, named `part1.mp3`, `part2.mp3`…
    func makeMP3Parts(folder: String, tags: BookMetadata, count: Int = 2, seconds: Double = 1) throws -> [URL] {
        try (1...count).map { try makeMP3("\(folder)/part\($0).mp3", tags: tags, seconds: seconds) }
    }

    /// The EPUB 3 fixture: "Original Title" by "First Author", with a JPEG cover.
    func makeEPUB(_ name: String) throws -> URL {
        let url = try inboxURL(name)
        return try MediaFixtures.makeEPUB3(in: url.deletingLastPathComponent(), name: url.lastPathComponent)
    }

    /// The PDF fixture: "Original Title" by "Original Author".
    func makePDF(_ name: String, pages: Int = 3) throws -> URL {
        let url = try inboxURL(name)
        MediaFixtures.makePDF(at: url, pages: pages)
        return url
    }

    /// A candidate over `urls`, each with its format's default role unless `roles` says otherwise.
    func candidate(_ urls: [URL], _ metadata: BookMetadata, roles: [URL: FileRole] = [:]) -> CandidateBook {
        CandidateBook(
            files: urls.map {
                CandidateFile(url: $0, role: roles[$0] ?? FileFormat(url: $0)?.defaultRole ?? .extra)
            },
            metadata: metadata)
    }

    // MARK: Looking at the result

    func lib(_ path: String) -> URL {
        root.appendingPathComponent(path)
    }

    /// Everything in the library folder except the database and VoxCarrel's hidden folder.
    func libraryTree() -> [String] {
        tree(root).filter {
            !$0.hasPrefix(LibraryStore.databaseFileName) && !$0.hasPrefix(".voxcarrel")
        }
    }

    /// Everything inside the hidden folder, relative to it.
    func hiddenTree() -> [String] {
        tree(service.layout.hiddenFolder)
    }

    func inboxTree() -> [String] {
        tree(inbox)
    }

    func bytes(_ url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    /// The descriptive tags inside a file, without the facts about the file itself.
    func tags(_ url: URL) throws -> BookMetadata {
        var m = try io.read(url).metadata
        m.durationSeconds = nil
        m.pageCount = nil
        return m
    }

    /// The raw track number tag ("1/2") of an MP3 or MP4 audio file, or nil.
    func track(_ url: URL) throws -> String? {
        if url.pathExtension.lowercased() == "mp3" {
            return try CTBTagFile.readMP3(atPath: url.path).items["TRCK"]?.first
        }
        return try CTBTagFile.readMP4(atPath: url.path).items["trkn"]?.first
    }

    /// The raw track title of an MP3.
    func trackTitle(_ url: URL) throws -> String? {
        try CTBTagFile.readMP3(atPath: url.path).items["TIT2"]?.first
    }

    func snapshot() throws -> OperationSnapshot {
        let batch = try #require(try store.lastBatch())
        let data = try #require(batch.snapshot)
        return try JSONDecoder().decode(OperationSnapshot.self, from: data)
    }

    /// The id of an `.imported` outcome with no file problems.
    func importedId(_ outcome: ImportOutcome, sourceLocation: SourceLocation = #_sourceLocation) throws -> Int64 {
        guard case .imported(let id, let problems) = outcome else {
            Issue.record("expected .imported, got \(outcome)", sourceLocation: sourceLocation)
            throw FixtureError.unexpectedOutcome
        }
        #expect(problems.isEmpty, sourceLocation: sourceLocation)
        return id
    }

    /// Imports one new book and returns its id.
    func importNew(
        _ urls: [URL], _ metadata: BookMetadata, cover: CoverChange = .keep, mode: TransferMode = .move
    ) throws -> Int64 {
        let result = try service.importItems(
            [ImportItem(candidate: candidate(urls, metadata), cover: cover)],
            options: ImportOptions(mode: mode))
        return try importedId(try #require(result.outcomes.first))
    }

    enum FixtureError: Error { case unexpectedOutcome }
}

/// An error for tests to throw.
struct Boom: Error, Equatable {}

func isFailed(_ outcome: ImportOutcome) -> String? {
    if case .failed(let reason) = outcome { return reason }
    return nil
}

import DemoContent
import Foundation
import Testing
import VoxCarrelFixtures

@testable import VoxCarrelAppCore
@testable import VoxCarrelCore

/// The app files by the library's folder pattern (folder layout plan, Task 2): the
/// review's marker and text, the folders it shows, the inspector's reason, the demo tools.
@MainActor
@Suite struct FolderLayoutFilingTests {
    static let kindPattern = "{Kind}/{Author}/{Title}"
    static let narratorPattern = "{Narrator}/{Title}"

    private func entry(_ h: Harness, _ title: String) throws -> ImportReview.Entry {
        try #require(h.model.review?.entries.first { $0.candidate.metadata.title == title }, "no entry titled \(title)")
    }

    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/inbox/\(name)") }

    private func seed(_ title: String, author: String? = "Ann Author", narrator: String? = nil, files: [String]) -> ImportSeed {
        var metadata = BookMetadata(title: title, authors: author.map { [$0] } ?? [])
        metadata.narrators = narrator.map { [$0] } ?? []
        return ImportSeed(
            candidate: CandidateBook(
                files: files.map { CandidateFile(url: url($0), role: FileFormat(url: url($0))?.defaultRole ?? .extra) },
                metadata: metadata),
            cover: nil, existingMatch: nil)
    }

    // MARK: FP20 The review, as a plain value

    @Test func fp20_aReviewFilesByTheStandardPatternUnlessToldOtherwise() {
        let review = ImportReview(seeds: [seed("Atlas", files: ["a.m4b"])], skipped: [], copyInsteadOfMove: false)
        #expect(review.folderPattern == .standard)
    }

    @Test func fp20_theWillNeedAttentionMarkerGoesByTheReviewsPattern() throws {
        var review = ImportReview(
            seeds: [
                seed("Atlas", files: ["a.m4b"]),
                seed("Rivers", narrator: "Nan Reader", files: ["r.m4b"]),
                seed("Beowulf", author: nil, narrator: "Seamus Heaney", files: ["b.m4b"]),
                seed("", author: nil, files: ["x.m4b"]),
            ], skipped: [], copyInsteadOfMove: false)
        let ids = review.entries.map(\.id)
        // The standard pattern asks for a title and an author.
        #expect(ids.map { review.readiness(of: $0) } == [.ready, .ready, .willNeedAttention, .willNeedAttention])
        #expect(review.status(of: ids[2])?.text == "Needs attention: no author")
        #expect(review.status(of: ids[3])?.text == "Needs attention: no title or author")
        #expect(review.destinationText(of: ids[3]) == "Will stay where it is until it has a title and an author")

        review.folderPattern = try FolderPattern(Self.narratorPattern)
        #expect(ids.map { review.readiness(of: $0) } == [.willNeedAttention, .ready, .ready, .willNeedAttention])
        #expect(review.status(of: ids[0])?.text == "Needs attention: no narrator")
        #expect(review.status(of: ids[0])?.isBlocking == false)
        #expect(review.destinationText(of: ids[0]) == "Will stay where it is until it has a narrator")
        #expect(review.status(of: ids[3])?.text == "Needs attention: no title or narrator")
        #expect(review.destinationText(of: ids[3]) == "Will stay where it is until it has a title and a narrator")
        #expect(review.status(of: ids[2]) == nil)
        // A book that will need attention can still be imported: it is catalogued where it is.
        #expect(review.canImport)

        review.folderPattern = try FolderPattern("{Author}/{Year}/{Narrator} - {Title}")
        #expect(review.status(of: ids[0])?.text == "Needs attention: no year or narrator")
        #expect(review.destinationText(of: ids[3]) == "Will stay where it is until it has a title, an author, a year and a narrator")
    }

    @Test func fp20_theFolderIsWorkedOutAgainWhenADetailThePatternUsesChanges() throws {
        var review = ImportReview(seeds: [seed("Atlas", files: ["a.epub"])], skipped: [], copyInsteadOfMove: false)
        let id = review.entries[0].id
        let metadata = review.entries[0].candidate.metadata
        let changes: [(inout BookMetadata) -> Void] = [
            { $0.narrators = ["Nan Reader"] }, { $0.year = 1999 }, { $0.genre = "Maps" }, { $0.publisher = "P" },
            { $0.language = "en" },
        ]

        // Under the standard pattern none of these decides the folder, nor do the files.
        review.setDestination("Ann Author/Atlas", for: id, matchingMetadata: metadata)
        #expect(review.entriesNeedingDestination.isEmpty)
        for change in changes {
            var changed = review
            change(&changed.entries[0].candidate.metadata)
            #expect(changed.entriesNeedingDestination.isEmpty)
        }
        var standardWithAudio = review
        standardWithAudio.entries[0].candidate.files.append(CandidateFile(url: url("a.m4b"), role: .audio))
        #expect(standardWithAudio.entriesNeedingDestination.isEmpty)

        // Another pattern: the folder worked out for the standard one no longer holds.
        review.folderPattern = try FolderPattern("{Kind}/{Narrator} {Year}/{Genre} {Publisher}/{Language}/{Title}")
        #expect(review.entriesNeedingDestination == [id])
        review.setDestination(nil, for: id, matchingMetadata: metadata, hasAudio: false)
        #expect(review.entriesNeedingDestination.isEmpty)
        for change in changes {
            var changed = review
            change(&changed.entries[0].candidate.metadata)
            #expect(changed.entriesNeedingDestination == [id])
        }
        // What this pattern does not name does not ask again.
        var same = review
        same.entries[0].candidate.metadata.summary = "About maps."
        same.entries[0].candidate.metadata.authors = ["Someone Else"]
        same.entries[0].candidate.metadata.series = "Charts"
        #expect(same.entriesNeedingDestination.isEmpty)

        // The files decide {Kind}: an audio file joining them asks again, and an answer
        // worked out for other files is not taken.
        var withAudio = review
        withAudio.entries[0].candidate.files.append(CandidateFile(url: url("a.m4b"), role: .audio))
        #expect(withAudio.entriesNeedingDestination == [id])
        withAudio.setDestination("Ebooks/x/Atlas", for: id, matchingMetadata: metadata, hasAudio: false)
        #expect(withAudio.entriesNeedingDestination == [id])
        withAudio.setDestination("Audiobooks/x/Atlas", for: id, matchingMetadata: metadata, hasAudio: true)
        #expect(withAudio.entriesNeedingDestination.isEmpty)
        #expect(withAudio.entries[0].destination == "Audiobooks/x/Atlas")

        // A number only counts inside its series, so the series decides the folder too.
        var numbered = ImportReview(seeds: [seed("Atlas", files: ["a.epub"])], skipped: [], copyInsteadOfMove: false)
        numbered.folderPattern = try FolderPattern("[{Number} - ]{Title}")
        numbered.setDestination("Atlas", for: numbered.entries[0].id, matchingMetadata: metadata)
        numbered.entries[0].candidate.metadata.series = "Charts"
        #expect(numbered.entriesNeedingDestination == [numbered.entries[0].id])
    }

    @Test func fp23_aBookWithNoFilesThatCannotBeFiledSaysWhatTheLayoutLacks() throws {
        var match = Book(metadata: BookMetadata(title: "Atlas", authors: ["Ann Author"]), folderPath: nil)
        match.id = 7
        match.externalCopies = [ExternalCopy(kind: .audible, form: .audio)]
        var first = seed("Atlas", files: ["a.m4b"])
        first.existingMatch = match
        var review = ImportReview(seeds: [first], skipped: [], copyInsteadOfMove: false)
        let id = review.entries[0].id
        #expect(review.entries[0].matchHasNoFiles)
        review.folderPattern = try FolderPattern(Self.narratorPattern)
        review.setMatchDestination(nil, for: id, matchedBook: match)
        #expect(review.destinationText(of: id)
            == "Cannot be added yet: “Atlas” has no narrator in the library, and neither have these files")

        // Under the standard pattern it is an author that such a book lacks.
        match.authors = []
        review.entries[0].existingMatch = match
        review.folderPattern = .standard
        review.setMatchDestination(nil, for: id, matchedBook: match)
        #expect(review.destinationText(of: id)
            == "Cannot be added yet: “Atlas” has no author in the library, and neither have these files")
    }

    // MARK: FP20 The worker and the model

    @Test func fp20_theWorkerPlansFoldersByTheLibrarysPattern() async throws {
        let root = try makeTempDir()
        let worker = try LibraryWorker(libraryRoot: root)
        #expect(try await worker.folderPattern() == .standard)
        try LibraryStore(libraryRoot: root).setFolderPatternText(Self.kindPattern)
        #expect(try await worker.folderPattern().text == Self.kindPattern)

        let metadata = BookMetadata(title: "Atlas", authors: ["Ann Author"])
        #expect(await worker.plannedFolder(for: metadata, hasAudio: true) == "Audiobooks/Ann Author/Atlas")
        #expect(await worker.plannedFolder(for: metadata, hasAudio: false) == "Ebooks/Ann Author/Atlas")
    }

    @Test func fp20_theImportSheetShowsAndImportsToTheFoldersOfTheLibrarysPattern() async throws {
        let h = try await Harness.empty()
        try h.store().setFolderPatternText(Self.kindPattern)
        let inbox = try Harness.inbox()

        await h.model.beginImport([inbox])
        let review = try #require(h.model.review)
        #expect(review.folderPattern.text == Self.kindPattern)
        #expect(review.entriesNeedingDestination.isEmpty)

        let rivers = try entry(h, "Quiet Rivers")
        let riversAuthor = try #require(rivers.candidate.metadata.authors.first)
        #expect(rivers.destination == "Ebooks/\(riversAuthor)/Quiet Rivers")
        #expect(review.destinationText(of: rivers.id) == "Will be filed in: Ebooks/\(riversAuthor)/Quiet Rivers")

        let keeper = try entry(h, "The Lighthouse Keeper")
        let keeperAuthor = try #require(keeper.candidate.metadata.authors.first)
        #expect(keeper.destination == "Audiobooks/\(keeperAuthor)/The Lighthouse Keeper")
        // An audiobook that comes with its ebook is one book, under Audiobooks.
        let pair = try entry(h, "The Clockmaker's Apprentice")
        #expect(pair.destination?.hasPrefix("Audiobooks/") == true)
        // No author: as under the standard pattern, it will need attention.
        let attic = try entry(h, "Voices from the Attic")
        #expect(review.readiness(of: attic.id) == .willNeedAttention)
        #expect(attic.destination == nil)

        let expected = Dictionary(
            uniqueKeysWithValues: review.entries.map { ($0.candidate.metadata.title, $0.destination) })
        await h.model.confirmImport()
        #expect(h.model.alert == nil)
        for book in try h.store().books() {
            #expect(book.folderPath == expected[book.title] ?? nil, "\(book.title)")
        }
        #expect(try h.book(try h.id("Quiet Rivers")).folderPath == "Ebooks/\(riversAuthor)/Quiet Rivers")
    }

    @Test func fp23_theImportSheetMarksABookThePatternCannotFile() async throws {
        let h = try await Harness.empty()
        try h.store().setFolderPatternText(Self.narratorPattern)
        let inbox = try Harness.inbox()

        await h.model.beginImport([inbox.appendingPathComponent("Quiet Rivers.epub")])
        var review = try #require(h.model.review)
        let id = try entry(h, "Quiet Rivers").id
        #expect(review.readiness(of: id) == .willNeedAttention)
        #expect(review.status(of: id)?.text == "Needs attention: no narrator")
        #expect(review.destinationText(of: id) == "Will stay where it is until it has a narrator")
        #expect(try entry(h, "Quiet Rivers").destination == nil)

        // Given a narrator in the review, it is ready and its folder follows.
        h.model.updateReview { $0.entries[0].candidate.metadata.narrators = ["Nan Reader"] }
        await h.model.settle()
        review = try #require(h.model.review)
        #expect(review.readiness(of: id) == .ready)
        #expect(review.destinationText(of: id) == "Will be filed in: Nan Reader/Quiet Rivers")
    }

    // MARK: FP23 The inspector's reason

    @Test func fp23_theInspectorSaysWhatTheLayoutNeeds() async throws {
        let h = try await Harness.empty()
        try h.store().setFolderPatternText(Self.narratorPattern)
        let inbox = try Harness.inbox()
        await h.model.beginImport([inbox.appendingPathComponent("Quiet Rivers.epub")])
        await h.model.confirmImport()

        try await h.select("Quiet Rivers")
        #expect(try h.book(try h.id("Quiet Rivers")).needsAttention)
        #expect(h.detail?.attentionReasons == ["No narrator, which the folder layout needs."])
    }

    @Test func fp23_theInspectorsReasonsFromWhatTheWorkerFound() {
        var book = Book(metadata: BookMetadata(title: "Atlas"), folderPath: nil, needsAttention: true)
        book.id = 1
        let row = BookRow(
            id: 1, book: book, hasAudio: true, hasEbook: false, formats: [], coverURL: nil, hasWriteProblem: false)
        var file = BookFile(path: "/elsewhere/atlas.m4b", format: .m4b, role: .audio, position: 0)
        file.id = 1
        let url = URL(fileURLWithPath: "/elsewhere/atlas.m4b")
        let files = [FileRow(id: 1, file: file, url: url, name: "atlas.m4b", isMissing: false, allowedRoles: [.audio])]
        func reasons(_ missing: [FolderToken]?) -> [String] {
            var detail = BookDetail(row: row, files: files, chapterCount: 0, collectionIds: [])
            detail.missingForFiling = missing
            return detail.attentionReasons
        }
        // Not told what the layout lacks: as before, a flagged book with no author needs one.
        #expect(reasons(nil) == ["Add an author to file this book"])
        #expect(reasons([.author]) == ["Add an author to file this book"])
        #expect(reasons([.author, .narrator]) == ["Add an author to file this book", "No narrator, which the folder layout needs."])
        #expect(reasons([.narrator, .year]) == ["No narrator or year, which the folder layout needs."])
        // The layout does not ask for an author, so none is asked for.
        #expect(reasons([]) == [])
    }

    // MARK: FP25 The demo tools

    @Test func fp25_theDemoLibraryIsFiledByTheStandardPattern() throws {
        let root = try makeTempDir()
        try DemoContent.makeLibrary(at: root, count: 40, audible: false)
        let store = try LibraryStore(libraryRoot: root)
        #expect(try store.folderPatternText() == nil)
        #expect(try LibraryService(store: store).folderPattern() == .standard)
        var filed = 0
        for book in try store.books() {
            let files = try store.files(bookId: try #require(book.id))
            guard let folder = book.folderPath else { continue }
            filed += 1
            let values = FolderPatternValues(metadata: book.metadata, hasAudio: files.contains { $0.role == .audio })
            #expect(folder == FolderPattern.standard.folder(for: values), "\(book.title)")
            #expect(files.allSatisfy { $0.path.hasPrefix(folder + "/") }, "\(book.title)")
        }
        #expect(filed >= 39)
    }
}

import Foundation
import Testing
@testable import VoxCarrelCore
import VoxCarrelFixtures

/// DF1–DF12: the details file (`metadata.opf`) kept beside each filed book.
@Suite struct DetailsFileTests {
    typealias F = LibraryFixture

    private func imported(_ f: F, _ title: String = "The Long Road", _ author: String = "Ann Author") throws -> Int64 {
        let tags = F.fullMeta(title, author)
        let file = try f.makeM4B("\(title).m4b", tags: tags)
        let result = try f.service.importItems([ImportItem(candidate: f.candidate([file], tags))])
        return try f.importedId(result.outcomes[0])
    }

    private func detailsFile(_ f: F, _ id: Int64) throws -> URL {
        let book = try #require(try f.store.book(id: id))
        return f.store.url(forFolder: try #require(book.folderPath)).appendingPathComponent("metadata.opf")
    }

    private func opfs(_ f: F) -> [String] {
        treeWithDetailsFiles(f.root).filter { $0.hasSuffix("metadata.opf") }
    }

    // DF1: an imported book has its details beside it, and they read back as the book's.
    @Test func DF1_anImportedBookHasItsDetailsBesideIt() throws {
        let f = try F()
        let id = try imported(f)
        let file = try detailsFile(f, id)
        let book = try #require(try f.store.book(id: id))
        let read = try #require(Sidecar.details(at: file))
        #expect(read.title == book.title && read.authors == book.authors)
        #expect(read.series == book.series && read.publisher == book.publisher && read.year == book.year)
        #expect(read.isbn == book.isbn && read.asin == book.asin && read.language == book.language)
        #expect(DetailsFile.isOurs(at: file))
        // A document any XML reader takes.
        _ = try XMLDocument(contentsOf: file)
    }

    // DF2: the text is the book's alone: the same book gives the same bytes, and says
    // everything another library manager reads.
    @Test func DF2_theTextSaysWhatTheBookIs() throws {
        var book = Book(metadata: F.fullMeta("Tom & Jerry <at \"sea\">", "Ursula K. Le Guin"), dateAdded: Date(timeIntervalSince1970: 1_700_000_000))
        book.id = 7
        book.narrators = ["Ned Reader"]
        book.series = "Sea Tales"
        book.seriesNumber = "2.5"
        book.genres = ["Fantasy", "Sea Stories"]
        book.tags = ["fantasy", "to lend"]
        book.rating = 4
        book.subtitle = "A Tale"
        let text = DetailsFile.text(for: book)
        #expect(text == DetailsFile.text(for: book))
        #expect(text.contains("<dc:title>Tom &amp; Jerry &lt;at &quot;sea&quot;&gt;</dc:title>"))
        #expect(text.contains("opf:role=\"aut\" opf:file-as=\"Guin, Ursula K. Le\">Ursula K. Le Guin</dc:creator>"))
        #expect(text.contains("<dc:contributor opf:role=\"nrt\">Ned Reader</dc:contributor>"))
        #expect(text.contains("<meta name=\"calibre:series\" content=\"Sea Tales\"/>"))
        #expect(text.contains("<meta name=\"calibre:series_index\" content=\"2.5\"/>"))
        #expect(text.contains("<meta name=\"calibre:rating\" content=\"8\"/>"))
        #expect(text.contains("<meta name=\"voxcarrel:subtitle\" content=\"A Tale\"/>"))
        // A genre and a tag of one name are one subject.
        #expect(text.components(separatedBy: "<dc:subject>").count - 1 == 3)
        #expect(!text.contains("<guide>"))
        #expect(DetailsFile.text(for: book, hasCoverBeside: true).contains("href=\"cover.jpg\""))
        let document = try XMLDocument(xmlString: text)
        #expect(document.rootElement()?.name == "package")
        // A series number that is no number is kept, but not passed off as an index.
        book.seriesNumber = "1-3"
        let odd = DetailsFile.text(for: book)
        #expect(!odd.contains("calibre:series_index") && odd.contains("voxcarrel:series_number\" content=\"1-3\""))
    }

    // DF3: an edit is in the file as soon as it is saved, and undoing it takes it out again.
    @Test func DF3_anEditIsWrittenAndUndoneInTheFile() throws {
        let f = try F()
        let id = try imported(f)
        let before = try Data(contentsOf: try detailsFile(f, id))
        var edit = BookEdit(book: try #require(try f.store.book(id: id)))
        edit.rating = 5
        edit.tags = ["to lend"]
        _ = try f.service.save([edit])
        let text = try read(try detailsFile(f, id))
        #expect(text.contains("calibre:rating\" content=\"10\"") && text.contains("<dc:subject>to lend</dc:subject>"))
        try f.service.undoLast()
        #expect(try Data(contentsOf: try detailsFile(f, id)) == before)
    }

    // DF4: a book that moves to another folder takes its details file with it: none is
    // left behind, and no folder is left standing for one.
    @Test func DF4_aRefiledBookLeavesNoDetailsFileBehind() throws {
        let f = try F()
        let id = try imported(f)
        let old = try detailsFile(f, id)
        var edit = BookEdit(book: try #require(try f.store.book(id: id)))
        edit.metadata.title = "The Short Road"
        #expect(try f.service.save([edit]) == [.saved(bookId: id, refiled: true, appOnlyFields: [], fileProblems: [])])
        let new = try detailsFile(f, id)
        #expect(new != old && opfs(f).count == 1)
        #expect(!FileManager.default.fileExists(atPath: old.deletingLastPathComponent().path))
        #expect(try read(new).contains("<dc:title>The Short Road</dc:title>"))
        // And back again.
        try f.service.undoLast()
        #expect(opfs(f).count == 1 && FileManager.default.fileExists(atPath: old.path))
        #expect(try read(old).contains("<dc:title>The Long Road</dc:title>"))
    }

    // DF5: a details file that was not written here is never overwritten or removed.
    @Test func DF5_someoneElsesDetailsFileIsLeftAlone() throws {
        let f = try F()
        let id = try imported(f)
        let file = try detailsFile(f, id)
        let theirs = Data("<package><metadata><title>Theirs</title></metadata></package>".utf8)
        try theirs.write(to: file)
        var edit = BookEdit(book: try #require(try f.store.book(id: id)))
        edit.rating = 3
        _ = try f.service.save([edit])
        #expect(f.service.refreshDetailsFiles() == 0)
        #expect(try Data(contentsOf: file) == theirs)
        // Nor does it go when the book does.
        try f.service.removeBook(id: id, moveFilesToTrash: false)
        #expect(try Data(contentsOf: file) == theirs)
    }

    // DF6: removing a book takes its details file, with or without its files.
    @Test func DF6_aRemovedBooksDetailsFileGoesWithIt() throws {
        let f = try F()
        let kept = try imported(f, "Kept")
        let gone = try imported(f, "Gone", "Bea Writer")
        let goneFile = try detailsFile(f, gone)
        try f.service.removeBook(id: gone, moveFilesToTrash: false)
        #expect(!FileManager.default.fileExists(atPath: goneFile.path))
        // The book's file is still there, untracked, as before.
        #expect(FileManager.default.fileExists(atPath: goneFile.deletingLastPathComponent().path))

        let keptFile = try detailsFile(f, kept)
        f.service.trashItem = { try FileManager.default.removeItem(at: $0) }
        try f.service.removeBook(id: kept, moveFilesToTrash: true)
        #expect(!FileManager.default.fileExists(atPath: keptFile.deletingLastPathComponent().path))
        #expect(opfs(f).isEmpty)
    }

    // DF7: the launch check writes what is missing or stale, and nothing when all is right.
    @Test func DF7_theLaunchCheckPutsDetailsFilesRight() throws {
        let f = try F()
        let id = try imported(f)
        let file = try detailsFile(f, id)
        let right = try Data(contentsOf: file)
        try FileManager.default.removeItem(at: file)
        _ = try f.service.reconcile()
        #expect(try Data(contentsOf: file) == right)
        // Changed behind the service's back: a rating set straight in the catalogue.
        _ = try f.store.modifyBook(id: id) { book, _ in book.rating = 2 }
        _ = try f.service.reconcile()
        #expect(try read(file).contains("calibre:rating\" content=\"4\""))
        let stamp = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        #expect(f.service.refreshDetailsFiles() == 0)
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date == stamp)
    }

    // DF8: books with no folder of their own have none: a book owned elsewhere, and
    // books that share a folder.
    @Test func DF8_booksWithoutAFolderOfTheirOwnHaveNone() throws {
        let f = try F()
        _ = try f.service.addExternalBook(
            metadata: F.meta("Owned Only", "Cy Away"), cover: nil,
            copy: ExternalCopy(kind: .audible, form: .audio, itemId: "B000000001"))
        #expect(opfs(f).isEmpty)

        let a = try imported(f, "One")
        let b = try imported(f, "Two")
        let shared = try #require(try f.store.book(id: a)?.folderPath)
        _ = try f.store.modifyBook(id: b) { book, _ in book.folderPath = shared }
        try FileManager.default.removeItem(at: try detailsFile(f, a))
        #expect(f.service.refreshDetailsFiles(ofBooks: [a, b]) == 0)
        let none = try detailsFile(f, a)
        #expect(!FileManager.default.fileExists(atPath: none.path))
    }

    // DF9: with the setting off nothing is written.
    @Test func DF9_nothingIsWrittenWhenTurnedOff() throws {
        let f = try F()
        f.service.writesDetailsFiles = false
        _ = try imported(f)
        _ = try f.service.reconcile()
        #expect(opfs(f).isEmpty)
    }

    // DF10: a change of folder layout carries each details file with its book's folder.
    @Test func DF10_aChangeOfLayoutCarriesTheDetailsFiles() throws {
        let f = try F()
        let id = try imported(f)
        let before = try Data(contentsOf: try detailsFile(f, id))
        let old = try detailsFile(f, id)
        _ = try f.service.applyLayoutChange(to: try FolderPattern("Books/{author}/{title}"))
        let new = try detailsFile(f, id)
        #expect(new != old && opfs(f).count == 1)
        #expect(try Data(contentsOf: new) == before)
    }

    // DF11: a merge leaves one details file, the kept book's, and undoing it gives each
    // book its own again.
    @Test func DF11_aMergeLeavesOneDetailsFile() throws {
        let f = try F()
        let audio = try imported(f, "Dune", "Frank Herbert")
        let tags = F.meta("Dune Ebook", "Frank Herbert")
        let ebook = try f.makeEPUB("dune.epub")
        let result = try f.service.importItems([ImportItem(candidate: f.candidate([ebook], tags))])
        let other = try f.importedId(result.outcomes[0])
        #expect(opfs(f).count == 2)
        let kept = try f.service.mergeBooks([audio, other], keep: audio, roles: [:])
        let keptFile = try detailsFile(f, kept)
        #expect(opfs(f).count == 1 && FileManager.default.fileExists(atPath: keptFile.path))
        try f.service.undoLast()
        #expect(opfs(f).count == 2)
        #expect(try read(try detailsFile(f, other)).contains("<dc:title>Dune Ebook</dc:title>"))
    }

    // DF12: renaming a genre in the library's list reaches the files of the books that have it.
    @Test func DF12_aRenamedGenreReachesTheDetailsFiles() throws {
        let f = try F()
        let id = try imported(f)
        let name = try f.service.addGenre("Road Stories", group: .fiction)
        var edit = BookEdit(book: try #require(try f.store.book(id: id)))
        edit.metadata.genres = [name]
        _ = try f.service.save([edit])
        #expect(try read(try detailsFile(f, id)).contains("<dc:subject>Road Stories</dc:subject>"))
        try f.service.renameGenre(name, to: "Road Tales")
        #expect(try read(try detailsFile(f, id)).contains("<dc:subject>Road Tales</dc:subject>"))
    }
}

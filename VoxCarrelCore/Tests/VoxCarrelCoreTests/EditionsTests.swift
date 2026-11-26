import Foundation
import Testing
@testable import VoxCarrelCore
import VoxCarrelFixtures

/// ED1–ED4: editions of one book, tied together as one work.
@Suite struct EditionsTests {
    typealias F = LibraryFixture

    private func imported(_ f: F, _ title: String, language: String? = nil, narrator: String? = nil) throws -> Int64 {
        var tags = BookMetadata(title: title, authors: ["Frank Herbert"])
        tags.language = language
        tags.narrators = narrator.map { [$0] } ?? []
        let file = try f.makeM4B("\(title).m4b", tags: tags)
        let result = try f.service.importItems([ImportItem(candidate: f.candidate([file], tags))])
        return try f.importedId(result.outcomes[0])
    }

    private func opf(_ f: F, _ id: Int64) throws -> String {
        let book = try #require(try f.store.book(id: id))
        let folder = f.store.url(forFolder: try #require(book.folderPath))
        return try String(contentsOf: folder.appendingPathComponent("metadata.opf"), encoding: .utf8)
    }

    // ED1: books are tied as editions of one work, each staying an entry of its own;
    // the details file beside each says which work; untied, the last one left is untied too.
    @Test func ED1_editionsAreTiedAndUntied() throws {
        let f = try F()
        let english = try imported(f, "Dune", language: "en", narrator: "Scott Brick")
        let german = try imported(f, "Der Wüstenplanet", language: "de")
        let other = try imported(f, "Emma")
        #expect(try f.service.otherEditions(ofBook: english).isEmpty)
        #expect(throws: EditionLinkError.needsTwoBooks) { try f.service.linkEditions([english]) }
        #expect(throws: EditionLinkError.needsTwoBooks) { try f.service.linkEditions([english, 999_999]) }

        try f.service.linkEditions([english, german])
        #expect(try f.service.otherEditions(ofBook: english).compactMap(\.id) == [german])
        #expect(try f.service.otherEditions(ofBook: german).compactMap(\.id) == [english])
        #expect(try f.service.otherEditions(ofBook: other).isEmpty)
        let key = try #require(try f.store.book(id: english)?.workKey)
        #expect(try f.store.book(id: german)?.workKey == key && f.store.book(id: other)?.workKey == nil)
        #expect(try opf(f, english).contains("<meta name=\"voxcarrel:work\" content=\"\(key)\"/>"))
        #expect(try opf(f, german).contains(key) && !opf(f, other).contains("voxcarrel:work"))
        // Each is still its own entry, in its own folder, with its own files.
        #expect(try f.store.books().count == 3 && Set(try f.store.books().compactMap(\.folderPath)).count == 3)

        try f.service.unlinkEdition(english)
        #expect(try f.store.book(id: english)?.workKey == nil && f.store.book(id: german)?.workKey == nil)
        #expect(try !opf(f, english).contains("voxcarrel:work") && !opf(f, german).contains("voxcarrel:work"))
        try f.service.unlinkEdition(other)
    }

    // ED2: tying a book to one that is already tied to others makes one work of them all.
    @Test func ED2_worksJoin() throws {
        let f = try F()
        let a = try imported(f, "Dune A")
        let b = try imported(f, "Dune B")
        let c = try imported(f, "Dune C")
        let d = try imported(f, "Dune D")
        try f.service.linkEditions([a, b])
        try f.service.linkEditions([c, d])
        try f.service.linkEditions([b, c])
        #expect(Set(try f.store.books().compactMap(\.workKey)).count == 1)
        #expect(try f.service.otherEditions(ofBook: a).compactMap(\.id).sorted() == [b, c, d])
        // One leaves: the other three are still one work.
        try f.service.unlinkEdition(d)
        #expect(try f.service.otherEditions(ofBook: a).compactMap(\.id).sorted() == [b, c])
        #expect(try f.service.otherEditions(ofBook: d).isEmpty)
    }

    // ED3: an undo does not untie editions tied since, and a hidden edition is not named.
    @Test func ED3_theTieOutlastsAnUndoAndKeepsHiddenBooksOutOfSight() throws {
        let f = try F()
        let english = try imported(f, "Dune", language: "en")
        let german = try imported(f, "Der Wüstenplanet", language: "de")
        var edit = BookEdit(book: try #require(try f.store.book(id: english)))
        edit.metadata.publisher = "Ace"
        _ = try f.service.save([edit])
        try f.service.linkEditions([english, german])
        try f.service.undoLast()
        #expect(try f.store.book(id: english)?.publisher != "Ace")
        #expect(try f.service.otherEditions(ofBook: english).compactMap(\.id) == [german])

        try f.store.setHidden(true, bookIds: [german])
        #expect(try BookScope.visible { try f.service.otherEditions(ofBook: english) }.isEmpty)
        #expect(try f.service.otherEditions(ofBook: english).count == 1)
    }

    // ED4: what sets one edition apart from another is its language, then who reads
    // it, then what kind of edition it is.
    @Test func ED4_whatSetsEditionsApart() throws {
        func book(_ language: String?, _ narrator: String?, _ kind: EditionKind? = nil) -> Book {
            var details = BookMetadata(title: "Dune", authors: ["Frank Herbert"])
            details.language = language
            details.narrators = narrator.map { [$0] } ?? []
            var book = Book(metadata: details)
            book.editionKind = kind.map { EditionKindNote(kind: $0, basis: .setByHand) }
            return book
        }
        let apart = LibraryService.whatSetsApart
        #expect(apart(book("de", "A"), book("en", "A")) == Locale.current.localizedString(forIdentifier: "de"))
        #expect(apart(book("en", "Scott Brick"), book("EN", "Simon Vance")) == "read by Scott Brick")
        #expect(apart(book("en", "A", .dramatised), book("en", "a", .unabridged)) == "dramatisation")
        #expect(apart(book("en", "A", .abridged), book("en", "A", .abridged)) == nil)
    }

    // MARK: Folders

    private func importedEdition(
        _ f: F, file: String, narrator: String?, language: String? = "en", target: ImportTarget = .newBook
    ) throws -> ImportOutcome {
        var tags = BookMetadata(title: "Dune", authors: ["Frank Herbert"])
        tags.narrators = narrator.map { [$0] } ?? []
        tags.language = language
        let source = try f.makeM4B(file, tags: tags)
        let item = ImportItem(candidate: f.candidate([source], tags), target: target)
        return try #require(try f.service.importItems([item]).outcomes.first)
    }

    // ED5: what an edition's folder says after its title is the first thing about it
    // that no other edition of the same title shares; an edition whose title is its
    // own says nothing more.
    @Test func ED5_whatAnEditionsFolderSays() throws {
        func book(_ id: Int64, _ title: String, language: String?, narrator: String?, kind: EditionKind? = nil) -> Book {
            var details = BookMetadata(title: title, authors: ["Frank Herbert"])
            details.language = language
            details.narrators = narrator.map { [$0] } ?? []
            var book = Book(metadata: details)
            book.id = id
            book.editionKind = kind.map { EditionKindNote(kind: $0, basis: .setByHand) }
            return book
        }
        let suffixes = LibraryService.editionSuffixes(of: [
            book(1, "Dune", language: "en", narrator: "Scott Brick"),
            book(2, "dune", language: "en", narrator: "Simon Vance"),
            book(3, "Dune", language: "en", narrator: "Full Cast", kind: .dramatised),
            book(4, "Dune", language: "de", narrator: "Jürgen Prochnow"),
            book(5, "Der Wüstenplanet", language: "de", narrator: nil),
        ])
        #expect(suffixes[1] == "read by Scott Brick" && suffixes[2] == "read by Simon Vance")
        #expect(suffixes[3] == "dramatisation" && suffixes[4] == "German")
        // Its title is its own: nothing is added.
        #expect(suffixes[5] == .some(nil))
        // Two that nothing tells apart get nothing, and stay in each other's way.
        let same = LibraryService.editionSuffixes(of: [
            book(1, "Dune", language: "en", narrator: nil), book(2, "Dune", language: "en", narrator: nil),
        ])
        #expect(same[1] == .some(nil) && same[2] == .some(nil))
    }

    // ED6: a second edition with the same title cannot be a new book in the first
    // one's folder; imported as another edition, it is an entry of its own, tied to
    // the first, and each is filed in a folder that says what sets it apart. Undo
    // takes the steps back one at a time.
    @Test func ED6_aSecondEditionIsImportedAndFiledApart() throws {
        let f = try F()
        let first = try f.importedId(try importedEdition(f, file: "brick.m4b", narrator: "Scott Brick"))
        #expect(try f.store.book(id: first)?.folderPath == "Frank Herbert/Dune")
        // As a plain new book it is refused, as before, and nothing changes.
        guard case .failed = try importedEdition(f, file: "vance.m4b", narrator: "Simon Vance") else {
            Issue.record("a second book in the same folder was not refused")
            return
        }
        #expect(try f.store.books().count == 1)

        let second = try f.importedId(
            try importedEdition(f, file: "vance2.m4b", narrator: "Simon Vance", target: .edition(of: first)))
        #expect(second != first)
        #expect(try f.store.books().count == 2)
        let folders = try [first, second].map { try #require(try f.store.book(id: $0)?.folderPath) }
        #expect(folders == ["Frank Herbert/Dune (read by Scott Brick)", "Frank Herbert/Dune (read by Simon Vance)"])
        for (id, folder) in zip([first, second], folders) {
            let files = try f.store.files(bookId: id)
            #expect(files.count == 1 && files.allSatisfy { $0.path.hasPrefix(folder + "/") })
            #expect(FileManager.default.fileExists(atPath: f.store.url(for: files[0]).path))
            #expect(try f.store.book(id: id)?.needsAttention == false)
        }
        // The file keeps the book's title as its name: it is the folder that differs.
        #expect(try f.store.files(bookId: first).first?.path.hasSuffix("/Dune.m4b") == true)
        #expect(try f.service.otherEditions(ofBook: first).compactMap(\.id) == [second])
        #expect(try f.tags(f.lib(folders[1] + "/Dune.m4b")).narrators == ["Simon Vance"])
        #expect(f.libraryTree().filter { !$0.contains("/Dune (") && $0 != "Frank Herbert" }.isEmpty)

        // Undo: first the renaming of the first edition's folder, then the import.
        try f.service.undoLast()
        #expect(try f.store.book(id: first)?.folderPath == "Frank Herbert/Dune")
        #expect(try f.store.book(id: second)?.folderPath == folders[1])
        try f.service.undoLast()
        #expect(try f.store.book(id: second) == nil)
        #expect(try f.store.books().count == 1)
    }

    // ED7: an edition whose title is its own (a translation) is filed under that title,
    // with nothing added, and the first keeps its folder; a third edition that shares
    // the first's title is told apart by what none of the others shares.
    @Test func ED7_onlyEditionsThatShareATitleAreToldApart() throws {
        let f = try F()
        let first = try f.importedId(try importedEdition(f, file: "en.m4b", narrator: "Scott Brick"))
        var german = BookMetadata(title: "Der Wüstenplanet", authors: ["Frank Herbert"])
        german.language = "de"
        let source = try f.makeM4B("de.m4b", tags: german)
        let outcome = try f.service.importItems([
            ImportItem(candidate: f.candidate([source], german), target: .edition(of: first))
        ]).outcomes[0]
        let translated = try f.importedId(outcome)
        #expect(try f.store.book(id: first)?.folderPath == "Frank Herbert/Dune")
        #expect(try f.store.book(id: translated)?.folderPath == "Frank Herbert/Der Wüstenplanet")
        #expect(try f.store.book(id: first)?.workKey != nil)

        let third = try f.importedId(
            try importedEdition(f, file: "de2.m4b", narrator: "Scott Brick", language: "de", target: .edition(of: translated)))
        #expect(try f.store.book(id: third)?.folderPath == "Frank Herbert/Dune (German)")
        #expect(try f.store.book(id: first)?.folderPath == "Frank Herbert/Dune (English)")
        #expect(try f.service.otherEditions(ofBook: first).count == 2)

        // Unlinked, an edition loses what was added, when the plain folder is free.
        try f.service.unlinkEdition(third)
        try f.service.unlinkEdition(translated)
        #expect(try f.store.book(id: first)?.folderPath == "Frank Herbert/Dune")
    }

    // ED8: when an edition is edited so that something else tells it from the others,
    // its folder and theirs are named afresh in the same save, as one step of Undo.
    @Test func ED8_anEditNamesTheEditionsFoldersAfresh() throws {
        let f = try F()
        let first = try f.importedId(try importedEdition(f, file: "a.m4b", narrator: "Scott Brick"))
        let second = try f.importedId(
            try importedEdition(f, file: "b.m4b", narrator: "Simon Vance", target: .edition(of: first)))
        #expect(try f.store.book(id: second)?.folderPath == "Frank Herbert/Dune (read by Simon Vance)")
        let steps = try f.service.undoLabels().count

        // The second turns out to be the German one: its language now tells it apart,
        // and the first is then the English one.
        var edit = BookEdit(book: try #require(try f.store.book(id: second)))
        edit.metadata.language = "de"
        let outcomes = try f.service.save([edit])
        #expect(outcomes.count == 1)
        #expect(try f.store.book(id: second)?.folderPath == "Frank Herbert/Dune (German)")
        #expect(try f.store.book(id: first)?.folderPath == "Frank Herbert/Dune (English)")
        #expect(try f.tags(f.lib("Frank Herbert/Dune (German)/Dune.m4b")).language == "de")
        #expect(try f.service.undoLabels().count == steps + 1)

        // Given a title of its own, it needs nothing added, and neither does the first.
        edit = BookEdit(book: try #require(try f.store.book(id: second)))
        edit.metadata.title = "Der Wüstenplanet"
        _ = try f.service.save([edit])
        #expect(try f.store.book(id: second)?.folderPath == "Frank Herbert/Der Wüstenplanet")
        #expect(try f.store.book(id: first)?.folderPath == "Frank Herbert/Dune")

        // One step back: both folders are as the edit found them.
        try f.service.undoLast()
        #expect(try f.store.book(id: second)?.folderPath == "Frank Herbert/Dune (German)")
        #expect(try f.store.book(id: first)?.folderPath == "Frank Herbert/Dune (English)")
    }
}

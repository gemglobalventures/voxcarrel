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
}

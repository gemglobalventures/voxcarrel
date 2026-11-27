import Foundation
import Testing
import VoxCarrelCore
import VoxCarrelFixtures

@testable import VoxCarrelAppCore

/// An author's or narrator's own page, and writing their name another way.
@MainActor
@Suite struct PeopleTests {
    @Test func aPersonsBooksAreSummedAndTheirNameCanBeWrittenAnotherWay() async throws {
        let h = try await Harness.demo()
        // The demo's author of a series of four.
        h.model.sidebarSelection = .browse(.authors, "Ines Calloway")
        await h.model.settle()
        var header = try #require(h.model.personHeader)
        let books = h.model.rows.filter { !$0.isMissing }.count
        #expect(header.name == "Ines Calloway" && header.kind == "Author" && header.canRename)
        #expect(header.facts.hasPrefix(books == 1 ? "1 book" : "\(books) books"))
        #expect(header.renamePrompt == "Write “Ines Calloway” as:")
        // Nothing else has a person's header.
        h.model.sidebarSelection = .allBooks
        await h.model.settle()
        #expect(h.model.personHeader == nil)

        h.model.sidebarSelection = .browse(.authors, "Ines Calloway")
        await h.model.settle()
        // The same name, or none, changes nothing.
        await h.model.renamePerson(to: "Ines Calloway")
        await h.model.renamePerson(to: "  ")
        #expect(h.model.undoLabel != "Rename Ines Calloway")

        await h.model.renamePerson(to: "I. Calloway")
        await h.model.settle()
        #expect(h.model.alert == nil && h.model.sidebarSelection == .browse(.authors, "I. Calloway"))
        header = try #require(h.model.personHeader)
        #expect(header.name == "I. Calloway" && h.model.rows.filter { !$0.isMissing }.count == books)
        #expect(h.model.rows.allSatisfy { $0.isMissing || $0.book.authors.contains("I. Calloway") })
        #expect(h.model.sidebar.browse[.authors]?.contains("Ines Calloway") == false)
        #expect(h.model.undoLabel == "Rename Ines Calloway")
    }
}

import Foundation
import Testing
@testable import VoxCarrelCore
import VoxCarrelFixtures

/// RP1–RP2: an author or a narrator written one way across the library.
@Suite struct RenamePersonTests {
    typealias F = LibraryFixture

    private func add(_ f: F, _ title: String, authors: [String], narrators: [String] = []) throws -> Int64 {
        var details = BookMetadata(title: title, authors: authors)
        details.narrators = narrators
        return try #require(try f.store.insert(Book(metadata: details), files: []).id)
    }

    @Test func RP1_aNarratorWrittenTwoWaysBecomesOnePerson() throws {
        let f = try F()
        let a = try add(f, "One", authors: ["Andy Weir"], narrators: ["Ray Porter"])
        let b = try add(f, "Two", authors: ["Dennis Taylor"], narrators: ["raymond porter ", "Someone Else"])
        let c = try add(f, "Three", authors: ["Raymond Porter"], narrators: ["Ray Porter", "Raymond Porter"])
        let d = try add(f, "Four", authors: ["Other"], narrators: ["Other Reader"])
        #expect(try f.service.renamePerson(.narrators, from: "Raymond Porter", to: "Ray Porter") == 2)
        #expect(try f.store.book(id: a)?.narrators == ["Ray Porter"])
        #expect(try f.store.book(id: b)?.narrators == ["Ray Porter", "Someone Else"])
        // Named twice, he is named once; and the author of that name is another field.
        let third = try #require(try f.store.book(id: c))
        #expect(third.narrators == ["Ray Porter"] && third.authors == ["Raymond Porter"])
        #expect(try f.store.book(id: d)?.narrators == ["Other Reader"])
        #expect(try f.service.undoLabels().first == "Rename Raymond Porter")
        _ = try f.service.undoLast()
        #expect(try f.store.book(id: b)?.narrators == ["raymond porter ", "Someone Else"])
    }

    @Test func RP2_onlyPeopleAndOnlyRealChanges() throws {
        let f = try F()
        _ = try add(f, "One", authors: ["Andy Weir"])
        #expect(try f.service.renamePerson(.authors, from: "Andy Weir", to: "Andy Weir") == 0)
        #expect(try f.service.renamePerson(.authors, from: "Andy Weir", to: "  ") == 0)
        #expect(try f.service.renamePerson(.authors, from: "Nobody", to: "Somebody") == 0)
        #expect(try f.service.renamePerson(.series, from: "Andy Weir", to: "X") == 0)
        #expect(try f.service.renamePerson(.authors, from: "andy weir", to: "Andrew Weir") == 1)
        #expect(try f.store.books().first?.authors == ["Andrew Weir"])
    }
}

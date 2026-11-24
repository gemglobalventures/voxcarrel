import CoreGraphics
import Foundation
import Testing
@testable import VoxCarrelCore
import VoxCarrelFixtures

/// Plan 14, Task 2: recognising the same book at import (rules IM16–IM18), and the three
/// files that prompted the plan, from the scanner to the match.
@Suite struct ImportGuessingTests {
    typealias F = LibraryFixture

    static let day = Date(timeIntervalSince1970: 1_700_000_000)

    @discardableResult
    private func add(
        _ f: F, _ title: String, _ authors: [String], asin: String? = nil, copies: [ExternalCopy] = [],
        daysLater: Double = 0, needsAttention: Bool = false
    ) throws -> Int64 {
        var metadata = BookMetadata(title: title, authors: authors)
        metadata.asin = asin
        var book = Book(
            metadata: metadata, needsAttention: needsAttention,
            dateAdded: Self.day.addingTimeInterval(daysLater * 86_400))
        book.externalCopies = copies
        return try #require(try f.store.insert(book, files: []).id)
    }

    /// "id:strength" of the best match, and a check that `existingMatch` gives the same
    /// book for a sure match and none for a possible one (IM17).
    private func match(_ f: F, _ title: String, _ authors: [String], asin: String? = nil) throws -> String? {
        var metadata = BookMetadata(title: title, authors: authors)
        metadata.asin = asin
        let found = try f.service.existingMatches(for: metadata)
        let joined = try f.service.existingMatch(for: metadata)
        #expect(joined == (found?.strength == .possible ? nil : found?.book))
        #expect(try f.service.existingMatch(for: CandidateBook(files: [], metadata: metadata)) == joined)
        return found.map { "\($0.book.id ?? -1):\($0.strength)" }
    }

    /// A PDF with nothing in its information dictionary.
    private func makeUntaggedPDF(_ f: F, _ name: String) throws -> URL {
        let url = f.inbox.appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        return url
    }

    // MARK: The owner's three files

    private func ownersLibrary() throws -> (f: F, audiobook: Int64) {
        let f = try F()
        let id = try add(f, "Mind Over Markets (Unabridged)", ["James F. Dalton"], asin: "B09WXN61GL")
        return (f, id)
    }

    // IM11, IM16: the untagged PDF named "Title - Author".
    @Test func theUntaggedPDFIsReadAsTitleThenAuthorAndOfferedTheAudiobook() throws {
        let (f, audiobook) = try ownersLibrary()
        let pdf = try makeUntaggedPDF(f, "Mind Over Markets_ Power Tradin - James F. Dalton.pdf")
        #expect(try f.io.read(pdf).metadata.title == "")
        #expect(try f.io.read(pdf).metadata.authors == [])

        let result = f.service.scan([pdf])

        #expect(result.skipped.isEmpty)
        #expect(result.candidates.count == 1)
        let candidate = try #require(result.candidates.first)
        #expect(candidate.metadata.title == "Mind Over Markets: Power Tradin")
        #expect(candidate.metadata.authors == ["James F. Dalton"])
        #expect(candidate.metadata.asin == nil)
        #expect(candidate.guessNotes == [.fromFileName, .orderSwapped])
        #expect(candidate.files == [CandidateFile(url: pdf, role: .ebook)])

        let match = try #require(try f.service.existingMatches(for: candidate.metadata))
        #expect(match.book.id == audiobook)
        #expect(match.strength == .possible)
        // Offered, never joined without asking.
        #expect(try f.service.existingMatch(for: candidate) == nil)
    }

    // IM13, IM16: the companion PDF named with the Audible ID, whose tags name another author.
    @Test func theCompanionPDFIsMatchedByTheAudibleIDInItsName() throws {
        let (f, audiobook) = try ownersLibrary()
        let pdf = try f.makePDF(
            "Mind Over Markets꞉ Power Trading with Market Generated Information, Updated Edition [B09WXN61GL].pdf")
        #expect(pdf.lastPathComponent.unicodeScalars.contains("\u{A789}"))

        let result = f.service.scan([pdf])

        #expect(result.candidates.count == 1)
        let candidate = try #require(result.candidates.first)
        // The tags win for what they give.
        #expect(candidate.metadata.title == "Original Title")
        #expect(candidate.metadata.authors == ["Original Author"])
        #expect(candidate.metadata.asin == "B09WXN61GL")
        #expect(candidate.guessNotes == [.audibleIDFromName])

        let match = try #require(try f.service.existingMatches(for: candidate.metadata))
        #expect(match.book.id == audiobook)
        #expect(match.strength == .audibleID)
        #expect(try f.service.existingMatch(for: candidate)?.id == audiobook)
    }

    // A title taken from a name has a real colon; text from tags is never changed.
    @Test func aTitleReadFromANameHasARealColonAndTagsAreLeftAlone() throws {
        let (f, _) = try ownersLibrary()
        let pdf = try makeUntaggedPDF(f, "Mind Over Markets\u{A789} Power Trading with Market Generated Information.pdf")
        let untagged = try #require(f.service.scan([pdf]).candidates.first)
        #expect(untagged.metadata.title == "Mind Over Markets: Power Trading with Market Generated Information")
        #expect(untagged.guessNotes.contains(.fromFileName))

        let tagged = try f.makeM4B(
            "tagged.m4b", tags: F.meta("Mind Over Markets\u{A789} Power_ Trading", "James\u{A789} Dalton"))
        let fromTags = try #require(f.service.scan([tagged]).candidates.first)
        #expect(fromTags.metadata.title == "Mind Over Markets\u{A789} Power_ Trading")
        #expect(fromTags.metadata.authors == ["James\u{A789} Dalton"])
    }

    // IM16: the audiobook tagged without the edition word.
    @Test func theAudiobookTaggedWithoutTheEditionWordIsASureMatch() throws {
        let (f, audiobook) = try ownersLibrary()
        let audio = try f.makeM4B("download.m4b", tags: F.meta("Mind Over Markets", "James F. Dalton"))

        let result = f.service.scan([audio])

        let candidate = try #require(result.candidates.first)
        #expect(candidate.metadata.title == "Mind Over Markets")
        #expect(candidate.metadata.authors == ["James F. Dalton"])
        #expect(candidate.metadata.asin == nil)
        #expect(candidate.guessNotes == [])

        let match = try #require(try f.service.existingMatches(for: candidate.metadata))
        #expect(match.book.id == audiobook)
        #expect(match.strength == .sure)
        #expect(try f.service.existingMatch(for: candidate)?.id == audiobook)
    }

    // IM15: dropped together, the three are still three: nothing here joins them without asking
    // except the Audible ID, which only the companion has.
    @Test func theThreeFilesDroppedTogetherAreNotJoinedOnASubtitle() throws {
        let (f, _) = try ownersLibrary()
        let untagged = try makeUntaggedPDF(f, "Mind Over Markets_ Power Tradin - James F. Dalton.pdf")
        let audio = try f.makeM4B("download.m4b", tags: F.meta("Mind Over Markets", "James F. Dalton"))

        let result = f.service.scan([untagged, audio])

        #expect(result.candidates.count == 2)
    }

    // IM11: what arrives in a watch folder is read with what the library knows, as at import.
    @Test func arrivalsInAWatchFolderAreReadWithTheKnownNames() throws {
        let f = try F()
        try add(f, "Dead Lions", ["Mick Herron"])
        var now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        _ = try f.service.addWatchFolder(f.inbox, now: now)
        // Both sides are name-shaped: only the library's knowing the author decides.
        _ = try f.makeM4B("Slow Horses - Mick Herron.m4b", tags: BookMetadata())

        now += 11
        _ = try f.service.checkInbox(now: now)
        now += 11
        let report = try f.service.checkInbox(now: now)

        #expect(report.arrivals.count == 1)
        let candidate = try #require(report.arrivals.first?.candidate)
        #expect(candidate.metadata.title == "Slow Horses")
        #expect(candidate.metadata.authors == ["Mick Herron"])
        #expect(candidate.guessNotes == [.fromFileName, .orderSwapped])
    }

    // MARK: IM16

    @Test func IM16_strengthOfAMatch() throws {
        let f = try F()
        let dune = try add(f, "Dune (Unabridged)", ["Frank Herbert", "Someone Else"], daysLater: 2)
        let messiah = try add(f, "Dune: Messiah", ["Frank Herbert"], daysLater: 3)
        let hobbit = try add(f, "The Hobbit", ["J.R.R. Tolkien"], asin: "B0HOBBIT01", daysLater: 4)
        let márquez = try add(f, "Cien años de soledad", ["Gabriel García Márquez"], daysLater: 5)

        // Sure: the same first author and the same title, edition words aside.
        #expect(try match(f, "Dune", ["Frank Herbert"]) == "\(dune):sure")
        #expect(try match(f, " dune - unabridged ", ["FRANK  HERBERT", "Other"]) == "\(dune):sure")
        #expect(try match(f, "Hobbit [Audiobook]", ["J. R. R. Tolkien"]) == "\(hobbit):sure")
        #expect(try match(f, "Cien anos de soledad", ["Gabriel Garcia Marquez"]) == "\(márquez):sure")
        #expect(try match(f, "Dune Messiah", ["Frank Herbert"]) == "\(messiah):sure")

        // The Audible ID comes first, whatever the title and author.
        #expect(try match(f, "Dune", ["Frank Herbert"], asin: " b0hobbit01 ") == "\(hobbit):audibleID")
        #expect(try match(f, "Anything", [], asin: "B0HOBBIT01") == "\(hobbit):audibleID")
        // An ID no book has falls back to the title and author.
        #expect(try match(f, "Dune", ["Frank Herbert"], asin: "B0UNKNOWN1") == "\(dune):sure")

        // Possible: the same first author and one title is the other up to a subtitle.
        #expect(try match(f, "Dune: The Graphic Novel", ["Frank Herbert"]) == "\(dune):possible")
        #expect(try match(f, "The Hobbit_ There and Back Again", ["J.R.R. Tolkien"]) == "\(hobbit):possible")
        // Possible: the same title and no author to compare.
        #expect(try match(f, "The Hobbit (Unabridged)", []) == "\(hobbit):possible")
        #expect(try match(f, "Dune", ["  "]) == "\(dune):possible")

        // Never: another first author; a subtitle and no author; a longer title; no title.
        #expect(try match(f, "Dune", ["Brian Herbert", "Frank Herbert"]) == nil)
        #expect(try match(f, "Dune", ["Someone Else"]) == nil)
        #expect(try match(f, "The Hobbit: There and Back Again", []) == nil)
        #expect(try match(f, "Dune Children", ["Frank Herbert"]) == nil)
        #expect(try match(f, "", ["Frank Herbert"]) == nil)
        #expect(try match(f, "?!", ["Frank Herbert"]) == nil)
        #expect(try match(f, "", []) == nil)
    }

    // IM16: two books of one author whose titles differ only in a sign are not one book.
    @Test func IM16_aTitleThatDiffersInASignWrittenOnToAWordIsNoMatch() throws {
        let f = try F()
        let c = try add(f, "C How to Program", ["Paul Deitel"])
        #expect(try match(f, "C++ How to Program", ["Paul Deitel"]) == nil)
        #expect(try match(f, "C# How to Program", ["Paul Deitel"]) == nil)
        #expect(try match(f, "C++ How to Program", []) == nil)
        #expect(try match(f, "c how to program (Unabridged)", ["Paul Deitel"]) == "\(c):sure")
    }

    // IM16: of several of one strength the earliest added; a sure match before a possible one.
    @Test func IM16_theBestAndEarliestMatchIsGiven() throws {
        let f = try F()
        // Inserted out of date order, so "earliest added" is not simply the lowest id.
        let subtitled = try add(f, "Dune: Special Edition", ["Frank Herbert"], daysLater: 0)
        try add(f, "Dune", ["Frank Herbert"], daysLater: 5)
        let earliest = try add(f, "dune (unabridged)", ["frank herbert"], daysLater: 1)
        let longer = try add(f, "Emma: A Novel", ["Jane Austen"], daysLater: 9)
        let first = try add(f, "Emma: An Annotated Edition", ["Jane Austen"], daysLater: 8)
        _ = longer

        #expect(try match(f, "Dune", ["Frank Herbert"]) == "\(earliest):sure")
        #expect(try match(f, "Emma", ["Jane Austen"]) == "\(first):possible")
        #expect(try match(f, "Dune: Special Edition", ["Frank Herbert"]) == "\(subtitled):sure")
        // With no author, the earliest book of that title.
        #expect(try match(f, "Dune", []) == "\(earliest):possible")
    }

    // IM16: books flagged as needing attention are never matched, at any strength.
    @Test func IM16_flaggedBooksAreNeverMatched() throws {
        let f = try F()
        try add(f, "Dune", ["Frank Herbert"], asin: "B0FLAGGED1", needsAttention: true)
        try add(f, "Emma: A Novel", ["Jane Austen"], needsAttention: true)

        #expect(try match(f, "Dune", ["Frank Herbert"]) == nil)
        #expect(try match(f, "Other", ["Other"], asin: "B0FLAGGED1") == nil)
        #expect(try match(f, "Emma", ["Jane Austen"]) == nil)
        #expect(try match(f, "Dune", []) == nil)
    }

    // MARK: IM17

    // IM17: Add Audible Book joins a sure match and adds a new book beside a possible one.
    @Test func IM17_addingABookOwnedElsewhereJoinsOnlyASureMatch() throws {
        let f = try F()
        let dune = try add(f, "Dune", ["Frank Herbert"])
        let copy = ExternalCopy(kind: .audible, form: .audio, store: "uk", itemId: nil)

        // Possible: a new book, and the one in the library is untouched.
        let before = try f.store.book(id: dune)
        let possible = try f.service.addExternalBook(
            metadata: BookMetadata(title: "Dune: The Graphic Novel", authors: ["Frank Herbert"]), cover: nil, copy: copy)
        guard case .added(let added) = possible else {
            Issue.record("expected a new book, got \(possible)")
            return
        }
        #expect(added != dune)
        #expect(try f.store.book(id: dune) == before)
        let untitled = try f.service.addExternalBook(
            metadata: BookMetadata(title: "Dune", authors: []), cover: nil, copy: copy)
        guard case .added = untitled else {
            Issue.record("expected a new book, got \(untitled)")
            return
        }

        // Sure: the book in the library is given the copy.
        let sure = try f.service.addExternalBook(
            metadata: BookMetadata(title: "Dune (Unabridged)", authors: ["Frank Herbert"]), cover: nil, copy: copy)
        #expect(sure == .markedExisting(bookId: dune))
        #expect(try f.store.book(id: dune)?.title == "Dune")
        #expect(try f.store.books().count == 3)
    }

    // MARK: IM18

    @Test func IM18_knownNamesAreTheLibrarysAuthorsAndTitles() throws {
        let f = try F()
        #expect(try f.service.knownNames() == .none)

        try add(f, "Mind Over Markets (Unabridged)", ["James F. Dalton", "Eric T. Jones"])
        try add(f, "The Hobbit", ["J.R.R. Tolkien"], needsAttention: true)
        try add(f, "", ["", "  "])
        try add(f, "?!", [])

        let known = try f.service.knownNames()
        #expect(known.authors == ["james f dalton", "eric t jones", "j r r tolkien"])
        #expect(known.titles == ["mind over markets", "hobbit"])
        // Normalised with what the name reader compares with.
        #expect(known.authors.contains(KnownNames.authorKey("JAMES F. DALTON")))
        #expect(known.titles.contains(KnownNames.titleKey("Mind over Markets")))
    }

    @Test func IM18_knownNamesOfALargeLibraryAreQuick() throws {
        let f = try F()
        for index in 0..<2_000 {
            try add(f, "A Long Enough Title Number \(index) (Unabridged)", ["Author \(index % 500) Surname", "Second \(index)"])
        }
        let clock = ContinuousClock()
        var known = KnownNames.none
        let taken = try clock.measure { known = try f.service.knownNames() }
        #expect(known.titles.count == 2_000)
        #expect(known.authors.count == 2_500)
        #expect(taken < .seconds(5))

        // A match against it is as quick.
        let matching = try clock.measure {
            _ = try f.service.existingMatches(
                for: BookMetadata(title: "A Long Enough Title Number 1999", authors: ["Author 499 Surname"]))
        }
        #expect(matching < .seconds(5))
    }
}

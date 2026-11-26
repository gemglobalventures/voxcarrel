import Foundation
import Testing
@testable import VoxCarrelCore
import VoxCarrelFixtures

/// TD1–TD5: what is untidy about a library, found across all of it.
@Suite struct TidyTests {
    typealias F = LibraryFixture

    /// Adds a book to the catalogue as it stands: no file is made or opened.
    @discardableResult
    private func add(
        _ f: F, _ title: String, author: String? = "Ines Calloway", narrator: String? = nil, series: (String, String?)? = nil,
        year: Int? = 2020, summary: String? = "About it.", language: String? = nil, files: [(String, FileFormat, FileRole)] = [("a.m4b", .m4b, .audio)],
        cover: Bool = true
    ) throws -> Int64 {
        var details = BookMetadata(title: title, authors: author.map { [$0] } ?? [])
        details.narrators = narrator.map { [$0] } ?? []
        details.series = series?.0
        details.seriesNumber = series?.1
        details.year = year
        details.summary = summary
        details.language = language
        let rows = files.enumerated().map { BookFile(path: "\(title)/\($0.element.0)", format: $0.element.1, role: $0.element.2, position: $0.offset) }
        let id = try #require(try f.store.insert(Book(metadata: details), files: rows).id)
        if cover { try f.service.covers.set(F.jpeg, for: id) }
        return id
    }

    // TD1: a tidy library finds nothing; each missing detail is found, and only on
    // the book that lacks it.
    @Test func TD1_missingDetailsAreFound() throws {
        let f = try F()
        let whole = try add(f, "Whole")
        #expect(try f.service.tidyFindings().isEmpty)
        let nobody = try add(f, "Nobody's", author: nil)
        let undated = try add(f, "Undated", year: nil)
        let unsaid = try add(f, "Unsaid", summary: "  ")
        let bare = try add(f, "Bare", cover: false)
        // Owned elsewhere, with no files here: its cover is its source's to give.
        try add(f, "Elsewhere", files: [], cover: false)
        let old = try add(f, "Old Format", files: [("a.mobi", .mobi, .ebook)])
        try add(f, "Both Formats", files: [("a.mobi", .mobi, .ebook), ("a.epub", .epub, .ebook)])
        let found = try f.service.tidyFindings()
        #expect(found[.noAuthor] == [nobody] && found[.noYear] == [undated] && found[.noDescription] == [unsaid])
        #expect(found[.noCover] == [bare] && found[.oldFormat] == [old])
        #expect(Set(found.keys) == [.noAuthor, .noYear, .noDescription, .noCover, .oldFormat])
        _ = whole
    }

    // TD2: a book in a series with no number; two books with one number; a series
    // whose numbers skip. Editions of one work rightly share a number.
    @Test func TD2_seriesAreChecked() throws {
        let f = try F()
        let one = try add(f, "One", series: ("Tidewater", "1"))
        let two = try add(f, "Two", series: ("Tidewater", "2"))
        let four = try add(f, "Four", series: ("tidewater", "4"))
        let loose = try add(f, "Loose", series: ("Tidewater", nil))
        let a = try add(f, "Alpha", series: ("Other", "1"))
        let b = try add(f, "Beta", series: ("Other", "1.0"))
        try add(f, "Gamma", series: ("Other", "2"))
        try add(f, "Omnibus", series: ("Third", "1-3"))
        var found = try f.service.tidyFindings()
        #expect(found[.seriesNoNumber] == [loose])
        #expect(found[.seriesGap] == [one, two, four, loose].sorted())
        #expect(found[.seriesSameNumber] == [a, b])
        try f.service.linkEditions([a, b])
        found = try f.service.tidyFindings()
        #expect(found[.seriesSameNumber] == nil)
    }

    // TD3: one name written two ways; titles carrying words that belong elsewhere.
    @Test func TD3_namesAndTitles() throws {
        let f = try F()
        let dotted = try add(f, "First", author: "J.R.R. Tolkien")
        let spaced = try add(f, "Second", author: "J. R. R. Tolkien", narrator: "Rob Inglis")
        try add(f, "Third", author: "Someone Else", narrator: "Rob Inglis")
        let unabridged = try add(f, "Fourth (Unabridged)", author: "A Writer")
        let novel = try add(f, "Fifth: A Novel", author: "B Writer")
        let numbered = try add(f, "Sixth (Saga, Book 2)", author: "C Writer", series: ("Saga", "2"))
        try add(f, "A Novel Idea", author: "D Writer")
        let found = try f.service.tidyFindings()
        #expect(found[.nameSpellings] == [dotted, spaced])
        #expect(found[.titleExtras] == [unabridged, novel, numbered])
    }

    // TD4: the same title by the same author twice is told as what it is: the same
    // book twice, its two forms filed apart, or editions not yet linked.
    @Test func TD4_theSameTitleTwice() throws {
        let f = try F()
        let twiceA = try add(f, "Twice")
        let twiceB = try add(f, "twice!")
        let heard = try add(f, "Forms")
        let read = try add(f, "Forms", files: [("a.epub", .epub, .ebook)])
        let english = try add(f, "Dune", author: "Frank Herbert", language: "en")
        let german = try add(f, "Dune", author: "Frank Herbert", language: "de")
        let linkedA = try add(f, "Linked", narrator: "One")
        let linkedB = try add(f, "Linked", narrator: "Two")
        try f.service.linkEditions([linkedA, linkedB])
        try add(f, "Twice", author: "Another Author")
        let found = try f.service.tidyFindings()
        #expect(found[.sameBookTwice] == [twiceA, twiceB])
        #expect(found[.formsApart] == [heard, read])
        #expect(found[.editionsNotLinked] == [english, german])
    }

    // TD5: a book let off a check is no longer listed under it, and can be put back;
    // a hidden book is not looked at while hidden books are out of sight.
    @Test func TD5_fineAsItIsAndHidden() throws {
        let f = try F()
        let a = try add(f, "Undated A", year: nil)
        let b = try add(f, "Undated B", year: nil, summary: nil)
        try f.service.setTidyIgnored(true, check: .noYear, bookIds: [a])
        var found = try f.service.tidyFindings()
        #expect(found[.noYear] == [b] && found[.noDescription] == [b])
        try f.service.setTidyIgnored(true, check: .noYear, bookIds: [b])
        #expect(try f.service.tidyFindings()[.noYear] == nil)
        try f.service.setTidyIgnored(false, check: .noYear, bookIds: [a, b])
        #expect(try f.service.tidyFindings()[.noYear] == [a, b])

        try f.store.setHidden(true, bookIds: [b])
        found = try BookScope.visible { try f.service.tidyFindings() }
        #expect(found[.noYear] == [a] && found[.noDescription] == nil)
        #expect(TidyCheck.allCases.allSatisfy { !$0.title.isEmpty && $0.explanation.count > 20 })
    }
}

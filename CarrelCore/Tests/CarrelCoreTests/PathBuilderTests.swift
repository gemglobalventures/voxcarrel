import Foundation
import Testing
@testable import CarrelCore

@Suite struct PathBuilderTests {
    func file(_ name: String, _ role: FileRole) -> CandidateFile {
        CandidateFile(url: URL(fileURLWithPath: "/in/\(name)"), role: role)
    }

    @Test func sanitiseReplacesSlashAndColon() {
        #expect(PathBuilder.sanitise("AC/DC: Live") == "AC-DC- Live")
    }

    @Test func sanitiseStripsLeadingDotsAndTrailingDotsAndSpaces() {
        #expect(PathBuilder.sanitise("..hidden. ") == "hidden")
        #expect(PathBuilder.sanitise("  Dune  ") == "Dune")
    }

    @Test func sanitiseCapsLengthAt200() {
        let long = String(repeating: "a", count: 300)
        #expect(PathBuilder.sanitise(long).count == 200)
    }

    @Test func standaloneBookFolder() {
        let m = BookMetadata(title: "Project Hail Mary", authors: ["Andy Weir", "Someone Else"])
        #expect(PathBuilder.bookFolder(metadata: m) == "Andy Weir/Project Hail Mary")
    }

    @Test func seriesBookFolderUsesNumberPrefix() {
        var m = BookMetadata(title: "Dune", authors: ["Frank Herbert"])
        m.series = "Dune"
        m.seriesNumber = "1"
        #expect(PathBuilder.bookFolder(metadata: m) == "Frank Herbert/Dune/1 - Dune")
    }

    @Test func seriesBookWithoutNumberUsesPlainTitle() {
        var m = BookMetadata(title: "The Hobbit", authors: ["J.R.R. Tolkien"])
        m.series = "Middle-earth"
        #expect(PathBuilder.bookFolder(metadata: m) == "J.R.R. Tolkien/Middle-earth/The Hobbit")
    }

    @Test func bookWithoutAuthorOrTitleCannotBeFiled() {
        #expect(PathBuilder.bookFolder(metadata: BookMetadata(title: "Dune")) == nil)
        #expect(PathBuilder.bookFolder(metadata: BookMetadata(title: "", authors: ["A"])) == nil)
        #expect(PathBuilder.bookFolder(metadata: BookMetadata(title: "...", authors: ["A"])) == nil)
    }

    @Test func singleAudioFileIsNamedAfterTitle() {
        #expect(PathBuilder.fileNames(title: "Dune", files: [file("x.M4B", .audio)]) == ["Dune.m4b"])
    }

    @Test func multiPartAudiobookIsNumberedWithAtLeastTwoDigits() {
        let files = [file("a.mp3", .audio), file("b.mp3", .audio), file("c.mp3", .audio)]
        #expect(PathBuilder.fileNames(title: "Dune", files: files)
            == ["01 - Dune.mp3", "02 - Dune.mp3", "03 - Dune.mp3"])
    }

    @Test func numberingWidensForLargePartCounts() {
        let files = (1...120).map { file("\($0).mp3", .audio) }
        let names = PathBuilder.fileNames(title: "T", files: files)
        #expect(names.first == "001 - T.mp3")
        #expect(names.last == "120 - T.mp3")
    }

    @Test func ebookFormatsShareTheTitle() {
        let files = [file("a.epub", .ebook), file("a.pdf", .ebook)]
        #expect(PathBuilder.fileNames(title: "Piranesi: A Novel", files: files)
            == ["Piranesi- A Novel.epub", "Piranesi- A Novel.pdf"])
    }

    @Test func oneBookHoldsAudioEbookAndExtrasTogether() {
        let files = [
            file("part1.mp3", .audio),
            file("Companion: Maps.PDF", .extra),
            file("part2.mp3", .audio),
            file("book.epub", .ebook),
        ]
        #expect(PathBuilder.fileNames(title: "Dune", files: files) == [
            "01 - Dune.mp3",
            "Extras/Companion- Maps.pdf",
            "02 - Dune.mp3",
            "Dune.epub",
        ])
    }
}

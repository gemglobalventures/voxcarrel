import Foundation
import Testing
@testable import VoxCarrelCore

@Suite struct PathBuilderTests {
    func file(_ name: String, _ role: FileRole) -> CandidateFile {
        CandidateFile(url: URL(fileURLWithPath: "/in/\(name)"), role: role)
    }

    @Test func sanitiseReplacesSlashAndColon() {
        #expect(PathBuilder.sanitise("AC/DC: Live") == "AC-DC- Live")
    }

    /// FP42: a "/" or ":" is replaced even when a combining mark follows it, where the
    /// two read as one character. Otherwise the "/" would reach the disk and make a level.
    @Test func fp42_sanitiseReplacesSlashAndColonBeforeACombiningMark() {
        #expect(PathBuilder.sanitise("a/\u{301}b").unicodeScalars.map(\.value) == [0x61, 0x2D, 0x301, 0x62])
        #expect(PathBuilder.sanitise("a:\u{308}b").unicodeScalars.map(\.value) == [0x61, 0x2D, 0x308, 0x62])
        for value in ["a/\u{301}b", "/\u{301}", "x:\u{20DD}y/\u{301}/\u{301}z", "naïve/\u{308}x", "\u{301}/\u{301}:\u{301}"] {
            let safe = PathBuilder.sanitise(value)
            #expect(!safe.unicodeScalars.contains("/"), "\(value.debugDescription)")
            #expect(!safe.unicodeScalars.contains(":"), "\(value.debugDescription)")
            #expect(!safe.utf8.contains(UInt8(ascii: "/")))
        }
    }

    @Test func fp42_aSlashBeforeACombiningMarkInAValueMakesNoFolderLevel() throws {
        var m = BookMetadata(title: "a/\u{301}b", authors: ["Ann:\u{301} Author"])
        m.series = "S/\u{308}"
        m.seriesNumber = "1/\u{301}2"
        for pattern in FolderPattern.presets.map(\.pattern) {
            let folder = try #require(pattern.folder(for: FolderPatternValues(metadata: m, hasAudio: true)))
            // Counted as the disk counts them: by the "/" bytes.
            let levels = folder.utf8.split(separator: UInt8(ascii: "/")).count
            let expected = pattern.text.split(separator: "|")[0].filter { $0 == "/" }.count + 1
            #expect(levels == expected, "\(pattern.text): \(folder.debugDescription)")
            #expect(!folder.unicodeScalars.contains(":"))
        }
    }

    /// FP42: a leading "." or space is stripped even when a combining mark follows it,
    /// where the two read as one character. Otherwise the name would begin with a dot
    /// on disk, and the folder would be hidden.
    @Test func fp42_sanitiseStripsALeadingDotOrSpaceBeforeACombiningMark() {
        #expect(PathBuilder.sanitise(".\u{301}x").unicodeScalars.map(\.value) == [0x301, 0x78])
        #expect(PathBuilder.sanitise(" .\u{308}. \u{301}Dune").unicodeScalars.map(\.value) == [0x308, 0x2E, 0x20, 0x301, 0x44, 0x75, 0x6E, 0x65])
        for value in [".\u{301}x", "..\u{301}", ". .\u{20DD}name", " \u{301}.hidden", "...\u{301}...", ".\u{301}", "/.\u{301}x"] {
            let safe = PathBuilder.sanitise(value)
            #expect(safe.unicodeScalars.first != ".", "\(value.debugDescription)")
            #expect(safe.unicodeScalars.first != " ", "\(value.debugDescription)")
            #expect(safe.utf8.first != UInt8(ascii: "."))
            #expect(PathBuilder.sanitise(safe) == safe)
        }
        #expect(PathBuilder.sanitise("..hidden. ") == "hidden")
    }

    @Test func fp42_noPresetFilesABookInAHiddenFolder() throws {
        var m = BookMetadata(title: ".\u{301}Title", authors: [".\u{308}Author"])
        m.series = " .\u{301}Series"
        m.seriesNumber = ".\u{301}1"
        for pattern in FolderPattern.presets.map(\.pattern) {
            let folder = try #require(pattern.folder(for: FolderPatternValues(metadata: m, hasAudio: true)))
            for level in folder.utf8.split(separator: UInt8(ascii: "/")) {
                #expect(level.first != UInt8(ascii: "."), "\(pattern.text): \(folder.debugDescription)")
            }
        }
        let names = PathBuilder.fileNames(
            title: ".\u{301}Title", files: [CandidateFile(url: URL(fileURLWithPath: "/in/x.m4b"), role: .audio)])
        #expect(names.allSatisfy { $0.utf8.first != UInt8(ascii: ".") })
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

    // MARK: Review fixes

    @Test func sanitiseStripsControlCharacters() {
        #expect(PathBuilder.sanitise("Du\u{0}ne\nPart\tOne\r") == "DunePartOne")
    }

    @Test func seriesNumberAndTitleTogetherAreCappedAt200() throws {
        var m = BookMetadata(title: String(repeating: "t", count: 200), authors: ["A"])
        m.series = "S"
        m.seriesNumber = String(repeating: "9", count: 100)

        let folder = try #require(PathBuilder.bookFolder(metadata: m))
        let last = try #require(folder.split(separator: "/").last)

        #expect(last.count == 200)
        #expect(last.hasPrefix(String(repeating: "9", count: 100) + " - t"))
    }

    @Test func fileNamesIncludingNumberAndExtensionAreCappedAt200() {
        let title = String(repeating: "t", count: 300)
        let files = [
            file("a.mp3", .audio), file("b.mp3", .audio),
            file("x.epub", .ebook), file("y.epub", .ebook),
            file(String(repeating: "m", count: 300) + ".pdf", .extra),
        ]

        let names = PathBuilder.fileNames(title: title, files: files)

        #expect(names.map { $0.split(separator: "/").last!.count } == [200, 200, 200, 200, 200])
        #expect(names[0].hasPrefix("01 - ttt") && names[0].hasSuffix("ttt.mp3"))
        #expect(names[1].hasPrefix("02 - ttt") && names[1].hasSuffix("ttt.mp3"))
        #expect(names[2].hasSuffix("ttt.epub"))
        #expect(names[3].hasSuffix("ttt 2.epub"))
        #expect(names[4].hasPrefix("Extras/mmm") && names[4].hasSuffix("mmm.pdf"))
    }

    @Test func fileNamesNeverRepeat() {
        let files = [
            CandidateFile(url: URL(fileURLWithPath: "/a/Map.pdf"), role: .extra),
            CandidateFile(url: URL(fileURLWithPath: "/b/Map.pdf"), role: .extra),
            CandidateFile(url: URL(fileURLWithPath: "/c/map.PDF"), role: .extra),
            CandidateFile(url: URL(fileURLWithPath: "/c/Map 2.pdf"), role: .extra),
            file("x.epub", .ebook), file("y.epub", .ebook), file("z.pdf", .ebook),
        ]

        #expect(PathBuilder.fileNames(title: "T", files: files) == [
            "Extras/Map.pdf", "Extras/Map 2.pdf", "Extras/map 3.pdf", "Extras/Map 2 2.pdf",
            "T.epub", "T 2.epub", "T.pdf",
        ])
    }

    @Test func extrasWithoutAnExtensionOrAUsableNameStillGetAGoodName() {
        let files = [file("README", .extra), file(" .pdf", .extra), file("...", .extra)]

        #expect(PathBuilder.fileNames(title: "T", files: files)
            == ["Extras/README", "Extras/Extra.pdf", "Extras/Extra"])
    }

    @Test func seriesFieldsCannotEscapeOrEmptyTheFolder() {
        var m = BookMetadata(title: "Dune", authors: ["A"])
        m.series = ".."
        #expect(PathBuilder.bookFolder(metadata: m) == "A/Dune")
        m.series = "S"
        m.seriesNumber = "../.."
        #expect(PathBuilder.bookFolder(metadata: m) == "A/S/- - Dune")
        m.seriesNumber = " . "
        #expect(PathBuilder.bookFolder(metadata: m) == "A/S/Dune")
    }
}


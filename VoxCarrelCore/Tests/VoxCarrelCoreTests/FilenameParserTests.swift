import Foundation
import Testing
@testable import VoxCarrelCore

@Suite struct FilenameParserTests {
    @Test func authorDashTitleInFileName() {
        let g = FilenameParser.guess(
            from: URL(fileURLWithPath: "/Users/me/Downloads/Andy Weir - Project Hail Mary.m4b"),
            isFolder: false)
        #expect(g.title == "Project Hail Mary")
        #expect(g.author == "Andy Weir")
    }

    @Test func onlyTheFirstDashSplits() {
        let g = FilenameParser.guess(
            from: URL(fileURLWithPath: "/x/Frank Herbert - Dune - Book One.epub"), isFolder: false)
        #expect(g.title == "Dune - Book One")
        #expect(g.author == "Frank Herbert")
    }

    @Test func parentFolderIsTheAuthorForFolderBooks() {
        let g = FilenameParser.guess(
            from: URL(fileURLWithPath: "/Volumes/NAS/Frank Herbert/Dune", isDirectory: true),
            isFolder: true)
        #expect(g.title == "Dune")
        #expect(g.author == "Frank Herbert")
    }

    @Test func genericParentFoldersAreNotAuthors() {
        for parent in ["Downloads", "Desktop", "Documents", "Audiobooks", "Ebooks", "Books"] {
            let g = FilenameParser.guess(
                from: URL(fileURLWithPath: "/Users/me/\(parent)/Dune.epub"), isFolder: false)
            #expect(g.title == "Dune")
            #expect(g.author == nil)
        }
    }

    @Test func folderNamesKeepTheirDots() {
        let g = FilenameParser.guess(
            from: URL(fileURLWithPath: "/x/J.R.R. Tolkien/The Hobbit v1.5", isDirectory: true),
            isFolder: true)
        #expect(g.title == "The Hobbit v1.5")
        #expect(g.author == "J.R.R. Tolkien")
    }

    // MARK: Review fixes

    @Test func fileInAFolderNamedAfterItTakesTheAuthorFromTheGrandparent() {
        for file in ["Dune.m4b", "dune.epub"] {
            let g = FilenameParser.guess(
                from: URL(fileURLWithPath: "/lib/Frank Herbert/Dune/\(file)"), isFolder: false)
            #expect(g.title.lowercased() == "dune")
            #expect(g.author == "Frank Herbert")
        }
    }

    @Test func fileInItsOwnBookFolderTakesTheAuthorFromTheGrandparent() {
        let url = URL(fileURLWithPath: "/lib/Andy Weir/Project Hail Mary/phm.m4b")

        let inBookFolder = FilenameParser.guess(from: url, isFolder: false, parentIsBookFolder: true)
        #expect(inBookFolder.title == "phm")
        #expect(inBookFolder.author == "Andy Weir")

        let inAuthorFolder = FilenameParser.guess(from: url, isFolder: false)
        #expect(inAuthorFolder.author == "Project Hail Mary")
    }

    @Test func genericGrandparentFoldersAreNotAuthors() {
        let named = FilenameParser.guess(
            from: URL(fileURLWithPath: "/Users/me/Downloads/Dune/Dune.m4b"), isFolder: false)
        #expect(named.title == "Dune")
        #expect(named.author == nil)

        let flagged = FilenameParser.guess(
            from: URL(fileURLWithPath: "/Users/me/Audiobooks/Dune/d.m4b"),
            isFolder: false, parentIsBookFolder: true)
        #expect(flagged.author == nil)
    }

    @Test func aNumberBeforeTheDashIsNotAnAuthor() {
        let g = FilenameParser.guess(
            from: URL(fileURLWithPath: "/x/Frank Herbert/01 - Chapter One.mp3"), isFolder: false)
        #expect(g.title == "Chapter One")
        #expect(g.author == "Frank Herbert")

        let generic = FilenameParser.guess(
            from: URL(fileURLWithPath: "/Users/me/Downloads/002 - Dune.m4b"), isFolder: false)
        #expect(generic.title == "Dune")
        #expect(generic.author == nil)
    }
}


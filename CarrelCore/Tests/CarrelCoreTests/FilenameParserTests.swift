import Foundation
import Testing
@testable import CarrelCore

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
}

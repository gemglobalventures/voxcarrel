import Foundation
import Testing
@testable import CarrelCore

@Suite struct ModelsTests {
    @Test func formatIsDetectedFromExtensionIgnoringCase() {
        #expect(FileFormat(url: URL(fileURLWithPath: "/a/Book.M4B")) == .m4b)
        #expect(FileFormat(url: URL(fileURLWithPath: "/a/book.epub")) == .epub)
        #expect(FileFormat(url: URL(fileURLWithPath: "/a/cover.jpg")) == nil)
    }

    @Test func formatsHaveADefaultRole() {
        #expect(FileFormat.m4b.defaultRole == .audio)
        #expect(FileFormat.m4a.defaultRole == .audio)
        #expect(FileFormat.mp3.defaultRole == .audio)
        #expect(FileFormat.epub.defaultRole == .ebook)
        #expect(FileFormat.pdf.defaultRole == .ebook)
        #expect(FileFormat.mobi.defaultRole == .ebook)
        #expect(FileFormat.azw3.defaultRole == .ebook)
    }

    @Test func metadataConvenienceInit() {
        let m = BookMetadata(title: "Dune", authors: ["Frank Herbert"])
        #expect(m.title == "Dune")
        #expect(m.authors == ["Frank Herbert"])
        #expect(m.narrators.isEmpty)
        #expect(m.series == nil)
    }
}

import Foundation
import Testing
import ZIPFoundation
@testable import VoxCarrelCore
import VoxCarrelFixtures

/// DG1–DG3: what a diagnostics report says of a library, and the zip it is saved as.
@Suite struct DiagnosticsTests {
    typealias F = LibraryFixture

    private func library(_ f: F) throws -> (whole: Int64, broken: Int64) {
        let whole = try f.importNew(
            [try f.makeM4B("a.m4b", tags: F.meta("Salt Road", "Ines Calloway"))], F.meta("Salt Road", "Ines Calloway"))
        let broken = try f.importNew([try f.makeEPUB("b.epub")], F.meta("Quiet Rivers", "Ned Marsh"))
        _ = try f.service.addExternalBook(
            metadata: F.meta("Far Shore", "Ola Finch"), cover: nil,
            copy: ExternalCopy(kind: .audible, form: .audio, itemId: "B000000001"))
        try FileManager.default.removeItem(at: f.store.url(for: try #require(try f.store.files(bookId: broken).first)))
        _ = try f.service.reconcile()
        return (whole, broken)
    }

    // DG1: counts, and the books that need attention, with no name of a book, an
    // author or a file anywhere in it.
    @Test func DG1_theReportNamesNothingUnlessAsked() throws {
        let f = try F()
        _ = try library(f)
        let report = try f.service.diagnosticsReport(includingTitles: false)
        #expect(report.contains("Books: 3 (with files here: 2, owned elsewhere only: 1)"))
        #expect(report.contains("Needing attention: 1"))
        #expect(report.contains("by kind: epub 1, m4b 1"))
        #expect(report.contains("Owned elsewhere: audible 1"))
        #expect(report.contains("Folder layout: the standard one"))
        #expect(report.contains("  Book 1: filed"))
        #expect(report.contains("    epub, ebook, missing from disk"))
        for name in ["Salt", "Road", "Ines", "Calloway", "Quiet", "Rivers", "Ned", "Marsh", "Far Shore", "Finch", ".epub", ".m4b", f.root.path] {
            #expect(!report.contains(name), "the report says \(name)")
        }
    }

    // DG2: asked to, it names the books that need attention and their files.
    @Test func DG2_theReportNamesBooksWhenAsked() throws {
        let f = try F()
        _ = try library(f)
        let report = try f.service.diagnosticsReport(includingTitles: true)
        #expect(report.contains("  \"Quiet Rivers\" by Ned Marsh: filed"))
        #expect(report.contains("Quiet Rivers.epub: epub, ebook, missing from disk"))
        // Only what needs attention is named.
        #expect(!report.contains("Salt Road"))
        // The place of the library on this Mac is never in it.
        #expect(!report.contains(f.root.path) && !report.contains(NSHomeDirectory()))
    }

    // DG3: a folder layout the owner wrote is not quoted unless asked.
    @Test func DG3_aLayoutOfTheOwnersIsNotQuoted() throws {
        let f = try F()
        _ = try f.service.applyLayoutChange(to: try FolderPattern("Ines Shelf/{author}/{title}"))
        #expect(try !f.service.diagnosticsReport(includingTitles: false).contains("Ines Shelf"))
        #expect(try f.service.diagnosticsReport(includingTitles: true).contains("Folder layout: Ines Shelf/{author}/{title}"))
    }

    // DG4: the zip holds each text under its name, and takes the place of an older one.
    @Test func DG4_theZipHoldsEachText() throws {
        let f = try F()
        let url = f.base.appendingPathComponent("report.zip")
        try Data("old".utf8).write(to: url)
        try DiagnosticsArchive.write(
            [.init(name: "about.txt", text: "one\n"), .init(name: "library.txt", text: "two ünïcode\n")], to: url)
        let archive = try Archive(url: url, accessMode: .read)
        var read: [String: String] = [:]
        for entry in archive {
            var data = Data()
            _ = try archive.extract(entry) { data.append($0) }
            read[entry.path] = String(decoding: data, as: UTF8.self)
        }
        #expect(read == ["about.txt": "one\n", "library.txt": "two ünïcode\n"])
        // Nothing is left beside it.
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.base.path).filter { $0.hasSuffix(".zip") } == ["report.zip"])
    }
}

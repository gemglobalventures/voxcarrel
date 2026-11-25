import Foundation
import Testing
@testable import VoxCarrelCore
import VoxCarrelFixtures

/// EC1–EC6: an EPUB made of a book's ebook and added beside it.
@Suite struct EbookConversionTests {
    typealias F = LibraryFixture

    /// A converter that makes a real EPUB without running anything, or fails as told.
    final class FakeConverter: EbookConverter, @unchecked Sendable {
        var isAvailable = true
        var failure: ConversionError?
        var writesRubbish = false
        var asked: [(source: URL, destination: URL)] = []

        func convert(_ source: URL, to destination: URL) throws {
            asked.append((source, destination))
            if let failure { throw failure }
            if writesRubbish {
                try Data("not an epub".utf8).write(to: destination)
                return
            }
            _ = try MediaFixtures.makeEPUB3(in: destination.deletingLastPathComponent(), name: destination.lastPathComponent)
        }
    }

    /// A book imported from one file of this kind, with a companion PDF.
    private func book(_ f: F, kind: String = "mobi") throws -> Int64 {
        let file = f.inbox.appendingPathComponent("road.\(kind)")
        try Data("the \(kind) of the long road".utf8).write(to: file)
        let extra = try f.makePDF("map.pdf")
        let result = try f.service.importItems([
            ImportItem(candidate: f.candidate([file, extra], F.meta("The Long Road", "Ann Author"), roles: [extra: .extra])),
        ])
        return try f.importedId(result.outcomes[0])
    }

    @Test func EC1_anEPUBIsAddedBesideTheFileItWasMadeFromWhichIsLeftAsItWas() throws {
        let f = try F()
        let id = try book(f)
        let before = try f.store.files(bookId: id)
        let sourceURL = f.store.url(for: before[0])
        let sourceBytes = try Data(contentsOf: sourceURL)
        let converter = FakeConverter()
        #expect(try f.service.fileToConvert(ofBook: id)?.format == .mobi)

        let done = try f.service.convertToEPUB(bookId: id, with: converter)
        #expect(converter.asked.count == 1 && converter.asked[0].source == sourceURL)
        #expect(done.source.format == .mobi && done.file.format == .epub && done.file.role == .ebook)
        let after = try f.store.files(bookId: id)
        #expect(after.map(\.format) == [.mobi, .pdf, .epub] && after.prefix(2).map(\.path) == before.map(\.path))
        let url = f.store.url(for: done.file)
        #expect(url.lastPathComponent == "The Long Road.epub" && url.deletingLastPathComponent() == sourceURL.deletingLastPathComponent())
        // The book's own details are in it, not the converter's.
        let tags = try f.tags(url)
        #expect(tags.title == "The Long Road" && tags.authors == ["Ann Author"])
        #expect(try Data(contentsOf: sourceURL) == sourceBytes && done.file.contentPrint != nil)
        // Nothing is left where it was made, and the library is whole.
        #expect(!FileManager.default.fileExists(atPath: converter.asked[0].destination.deletingLastPathComponent().path))
        let check = try f.service.reconcile()
        #expect(check.booksWithMissingFiles.isEmpty && check.untrackedFiles.isEmpty)
        // With an EPUB, there is nothing more to convert.
        #expect(try f.service.fileToConvert(ofBook: id) == nil)
        #expect(throws: ConversionError.nothingToConvert) { try f.service.convertToEPUB(bookId: id, with: converter) }
    }

    @Test func EC2_aConverterThatFailsOrMakesNoEPUBLeavesTheBookAsItWas() throws {
        let f = try F()
        let id = try book(f)
        let before = try f.store.files(bookId: id)
        let folder = f.store.url(for: before[0]).deletingLastPathComponent()
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        let converter = FakeConverter()
        for failure in [ConversionError.protected, .failed("It broke."), .tookTooLong] {
            converter.failure = failure
            #expect(throws: failure) { try f.service.convertToEPUB(bookId: id, with: converter) }
        }
        converter.failure = nil
        converter.writesRubbish = true
        #expect(throws: ConversionError.notAnEPUB) { try f.service.convertToEPUB(bookId: id, with: converter) }
        converter.writesRubbish = false
        converter.isAvailable = false
        #expect(throws: ConversionError.noConverter) { try f.service.convertToEPUB(bookId: id, with: converter) }
        #expect(try f.store.files(bookId: id) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == names)
        for asked in converter.asked {
            #expect(!FileManager.default.fileExists(atPath: asked.destination.deletingLastPathComponent().path))
        }
    }

    @Test func EC3_onlyEbooksOfAKindThatConvertsAreOffered() throws {
        #expect(Set(FileFormat.allCases.filter(\.convertsToEPUB)) == [.mobi, .azw3, .azw, .prc, .fb2, .lit, .chm, .djvu])
        let f = try F()
        let converter = FakeConverter()
        // A PDF alone, an audiobook, a book with an EPUB already, a book owned elsewhere.
        let pdf = try f.importedId(try f.service.importItems([ImportItem(candidate: f.candidate([try f.makePDF("p.pdf")], F.meta("Pages", "A")))]).outcomes[0])
        let audio = try f.importedId(try f.service.importItems([ImportItem(candidate: f.candidate([try f.makeM4B("a.m4b", tags: F.meta("Sound", "A"))], F.meta("Sound", "A")))]).outcomes[0])
        let epub = try f.importedId(try f.service.importItems([ImportItem(candidate: f.candidate([try f.makeEPUB("e.epub")], F.meta("Words", "A")))]).outcomes[0])
        let elsewhere = try #require(try f.store.insert(Book(metadata: BookMetadata(title: "Away", authors: ["A"])), files: []).id)
        for id in [pdf, audio, epub, elsewhere] {
            #expect(try f.service.fileToConvert(ofBook: id) == nil)
            #expect(throws: ConversionError.nothingToConvert) { try f.service.convertToEPUB(bookId: id, with: converter) }
        }
        #expect(throws: LibraryError.self) { try f.service.convertToEPUB(bookId: 999, with: converter) }
        #expect(converter.asked.isEmpty)
    }

    @Test func EC4_aNameAlreadyTakenIsNotWrittenOverAndACatalogueThatWillNotChangeLeavesNoFile() throws {
        let f = try F()
        let id = try book(f, kind: "azw3")
        let folder = f.store.url(for: try f.store.files(bookId: id)[0]).deletingLastPathComponent()
        let squatter = folder.appendingPathComponent("the long road.EPUB")
        try Data("mine".utf8).write(to: squatter)
        struct Refused: Error {}
        f.service.beforeCommit = { throw Refused() }
        #expect(throws: Refused.self) { try f.service.convertToEPUB(bookId: id, with: FakeConverter()) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.lowercased().hasSuffix(".epub") } == ["the long road.EPUB"])
        f.service.beforeCommit = nil
        let done = try f.service.convertToEPUB(bookId: id, with: FakeConverter())
        #expect(f.store.url(for: done.file).lastPathComponent == "The Long Road 2.epub")
        #expect(try Data(contentsOf: squatter) == Data("mine".utf8))
    }

    @Test func EC5_whatTheConverterSaysIsReadForWhatWentWrong() {
        #expect(CalibreConverter.error(from: "Traceback\nDRMError: this book has DRM\n") == .protected)
        #expect(CalibreConverter.error(from: "one\n\n  ValueError: bad file  \n\n") == .failed("ValueError: bad file"))
        #expect(CalibreConverter.error(from: "") == .failed("The converter stopped without saying why."))
        let long = String(repeating: "x", count: 900)
        if case .failed(let said) = CalibreConverter.error(from: long) { #expect(said.count == 300) } else { Issue.record("not failed") }
    }

    @Test func EC6_calibresConverterIsFoundOnlyWhereItIsAndRunAsAProgramOfItsOwn() throws {
        let folder = try makeTempDir()
        let none = CalibreConverter(places: [folder.appendingPathComponent("nowhere/ebook-convert")])
        #expect(!none.isAvailable)
        #expect(throws: ConversionError.noConverter) { try none.convert(folder.appendingPathComponent("a.mobi"), to: folder.appendingPathComponent("a.epub")) }
        // A stand-in for the converter: a script given the same two arguments.
        func tool(_ name: String, _ body: String) throws -> URL {
            let url = folder.appendingPathComponent(name)
            try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url
        }
        let source = folder.appendingPathComponent("in.mobi")
        try Data("source".utf8).write(to: source)
        let good = CalibreConverter(places: [try tool("good", "cp \"$1\" \"$2\"")])
        let made = folder.appendingPathComponent("out.epub")
        #expect(good.isAvailable)
        try good.convert(source, to: made)
        #expect(try Data(contentsOf: made) == Data("source".utf8))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("out.log").path))
        let locked = CalibreConverter(places: [try tool("locked", "echo 'DRMError: protected' >&2; exit 1")])
        #expect(throws: ConversionError.protected) { try locked.convert(source, to: folder.appendingPathComponent("l.epub")) }
        let broken = CalibreConverter(places: [try tool("broken", "echo working; echo 'It broke.' >&2; exit 3")])
        #expect(throws: ConversionError.failed("It broke.")) { try broken.convert(source, to: folder.appendingPathComponent("b.epub")) }
        let silent = CalibreConverter(places: [try tool("silent", "exit 0")])
        #expect(throws: ConversionError.self) { try silent.convert(source, to: folder.appendingPathComponent("s.epub")) }
        let slow = CalibreConverter(places: [try tool("slow", "sleep 30")], limit: 0.5)
        #expect(throws: ConversionError.tookTooLong) { try slow.convert(source, to: folder.appendingPathComponent("t.epub")) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".log") || $0.hasSuffix(".epub") } == ["out.epub"])
    }
}

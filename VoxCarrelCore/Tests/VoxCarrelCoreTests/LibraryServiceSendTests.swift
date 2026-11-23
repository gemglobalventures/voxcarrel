import CryptoKit
import Foundation
import GRDB
import Testing
@testable import VoxCarrelCore
import VoxCarrelFixtures
import ZIPFoundation

extension LibraryFixture {
    static let sendChapters: [(start: Double, title: String)] = [(0, "Opening"), (1, "Middle"), (2, "End")]

    /// A single M4B with three chapter marks, imported; returns its id.
    func importChapteredBook(_ title: String = "Marked Book", cover: CoverImage? = nil) throws -> Int64 {
        let url = inbox.appendingPathComponent("\(title).m4b")
        try MediaFixtures.makeChapteredM4B(at: url, seconds: 3, chapters: Self.sendChapters)
        let tags = Self.meta(title, "An Author")
        try io.write(tags, cover: cover.map { .set($0) } ?? .keep, to: url)
        return try importNew([url], tags)
    }

    /// A book of four MP3 parts, imported; returns its id.
    func importFourPartBook(_ title: String = "Four Parts") throws -> Int64 {
        let tags = Self.meta(title, "An Author")
        return try importNew(try makeMP3Parts(folder: title, tags: tags, count: 4), tags)
    }

    func audioURLs(_ bookId: Int64) throws -> [URL] {
        try store.files(bookId: bookId).filter { $0.role == .audio }.map { store.url(for: $0) }
    }

    /// Every file under the library folder with its hash and modification date.
    func libraryState() throws -> [String: String] {
        var state: [String: String] = [:]
        for path in libraryTree() {
            let url = root.appendingPathComponent(path)
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { continue }
            let modified = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
            let stamp = String(modified?.timeIntervalSinceReferenceDate ?? -1)
            if isFolder.boolValue {
                state[path] = "folder " + stamp
            } else {
                let hash = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
                state[path] = hash + " " + stamp
            }
        }
        return state
    }

    func sentRowCount() throws -> Int {
        try store.dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sentRecord") ?? -1 }
    }
}

@Suite struct LibraryServiceSendTests {
    typealias F = LibraryFixture

    func size(_ url: URL) throws -> Int64 {
        try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64)
    }

    /// The entries of a zip, in the order they were stored.
    func entries(_ zip: URL) throws -> [(name: String, stored: Bool, data: Data)] {
        let archive = try Archive(url: zip, accessMode: .read)
        let raw = try Data(contentsOf: zip)
        return try archive.map { entry in
            var data = Data()
            _ = try archive.extract(entry) { data.append($0) }
            // Stored, not compressed: the file's bytes are in the zip as they are.
            let stored = entry.compressedSize == entry.uncompressedSize && raw.range(of: data) != nil
            return (entry.path, stored, data)
        }
    }

    // MARK: SP1 Which files

    @Test func sp1_aSingleFileBookSendsItsOneAudioFile() throws {
        let f = try F()
        let id = try f.importChapteredBook(cover: F.jpeg)
        let check = try f.service.sendCheck(for: id)
        #expect(check.blockers == [])
        #expect(check.files == (try f.audioURLs(id)))
        #expect(check.files.count == 1)
        #expect(!check.needsPackage)
        #expect(check.totalBytes == (try size(check.files[0])))
    }

    @Test func sp1_aBookInPartsSendsThemInPlayingOrder() throws {
        let f = try F()
        let id = try f.importFourPartBook()
        let check = try f.service.sendCheck(for: id)
        let rows = try f.store.files(bookId: id)
        #expect(rows.map(\.position) == [0, 1, 2, 3])
        #expect(check.files == rows.map { f.store.url(for: $0) })
        #expect(check.files.count == 4)
        #expect(check.needsPackage)
        #expect(check.totalBytes == (try check.files.map(size).reduce(0, +)))
    }

    @Test func sp1_playingOrderIsThePositionOrderNotTheNameOrder() throws {
        let f = try F()
        let id = try f.importFourPartBook()
        // The parts play in the reverse of their names.
        var rows = try f.store.files(bookId: id)
        let reversed = Array(rows.reversed())
        for index in rows.indices { rows[index] = reversed[index]; rows[index].position = index }
        try f.store.replaceFiles(bookId: id, files: rows)

        let check = try f.service.sendCheck(for: id)
        #expect(check.files == reversed.map { f.store.url(for: $0) })
        #expect(check.fingerprint.files.map(\.name) == reversed.map { f.store.url(for: $0).lastPathComponent })
    }

    @Test func sp1_ebookAndExtraFilesAreNeverIncluded() throws {
        let f = try F()
        let tags = F.meta("Both Forms", "An Author")
        let audio = try f.makeM4B("both.m4b", tags: tags)
        let ebook = try f.makeEPUB("both.epub")
        let extra = try f.makePDF("map.pdf")
        let result = try f.service.importItems(
            [ImportItem(candidate: f.candidate([audio, ebook, extra], tags, roles: [extra: .extra]), cover: .keep)],
            options: ImportOptions(mode: .move))
        let id = try f.importedId(try #require(result.outcomes.first))
        #expect(try f.store.files(bookId: id).map(\.role) == [.audio, .ebook, .extra])

        let check = try f.service.sendCheck(for: id)
        #expect(check.blockers == [])
        #expect(check.files == (try f.audioURLs(id)))
        #expect(check.files.map(\.pathExtension) == ["m4b"])
        #expect(check.fingerprint.files.count == 1)
        #expect(!check.needsPackage)
    }

    // MARK: SP2 Blockers

    func expectBlocked(_ check: SendCheck, _ blockers: [SendBlocker], sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(check.blockers == blockers, sourceLocation: sourceLocation)
        #expect(check.files == [], sourceLocation: sourceLocation)
        #expect(check.totalBytes == 0, sourceLocation: sourceLocation)
        #expect(check.fingerprint.files == [], sourceLocation: sourceLocation)
        #expect(!check.needsPackage, sourceLocation: sourceLocation)
    }

    @Test func sp2_anAudibleOnlyBookHasNoAudio() throws {
        let f = try F()
        let outcome = try f.service.addExternalBook(
            metadata: F.meta("Only On Audible", "An Author"), cover: nil,
            copy: ExternalCopy(kind: .audible, form: .audio, store: "us", itemId: "B08G9PRS1K"))
        guard case .added(let id) = outcome else {
            Issue.record("expected .added, got \(outcome)")
            return
        }
        expectBlocked(try f.service.sendCheck(for: id), [.noAudio])
    }

    @Test func sp2_anEbookOnlyBookHasNoAudio() throws {
        let f = try F()
        let id = try f.importNew([try f.makeEPUB("text.epub")], F.meta("Text Only", "An Author"))
        expectBlocked(try f.service.sendCheck(for: id), [.noAudio])
    }

    @Test func sp2_eachAudioFileNotOnDiskIsNamed() throws {
        let f = try F()
        let id = try f.importFourPartBook()
        let urls = try f.audioURLs(id)
        try FileManager.default.removeItem(at: urls[1])
        try FileManager.default.removeItem(at: urls[3])
        expectBlocked(
            try f.service.sendCheck(for: id),
            [.missingFile(urls[1].lastPathComponent), .missingFile(urls[3].lastPathComponent)])
    }

    @Test func sp2_aMissingEbookDoesNotBlock() throws {
        let f = try F()
        let tags = F.meta("Both Forms", "An Author")
        let id = try f.importNew([try f.makeM4B("both.m4b", tags: tags), try f.makeEPUB("both.epub")], tags)
        let ebook = try #require(try f.store.files(bookId: id).first { $0.role == .ebook })
        try FileManager.default.removeItem(at: f.store.url(for: ebook))
        #expect(try f.service.sendCheck(for: id).blockers == [])
    }

    @Test func sp2_anAudioFileOfAnotherFormatIsNamed() throws {
        let f = try F()
        let tags = F.meta("Odd Audio", "An Author")
        let id = try f.importNew([try f.makeM4B("odd.m4b", tags: tags), try f.makePDF("odd.pdf")], tags)
        // The catalogue says the PDF is a part of the audio.
        var rows = try f.store.files(bookId: id)
        rows[1].role = .audio
        try f.store.replaceFiles(bookId: id, files: rows)
        let name = f.store.url(for: rows[1]).lastPathComponent
        expectBlocked(try f.service.sendCheck(for: id), [.unsupportedFormat(name)])
    }

    @Test func sp2_m4aAndMp3AndM4bAreSupported() throws {
        let f = try F()
        let tags = F.meta("An M4A", "An Author")
        let id = try f.importNew([try f.makeM4B("one.m4a", tags: tags)], tags)
        #expect(try f.service.sendCheck(for: id).blockers == [])
        #expect(try f.service.sendCheck(for: id).files.map(\.pathExtension) == ["m4a"])
    }

    @Test func sp2_aBookWithFilesButNoFolderIsNotFiled() throws {
        let f = try F()
        let id = try f.importChapteredBook()
        var book = try #require(try f.store.book(id: id))
        book.folderPath = nil
        try f.store.update(book)
        expectBlocked(try f.service.sendCheck(for: id), [.notFiled])
    }

    @Test func sp2_blockersComeInTheInterfaceOrder() throws {
        let f = try F()
        let tags = F.meta("Much Wrong", "An Author")
        let id = try f.importNew(
            try f.makeMP3Parts(folder: "wrong", tags: tags, count: 2) + [try f.makePDF("wrong.pdf")], tags)
        var rows = try f.store.files(bookId: id)
        rows[2].role = .audio
        try f.store.replaceFiles(bookId: id, files: rows)
        try FileManager.default.removeItem(at: f.store.url(for: rows[0]))
        var book = try #require(try f.store.book(id: id))
        book.folderPath = nil
        try f.store.update(book)
        expectBlocked(
            try f.service.sendCheck(for: id),
            [
                .missingFile(f.store.url(for: rows[0]).lastPathComponent),
                .unsupportedFormat(f.store.url(for: rows[2]).lastPathComponent),
                .notFiled,
            ])
    }

    @Test func sp2_anUnknownBookIsAnError() throws {
        let f = try F()
        #expect(throws: LibraryError.bookNotFound(99)) { try f.service.sendCheck(for: 99) }
    }

    // MARK: SP3 Warnings

    @Test func sp3_aSoundBookWithACoverHasNoWarnings() throws {
        let f = try F()
        let id = try f.importChapteredBook(cover: F.jpeg)
        #expect(try f.service.sendCheck(for: id).warnings == [])
    }

    @Test func sp3_filesWithAWrongLengthHeaderAreCounted() throws {
        let f = try F()
        let id = try f.importWrongHeaderBook()
        #expect(try f.service.sendCheck(for: id).warnings == [.wrongLengthHeader(files: 3), .noCoverInFile])
    }

    @Test func sp3_filesWhoseTagsWereNotWrittenAreCounted() throws {
        let f = try F()
        let id = try f.importFourPartBook()
        var rows = try f.store.files(bookId: id)
        rows[0].writeProblem = "The file is locked"
        rows[2].writeProblem = "The file is locked"
        try f.store.replaceFiles(bookId: id, files: rows)
        #expect(try f.service.sendCheck(for: id).warnings == [.tagsNotWritten(files: 2), .noCoverInFile])
    }

    @Test func sp3_noCoverIsWarnedOfOnlyWhenNoAudioFileHoldsOne() throws {
        let f = try F()
        let without = try f.importChapteredBook("No Cover")
        #expect(try f.service.sendCheck(for: without).warnings == [.noCoverInFile])

        // One part of several holding a cover is enough.
        let id = try f.importFourPartBook()
        let urls = try f.audioURLs(id)
        try f.io.write(F.meta("Four Parts", "An Author"), cover: .set(F.jpeg), to: urls[2])
        #expect(try f.service.sendCheck(for: id).warnings == [])
    }

    @Test func sp3_aCoverInTheEbookAloneDoesNotCount() throws {
        let f = try F()
        let tags = F.meta("Both Forms", "An Author")
        // The EPUB fixture has a cover; the audio has none.
        let id = try f.importNew([try f.makeM4B("both.m4b", tags: tags), try f.makeEPUB("both.epub")], tags)
        #expect(try f.service.sendCheck(for: id).warnings == [.noCoverInFile])
    }

    @Test func sp3_anEarlierSendIsWarnedOfWithItsNewestDate() throws {
        let f = try F()
        let id = try f.importChapteredBook(cover: F.jpeg)
        let fingerprint = try f.service.sendCheck(for: id).fingerprint
        let newest = Date(timeIntervalSinceReferenceDate: 800_000_500.25)
        try f.service.recordSent(bookId: id, method: .link, fingerprint: fingerprint, at: newest)
        try f.service.recordSent(
            bookId: id, method: .share, fingerprint: fingerprint, at: Date(timeIntervalSinceReferenceDate: 800_000_000))
        #expect(try f.service.sendCheck(for: id).warnings == [.sentBefore(newest)])
    }

    @Test func sp3_overOneGigabyteIsLarge() throws {
        #expect(LibraryService.largeSendBytes == 1_000_000_000)
        let f = try F()
        let id = try f.importChapteredBook(cover: F.jpeg)
        let bytes = try size(try f.audioURLs(id)[0])

        f.service.sendLargeOver = bytes
        #expect(try f.service.sendCheck(for: id).warnings == [])
        f.service.sendLargeOver = bytes - 1
        #expect(try f.service.sendCheck(for: id).warnings == [.large(bytes: bytes)])
    }

    @Test func sp3_warningsComeInTheInterfaceOrder() throws {
        let f = try F()
        let id = try f.importWrongHeaderBook()
        var rows = try f.store.files(bookId: id)
        rows[1].writeProblem = "The file is locked"
        try f.store.replaceFiles(bookId: id, files: rows)
        let first = try f.service.sendCheck(for: id)
        let date = Date(timeIntervalSinceReferenceDate: 800_000_000)
        try f.service.recordSent(bookId: id, method: .share, fingerprint: first.fingerprint, at: date)
        f.service.sendLargeOver = 10

        #expect(try f.service.sendCheck(for: id).warnings == [
            .wrongLengthHeader(files: 3), .tagsNotWritten(files: 1), .noCoverInFile, .sentBefore(date),
            .large(bytes: first.totalBytes),
        ])
    }

    // MARK: SP4 Fingerprint

    @Test func sp4_aSingleFileIsDescribedWithItsSizeLengthAndChapters() throws {
        let f = try F()
        let id = try f.importChapteredBook()
        let url = try f.audioURLs(id)[0]
        let check = try f.service.sendCheck(for: id)

        let entry = try #require(check.fingerprint.files.first)
        #expect(check.fingerprint.files.count == 1)
        #expect(entry.name == url.lastPathComponent)
        #expect(entry.bytes == (try size(url)))
        #expect(abs(try #require(entry.seconds) - 3) < 0.2)
        // As the metadata layer reads them.
        let read = try f.io.read(url).chapters
        #expect(read.count == 3)
        #expect(entry.chapters == read.map { SentChapter(start: $0.start, title: $0.title) })
        #expect(entry.chapters.map(\.title) == ["Opening", "Middle", "End"])
    }

    @Test func sp4_eachPartHasAnEntryInPlayingOrder() throws {
        let f = try F()
        let id = try f.importFourPartBook()
        let urls = try f.audioURLs(id)
        let fingerprint = try f.service.sendCheck(for: id).fingerprint
        #expect(fingerprint.files.map(\.name) == urls.map(\.lastPathComponent))
        #expect(fingerprint.files.map(\.bytes) == (try urls.map(size)))
        #expect(fingerprint.files.allSatisfy { $0.chapters.isEmpty })
        for entry in fingerprint.files { #expect(abs(try #require(entry.seconds) - 1) < 0.1) }
    }

    @Test func sp4_anMP3WithAWrongHeaderHasItsMeasuredLength() throws {
        let f = try F()
        let id = try f.importWrongHeaderBook()
        let fingerprint = try f.service.sendCheck(for: id).fingerprint
        #expect(fingerprint.files.count == 3)
        for entry in fingerprint.files {
            #expect(abs(try #require(entry.seconds) - LibraryServiceLengthTests.trueSeconds) < 0.01)
        }
    }

    @Test func sp4_aFileWhoseTagsCannotBeReadHasNoLengthAndNoChapters() throws {
        let f = try F()
        let id = try f.importFourPartBook()
        let urls = try f.audioURLs(id)
        try Data("this is not audio at all".utf8).write(to: urls[1])

        let check = try f.service.sendCheck(for: id)
        #expect(check.blockers == [])
        #expect(check.files == urls)
        let entry = check.fingerprint.files[1]
        #expect(entry == SentFile(name: urls[1].lastPathComponent, bytes: 24, seconds: nil, chapters: []))
        #expect(check.fingerprint.files[0].seconds != nil)
    }

    @Test func sp4_theFingerprintSurvivesBeingStored() throws {
        let fingerprint = SendFingerprint(files: [
            SentFile(name: "a.m4b", bytes: 5_000_000_000, seconds: 12.5, chapters: [SentChapter(start: 0, title: "One")]),
            SentFile(name: "b.mp3", bytes: 3, seconds: nil, chapters: []),
        ])
        let data = try JSONEncoder().encode(fingerprint)
        #expect(try JSONDecoder().decode(SendFingerprint.self, from: data) == fingerprint)
    }

    // MARK: SP5 The package

    @Test func sp5_oneFileIsReturnedAsItIs() throws {
        let f = try F()
        let id = try f.importChapteredBook()
        let before = try f.libraryState()
        let folder = try makeTempDir()

        let check = try f.service.sendCheck(for: id)
        let package = try f.service.makeSendPackage(for: check, in: folder)

        #expect(package == (try f.audioURLs(id)[0]))
        #expect(tree(folder) == [])
        #expect(try f.libraryState() == before)
    }

    @Test func sp5_severalFilesBecomeOneStoredZipInPlayingOrder() throws {
        let f = try F()
        let id = try f.importFourPartBook()
        let urls = try f.audioURLs(id)
        let before = try f.libraryState()
        let folder = try makeTempDir()

        let check = try f.service.sendCheck(for: id)
        let package = try f.service.makeSendPackage(for: check, in: folder)

        #expect(check.packageName == "Four Parts.zip")
        #expect(package.standardizedFileURL.path == folder.appendingPathComponent("Four Parts.zip").standardizedFileURL.path)
        #expect(tree(folder) == ["Four Parts.zip"])
        let stored = try entries(package)
        #expect(stored.map(\.name) == urls.map(\.lastPathComponent))
        #expect(stored.allSatisfy { $0.stored })
        #expect(stored.map(\.data) == (try urls.map { try Data(contentsOf: $0) }))
        // Nothing in the library has changed: not a byte, not a date, not a name.
        #expect(try f.libraryState() == before)
    }

    @Test func sp5_aFolderInsideTheLibraryIsRefused() throws {
        let f = try F()
        let id = try f.importFourPartBook()
        let check = try f.service.sendCheck(for: id)
        let before = try f.libraryState()
        let inside = try #require(try f.audioURLs(id).first).deletingLastPathComponent()

        #expect(throws: SendError.folderInsideLibrary) { try f.service.makeSendPackage(for: check, in: inside) }
        #expect(throws: SendError.folderInsideLibrary) { try f.service.makeSendPackage(for: check, in: f.root) }
        #expect(throws: SendError.folderInsideLibrary) {
            try f.service.makeSendPackage(for: check, in: f.root.appendingPathComponent("Not There Yet"))
        }
        // However the folder is spelled.
        let spelled = f.base.appendingPathComponent("Inbox/../Library/An Author")
        #expect(throws: SendError.folderInsideLibrary) { try f.service.makeSendPackage(for: check, in: spelled) }
        #expect(try f.libraryState() == before)
        #expect(!f.libraryTree().contains { $0.hasSuffix(".zip") || $0.contains("Not There Yet") })
    }

    @Test func sp5_aFolderReachedThroughALinkIntoTheLibraryIsRefused() throws {
        let f = try F()
        let id = try f.importFourPartBook()
        let check = try f.service.sendCheck(for: id)
        let link = f.base.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.root.appendingPathComponent("An Author"))
        #expect(throws: SendError.folderInsideLibrary) { try f.service.makeSendPackage(for: check, in: link) }
        #expect(!f.libraryTree().contains { $0.hasSuffix(".zip") })
    }

    @Test func sp5_aBlockedCheckMakesNoPackage() throws {
        let f = try F()
        let id = try f.importFourPartBook()
        try FileManager.default.removeItem(at: try f.audioURLs(id)[0])
        let check = try f.service.sendCheck(for: id)
        let folder = try makeTempDir()
        #expect(throws: SendError.nothingToSend) { try f.service.makeSendPackage(for: check, in: folder) }
        #expect(tree(folder) == [])
    }

    @Test func sp5_anExistingFileOfThePackagesNameIsNotReplaced() throws {
        let f = try F()
        let id = try f.importFourPartBook()
        let check = try f.service.sendCheck(for: id)
        let folder = try makeTempDir()
        try Data("mine".utf8).write(to: folder.appendingPathComponent("Four Parts.zip"))

        #expect(throws: SendError.packageExists("Four Parts.zip")) {
            try f.service.makeSendPackage(for: check, in: folder)
        }
        #expect(tree(folder) == ["Four Parts.zip"])
        #expect(try read(folder.appendingPathComponent("Four Parts.zip")) == "mine")
    }

    @Test func sp5_aPackageNameThatIsAPathIsRefused() throws {
        let f = try F()
        let id = try f.importFourPartBook()
        var check = try f.service.sendCheck(for: id)
        let folder = try makeTempDir().appendingPathComponent("inner", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["../escaped.zip", "a/b.zip", "..", ".", ""] {
            check.packageName = name
            #expect(throws: SendError.badPackageName) { try f.service.makeSendPackage(for: check, in: folder) }
        }
        #expect(tree(folder.deletingLastPathComponent()) == ["inner"])
    }

    // MARK: SP6 Failure

    @Test func sp6_aZipThatFailsPartWayLeavesNothingBehind() throws {
        let f = try F()
        let id = try f.importFourPartBook()
        let check = try f.service.sendCheck(for: id)
        // The third part goes after the check.
        try FileManager.default.removeItem(at: check.files[2])
        let before = try f.libraryState()
        let folder = try makeTempDir()

        #expect(throws: (any Error).self) { try f.service.makeSendPackage(for: check, in: folder) }
        #expect(tree(folder) == [])
        #expect(try f.libraryState() == before)
    }

    @Test func sp6_twoFilesOfOneNameCannotGoInOneZip() throws {
        let f = try F()
        let id = try f.importFourPartBook()
        var check = try f.service.sendCheck(for: id)
        // Cannot happen for a filed book: a file of the same name from another folder.
        let other = f.base.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let twin = other.appendingPathComponent(check.files[0].lastPathComponent.uppercased())
        try FileManager.default.copyItem(at: check.files[0], to: twin)
        check.files[3] = twin
        let folder = try makeTempDir()

        #expect(throws: SendError.nameClash(twin.lastPathComponent)) {
            try f.service.makeSendPackage(for: check, in: folder)
        }
        #expect(tree(folder) == [])
    }

    @Test func sp6_aLinkInPlaceOfAFileIsNotPackaged() throws {
        let f = try F()
        let id = try f.importFourPartBook()
        let check = try f.service.sendCheck(for: id)
        let secret = f.base.appendingPathComponent("secret.txt")
        try Data("secret".utf8).write(to: secret)
        try FileManager.default.removeItem(at: check.files[1])
        try FileManager.default.createSymbolicLink(at: check.files[1], withDestinationURL: secret)
        let folder = try makeTempDir()

        #expect(throws: SendError.notARegularFile(check.files[1].lastPathComponent)) {
            try f.service.makeSendPackage(for: check, in: folder)
        }
        #expect(tree(folder) == [])
    }

    // MARK: SP7 The package's name

    @Test func sp7_thePackageIsNamedAfterTheTitleMadeSafe() throws {
        #expect(LibraryService.sendPackageName(title: "Dune") == "Dune.zip")
        #expect(LibraryService.sendPackageName(title: "Dune: Messiah / Part 1") == "Dune- Messiah - Part 1.zip")
        #expect(LibraryService.sendPackageName(title: "..hidden. ") == "hidden.zip")
        #expect(LibraryService.sendPackageName(title: "What?") == PathBuilder.sanitise("What?") + ".zip")
    }

    @Test func sp7_aTitleThatSanitisesToNothingGivesAudiobook() throws {
        #expect(LibraryService.sendPackageName(title: "") == "Audiobook.zip")
        #expect(LibraryService.sendPackageName(title: " . .. ") == "Audiobook.zip")
        #expect(LibraryService.sendPackageName(title: "\u{0007}") == "Audiobook.zip")
    }

    @Test func sp7_aVeryLongTitleStillGivesANameTheDiskAccepts() throws {
        let name = LibraryService.sendPackageName(title: String(repeating: "ß€", count: 150))
        #expect(name.hasSuffix(".zip"))
        #expect(name.utf8.count <= 255)
        let folder = try makeTempDir()
        try Data().write(to: folder.appendingPathComponent(name))
    }

    @Test func sp7_theCheckCarriesTheNameForItsBook() throws {
        let f = try F()
        let tags = F.meta("Dune: Messiah", "Frank Herbert")
        let id = try f.importNew(try f.makeMP3Parts(folder: "dune", tags: tags, count: 2), tags)
        #expect(try f.service.sendCheck(for: id).packageName == "Dune- Messiah.zip")
        // A single-file book has the name too, though it is not used.
        let single = try f.importChapteredBook()
        #expect(try f.service.sendCheck(for: single).packageName == "Marked Book.zip")
    }

    // MARK: SP8 The record

    @Test func sp8_sendsAreRecordedAndReturnedNewestFirst() throws {
        let f = try F()
        let id = try f.importChapteredBook()
        let other = try f.importFourPartBook()
        let fingerprint = try f.service.sendCheck(for: id).fingerprint
        let otherFingerprint = try f.service.sendCheck(for: other).fingerprint
        func date(_ seconds: Double) -> Date { Date(timeIntervalSinceReferenceDate: seconds) }
        #expect(try f.service.sentRecords(for: id) == [])

        try f.service.recordSent(bookId: id, method: .share, fingerprint: fingerprint, at: date(800_000_100.125))
        try f.service.recordSent(bookId: id, method: .link, fingerprint: fingerprint, at: date(800_000_300.5))
        try f.service.recordSent(bookId: id, method: .share, fingerprint: fingerprint, at: date(800_000_200))
        try f.service.recordSent(bookId: other, method: .link, fingerprint: otherFingerprint, at: date(800_000_900))

        #expect(try f.service.sentRecords(for: id) == [
            SentRecord(bookId: id, sentAt: date(800_000_300.5), method: .link, fingerprint: fingerprint),
            SentRecord(bookId: id, sentAt: date(800_000_200), method: .share, fingerprint: fingerprint),
            SentRecord(bookId: id, sentAt: date(800_000_100.125), method: .share, fingerprint: fingerprint),
        ])
        #expect(try f.service.sentRecords(for: other) == [
            SentRecord(bookId: other, sentAt: date(800_000_900), method: .link, fingerprint: otherFingerprint),
        ])
        #expect(try f.service.sentRecords(for: 999) == [])
    }

    @Test func sp8_twoSendsAtOneMomentComeLastRecordedFirst() throws {
        let f = try F()
        let id = try f.importChapteredBook()
        let fingerprint = try f.service.sendCheck(for: id).fingerprint
        let date = Date(timeIntervalSinceReferenceDate: 800_000_000)
        try f.service.recordSent(bookId: id, method: .share, fingerprint: fingerprint, at: date)
        try f.service.recordSent(bookId: id, method: .link, fingerprint: fingerprint, at: date)
        #expect(try f.service.sentRecords(for: id).map(\.method) == [.link, .share])
    }

    @Test func sp8_aSendOfAnUnknownBookIsNotRecorded() throws {
        let f = try F()
        #expect(throws: LibraryError.bookNotFound(42)) {
            try f.service.recordSent(bookId: 42, method: .share, fingerprint: SendFingerprint(files: []), at: Date())
        }
        #expect(try f.sentRowCount() == 0)
    }

    @Test func sp8_removingTheBookRemovesItsRecords() throws {
        let f = try F()
        let id = try f.importChapteredBook()
        let other = try f.importFourPartBook()
        let fingerprint = try f.service.sendCheck(for: id).fingerprint
        try f.service.recordSent(bookId: id, method: .share, fingerprint: fingerprint, at: Date())
        try f.service.recordSent(bookId: id, method: .link, fingerprint: fingerprint, at: Date())
        try f.service.recordSent(bookId: other, method: .link, fingerprint: fingerprint, at: Date())
        #expect(try f.sentRowCount() == 3)

        try f.service.removeBook(id: id, moveFilesToTrash: false)

        #expect(try f.sentRowCount() == 1)
        #expect(try f.service.sentRecords(for: id) == [])
        #expect(try f.service.sentRecords(for: other).count == 1)
    }

    @Test func sp8_recordingIsNotJournaledAndUndoOfSomethingElseLeavesIt() throws {
        let f = try F()
        let id = try f.importChapteredBook()
        let fingerprint = try f.service.sendCheck(for: id).fingerprint
        // An unrelated operation, the one that undo would reverse.
        let other = try f.importFourPartBook()
        let label = try #require(try f.service.undoLabel())
        let batch = try #require(try f.store.lastBatch())

        try f.service.recordSent(bookId: id, method: .share, fingerprint: fingerprint, at: Date(timeIntervalSinceReferenceDate: 1))

        #expect(try f.service.undoLabel() == label)
        #expect(try f.store.lastBatch() == batch)
        let record = try f.service.sentRecords(for: id)
        #expect(record.count == 1)

        #expect(try f.service.undoLast() == label)
        #expect(try f.store.book(id: other) == nil)
        #expect(try f.service.sentRecords(for: id) == record)
        #expect(try f.service.undoLabel() == nil)
    }

    @Test func sp8_savingABooksDetailsKeepsItsRecords() throws {
        let f = try F()
        let id = try f.importChapteredBook()
        let fingerprint = try f.service.sendCheck(for: id).fingerprint
        try f.service.recordSent(bookId: id, method: .link, fingerprint: fingerprint, at: Date(timeIntervalSinceReferenceDate: 5))
        let record = try f.service.sentRecords(for: id)

        _ = try f.service.repairLengthHeaders(for: [id])
        try f.store.setReadStatus(.finished, for: [id])
        var rows = try f.store.files(bookId: id)
        rows[0].writeProblem = "x"
        try f.store.replaceFiles(bookId: id, files: rows)

        #expect(try f.service.sentRecords(for: id) == record)
    }

    @Test func sp8_aRecordThatCannotBeReadIsLeftOutNotAnError() throws {
        let f = try F()
        let id = try f.importChapteredBook()
        let fingerprint = try f.service.sendCheck(for: id).fingerprint
        try f.service.recordSent(bookId: id, method: .link, fingerprint: fingerprint, at: Date(timeIntervalSinceReferenceDate: 5))
        try f.store.dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO sentRecord (bookId, sentAt, method, fingerprint) VALUES (?, 9, 'carrier pigeon', '{}')",
                arguments: [id])
        }
        #expect(try f.service.sentRecords(for: id).map(\.method) == [.link])
        // The warning goes by the newest record that can be read.
        #expect(try f.service.sendCheck(for: id).warnings.contains(.sentBefore(Date(timeIntervalSinceReferenceDate: 5))))
    }

    // MARK: SP9 Migration

    @Test func sp9_aV10LibraryOpensAndItsTablesAreUntouched() throws {
        let root = try makeTempDir()
        let path = root.appendingPathComponent(LibraryStore.databaseFileName).path
        let tables = [
            "book", "bookFile", "collection", "collectionBook", "operationBatch", "operationMove", "libraryNote",
            "watchFolder", "inboxEntry", "seriesLink", "seriesEntry", "librarySetting",
        ]
        func rows(_ db: Database) throws -> [String: [Row]] {
            var all: [String: [Row]] = [:]
            for table in tables { all[table] = try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY rowid") }
            return all
        }
        func schema(_ db: Database) throws -> [String] {
            try String.fetchAll(
                db, sql: "SELECT sql FROM sqlite_master WHERE tbl_name IN (\(tables.map { "'\($0)'" }.joined(separator: ","))) AND sql IS NOT NULL ORDER BY name")
        }
        var before: [String: [Row]] = [:]
        var schemaBefore: [String] = []
        do {
            let queue = try DatabaseQueue(path: path)
            try LibraryStore.migrator.migrate(queue, upTo: "v10")
            try queue.write { db in
                try db.execute(sql: """
                    INSERT INTO book (title, authors, narrators, series, seriesNumber, tags, rating, needsAttention,
                                      folderPath, durationSeconds, dateAdded, readStatus, appOnlyFields, externalCopies,
                                      editionKind, partsAppearMissing)
                    VALUES ('Patriot Games', '["Tom Clancy"]', '[]', 'Jack Ryan', '2', '["kept"]', 4, 0,
                            'Tom Clancy/Patriot Games', 4368.5, '2025-01-02 03:04:05.000', 'finished', '[]', '[]', NULL, 1);
                    INSERT INTO bookFile (bookId, path, format, role, position)
                    VALUES (1, 'Tom Clancy/Patriot Games/Patriot Games.m4b', 'm4b', 'audio', 0);
                    INSERT INTO collection (name) VALUES ('To Read');
                    INSERT INTO collectionBook (collectionId, bookId) VALUES (1, 1);
                    INSERT INTO operationBatch (label, createdAt) VALUES ('Import 1 Book', '2025-01-02 03:04:05.000');
                    INSERT INTO operationMove (batchId, fromPath, toPath, wasCopy) VALUES (1, '/from', '/to', 0);
                    INSERT INTO libraryNote (key, value) VALUES ('lengthHeadersChecked', '1');
                    INSERT INTO watchFolder (path, mode, isEnabled, includesPDFs, addedAt)
                    VALUES ('/somewhere/watched', 'move', 1, 0, 700000000.25);
                    INSERT INTO inboxEntry (folderId, path, size, modifiedAt, state)
                    VALUES (1, '/somewhere/watched/a.m4b', 10, 700000000.5, 'dismissed');
                    INSERT INTO seriesLink (seriesKey, seriesName, audibleSeriesId, audibleSeriesTitle, store, checkedAt)
                    VALUES ('Jack Ryan', 'Jack Ryan', 'B00SERIES', 'Jack Ryan', 'us', 700000001.5);
                    INSERT INTO seriesEntry (linkId, position, number, sort, title, asins, titles, authors, narrators)
                    VALUES (1, 0, '2', 2.0, 'Patriot Games', '["B00"]', '["Patriot Games"]', '["Tom Clancy"]', '[]');
                    INSERT INTO librarySetting (key, value) VALUES ('folderPattern', '{Author}/{Title}');
                    """)
                before = try rows(db)
                schemaBefore = try schema(db)
                let hasTable = try db.tableExists("sentRecord")
                #expect(!hasTable)
            }
        }

        let store = try LibraryStore(libraryRoot: root)
        let service = LibraryService(store: store)

        try store.dbQueue.read { db in
            let rowsAfter = try rows(db)
            let schemaAfter = try schema(db)
            let columns = try db.columns(in: "sentRecord").map(\.name)
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sentRecord")
            #expect(rowsAfter == before)
            #expect(schemaAfter == schemaBefore)
            #expect(columns == ["id", "bookId", "sentAt", "method", "fingerprint"])
            #expect(count == 0)
        }
        // The migrated library records a send of the book it already had.
        let fingerprint = SendFingerprint(files: [SentFile(name: "Patriot Games.m4b", bytes: 5, seconds: 4368.5, chapters: [])])
        let date = Date(timeIntervalSinceReferenceDate: 800_000_000)
        try service.recordSent(bookId: 1, method: .link, fingerprint: fingerprint, at: date)
        #expect(try service.sentRecords(for: 1) == [SentRecord(bookId: 1, sentAt: date, method: .link, fingerprint: fingerprint)])
        try store.dbQueue.read { db in
            let rowsAfter = try rows(db)
            #expect(rowsAfter == before)
        }
    }

    // MARK: SP10 The check changes nothing

    @Test func sp10_theCheckChangesNothingOnDiskOrInTheCatalogue() throws {
        let f = try F()
        let ids = [try f.importChapteredBook(), try f.importFourPartBook(), try f.importWrongHeaderBook()]
        try f.service.recordSent(
            bookId: ids[0], method: .share, fingerprint: SendFingerprint(files: []), at: Date(timeIntervalSinceReferenceDate: 3))
        func catalogue() throws -> [String] {
            try f.store.dbQueue.read { db in
                try ["book", "bookFile", "operationBatch", "operationMove", "libraryNote", "librarySetting", "sentRecord"]
                    .flatMap { table in
                        try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY rowid").map { "\(table): \($0)" }
                    }
            }
        }
        let disk = try f.libraryState()
        let hidden = f.hiddenTree()
        let rows = try catalogue()
        let label = try f.service.undoLabel()

        for id in ids {
            let check = try f.service.sendCheck(for: id)
            #expect(check.blockers == [])
            #expect(try f.service.sendCheck(for: id) == check)
        }

        #expect(try f.libraryState() == disk)
        #expect(f.hiddenTree() == hidden)
        #expect(try catalogue() == rows)
        #expect(try f.service.undoLabel() == label)
    }

    @Test func sp10_theCheckAndThePackageAreRefusedWhileALayoutChangeIsUnresolved() throws {
        let f = try F()
        let id = try f.importFourPartBook()
        let check = try f.service.sendCheck(for: id)
        try FileManager.default.createDirectory(at: f.service.layout.hiddenFolder, withIntermediateDirectories: true)
        try Data("not a record".utf8).write(to: f.service.layoutIntentURL)
        #expect(f.service.hasInterruptedLayoutChange)
        let folder = try makeTempDir()

        #expect(throws: LibraryError.layoutChangeInterrupted) { try f.service.sendCheck(for: id) }
        #expect(throws: LibraryError.layoutChangeInterrupted) { try f.service.makeSendPackage(for: check, in: folder) }
        #expect(tree(folder) == [])
    }
}

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import VoxCarrelCore
import VoxCarrelFixtures
import ZIPFoundation

/// Pictures made for these tests, and ways of looking at a picture.
enum CoverPictures {
    /// A picture of one colour with a border of another, a tenth of its shorter side wide.
    static func make(
        width: Int, height: Int, type: UTType = .jpeg, edge: (CGFloat, CGFloat, CGFloat) = (0.1, 0.2, 0.9),
        middle: (CGFloat, CGFloat, CGFloat) = (0.9, 0.8, 0.1)
    ) -> CoverImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: edge.0, green: edge.1, blue: edge.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: middle.0, green: middle.1, blue: middle.2, alpha: 1))
        let border = min(width, height) / 10
        context.fill(CGRect(x: border, y: border, width: width - 2 * border, height: height - 2 * border))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(
            destination, context.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        CGImageDestinationFinalize(destination)
        return CoverImage(data: data as Data, mime: type == .png ? "image/png" : "image/jpeg")
    }

    static func size(_ image: CoverImage) -> [Int]? {
        guard let source = CGImageSourceCreateWithData(image.data as CFData, nil),
              let picture = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return [picture.width, picture.height]
    }

    /// The colour at a point, counted from the top left, as red, green and blue from 0 to 255.
    static func colour(_ image: CoverImage, x: Int, y: Int) -> [Int]? {
        guard let source = CGImageSourceCreateWithData(image.data as CFData, nil),
              let picture = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        var pixels = [UInt8](repeating: 0, count: picture.width * picture.height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: picture.width, height: picture.height, bitsPerComponent: 8,
                bytesPerRow: picture.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            context.draw(picture, in: CGRect(x: 0, y: 0, width: picture.width, height: picture.height))
            return true
        }
        guard drawn else { return nil }
        let at = (y * picture.width + x) * 4
        return [Int(pixels[at]), Int(pixels[at + 1]), Int(pixels[at + 2])]
    }

    static func near(_ a: [Int]?, _ b: [Int], within: Int = 12) -> Bool {
        guard let a, a.count == b.count else { return false }
        return zip(a, b).allSatisfy { abs($0 - $1) <= within }
    }

    /// The sound itself of an M4B or M4A: what its `mdat` box holds.
    static func mediaData(_ url: URL) throws -> Data {
        let data = try Data(contentsOf: url)
        var at = 0
        while at + 8 <= data.count {
            var size = Int(data[at]) << 24 | Int(data[at + 1]) << 16 | Int(data[at + 2]) << 8 | Int(data[at + 3])
            let type = String(decoding: data[(at + 4)..<(at + 8)], as: UTF8.self)
            var header = 8
            if size == 1 {
                size = data[(at + 8)..<(at + 16)].reduce(0) { $0 << 8 | Int($1) }
                header = 16
            } else if size == 0 {
                size = data.count - at
            }
            if type == "mdat" { return data.subdata(in: (at + header)..<(at + size)) }
            at += size
        }
        throw Boom()
    }

    /// The frames of an MP3: everything after its ID3v2 tag.
    static func frames(_ url: URL) throws -> Data {
        let data = try Data(contentsOf: url)
        guard data.count > 10, data.prefix(3) == Data("ID3".utf8) else { return data }
        let size = Int(data[6]) << 21 | Int(data[7]) << 14 | Int(data[8]) << 7 | Int(data[9])
        return data.subdata(in: (10 + size)..<data.count)
    }
}

@Suite struct LibraryServiceSendCoverTests {
    typealias F = LibraryFixture
    typealias P = CoverPictures
    static let tall = P.make(width: 200, height: 300)
    static let square = SendOptions(squareCover: true)

    /// A single chaptered M4B holding `cover`, imported.
    func importSingle(_ f: F, cover: CoverImage?) throws -> Int64 {
        try f.importChapteredBook("Marked Book", cover: cover)
    }

    /// Four MP3 parts each holding `cover`, imported.
    func importParts(_ f: F, cover: CoverImage?) throws -> Int64 {
        let tags = F.meta("Four Parts", "An Author")
        let urls = try f.makeMP3Parts(folder: "parts", tags: tags, count: 4)
        if let cover { for url in urls { try f.io.write(tags, cover: .set(cover), to: url) } }
        return try f.importNew(urls, tags)
    }

    func size(_ url: URL) throws -> Int64 {
        try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64)
    }

    // MARK: SP11 Is the cover square

    @Test func sp11_theCheckSaysWhetherTheCoverIsSquare() throws {
        let f = try F()
        #expect(try f.service.sendCheck(for: try importSingle(f, cover: Self.tall)).coverIsSquare == false)
        let g = try F()
        #expect(try g.service.sendCheck(for: try importSingle(g, cover: F.jpeg)).coverIsSquare == true)
        let h = try F()
        #expect(try h.service.sendCheck(for: try importSingle(h, cover: nil)).coverIsSquare == nil)
    }

    @Test func sp11_within2PercentCountsAsSquare() throws {
        #expect(CoverSquaring.isSquare(width: 500, height: 500))
        #expect(CoverSquaring.isSquare(width: 500, height: 490))
        #expect(CoverSquaring.isSquare(width: 490, height: 500))
        #expect(!CoverSquaring.isSquare(width: 500, height: 489))
        #expect(!CoverSquaring.isSquare(width: 489, height: 500))
        #expect(!CoverSquaring.isSquare(width: 0, height: 0))
        let f = try F()
        let nearly = P.make(width: 300, height: 295)
        #expect(try f.service.sendCheck(for: try importSingle(f, cover: nearly)).coverIsSquare == true)
    }

    @Test func sp11_itIsTheFirstAudioFilesCoverThatCounts() throws {
        let f = try F()
        let id = try importParts(f, cover: nil)
        let urls = try f.audioURLs(id)
        let tags = F.meta("Four Parts", "An Author")
        try f.io.write(tags, cover: .set(F.jpeg), to: urls[0])
        try f.io.write(tags, cover: .set(Self.tall), to: urls[2])
        #expect(try f.service.sendCheck(for: id).coverIsSquare == true)
        // With none in the first, the first that holds one.
        try f.io.write(tags, cover: .remove, to: urls[0])
        #expect(try f.service.sendCheck(for: id).coverIsSquare == false)
    }

    @Test func sp11_aBlockedCheckSaysNothingOfTheCover() throws {
        let f = try F()
        let id = try importSingle(f, cover: Self.tall)
        try FileManager.default.removeItem(at: try f.audioURLs(id)[0])
        #expect(try f.service.sendCheck(for: id).coverIsSquare == nil)
    }

    // MARK: SP12 Squaring

    @Test func sp12_aTallCoverIsCentredOnASquareWithBarsOfItsEdgeColour() throws {
        let squared = try #require(CoverSquaring.squared(Self.tall))
        #expect(squared.mime == "image/jpeg")
        #expect(CoverImage.sniffedMIME(squared.data) == "image/jpeg")
        #expect(P.size(squared) == [300, 300])
        let edge = try #require(P.colour(Self.tall, x: 3, y: 150))
        let middle = try #require(P.colour(Self.tall, x: 100, y: 150))
        #expect(!P.near(edge, middle, within: 100))
        // The bars, left and right, in the colour of the cover's edge.
        #expect(P.near(P.colour(squared, x: 10, y: 150), edge))
        #expect(P.near(P.colour(squared, x: 290, y: 20), edge))
        #expect(P.near(P.colour(squared, x: 40, y: 290), edge))
        // The cover in the middle, whole: from its top to its bottom, 200 wide from 50.
        #expect(P.near(P.colour(squared, x: 150, y: 150), middle))
        #expect(P.near(P.colour(squared, x: 150, y: 30), middle))
        #expect(P.near(P.colour(squared, x: 150, y: 270), middle))
        #expect(P.near(P.colour(squared, x: 80, y: 150), middle))
        #expect(P.near(P.colour(squared, x: 220, y: 150), middle))
        // Its own border is still there, top and bottom: nothing was cut off.
        #expect(P.near(P.colour(squared, x: 150, y: 3), edge))
        #expect(P.near(P.colour(squared, x: 150, y: 296), edge))
    }

    @Test func sp12_aWideCoverGetsBarsAboveAndBelow() throws {
        let wide = P.make(width: 400, height: 100, type: .png)
        let squared = try #require(CoverSquaring.squared(wide))
        #expect(squared.mime == "image/jpeg")
        #expect(P.size(squared) == [400, 400])
        let edge = try #require(P.colour(wide, x: 200, y: 3))
        let middle = try #require(P.colour(wide, x: 200, y: 50))
        #expect(P.near(P.colour(squared, x: 200, y: 20), edge))
        #expect(P.near(P.colour(squared, x: 200, y: 380), edge))
        #expect(P.near(P.colour(squared, x: 200, y: 200), middle))
        #expect(P.near(P.colour(squared, x: 20, y: 200), middle))
        #expect(P.near(P.colour(squared, x: 380, y: 200), middle))
        #expect(P.near(P.colour(squared, x: 3, y: 200), edge))
    }

    @Test func sp12_aLargeCoverIsScaledDownTo1400() throws {
        let large = P.make(width: 2000, height: 3000)
        let squared = try #require(CoverSquaring.squared(large))
        #expect(P.size(squared) == [1400, 1400])
        let edge = try #require(P.colour(large, x: 1000, y: 20))
        let middle = try #require(P.colour(large, x: 1000, y: 1500))
        // Not cropped: the border's colour is still at the top and bottom of the cover.
        #expect(P.near(P.colour(squared, x: 700, y: 20), edge))
        #expect(P.near(P.colour(squared, x: 700, y: 1380), edge))
        #expect(P.near(P.colour(squared, x: 100, y: 700), edge))
        #expect(P.near(P.colour(squared, x: 700, y: 700), middle))
        #expect(CoverSquaring.maxSide == 1400)
        // One exactly at the limit keeps its size.
        #expect(P.size(try #require(CoverSquaring.squared(P.make(width: 700, height: 1400)))) == [1400, 1400])
    }

    @Test func sp12_aSquareCoverOrOneThatCannotBeReadGivesNothing() {
        #expect(CoverSquaring.squared(F.jpeg) == nil)
        #expect(CoverSquaring.squared(P.make(width: 500, height: 492)) == nil)
        #expect(CoverSquaring.squared(CoverImage(data: Data("not a picture".utf8), mime: "image/jpeg")) == nil)
        #expect(CoverSquaring.squared(CoverImage(data: Data(), mime: "image/png")) == nil)
    }

    // MARK: SP13 The copy

    @Test func sp13_aSingleFileIsSentAsACopyWithTheSquaredCover() async throws {
        let f = try F()
        let id = try importSingle(f, cover: Self.tall)
        let original = try f.audioURLs(id)[0]
        let before = try f.libraryState()
        let check = try f.service.sendCheck(for: id)
        let folder = try makeTempDir()

        let sent = try f.service.prepareSend(for: check, options: Self.square, in: folder)

        // A copy in the folder given, under the file's own name: not the library's file.
        #expect(sent.file.standardizedFileURL.path
            == folder.appendingPathComponent(original.lastPathComponent).standardizedFileURL.path)
        #expect(tree(folder) == [original.lastPathComponent])
        #expect(sent.coversSquared == 1)
        #expect(sent.coversNotSquared == 0)
        // Its cover is the squared one.
        let was = try f.io.read(original)
        let now = try f.io.read(sent.file)
        #expect(now.cover == CoverSquaring.squared(Self.tall))
        #expect(P.size(try #require(now.cover)) == [300, 300])
        #expect(P.size(try #require(was.cover)) == [200, 300])
        // Everything else is as it was: the details, the chapter marks, the length, the sound.
        #expect(now.metadata == was.metadata)
        #expect(now.chapters == was.chapters)
        #expect(now.chapters.map(\.title) == ["Opening", "Middle", "End"])
        #expect(try f.io.readTrackTags(at: sent.file) == (try f.io.readTrackTags(at: original)))
        #expect(try P.mediaData(sent.file) == (try P.mediaData(original)))
        #expect(abs(try await MediaFixtures.avDuration(sent.file) - 3) < 0.2)
        // The fingerprint describes the copy.
        #expect(sent.fingerprint.files.count == 1)
        #expect(sent.fingerprint.files[0].bytes == (try size(sent.file)))
        #expect(sent.fingerprint.files[0].name == check.fingerprint.files[0].name)
        #expect(sent.fingerprint.files[0].seconds == check.fingerprint.files[0].seconds)
        #expect(sent.fingerprint.files[0].chapters == check.fingerprint.files[0].chapters)
        // The library has not been touched: not a byte, not a date.
        #expect(try f.libraryState() == before)
        // The plain form gives the same file.
        let again = try makeTempDir()
        let url = try f.service.makeSendPackage(for: check, options: Self.square, in: again)
        #expect(url.lastPathComponent == original.lastPathComponent)
        #expect(tree(again) == [original.lastPathComponent])
        #expect(try Data(contentsOf: url) == (try Data(contentsOf: sent.file)))
    }

    @Test func sp13_severalFilesAreZippedFromCopiesEachWithTheSquaredCover() throws {
        let f = try F()
        let id = try importParts(f, cover: Self.tall)
        let originals = try f.audioURLs(id)
        let before = try f.libraryState()
        let check = try f.service.sendCheck(for: id)
        #expect(check.coverIsSquare == false)
        let folder = try makeTempDir()

        let sent = try f.service.prepareSend(for: check, options: Self.square, in: folder)

        // Only the zip is left in the folder.
        #expect(tree(folder) == ["Four Parts.zip"])
        #expect(sent.file.lastPathComponent == "Four Parts.zip")
        #expect(sent.coversSquared == 4)
        #expect(sent.coversNotSquared == 0)
        let out = try makeTempDir()
        try FileManager.default.unzipItem(at: sent.file, to: out)
        #expect(tree(out) == originals.map(\.lastPathComponent).sorted())
        let archive = try Archive(url: sent.file, accessMode: .read)
        #expect(archive.map(\.path) == originals.map(\.lastPathComponent))
        let squared = CoverSquaring.squared(Self.tall)
        for (index, original) in originals.enumerated() {
            let copy = out.appendingPathComponent(original.lastPathComponent)
            let was = try f.io.read(original)
            let now = try f.io.read(copy)
            #expect(now.cover == squared)
            #expect(now.metadata == was.metadata)
            #expect(now.chapters == was.chapters)
            #expect(try f.io.readTrackTags(at: copy) == (try f.io.readTrackTags(at: original)))
            #expect(try P.frames(copy) == (try P.frames(original)))
            #expect(sent.fingerprint.files[index].name == original.lastPathComponent)
            #expect(sent.fingerprint.files[index].bytes == (try size(copy)))
            #expect(sent.fingerprint.files[index].seconds == check.fingerprint.files[index].seconds)
        }
        #expect(try f.libraryState() == before)
    }

    @Test func sp13_aPartWithNoCoverOfItsOwnGetsTheSquaredOneToo() throws {
        let f = try F()
        let id = try importParts(f, cover: nil)
        let originals = try f.audioURLs(id)
        try f.io.write(F.meta("Four Parts", "An Author"), cover: .set(Self.tall), to: originals[0])
        let check = try f.service.sendCheck(for: id)
        let folder = try makeTempDir()

        let sent = try f.service.prepareSend(for: check, options: Self.square, in: folder)

        #expect(sent.coversSquared == 4)
        let out = try makeTempDir()
        try FileManager.default.unzipItem(at: sent.file, to: out)
        for original in originals {
            let cover = try f.io.read(out.appendingPathComponent(original.lastPathComponent)).cover
            #expect(cover == CoverSquaring.squared(Self.tall))
        }
    }

    @Test func sp13_theFolderMustBeOutsideTheLibraryAndFree() throws {
        let f = try F()
        let id = try importSingle(f, cover: Self.tall)
        let check = try f.service.sendCheck(for: id)
        let before = try f.libraryState()
        #expect(throws: SendError.folderInsideLibrary) {
            try f.service.prepareSend(for: check, options: Self.square, in: f.root.appendingPathComponent("An Author"))
        }
        let folder = try makeTempDir()
        let name = try f.audioURLs(id)[0].lastPathComponent
        try Data("mine".utf8).write(to: folder.appendingPathComponent(name))
        #expect(throws: SendError.packageExists(name)) {
            try f.service.prepareSend(for: check, options: Self.square, in: folder)
        }
        #expect(try read(folder.appendingPathComponent(name)) == "mine")
        #expect(tree(folder) == [name])
        #expect(try f.libraryState() == before)
    }

    @Test func sp13_aZipThatFailsLeavesNoCopiesBehind() throws {
        let f = try F()
        let id = try importParts(f, cover: Self.tall)
        let check = try f.service.sendCheck(for: id)
        try FileManager.default.removeItem(at: check.files[3])
        let folder = try makeTempDir()
        #expect(throws: (any Error).self) { try f.service.prepareSend(for: check, options: Self.square, in: folder) }
        #expect(tree(folder) == [])
    }

    // MARK: SP14 A copy that will not take the cover

    @Test func sp14_aCopyThatFailsToTakeTheCoverIsSentAsTheOriginal() throws {
        let f = try F()
        let id = try importParts(f, cover: Self.tall)
        let originals = try f.audioURLs(id)
        let before = try f.libraryState()
        let check = try f.service.sendCheck(for: id)
        let folder = try makeTempDir()
        var written: [String] = []
        f.service.sendCoverWriter = { cover, url in
            written.append(url.path)
            if url.lastPathComponent == originals[1].lastPathComponent { throw MetadataIOError.locked("x") }
            try AudioTagIO.setCover(cover, in: url)
        }

        let sent = try f.service.prepareSend(for: check, options: Self.square, in: folder)

        #expect(sent.coversSquared == 3)
        #expect(sent.coversNotSquared == 1)
        // Never a library file: every write was to a copy outside it.
        #expect(written.count == 4)
        #expect(written.allSatisfy { f.service.layout.relativeComponents(of: URL(fileURLWithPath: $0)) == nil })
        let out = try makeTempDir()
        try FileManager.default.unzipItem(at: sent.file, to: out)
        for (index, original) in originals.enumerated() {
            let copy = out.appendingPathComponent(original.lastPathComponent)
            if index == 1 {
                #expect(try Data(contentsOf: copy) == (try Data(contentsOf: original)))
            } else {
                #expect(try f.io.read(copy).cover == CoverSquaring.squared(Self.tall))
            }
            // The fingerprint is of what is sent, squared or not.
            #expect(sent.fingerprint.files[index].bytes == (try size(copy)))
        }
        #expect(sent.fingerprint.files[1] == check.fingerprint.files[1])
        #expect(tree(folder) == ["Four Parts.zip"])
        #expect(try f.libraryState() == before)
    }

    @Test func sp14_aSingleFileThatFailsIsStillSent() throws {
        let f = try F()
        let id = try importSingle(f, cover: Self.tall)
        let original = try f.audioURLs(id)[0]
        let check = try f.service.sendCheck(for: id)
        let folder = try makeTempDir()
        f.service.sendCoverWriter = { _, _ in throw MetadataIOError.verificationFailed("no") }

        let sent = try f.service.prepareSend(for: check, options: Self.square, in: folder)

        #expect(sent.coversSquared == 0)
        #expect(sent.coversNotSquared == 1)
        #expect(try Data(contentsOf: sent.file) == (try Data(contentsOf: original)))
        #expect(sent.fingerprint == check.fingerprint)
    }

    @Test func sp14_theRealWriterLeavesACopyItCannotChangeAsItWas() throws {
        // A file that is no audio at all: the verified writer refuses, and nothing is changed.
        let folder = try makeTempDir()
        let file = folder.appendingPathComponent("broken.m4b")
        try Data("not audio".utf8).write(to: file)
        #expect(throws: (any Error).self) { try AudioTagIO.setCover(Self.tall, in: file) }
        #expect(try read(file) == "not audio")
        #expect(tree(folder) == ["broken.m4b"])
    }

    // MARK: SP15 Otherwise as before

    @Test func sp15_withTheOptionOffNothingIsCopied() throws {
        let f = try F()
        let id = try importSingle(f, cover: Self.tall)
        let check = try f.service.sendCheck(for: id)
        let folder = try makeTempDir()
        let sent = try f.service.prepareSend(for: check, options: SendOptions(squareCover: false), in: folder)
        #expect(sent == PreparedSend(file: check.files[0], fingerprint: check.fingerprint, coversSquared: 0, coversNotSquared: 0))
        #expect(tree(folder) == [])
        #expect(try f.service.makeSendPackage(for: check, options: SendOptions(squareCover: false), in: folder) == check.files[0])
        #expect(try f.service.makeSendPackage(for: check, in: folder) == check.files[0])
        #expect(SendOptions() == SendOptions(squareCover: false))
    }

    @Test func sp15_aSquareCoverOrNoCoverIsSentAsItIs() throws {
        for cover in [F.jpeg, nil] {
            let f = try F()
            let id = try importSingle(f, cover: cover)
            let check = try f.service.sendCheck(for: id)
            let folder = try makeTempDir()
            let sent = try f.service.prepareSend(for: check, options: Self.square, in: folder)
            #expect(sent == PreparedSend(file: check.files[0], fingerprint: check.fingerprint, coversSquared: 0, coversNotSquared: 0))
            #expect(tree(folder) == [])

            let g = try F()
            let parts = try importParts(g, cover: cover)
            let partsCheck = try g.service.sendCheck(for: parts)
            let plain = try g.service.makeSendPackage(for: partsCheck, in: try makeTempDir())
            let other = try makeTempDir()
            let optioned = try g.service.prepareSend(for: partsCheck, options: Self.square, in: other)
            #expect(optioned.fingerprint == partsCheck.fingerprint)
            #expect(optioned.coversSquared == 0)
            #expect(tree(other) == ["Four Parts.zip"])
            let a = try Archive(url: plain, accessMode: .read).map { [$0.path, String($0.checksum)] }
            let b = try Archive(url: optioned.file, accessMode: .read).map { [$0.path, String($0.checksum)] }
            #expect(a == b)
        }
    }

    @Test func sp15_aBlockedCheckIsStillRefused() throws {
        let f = try F()
        let id = try importSingle(f, cover: Self.tall)
        try FileManager.default.removeItem(at: try f.audioURLs(id)[0])
        let check = try f.service.sendCheck(for: id)
        let folder = try makeTempDir()
        #expect(throws: SendError.nothingToSend) { try f.service.prepareSend(for: check, options: Self.square, in: folder) }
        #expect(tree(folder) == [])
    }
}

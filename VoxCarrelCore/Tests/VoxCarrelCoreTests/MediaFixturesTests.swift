import AVFoundation
import Foundation
import PDFKit
import Testing
import UniformTypeIdentifiers
@testable import VoxCarrelCore
import VoxCarrelFixtures

@Suite struct MediaFixturesTests {
    @Test func aacFixtureDecodesAtTheRequestedLength() async throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("a.m4b")
        try MediaFixtures.makeAAC(at: url, seconds: 3)

        let duration = try await MediaFixtures.avDuration(url)
        #expect(abs(duration - 3) < 0.1)
        #expect(try MediaFixtures.decodedFrameCount(url) > 100_000)
    }

    @Test func mp3FixtureDecodesAtTheRequestedLength() async throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("a.mp3")
        try MediaFixtures.makeSilentMP3(seconds: 5).write(to: url)

        let duration = try await MediaFixtures.avDuration(url)
        #expect(abs(duration - 5) < 0.1)
    }

    @Test func imagesAreDecodable() {
        for type in [UTType.jpeg, UTType.png] {
            let data = MediaFixtures.makeImage(type)
            #expect(CGImageSourceCreateWithData(data as CFData, nil).map(CGImageSourceGetCount) == 1)
        }
    }

    @Test func pdfFixtureHasItsPages() throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("a.pdf")
        MediaFixtures.makePDF(at: url, pages: 3)

        #expect(PDFDocument(url: url)?.pageCount == 3)
    }

    @Test func epubFixturesPassTheZipTool() throws {
        let dir = try makeTempDir()
        for url in [try MediaFixtures.makeEPUB3(in: dir), try MediaFixtures.makeEPUB2(in: dir)] {
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            unzip.arguments = ["-tq", url.path]
            unzip.standardOutput = Pipe()
            try unzip.run()
            unzip.waitUntilExit()
            #expect(unzip.terminationStatus == 0)
        }
    }
}

import AVFoundation
import CTagBridge
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import VoxCarrelCore

@Suite struct AudioTagIOTests {
    static let free = "----:com.apple.iTunes:"

    func sample() -> BookMetadata {
        var m = BookMetadata(title: "Project Hail Mary", authors: ["Andy Weir", "Tolkien, J. R. R."])
        m.subtitle = "A Novel"
        m.narrators = ["Ray Porter", "Someone Else"]
        m.series = "The Expanse"
        m.seriesNumber = "2.5"
        m.genre = "Science Fiction"
        m.year = 2021
        m.publisher = "Audible Studios"
        m.summary = "A placeholder summary for the tests.\nSecond line, with ünïcödé."
        m.language = "en"
        m.isbn = "9780593135204"
        m.asin = "B08G9PRS1K"
        return m
    }

    // MARK: Helpers

    /// A fresh audio fixture named `name` (its extension picks the format) in `dir`.
    func makeAudio(_ name: String, in dir: URL, seconds: Double = 3) throws -> URL {
        let url = dir.appendingPathComponent(name)
        if url.pathExtension == "mp3" {
            try MediaFixtures.makeSilentMP3(seconds: seconds).write(to: url)
        } else {
            try MediaFixtures.makeAAC(at: url, seconds: seconds)
        }
        return url
    }

    func jpeg() -> CoverImage { CoverImage(data: MediaFixtures.makeImage(.jpeg), mime: "image/jpeg") }
    func png() -> CoverImage { CoverImage(data: MediaFixtures.makeImage(.png), mime: "image/png") }

    /// The raw atoms or frames in the file, read through the bridge.
    func rawItems(_ url: URL) throws -> [String: [String]] {
        let snap = url.pathExtension == "mp3"
            ? try CTBTagFile.readMP3(atPath: url.path)
            : try CTBTagFile.readMP4(atPath: url.path)
        return snap.items
    }

    /// Writes raw atoms or frames through the bridge, as another app would.
    func seedRaw(_ items: [String: [String]], in url: URL) throws {
        let changes = CTBChanges()
        changes.setItems = items
        if url.pathExtension == "mp3" {
            try CTBTagFile.writeMP3(atPath: url.path, changes: changes)
        } else {
            try CTBTagFile.writeMP4(atPath: url.path, changes: changes)
        }
    }

    /// Compares every field except `durationSeconds`, one by one so a failure names the field.
    func expectSameFields(_ got: BookMetadata, _ want: BookMetadata, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(got.title == want.title, sourceLocation: sourceLocation)
        #expect(got.subtitle == want.subtitle, sourceLocation: sourceLocation)
        #expect(got.authors == want.authors, sourceLocation: sourceLocation)
        #expect(got.narrators == want.narrators, sourceLocation: sourceLocation)
        #expect(got.series == want.series, sourceLocation: sourceLocation)
        #expect(got.seriesNumber == want.seriesNumber, sourceLocation: sourceLocation)
        #expect(got.genre == want.genre, sourceLocation: sourceLocation)
        #expect(got.year == want.year, sourceLocation: sourceLocation)
        #expect(got.publisher == want.publisher, sourceLocation: sourceLocation)
        #expect(got.summary == want.summary, sourceLocation: sourceLocation)
        #expect(got.language == want.language, sourceLocation: sourceLocation)
        #expect(got.isbn == want.isbn, sourceLocation: sourceLocation)
        #expect(got.asin == want.asin, sourceLocation: sourceLocation)
        #expect(got.pageCount == want.pageCount, sourceLocation: sourceLocation)
    }

    func roundTrip(_ name: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let dir = try makeTempDir()
        let url = try makeAudio(name, in: dir)
        let cover = jpeg()

        let report = try AudioTagIO.write(sample(), cover: .set(cover), part: nil, to: url)
        #expect(report.notWritten.isEmpty, sourceLocation: sourceLocation)

        let after = try AudioTagIO.read(url)
        expectSameFields(after.metadata, sample(), sourceLocation: sourceLocation)
        #expect(after.cover?.data == cover.data, sourceLocation: sourceLocation)
        #expect(after.cover?.mime == "image/jpeg", sourceLocation: sourceLocation)
    }

    func tempFiles(in dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix(".voxcarrel-") }
    }

    // MARK: Round trips

    @Test func roundTripM4B() throws { try roundTrip("book.m4b") }
    @Test func roundTripM4A() throws { try roundTrip("book.m4a") }
    @Test func roundTripMP3() throws { try roundTrip("book.mp3") }

    @Test func audioIsUntouchedByWriting() async throws {
        let dir = try makeTempDir()
        for name in ["book.m4b", "book.mp3"] {
            let url = try makeAudio(name, in: dir)
            let framesBefore = try MediaFixtures.decodedFrameCount(url)
            let durationBefore = try await MediaFixtures.avDuration(url)
            #expect(framesBefore > 100_000)

            try AudioTagIO.write(sample(), cover: .set(jpeg()), part: nil, to: url)

            let framesAfter = try MediaFixtures.decodedFrameCount(url)
            let durationAfter = try await MediaFixtures.avDuration(url)
            #expect(framesAfter == framesBefore, "\(name)")
            #expect(durationAfter == durationBefore, "\(name)")
        }
    }

    @Test func readsDuration() throws {
        let dir = try makeTempDir()
        for name in ["book.m4b", "book.mp3"] {
            let url = try makeAudio(name, in: dir, seconds: 3)
            let contents = try AudioTagIO.read(url)
            let duration = try #require(contents.metadata.durationSeconds, "\(name)")
            #expect(abs(duration - 3) < 0.2, "\(name)")
        }
    }

    // MARK: Cover

    @Test func coverCanBeKeptReplacedAndRemoved() throws {
        let dir = try makeTempDir()
        for name in ["book.m4b", "book.mp3"] {
            let url = try makeAudio(name, in: dir)
            try AudioTagIO.write(sample(), cover: .set(jpeg()), part: nil, to: url)

            var edited = sample()
            edited.title = "A Different Title"
            try AudioTagIO.write(edited, cover: .keep, part: nil, to: url)
            let kept = try AudioTagIO.read(url)
            #expect(kept.metadata.title == "A Different Title", "\(name)")
            #expect(kept.cover == jpeg(), "\(name)")

            try AudioTagIO.write(edited, cover: .set(png()), part: nil, to: url)
            let replaced = try AudioTagIO.read(url)
            #expect(replaced.cover?.mime == "image/png", "\(name)")
            #expect(replaced.cover?.data == png().data, "\(name)")

            try AudioTagIO.write(edited, cover: .remove, part: nil, to: url)
            let removed = try AudioTagIO.read(url)
            #expect(removed.cover == nil, "\(name)")
            expectSameFields(removed.metadata, edited)
        }
    }

    // MARK: Fields

    @Test func clearingAFieldRemovesIt() throws {
        let dir = try makeTempDir()
        for name in ["book.m4b", "book.mp3"] {
            let url = try makeAudio(name, in: dir)
            try AudioTagIO.write(sample(), cover: .keep, part: nil, to: url)

            var cleared = sample()
            cleared.series = nil
            cleared.seriesNumber = nil
            cleared.narrators = []
            cleared.summary = nil
            try AudioTagIO.write(cleared, cover: .keep, part: nil, to: url)

            let got = try AudioTagIO.read(url).metadata
            #expect(got.series == nil, "\(name)")
            #expect(got.seriesNumber == nil, "\(name)")
            #expect(got.narrators.isEmpty, "\(name)")
            #expect(got.summary == nil, "\(name)")
            expectSameFields(got, cleared)

            // The tags themselves are gone, not just hidden from `read`.
            let raw = try rawItems(url)
            let gone = name.hasSuffix("mp3")
                ? ["TXXX:SERIES", "TXXX:SERIES-PART", "MVNM", "MVIN", "GRP1", "TCOM", "COMM", "TXXX:DESCRIPTION"]
                : [Self.free + "SERIES", Self.free + "SERIES-PART", "©mvn", "©mvi", "©grp", "©nrt", "©wrt",
                   "desc", "ldes", "©cmt"]
            for key in gone {
                #expect(raw[key] == nil, "\(name) \(key)")
            }
        }
    }

    // MARK: ID3 versions

    @Test func existingID3v23TagStaysVersion23() throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("book23.mp3")
        try MediaFixtures.makeSilentMP3(seconds: 3, id3v23Title: "Old").write(to: url)
        let versionBefore = try CTBTagFile.readMP3(atPath: url.path).id3v2MajorVersion
        #expect(versionBefore == 3)

        try AudioTagIO.write(sample(), cover: .set(jpeg()), part: nil, to: url)

        let versionAfter = try CTBTagFile.readMP3(atPath: url.path).id3v2MajorVersion
        #expect(versionAfter == 3)
        let got = try AudioTagIO.read(url).metadata
        #expect(got.year == 2021)
        expectSameFields(got, sample())
    }

    @Test func untaggedMP3GetsID3v24() throws {
        let dir = try makeTempDir()
        let url = try makeAudio("book.mp3", in: dir)
        let versionBefore = try CTBTagFile.readMP3(atPath: url.path).id3v2MajorVersion
        #expect(versionBefore == 0)

        try AudioTagIO.write(sample(), cover: .keep, part: nil, to: url)

        let versionAfter = try CTBTagFile.readMP3(atPath: url.path).id3v2MajorVersion
        #expect(versionAfter == 4)
    }

    // MARK: Other people's data

    @Test func unknownTagsSurviveAWrite() throws {
        let dir = try makeTempDir()
        for (name, key) in [("book.m4b", Self.free + "MYAPP"), ("book.mp3", "TXXX:MYAPP")] {
            let url = try makeAudio(name, in: dir)
            try seedRaw([key: ["keep me"]], in: url)
            let seeded = try rawItems(url)
            #expect(seeded[key] == ["keep me"], "\(name)")

            try AudioTagIO.write(sample(), cover: .set(jpeg()), part: nil, to: url)

            let raw = try rawItems(url)
            #expect(raw[key] == ["keep me"], "\(name)")
        }
    }

    @Test func chaptersAreReadAndSurviveAWrite() throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("chaptered.m4b")
        let wanted: [(start: Double, title: String)] = [
            (0, "Opening Credits"), (2, "Chapter 1"), (4.5, "Chapter 2: Ünïcode"),
        ]
        try MediaFixtures.makeChapteredM4B(at: url, seconds: 6, chapters: wanted)

        let before = try AudioTagIO.read(url)
        #expect(before.chapters.map(\.title) == wanted.map(\.title))
        try #require(before.chapters.count == 3)
        for (chapter, want) in zip(before.chapters, wanted) {
            #expect(abs(chapter.start - want.start) < 0.05, "\(want.title)")
        }

        try AudioTagIO.write(sample(), cover: .set(jpeg()), part: nil, to: url)

        let after = try AudioTagIO.read(url)
        #expect(after.chapters == before.chapters)
        expectSameFields(after.metadata, sample())
    }

    // MARK: Multi-part books

    @Test func multiPartKeepsTrackTitleAndSetsTrackNumber() throws {
        let dir = try makeTempDir()
        for (name, titleKey, albumKey, trackKey) in [
            ("part03.mp3", "TIT2", "TALB", "TRCK"), ("part03.m4a", "©nam", "©alb", "trkn"),
        ] {
            let url = try makeAudio(name, in: dir)
            try seedRaw([titleKey: ["Chapter 3"]], in: url)

            try AudioTagIO.write(sample(), cover: .keep, part: PartPosition(index: 3, count: 12), to: url)

            let raw = try rawItems(url)
            #expect(raw[titleKey] == ["Chapter 3"], "\(name)")
            #expect(raw[albumKey] == ["Project Hail Mary"], "\(name)")
            #expect(raw[trackKey] == ["3/12"], "\(name)")
            let got = try AudioTagIO.read(url).metadata
            #expect(got.title == "Project Hail Mary", "\(name)")
        }
    }

    @Test func singleFileWriteSetsBothTitles() throws {
        let dir = try makeTempDir()
        for (name, titleKey, albumKey, trackKey) in [
            ("book.m4b", "©nam", "©alb", "trkn"), ("book.mp3", "TIT2", "TALB", "TRCK"),
        ] {
            let url = try makeAudio(name, in: dir)

            try AudioTagIO.write(sample(), cover: .keep, part: nil, to: url)

            let raw = try rawItems(url)
            #expect(raw[titleKey] == ["Project Hail Mary"], "\(name)")
            #expect(raw[albumKey] == ["Project Hail Mary"], "\(name)")
            #expect(raw[trackKey] == nil, "\(name)")
        }
    }

    @Test func readsTagsWrittenByOtherApps() throws {
        let dir = try makeTempDir()
        let url = try makeAudio("other.m4b", in: dir)
        try seedRaw([
            "©alb": ["Leviathan Wakes"],
            "aART": ["Andy Weir, Second Author"],
            "©wrt": ["Ray Porter"],
            "©grp": ["The Expanse #3"],
            "©day": ["2021-05-04"],
        ], in: url)
        let raw = try rawItems(url)
        #expect(raw["©nrt"] == nil)
        #expect(raw[Self.free + "SERIES"] == nil)

        let got = try AudioTagIO.read(url).metadata
        #expect(got.title == "Leviathan Wakes")
        #expect(got.authors == ["Andy Weir", "Second Author"])
        #expect(got.narrators == ["Ray Porter"])
        #expect(got.series == "The Expanse")
        #expect(got.seriesNumber == "3")
        #expect(got.year == 2021)
    }

    // MARK: Failures

    @Test func unsupportedOrBrokenFilesThrow() throws {
        let dir = try makeTempDir()
        let text = try touch(dir.appendingPathComponent("notes.txt"), "just some notes")
        #expect(throws: MetadataIOError.unsupportedFormat("txt")) {
            _ = try AudioTagIO.read(text)
        }
        #expect(throws: MetadataIOError.unsupportedFormat("txt")) {
            _ = try AudioTagIO.write(sample(), cover: .keep, part: nil, to: text)
        }

        let broken = try touch(dir.appendingPathComponent("x.m4b"), "this is not an audiobook")
        let bytesBefore = try Data(contentsOf: broken)
        #expect(throws: MetadataIOError.unreadable("x.m4b")) {
            _ = try AudioTagIO.read(broken)
        }
        #expect(throws: MetadataIOError.unreadable("x.m4b")) {
            _ = try AudioTagIO.write(sample(), cover: .set(jpeg()), part: nil, to: broken)
        }
        let bytesAfter = try Data(contentsOf: broken)
        #expect(bytesAfter == bytesBefore)
        let textAfter = try read(text)
        #expect(textAfter == "just some notes")
    }

    @Test func noTempFilesAreLeftBehind() throws {
        let dir = try makeTempDir()

        // After a successful write.
        let good = try makeAudio("good.m4b", in: dir)
        try AudioTagIO.write(sample(), cover: .set(jpeg()), part: nil, to: good)
        let afterSuccess = try tempFiles(in: dir)
        #expect(afterSuccess.isEmpty)

        // After a write that fails before any copy is made.
        let broken = try touch(dir.appendingPathComponent("x.m4b"), "this is not an audiobook")
        #expect(throws: MetadataIOError.unreadable("x.m4b")) {
            _ = try AudioTagIO.write(sample(), cover: .keep, part: nil, to: broken)
        }
        let afterBroken = try tempFiles(in: dir)
        #expect(afterBroken.isEmpty)

        // After a write that fails on the copy: a read-only file gives a read-only copy.
        let locked = try makeAudio("locked.m4b", in: dir)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: locked.path)
        let lockedBytes = try Data(contentsOf: locked)
        #expect(throws: MetadataIOError.locked("locked.m4b")) {
            _ = try AudioTagIO.write(sample(), cover: .keep, part: nil, to: locked)
        }
        let afterLocked = try tempFiles(in: dir)
        #expect(afterLocked.isEmpty)
        let lockedBytesAfter = try Data(contentsOf: locked)
        #expect(lockedBytesAfter == lockedBytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == ["good.m4b", "locked.m4b", "x.m4b"])
    }
}

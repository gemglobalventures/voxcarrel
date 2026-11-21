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

    // MARK: Files that are not what their name says

    @Test func filesWithNoMeasurableAudioAreRefusedUntouched() throws {
        let dir = try makeTempDir()
        // An MP4 file with an .mp3 name: TagLib's MPEG reader opens anything.
        let real = try makeAudio("real.m4a", in: dir, seconds: 2)
        let misnamed = dir.appendingPathComponent("misnamed.mp3")
        try FileManager.default.moveItem(at: real, to: misnamed)
        let notes = try touch(dir.appendingPathComponent("notes.mp3"), "these are just my notes, not audio\n")

        for url in [misnamed, notes] {
            let name = url.lastPathComponent
            let bytes = try Data(contentsOf: url)
            #expect(throws: MetadataIOError.unreadable(name)) { _ = try AudioTagIO.read(url) }
            #expect(throws: MetadataIOError.unreadable(name)) {
                _ = try AudioTagIO.write(sample(), cover: .set(jpeg()), part: nil, to: url)
            }
            #expect(try Data(contentsOf: url) == bytes, "\(name)")
        }
        #expect(try tempFiles(in: dir).isEmpty)
    }

    // MARK: Multi-value tags

    @Test func everyValueOfAMultiValueTagIsReadAndKept() throws {
        let dir = try makeTempDir()
        for (name, authorKeys, narratorKey, genreKey) in [
            ("multi.mp3", ["TPE1", "TPE2"], "TCOM", "TCON"), ("multi.m4b", ["©ART", "aART"], "©nrt", "©gen"),
        ] {
            let url = try makeAudio(name, in: dir)
            var seed = [narratorKey: ["Ray Porter", "Jane Reader, Joe Reader"], genreKey: ["Fantasy", "Humour"]]
            for key in authorKeys { seed[key] = ["Alice Able", "Baker, Bob", "Carol Cho; Dan Dee"] }
            try seedRaw(seed, in: url)

            let got = try AudioTagIO.read(url).metadata
            #expect(got.authors == ["Alice Able", "Baker, Bob", "Carol Cho", "Dan Dee"], "\(name)")
            #expect(got.narrators == ["Ray Porter", "Jane Reader", "Joe Reader"], "\(name)")
            #expect(got.genre == "Fantasy; Humour", "\(name)")

            // Writing back what was read loses nobody; the tag becomes one joined value.
            try AudioTagIO.write(got, cover: .keep, part: nil, to: url)
            let raw = try rawItems(url)
            for key in authorKeys {
                #expect(raw[key] == ["Alice Able; Baker, Bob; Carol Cho; Dan Dee"], "\(name) \(key)")
            }
            #expect(raw[narratorKey] == ["Ray Porter; Jane Reader; Joe Reader"], "\(name)")
            #expect(raw[genreKey] == ["Fantasy; Humour"], "\(name)")
            expectSameFields(try AudioTagIO.read(url).metadata, got)
        }
    }

    // MARK: Dates

    @Test func fullDateIsKeptWhenTheYearIsUnchanged() throws {
        let dir = try makeTempDir()
        for (name, key, date) in [("date.m4b", "©day", "2019-03-01T08:00:00Z"), ("date.mp3", "TDRC", "2019-03-01")] {
            let url = try makeAudio(name, in: dir)
            try seedRaw([key: [date]], in: url)
            var m = try AudioTagIO.read(url).metadata
            #expect(m.year == 2019, "\(name)")

            m.title = "Only The Title Changes"
            try AudioTagIO.write(m, cover: .keep, part: nil, to: url)
            #expect(try rawItems(url)[key] == [date], "\(name)")
            #expect(try AudioTagIO.read(url).metadata.year == 2019, "\(name)")

            m.year = 2020
            try AudioTagIO.write(m, cover: .keep, part: nil, to: url)
            #expect(try rawItems(url)[key] == ["2020"], "\(name)")

            m.year = nil
            try AudioTagIO.write(m, cover: .keep, part: nil, to: url)
            #expect(try rawItems(url)[key] == nil, "\(name)")
            #expect(try AudioTagIO.read(url).metadata.year == nil, "\(name)")
        }
    }

    @Test func id3v23YearAndDayMonthFramesAreKeptWhenTheYearIsUnchanged() throws {
        let url = try makeTempDir().appendingPathComponent("old.mp3")
        var data = MediaFixtures.id3v23Tag(frames: [
            ("TALB", MediaFixtures.id3Text("Old Book")), ("TYER", MediaFixtures.id3Text("2001")),
            ("TDAT", MediaFixtures.id3Text("0103")),
        ])
        data.append(MediaFixtures.makeSilentMP3(seconds: 2))
        try data.write(to: url)
        // TagLib presents TYER + TDAT (DDMM) as one TDRC value.
        #expect(try rawItems(url)["TDRC"] == ["2001-03-01"])

        var m = try AudioTagIO.read(url).metadata
        #expect(m.year == 2001)
        m.title = "Renamed"
        try AudioTagIO.write(m, cover: .keep, part: nil, to: url)

        #expect(try rawItems(url)["TDRC"] == ["2001-03-01"])
        #expect(try CTBTagFile.readMP3(atPath: url.path).id3v2MajorVersion == 3)
    }

    // MARK: Comments

    @Test func aCommentThatIsNotTheDescriptionIsLeftAlone() throws {
        let dir = try makeTempDir()
        for (name, commentKey, descriptionKeys) in [
            ("c.m4b", "©cmt", ["ldes", "desc"]), ("c.mp3", "COMM", ["TXXX:DESCRIPTION"]),
        ] {
            let url = try makeAudio(name, in: dir)
            var seed = [commentKey: ["Bought at the 2019 fair"]]
            for key in descriptionKeys { seed[key] = ["The blurb"] }
            try seedRaw(seed, in: url)

            var m = try AudioTagIO.read(url).metadata
            #expect(m.summary == "The blurb", "\(name)")
            try AudioTagIO.write(m, cover: .keep, part: nil, to: url)
            #expect(try rawItems(url)[commentKey] == ["Bought at the 2019 fair"], "\(name)")

            m.summary = "A new blurb"
            try AudioTagIO.write(m, cover: .keep, part: nil, to: url)
            var raw = try rawItems(url)
            #expect(raw[commentKey] == ["Bought at the 2019 fair"], "\(name)")
            for key in descriptionKeys { #expect(raw[key] == ["A new blurb"], "\(name) \(key)") }

            m.summary = nil
            try AudioTagIO.write(m, cover: .keep, part: nil, to: url)
            raw = try rawItems(url)
            #expect(raw[commentKey] == ["Bought at the 2019 fair"], "\(name)")
            for key in descriptionKeys { #expect(raw[key] == nil, "\(name) \(key)") }
        }
    }

    @Test func aCommentThatMirrorsTheDescriptionFollowsIt() throws {
        let dir = try makeTempDir()
        for (name, commentKey) in [("c.m4b", "©cmt"), ("c.mp3", "COMM")] {
            let url = try makeAudio(name, in: dir)
            try AudioTagIO.write(sample(), cover: .keep, part: nil, to: url) // no comment yet: one is added
            #expect(try rawItems(url)[commentKey] == [sample().summary!], "\(name)")

            var m = sample()
            m.summary = "Second blurb"
            try AudioTagIO.write(m, cover: .keep, part: nil, to: url)
            #expect(try rawItems(url)[commentKey] == ["Second blurb"], "\(name)")
        }
    }

    // MARK: Grouping

    @Test func aBareGroupingIsNotASeries() throws {
        let dir = try makeTempDir()
        for (name, key, seriesKeys) in [
            ("g.m4b", "©grp", [Self.free + "SERIES", "©mvn"]), ("g.mp3", "GRP1", ["TXXX:SERIES", "MVNM"]),
        ] {
            let url = try makeAudio(name, in: dir)
            try seedRaw([key: ["Fiction"]], in: url)
            let m = try AudioTagIO.read(url).metadata
            #expect(m.series == nil, "\(name)")
            #expect(m.seriesNumber == nil, "\(name)")

            try seedRaw([key: ["The Expanse #3"]], in: url)
            let numbered = try AudioTagIO.read(url).metadata
            #expect(numbered.series == "The Expanse", "\(name)")
            #expect(numbered.seriesNumber == "3", "\(name)")
            for seriesKey in seriesKeys { #expect(try rawItems(url)[seriesKey] == nil, "\(name)") }
        }
    }

    // MARK: TXXX descriptions

    @Test func userTextFramesMatchWithoutRegardToCase() throws {
        let url = try makeAudio("case.mp3", in: try makeTempDir())
        try seedRaw([
            "TXXX:series": ["Lower Series"], "TXXX:Series-Part": ["4"], "TXXX:Asin": ["B000000001"],
            "TXXX:isbn": ["9780000000001"], "TXXX:Description": ["Mixed-case blurb"], "TXXX:narrator": ["Nora Narrator"],
            "TXXX:MyApp": ["keep me"],
        ], in: url)

        var m = try AudioTagIO.read(url).metadata
        #expect(m.series == "Lower Series")
        #expect(m.seriesNumber == "4")
        #expect(m.asin == "B000000001")
        #expect(m.isbn == "9780000000001")
        #expect(m.summary == "Mixed-case blurb")
        #expect(m.narrators == ["Nora Narrator"])

        m.series = "Renamed Series"
        try AudioTagIO.write(m, cover: .keep, part: nil, to: url)

        let raw = try rawItems(url)
        let userFrames = raw.keys.filter { $0.hasPrefix("TXXX:") }.sorted()
        #expect(userFrames == ["TXXX:ASIN", "TXXX:DESCRIPTION", "TXXX:ISBN", "TXXX:MyApp", "TXXX:SERIES", "TXXX:SERIES-PART", "TXXX:narrator"])
        #expect(raw["TXXX:SERIES"] == ["Renamed Series"])
        #expect(raw["TXXX:MyApp"] == ["keep me"])
        #expect(try AudioTagIO.read(url).metadata.series == "Renamed Series")
    }

    // MARK: Pictures and cover types

    /// An MP3 whose ID3v2.3 tag holds the given pictures, in order.
    func mp3(_ name: String, in dir: URL, pictures: [(image: Data, mime: String, type: UInt8)]) throws -> URL {
        let url = dir.appendingPathComponent(name)
        var data = MediaFixtures.id3v23Tag(frames: [("TALB", MediaFixtures.id3Text("Pictures"))] + pictures.map {
            (id: "APIC", body: MediaFixtures.id3Picture($0.image, mime: $0.mime, type: $0.type))
        })
        data.append(MediaFixtures.makeSilentMP3(seconds: 2))
        try data.write(to: url)
        return url
    }

    @Test func mp3CoverChangesLeaveOtherPicturesAlone() throws {
        let dir = try makeTempDir()
        let back = MediaFixtures.makeImage(.jpeg, size: 16, red: 0.1)
        let front = MediaFixtures.makeImage(.jpeg, size: 24, red: 0.5)
        let artist = MediaFixtures.makeImage(.png, size: 16, red: 0.9)
        let pictures: [(image: Data, mime: String, type: UInt8)] = [(back, "image/jpeg", 4), (front, "image/jpeg", 3), (artist, "image/png", 8)]
        let m = BookMetadata(title: "Pictures")

        let replaced = try mp3("replace.mp3", in: dir, pictures: pictures)
        #expect(try AudioTagIO.read(replaced).cover?.data == front)
        try AudioTagIO.write(m, cover: .set(png()), part: nil, to: replaced)
        #expect(try AudioTagIO.read(replaced).cover == png())
        #expect(try CTBTagFile.readMP3(atPath: replaced.path).pictureTypes.map(\.intValue).sorted() == [3, 4, 8])

        let removed = try mp3("remove.mp3", in: dir, pictures: pictures)
        try AudioTagIO.write(m, cover: .remove, part: nil, to: removed)
        #expect(try CTBTagFile.readMP3(atPath: removed.path).pictureTypes.map(\.intValue).sorted() == [4, 8])
        // With no front cover left, `read` falls back to the first remaining picture.
        #expect(try AudioTagIO.read(removed).cover?.data == back)

        // No front cover at all: the one picture `read` reports is the one replaced.
        let noFront = try mp3("nofront.mp3", in: dir, pictures: [(back, "image/jpeg", 4), (artist, "image/png", 8)])
        #expect(try AudioTagIO.read(noFront).cover?.data == back)
        try AudioTagIO.write(m, cover: .set(png()), part: nil, to: noFront)
        #expect(try AudioTagIO.read(noFront).cover == png())
        #expect(try CTBTagFile.readMP3(atPath: noFront.path).pictureTypes.map(\.intValue).sorted() == [3, 8])
    }

    @Test func coverTypeComesFromTheImageBytes() throws {
        let dir = try makeTempDir()
        let jpegData = MediaFixtures.makeImage(.jpeg)
        let gifData = MediaFixtures.makeImage(.gif)
        let junk = Data("not an image at all".utf8)

        // ID3v2.2-style and misspelt MIME strings are common in old MP3s.
        for (mime, image, want) in [("image/jpg", jpegData, "image/jpeg"), ("JPG", jpegData, "image/jpeg"), ("", MediaFixtures.makeImage(.png), "image/png"),
                                    ("image/jpeg", gifData, "image/gif"), ("image/jpeg", junk, "application/octet-stream")] {
            let url = try mp3("m-\(UUID().uuidString).mp3", in: dir, pictures: [(image, mime, 3)])
            let cover = try AudioTagIO.read(url).cover
            #expect(cover?.mime == want, "APIC mime \(mime.debugDescription)")
            #expect(cover?.data == image)
        }

        // MP4: whatever format flag the atom carries, the bytes decide.
        for (image, flagged, want) in [(gifData, "image/jpeg", "image/gif"), (jpegData, "image/png", "image/jpeg"), (junk, "image/jpeg", "application/octet-stream")] {
            let url = try makeAudio("m-\(UUID().uuidString).m4b", in: dir, seconds: 2)
            let changes = CTBChanges()
            changes.replaceCover = true
            changes.coverData = image
            changes.coverMIME = flagged
            try CTBTagFile.writeMP4(atPath: url.path, changes: changes)
            let cover = try AudioTagIO.read(url).cover
            #expect(cover?.mime == want)
            #expect(cover?.data == image)
        }
    }
}

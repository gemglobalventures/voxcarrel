import Foundation
import Testing
import VoxCarrelCore
import VoxCarrelFixtures

@testable import VoxCarrelAppCore

/// Import Highlights from a Kindle or Kobo: a file of the device is read and reviewed
/// before anything is changed.
@MainActor
@Suite struct DeviceHighlightsImportTests {
    static let clippings = """
        Quiet Rivers (Okafor, Amara)
        - Your Highlight on page 3 | Location 40-41 | Added on Monday, March 3, 2025 9:14:05 AM

        Rivers do not hurry.
        ==========
        A Book Not Here (Someone Else)
        - Your Highlight on Location 9-10 | Added on Monday, March 3, 2025 9:20:00 AM

        Lost words.
        ==========

        """

    @Test func aKindlesClippingsAreReviewedThenBroughtIn() async throws {
        let h = try await Harness.demo()
        // Chosen as the device: the file is found where a Kindle keeps it.
        let device = try makeTempDir()
        try FileManager.default.createDirectory(at: device.appendingPathComponent("documents"), withIntermediateDirectories: true)
        try Data(Self.clippings.utf8).write(to: device.appendingPathComponent("documents/My Clippings.txt"))
        let quiet = try h.id("Quiet Rivers")
        let before = try LibraryStore(libraryRoot: h.root).highlights(forBook: quiet).count

        await h.model.beginHighlightsImport(fromFile: device)
        let session = try #require(h.model.highlightsImport)
        await session.reading?.value
        #expect(session.phase == .review && session.sources == ["A Kindle's clippings file"])
        #expect(session.canImport && session.lines.contains { $0.contains("A Book Not Here") })
        // Nothing yet.
        #expect(try LibraryStore(libraryRoot: h.root).highlights(forBook: quiet).count == before)

        await session.apply()
        #expect(h.model.highlightsImport == nil)
        let now = try LibraryStore(libraryRoot: h.root).highlights(forBook: quiet)
        #expect(now.count == before + 1 && now.contains { $0.text == "Rivers do not hurry." && $0.source == .kindle })
    }

    @Test func aFileThatIsNeitherIsSaidToBeNeither() async throws {
        let h = try await Harness.demo()
        let other = try makeTempDir().appendingPathComponent("notes.txt")
        try Data("Just some notes of mine.".utf8).write(to: other)
        await h.model.beginHighlightsImport(fromFile: other)
        #expect(h.model.highlightsImport == nil)
        #expect(h.model.alert == "This is neither a Kindle's clippings file (My Clippings.txt) nor a Kobo's database (KoboReader.sqlite).")
        h.model.alert = nil

        let empty = try makeTempDir().appendingPathComponent("My Clippings.txt")
        try Data("A Book (An Author)\n- Your Bookmark on page 3 | Added on Monday, March 3, 2025 9:14:05 AM\n\n\n==========\n".utf8).write(to: empty)
        await h.model.beginHighlightsImport(fromFile: empty)
        #expect(h.model.highlightsImport == nil && h.model.alert == "No highlights were found there.")
        #expect(AppModel.highlightsFile(in: other) == other)
    }
}

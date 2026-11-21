import DemoContent
import Foundation
import Testing
import UniformTypeIdentifiers
import VoxCarrelCore
import VoxCarrelFixtures

@testable import VoxCarrelAppCore

/// A9–A18 and collections: the inspector, editing, undo and removing.
@MainActor
@Suite struct AppModelEditingTests {
    private let png = MediaFixtures.makeImage(.png)
    private let jpeg = MediaFixtures.makeImage(.jpeg)

    private func storedCover(_ h: Harness, _ id: Int64) throws -> CoverImage? {
        LibraryService(store: try h.store()).covers.image(for: id)
    }

    private func collectionId(_ h: Harness, _ name: String) throws -> Int64 {
        try #require(h.model.sidebar.collections.first { $0.name == name }?.id, "no collection named \(name)")
    }

    private func titles(_ h: Harness, inCollection id: Int64) throws -> [String] {
        try h.store().books(inCollection: id).map(\.title).sorted()
    }

    // MARK: A9 What the inspector shows

    /// A9
    @Test func oneSelectedBookIsShownWithItsFilesAndADraft() async throws {
        let h = try await Harness.demo()
        #expect(h.model.inspecting == .nothing)

        let id = try await h.select("Salt Road")
        let detail = try #require(h.detail)
        #expect(detail.row.id == id)
        #expect(detail.files.map(\.name) == (try h.fileURLs(id).map(\.lastPathComponent)))
        #expect(detail.files.allSatisfy { !$0.isMissing })
        #expect(detail.collectionIds == [try collectionId(h, "Favourites")])
        #expect(h.draft == BookDraft(book: try h.book(id)))
        #expect(!h.model.hasUnsavedChanges)

        h.model.select([])
        await h.model.settle()
        #expect(h.model.inspecting == .nothing)
    }

    /// A9: the book appears at once from its row; its files follow when the library has answered.
    @Test func aBookIsShownFromItsRowUntilItsDetailsArrive() async throws {
        let h = try await Harness.demo()
        let id = try h.id("Salt Road")
        h.model.click(id, modifiers: [])
        #expect(h.detail?.row.id == id)
        #expect(h.detail?.files.isEmpty == true)
        #expect(h.draft?.title == "Salt Road")

        // What is typed before the details arrive is kept.
        h.model.updateDraft { $0.genre = "Sea Stories" }
        await h.model.settle()
        #expect(h.detail?.files.isEmpty == false)
        #expect(h.draft?.genre == "Sea Stories")
        #expect(h.model.hasUnsavedChanges)
    }

    /// A9
    @Test func severalSelectedBooksAreShownAsABulkDraftInRowOrder() async throws {
        let h = try await Harness.demo()
        h.model.sort = BookSort(key: .title, ascending: false)
        try await h.select(["Quiet Rivers", "Salt Road", "Harbour of Glass"])
        #expect(h.bulkDraft?.books.map(\.title) == ["Salt Road", "Quiet Rivers", "Harbour of Glass"])
        #expect(h.bulkDraft?.values.isEmpty == true)

        h.model.click(try h.id("Salt Road"), modifiers: .command)
        await h.model.settle()
        #expect(h.bulkDraft?.books.map(\.title) == ["Quiet Rivers", "Harbour of Glass"])

        h.model.click(try h.id("Quiet Rivers"), modifiers: .command)
        await h.model.settle()
        #expect(h.draft?.title == "Harbour of Glass")
    }

    /// A9: quick clicks end with the last book clicked.
    @Test func theInspectorEndsOnTheLastSelection() async throws {
        let h = try await Harness.demo()
        for title in ["Salt Road", "Quiet Rivers", "Night Train to Vostok"] {
            h.model.click(try h.id(title), modifiers: [])
        }
        await h.model.settle()
        #expect(h.detail?.row.book.title == "Night Train to Vostok")
        #expect(h.detail?.files.count == 4)
    }

    // MARK: A10 Saving

    /// A10, A11
    @Test func saveWritesTheDraftAndReloads() async throws {
        let h = try await Harness.demo()
        h.recordBusyLabels()
        let id = try await h.select("Salt Road")
        #expect(h.model.undoLabel == Harness.demoUndoLabel)
        h.model.updateDraft {
            $0.title = "The Salt Road"
            $0.genre = "Sea Stories"
            $0.rating = 2
        }

        await h.model.save()
        #expect(h.busyLabels == ["Saving…"])
        #expect(h.model.busyLabel == nil)
        #expect(h.model.alert == nil)
        #expect(h.model.result == nil)

        let saved = try h.book(id)
        #expect(saved.title == "The Salt Road")
        #expect(saved.genre == "Sea Stories")
        #expect(saved.rating == 2)

        #expect(h.model.rows.first { $0.id == id }?.book == saved)
        #expect(h.model.sidebar.browse[.genre]?.contains("Sea Stories") == true)
        #expect(h.model.undoLabel == "Edit The Salt Road")
        #expect(h.model.selection == [id])
        #expect(h.detail?.row.book == saved)
        #expect(h.draft == BookDraft(book: saved))
        #expect(!h.model.hasUnsavedChanges)
        // The file was renamed with the book, and the inspector knows where it is now.
        #expect(h.detail?.files.map(\.url.path) == (try h.fileURLs(id).map(\.path)))
        #expect(h.detail?.files.allSatisfy { !$0.isMissing } == true)
    }

    /// A10
    @Test func aDraftWithAProblemIsNotSaved() async throws {
        let h = try await Harness.demo()
        let id = try await h.select("Salt Road")
        h.model.updateDraft {
            $0.genre = "Sea Stories"
            $0.year = "nineteen"
        }
        await h.model.save()
        #expect(h.model.alert == "Year must be a number such as 1984.")
        #expect(h.model.undoLabel == Harness.demoUndoLabel)
        #expect(try h.book(id).genre == "Fantasy")
        #expect(h.draft?.genre == "Sea Stories")
        #expect(h.model.hasUnsavedChanges)
    }

    /// A10: with nothing changed there is nothing to save.
    @Test func savingAnUntouchedDraftDoesNothing() async throws {
        let h = try await Harness.demo()
        h.recordBusyLabels()
        try await h.select("Salt Road")
        await h.model.save()
        #expect(h.busyLabels.isEmpty)
        #expect(h.model.undoLabel == Harness.demoUndoLabel)
    }

    /// A10: several books at once.
    @Test func saveWritesABulkDraftToEveryBook() async throws {
        let h = try await Harness.demo()
        h.recordBusyLabels()
        let ids = try await h.select(["Salt Road", "Quiet Rivers", "Night Train to Vostok"])
        h.model.updateBulkDraft {
            $0.values[.genre] = "Sea Stories"
            $0.values[.tags] = "shelf one"
        }

        await h.model.save()
        #expect(h.busyLabels == ["Saving 3 books…"])
        #expect(h.model.alert == nil)
        #expect(h.model.result == nil)
        for id in ids {
            let book = try h.book(id)
            #expect(book.genre == "Sea Stories")
            #expect(book.tags.contains("shelf one"))
        }
        #expect(try h.book(try h.id("Salt Road")).tags == ["sea", "comfort listen", "shelf one"])
        #expect(h.model.selection == ids)
        #expect(h.bulkDraft?.values.isEmpty == true)
        #expect(h.bulkDraft?.shared(.genre) == .same("Sea Stories"))
        #expect(!h.model.hasUnsavedChanges)
    }

    /// A10
    @Test func aBulkDraftWithAProblemIsNotSaved() async throws {
        let h = try await Harness.demo()
        try await h.select(["Salt Road", "Quiet Rivers"])
        h.model.updateBulkDraft { $0.values[.year] = "soon" }
        await h.model.save()
        #expect(h.model.alert == "Year must be a number such as 1984.")
        #expect(h.model.undoLabel == Harness.demoUndoLabel)
        #expect(h.model.hasUnsavedChanges)
    }

    /// A10: a save that could not update a file says so in a result sheet.
    @Test func anUncleanSaveSetsTheResult() async throws {
        let h = try await Harness.demo()
        let id = try await h.select("Quiet Rivers")
        // No longer an EPUB, so its tags cannot be written.
        try Data("not a book".utf8).write(to: try #require(try h.fileURLs(id).first))
        h.model.updateDraft { $0.genre = "Verse" }

        await h.model.save()
        let result = try #require(h.model.result)
        #expect(!result.isClean)
        #expect(result.problems.map(\.title) == ["Quiet Rivers"])
        #expect(h.model.alert == nil)
        #expect(h.model.busyLabel == nil)
        #expect(h.model.rows.first { $0.id == id }?.book.genre == (try h.book(id).genre))
    }

    // MARK: A11 Reloading after a change

    /// A11: a role change gives the file a new place; the inspector's ids are the new ones.
    @Test func settingARoleReloadsWithFreshFiles() async throws {
        let h = try await Harness.demo()
        let id = try await h.select("A Field Guide to Small Hours")
        let pdf = try #require(h.detail?.files.first { $0.file.format == .pdf })
        let other: FileRole = pdf.file.role == .extra ? .ebook : .extra
        let ebooksBefore = try #require(h.model.sidebar.counts[.ebooks])

        await h.model.setRole(other, forFile: pdf.id)
        #expect(h.model.alert == nil)
        #expect(h.model.busyLabel == nil)
        let changed = try #require(h.detail?.files.first { $0.file.format == .pdf })
        #expect(changed.file.role == other)
        #expect(!changed.isMissing)
        #expect(h.detail?.files.map(\.id) == (try h.store().files(bookId: id).compactMap(\.id)))
        #expect(h.model.sidebar.counts[.ebooks] == ebooksBefore + (other == .ebook ? 1 : -1))
        #expect(h.model.rows.first { $0.id == id }?.hasEbook == (other == .ebook))
        #expect(h.model.undoLabel == "Change file role")

        // And back again, with the id the inspector has now.
        await h.model.setRole(pdf.file.role, forFile: changed.id)
        #expect(h.model.alert == nil)
        #expect(h.detail?.files.first { $0.file.format == .pdf }?.file.role == pdf.file.role)
        #expect(h.model.sidebar.counts[.ebooks] == ebooksBefore)
    }

    /// A11
    @Test func rewritingTagsReloads() async throws {
        let h = try await Harness.demo()
        h.recordBusyLabels()
        try await h.select(["Salt Road", "Quiet Rivers"])
        await h.model.rewriteTags()
        #expect(h.busyLabels == ["Rewriting tags…"])
        #expect(h.model.alert == nil)
        #expect(h.model.result == nil)
        #expect(h.model.undoLabel == "Rewrite tags for 2 books")
    }

    /// A11: rewriting with nothing selected does nothing.
    @Test func rewritingTagsNeedsASelection() async throws {
        let h = try await Harness.demo()
        h.recordBusyLabels()
        await h.model.rewriteTags()
        #expect(h.busyLabels.isEmpty)
        #expect(h.model.undoLabel == Harness.demoUndoLabel)
    }

    /// A11: a rewrite that could not update a file says so.
    @Test func anUncleanRewriteSetsTheResult() async throws {
        let h = try await Harness.demo()
        let id = try await h.select("Quiet Rivers")
        try Data("not a book".utf8).write(to: try #require(try h.fileURLs(id).first))
        await h.model.rewriteTags()
        #expect(h.model.result?.isClean == false)
        #expect(h.model.result?.problems.map(\.title) == ["Quiet Rivers"])
    }

    /// A11: pointing at a file that went missing puts it back and reloads.
    @Test func locatingAMissingFileReloads() async throws {
        let h = try await Harness.demo(start: false)
        let id = try h.id("Quiet Rivers")
        let expected = try #require(try h.fileURLs(id).first)
        let elsewhere = try makeTempDir().appendingPathComponent("found.epub")
        try FileManager.default.moveItem(at: expected, to: elsewhere)

        await h.model.start()
        try await h.select("Quiet Rivers")
        let file = try #require(h.detail?.files.first)
        #expect(file.isMissing)
        #expect(h.detail?.row.book.needsAttention == true)

        await h.model.locate(fileId: file.id, at: elsewhere)
        #expect(h.model.alert == nil)
        #expect(exists(expected))
        #expect(!exists(elsewhere))
        #expect(h.detail?.files.first?.isMissing == false)
        #expect(h.detail?.row.book.needsAttention == false)
        #expect(h.model.sidebar.counts[.needsAttention] == 1)
    }

    // MARK: A12 Covers

    /// A12
    @Test func aPNGOrJPEGFileBecomesTheDraftsCover() async throws {
        let h = try await Harness.demo()
        let id = try await h.select("Salt Road")
        let folder = try makeTempDir()
        let pngFile = folder.appendingPathComponent("cover.png")
        try png.write(to: pngFile)
        // Judged by its bytes, not its name.
        let jpegFile = folder.appendingPathComponent("cover.dat")
        try jpeg.write(to: jpegFile)

        await h.model.setCover(from: pngFile)
        #expect(h.draft?.cover == .set(CoverImage(data: png, mime: "image/png")))
        #expect(h.model.hasUnsavedChanges)
        await h.model.setCover(from: jpegFile)
        #expect(h.draft?.cover == .set(CoverImage(data: jpeg, mime: "image/jpeg")))
        #expect(h.model.alert == nil)

        await h.model.save()
        #expect(h.model.alert == nil)
        #expect(try storedCover(h, id)?.data == jpeg)
        #expect(h.draft?.cover == .keep)
    }

    /// A12
    @Test func aFileThatIsNotAJPEGOrPNGIsRefused() async throws {
        let h = try await Harness.demo()
        try await h.select("Salt Road")
        let folder = try makeTempDir()
        let text = try touch(folder.appendingPathComponent("cover.png"), "this is not an image")
        let gif = folder.appendingPathComponent("cover.gif")
        try MediaFixtures.makeImage(.gif).write(to: gif)

        for file in [text, gif, folder.appendingPathComponent("nothing here.png")] {
            h.model.alert = nil
            await h.model.setCover(from: file)
            let alert = try #require(h.model.alert, "\(file.lastPathComponent)")
            #expect(alert.contains(file.lastPathComponent))
            #expect(h.draft?.cover == .keep)
            #expect(!h.model.hasUnsavedChanges)
        }
    }

    /// A12: a file that is plainly not a picture (a book dropped in the wrong place), or
    /// one far too big to be a cover, is refused without being read.
    @Test func aBookFileOrAVeryLargeFileIsRefusedUnread() async throws {
        let h = try await Harness.demo()
        try await h.select("Salt Road")
        let folder = try makeTempDir()
        // Not readable at all: were it read, the message would be that it could not be.
        let book = try touch(folder.appendingPathComponent("Dropped.m4b"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: book.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: book.path) }
        await h.model.setCover(from: book)
        #expect(h.model.alert == "\"Dropped.m4b\" is not a JPEG or PNG image, so it cannot be used as a cover.")

        // A sparse file: 51 MB long, and nothing on the disk.
        let huge = folder.appendingPathComponent("huge.png")
        FileManager.default.createFile(atPath: huge.path, contents: nil)
        let handle = try FileHandle(forWritingTo: huge)
        try handle.truncate(atOffset: 51 * 1024 * 1024)
        try handle.close()
        h.model.alert = nil
        await h.model.setCover(from: huge)
        #expect(h.model.alert == "\"huge.png\" is too large to be a cover. Choose an image smaller than 50 MB.")
        #expect(h.draft?.cover == .keep)
        #expect(AppModel.coverSizeLimit == 50 * 1024 * 1024)
    }

    /// A12: a cover that arrives after another book has been selected is not given to that book.
    @Test func aCoverReadForOneBookIsNotGivenToAnother() async throws {
        let h = try await Harness.demo()
        try await h.select("Salt Road")
        let file = try makeTempDir().appendingPathComponent("cover.png")
        try png.write(to: file)
        let gate = Gate()
        h.model.beforeUsingCover = { await gate.wait() }
        let setting = Task { await h.model.setCover(from: file) }
        await gate.arrival()
        try await h.select("Quiet Rivers")
        await gate.release()
        await setting.value
        #expect(h.draft?.original.title == "Quiet Rivers")
        #expect(h.draft?.cover == .keep)
        #expect(!h.model.hasUnsavedChanges)
    }

    /// A12: image data, as dropped or pasted, follows the same rule.
    @Test func coverDataFollowsTheSameRule() async throws {
        let h = try await Harness.demo()
        try await h.select("Salt Road")
        h.model.setCover(data: MediaFixtures.makeImage(.gif))
        #expect(h.model.alert != nil)
        #expect(h.draft?.cover == .keep)

        h.model.alert = nil
        h.model.setCover(data: png)
        #expect(h.model.alert == nil)
        #expect(h.draft?.cover == .set(CoverImage(data: png, mime: "image/png")))
    }

    /// A12
    @Test func removingTheCover() async throws {
        let h = try await Harness.demo()
        let id = try await h.select("Salt Road")
        #expect(try storedCover(h, id) != nil)

        h.model.removeCover()
        #expect(h.draft?.cover == .remove)
        await h.model.save()
        #expect(try storedCover(h, id) == nil)
        #expect(h.model.rows.first { $0.id == id }?.coverURL == nil)

        // A book with no cover has none to remove: taking away a cover just chosen leaves no change.
        h.model.setCover(data: png)
        h.model.removeCover()
        #expect(h.draft?.cover == .keep)
        #expect(!h.model.hasUnsavedChanges)
    }

    /// A12
    @Test func coverChangesAreIgnoredWithSeveralBooksSelected() async throws {
        let h = try await Harness.demo()
        try await h.select(["Salt Road", "Quiet Rivers"])
        let before = h.model.inspecting
        h.model.setCover(data: png)
        await h.model.setCover(from: URL(fileURLWithPath: "/nowhere/cover.png"))
        h.model.removeCover()
        #expect(h.model.inspecting == before)
        #expect(h.model.alert == nil)
        #expect(!h.model.hasUnsavedChanges)
    }

    // MARK: A13 Changes that do not need Save

    /// A13
    @Test func readStatusIsSetAtOnceAndKeepsTheDraft() async throws {
        let h = try await Harness.demo()
        let id = try await h.select("Harbour of Glass")
        h.model.updateDraft {
            $0.title = "Harbour of Glass Revised"
            $0.tags = "glass; harbours"
            $0.rating = 5
        }
        h.model.setCover(data: png)
        let before = Date()

        await h.model.setReadStatus(.finished, for: [id])
        #expect(h.model.alert == nil)
        let stored = try h.book(id)
        #expect(stored.readStatus == .finished)
        #expect(stored.title == "Harbour of Glass")
        // The current date.
        let finished = try #require(stored.dateFinished)
        #expect(finished.timeIntervalSince(before) > -2 && finished.timeIntervalSinceNow < 2)
        #expect(h.model.sidebar.counts[.finished] == 4)
        #expect(h.model.rows.first { $0.id == id }?.book.readStatus == .finished)

        // The draft is of the fresh book, with the edits still in it.
        let draft = try #require(h.draft)
        #expect(draft.original == stored)
        #expect(h.detail?.row.book == stored)
        #expect(draft.title == "Harbour of Glass Revised")
        #expect(draft.tags == "glass; harbours")
        #expect(draft.rating == 5)
        #expect(draft.cover == .set(CoverImage(data: png, mime: "image/png")))
        #expect(draft.genre == "Fantasy")
        #expect(h.model.hasUnsavedChanges)

        // Saving afterwards writes the edits and keeps the status.
        await h.model.save()
        let saved = try h.book(id)
        #expect(saved.title == "Harbour of Glass Revised")
        #expect(saved.tags == ["glass", "harbours"])
        #expect(saved.readStatus == .finished)
    }

    /// A13: a book that the change takes out of the rows stays in the inspector while it
    /// has unsaved edits.
    @Test func aBookWithUnsavedEditsStaysInspectedWhenItLeavesTheRows() async throws {
        let h = try await Harness.demo()
        h.model.sidebarSelection = .unread
        await h.model.settle()
        let id = try await h.edit("Harbour of Glass", newTitle: "Harbour of Glass Revised")

        await h.model.setReadStatus(.finished, for: [id])
        #expect(!h.model.rows.contains { $0.id == id })
        #expect(h.model.selection == [id])
        #expect(h.draft?.title == "Harbour of Glass Revised")
        #expect(h.draft?.original.readStatus == .finished)
        #expect(h.model.prompt == nil)

        // Once the edits are let go, the selection follows the rows again.
        h.model.discardChanges()
        await h.model.settle()
        #expect(h.model.selection.isEmpty)
        #expect(h.model.inspecting == .nothing)
    }

    /// A13
    @Test func collectionChangesKeepTheDraft() async throws {
        let h = try await Harness.demo()
        let id = try await h.edit("Harbour of Glass", newTitle: "Harbour of Glass Revised")
        let favourites = try collectionId(h, "Favourites")
        let holiday = try collectionId(h, "Holiday Listening")
        #expect(h.detail?.collectionIds == [holiday])

        await h.model.add([id], toCollection: favourites)
        #expect(h.detail?.collectionIds == [favourites, holiday])
        #expect(h.draft?.title == "Harbour of Glass Revised")

        await h.model.remove([id], fromCollection: holiday)
        #expect(h.detail?.collectionIds == [favourites])
        #expect(h.draft?.title == "Harbour of Glass Revised")

        await h.model.createCollection(name: "Glass", adding: [id])
        #expect(h.detail?.collectionIds.count == 2)
        #expect(h.draft?.title == "Harbour of Glass Revised")
        #expect(h.model.hasUnsavedChanges)
        #expect(h.model.alert == nil)
    }

    /// A13: the same for an edit to several books.
    @Test func readStatusKeepsABulkDraft() async throws {
        let h = try await Harness.demo()
        let ids = try await h.select(["Harbour of Glass", "Quiet Rivers"])
        h.model.updateBulkDraft {
            $0.values[.genre] = "Sea Stories"
            $0.values[.tags] = "shelf one"
        }

        await h.model.setReadStatus(.inProgress, for: ids)
        let draft = try #require(h.bulkDraft)
        #expect(draft.values == [.genre: "Sea Stories", .tags: "shelf one"])
        #expect(draft.books.map(\.readStatus) == [.inProgress, .inProgress])
        #expect(draft.books == h.model.rows.filter { ids.contains($0.id) }.map(\.book))
        #expect(h.model.hasUnsavedChanges)
    }

    // MARK: A14 Opening and revealing

    /// A14
    @Test func openPrefersTheAudiobook() async throws {
        let h = try await Harness.demo()
        let clockmaker = try h.id("The Clockmaker's Apprentice")
        h.model.open(clockmaker)
        await h.model.settle()
        #expect(h.opener.opened.map(\.pathExtension) == ["m4b"])

        // The first part of several.
        let train = try h.id("Night Train to Vostok")
        h.model.open(train)
        await h.model.settle()
        #expect(h.opener.opened.last?.path == (try h.fileURLs(train).first?.path))

        // No audiobook: the ebook.
        h.model.open(try h.id("Quiet Rivers"))
        await h.model.settle()
        #expect(h.opener.opened.last?.pathExtension == "epub")
        #expect(h.opener.opened.count == 3)
        #expect(h.model.alert == nil)
    }

    /// A14
    @Test func listenAndReadOpenTheFirstFileOfThatKind() async throws {
        let h = try await Harness.demo()
        let clockmaker = try h.id("The Clockmaker's Apprentice")
        h.model.read(clockmaker)
        await h.model.settle()
        h.model.listen(clockmaker)
        await h.model.settle()
        #expect(h.opener.opened.map(\.pathExtension) == ["epub", "m4b"])
        #expect(h.model.alert == nil)

        // Nothing of that kind: said, and nothing opened.
        h.model.listen(try h.id("Quiet Rivers"))
        await h.model.settle()
        #expect(h.model.alert == "This book has no audiobook file.")
        h.model.alert = nil
        h.model.read(try h.id("Salt Road"))
        await h.model.settle()
        #expect(h.model.alert == "This book has no ebook file.")
        #expect(h.opener.opened.count == 2)
    }

    /// A14
    @Test func aMissingFileIsNotOpened() async throws {
        let h = try await Harness.demo()
        let id = try h.id("Quiet Rivers")
        let file = try #require(try h.fileURLs(id).first)
        try FileManager.default.removeItem(at: file)

        for action in [h.model.open, h.model.read] {
            h.model.alert = nil
            action(id)
            await h.model.settle()
            #expect(h.model.alert?.contains(file.lastPathComponent) == true)
        }
        #expect(h.opener.opened.isEmpty)
    }

    /// A14: a filed book's folder; for a book left in place, its first file.
    @Test func revealShowsFoldersOfFiledBooksAndFilesOfTheRest() async throws {
        let h = try await Harness.demo()
        let train = try h.id("Night Train to Vostok")
        let attic = try h.id("Voices from the Attic")
        #expect(try h.book(attic).folderPath == nil)
        let folder = try #require(try h.book(train).folderPath)

        h.model.reveal([attic, train])
        await h.model.settle()
        let revealed = try #require(h.opener.revealed.first)
        #expect(h.opener.revealed.count == 1)
        // In row order.
        #expect(revealed.map(\.standardizedFileURL.path) == [
            try h.store().url(forFolder: folder).standardizedFileURL.path,
            try #require(try h.fileURLs(attic).first).standardizedFileURL.path,
        ])
        #expect(revealed.allSatisfy { exists($0) })

        h.model.reveal([])
        await h.model.settle()
        #expect(h.opener.revealed.count == 1)
    }

    /// A14
    @Test func revealingOneFile() async throws {
        let h = try await Harness.demo()
        try await h.select("Night Train to Vostok")
        let file = try #require(h.detail?.files.last)
        h.model.reveal(file: file)
        #expect(h.opener.revealed == [[file.url]])
    }

    // MARK: A10 What is typed while a save runs

    /// A10: text typed between Save and its end is neither saved nor lost: it is still
    /// in the draft afterwards, as an unsaved change to the saved book.
    @Test func whatIsTypedDuringASaveIsKept() async throws {
        let h = try await Harness.demo()
        let id = try await h.edit("Salt Road", newTitle: "Salt Road X")
        h.model.updateDraft { $0.genre = "Adventure" }
        let gate = Gate()
        h.model.beforeOperation = { await gate.wait() }
        let saving = Task { await h.model.save() }
        await gate.arrival()
        h.model.updateDraft {
            $0.title = "Salt Road XY"
            $0.publisher = "Typed During Save"
            $0.clickStar(5)
        }
        await gate.release()
        await saving.value

        #expect(try h.book(id).title == "Salt Road X")
        #expect(try h.book(id).genre == "Adventure")
        #expect(try h.book(id).publisher == nil)
        let draft = try #require(h.draft)
        #expect(draft.original.title == "Salt Road X")
        #expect(draft.title == "Salt Road XY")
        #expect(draft.publisher == "Typed During Save")
        #expect(draft.rating == 5)
        #expect(draft.genre == "Adventure")
        #expect(draft.isDirty)

        // Saved again, it is all there, and nothing is left over.
        h.model.beforeOperation = nil
        await h.model.save()
        #expect(try h.book(id).title == "Salt Road XY")
        #expect(try h.book(id).publisher == "Typed During Save")
        #expect(try h.book(id).rating == 5)
        #expect(!h.model.hasUnsavedChanges)
    }

    /// A10: the same for several books.
    @Test func whatIsTypedDuringABulkSaveIsKept() async throws {
        let h = try await Harness.demo()
        let ids = try await h.select(["Salt Road", "Quiet Rivers"])
        h.model.setBulkText("Travel", for: .genre)
        let gate = Gate()
        h.model.beforeOperation = { await gate.wait() }
        let saving = Task { await h.model.save() }
        await gate.arrival()
        h.model.setBulkText("Harbour Press", for: .publisher)
        await gate.release()
        await saving.value

        for id in ids {
            #expect(try h.book(id).genre == "Travel")
            #expect(try h.book(id).publisher != "Harbour Press")
        }
        #expect(h.bulkDraft?.values == [.publisher: "Harbour Press"])
        #expect(h.model.hasUnsavedChanges)
    }

    /// A10: a save with nothing typed meanwhile leaves nothing unsaved, as before.
    @Test func aSaveWithNothingTypedMeanwhileLeavesNothingUnsaved() async throws {
        let h = try await Harness.demo()
        try await h.edit("Salt Road", newTitle: "Salt Road X")
        await h.model.save()
        #expect(!h.model.hasUnsavedChanges)
        #expect(h.draft?.title == "Salt Road X")
        #expect(h.model.sentDraft == nil)
    }

    /// G: Save is offered by the File menu whenever there is something to save.
    @Test func saveIsOfferedWhenThereAreUnsavedChangesAndNothingRuns() async throws {
        let h = try await Harness.demo()
        #expect(!h.model.canSave)
        try await h.edit("Salt Road", newTitle: "Salt Road X")
        #expect(h.model.canSave)
        let gate = Gate()
        h.model.beforeOperation = { await gate.wait() }
        let quiet = try h.id("Quiet Rivers")
        let running = Task { await h.model.setReadStatus(.finished, for: [quiet]) }
        await gate.arrival()
        #expect(!h.model.canSave)
        await gate.release()
        await running.value
        #expect(h.model.canSave)
    }

    // MARK: A15 Removing

    /// A started model on a demo library whose "Trash" is a folder of the test's own.
    private func demoWithATrash() async throws -> (h: Harness, trash: URL, trashed: () -> [String]) {
        let h = try await Harness.demo(start: false)
        let trash = try makeTempDir()
        h.model.trashItem = { url in
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent))
        }
        await h.model.start()
        return (h, trash, { (try? FileManager.default.contentsOfDirectory(atPath: trash.path).sorted()) ?? [] })
    }

    /// A15: "Move Files to Trash" sends the files to the Trash and removes the books.
    @Test func removingWithTheFilesSendsThemToTheTrash() async throws {
        let (h, _, trashed) = try await demoWithATrash()
        let quiet = try h.id("Quiet Rivers")
        let files = try h.fileURLs(quiet)
        let folder = files[0].deletingLastPathComponent()
        h.model.requestRemove([quiet])
        await h.model.confirmRemove(moveFilesToTrash: true)

        #expect(h.model.result == nil)
        #expect(h.model.alert == nil)
        #expect(try h.store().book(id: quiet) == nil)
        #expect(files.allSatisfy { !exists($0) })
        #expect(trashed() == files.map(\.lastPathComponent).sorted())
        // The book's emptied folder goes too.
        #expect(!exists(folder))
        #expect(h.model.rows.count == 11)
    }

    /// A15: "Remove from Library Only" sends nothing to the Trash.
    @Test func removingFromTheLibraryOnlyTrashesNothing() async throws {
        let (h, _, trashed) = try await demoWithATrash()
        let quiet = try h.id("Quiet Rivers")
        let files = try h.fileURLs(quiet)
        h.model.requestRemove([quiet])
        await h.model.confirmRemove(moveFilesToTrash: false)
        #expect(try h.store().book(id: quiet) == nil)
        #expect(files.allSatisfy { exists($0) })
        #expect(trashed().isEmpty)
    }

    /// A15: a file that cannot be sent to the Trash keeps its book, and the result says why.
    @Test func aFileThatCannotBeTrashedKeepsItsBook() async throws {
        let h = try await Harness.demo(start: false)
        struct NoTrash: LocalizedError { var errorDescription: String? { "This disk has no Trash." } }
        h.model.trashItem = { _ in throw NoTrash() }
        await h.model.start()
        let quiet = try h.id("Quiet Rivers")
        h.model.requestRemove([quiet])
        await h.model.confirmRemove(moveFilesToTrash: true)
        #expect(try h.store().book(id: quiet) != nil)
        #expect(try h.fileURLs(quiet).allSatisfy { exists($0) })
        #expect(h.model.result?.headline == "1 book could not be removed")
        #expect(h.model.result?.problems.first?.detail == "This disk has no Trash.")
    }

    /// A15: a book whose files were left where they were found, outside the library
    /// folder: the question says where they are, and they are sent to the Trash only if
    /// that is what was chosen.
    @Test func filesOutsideTheLibraryAreNamedAndTrashedOnlyWhenChosen() async throws {
        let (h, _, trashed) = try await demoWithATrash()
        let inbox = try Harness.inbox()
        let attic = inbox.appendingPathComponent("Downloads/voices_from_the_attic.m4b")
        for round in ["keep", "trash"] {
            await h.model.beginImport([attic])
            await h.model.confirmImport()
            h.model.result = nil
            let id = try #require(h.model.rows.first { $0.outsideFiles.isEmpty == false }?.id)
            #expect(try h.fileURLs(id).map(\.lastPathComponent) == ["voices_from_the_attic.m4b"])

            h.model.requestRemove([id, try h.id("Salt Road")])
            let prompt = try #require(h.model.prompt)
            guard case .removeBooks(_, _, let outside) = prompt else {
                Issue.record("not the remove question")
                return
            }
            #expect(outside.count == 1)
            #expect(outside.first.map { URL(fileURLWithPath: $0).lastPathComponent } == "voices_from_the_attic.m4b")
            #expect(prompt.message.contains("These files are not in the library folder"))
            #expect(prompt.message.contains(outside[0]))

            if round == "keep" {
                h.model.prompt = nil
                h.model.requestRemove([id])
                await h.model.confirmRemove(moveFilesToTrash: false)
                #expect(exists(attic))
                #expect(trashed().isEmpty)
            } else {
                h.model.prompt = nil
                h.model.requestRemove([id])
                await h.model.confirmRemove(moveFilesToTrash: true)
                #expect(!exists(attic))
                #expect(trashed() == ["voices_from_the_attic.m4b"])
            }
            #expect(try h.store().book(id: id) == nil)
        }
    }

    /// A15: books whose files are all in the library say nothing more.
    @Test func theRemoveQuestionSaysNothingMoreForFilesInTheLibrary() async throws {
        let h = try await Harness.demo()
        h.model.requestRemove(try h.ids(["Salt Road", "Voices from the Attic"]))
        guard case .removeBooks(_, _, let outside) = try #require(h.model.prompt) else { return }
        #expect(outside.isEmpty)
        #expect(h.model.prompt?.message == "You can move the files to the Trash as well, or leave them where they are.")
    }

    /// A15. Only "keep the files" is tried: nothing in these tests goes to the real Trash.
    @Test func removingAsksFirstThenRemoves() async throws {
        let h = try await Harness.demo()
        h.recordBusyLabels()
        let ids = try await h.select(["Salt Road", "Quiet Rivers"])
        let quiet = try h.id("Quiet Rivers")
        let salt = try h.id("Salt Road")
        let files = try h.fileURLs(quiet) + h.fileURLs(salt)

        h.model.requestRemove(ids)
        #expect(h.model.prompt == .removeBooks(ids: [quiet, salt], titles: ["Quiet Rivers", "Salt Road"]))
        #expect(try h.store().books().count == 12)

        await h.model.confirmRemove(moveFilesToTrash: false)
        #expect(h.busyLabels == ["Removing 2 books…"])
        #expect(h.model.prompt == nil)
        #expect(h.model.alert == nil)
        #expect(h.model.result == nil)
        #expect(try h.store().books().count == 10)
        #expect(h.model.rows.count == 10)
        #expect(h.model.sidebar.counts[.allBooks] == 10)
        #expect(h.model.selection.isEmpty)
        #expect(h.model.inspecting == .nothing)
        #expect(files.allSatisfy { exists($0) })
    }

    /// A15: dismissing the question removes nothing, and there is then nothing to confirm.
    @Test func dismissingTheRemoveQuestionRemovesNothing() async throws {
        let h = try await Harness.demo()
        h.model.requestRemove([try h.id("Salt Road")])
        #expect(h.model.prompt != nil)
        h.model.prompt = nil
        await h.model.confirmRemove(moveFilesToTrash: false)
        #expect(h.model.rows.count == 12)

        h.model.requestRemove([])
        #expect(h.model.prompt == nil)
    }

    /// A15: books that could not be removed are listed.
    @Test func removalFailuresGoToTheResult() async throws {
        let h = try await Harness.demo()
        let salt = try h.id("Salt Road")
        let quiet = try h.id("Quiet Rivers")
        h.model.requestRemove([salt, quiet])
        // Gone by other means before the answer came.
        try h.store().deleteBook(id: salt)

        await h.model.confirmRemove(moveFilesToTrash: false)
        let result = try #require(h.model.result)
        #expect(!result.isClean)
        #expect(result.headline == "1 book removed, 1 could not be removed")
        #expect(result.problems == [.init(title: "Salt Road", detail: "That book is no longer in the library.")])
        #expect(h.model.rows.count == 10)
    }

    /// A15: removing the book being edited needs no second question.
    @Test func removingTheBookBeingEdited() async throws {
        let h = try await Harness.demo()
        let id = try await h.edit("Salt Road", newTitle: "Salt Road Revised")
        h.model.requestRemove([id])
        await h.model.confirmRemove(moveFilesToTrash: false)
        #expect(h.model.selection.isEmpty)
        #expect(h.model.inspecting == .nothing)
        #expect(!h.model.hasUnsavedChanges)
        #expect(h.model.rows.count == 11)
    }

    // MARK: A16 One operation at a time

    /// A16: Undo pressed while a save is in flight does nothing.
    @Test func undoDuringASaveDoesNothing() async throws {
        let h = try await Harness.demo()
        // Something that could be undone.
        let quiet = try await h.edit("Quiet Rivers", newTitle: "Quieter Rivers")
        await h.model.save()
        let label = try #require(h.model.undoLabel)

        let salt = try await h.edit("Salt Road", newTitle: "Saltier Road")
        let gate = Gate()
        h.model.beforeOperation = { await gate.wait() }
        let saving = Task { await h.model.save() }
        await gate.arrival()
        #expect(h.model.busyLabel == "Saving…")

        await h.model.undo()
        #expect(h.model.busyLabel == "Saving…")
        #expect(h.model.alert == nil)
        #expect(try h.book(quiet).title == "Quieter Rivers")
        #expect(try LibraryService(store: h.store()).undoLabel() == label)

        await gate.release()
        await saving.value
        #expect(h.model.busyLabel == nil)
        #expect(try h.book(quiet).title == "Quieter Rivers")
        #expect(try h.book(salt).title == "Saltier Road")
    }

    /// A16: nothing else that changes the library starts either.
    @Test func otherOperationsDoNothingWhileOneRuns() async throws {
        let h = try await Harness.demo()
        let salt = try await h.select("Salt Road")
        let fileId = try #require(h.detail?.files.first?.id)
        let favourites = try collectionId(h, "Favourites")
        let quiet = try h.id("Quiet Rivers")
        let other = try makeTempDir()

        let gate = Gate()
        h.model.beforeOperation = { await gate.wait() }
        let running = Task { await h.model.setReadStatus(.unread, for: [salt]) }
        await gate.arrival()
        #expect(h.model.busyLabel != nil)

        h.model.updateDraft { $0.title = "Saltier Road" }
        await h.model.save()
        await h.model.setReadStatus(.finished, for: [quiet, salt])
        await h.model.rewriteTags()
        await h.model.setRole(.audio, forFile: 999_999)
        await h.model.locate(fileId: fileId, at: other)
        await h.model.createCollection(name: "New", adding: [salt])
        await h.model.renameCollection(id: favourites, to: "Best")
        await h.model.add([quiet], toCollection: try collectionId(h, "Holiday Listening"))
        await h.model.remove([salt], fromCollection: favourites)
        await h.model.deleteCollection(id: favourites)
        h.model.requestRemove([quiet])
        await h.model.confirmRemove(moveFilesToTrash: false)
        await h.model.confirmChooseLibrary(other)
        await h.model.retryLibrary()
        await h.model.start()
        #expect(h.model.busyLabel != nil)
        #expect(h.model.alert == nil)
        #expect(h.model.prompt == nil)
        // Choosing a library is refused in words: the folder was picked in a panel, and
        // nothing happening would look like a fault.
        #expect(!h.model.canChooseLibrary)
        await h.model.chooseLibrary(other)
        #expect(h.model.alert == "VoxCarrel is busy. Choose the library folder again when it has finished.")
        h.model.alert = nil
        #expect(h.model.prompt == nil)

        // Reading still works.
        h.model.searchText = "quiet"
        await h.model.latestReload?.value
        #expect(h.model.prompt == .unsavedChanges)
        await h.model.resolveUnsaved(.discard)
        #expect(h.titles == ["Quiet Rivers"])
        h.model.open(quiet)

        await gate.release()
        await running.value
        await h.model.settle()
        #expect(h.model.busyLabel == nil)
        #expect(h.model.status == .available(h.root))
        #expect(h.opener.opened.count == 1)
        #expect(try h.book(salt).title == "Salt Road")
        #expect(try h.book(salt).readStatus == .unread)
        #expect(try h.book(quiet).readStatus == .finished)
        #expect(h.model.sidebar.collections.map(\.name) == ["Favourites", "Holiday Listening"])
        #expect(try titles(h, inCollection: favourites) == ["Quiet Rivers", "Salt Road", "The Lighthouse Keeper"])
        #expect(try h.store().books().count == 12)
        #expect(h.model.undoLabel == Harness.demoUndoLabel)
        #expect(!exists(other.appendingPathComponent(LibraryStore.databaseFileName)))
    }

    /// A16: with no library open there is nothing to work on.
    @Test func operationsDoNothingWithNoLibrary() async throws {
        let h = try Harness(root: try makeTempDir(), choose: false)
        await h.model.start()
        h.recordBusyLabels()
        await h.model.undo()
        await h.model.save()
        await h.model.setReadStatus(.finished, for: [1])
        await h.model.createCollection(name: "New", adding: [])
        await h.model.rewriteTags()
        h.model.requestRemove([1])
        h.model.open(1)
        h.model.reveal([1])
        await h.model.settle()
        #expect(h.busyLabels.isEmpty)
        #expect(h.model.alert == nil)
        #expect(h.model.prompt == nil)
        #expect(h.opener.opened.isEmpty && h.opener.revealed.isEmpty)
    }

    // MARK: A17 Errors

    /// A17: the error is said in a sentence, and what the library holds now is shown.
    @Test func anErrorBecomesAnAlertAndStateIsReloaded() async throws {
        let h = try await Harness.demo()
        let salt = try await h.select("Salt Road")
        // Changed behind the model's back, so a reload can be told from none.
        try h.store().setReadStatus(.unread, for: [salt])
        #expect(h.model.sidebar.counts[.finished] == 3)

        await h.model.setRole(.audio, forFile: 999_999)
        #expect(h.model.alert == "That file is no longer in the library.")
        #expect(h.model.busyLabel == nil)
        #expect(h.model.sidebar.counts[.finished] == 2)
        #expect(h.model.rows.first { $0.id == salt }?.book.readStatus == .unread)
        #expect(h.detail?.row.book.readStatus == .unread)
    }

    /// A17
    @Test func aFailedLocateSaysWhy() async throws {
        let h = try await Harness.demo()
        try await h.select("Salt Road")
        let file = try #require(h.detail?.files.first)
        // The file is not missing, so there is nothing to locate.
        await h.model.locate(fileId: file.id, at: try touch(try makeTempDir().appendingPathComponent("other.m4b")))
        let alert = try #require(h.model.alert)
        #expect(alert.hasPrefix("That file could not be used in place of the missing one"))
        #expect(h.model.busyLabel == nil)
    }

    // MARK: A18 Undo

    /// A18
    @Test func undoReversesTheLastOperationAndReloads() async throws {
        let h = try await Harness.demo()
        h.recordBusyLabels()
        let id = try await h.edit("Salt Road", newTitle: "Saltier Road")
        let files = try h.fileURLs(id)
        await h.model.save()
        #expect(h.model.undoLabel != nil)
        #expect(try h.fileURLs(id) != files)

        await h.model.undo()
        #expect(h.busyLabels == ["Saving…", "Undoing…"])
        #expect(h.model.alert == nil)
        #expect(h.model.undoLabel == nil)
        #expect(try h.book(id).title == "Salt Road")
        #expect(try h.fileURLs(id) == files)
        #expect(h.titles.contains("Salt Road") && !h.titles.contains("Saltier Road"))
        #expect(h.draft?.title == "Salt Road")
        #expect(h.detail?.files.map(\.url.path) == files.map(\.path))
    }

    /// A18
    @Test func aBlockedUndoSaysWhyAndCanBeTriedAgain() async throws {
        let h = try await Harness.demo()
        let id = try await h.edit("Salt Road", newTitle: "Saltier Road")
        let original = try #require(try h.fileURLs(id).first)
        await h.model.save()
        let label = try #require(h.model.undoLabel)
        // Something is now in the way where the file used to be.
        try touch(original)

        await h.model.undo()
        let alert = try #require(h.model.alert)
        #expect(alert.hasPrefix("Undo could not put the files back, so nothing was changed."))
        #expect(h.model.undoLabel == label)
        #expect(try h.book(id).title == "Saltier Road")
        #expect(h.model.busyLabel == nil)

        try FileManager.default.removeItem(at: original)
        h.model.alert = nil
        await h.model.undo()
        #expect(h.model.alert == nil)
        #expect(try h.book(id).title == "Salt Road")
        #expect(h.model.undoLabel == nil)
    }

    /// A18
    @Test func undoWithNothingToUndoSaysSo() async throws {
        let h = try Harness(root: try makeTempDir())
        await h.model.start()
        #expect(h.model.undoLabel == nil)
        await h.model.undo()
        #expect(h.model.alert == "There is nothing to undo.")
        #expect(h.model.busyLabel == nil)
    }

    /// A18, A13: undoing something else leaves an unsaved draft's edits in place.
    @Test func undoKeepsUnsavedEdits() async throws {
        let h = try await Harness.demo()
        let id = try await h.edit("Salt Road", newTitle: "Saltier Road")
        await h.model.save()
        h.model.updateDraft { $0.genre = "Sea Stories" }

        await h.model.undo()
        #expect(try h.book(id).title == "Salt Road")
        #expect(h.draft?.title == "Salt Road")
        #expect(h.draft?.genre == "Sea Stories")
        #expect(h.model.hasUnsavedChanges)
    }

    // MARK: Collections

    @Test func creatingACollection() async throws {
        let h = try await Harness.demo()
        let ids = try h.ids(["Salt Road", "Quiet Rivers"])
        await h.model.createCollection(name: "  Sea Shelf  ", adding: ids)
        #expect(h.model.alert == nil)
        #expect(h.model.sidebar.collections.map(\.name) == ["Favourites", "Holiday Listening", "Sea Shelf"])
        #expect(try titles(h, inCollection: try collectionId(h, "Sea Shelf")) == ["Quiet Rivers", "Salt Road"])

        await h.model.createCollection(name: "Empty One", adding: [])
        #expect(try titles(h, inCollection: try collectionId(h, "Empty One")).isEmpty)
    }

    /// A blank name, or one another collection has (ignoring case), is refused in a plain sentence.
    @Test func aCollectionNeedsANameOfItsOwn() async throws {
        let h = try await Harness.demo()
        h.recordBusyLabels()
        await h.model.createCollection(name: "   ", adding: [])
        #expect(h.model.alert == "A collection needs a name.")

        h.model.alert = nil
        await h.model.createCollection(name: " favourites ", adding: [])
        #expect(h.model.alert == "There is already a collection named \"Favourites\".")

        let holiday = try collectionId(h, "Holiday Listening")
        h.model.alert = nil
        await h.model.renameCollection(id: holiday, to: "")
        #expect(h.model.alert == "A collection needs a name.")

        h.model.alert = nil
        await h.model.renameCollection(id: holiday, to: "FAVOURITES")
        #expect(h.model.alert == "There is already a collection named \"Favourites\".")

        #expect(h.model.sidebar.collections.map(\.name) == ["Favourites", "Holiday Listening"])
        #expect(h.busyLabels.isEmpty)
    }

    @Test func renamingACollection() async throws {
        let h = try await Harness.demo()
        let holiday = try collectionId(h, "Holiday Listening")
        await h.model.renameCollection(id: holiday, to: " Travel ")
        #expect(h.model.alert == nil)
        #expect(h.model.sidebar.collections.map(\.name) == ["Favourites", "Travel"])
        #expect(h.model.sidebar.collections.last?.id == holiday)

        // Its own name in other letters is not a clash.
        await h.model.renameCollection(id: holiday, to: "TRAVEL")
        #expect(h.model.alert == nil)
        #expect(h.model.sidebar.collections.map(\.name) == ["Favourites", "TRAVEL"])
    }

    @Test func addingToAndRemovingFromACollection() async throws {
        let h = try await Harness.demo()
        let favourites = try collectionId(h, "Favourites")
        h.model.sidebarSelection = .collection(favourites)
        await h.model.settle()
        #expect(h.model.rows.count == 3)

        await h.model.add(try h.ids(["Night Train to Vostok", "Salt Road"]), toCollection: favourites)
        #expect(h.model.alert == nil)
        #expect(h.titles == ["Night Train to Vostok", "Quiet Rivers", "Salt Road", "The Lighthouse Keeper"])

        // The menus offer it for the collection that is being looked at, by name.
        let ids = try await h.select(["Quiet Rivers", "Salt Road"])
        #expect(h.model.shownCollection?.id == favourites)
        #expect(h.model.removeFromCollectionTitle == "Remove from \"Favourites\"")
        #expect(h.model.selectionCommands.removeFromCollection)
        #expect(!h.model.commands(for: []).removeFromCollection)
        await h.model.removeFromShownCollection(ids)
        #expect(h.titles == ["Night Train to Vostok", "The Lighthouse Keeper"])
        #expect(h.model.selection.isEmpty)
        #expect(try h.store().books().count == 12)
    }

    /// Removing from a collection is offered only while a collection is what is shown.
    @Test func removingFromACollectionNeedsACollectionToBeShown() async throws {
        let h = try await Harness.demo()
        let ids = try await h.select(["Quiet Rivers"])
        #expect(h.model.shownCollection == nil)
        #expect(h.model.removeFromCollectionTitle == nil)
        #expect(!h.model.selectionCommands.removeFromCollection)
        h.recordBusyLabels()
        await h.model.removeFromShownCollection(ids)
        #expect(h.busyLabels.isEmpty)
        #expect(try titles(h, inCollection: try collectionId(h, "Favourites")).contains("Quiet Rivers"))
    }

    @Test func deletingACollection() async throws {
        let h = try await Harness.demo()
        let favourites = try collectionId(h, "Favourites")
        let holiday = try collectionId(h, "Holiday Listening")
        h.model.sidebarSelection = .collection(favourites)
        await h.model.settle()

        // Another collection: the one being looked at stays.
        await h.model.deleteCollection(id: holiday)
        #expect(h.model.sidebar.collections.map(\.name) == ["Favourites"])
        #expect(h.model.sidebarSelection == .collection(favourites))
        #expect(h.model.rows.count == 3)

        // The one being looked at: back to all books.
        await h.model.deleteCollection(id: favourites)
        #expect(h.model.alert == nil)
        #expect(h.model.sidebar.collections.isEmpty)
        #expect(h.model.sidebarSelection == .allBooks)
        #expect(h.model.rows.count == 12)
    }

    /// A browse value that an edit leaves no book with falls back to all books.
    @Test func aBrowseValueThatDisappearsFallsBackToAllBooks() async throws {
        let h = try await Harness.demo()
        h.model.sidebarSelection = .browse(.genre, "Poetry")
        await h.model.settle()
        #expect(h.titles == ["Quiet Rivers"])
        let id = try await h.select("Quiet Rivers")
        h.model.updateDraft { $0.genre = "Verse" }

        await h.model.save()
        #expect(h.model.sidebarSelection == .allBooks)
        #expect(h.model.rows.count == 12)
        #expect(h.model.selection == [id])
        #expect(h.draft?.genre == "Verse")
    }
}

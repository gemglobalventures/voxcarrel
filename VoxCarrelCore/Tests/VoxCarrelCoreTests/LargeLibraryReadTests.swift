import Foundation
import Testing
@testable import VoxCarrelCore
import VoxCarrelFixtures

/// LR1–LR5: the readings a large library is counted and listed by give what the slow
/// way round gives.
@Suite struct LargeLibraryReadTests {
    typealias F = LibraryFixture

    /// A few books of every sort: with audio, with an ebook, owned elsewhere, in each
    /// reading state, one needing attention, one hidden, with tags.
    private func library(_ f: F) throws -> (hidden: Int64, all: [Int64]) {
        var ids: [Int64] = []
        let audio = try f.importedId(try f.service.importItems([ImportItem(candidate: f.candidate([try f.makeM4B("a.m4b", tags: F.meta("Sound", "A"))], F.meta("Sound", "A")))]).outcomes[0])
        let ebook = try f.importedId(try f.service.importItems([ImportItem(candidate: f.candidate([try f.makeEPUB("e.epub")], F.meta("Words", "B")))]).outcomes[0])
        ids += [audio, ebook]
        for (index, status) in [ReadStatus.unread, .inProgress, .finished, .finished].enumerated() {
            var book = Book(metadata: BookMetadata(title: "Away \(index)", authors: ["C"]), folderPath: nil, needsAttention: index == 0, dateAdded: Date())
            book.readStatus = status
            book.tags = index.isMultiple(of: 2) ? ["kept", "Travel"] : ["kept"]
            book.externalCopies = [ExternalCopy(kind: index == 3 ? .kindle : .audible, form: index == 3 ? .ebook : .audio, itemId: "B\(index)")]
            ids.append(try #require(try f.store.insert(book, files: []).id))
        }
        try f.store.setHidden(true, bookIds: [ids[4]])
        return (ids[4], ids)
    }

    @Test func LR1_countsAndIdsAreThoseOfTheListsThemselvesInBothScopes() throws {
        let f = try F()
        _ = try library(f)
        func check() throws {
            #expect(try f.store.bookCount() == f.store.books().count)
            for role in [FileRole.audio, .ebook, .extra] {
                #expect(try f.store.bookCount(having: role) == f.store.books(having: role).count, "\(role)")
                #expect(try f.store.bookIds(having: role) == Set(f.store.books(having: role).compactMap(\.id)), "\(role)")
            }
            for status in [ReadStatus.unread, .inProgress, .finished] {
                #expect(try f.store.bookCount(readStatus: status) == f.store.books(readStatus: status).count, "\(status)")
            }
            #expect(try f.store.bookCount(needsAttention: true) == f.store.books(needsAttention: true).count)
            #expect(try f.store.bookCount(having: .audio, readStatus: .finished) == f.store.books(having: .audio, readStatus: .finished).count)
            #expect(try Set(f.store.allTags()) == Set(f.store.books().flatMap(\.tags)))
        }
        try check()
        #expect(try f.store.bookCount() == 6 && f.store.bookCount(readStatus: .finished) == 2)
        try BookScope.visible { () throws -> Void in
            try check()
            #expect(try f.store.bookCount() == 5 && f.store.bookCount(readStatus: .finished) == 1)
            // A tag only the hidden book has is not listed.
            #expect(try Set(f.store.allTags()) == ["kept", "Travel"])
        }
    }

    @Test func LR2_everyShelfIsCountedInOnePassAsItIsOneByOne() throws {
        let f = try F()
        _ = try library(f)
        let shelves = try f.service.smartShelves()
        #expect(!shelves.isEmpty)
        for scoped in [false, true] {
            try BookScope.$visibleOnly.withValue(scoped) {
                let counts = try f.service.bookCounts(on: shelves)
                for shelf in shelves {
                    #expect(counts[try #require(shelf.id)] == (try f.service.books(on: shelf).count), "\(shelf.name) \(scoped)")
                }
            }
        }
        // A shelf not yet stored has no id to be counted under.
        var draft = try #require(shelves.first)
        draft.id = nil
        #expect(try f.service.bookCounts(on: [draft]).isEmpty)
    }

    @Test func LR3_whatIsReadOnceIsReadAgainOutsideThatReading() throws {
        let f = try F()
        _ = try library(f)
        var inside = 0
        try BookScope.readingOnce { () throws -> Void in
            inside = try f.store.books().count
            #expect(try f.store.books().count == inside && f.store.allFiles().count == 2)
            // Each scope has its own answer, kept apart.
            #expect(try BookScope.visible { try f.store.books().count } == inside - 1)
            #expect(try f.store.books().count == inside)
            #expect(try BookScope.visible { try f.store.allFiles().count } == 2)
        }
        // After it, the library is read afresh: a book added since is there.
        _ = try f.store.insert(Book(metadata: BookMetadata(title: "New", authors: ["D"])), files: [])
        #expect(try f.store.books().count == inside + 1)
        try BookScope.readingOnce { () throws -> Void in #expect(try f.store.books().count == inside + 1) }
    }

    @Test func LR4_everyCoverReadInOnePassIsTheOneAskedForBookByBook() throws {
        let f = try F()
        let (_, ids) = try library(f)
        let covers = f.service.covers
        #expect(covers.all().isEmpty || covers.all().keys.allSatisfy { covers.url(for: $0) != nil })
        try covers.set(CoverImage(data: MediaFixtures.makeImage(.jpeg), mime: "image/jpeg"), for: ids[2])
        try covers.set(CoverImage(data: MediaFixtures.makeImage(.png), mime: "image/png"), for: ids[3])
        // A stray file in the covers folder is nobody's cover.
        let folder = try #require(covers.url(for: ids[2])).deletingLastPathComponent()
        try Data("x".utf8).write(to: folder.appendingPathComponent("notes.txt"))
        try Data("x".utf8).write(to: folder.appendingPathComponent("abc.jpg"))
        let all = covers.all()
        for id in ids {
            #expect(all[id]?.url == covers.url(for: id), "\(id)")
        }
        #expect(all[ids[2]] != nil && all[ids[3]] != nil)
        let stated = try #require(all[ids[2]])
        #expect(stated.modified == (try stated.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate))
        // Replaced by one of another kind, the old one is gone from both.
        try covers.set(CoverImage(data: MediaFixtures.makeImage(.png), mime: "image/png"), for: ids[2])
        #expect(covers.all()[ids[2]]?.url == covers.url(for: ids[2]) && covers.url(for: ids[2])?.pathExtension == "png")
    }

    @Test func LR5_aLibraryWithNoCoversFolderHasNoCovers() throws {
        let f = try F()
        #expect(f.service.covers.all().isEmpty)
    }
}

import DemoContent
import Foundation
import Testing
import VoxCarrelAppCore
import VoxCarrelCore
import VoxCarrelFixtures

@Suite struct ImportReviewTests {
    // MARK: Building blocks (nothing here touches a file)

    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/inbox/\(name)")
    }

    private func file(_ name: String, _ role: FileRole? = nil) -> CandidateFile {
        let url = url(name)
        return CandidateFile(url: url, role: role ?? FileFormat(url: url)?.defaultRole ?? .extra)
    }

    private func seed(
        _ title: String, author: String? = "Ann Author", files: [CandidateFile], cover: CoverImage? = nil,
        match: Book? = nil
    ) -> ImportSeed {
        ImportSeed(
            candidate: CandidateBook(
                files: files, metadata: BookMetadata(title: title, authors: author.map { [$0] } ?? [])),
            cover: cover, existingMatch: match)
    }

    private func cover(_ byte: UInt8) -> CoverImage {
        CoverImage(data: Data([byte]), mime: "image/jpeg")
    }

    private func libraryBook(_ title: String, id: Int64 = 7, folder: String? = "Ann Author/Atlas") -> Book {
        var book = Book(
            metadata: BookMetadata(title: title, authors: ["Ann Author"]), folderPath: folder,
            dateAdded: Date(timeIntervalSince1970: 1_000_000))
        book.id = id
        return book
    }

    private func review(_ seeds: [ImportSeed], copy: Bool = false) -> ImportReview {
        ImportReview(seeds: seeds, skipped: [], copyInsteadOfMove: copy)
    }

    // MARK: R1

    /// R1
    @Test func initMakesOneIncludedEntryPerSeed() {
        let match = libraryBook("Atlas")
        let seeds = [
            seed("Atlas", files: [file("atlas.m4b")], cover: cover(1), match: match),
            seed("Rivers", files: [file("rivers.epub")]),
        ]
        let skipped = [url("notes.txt")]
        let review = ImportReview(seeds: seeds, skipped: skipped, copyInsteadOfMove: true)

        #expect(review.entries.map(\.candidate) == seeds.map(\.candidate))
        #expect(review.entries.allSatisfy { $0.included })
        #expect(review.entries.allSatisfy { !$0.coverChanged })
        #expect(review.entries.map(\.cover) == [cover(1), nil])
        #expect(review.entries.map(\.existingMatch) == [match, nil])
        #expect(Set(review.entries.map(\.id)).count == 2)
        #expect(review.skipped == skipped)
        #expect(review.copyInsteadOfMove)
        #expect(review.includedCount == 2)
    }

    /// R1
    @Test func anEntryWithAMatchStartsAsAddedToIt() {
        let review = review([seed("Atlas", files: [file("atlas.m4b")], match: libraryBook("Atlas"))])
        #expect(review.entries[0].addToExisting)
    }

    // MARK: R2

    /// R2
    @Test func anEntryWithNoFilesIsBlocked() {
        var review = review([
            seed("Atlas", files: []),
            seed("Rivers", files: [], match: libraryBook("Rivers")),
        ])
        #expect(review.readiness(of: review.entries[0].id) == .blocked("No files"))
        // Adding nothing to an existing book is refused by the engine as well.
        #expect(review.readiness(of: review.entries[1].id) == .blocked("No files"))
        review.entries[1].addToExisting = false
        #expect(review.readiness(of: review.entries[1].id) == .blocked("No files"))
    }

    /// R2
    @Test func aNewBookOfOnlyExtrasIsBlocked() {
        var review = review([
            seed("Atlas", files: [file("map.pdf", .extra), file("notes.pdf", .extra)]),
            seed("Rivers", files: [file("rivers-map.pdf", .extra)], match: libraryBook("Rivers")),
        ])
        let reason = "A book needs at least one audiobook or ebook file"
        #expect(review.readiness(of: review.entries[0].id) == .blocked(reason))
        // Extras may be added to a book that is already in the library.
        #expect(review.readiness(of: review.entries[1].id) == .ready)
        review.entries[1].addToExisting = false
        #expect(review.readiness(of: review.entries[1].id) == .blocked(reason))
        // Derived from the current state: one real file is enough.
        review.entries[0].candidate.files[0].role = .ebook
        #expect(review.readiness(of: review.entries[0].id) == .ready)
    }

    /// R2
    @Test func aBlankTitleOrFirstAuthorWillNeedAttention() {
        var review = review([
            seed("", files: [file("a.m4b")]),
            seed("   ", files: [file("b.m4b")]),
            seed("No Author", author: nil, files: [file("c.m4b")]),
            seed("Blank Author", author: " ", files: [file("d.m4b")]),
            seed("Fine", files: [file("e.m4b")]),
        ])
        let ids = review.entries.map(\.id)
        for id in ids.prefix(4) {
            #expect(review.readiness(of: id) == .willNeedAttention)
        }
        #expect(review.readiness(of: ids[4]) == .ready)

        // Only the first author counts, and the answer follows the text as it is now.
        review.entries[4].candidate.metadata.authors = ["", "Second Author"]
        #expect(review.readiness(of: ids[4]) == .willNeedAttention)
        review.entries[0].candidate.metadata.title = "Now Titled"
        #expect(review.readiness(of: ids[0]) == .ready)
    }

    /// R2: a book already in the library has its own title and author.
    @Test func blankDetailsDoNotMatterWhenAddingToAnExistingBook() {
        var review = review([seed("Atlas", files: [file("atlas.epub")], match: libraryBook("Atlas"))])
        let id = review.entries[0].id
        review.entries[0].candidate.metadata.title = ""
        #expect(review.readiness(of: id) == .ready)
        review.entries[0].addToExisting = false
        #expect(review.readiness(of: id) == .willNeedAttention)
    }

    /// R2: blocked comes before needs-attention.
    @Test func blockedWinsOverNeedsAttention() {
        let review = review([seed("", files: [file("map.pdf", .extra)])])
        #expect(
            review.readiness(of: review.entries[0].id)
                == .blocked("A book needs at least one audiobook or ebook file"))
    }

    // MARK: R3

    /// R3
    @Test func canImportNeedsAnIncludedEntryAndNoIncludedBlockedOne() {
        var review = review([
            seed("Atlas", files: [file("atlas.m4b")]),
            seed("Maps", files: [file("map.pdf", .extra)]),
            seed("Untitled", author: nil, files: [file("c.m4b")]),
        ])
        #expect(review.includedCount == 3)
        #expect(!review.canImport)  // "Maps" is blocked

        review.entries[1].included = false
        #expect(review.includedCount == 2)
        #expect(review.canImport)  // needs-attention does not block

        review.entries[0].included = false
        review.entries[2].included = false
        #expect(review.includedCount == 0)
        #expect(!review.canImport)

        #expect(!ImportReview(seeds: [], skipped: [], copyInsteadOfMove: false).canImport)
    }

    // MARK: R4

    /// R4
    @Test func setRoleChangesOnlyThatFile() {
        var review = review([
            seed("Atlas", files: [file("atlas.m4b"), file("atlas.epub"), file("atlas.pdf")]),
            seed("Rivers", files: [file("rivers.pdf")]),
        ])
        let before = review
        let id = review.entries[0].id
        review.setRole(.extra, file: url("atlas.pdf"), in: id)

        #expect(review.entries[0].candidate.files == [
            file("atlas.m4b"), file("atlas.epub"), file("atlas.pdf", .extra),
        ])
        var expected = before
        expected.entries[0].candidate.files[2].role = .extra
        #expect(review == expected)

        review.setRole(.ebook, file: url("atlas.pdf"), in: id)
        #expect(review == before)
    }

    /// R4: every format with every role; only those `FileRow.allowedRoles` lists are taken.
    @Test func setRoleIgnoresARoleTheFormatCannotTake() {
        for format in FileFormat.allCases {
            let allowed = FileRow.allowedRoles(for: format)
            for start in allowed {
                for role in FileRole.allCases {
                    let target = url("book.\(format.rawValue)")
                    var review = review([seed("Book", files: [CandidateFile(url: target, role: start)])])
                    review.setRole(role, file: target, in: review.entries[0].id)
                    #expect(
                        review.entries[0].candidate.files[0].role == (allowed.contains(role) ? role : start),
                        "\(format) \(start) → \(role)")
                }
            }
        }
    }

    /// R4: a file or an entry that is not there changes nothing.
    @Test func setRoleIgnoresWhatIsNotThere() {
        var review = review([
            seed("Atlas", files: [file("atlas.pdf")]), seed("Rivers", files: [file("rivers.pdf")]),
        ])
        let before = review
        review.setRole(.extra, file: url("rivers.pdf"), in: review.entries[0].id)
        review.setRole(.extra, file: url("atlas.pdf"), in: UUID())
        #expect(review == before)
    }

    // MARK: R5

    /// R5
    @Test func detachDoesNothingToAnEntryWithOneFile() {
        var review = review([seed("Atlas", files: [file("atlas.m4b")], cover: cover(1))])
        let before = review
        review.detach(file: url("atlas.m4b"), from: review.entries[0].id)
        #expect(review == before)
    }

    /// R5
    @Test func detachMovesTheFileIntoANewEntryRightAfter() {
        var first = seed(
            "Atlas", files: [file("atlas.m4b"), file("atlas.epub"), file("atlas.pdf", .extra)], cover: cover(1),
            match: libraryBook("Atlas"))
        first.candidate.metadata.genre = "Travel"
        first.candidate.sourceFolder = url("Atlas")
        var review = review([first, seed("Rivers", files: [file("rivers.epub")])])
        review.entries[0].coverChanged = true
        let ids = review.entries.map(\.id)

        review.detach(file: url("atlas.epub"), from: ids[0])

        #expect(review.entries.count == 3)
        #expect(review.entries.map(\.id).filter { ids.contains($0) } == ids)
        #expect(review.entries[0].id == ids[0])
        #expect(review.entries[2].id == ids[1])
        // The old entry loses the file and nothing else.
        #expect(review.entries[0].candidate.files == [file("atlas.m4b"), file("atlas.pdf", .extra)])
        #expect(review.entries[0].candidate.metadata == first.candidate.metadata)
        #expect(review.entries[0].cover == cover(1))
        #expect(review.entries[0].coverChanged)
        #expect(review.entries[0].existingMatch == libraryBook("Atlas"))

        let made = review.entries[1]
        #expect(!ids.contains(made.id))
        #expect(made.candidate.files == [file("atlas.epub")])
        #expect(made.candidate.metadata == first.candidate.metadata)
        #expect(made.included)
        #expect(made.cover == nil)
        #expect(!made.coverChanged)
        #expect(made.existingMatch == nil)
        // Not added to anything, so it is a new book that still needs its folder.
        #expect(review.items()[1].target == .newBook)
        #expect(made.destination == nil)
        #expect(review.entriesNeedingDestination.contains(made.id))
    }

    /// R5: an extra cannot be a book by itself, so it becomes what its format normally is.
    @Test func aDetachedExtraTakesItsFormatsDefaultRole() {
        var review = review([seed("Atlas", files: [file("atlas.m4b"), file("atlas.pdf", .extra)])])
        review.detach(file: url("atlas.pdf"), from: review.entries[0].id)
        #expect(review.entries.map(\.candidate.files) == [[file("atlas.m4b")], [file("atlas.pdf", .ebook)]])
        #expect(review.readiness(of: review.entries[1].id) == .ready)
    }

    /// R5: a file that is not in the entry, or an entry that is not there, changes nothing.
    @Test func detachIgnoresWhatIsNotThere() {
        var review = review([
            seed("Atlas", files: [file("atlas.m4b"), file("atlas.epub")]),
            seed("Rivers", files: [file("rivers.epub"), file("rivers.pdf")]),
        ])
        let before = review
        review.detach(file: url("rivers.epub"), from: review.entries[0].id)
        review.detach(file: url("atlas.epub"), from: UUID())
        #expect(review == before)
    }

    /// R5, R7: the new entry has the same details, so the folder already worked out holds for it.
    @Test func aDetachedEntryKeepsTheComputedDestination() {
        var review = review([seed("Atlas", files: [file("atlas.m4b"), file("atlas.epub")])])
        let id = review.entries[0].id
        review.setDestination(
            "Ann Author/Atlas", for: id, matchingMetadata: review.entries[0].candidate.metadata)
        review.detach(file: url("atlas.epub"), from: id)
        #expect(review.entries.map(\.destination) == ["Ann Author/Atlas", "Ann Author/Atlas"])
        #expect(review.entriesNeedingDestination.isEmpty)
    }

    // MARK: R6

    /// R6
    @Test func mergeNeedsTwoEntries() {
        var review = review([
            seed("Atlas", files: [file("atlas.m4b")]), seed("Rivers", files: [file("rivers.epub")]),
        ])
        let before = review
        review.merge([])
        review.merge([review.entries[1].id])
        review.merge([review.entries[1].id, UUID()])  // only one of them is in the list
        #expect(review == before)
    }

    /// R6
    @Test func mergeFoldsTheEntriesIntoTheFirstInListOrder() {
        var second = seed(
            "Atlas Part Two", files: [file("extra.pdf", .extra), file("two.mp3"), file("atlas.epub")],
            cover: cover(2), match: libraryBook("Atlas"))
        second.candidate.metadata.genre = "Travel"
        var review = review([
            seed("Rivers", files: [file("rivers.epub")]),
            second,
            seed("Untouched", files: [file("untouched.m4b")]),
            seed("Atlas Part One", author: "Someone Else", files: [file("one.mp3"), file("map.pdf", .extra)],
                 cover: cover(4)),
            seed("Atlas Part Three", files: [file("three.mp3")], cover: cover(5)),
        ])
        review.entries[1].addToExisting = false
        review.entries[1].coverChanged = true
        review.entries[1].included = false
        let ids = review.entries.map(\.id)

        review.merge([ids[4], ids[1], ids[3]])

        #expect(review.entries.map(\.id) == [ids[0], ids[1], ids[2]])
        let merged = review.entries[1]
        // Its own details, cover, match and flags.
        #expect(merged.candidate.metadata == second.candidate.metadata)
        #expect(merged.cover == cover(2))
        #expect(merged.coverChanged)
        #expect(merged.existingMatch == libraryBook("Atlas"))
        #expect(!merged.addToExisting)
        #expect(!merged.included)
        // Concatenated in list order, then audio, ebook, extra without otherwise reordering.
        #expect(merged.candidate.files == [
            file("two.mp3"), file("one.mp3"), file("three.mp3"),
            file("atlas.epub"),
            file("extra.pdf", .extra), file("map.pdf", .extra),
        ])
        // The others are as they were.
        #expect(review.entries[0].candidate.files == [file("rivers.epub")])
        #expect(review.entries[2].candidate.files == [file("untouched.m4b")])
    }

    /// R6
    @Test func mergeTakesTheFirstMergedCoverWhenTheSurvivorHasNone() {
        var review = review([
            seed("One", files: [file("one.mp3")]),
            seed("Two", files: [file("two.mp3")]),
            seed("Three", files: [file("three.mp3")], cover: cover(3)),
            seed("Four", files: [file("four.mp3")], cover: cover(4)),
        ])
        let ids = review.entries.map(\.id)
        review.merge(Set(ids))
        #expect(review.entries.count == 1)
        #expect(review.entries[0].cover == cover(3))
        // It is the cover found in a file that is now this book's, not one the user chose.
        #expect(!review.entries[0].coverChanged)
    }

    /// R6: a cover the user chose for a merged entry stays a chosen cover, or it would not be sent.
    @Test func mergeCarriesAChosenCoverAsChosen() {
        var review = review([
            seed("One", files: [file("one.mp3")]), seed("Two", files: [file("two.mp3")]),
        ])
        review.entries[1].cover = cover(9)
        review.entries[1].coverChanged = true
        review.merge(Set(review.entries.map(\.id)))
        #expect(review.entries[0].cover == cover(9))
        #expect(review.entries[0].coverChanged)
        #expect(review.items()[0].cover == .set(cover(9)))
    }

    /// R6
    @Test func mergeKeepsOneCopyOfASharedFile() {
        var review = review([
            seed("One", files: [file("one.mp3"), file("shared.pdf", .extra)]),
            seed("Two", files: [file("shared.pdf", .ebook), file("two.mp3"), file("one.mp3")]),
        ])
        review.merge(Set(review.entries.map(\.id)))
        // The first copy met is the one kept, with the role it had there.
        #expect(review.entries[0].candidate.files == [
            file("one.mp3"), file("two.mp3"), file("shared.pdf", .extra),
        ])
    }

    // MARK: R7

    /// R7
    @Test func everyNewBookNeedsADestinationAtFirst() {
        let review = review([
            seed("Atlas", files: [file("atlas.m4b")]),
            seed("Rivers", files: [file("rivers.epub")], match: libraryBook("Rivers", folder: "Ann Author/Rivers")),
            seed("Maps", files: [file("maps.epub")]),
        ])
        #expect(review.entriesNeedingDestination == [review.entries[0].id, review.entries[2].id])
        #expect(review.entries.map(\.destination) == [nil, "Ann Author/Rivers", nil])
    }

    /// R7
    @Test func setDestinationAnswersTheNeed() {
        var review = review([seed("Atlas", files: [file("atlas.m4b")])])
        let id = review.entries[0].id
        review.setDestination(
            "Ann Author/Atlas", for: id, matchingMetadata: review.entries[0].candidate.metadata)
        #expect(review.entries[0].destination == "Ann Author/Atlas")
        #expect(review.entriesNeedingDestination.isEmpty)
    }

    /// R7: a book that cannot be filed has been answered too, with nil.
    @Test func aNilDestinationIsAnAnswer() {
        var review = review([seed("Atlas", author: nil, files: [file("atlas.m4b")])])
        let id = review.entries[0].id
        review.setDestination(nil, for: id, matchingMetadata: review.entries[0].candidate.metadata)
        #expect(review.entries[0].destination == nil)
        #expect(review.entriesNeedingDestination.isEmpty)
    }

    /// R7: title, first author, series and series number decide the folder; nothing else does.
    @Test func editingADetailThatDecidesTheFolderNeedsANewDestination() {
        let edits: [(name: String, needs: Bool, edit: (inout BookMetadata) -> Void)] = [
            ("title", true, { $0.title = "Atlas of Clouds" }),
            ("first author", true, { $0.authors = ["Mo Reed", "Second Author"] }),
            ("series", true, { $0.series = "Skies" }),
            ("series number", true, { $0.seriesNumber = "2" }),
            ("second author", false, { $0.authors = ["Ann Author", "Third Author"] }),
            ("genre", false, { $0.genre = "Travel" }),
            ("subtitle", false, { $0.subtitle = "A Journey" }),
            ("narrators", false, { $0.narrators = ["Tom Hale"] }),
            ("year", false, { $0.year = 2001 }),
            ("summary", false, { $0.summary = "Clouds." }),
        ]
        for edit in edits {
            var first = seed("Atlas", files: [file("atlas.m4b")])
            first.candidate.metadata.authors = ["Ann Author", "Second Author"]
            first.candidate.metadata.series = "Maps"
            first.candidate.metadata.seriesNumber = "1"
            var review = review([first, seed("Rivers", files: [file("rivers.epub")])])
            for entry in review.entries {
                review.setDestination("somewhere", for: entry.id, matchingMetadata: entry.candidate.metadata)
            }
            #expect(review.entriesNeedingDestination.isEmpty)

            edit.edit(&review.entries[0].candidate.metadata)
            #expect(
                review.entriesNeedingDestination == (edit.needs ? [review.entries[0].id] : []), "\(edit.name)")

            // Putting the text back makes the folder that was worked out right again.
            review.entries[0].candidate.metadata = first.candidate.metadata
            #expect(review.entriesNeedingDestination.isEmpty, "\(edit.name)")
        }
    }

    /// R7
    @Test func aLateAnswerForOldTextIsIgnored() {
        var review = review([seed("Atlas", files: [file("atlas.m4b")])])
        let id = review.entries[0].id
        let asked = review.entries[0].candidate.metadata
        review.entries[0].candidate.metadata.title = "Atlas of Clouds"

        review.setDestination("Ann Author/Atlas", for: id, matchingMetadata: asked)
        #expect(review.entries[0].destination == nil)
        #expect(review.entriesNeedingDestination == [id])

        review.setDestination(
            "Ann Author/Atlas of Clouds", for: id, matchingMetadata: review.entries[0].candidate.metadata)
        #expect(review.entries[0].destination == "Ann Author/Atlas of Clouds")
        #expect(review.entriesNeedingDestination.isEmpty)

        // An answer for an entry that is not there changes nothing.
        let before = review
        review.setDestination("x", for: UUID(), matchingMetadata: asked)
        #expect(review == before)
    }

    /// R7: an answer asked for before a change that does not move the book still holds.
    @Test func anAnswerStillHoldsAfterAnEditThatDoesNotMoveTheBook() {
        var review = review([seed("Atlas", files: [file("atlas.m4b")])])
        let id = review.entries[0].id
        let asked = review.entries[0].candidate.metadata
        review.entries[0].candidate.metadata.genre = "Travel"
        review.setDestination("Ann Author/Atlas", for: id, matchingMetadata: asked)
        #expect(review.entries[0].destination == "Ann Author/Atlas")
        #expect(review.entriesNeedingDestination.isEmpty)
    }

    /// R7
    @Test func anEntryAddedToAnExistingBookGoesToThatBooksFolder() {
        var review = review([
            seed("Atlas", files: [file("atlas.epub")], match: libraryBook("Atlas", folder: "Ann Author/Atlas")),
        ])
        let id = review.entries[0].id
        #expect(review.entries[0].destination == "Ann Author/Atlas")
        #expect(review.entriesNeedingDestination.isEmpty)

        // Its own text does not decide anything, and no answer replaces the book's folder.
        review.entries[0].candidate.metadata.title = "Atlas of Clouds"
        #expect(review.entriesNeedingDestination.isEmpty)
        review.setDestination(
            "Elsewhere", for: id, matchingMetadata: review.entries[0].candidate.metadata)
        #expect(review.entries[0].destination == "Ann Author/Atlas")
    }

    /// R7
    @Test func togglingAddToExistingSwitchesTheDestinationRule() {
        var review = review([
            seed("Atlas", files: [file("atlas.epub")], match: libraryBook("Atlas", folder: "Ann Author/Atlas")),
        ])
        let id = review.entries[0].id

        review.entries[0].addToExisting = false
        #expect(review.entries[0].destination == nil)
        #expect(review.entriesNeedingDestination == [id])
        review.setDestination(
            "Ann Author/Atlas 2", for: id, matchingMetadata: review.entries[0].candidate.metadata)
        #expect(review.entries[0].destination == "Ann Author/Atlas 2")
        #expect(review.entriesNeedingDestination.isEmpty)

        review.entries[0].addToExisting = true
        #expect(review.entries[0].destination == "Ann Author/Atlas")
        #expect(review.entriesNeedingDestination.isEmpty)
    }

    /// R7: `addToExisting` means nothing without a match.
    @Test func addToExistingWithoutAMatchIsANewBook() {
        var review = review([seed("Atlas", files: [file("atlas.m4b")])])
        review.entries[0].addToExisting = true
        #expect(review.entriesNeedingDestination == [review.entries[0].id])
        #expect(review.items()[0].target == .newBook)
    }

    // MARK: R8

    /// R8
    @Test func itemsAreTheIncludedEntriesInOrder() {
        var review = review([
            seed("Atlas", files: [file("atlas.m4b")], cover: cover(1)),
            seed("Left Out", files: [file("left-out.m4b")]),
            seed("Rivers", files: [file("rivers.epub")], cover: cover(2), match: libraryBook("Rivers", id: 42)),
            seed("Maps", files: [file("maps.epub")], cover: cover(3), match: libraryBook("Maps", id: 43)),
            seed("Skies", files: [file("skies.epub")]),
        ])
        review.entries[1].included = false
        review.entries[3].addToExisting = false
        review.entries[0].candidate.metadata.title = "Atlas of Clouds"
        review.entries[2].cover = cover(9)
        review.entries[2].coverChanged = true
        // Marked as changed, but with nothing to send.
        review.entries[4].coverChanged = true

        let items = review.items()
        #expect(items.map(\.candidate) == [0, 2, 3, 4].map { review.entries[$0].candidate })
        #expect(items[0].candidate.metadata.title == "Atlas of Clouds")
        #expect(items.map(\.target) == [.newBook, .existing(bookId: 42), .newBook, .newBook])
        // A cover that was only found in the files is not sent: the engine finds it again.
        #expect(items.map(\.cover) == [.keep, .set(cover(9)), .keep, .keep])
    }

    // MARK: R9

    /// R9
    @Test func optionsFollowCopyInsteadOfMove() {
        var review = review([], copy: true)
        #expect(review.options.mode == .copy)
        review.copyInsteadOfMove = false
        #expect(review.options.mode == .move)
    }

    // MARK: End to end

    private struct Library {
        var worker: LibraryWorker
        var root: URL
        var inbox: URL
        var review: ImportReview
    }

    /// The demo inbox, scanned into a review on a new, empty library.
    private func reviewOfTheDemoInbox(copy: Bool) async throws -> Library {
        let root = try makeTempDir()
        let inbox = try makeTempDir().appendingPathComponent("Inbox")
        let worker = try LibraryWorker(libraryRoot: root)
        let prepared = try await worker.prepareImport(try DemoContent.makeInbox(at: inbox))
        var review = ImportReview(seeds: prepared.seeds, skipped: prepared.skipped, copyInsteadOfMove: copy)
        // What the sheet does: ask the worker where each book would go.
        for id in review.entriesNeedingDestination {
            let entry = try #require(review.entries.first { $0.id == id })
            let folder = await worker.plannedFolder(for: entry.candidate.metadata)
            review.setDestination(folder, for: id, matchingMetadata: entry.candidate.metadata)
        }
        #expect(review.entriesNeedingDestination.isEmpty)
        return Library(worker: worker, root: root, inbox: inbox, review: review)
    }

    private func index(of title: String, in review: ImportReview) throws -> Int {
        try #require(review.entries.firstIndex { $0.candidate.metadata.title == title }, "\(title)")
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// R1–R3, R7–R9, end to end: every demo book is filed except the one with no author.
    @Test func theDemoInboxImportsThroughTheReview() async throws {
        let library = try await reviewOfTheDemoInbox(copy: false)
        let review = library.review
        let attic = try index(of: "Voices from the Attic", in: review)

        #expect(review.entries.count == 12)
        #expect(review.skipped.isEmpty)
        #expect(review.canImport)
        #expect(review.includedCount == 12)
        for (index, entry) in review.entries.enumerated() {
            #expect(review.readiness(of: entry.id) == (index == attic ? .willNeedAttention : .ready))
            #expect((entry.destination == nil) == (index == attic), "\(entry.candidate.metadata.title)")
        }

        let items = review.items()
        #expect(items.count == 12)
        #expect(review.options.mode == .move)
        let result = try await library.worker.importItems(items, options: review.options)

        #expect(result.outcomes.count == 12)
        var filed: [Int64: String] = [:]
        for (index, outcome) in result.outcomes.enumerated() {
            let title = review.entries[index].candidate.metadata.title
            switch outcome {
            case .imported(let bookId, let problems):
                #expect(index != attic, "\(title)")
                #expect(problems.isEmpty, "\(title)")
                filed[bookId] = review.entries[index].destination
            case .needsAttention:
                #expect(index == attic, "\(title)")
            case .failed(let reason):
                Issue.record("\(title): \(reason)")
            }
        }
        #expect(filed.count == 11)

        let rows = try await library.worker.rows(for: .allBooks, search: "")
        #expect(rows.count == 12)
        let unfiled = try await library.worker.rows(for: .needsAttention, search: "")
        #expect(unfiled.map(\.book.title) == ["Voices from the Attic"])
        // Each book is where the review said it would go.
        for row in rows where row.book.title != "Voices from the Attic" {
            #expect(row.book.folderPath != nil, "\(row.book.title)")
            #expect(row.book.folderPath == filed[row.id], "\(row.book.title)")
        }
        // Moved, not copied: the filed files have left the inbox; the unfiled one stays.
        let lighthouse = library.inbox.appendingPathComponent("The Lighthouse Keeper.m4b")
        #expect(!exists(lighthouse))
        #expect(exists(library.inbox.appendingPathComponent("Downloads/voices_from_the_attic.m4b")))
    }

    /// R4–R6, R8, R9, end to end: a companion PDF is detached and imported as its own book,
    /// three books are merged into one of three parts, and one book is left out.
    @Test func detachedAndMergedEntriesImportAsReviewed() async throws {
        let library = try await reviewOfTheDemoInbox(copy: true)
        var review = library.review

        // Detach the companion PDF and give it its own title.
        let guide = try index(of: "A Field Guide to Small Hours", in: review)
        let guideId = review.entries[guide].id
        let companion = try #require(review.entries[guide].candidate.files.first { $0.role == .extra })
        #expect(companion.url.pathExtension == "pdf")
        review.detach(file: companion.url, from: guideId)
        #expect(review.entries.count == 13)
        #expect(review.entries[guide + 1].candidate.files.map(\.role) == [.ebook])
        review.entries[guide + 1].candidate.metadata.title = "Small Hours Companion"
        let companionId = review.entries[guide + 1].id

        // Merge the three series books into the first of them.
        let seriesTitles = ["Salt Road", "The Drowned Bell", "Harbour of Glass"]
        let series = try seriesTitles.map { try index(of: $0, in: review) }.sorted()
        let seriesIds = series.map { review.entries[$0].id }
        let seriesFileNames = series.flatMap { review.entries[$0].candidate.files.map(\.url.lastPathComponent) }
        review.merge(Set(seriesIds))
        #expect(review.entries.count == 11)
        // The first of them in list order survives, under its own title.
        let merged = try #require(review.entries.first { seriesIds.contains($0.id) })
        #expect(merged.id == seriesIds[0])
        #expect(merged.candidate.files.map(\.url.lastPathComponent) == seriesFileNames)
        let mergedTitle = merged.candidate.metadata.title

        // In a two-format ebook, the PDF becomes an extra.
        let daughter = try index(of: "The Cartographer's Daughter", in: review)
        let daughterPDF = try #require(
            review.entries[daughter].candidate.files.first { $0.url.pathExtension == "pdf" })
        #expect(daughterPDF.role == .ebook)
        review.setRole(.extra, file: daughterPDF.url, in: review.entries[daughter].id)

        // Leave one book out.
        review.entries[try index(of: "Quiet Rivers", in: review)].included = false

        // The detached entry was renamed, so it alone needs a folder.
        #expect(review.entriesNeedingDestination == [companionId])
        for id in review.entriesNeedingDestination {
            let entry = try #require(review.entries.first { $0.id == id })
            let folder = await library.worker.plannedFolder(for: entry.candidate.metadata)
            review.setDestination(folder, for: id, matchingMetadata: entry.candidate.metadata)
        }
        #expect(
            review.entries.first { $0.id == companionId }?.destination == "Jonas Whitlock/Small Hours Companion")
        #expect(review.canImport)
        #expect(review.includedCount == 10)

        #expect(review.options.mode == .copy)
        let result = try await library.worker.importItems(review.items(), options: review.options)
        #expect(result.outcomes.count == 10)
        for outcome in result.outcomes {
            if case .failed(let reason) = outcome { Issue.record("failed: \(reason)") }
        }

        let rows = try await library.worker.rows(for: .allBooks, search: "")
        #expect(rows.count == 10)
        let titles = Set(rows.map(\.book.title))
        #expect(!titles.contains("Quiet Rivers"))
        #expect(titles.intersection(seriesTitles) == [mergedTitle])

        func files(of title: String) async throws -> [FileRow] {
            let row = try #require(rows.first { $0.book.title == title }, "\(title)")
            let detail = try await library.worker.detail(bookId: row.id)
            return try #require(detail).files
        }

        let guideFiles = try await files(of: "A Field Guide to Small Hours")
        #expect(guideFiles.map(\.file.role) == [.audio])
        let companionFiles = try await files(of: "Small Hours Companion")
        #expect(companionFiles.map(\.file.role) == [.ebook])
        #expect(companionFiles.map(\.file.format) == [.pdf])
        #expect(companionFiles.map(\.file.path) == ["Jonas Whitlock/Small Hours Companion/Small Hours Companion.pdf"])
        #expect(companionFiles.allSatisfy { !$0.isMissing })

        let seriesFiles = try await files(of: mergedTitle)
        #expect(seriesFiles.map(\.file.role) == [.audio, .audio, .audio])
        #expect(seriesFiles.map(\.name) == (1...3).map { "0\($0) - \(mergedTitle).m4b" })
        #expect(seriesFiles.allSatisfy { !$0.isMissing })

        let daughterFiles = try await files(of: "The Cartographer's Daughter")
        #expect(daughterFiles.map(\.file.role) == [.ebook, .extra])
        #expect(daughterFiles.map(\.file.format) == [.epub, .pdf])

        // Copied: the inbox still has its files.
        #expect(exists(companion.url))
        #expect(exists(library.inbox.appendingPathComponent("Quiet Rivers.epub")))
    }
}

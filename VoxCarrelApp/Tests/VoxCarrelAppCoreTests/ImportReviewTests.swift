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

    /// R9: a review of files that are in the library already never copies.
    @Test func aMoveOnlyReviewNeverCopies() {
        var review = ImportReview(
            seeds: [seed("Atlas", files: [file("atlas.m4b")])], skipped: [], copyInsteadOfMove: true, moveOnly: true)
        #expect(review.moveOnly)
        #expect(!review.offersCopy)
        #expect(review.copyInsteadOfMove == false)
        #expect(review.options.mode == .move)
        review.copyInsteadOfMove = true
        #expect(review.options.mode == .move)
        #expect(self.review([], copy: true).offersCopy)
    }

    // MARK: R10 What is sent is tidy

    /// R10: text goes to the library without the spaces around it; nothing but spaces is nothing.
    @Test func itemsAreTrimmed() {
        var review = review([seed("Atlas", files: [file("atlas.m4b")])])
        let id = review.entries[0].id
        review.setText("  Atlas of Clouds  ", for: .title, of: id)
        review.setText("   ", for: .series, of: id)
        review.setText(" 2 ", for: .seriesNumber, of: id)
        review.entries[0].candidate.metadata.authors = [" Ann Author ", "  ", "Bo Writer"]
        review.entries[0].candidate.metadata.narrators = ["  "]
        review.entries[0].candidate.metadata.genre = " Travel "
        review.entries[0].candidate.metadata.subtitle = "\n"

        let metadata = review.items()[0].candidate.metadata
        #expect(metadata.title == "Atlas of Clouds")
        #expect(metadata.series == nil)
        #expect(metadata.seriesNumber == "2")
        #expect(metadata.authors == ["Ann Author", "Bo Writer"])
        #expect(metadata.narrators == [])
        #expect(metadata.genre == "Travel")
        #expect(metadata.subtitle == nil)
        // The files are sent as they are.
        #expect(review.items()[0].candidate.files == review.entries[0].candidate.files)
    }

    // MARK: R11 The book already in the library follows the details

    /// R11: a new title or first author means the match must be looked for again.
    @Test func changingTitleOrFirstAuthorAsksForTheMatchAgain() {
        var review = review([
            seed("Atlas", files: [file("atlas.m4b")], match: libraryBook("Atlas")),
            seed("Rivers", files: [file("rivers.epub")]),
        ])
        let (atlas, rivers) = (review.entries[0].id, review.entries[1].id)
        #expect(review.entriesNeedingMatch.isEmpty)

        // Spaces and capitals are not a change, nor is anything but the title and first author.
        review.setText("atlas ", for: .title, of: atlas)
        review.setText("Some Series", for: .series, of: rivers)
        #expect(review.entriesNeedingMatch.isEmpty)

        review.setText("Atlas of Clouds", for: .title, of: atlas)
        review.setText("Bo Writer; Ann Author", for: .authors, of: rivers)
        #expect(review.entriesNeedingMatch == [atlas, rivers])
    }

    /// R11: no longer matching, the entry is a new book; matching now, it is offered, switched on.
    @Test func theMatchIsReplacedByTheAnswer() {
        var review = review([
            seed("Atlas", files: [file("atlas.m4b")], match: libraryBook("Atlas")),
            seed("Rivers", files: [file("rivers.epub")]),
        ])
        let (atlas, rivers) = (review.entries[0].id, review.entries[1].id)
        review.setText("Atlas of Clouds", for: .title, of: atlas)
        review.setExistingMatch(nil, for: atlas, matchingMetadata: review.entries[0].candidate.metadata)
        #expect(review.entries[0].existingMatch == nil)
        #expect(!review.entries[0].isAddedToExisting)
        #expect(review.items()[0].target == .newBook)
        #expect(review.items()[0].candidate.metadata.title == "Atlas of Clouds")
        // A new book needs its folder worked out.
        #expect(review.entriesNeedingDestination.contains(atlas))

        review.entries[1].addToExisting = false
        review.setText("Maps", for: .title, of: rivers)
        review.setExistingMatch(
            libraryBook("Maps", id: 43), for: rivers, matchingMetadata: review.entries[1].candidate.metadata)
        #expect(review.entries[1].existingMatch?.id == 43)
        #expect(review.entries[1].isAddedToExisting)
        #expect(review.items()[1].target == .existing(bookId: 43))
        #expect(review.entriesNeedingMatch.isEmpty)
    }

    /// R11: an answer for details that have changed again is not used.
    @Test func aLateMatchIsIgnored() {
        var review = review([seed("Atlas", files: [file("atlas.m4b")])])
        let id = review.entries[0].id
        review.setText("Maps", for: .title, of: id)
        let asked = review.entries[0].candidate.metadata
        review.setText("Maps of Nowhere", for: .title, of: id)
        review.setExistingMatch(libraryBook("Maps", id: 43), for: id, matchingMetadata: asked)
        #expect(review.entries[0].existingMatch == nil)
        #expect(review.entriesNeedingMatch == [id])
    }

    /// R11: the same match found again leaves the user's choice not to use it alone.
    @Test func theSameMatchAgainKeepsTheSwitchAsItIs() {
        let match = libraryBook("Atlas")
        var review = review([seed("Atlas", files: [file("atlas.m4b")], match: match)])
        let id = review.entries[0].id
        review.entries[0].addToExisting = false
        review.setText("Atlas!", for: .title, of: id)
        review.setText("Atlas", for: .title, of: id)
        review.setExistingMatch(match, for: id, matchingMetadata: review.entries[0].candidate.metadata)
        #expect(review.entries[0].addToExisting == false)
    }

    /// R11: a file moved out to be its own book is not put back into the library's book.
    @Test func aDetachedEntryIsNotMatchedUntilItsDetailsChange() {
        var review = review([
            seed("Atlas", files: [file("atlas.m4b"), file("atlas.pdf", .extra)], match: libraryBook("Atlas"))
        ])
        review.detach(file: url("atlas.pdf"), from: review.entries[0].id)
        #expect(review.entriesNeedingMatch.isEmpty)
        #expect(review.entries[1].existingMatch == nil)
    }

    /// R11: an entry that joins a library book keeps that book's details, and says so.
    @Test func detailsOfAnEntryAddedToAnExistingBookAreKept() {
        var review = review([
            seed("Atlas", files: [file("atlas.m4b")], match: libraryBook("Atlas")),
            seed("Rivers", files: [file("rivers.epub")]),
        ])
        let (atlas, rivers) = (review.entries[0].id, review.entries[1].id)
        #expect(review.keptDetailsNote(of: atlas) == "These files join \"Atlas\", which keeps its own details. "
            + "Change the title or author to import them as a different book.")
        #expect(review.keptDetailsNote(of: rivers) == nil)
        // The title and the authors decide which book it is, so they can always be typed.
        #expect(!review.isLocked(.title, of: atlas))
        #expect(!review.isLocked(.authors, of: atlas))
        #expect(review.isLocked(.series, of: atlas))
        #expect(review.isLocked(.seriesNumber, of: atlas))
        #expect(review.isLocked(.narrators, of: atlas))
        #expect(!review.isLocked(.series, of: rivers))

        review.setText("Ignored", for: .series, of: atlas)
        #expect(review.entries[0].candidate.metadata.series == nil)

        review.entries[0].addToExisting = false
        #expect(review.keptDetailsNote(of: atlas) == nil)
        #expect(!review.isLocked(.series, of: atlas))
    }

    // MARK: IH1–IH3, IH8 Guessing (plan 14)

    private func offered(
        _ strength: MatchStrength, title: String = "Atlas", id: Int64 = 7, hasAudio: Bool = false,
        hasPDFEbook: Bool = false
    ) -> ImportMatch {
        ImportMatch(book: libraryBook(title, id: id), strength: strength, hasAudio: hasAudio, hasPDFEbook: hasPDFEbook)
    }

    private func seed(_ title: String, author: String? = "Ann Author", files: [CandidateFile], offered: ImportMatch?)
        -> ImportSeed
    {
        ImportSeed(
            candidate: CandidateBook(
                files: files, metadata: BookMetadata(title: title, authors: author.map { [$0] } ?? [])),
            cover: nil, match: offered)
    }

    private func roles(_ review: ImportReview, _ entry: Int = 0) -> [FileRole] {
        review.entries[entry].candidate.files.map(\.role)
    }

    /// IH1: on for a match by Audible ID and a sure one, off for a possible one, which is
    /// still offered.
    @Test func IH1_theSwitchStartsOnForASureMatchAndOffForAPossibleOne() {
        let review = review([
            seed("Atlas", files: [file("a.m4b")], offered: offered(.audibleID)),
            seed("Atlas", files: [file("b.m4b")], offered: offered(.sure)),
            seed("Atlas: A Journey", files: [file("c.m4b")], offered: offered(.possible)),
            seed("Rivers", files: [file("d.m4b")], offered: nil),
        ])
        #expect(review.entries.map(\.addToExisting) == [true, true, false, true])
        #expect(review.entries.map(\.isAddedToExisting) == [true, true, false, false])
        #expect(review.entries.map(\.matchStrength).prefix(3) == [.audibleID, .sure, .possible])
        #expect(review.entries[2].existingMatch == libraryBook("Atlas"))
        // A possible match left as it is offered is imported as a new book.
        #expect(review.items().map(\.target) == [.existing(bookId: 7), .existing(bookId: 7), .newBook, .newBook])
    }

    /// IH1: a seed made the old way has a sure match.
    @Test func IH1_aSeedWithOnlyABookIsASureMatch() {
        let review = review([seed("Atlas", files: [file("a.m4b")], match: libraryBook("Atlas"))])
        #expect(review.entries[0].matchStrength == .sure)
        #expect(review.entries[0].addToExisting)
    }

    /// IH1: the owner's yes to a possible match joins the book.
    @Test func IH1_answeringYesToAPossibleMatchAddsToTheBook() {
        var review = review([seed("Atlas: A Journey", files: [file("c.m4b")], offered: offered(.possible))])
        let id = review.entries[0].id
        review.setAddToExisting(true, for: id)
        #expect(review.entries[0].isAddedToExisting)
        #expect(review.items().map(\.target) == [.existing(bookId: 7)])
        #expect(review.entries[0].destination == "Ann Author/Atlas")
    }

    /// IH2: looked up again, the switch follows the new strength while the owner has
    /// not touched it.
    @Test func IH2_theSwitchFollowsTheStrengthOfANewLookup() {
        var review = review([seed("Atlas", author: nil, files: [file("c.m4b")], offered: offered(.possible))])
        let id = review.entries[0].id
        #expect(!review.entries[0].addToExisting)

        // The owner types the author: the same book, now sure.
        review.setText("Ann Author", for: .authors, of: id)
        #expect(review.entriesNeedingMatch == [id])
        review.setMatch(offered(.sure), for: id, matchingMetadata: review.entries[0].candidate.metadata)
        #expect(review.entriesNeedingMatch.isEmpty)
        #expect(review.entries[0].matchStrength == .sure)
        #expect(review.entries[0].addToExisting)

        // And back to only possible: off again.
        review.setText("Atlas: A Journey", for: .title, of: id)
        review.setMatch(offered(.possible), for: id, matchingMetadata: review.entries[0].candidate.metadata)
        #expect(!review.entries[0].addToExisting)

        // No match at all, then another book by its Audible ID: on.
        review.setText("Maps", for: .title, of: id)
        review.setMatch(nil, for: id, matchingMetadata: review.entries[0].candidate.metadata)
        #expect(review.entries[0].existingMatch == nil)
        review.setText("Maps of Home", for: .title, of: id)
        review.setMatch(
            offered(.audibleID, title: "Maps of Home", id: 43), for: id,
            matchingMetadata: review.entries[0].candidate.metadata)
        #expect(review.entries[0].addToExisting)
    }

    /// IH2: an answer for details the entry no longer has is ignored, as before.
    @Test func IH2_aLateAnswerIsIgnored() {
        var review = review([seed("Atlas", files: [file("c.m4b")], offered: nil)])
        let id = review.entries[0].id
        let asked = review.entries[0].candidate.metadata
        review.setText("Maps", for: .title, of: id)
        review.setMatch(offered(.possible), for: id, matchingMetadata: asked)
        #expect(review.entries[0].existingMatch == nil)
        #expect(review.entriesNeedingMatch == [id])
    }

    /// IH2: what the owner set by hand for a book stays, however that book is found again.
    @Test func IH2_theOwnersChoiceForABookSurvivesANewLookup() {
        // Refused by hand (on, then off again), then the match becomes sure: still off.
        var review = review([seed("Atlas", author: nil, files: [file("c.m4b")], offered: offered(.possible))])
        let id = review.entries[0].id
        review.setAddToExisting(true, for: id)
        review.setAddToExisting(false, for: id)
        review.setText("Ann Author", for: .authors, of: id)
        review.setMatch(offered(.sure), for: id, matchingMetadata: review.entries[0].candidate.metadata)
        #expect(review.entries[0].matchStrength == .sure)
        #expect(!review.entries[0].addToExisting)

        // Accepted by hand, then the match becomes only possible: still on.
        var accepted = self.review([seed("Atlas", files: [file("c.m4b")], offered: offered(.sure))])
        let other = accepted.entries[0].id
        accepted.setAddToExisting(false, for: other)
        accepted.setAddToExisting(true, for: other)
        accepted.setText("Atlas: A Journey", for: .title, of: other)
        accepted.setMatch(offered(.possible), for: other, matchingMetadata: accepted.entries[0].candidate.metadata)
        #expect(accepted.entries[0].addToExisting)
    }

    /// IH2: the choice is for that book: another book is offered by its own strength,
    /// and the first one, offered again, is as the owner left it.
    @Test func IH2_theOwnersChoiceIsForThatBookOnly() {
        var review = review([seed("Atlas", files: [file("c.m4b")], offered: offered(.sure))])
        let id = review.entries[0].id
        review.update(id) { $0.addToExisting = false }

        review.setText("Maps", for: .title, of: id)
        review.setMatch(offered(.sure, title: "Maps", id: 43), for: id, matchingMetadata: review.entries[0].candidate.metadata)
        #expect(review.entries[0].addToExisting)

        review.setText("Atlas", for: .title, of: id)
        review.setMatch(offered(.sure), for: id, matchingMetadata: review.entries[0].candidate.metadata)
        #expect(!review.entries[0].addToExisting)

        // Through no match at all, too.
        review.setText("Nothing", for: .title, of: id)
        review.setMatch(nil, for: id, matchingMetadata: review.entries[0].candidate.metadata)
        review.setText("Atlas", for: .title, of: id)
        review.setMatch(offered(.audibleID), for: id, matchingMetadata: review.entries[0].candidate.metadata)
        #expect(!review.entries[0].addToExisting)
    }

    /// IH3: a PDF that joins a book known by its Audible ID that has audio, or a book
    /// that has a PDF ebook already, is guessed to be an extra; any other is the ebook.
    @Test func IH3_aPDFJoiningABookIsGuessedAnExtraOrAnEbook() {
        let review = review([
            seed("Atlas", files: [file("a.pdf")], offered: offered(.audibleID, hasAudio: true)),
            seed("Atlas", files: [file("b.pdf")], offered: offered(.audibleID)),
            seed("Atlas", files: [file("c.pdf")], offered: offered(.sure, hasAudio: true)),
            seed("Atlas", files: [file("d.pdf")], offered: offered(.sure, hasPDFEbook: true)),
            seed("Atlas", files: [file("e.pdf")], offered: offered(.audibleID, hasAudio: true, hasPDFEbook: true)),
            seed("Atlas", files: [file("f.pdf")], offered: nil),
            // Only PDFs are guessed about, and only those that are ebooks.
            seed(
                "Atlas", files: [file("g.m4b"), file("g.epub"), file("g.pdf"), file("notes.pdf", .extra)],
                offered: offered(.audibleID, hasAudio: true)),
        ])
        #expect((0..<6).map { roles(review, $0) } == [[.extra], [.ebook], [.ebook], [.extra], [.extra], [.ebook]])
        #expect(roles(review, 6) == [.audio, .ebook, .extra, .extra])
        #expect(review.entries.allSatisfy { review.readiness(of: $0.id) == .ready })
    }

    /// IH3: the guess holds only while the switch is on.
    @Test func IH3_theGuessFollowsTheSwitch() {
        var review = review([
            seed("Atlas: A Journey", files: [file("a.pdf")], offered: offered(.possible, hasPDFEbook: true)),
            seed("Atlas", files: [file("b.pdf")], offered: offered(.audibleID, hasAudio: true)),
        ])
        let (possible, sure) = (review.entries[0].id, review.entries[1].id)
        // Off: an ebook, and a book of its own that can be imported.
        #expect(roles(review, 0) == [.ebook])
        #expect(review.readiness(of: possible) == .ready)

        review.setAddToExisting(true, for: possible)
        #expect(roles(review, 0) == [.extra])
        review.setAddToExisting(false, for: possible)
        #expect(roles(review, 0) == [.ebook])

        // The same through the entry itself, as a view may change it.
        review.update(sure) { $0.addToExisting = false }
        #expect(roles(review, 1) == [.ebook])
        #expect(review.readiness(of: sure) == .ready)
        review.update(sure) { $0.addToExisting = true }
        #expect(roles(review, 1) == [.extra])
    }

    /// IH3: the guess follows the match as it is looked up again.
    @Test func IH3_theGuessFollowsANewLookup() {
        var review = review([seed("Atlas", files: [file("a.pdf")], offered: nil)])
        let id = review.entries[0].id
        func lookedUp(_ match: ImportMatch?) {
            review.setMatch(match, for: id, matchingMetadata: review.entries[0].candidate.metadata)
        }
        lookedUp(offered(.audibleID, hasAudio: true))
        #expect(roles(review) == [.extra])
        lookedUp(offered(.sure, hasAudio: true))
        #expect(roles(review) == [.ebook])
        lookedUp(offered(.sure, hasPDFEbook: true))
        #expect(roles(review) == [.extra])
        lookedUp(offered(.possible, hasPDFEbook: true))
        #expect(roles(review) == [.ebook])
        lookedUp(offered(.sure, hasPDFEbook: true))
        #expect(roles(review) == [.extra])
        lookedUp(nil)
        #expect(roles(review) == [.ebook])
        #expect(review.readiness(of: id) == .ready)
    }

    /// IH3: the guess is only where the role control starts: what the owner chooses there is kept.
    @Test func IH3_theOwnersChoiceOfRoleIsKept() {
        var review = review([
            seed("Atlas", files: [file("a.pdf")], offered: offered(.audibleID, hasAudio: true)),
            seed("Atlas", files: [file("b.pdf")], offered: offered(.sure)),
        ])
        let (guessed, plain) = (review.entries[0].id, review.entries[1].id)

        // Guessed an extra; the owner says it is the ebook.
        review.setRole(.ebook, file: url("a.pdf"), in: guessed)
        #expect(roles(review, 0) == [.ebook])
        review.setAddToExisting(false, for: guessed)
        review.setAddToExisting(true, for: guessed)
        review.setMatch(
            offered(.audibleID, hasAudio: true, hasPDFEbook: true), for: guessed,
            matchingMetadata: review.entries[0].candidate.metadata)
        #expect(roles(review, 0) == [.ebook])

        // Guessed the ebook; the owner says it is an extra: it stays one with the switch off,
        // as it did before there were guesses.
        review.setRole(.extra, file: url("b.pdf"), in: plain)
        review.setAddToExisting(false, for: plain)
        #expect(roles(review, 1) == [.extra])
        #expect(review.readiness(of: plain) == .blocked("A book needs at least one audiobook or ebook file"))
    }

    /// IH3: an extra the scan made is not the guess's to change back.
    @Test func IH3_anExtraThatWasNotGuessedIsLeftAlone() {
        var review = review([
            seed(
                "Atlas", files: [file("a.m4b"), file("booklet.pdf", .extra)],
                offered: offered(.audibleID, hasAudio: true))
        ])
        let id = review.entries[0].id
        review.setAddToExisting(false, for: id)
        #expect(roles(review) == [.audio, .extra])
        review.setMatch(nil, for: id, matchingMetadata: review.entries[0].candidate.metadata)
        #expect(roles(review) == [.audio, .extra])
    }

    /// IH3: a guessed extra moved out to be a book of its own is an ebook there, and
    /// merged into another entry it is still the guess's.
    @Test func IH3_theGuessSurvivesDetachAndMerge() {
        var review = review([
            seed("Atlas", files: [file("a.m4b"), file("a.pdf")], offered: offered(.audibleID, hasAudio: true)),
            seed("Atlas", files: [file("b.pdf")], offered: offered(.audibleID, hasAudio: true)),
        ])
        #expect(roles(review, 0) == [.audio, .extra])
        review.merge(Set(review.entries.map(\.id)))
        #expect(roles(review, 0) == [.audio, .extra, .extra])
        let id = review.entries[0].id
        review.setAddToExisting(false, for: id)
        #expect(roles(review, 0) == [.audio, .ebook, .ebook])
        review.setAddToExisting(true, for: id)

        review.detach(file: url("b.pdf"), from: id)
        #expect(roles(review, 0) == [.audio, .extra])
        #expect(roles(review, 1) == [.ebook])
        #expect(review.entries[1].existingMatch == nil)
    }

    /// IH8: what is imported is what the entry shows: the candidate as it was scanned
    /// (its own notes included), the guessed role, and the target the switch says.
    @Test func IH8_itemsCarryTheEntryAsTheOwnerLeftIt() {
        var candidate = CandidateBook(
            files: [file("a.pdf")], metadata: BookMetadata(title: "Atlas", authors: ["Ann Author"]),
            guessNotes: [.fromFileName, .orderUnsure])
        var review = review([
            ImportSeed(candidate: candidate, cover: nil, match: offered(.audibleID, hasAudio: true)),
            ImportSeed(candidate: candidate, cover: nil, match: offered(.possible)),
            ImportSeed(candidate: candidate, cover: nil, match: nil),
        ])
        review.setText("Atlas ", for: .title, of: review.entries[2].id)

        let items = review.items()
        #expect(items.map(\.target) == [.existing(bookId: 7), .newBook, .newBook])
        candidate.files[0].role = .extra
        #expect(items[0].candidate == candidate)
        candidate.files[0].role = .ebook
        #expect(items[1].candidate == candidate)
        // Edited by hand: the scan's notes still go with the candidate.
        #expect(items[2].candidate == candidate)
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

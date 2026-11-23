import Foundation
import Testing
import VoxCarrelCore

@testable import VoxCarrelAppCore

/// What the review sheet writes about an import, and the changes it makes by an
/// entry's id (plan Task 11). Q1–Q9. Nothing here touches a file.
@Suite struct ImportReviewDisplayTests {
    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/inbox/\(name)")
    }

    private func file(_ name: String, _ role: FileRole? = nil) -> CandidateFile {
        let url = url(name)
        return CandidateFile(url: url, role: role ?? FileFormat(url: url)?.defaultRole ?? .extra)
    }

    private func seed(
        _ title: String, author: String? = "Ann Author", files: [CandidateFile], match: Book? = nil
    ) -> ImportSeed {
        ImportSeed(
            candidate: CandidateBook(
                files: files, metadata: BookMetadata(title: title, authors: author.map { [$0] } ?? [])),
            cover: nil, existingMatch: match)
    }

    private func libraryBook(_ title: String, id: Int64 = 7, folder: String? = "Ann Author/Atlas") -> Book {
        var book = Book(
            metadata: BookMetadata(title: title, authors: ["Ann Author"]), folderPath: folder,
            dateAdded: Date(timeIntervalSince1970: 1_000_000))
        book.id = id
        return book
    }

    private func review(_ seeds: [ImportSeed], skipped: [URL] = []) -> ImportReview {
        ImportReview(seeds: seeds, skipped: skipped, copyInsteadOfMove: false)
    }

    // MARK: Q1 Changing an entry by its id

    /// Q1
    @Test func updateChangesTheEntryWithThatIdWhereverItIsNow() {
        var review = review([
            seed("Atlas", files: [file("atlas.m4b"), file("atlas.pdf", .extra)]),
            seed("Rivers", files: [file("rivers.epub")]),
        ])
        let rivers = review.entries[1].id
        // Detaching puts a new entry before it.
        review.detach(file: url("atlas.pdf"), from: review.entries[0].id)
        review.update(rivers) { $0.included = false }
        #expect(review.entries.map(\.included) == [true, true, false])
        #expect(review.entry(rivers)?.candidate.metadata.title == "Rivers")

        let before = review
        review.update(UUID()) { $0.included = false }
        #expect(review == before)
        #expect(review.entry(UUID()) == nil)
    }

    // MARK: Q2 The fields

    /// Q2
    @Test func fieldsShowAnEntrysDetailsAsText() {
        var review = review([seed("Atlas", files: [file("atlas.m4b")])])
        let id = review.entries[0].id
        review.update(id) {
            $0.candidate.metadata.authors = ["Le Guin, Ursula K.", "Ann Author"]
            $0.candidate.metadata.narrators = ["Nat Narrator"]
            $0.candidate.metadata.series = "Maps"
            $0.candidate.metadata.seriesNumber = "2.5"
        }
        #expect(review.text(for: .title, of: id) == "Atlas")
        #expect(review.text(for: .authors, of: id) == "Le Guin, Ursula K.; Ann Author")
        #expect(review.text(for: .narrators, of: id) == "Nat Narrator")
        #expect(review.text(for: .series, of: id) == "Maps")
        #expect(review.text(for: .seriesNumber, of: id) == "2.5")
        #expect(review.text(for: .title, of: UUID()) == "")
    }

    /// Q2
    @Test func typingInAFieldChangesTheEntry() {
        var review = review([seed("Atlas", files: [file("atlas.m4b")])])
        let id = review.entries[0].id
        review.setText("Atlas of Clouds", for: .title, of: id)
        review.setText("Ann Author; Le Guin, Ursula K.; ", for: .authors, of: id)
        review.setText(" Nat Narrator ;nat narrator", for: .narrators, of: id)
        review.setText("Maps", for: .series, of: id)
        review.setText("3", for: .seriesNumber, of: id)

        let metadata = review.entries[0].candidate.metadata
        #expect(metadata.title == "Atlas of Clouds")
        #expect(metadata.authors == ["Ann Author", "Le Guin, Ursula K."])
        #expect(metadata.narrators == ["Nat Narrator"])
        #expect(metadata.series == "Maps")
        #expect(metadata.seriesNumber == "3")
        // The folder depends on these, so it is to be worked out again.
        #expect(review.entriesNeedingDestination == [id])
    }

    /// Q2: what is typed is kept as typed, so the field does not change under the
    /// user's hands; an emptied series is no series.
    @Test func aFieldKeepsWhatWasTypedAndAnEmptiedOneIsNothing() {
        var review = review([seed("Atlas", files: [file("atlas.m4b")])])
        let id = review.entries[0].id
        review.setText("Atlas ", for: .title, of: id)
        review.setText("Maps ", for: .series, of: id)
        #expect(review.text(for: .title, of: id) == "Atlas ")
        #expect(review.text(for: .series, of: id) == "Maps ")

        review.setText("", for: .series, of: id)
        review.setText("", for: .seriesNumber, of: id)
        review.setText("", for: .authors, of: id)
        #expect(review.entries[0].candidate.metadata.series == nil)
        #expect(review.entries[0].candidate.metadata.seriesNumber == nil)
        #expect(review.entries[0].candidate.metadata.authors == [])
        #expect(review.text(for: .series, of: id) == "")
    }

    // MARK: Q3 Status

    /// Q3
    @Test func aReadyEntryHasNoStatus() {
        let review = review([seed("Atlas", files: [file("atlas.m4b")])])
        #expect(review.status(of: review.entries[0].id) == nil)
    }

    /// Q3
    @Test func anEntryThatWillNeedAttentionSaysWhatIsMissing() {
        let review = review([
            seed("Atlas", author: nil, files: [file("atlas.m4b")]),
            seed("  ", files: [file("blank.m4b")]),
            seed("", author: " ", files: [file("nothing.m4b")]),
        ])
        let statuses = review.entries.map { review.status(of: $0.id) }
        #expect(statuses.map { $0?.text } == [
            "Needs attention: no author", "Needs attention: no title", "Needs attention: no title or author",
        ])
        #expect(statuses.allSatisfy { $0?.isBlocking == false })
    }

    /// Q3
    @Test func aBlockedEntrySaysWhy() {
        var review = review([seed("Atlas", files: [file("atlas.pdf", .extra)])])
        let id = review.entries[0].id
        #expect(
            review.status(of: id)
                == ImportReview.Status(text: "A book needs at least one audiobook or ebook file", isBlocking: true))
        review.update(id) { $0.candidate.files = [] }
        #expect(review.status(of: id) == ImportReview.Status(text: "No files", isBlocking: true))
    }

    /// Q3: a symbol tells the two kinds of status apart without colour.
    @Test func aStatusHasASymbolOfItsKind() {
        #expect(ImportReview.Status(text: "No files", isBlocking: true).symbol == "xmark.octagon.fill")
        #expect(
            ImportReview.Status(text: "Needs attention: no author", isBlocking: false).symbol
                == "exclamationmark.triangle.fill")
    }

    // MARK: Q4 Where it will go

    /// Q4
    @Test func aReadyEntrySaysWhereItWillBeFiled() {
        var review = review([seed("Atlas", files: [file("atlas.m4b")])])
        let id = review.entries[0].id
        // Not worked out yet.
        #expect(review.destinationText(of: id) == "Working out where it will be filed…")
        review.setDestination("Ann Author/Atlas", for: id, matchingMetadata: review.entries[0].candidate.metadata)
        #expect(review.destinationText(of: id) == "Will be filed in: Ann Author/Atlas")
    }

    /// Q4
    @Test func anEntryThatCannotBeFiledSaysWhatItNeeds() {
        var review = review([
            seed("Atlas", author: nil, files: [file("atlas.m4b")]),
            seed("", files: [file("blank.m4b")]),
            seed("", author: nil, files: [file("nothing.m4b")]),
        ])
        for entry in review.entries {
            review.setDestination(nil, for: entry.id, matchingMetadata: entry.candidate.metadata)
        }
        #expect(review.entries.map { review.destinationText(of: $0.id) } == [
            "Will stay where it is until it has an author",
            "Will stay where it is until it has a title",
            "Will stay where it is until it has a title and an author",
        ])
    }

    /// Q4
    @Test func anEntryAddedToABookSaysWhichFolder() {
        var review = review([
            seed("Atlas", files: [file("atlas.epub")], match: libraryBook("Atlas")),
            seed("Loose", files: [file("loose.epub")], match: libraryBook("Loose", id: 8, folder: nil)),
        ])
        #expect(review.destinationText(of: review.entries[0].id) == "Will be added to: Ann Author/Atlas")
        #expect(review.destinationText(of: review.entries[1].id) == "Will be added to the existing book")

        // As a book of its own it is filed like any other.
        let id = review.entries[0].id
        review.update(id) { $0.addToExisting = false }
        review.setDestination("Ann Author/Atlas 2", for: id, matchingMetadata: review.entries[0].candidate.metadata)
        #expect(review.destinationText(of: id) == "Will be filed in: Ann Author/Atlas 2")
    }

    /// Q4
    @Test func anEntryThatIsBlockedOrLeftOutSaysSo() {
        var review = review([
            seed("Atlas", files: [file("atlas.pdf", .extra)]),
            seed("Rivers", files: [file("rivers.epub")]),
        ])
        #expect(
            review.destinationText(of: review.entries[0].id)
                == "Cannot be imported: A book needs at least one audiobook or ebook file")
        review.update(review.entries[1].id) { $0.included = false }
        #expect(review.destinationText(of: review.entries[1].id) == "Will not be imported")
        #expect(review.destinationText(of: UUID()) == "")
    }

    // MARK: Q5 How many

    /// Q5
    @Test func theCountSaysHowManyOfTheBooksWillBeImported() {
        var review = review([
            seed("Atlas", files: [file("atlas.m4b")]),
            seed("Rivers", files: [file("rivers.epub")]),
            seed("Maps", files: [file("maps.epub")]),
        ])
        #expect(review.countText == "3 of 3 books will be imported")
        review.update(review.entries[1].id) { $0.included = false }
        #expect(review.countText == "2 of 3 books will be imported")

        var one = self.review([seed("Atlas", files: [file("atlas.m4b")])])
        #expect(one.countText == "1 of 1 book will be imported")
        one.update(one.entries[0].id) { $0.included = false }
        #expect(one.countText == "0 of 1 book will be imported")
    }

    // MARK: Q6 The selection

    /// Q6
    @Test func theSelectionIsNothingOneEntryOrSeveral() {
        var review = review([
            seed("Atlas", files: [file("atlas.m4b")]),
            seed("Rivers", files: [file("rivers.epub")]),
            seed("Maps", files: [file("maps.epub")]),
        ])
        let ids = review.entries.map(\.id)
        #expect(review.selected([]) == .none)
        #expect(review.selected([ids[1]]) == .one(review.entries[1]))
        #expect(review.selected([ids[0], ids[2]]) == .many(headline: "2 books selected"))
        #expect(review.selected(Set(ids)) == .many(headline: "3 books selected"))
        // An entry that is no longer there does not count.
        #expect(review.selected([UUID()]) == .none)

        // After a merge the selection still names the entries that are gone.
        review.merge([ids[0], ids[2]])
        #expect(review.selected([ids[0], ids[2]]) == .one(review.entries[0]))
    }

    /// Q6
    @Test func mergeAppliesToTwoOrMoreEntries() {
        var review = review([
            seed("Atlas", files: [file("atlas.m4b")]),
            seed("Rivers", files: [file("rivers.epub")]),
        ])
        let ids = review.entries.map(\.id)
        #expect(!review.canMerge([]))
        #expect(!review.canMerge([ids[0]]))
        #expect(!review.canMerge([ids[0], UUID()]))
        #expect(review.canMerge(Set(ids)))
        review.merge(Set(ids))
        #expect(!review.canMerge(Set(ids)))
    }

    // MARK: Q7 Files

    /// Q7
    @Test func eachFileHasItsNameItsRolesAndWhetherItCanBeMovedOut() {
        var review = review([
            seed("Atlas", files: [file("atlas.m4b"), file("atlas.epub"), file("map.pdf", .extra)]),
            seed("Rivers", files: [file("rivers.epub")]),
        ])
        let files = review.files(of: review.entries[0].id)
        #expect(files.map(\.name) == ["atlas.m4b", "atlas.epub", "map.pdf"])
        #expect(files.map(\.url) == [url("atlas.m4b"), url("atlas.epub"), url("map.pdf")])
        #expect(files.map(\.role) == [.audio, .ebook, .extra])
        #expect(files.map(\.allowedRoles) == [[.audio], [.ebook, .extra], [.ebook, .extra]])
        #expect(files.allSatisfy { $0.canDetach })

        // A book's only file has nowhere to go.
        #expect(review.files(of: review.entries[1].id).map(\.canDetach) == [false])
        #expect(review.files(of: UUID()).isEmpty)

        review.setRole(.ebook, file: url("map.pdf"), in: review.entries[0].id)
        #expect(review.files(of: review.entries[0].id).map(\.role) == [.audio, .ebook, .ebook])
    }

    /// Q7
    @Test func anEntrysFilesAreSummedUpInALine() {
        let review = review([
            seed("Atlas", files: [file("atlas.m4b"), file("atlas.epub"), file("map.pdf", .extra)]),
            seed("Parts", files: [file("1.mp3"), file("2.mp3"), file("3.mp3")]),
            seed("Both", files: [file("both.epub"), file("both.pdf"), file("a.pdf", .extra), file("b.pdf", .extra)]),
            seed("Extra", files: [file("extra.pdf", .extra)]),
        ])
        #expect(review.entries.map(\.filesText) == [
            "M4B · EPUB · 1 extra", "3 MP3", "EPUB · PDF · 2 extras", "1 extra",
        ])
        #expect(review.entries.map(\.hasAudio) == [true, true, false, false])
        #expect(review.entries.map(\.hasEbook) == [true, false, true, false])
    }

    // MARK: Q8 What a row writes

    /// Q8
    @Test func aRowShowsTheTitleAndAuthorsOrThatThereAreNone() {
        var review = review([
            seed("Atlas", files: [file("atlas.m4b")]),
            seed(" ", author: nil, files: [file("blank.m4b")]),
        ])
        review.update(review.entries[0].id) { $0.candidate.metadata.authors = ["Ann Author", "Bo Writer"] }
        #expect(review.entries.map(\.titleText) == ["Atlas", "Untitled"])
        #expect(review.entries.map(\.authorsText) == ["Ann Author, Bo Writer", "No author"])
    }

    /// Q8: the placeholder cover is the one the book will have in the library.
    @Test func anEntryWithNoCoverHasThePlaceholderOfItsTitle() {
        let review = review([seed("The Salt Road", files: [file("salt.m4b")])])
        let row = BookRow(
            id: 1, book: Book(metadata: BookMetadata(title: "The Salt Road"), dateAdded: Date()),
            hasAudio: true, hasEbook: false, formats: [], coverURL: nil, hasWriteProblem: false)
        #expect(review.entries[0].coverInitials == "SR")
        #expect(review.entries[0].coverInitials == row.coverInitials)
        #expect(review.entries[0].placeholderHue == row.placeholderHue)
    }

    /// Q8
    @Test func anEntryWithAMatchOffersToAddToIt() {
        var unsaved = libraryBook("Never Saved")
        unsaved.id = nil
        let review = review([
            seed("Atlas", files: [file("atlas.epub")], match: libraryBook("Atlas")),
            seed("Rivers", files: [file("rivers.epub")]),
            seed("Never Saved", files: [file("never.epub")], match: unsaved),
        ])
        #expect(review.entries.map(\.existingMatchText) == ["Add to the existing book \"Atlas\"", nil, nil])
    }

    // MARK: R9 (plan 6) A match that is on Audible and has no files

    private func audibleOnly(_ title: String, author: String? = "Ann Author") -> Book {
        var book = Book(metadata: BookMetadata(title: title, authors: author.map { [$0] } ?? []), folderPath: nil)
        book.id = 9
        book.externalCopies = [ExternalCopy(kind: .audible, form: .audio, store: "uk")]
        return book
    }

    /// R9
    @Test func aMatchThatIsOnlyOnAudibleSaysSo() {
        var here = libraryBook("Rivers")
        here.externalCopies = [ExternalCopy(kind: .audible, form: .audio)]
        let review = review([
            seed("Atlas", files: [file("atlas.m4b")], match: audibleOnly("Atlas")),
            seed("Rivers", files: [file("rivers.m4b")], match: here),
        ])
        #expect(
            review.entries.map(\.existingMatchText)
                == ["Add to “Atlas”, which is on Audible", "Add to the existing book \"Rivers\""])
        #expect(review.entries.map(\.matchHasNoFiles) == [true, false])
    }

    /// R9: its files go where the book will be filed, which the library works out.
    @Test func aMatchWithNoFilesIsFiledWhereItsOwnDetailsSay() {
        let match = audibleOnly("Atlas")
        var review = review([
            seed("Atlas", files: [file("atlas.m4b")], match: match),
            seed("Rivers", files: [file("rivers.m4b")], match: libraryBook("Rivers")),
        ])
        let id = review.entries[0].id
        #expect(review.entriesNeedingMatchDestination == [id])
        #expect(review.entriesNeedingDestination.isEmpty)
        #expect(review.entries[0].destination == nil)
        #expect(review.destinationText(of: id) == "Working out where it will be filed…")
        #expect(review.readiness(of: id) == .ready)

        // An answer for a book that is no longer the match is ignored.
        var other = match
        other.title = "Atlas of Somewhere"
        review.setMatchDestination("Wrong/Place", for: id, matchedBook: other)
        #expect(review.entries[0].destination == nil)
        #expect(review.entriesNeedingMatchDestination == [id])

        review.setMatchDestination("Ann Author/Atlas", for: id, matchedBook: match)
        #expect(review.entries[0].destination == "Ann Author/Atlas")
        #expect(review.destinationText(of: id) == "Will be filed in: Ann Author/Atlas")
        #expect(review.entriesNeedingMatchDestination.isEmpty)
        // Nothing is recorded for an entry whose match has files, or that is not there.
        review.setMatchDestination("Wrong/Place", for: review.entries[1].id, matchedBook: libraryBook("Rivers"))
        #expect(review.entries[1].destination == "Ann Author/Atlas")
        review.setMatchDestination("Wrong/Place", for: UUID(), matchedBook: match)

        // Switched off, the entry is a new book like any other; switched on again, the answer still holds.
        review.update(id) { $0.addToExisting = false }
        #expect(review.entriesNeedingMatchDestination.isEmpty)
        #expect(review.entriesNeedingDestination == [id])
        #expect(review.entries[0].destination == nil)
        review.update(id) { $0.addToExisting = true }
        #expect(review.entries[0].destination == "Ann Author/Atlas")
        #expect(review.entriesNeedingMatchDestination.isEmpty)
    }

    /// R9: the note under the details says the truth about a book that has no files yet:
    /// its own details are kept, and what it lacks comes from the files.
    @Test func aMatchWithNoFilesSaysItsGapsAreFilledFromTheFiles() {
        let match = audibleOnly("Atlas", author: "Ann Author")
        var review = review([seed("Atlas", author: "Ann Author", files: [file("atlas.m4b")], match: match)])
        let id = review.entries[0].id
        #expect(
            review.keptDetailsNote(of: id)
                == "These files join “Atlas”, which keeps its own details. "
                + "What it lacks is filled in from the files, and nothing in them is lost.")
        review.update(id) { $0.addToExisting = false }
        #expect(review.keptDetailsNote(of: id) == nil)
    }

    /// R9: a book with no author, given files that name none, cannot be filed, and the
    /// import will fail: said beforehand.
    @Test func aMatchWithNoFilesThatCannotBeFiledSaysWhy() {
        let match = audibleOnly("Atlas", author: nil)
        var review = review([seed("Atlas", author: nil, files: [file("atlas.m4b")], match: match)])
        let id = review.entries[0].id
        review.setMatchDestination(nil, for: id, matchedBook: match)
        #expect(review.entriesNeedingMatchDestination.isEmpty)
        #expect(review.entries[0].destination == nil)
        #expect(
            review.destinationText(of: id)
                == "Cannot be added yet: “Atlas” has no author in the library, and neither have these files")
    }

    // MARK: IH1, IH4–IH6 Guessing (plan 14)

    private func guessed(
        _ notes: GuessNotes, title: String = "Slow Horses", author: String? = "Mick Herron", asin: String? = nil,
        match: ImportMatch? = nil
    ) -> ImportSeed {
        var metadata = BookMetadata(title: title, authors: author.map { [$0] } ?? [])
        metadata.asin = asin
        return ImportSeed(
            candidate: CandidateBook(files: [file("book.epub")], metadata: metadata, guessNotes: notes),
            cover: nil, match: match)
    }

    private func possible(_ title: String = "Mind Over Markets (Unabridged)") -> ImportMatch {
        ImportMatch(book: libraryBook(title), strength: .possible)
    }

    private static let checkOrder = "Read from the file name; check the title and author are the right way round."

    /// IH1: a possible match is worded as a question; the others as before.
    @Test func IH1_aPossibleMatchIsAskedAbout() {
        let review = review([
            guessed([], match: possible()),
            guessed([], match: ImportMatch(book: libraryBook("Atlas"), strength: .sure)),
            guessed([], match: ImportMatch(book: libraryBook("Atlas"), strength: .audibleID)),
        ])
        #expect(
            review.entries.map(\.existingMatchText) == [
                "Looks like “Mind Over Markets (Unabridged)”, which is already in your library. Add these files to it?",
                "Add to the existing book \"Atlas\"", "Add to the existing book \"Atlas\"",
            ])
    }

    /// IH4: one line under the title and authors, only when a note applies.
    @Test func IH4_theNoteSaysWhatWasReadFromTheName() {
        let review = review([
            guessed([]),
            guessed([.fromFileName]),
            guessed([.fromFileName, .orderSwapped]),
            guessed([.fromFileName, .orderUnsure]),
            guessed([.fromFileName, .orderGuessedByShape]),
            guessed([.fromFileName, .orderSwapped, .orderGuessedByShape]),
            guessed([.fromFileName, .titleLooksLikePerson]),
            guessed([.fromFileName, .orderUnsure, .titleLooksLikePerson]),
            guessed([.audibleIDFromName]),
        ])
        #expect(
            review.entries.map { review.guessNote(of: $0.id) } == [
                nil,
                "Read from the file name.",
                "Read from the file name as “Title - Author”.",
                Self.checkOrder,
                // Read the usual way round: nothing to ask, even though shape decided it.
                "Read from the file name.",
                Self.checkOrder,
                "This title looks like a person's name.",
                Self.checkOrder,
                nil,
            ])
        #expect(review.guessNote(of: UUID()) == nil)
    }

    /// IH4: the note about the Audible ID stands beside the ID, and only for one read from a name.
    @Test func IH4_theAudibleIDNoteStandsBesideTheID() {
        var review = review([
            guessed([.audibleIDFromName], asin: "B09WXN61GL"),
            guessed([], asin: "B09WXN61GL"),
            guessed([.fromFileName]),
        ])
        let id = review.entries[0].id
        #expect(review.entries.map { review.guessedAudibleIDText(of: $0.id) } == ["Audible ID B09WXN61GL", nil, nil])
        #expect(
            review.entries.map { review.audibleIDNote(of: $0.id) }
                == ["The Audible ID was read from the file name.", nil, nil])

        // Editing the title leaves it; another ID (from a lookup, say) is not the name's.
        review.setText("Another Title", for: .title, of: id)
        #expect(review.audibleIDNote(of: id) != nil)
        review.update(id) { $0.candidate.metadata.asin = "B000000001" }
        #expect(review.audibleIDNote(of: id) == nil)
        #expect(review.guessedAudibleIDText(of: id) == nil)
    }

    /// IH4: editing the title or the authors by hand clears the notes about them.
    @Test func IH4_editingAFieldClearsItsNotes() {
        for field in [ImportReview.Field.title, .authors] {
            var review = review([
                guessed([.fromFileName, .orderUnsure, .titleLooksLikePerson, .audibleIDFromName], asin: "B09WXN61GL")
            ])
            let id = review.entries[0].id
            // Typing what is there already is no edit.
            review.setText(review.text(for: field, of: id), for: field, of: id)
            #expect(review.guessNote(of: id) == Self.checkOrder)

            review.setText("Something Else", for: field, of: id)
            #expect(review.guessNote(of: id) == nil)
            #expect(review.entries[0].guessNotes == [.audibleIDFromName])
            #expect(review.question(of: id) == nil)
            // The scan's own notes are not the review's to change.
            #expect(review.entries[0].candidate.guessNotes.contains(.orderUnsure))
        }
        // Another field says nothing about the title and authors.
        var review = review([guessed([.fromFileName, .orderUnsure])])
        review.setText("A Series", for: .series, of: review.entries[0].id)
        #expect(review.guessNote(of: review.entries[0].id) == Self.checkOrder)
    }

    /// IH4, IH5: Swap answers the question of the order, and clears the notes.
    @Test func IH4_swappingClearsTheNotes() {
        var review = review([guessed([.fromFileName, .orderUnsure, .titleLooksLikePerson])])
        let id = review.entries[0].id
        review.swapTitleAndAuthor(for: id)
        #expect(review.text(for: .title, of: id) == "Mick Herron")
        #expect(review.guessNote(of: id) == nil)
        #expect(!review.offersProminentSwap(of: id))
        #expect(review.question(of: id) == nil)
    }

    /// IH4: details taken from a lookup are no longer what the name said.
    @Test func IH4_detailsChangedThroughTheEntryClearTheNotesToo() {
        var review = review([guessed([.fromFileName, .orderSwapped, .orderGuessedByShape])])
        let id = review.entries[0].id
        review.update(id) { $0.included = false }
        #expect(review.guessNote(of: id) == Self.checkOrder)
        review.update(id) { $0.candidate.metadata.authors = ["M. Herron"] }
        #expect(review.guessNote(of: id) == nil)
    }

    /// IH5: Swap stands out while the order is in question or the title looks like a
    /// person, and there are two to exchange.
    @Test func IH5_swapStandsOutWhileTheOrderIsInQuestion() {
        let review = review([
            guessed([.fromFileName, .orderUnsure]),
            guessed([.fromFileName, .orderGuessedByShape]),
            guessed([.fromFileName, .orderSwapped, .orderGuessedByShape]),
            guessed([.fromFileName, .titleLooksLikePerson]),
            guessed([.fromFileName, .orderSwapped]),
            guessed([.fromFileName]),
            guessed([]),
            // Nothing to exchange it with.
            guessed([.fromFileName, .titleLooksLikePerson], author: nil),
        ])
        #expect(
            review.entries.map { review.offersProminentSwap(of: $0.id) }
                == [true, false, true, true, false, false, false, false])
        #expect(!review.offersProminentSwap(of: UUID()))
    }

    /// IH6: an entry with a question says which, for its caution mark's tooltip.
    @Test func IH6_anEntrySaysWhatThereIsToCheck() {
        let order = "Check that the title and author are the right way round."
        let person = "This title looks like a person's name."
        let match = "This may be “Mind Over Markets (Unabridged)”, which is already in your library."
        let review = review([
            guessed([]),
            guessed([.fromFileName]),
            guessed([.fromFileName, .orderSwapped]),
            guessed([.audibleIDFromName], asin: "B09WXN61GL"),
            guessed([.fromFileName, .orderGuessedByShape]),
            guessed([.fromFileName, .orderUnsure]),
            guessed([.fromFileName, .orderSwapped, .orderGuessedByShape]),
            guessed([.fromFileName, .titleLooksLikePerson], author: nil),
            guessed([.fromFileName, .orderUnsure, .titleLooksLikePerson]),
            guessed([], match: possible()),
            guessed([.fromFileName, .orderUnsure], match: possible()),
            guessed([], match: ImportMatch(book: libraryBook("Atlas"), strength: .sure)),
        ])
        #expect(
            review.entries.map { review.question(of: $0.id) } == [
                nil, nil, nil, nil, nil, order, order, person, "\(order) \(person)", match, "\(order) \(match)", nil,
            ])
        #expect(review.entries.map(\.question) == review.entries.map { review.question(of: $0.id) })
        #expect(review.question(of: UUID()) == nil)
    }

    /// IH6: touching the switch answers a possible match, whichever way; a new lookup
    /// that offers another possible book asks again.
    @Test func IH6_touchingTheSwitchAnswersAPossibleMatch() {
        var review = review([guessed([], match: possible()), guessed([], match: possible())])
        let (yes, no) = (review.entries[0].id, review.entries[1].id)
        #expect(review.entries.map(\.isPossibleMatchUnanswered) == [true, true])

        review.setAddToExisting(true, for: yes)
        #expect(review.question(of: yes) == nil)
        // On and off again is an answer too: no.
        review.setAddToExisting(true, for: no)
        review.setAddToExisting(false, for: no)
        #expect(!review.entries[1].addToExisting)
        #expect(review.question(of: no) == nil)
        #expect(review.questionsText == nil)

        // Looked up again and the same book found: still answered.
        review.setMatch(possible(), for: no, matchingMetadata: review.entries[1].candidate.metadata)
        #expect(review.question(of: no) == nil)
        // Another possible book is another question.
        review.setText("Dune Messiah", for: .title, of: no)
        var other = possible("Dune")
        other.book.id = 99
        review.setMatch(other, for: no, matchingMetadata: review.entries[1].candidate.metadata)
        #expect(review.question(of: no) == "This may be “Dune”, which is already in your library.")
    }

    /// The count line gains a quiet second line while a book that will be imported has
    /// a question; a question never stops the import.
    @Test func theCountOfBooksWithAQuestion() {
        var review = review([
            guessed([.fromFileName, .orderUnsure]),
            guessed([], match: possible()),
            guessed([.fromFileName]),
        ])
        #expect(review.questionsText == "2 books have a question to check.")
        #expect(review.countText == "3 of 3 books will be imported")
        #expect(review.canImport)

        // A book that is left out is not counted.
        review.update(review.entries[0].id) { $0.included = false }
        #expect(review.questionsText == "1 book has a question to check.")
        // Saying no is an answer.
        review.setAddToExisting(false, for: review.entries[1].id)
        #expect(review.questionsText == nil)
        review.update(review.entries[0].id) { $0.included = true }
        #expect(review.questionsText == "1 book has a question to check.")
        review.swapTitleAndAuthor(for: review.entries[0].id)
        #expect(review.questionsText == nil)
        #expect(ImportReview(seeds: [], skipped: [], copyInsteadOfMove: false).questionsText == nil)
    }

    // MARK: Q9 Skipped

    /// Q9
    @Test func skippedPathsAreListedByName() {
        let skipped = [url("notes.txt"), URL(fileURLWithPath: "/inbox/Unzipped.epub", isDirectory: true)]
        let review = review([seed("Atlas", files: [file("atlas.m4b")])], skipped: skipped)
        #expect(review.skippedTitle == "Skipped (2)")
        #expect(review.skippedLines.map(\.name) == ["notes.txt", "Unzipped.epub"])
        #expect(review.skippedLines.map(\.path) == ["/inbox/notes.txt", "/inbox/Unzipped.epub"])

        let none = self.review([seed("Atlas", files: [file("atlas.m4b")])])
        #expect(none.skippedTitle == nil)
        #expect(none.skippedLines.isEmpty)
    }
}

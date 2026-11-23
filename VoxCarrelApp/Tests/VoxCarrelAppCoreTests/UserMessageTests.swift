import Foundation
import Testing
import VoxCarrelAppCore
import VoxCarrelCore
import VoxCarrelFixtures

@Suite struct UserMessageTests {
    // MARK: M1 — LibraryError, one test per case

    /// M1
    @Test func bookNotFound() {
        #expect(UserMessage.text(for: LibraryError.bookNotFound(42)) == "That book is no longer in the library.")
    }

    /// M1
    @Test func fileNotFound() {
        #expect(UserMessage.text(for: LibraryError.fileNotFound(42)) == "That file is no longer in the library.")
    }

    /// M1
    @Test func invalidRole() {
        #expect(UserMessage.text(for: LibraryError.invalidRole)
            == "That kind of file cannot be used that way. An audio file is always part of the audiobook; "
            + "other files can be the ebook or an extra.")
    }

    /// M1
    @Test func nothingToUndo() {
        #expect(UserMessage.text(for: LibraryError.nothingToUndo) == "There is nothing to undo.")
    }

    /// M1: names the file the error carries.
    @Test func undoBlocked() {
        let error = LibraryError.undoBlocked(
            "A file named \"Dune.m4b\" already exists at the destination (/Volumes/In/Dune.m4b)")
        #expect(UserMessage.text(for: error)
            == "Undo could not put the files back, so nothing was changed. "
            + "A file named \"Dune.m4b\" already exists at the destination (/Volumes/In/Dune.m4b). "
            + "Once that is sorted out, you can try Undo again.")
    }

    /// The book whose folder could not be moved is named, and that nothing changed is said.
    @Test func layoutChangeFailed() {
        let error = LibraryError.layoutChangeFailed(
            book: "“Dune”", reason: "something is already there (/L/Frank Herbert/Dune)")
        #expect(UserMessage.text(for: error)
            == "The folder of “Dune” could not be moved, so the folder layout was not changed. "
            + "Something is already there (/L/Frank Herbert/Dune). Every folder is where it was.")
    }

    /// Says what is wrong and what to do about it, with no talk of records or files.
    @Test func layoutChangeInterrupted() {
        #expect(UserMessage.text(for: LibraryError.layoutChangeInterrupted)
            == "A change of folder layout was interrupted and has not been put right yet, so nothing else can be "
            + "changed for now. Close the library and open it again: VoxCarrel will try once more to put "
            + "every folder back.")
    }

    /// M1: each stranded file on its own line.
    @Test func rollbackIncomplete() {
        let error = LibraryError.rollbackIncomplete(
            cause: "the disk is full",
            stranded: [
                "/Library/Ann Lee/Dune/Dune.m4b (from /Volumes/In/Dune.m4b)",
                "/Library/Ann Lee/Dune/Dune.epub (from /Volumes/In/Dune.epub)",
            ])
        let text = UserMessage.text(for: error)
        #expect(text
            == "The change could not be made, and some files could not be put back where they came from. "
            + "The disk is full. "
            + "These files are still in the library folder, but no book uses them:\n"
            + "/Library/Ann Lee/Dune/Dune.m4b (from /Volumes/In/Dune.m4b)\n"
            + "/Library/Ann Lee/Dune/Dune.epub (from /Volumes/In/Dune.epub)")
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        #expect(lines[1] == "/Library/Ann Lee/Dune/Dune.m4b (from /Volumes/In/Dune.m4b)")
        #expect(lines[2] == "/Library/Ann Lee/Dune/Dune.epub (from /Volumes/In/Dune.epub)")
    }

    /// M1: names the file the error carries.
    @Test func cannotLocate() {
        let error = LibraryError.cannotLocate("\"Chosen.mp3\" is not a file of the same type as the missing one (.m4b)")
        #expect(UserMessage.text(for: error)
            == "That file could not be used in place of the missing one, so nothing was changed. "
            + "\"Chosen.mp3\" is not a file of the same type as the missing one (.m4b).")

        // A reason that starts in lower case still reads as a sentence.
        #expect(UserMessage.text(for: LibraryError.cannotLocate("the file is not missing (/L/a.m4b)"))
            .hasSuffix("nothing was changed. The file is not missing (/L/a.m4b)."))
    }

    // MARK: M1 — the other engine errors that can reach the user

    /// M1
    @Test func collectionErrors() {
        #expect(UserMessage.text(for: CollectionError.blankName) == "A collection needs a name.")
        #expect(UserMessage.text(for: CollectionError.notFound(3)) == "That collection no longer exists.")
    }

    /// M1
    @Test func metadataErrors() {
        #expect(UserMessage.text(for: MetadataIOError.unsupportedFormat("ogg"))
            == "Files of type \"ogg\" are not supported.")
        #expect(UserMessage.text(for: MetadataIOError.unreadable("/In/Dune.m4b"))
            == "\"Dune.m4b\" could not be read. It may be damaged, or not the kind of file its name says.")
        #expect(UserMessage.text(for: MetadataIOError.locked("/In/Dune.m4b"))
            == "\"Dune.m4b\" is locked, read-only or protected, so it could not be changed.")
        #expect(UserMessage.text(for: MetadataIOError.notARegularFile("/In/Dune.m4b"))
            == "\"Dune.m4b\" is not an ordinary file, so it was left alone.")
        #expect(UserMessage.text(for: MetadataIOError.verificationFailed("the title did not read back"))
            == "The changed file did not pass its checks, so the original was kept. The title did not read back.")
        #expect(UserMessage.text(for: MetadataIOError.cleanupFailed("/In/.Dune.m4b.tmp"))
            == "The file was left unchanged, but a working copy could not be removed. "
            + "You can delete it yourself: /In/.Dune.m4b.tmp")
    }

    /// M1
    @Test func organiserErrors() {
        #expect(UserMessage.text(for: OrganiserError.destinationExists("/L/Ann/Dune.m4b"))
            == "There is already a file named \"Dune.m4b\" in that place, so nothing was replaced: /L/Ann/Dune.m4b")
        #expect(UserMessage.text(for: OrganiserError.sourceMissing("/In/Dune.m4b"))
            == "The file \"Dune.m4b\" could not be found. It was expected here: /In/Dune.m4b")
        #expect(UserMessage.text(for: OrganiserError.notARegularFile("/In/Dune.m4b"))
            == "\"Dune.m4b\" is not an ordinary file, so it was left alone.")
        #expect(UserMessage.text(for: OrganiserError.cannotBeChanged("/In/Dune.m4b"))
            == "\"Dune.m4b\" is locked, or its folder cannot be changed: /In/Dune.m4b")
        let incomplete = OrganiserError.rollbackIncomplete(
            cause: "the disk is full",
            outstanding: [
                MoveRecord(from: "/In/a.m4b", to: "/L/a.m4b", wasCopy: false),
                MoveRecord(from: "/In/b.m4b", to: "/L/b.m4b", wasCopy: false),
            ])
        #expect(UserMessage.text(for: incomplete)
            == "The files could not be moved, and some could not be put back where they came from. "
            + "The disk is full. These files are not where they were:\n"
            + "\"a.m4b\" is now at /L/a.m4b\n"
            + "\"b.m4b\" is now at /L/b.m4b")
    }

    /// M1: anything else uses its own description.
    @Test func otherErrorsUseTheirLocalizedDescription() {
        struct Odd: LocalizedError { var errorDescription: String? { "The moon is in the way." } }
        #expect(UserMessage.text(for: Odd()) == "The moon is in the way.")
        let cocoa = CocoaError(.fileNoSuchFile)
        #expect(UserMessage.text(for: cocoa) == cocoa.localizedDescription)
    }

    /// M1: no type names, no "error" followed by a code.
    @Test func noMessageShowsATypeNameOrAnErrorCode() throws {
        let errors: [Error] = [
            LibraryError.bookNotFound(1), LibraryError.fileNotFound(2), LibraryError.invalidRole,
            LibraryError.nothingToUndo, LibraryError.undoBlocked("it is locked"),
            LibraryError.rollbackIncomplete(cause: "the disk is full", stranded: ["/a (from /b)"]),
            LibraryError.cannotLocate("it is not a plain file"),
            LibraryError.layoutChangeFailed(book: "“Dune”", reason: "it is locked"),
            LibraryError.layoutChangeInterrupted,
            CollectionError.blankName, CollectionError.notFound(1),
            MetadataIOError.unsupportedFormat("ogg"), MetadataIOError.unreadable("/a.m4b"),
            MetadataIOError.locked("/a.m4b"), MetadataIOError.notARegularFile("/a.m4b"),
            MetadataIOError.verificationFailed("x"), MetadataIOError.cleanupFailed("/a.tmp"),
            OrganiserError.destinationExists("/a.m4b"), OrganiserError.sourceMissing("/a.m4b"),
            OrganiserError.notARegularFile("/a.m4b"), OrganiserError.cannotBeChanged("/a.m4b"),
            OrganiserError.rollbackIncomplete(cause: "x", outstanding: []),
        ]
        let code = try Regex("(?i)error\\s*#?\\d")
        for error in errors {
            let text = UserMessage.text(for: error)
            #expect(!text.isEmpty)
            for name in ["LibraryError", "CollectionError", "MetadataIOError", "OrganiserError", "VoxCarrelCore"] {
                #expect(!text.contains(name), "\(text)")
            }
            #expect(!text.contains(code), "\(text)")
            #expect(!text.contains("  "), "\(text)")
        }
    }

    // MARK: M2 — import summary

    /// M2
    @Test func importHeadlineCountsEachKindAndOmitsZeroes() {
        func headline(_ outcomes: [ImportOutcome]) -> String {
            UserMessage.summary(of: ImportResult(outcomes: outcomes), titles: outcomes.map { _ in "T" }).headline
        }
        let ok = ImportOutcome.imported(bookId: 1, fileProblems: [])
        let attention = ImportOutcome.needsAttention(bookId: 2)
        let failed = ImportOutcome.failed(reason: "no")

        #expect(headline(Array(repeating: ok, count: 11) + [attention]) == "11 books imported, 1 needs attention")
        #expect(headline([ok]) == "1 book imported")
        #expect(headline([ok, ok]) == "2 books imported")
        #expect(headline([ok, attention, attention, failed])
            == "1 book imported, 2 need attention, 1 could not be imported")
        #expect(headline([ok, ok, failed, failed]) == "2 books imported, 2 could not be imported")
        #expect(headline([attention]) == "1 book needs attention")
        #expect(headline([attention, attention, failed]) == "2 books need attention, 1 could not be imported")
        #expect(headline([failed]) == "1 book could not be imported")
        #expect(headline([failed, failed]) == "2 books could not be imported")
        #expect(headline([]) == "Nothing was imported")
    }

    /// M2
    @Test func importProblemsAreListedUnderTheirBooksTitle() {
        let result = ImportResult(outcomes: [
            .imported(bookId: 1, fileProblems: []),
            .failed(reason: "The file \"Dune.m4b\" could not be found (/In/Dune.m4b)"),
            .imported(bookId: 2, fileProblems: [
                FileProblem(file: "Part 1.mp3", reason: "\"Part 1.mp3\" is locked, read-only or protected, so it could not be changed"),
                FileProblem(file: "Part 2.mp3", reason: "it could not be read"),
            ]),
            .needsAttention(bookId: 3),
        ])
        let summary = UserMessage.summary(of: result, titles: ["Quiet Rivers", "Dune", "Salt Road", ""])
        #expect(summary.headline == "2 books imported, 1 needs attention, 1 could not be imported")
        #expect(summary.problems == [
            .init(title: "Dune", detail: "The file \"Dune.m4b\" could not be found (/In/Dune.m4b)."),
            .init(
                title: "Salt Road",
                detail: "Part 1.mp3: \"Part 1.mp3\" is locked, read-only or protected, so it could not be changed."),
            .init(title: "Salt Road", detail: "Part 2.mp3: It could not be read."),
        ])
        #expect(!summary.isClean)
    }

    /// M2
    @Test func importIsCleanOnlyWhenThereIsNothingToRead() {
        let ok = ImportOutcome.imported(bookId: 1, fileProblems: [])
        func summary(_ outcomes: [ImportOutcome]) -> ResultSummary {
            UserMessage.summary(of: ImportResult(outcomes: outcomes), titles: outcomes.map { _ in "T" })
        }
        #expect(summary([ok, ok]).isClean)
        #expect(summary([ok, ok]).problems.isEmpty)
        // A book left where it was is something the user needs to know, though it has no line.
        #expect(!summary([ok, .needsAttention(bookId: 2)]).isClean)
        #expect(summary([ok, .needsAttention(bookId: 2)]).problems.isEmpty)
        #expect(!summary([.failed(reason: "no")]).isClean)
        #expect(!summary([.imported(bookId: 1, fileProblems: [FileProblem(file: "a", reason: "b")])]).isClean)
    }

    /// M2: a book with no usable title still gets a line that can be read.
    @Test func importLineForABookWithoutATitle() {
        let result = ImportResult(outcomes: [.failed(reason: "There are no files to import"), .failed(reason: "no")])
        let summary = UserMessage.summary(of: result, titles: ["  "])
        #expect(summary.problems.map(\.title) == ["Untitled book", "Untitled book"])
        #expect(summary.problems[0].detail == "There are no files to import.")
    }

    // MARK: M3 — save summary

    /// M3
    @Test func saveIsCleanWhenEveryBookSavedWithoutFileProblems() {
        let outcomes: [SaveOutcome] = [
            .saved(bookId: 1, refiled: true, appOnlyFields: [], fileProblems: []),
            .saved(bookId: 2, refiled: false, appOnlyFields: [], fileProblems: []),
        ]
        let summary = UserMessage.summary(of: outcomes, titles: [1: "Dune", 2: "Emma"])
        #expect(summary.isClean)
        #expect(summary.problems.isEmpty)
        #expect(summary.headline == "2 books saved")
    }

    /// M3
    @Test func appOnlyFieldsAloneDoNotMakeASaveUnclean() {
        let outcomes: [SaveOutcome] = [
            .saved(bookId: 1, refiled: false, appOnlyFields: [.series, .cover], fileProblems: [])
        ]
        let summary = UserMessage.summary(of: outcomes, titles: [1: "Dune"])
        #expect(summary.isClean)
        #expect(summary.problems.isEmpty)
        #expect(summary.headline == "1 book saved")
    }

    /// M3
    @Test func aFailedBookGivesALineWithItsReason() {
        let outcomes: [SaveOutcome] = [
            .saved(bookId: 1, refiled: false, appOnlyFields: [], fileProblems: []),
            .failed(bookId: 2, reason: "That book is not in the library"),
            .failed(bookId: 3, reason: "no"),
        ]
        let summary = UserMessage.summary(of: outcomes, titles: [1: "Dune", 2: "Emma"])
        #expect(!summary.isClean)
        #expect(summary.headline == "1 book saved, 2 could not be saved")
        #expect(summary.problems == [
            .init(title: "Emma", detail: "That book is not in the library."),
            .init(title: "Untitled book", detail: "No."),
        ])
    }

    /// M3
    @Test func aFileProblemGivesALineWithTheFileNameAndReason() {
        let outcomes: [SaveOutcome] = [
            .saved(bookId: 1, refiled: false, appOnlyFields: [.series], fileProblems: [
                FileProblem(file: "Dune 1.mp3", reason: "it is locked"),
                FileProblem(file: "Dune 2.mp3", reason: "it is locked"),
            ]),
            .saved(bookId: 2, refiled: false, appOnlyFields: [], fileProblems: []),
        ]
        let summary = UserMessage.summary(of: outcomes, titles: [1: "Dune", 2: "Emma"])
        #expect(!summary.isClean)
        #expect(summary.headline == "2 books saved, 2 files could not be updated")
        #expect(summary.problems == [
            .init(title: "Dune", detail: "Dune 1.mp3: It is locked."),
            .init(title: "Dune", detail: "Dune 2.mp3: It is locked."),
        ])
    }

    /// M3
    @Test func saveHeadlines() {
        func headline(_ outcomes: [SaveOutcome]) -> String {
            UserMessage.summary(of: outcomes, titles: [:]).headline
        }
        let problem = FileProblem(file: "a.mp3", reason: "locked")
        #expect(headline([]) == "Nothing was saved")
        #expect(headline([.failed(bookId: 1, reason: "no")]) == "1 book could not be saved")
        #expect(headline([.failed(bookId: 1, reason: "no"), .failed(bookId: 2, reason: "no")])
            == "2 books could not be saved")
        #expect(headline([.saved(bookId: 1, refiled: false, appOnlyFields: [], fileProblems: [problem])])
            == "1 book saved, 1 file could not be updated")
    }

    // MARK: Field names

    @Test func fieldNamesArePlainWords() {
        #expect(UserMessage.fieldName(.seriesNumber) == "Series number")
        #expect(UserMessage.fieldName(.title) == "Title")
        #expect(UserMessage.fieldName(.authors) == "Author")
        #expect(UserMessage.fieldName(.narrators) == "Narrator")
        #expect(UserMessage.fieldName(.isbn) == "ISBN")
        #expect(UserMessage.fieldName(.asin) == "ASIN")
        #expect(UserMessage.fieldName(.cover) == "Cover")
        let names = MetadataField.allCases.map(UserMessage.fieldName)
        #expect(Set(names).count == names.count)
        #expect(names.allSatisfy { $0.first?.isUppercase == true })
    }

    /// M1: an error of the database itself is said in plain words, with nothing of the
    /// database's own language in it.
    @Test func aDatabaseErrorIsSaidPlainly() throws {
        let root = try makeTempDir()
        try touch(root.appendingPathComponent(LibraryStore.databaseFileName), "this is not a database")
        var caught: Error?
        do { _ = try LibraryStore(libraryRoot: root) } catch { caught = error }
        let error = try #require(caught)
        #expect(LibraryStore.isDatabaseError(error))
        #expect(!LibraryStore.isDatabaseError(LibraryError.nothingToUndo))
        let text = UserMessage.text(for: error)
        #expect(text == "The library's database could not be read. It may be damaged, or not a VoxCarrel library.")
    }

    // MARK: Lookup

    /// K2: what a lookup source's failure is called, naming the source.
    @Test func lookupFailuresNameTheSource() {
        #expect(UserMessage.text(for: LookupError.notReachable, source: .audible) == "Audible could not be reached.")
        #expect(UserMessage.text(for: LookupError.notReachable, source: .openLibrary)
            == "Open Library could not be reached.")
        #expect(UserMessage.text(for: LookupError.refused(status: 503), source: .openLibrary)
            == "Open Library answered with an error.")
        #expect(UserMessage.text(for: LookupError.refused(status: 429), source: .audible)
            == "Audible answered with an error.")
        #expect(UserMessage.text(for: LookupError.unreadable, source: .audible)
            == "Audible sent an answer VoxCarrel could not read.")
    }

    /// A lookup error with no source to name is still a plain sentence.
    @Test func aBareLookupErrorIsAPlainSentence() {
        let notReachable: any Error = LookupError.notReachable
        #expect(UserMessage.text(for: notReachable)
            == "The lookup service could not be reached. Check your internet connection.")
        let refused: any Error = LookupError.refused(status: 500)
        #expect(UserMessage.text(for: refused) == "The lookup service answered with an error.")
        let unreadable: any Error = LookupError.unreadable
        #expect(UserMessage.text(for: unreadable) == "The lookup service sent an answer VoxCarrel could not read.")
    }

    // MARK: Send to Phone

    /// PH21: every reason the file to send could not be made is a plain sentence.
    @Test func sendErrors() {
        #expect(UserMessage.text(for: SendError.nothingToSend) == "There is nothing to send for this book.")
        #expect(UserMessage.text(for: SendError.folderInsideLibrary)
            == "The copy to send could not be made, because its temporary folder is inside the library folder.")
        #expect(UserMessage.text(for: SendError.badPackageName)
            == "The book's title cannot be used as a file name. Change the title, then send the book again.")
        #expect(UserMessage.text(for: SendError.nameClash("Part 1.mp3"))
            == "Two of the book's files are named \"Part 1.mp3\", so they cannot be sent together.")
        #expect(UserMessage.text(for: SendError.notARegularFile("Part 1.mp3"))
            == "\"Part 1.mp3\" is not an ordinary file, so the book was not sent.")
        #expect(UserMessage.text(for: SendError.packageExists("Book.zip"))
            == "The copy to send could not be made, because \"Book.zip\" is already there. Try again.")
    }

    /// PH24: the link server's own errors are said as it words them.
    @Test func phoneLinkErrors() {
        #expect(UserMessage.text(for: PhoneLinkError.noLocalAddress) == "This Mac has no address on a local network.")
        #expect(UserMessage.text(for: PhoneLinkError.cannotListen)
            == "This Mac could not start listening for the phone.")
    }
}

import Foundation
import GRDB
import Testing
@testable import VoxCarrelCore
import VoxCarrelFixtures

/// Managing the library's list of genres: adding, renaming, merging, moving, deleting
/// and resetting, each with its undo, and what names from files and lookups come to
/// in a list that has been changed.
@Suite struct GenreListServiceTests {
    typealias F = LibraryFixture
    typealias Refused = LibraryService.GenreChangeError

    static let thrillers = "Thrillers & Spies"
    static let crime = "Crime & Mystery"

    /// A book with no files, holding these genres.
    @discardableResult
    func book(_ f: F, _ title: String, _ genres: [String]) throws -> Int64 {
        var details = F.meta(title, "An Author")
        details.genres = genres
        var book = Book(metadata: details)
        book.externalCopies = [ExternalCopy(kind: .audible, form: .audio)]
        return try #require(try f.store.insert(book, files: []).id)
    }

    /// A book of one M4B whose file carries `tag` as its genre tag.
    func importM4B(_ f: F, title: String, tag: String?) throws -> Int64 {
        var tags = F.meta(title, "Mick Herron")
        tags.genres = tag.map { [$0] } ?? []
        let url = try f.makeM4B("\(title).m4b", tags: tags)
        let candidate = try #require(f.service.scan([url]).candidates.first)
        let result = try f.service.importItems([ImportItem(candidate: candidate)])
        return try f.importedId(try #require(result.outcomes.first))
    }

    func genres(_ f: F, _ id: Int64) throws -> [String] {
        try #require(try f.store.book(id: id)).genres
    }

    func entry(_ f: F, _ name: String) throws -> GenreEntry? {
        try f.service.genreList().first { $0.name == name }
    }

    /// The names of the list that are shown.
    func shown(_ f: F) throws -> [String] {
        try f.service.genreList().filter { !$0.isHidden }.map(\.name)
    }

    /// Everything undo must put back: every book, and the list as stored.
    struct Whole: Equatable {
        var books: [Book]
        var rows: [GenreRow]
    }

    func whole(_ f: F) throws -> Whole {
        Whole(books: try f.store.books(), rows: try f.store.genreRows())
    }

    func expectRefused(_ expected: Refused, _ body: () throws -> Void, sourceLocation: SourceLocation = #_sourceLocation) {
        do {
            try body()
            Issue.record("expected \(expected), nothing was thrown", sourceLocation: sourceLocation)
        } catch let error as Refused {
            #expect(error == expected, sourceLocation: sourceLocation)
        } catch {
            Issue.record("expected \(expected), got \(error)", sourceLocation: sourceLocation)
        }
    }

    // MARK: G22 Adding

    @Test func G22_aGenreOfTheOwnersOwnIsAddedToItsGroup() throws {
        let f = try F()
        #expect(try f.service.addGenre("  Pub   Quiz ", group: .nonFiction) == "Pub Quiz")
        let own = try #require(try entry(f, "Pub Quiz"))
        #expect(own.group == .nonFiction)
        #expect(own.builtInName == nil)
        #expect(!own.isHidden)
        #expect(own.bookCount == 0)
        // After the built-in ones of its group.
        let group = try f.service.genreList().filter { $0.group == .nonFiction }
        #expect(group.last?.name == "Pub Quiz")
    }

    @Test func G22_aNameWithASeparatorOrNothingInItIsRefused() throws {
        let f = try F()
        let before = try whole(f)
        for name in ["Crime, Mystery", "A; B", "Mystery/Thriller", "", "   "] {
            expectRefused(.invalidName) { try f.service.addGenre(name, group: .fiction) }
        }
        #expect(try whole(f) == before)
    }

    @Test func G22_aNameOnTheListIsRefusedWithTheNameAsListed() throws {
        let f = try F()
        try f.service.addGenre("Pub Quiz", group: .other)
        let before = try whole(f)
        expectRefused(.nameInUse("Pub Quiz")) { try f.service.addGenre("pub quiz", group: .fiction) }
        expectRefused(.nameInUse("Fantasy")) { try f.service.addGenre("FANTASY", group: .other) }
        #expect(try whole(f) == before)
    }

    @Test func G22_aSourceNameOfTheMappingIsTheBuiltInGenreAndNothingIsAdded() throws {
        let f = try F()
        let before = try whole(f)
        #expect(try f.service.addGenre("Sci-Fi", group: .other) == "Science Fiction")
        #expect(try f.service.addGenre("spy stories", group: .other) == Self.thrillers)
        #expect(try whole(f) == before)

        #expect(f.service.listedGenre(forTyped: "sci-fi") == "Science Fiction")
        #expect(f.service.listedGenre(forTyped: "fantasy") == "Fantasy")
        #expect(f.service.listedGenre(forTyped: "LitRPG") == nil)
        // Wording that says nothing, or that is two genres, is no one genre.
        #expect(f.service.listedGenre(forTyped: "Audiobook") == nil)
        #expect(f.service.listedGenre(forTyped: "Horror, Romance") == nil)
    }

    @Test func G22_GP10_aSourceNameIsTheBuiltInGenreAsTheLibraryNowNamesIt() throws {
        let f = try F()
        try f.service.renameGenre("Science Fiction", to: "SF")
        #expect(try f.service.addGenre("Sci-Fi", group: .other) == "SF")
        // The name it shipped under is still that genre's, and cannot be another's.
        #expect(try f.service.addGenre("Science Fiction", group: .other) == "SF")
        #expect(f.service.listedGenre(forTyped: "science fiction") == "SF")
        #expect(try shown(f).filter { $0 == "Science Fiction" }.isEmpty)
    }

    @Test func G22_addingAGenreLeavesWhatCanBeUndoneAsItWas() throws {
        let f = try F()
        let id = try book(f, "One", ["Fantasy"])
        try f.service.renameGenre("Fantasy", to: "Magic")
        let label = try f.service.undoLabel()
        try f.service.addGenre("Pub Quiz", group: .other)
        #expect(try f.service.undoLabel() == label)
        // Undoing the rename leaves the genre added since.
        try f.service.undoLast()
        #expect(try genres(f, id) == ["Fantasy"])
        #expect(try entry(f, "Pub Quiz") != nil)
    }

    // MARK: G23 Moving

    @Test func G23_aGenreMovesToAnotherGroupBuiltInOrNot() throws {
        let f = try F()
        let id = try book(f, "One", ["Pub Quiz", "True Crime"])
        let before = try #require(try f.store.book(id: id))
        try f.service.moveGenre("pub quiz", to: .nonFiction)
        try f.service.moveGenre("True Crime", to: .fiction)
        #expect(try entry(f, "Pub Quiz")?.group == .nonFiction)
        #expect(try entry(f, "True Crime")?.group == .fiction)
        #expect(try entry(f, "True Crime")?.builtInName == "True Crime")
        // Books are as they were, and are found under the new groups.
        #expect(try f.store.book(id: id) == before)
        #expect(try f.service.books(inGroup: .fiction) == [id])
        #expect(try f.service.books(inGroup: .other).isEmpty)
    }

    @Test func G23_movingToTheGroupItIsInChangesNothing() throws {
        let f = try F()
        try book(f, "One", ["Fantasy"])
        let label = try f.service.undoLabel()
        try f.service.moveGenre("Fantasy", to: .fiction)
        #expect(try f.service.undoLabel() == label)
    }

    @Test func G23_aNameThatIsNotOnTheListIsRefused() throws {
        let f = try F()
        expectRefused(.unknownGenre) { try f.service.moveGenre("Nowhere", to: .fiction) }
        expectRefused(.unknownGenre) { try f.service.renameGenre("Nowhere", to: "Somewhere") }
        expectRefused(.unknownGenre) { try f.service.mergeGenre("Nowhere", into: "Fantasy") }
        expectRefused(.unknownGenre) { try f.service.mergeGenre("Fantasy", into: "Nowhere") }
        expectRefused(.unknownGenre) { try f.service.deleteGenre("Nowhere") }
    }

    // MARK: G24 Renaming

    @Test func G24_renamingChangesTheNameOnEveryBookAndInTheList() throws {
        let f = try F()
        let first = try book(f, "One", ["Pub Quiz", "Fantasy"])
        let second = try book(f, "Two", ["Horror", "pub quiz"])
        let third = try book(f, "Three", ["Horror"])
        try f.service.renameGenre("Pub Quiz", to: " Quizzes ")
        #expect(try genres(f, first) == ["Quizzes", "Fantasy"])
        #expect(try genres(f, second) == ["Horror", "Quizzes"])
        #expect(try genres(f, third) == ["Horror"])
        #expect(try entry(f, "Pub Quiz") == nil)
        let renamed = try #require(try entry(f, "Quizzes"))
        #expect(renamed.bookCount == 2)
        #expect(renamed.group == .other)
        #expect(try f.service.books(inGenre: "Quizzes") == [first, second])
        // The search follows.
        #expect(try f.store.search("Quizzes").count == 2)
        #expect(try f.store.search("Pub").isEmpty)
    }

    @Test func G24_aBuiltInGenreCanBeRenamedAndKeepsTheNameItShippedUnder() throws {
        let f = try F()
        let id = try book(f, "One", ["Humour"])
        try f.service.renameGenre("Humour", to: "Comedy Shows")
        #expect(try genres(f, id) == ["Comedy Shows"])
        let renamed = try #require(try entry(f, "Comedy Shows"))
        #expect(renamed.builtInName == "Humour")
        #expect(renamed.group == .fiction)
        // It keeps its place among the built-in genres.
        #expect(try f.service.genreList().map { $0.builtInName } == BuiltInGenre.all.map(\.name))
    }

    @Test func G24_renamingToTheNameOfAnotherGenreIsRefusedSoThatAMergeCanBeOffered() throws {
        let f = try F()
        let id = try book(f, "One", ["Pub Quiz", "Fantasy"])
        let before = try whole(f)
        let label = try f.service.undoLabel()
        expectRefused(.nameInUse("Fantasy")) { try f.service.renameGenre("Pub Quiz", to: "fantasy") }
        expectRefused(.nameInUse("Pub Quiz")) { try f.service.renameGenre("Horror", to: "PUB QUIZ") }
        #expect(try whole(f) == before)
        #expect(try genres(f, id) == ["Pub Quiz", "Fantasy"])
        #expect(try f.service.undoLabel() == label)
    }

    @Test func G24_aNameAnotherBuiltInGenreShippedUnderIsInUse() throws {
        let f = try F()
        try f.service.renameGenre("Fantasy", to: "Magic")
        try f.service.addGenre("Pub Quiz", group: .other)
        expectRefused(.nameInUse("Magic")) { try f.service.renameGenre("Pub Quiz", to: "Fantasy") }
        // Its own shipped name is free to it.
        try f.service.renameGenre("Magic", to: "Fantasy")
        #expect(try entry(f, "Fantasy")?.builtInName == "Fantasy")
    }

    @Test func G24_aChangeOfCapitalisationOnlyIsARename() throws {
        let f = try F()
        let id = try book(f, "One", ["Pub quiz"])
        try f.service.renameGenre("Pub quiz", to: "Pub Quiz")
        #expect(try genres(f, id) == ["Pub Quiz"])
        #expect(try shown(f).filter { GenreName.same($0, "pub quiz") } == ["Pub Quiz"])
    }

    @Test func G24_aNameThatCannotBeANameIsRefused() throws {
        let f = try F()
        try book(f, "One", ["Fantasy"])
        let before = try whole(f)
        for name in ["Swords, Sorcery", "Swords/Sorcery", "A; B", " "] {
            expectRefused(.invalidName) { try f.service.renameGenre("Fantasy", to: name) }
        }
        #expect(try whole(f) == before)
    }

    @Test func G24_theOldNameDoesNotComeBackWhenABookIsSaved() throws {
        let f = try F()
        let id = try book(f, "One", ["Pub Quiz"])
        try f.service.renameGenre("Pub Quiz", to: "Quizzes")
        var edit = BookEdit(book: try #require(try f.store.book(id: id)))
        edit.rating = 4
        _ = try f.service.save([edit])
        #expect(try genres(f, id) == ["Quizzes"])
        #expect(try entry(f, "Pub Quiz") == nil)
        #expect(try f.service.genreList().count == BuiltInGenre.all.count + 1)
    }

    @Test func G24_resetPutsEveryBuiltInNameBackAndLeavesTheOwnersOwnAlone() throws {
        let f = try F()
        let first = try book(f, "One", ["Humour", "Pub Quiz"])
        let second = try book(f, "Two", ["Fantasy", "Horror"])
        try f.service.renameGenre("Humour", to: "Comedy Shows")
        try f.service.renameGenre("Pub Quiz", to: "Quizzes")
        try f.service.moveGenre("Horror", to: .other)
        try f.service.mergeGenre("Fantasy", into: "Horror")
        #expect(try genres(f, second) == ["Horror"])
        #expect(try entry(f, "Fantasy")?.isHidden == true)

        try f.service.resetBuiltInGenreNames()
        #expect(try genres(f, first) == ["Humour", "Quizzes"])
        // The merged genre is back, empty: its books stay where the merge put them.
        #expect(try genres(f, second) == ["Horror"])
        let fantasy = try #require(try entry(f, "Fantasy"))
        #expect(!fantasy.isHidden)
        #expect(fantasy.mergedInto == nil)
        #expect(fantasy.bookCount == 0)
        let list = try f.service.genreList()
        #expect(list.filter { $0.builtInName != nil }.allSatisfy { $0.name == $0.builtInName && !$0.isHidden })
        #expect(list.filter { $0.builtInName != nil }.count == BuiltInGenre.all.count)
        #expect(try entry(f, "Quizzes")?.builtInName == nil)
        // Names only: a group it was moved to stays.
        #expect(try entry(f, "Horror")?.group == .other)
        // And the mapping's names are themselves again.
        #expect(f.service.genres(fromTag: "Fantasy; Comedy") == ["Fantasy", "Humour"])
    }

    @Test func G24_resetExchangesNamesThatWereSwapped() throws {
        let f = try F()
        let id = try book(f, "One", ["Horror", "Romance"])
        // The service does not let one built-in genre take the name another shipped
        // under, so the exchange is written behind its back.
        try f.service.renameGenre("Horror", to: "Held")
        expectRefused(.nameInUse("Held")) { try f.service.renameGenre("Romance", to: "Horror") }
        try f.store.dbQueue.write { db in
            try db.execute(sql: "UPDATE genre SET name = 'Horror' WHERE builtInName = 'Romance'")
            try db.execute(sql: "UPDATE genre SET name = 'Romance' WHERE builtInName = 'Horror'")
            try db.execute(sql: #"UPDATE book SET genres = '["Romance","Horror"]'"#)
        }
        #expect(try genres(f, id) == ["Romance", "Horror"])
        try f.service.resetBuiltInGenreNames()
        #expect(try genres(f, id) == ["Horror", "Romance"])
        #expect(try f.service.genreList().map(\.name) == BuiltInGenre.all.map(\.name))
    }

    @Test func G24_resetTakesInAnOwnGenreThatHasABuiltInName() throws {
        let f = try F()
        try f.service.renameGenre("Fantasy", to: "Magic")
        // Stored behind the service's back: it would never give a book this name.
        let stray = try book(f, "Stray", ["Fantasy"])
        let renamed = try book(f, "Renamed", ["Magic"])
        #expect(try entry(f, "Fantasy")?.builtInName == nil)
        try f.service.resetBuiltInGenreNames()
        #expect(try genres(f, stray) == ["Fantasy"])
        #expect(try genres(f, renamed) == ["Fantasy"])
        #expect(try f.service.genreList().filter { GenreName.same($0.name, "Fantasy") }.count == 1)
        #expect(try entry(f, "Fantasy")?.builtInName == "Fantasy")
        #expect(try entry(f, "Fantasy")?.bookCount == 2)
    }

    @Test func G24_resetWithNothingToPutBackChangesNothing() throws {
        let f = try F()
        try book(f, "One", ["Fantasy"])
        let label = try f.service.undoLabel()
        try f.service.resetBuiltInGenreNames()
        #expect(try f.service.undoLabel() == label)
    }

    // MARK: G25 Merging

    @Test func G25_mergingMovesEveryBookAndRemovesAnOwnGenre() throws {
        let f = try F()
        let first = try book(f, "One", ["Pub Quiz", "Horror"])
        let second = try book(f, "Two", ["Romance", "pub quiz"])
        let third = try book(f, "Three", ["Romance"])
        try f.service.mergeGenre("Pub Quiz", into: "reference & learning")
        #expect(try genres(f, first) == ["Reference & Learning", "Horror"])
        #expect(try genres(f, second) == ["Romance", "Reference & Learning"])
        #expect(try genres(f, third) == ["Romance"])
        #expect(try f.store.genreRows().contains { $0.name == "Pub Quiz" } == false)
        #expect(try entry(f, "Reference & Learning")?.bookCount == 2)
    }

    @Test func G25_aBookThatHasBothKeepsOneInThePlaceOfTheFirstOfTheTwo() throws {
        let f = try F()
        let sourceFirst = try book(f, "One", ["Pub Quiz", "Horror", "Trivia"])
        let targetFirst = try book(f, "Two", ["Trivia", "Horror", "Pub Quiz"])
        let between = try book(f, "Three", ["Romance", "Pub Quiz", "Horror", "Trivia", "Fantasy"])
        try f.service.mergeGenre("Pub Quiz", into: "Trivia")
        #expect(try genres(f, sourceFirst) == ["Trivia", "Horror"])
        #expect(try genres(f, targetFirst) == ["Trivia", "Horror"])
        #expect(try genres(f, between) == ["Romance", "Trivia", "Horror", "Fantasy"])
        #expect(try entry(f, "Trivia")?.bookCount == 3)
    }

    @Test func G25_GP10_aBuiltInGenreMergedAwayIsHiddenAndRecordsWhereItWent() throws {
        let f = try F()
        let id = try book(f, "One", ["Fantasy"])
        try f.service.mergeGenre("Fantasy", into: "Science Fiction")
        #expect(try genres(f, id) == ["Science Fiction"])
        let hidden = try #require(try entry(f, "Fantasy"))
        #expect(hidden.isHidden)
        #expect(hidden.builtInName == "Fantasy")
        #expect(hidden.mergedInto == "Science Fiction")
        #expect(hidden.bookCount == 0)
        #expect(try shown(f).contains("Fantasy") == false)
        #expect(try f.service.genreList().count == BuiltInGenre.all.count)
    }

    @Test func G25_aHiddenGenreIsNotThereToBeChanged() throws {
        let f = try F()
        try f.service.mergeGenre("Fantasy", into: "Science Fiction")
        expectRefused(.unknownGenre) { try f.service.renameGenre("Fantasy", to: "Magic") }
        expectRefused(.unknownGenre) { try f.service.moveGenre("Fantasy", to: .other) }
        expectRefused(.unknownGenre) { try f.service.mergeGenre("Fantasy", into: "Horror") }
        expectRefused(.unknownGenre) { try f.service.deleteGenre("Fantasy") }
        // Its name is still taken.
        expectRefused(.nameInUse("Fantasy")) { try f.service.renameGenre("Horror", to: "Fantasy") }
    }

    @Test func G25_mergingIntoAGenreThatWasMergedAwayGoesWhereThatWent() throws {
        let f = try F()
        let id = try book(f, "One", ["Horror"])
        try f.service.mergeGenre("Fantasy", into: "Science Fiction")
        try f.service.mergeGenre("Horror", into: "Fantasy")
        #expect(try genres(f, id) == ["Science Fiction"])
        #expect(try entry(f, "Horror")?.mergedInto == "Science Fiction")
    }

    @Test func G25_mergingBackIntoAGenreThatWasMergedIntoThisOneBringsItBack() throws {
        let f = try F()
        let id = try book(f, "One", ["Fantasy"])
        try f.service.mergeGenre("Fantasy", into: "Science Fiction")
        try f.service.mergeGenre("Science Fiction", into: "Fantasy")
        #expect(try genres(f, id) == ["Fantasy"])
        #expect(try entry(f, "Fantasy")?.isHidden == false)
        #expect(try entry(f, "Fantasy")?.mergedInto == nil)
        #expect(try entry(f, "Science Fiction")?.isHidden == true)
        #expect(try entry(f, "Science Fiction")?.mergedInto == "Fantasy")
        #expect(f.service.genres(fromTag: "Sci-Fi") == ["Fantasy"])
    }

    @Test func G25_mergingAGenreIntoItselfChangesNothing() throws {
        let f = try F()
        try book(f, "One", ["Fantasy"])
        let before = try whole(f)
        let label = try f.service.undoLabel()
        try f.service.mergeGenre("Fantasy", into: "fantasy")
        #expect(try whole(f) == before)
        #expect(try f.service.undoLabel() == label)
    }

    // MARK: G26 Deleting

    @Test func G26_deletingAnOwnGenreTakesItOffItsBooks() throws {
        let f = try F()
        let first = try book(f, "One", ["Pub Quiz", "Horror"])
        let second = try book(f, "Two", ["pub quiz"])
        #expect(try entry(f, "Pub Quiz")?.bookCount == 2)
        try f.service.deleteGenre("Pub Quiz")
        #expect(try genres(f, first) == ["Horror"])
        #expect(try genres(f, second) == [])
        #expect(try f.store.genreRows().count == BuiltInGenre.all.count)
        #expect(try f.service.booksWithNoGenre() == [second])
    }

    @Test func G26_aBuiltInGenreIsNotDeletedRenamedOrNot() throws {
        let f = try F()
        try book(f, "One", ["Fantasy"])
        try f.service.renameGenre("Horror", to: "Frights")
        let before = try whole(f)
        expectRefused(.builtIn) { try f.service.deleteGenre("Fantasy") }
        expectRefused(.builtIn) { try f.service.deleteGenre("Frights") }
        #expect(try whole(f) == before)
    }

    @Test func G26_GP10_aBuiltInGenreMergedIntoADeletedOneComesBackEmpty() throws {
        let f = try F()
        let id = try book(f, "One", ["Fantasy"])
        try f.service.addGenre("Swords", group: .fiction)
        try f.service.mergeGenre("Fantasy", into: "Swords")
        try f.service.deleteGenre("Swords")
        #expect(try genres(f, id) == [])
        let fantasy = try #require(try entry(f, "Fantasy"))
        #expect(!fantasy.isHidden)
        #expect(fantasy.mergedInto == nil)
        #expect(f.service.genres(fromTag: "Fantasy") == ["Fantasy"])
    }

    // MARK: G27 At once, in the library only, and undoable

    @Test func G27_listChangesWriteNoFileAndMoveNoFolder() throws {
        let f = try F()
        try f.service.applyLayoutChange(to: try FolderPattern("{Genre}/{Author}/{Title}"))
        let renamed = try importM4B(f, title: "Renamed", tag: "Pub Quiz")
        let merged = try importM4B(f, title: "Merged", tag: "Trivia")
        let deleted = try importM4B(f, title: "Deleted", tag: "Oddments")
        let moved = try importM4B(f, title: "Moved", tag: "Horror")
        let ids = [renamed, merged, deleted, moved]
        func urls() throws -> [URL] { try ids.map { f.store.url(for: try #require(try f.store.files(bookId: $0).first)) } }
        let places = try urls()
        let bytes = try places.map { try Data(contentsOf: $0) }
        let stamps = places.map { FileStamp(fileAt: $0) }
        let tree = f.libraryTree()
        try f.service.renameGenre("Pub Quiz", to: "Quizzes")
        try f.service.mergeGenre("Trivia", into: "Reference & Learning")
        try f.service.deleteGenre("Oddments")
        try f.service.moveGenre("Horror", to: .other)

        #expect(try urls() == places)
        #expect(try places.map { try Data(contentsOf: $0) } == bytes)
        #expect(places.map { FileStamp(fileAt: $0) } == stamps)
        #expect(f.libraryTree() == tree)
        #expect(try f.store.book(id: renamed)?.genreTag == "Pub Quiz")
        #expect(try f.store.book(id: renamed)?.folderPath?.hasPrefix("Pub Quiz/") == true)
        // What the files hold is still recorded as it was.
        #expect(try f.store.book(id: merged)?.genreTag == "Trivia")
        #expect(try f.store.book(id: merged)?.genres == ["Reference & Learning"])
        #expect(try f.store.book(id: deleted)?.genreTag == "Oddments")
        #expect(try f.store.book(id: deleted)?.genres == [])
        _ = moved
    }

    @Test func G27_undoOfARenameRestoresTheBooksAndTheList() throws {
        let f = try F()
        try book(f, "One", ["Pub Quiz", "Fantasy"])
        try book(f, "Two", ["Horror"])
        let before = try whole(f)
        try f.service.renameGenre("Pub Quiz", to: "Quizzes")
        #expect(try whole(f) != before)
        #expect(try f.service.undoLabel() == "Rename genre")
        #expect(try f.service.undoLast() == "Rename genre")
        #expect(try whole(f) == before)
        #expect(try f.service.undoLabel() == nil)
        #expect(try f.store.search("Pub").count == 1)
    }

    @Test func G27_undoOfAMergeRestoresTheBooksAndTheList() throws {
        let f = try F()
        try book(f, "Both", ["Trivia", "Horror", "Pub Quiz"])
        try book(f, "Source", ["Pub Quiz"])
        try book(f, "Target", ["Trivia"])
        try book(f, "BuiltIn", ["Fantasy", "Science Fiction"])
        let before = try whole(f)
        try f.service.mergeGenre("Pub Quiz", into: "Trivia")
        #expect(try f.service.undoLast() == "Merge genres")
        #expect(try whole(f) == before)

        // A built-in genre comes back into sight, with its books.
        try f.service.mergeGenre("Fantasy", into: "Science Fiction")
        #expect(try whole(f) != before)
        try f.service.undoLast()
        #expect(try whole(f) == before)
        #expect(try entry(f, "Fantasy")?.isHidden == false)
        #expect(f.service.genres(fromTag: "Fantasy") == ["Fantasy"])
    }

    @Test func G27_undoOfAMoveRestoresTheList() throws {
        let f = try F()
        try book(f, "One", ["Pub Quiz"])
        let before = try whole(f)
        try f.service.moveGenre("Pub Quiz", to: .fiction)
        #expect(try f.service.undoLast() == "Move genre")
        #expect(try whole(f) == before)
        #expect(try entry(f, "Pub Quiz")?.group == .other)
    }

    @Test func G27_undoOfADeleteRestoresTheBooksAndTheList() throws {
        let f = try F()
        try book(f, "One", ["Horror", "Pub Quiz", "Fantasy"])
        try book(f, "Two", ["Pub Quiz"])
        try f.service.addGenre("Swords", group: .fiction)
        try f.service.mergeGenre("Romance", into: "Pub Quiz")
        let before = try whole(f)
        try f.service.deleteGenre("Pub Quiz")
        #expect(try f.service.undoLast() == "Delete genre")
        #expect(try whole(f) == before)
        #expect(try entry(f, "Romance")?.mergedInto == "Pub Quiz")
    }

    @Test func G27_undoOfAResetRestoresTheBooksAndTheList() throws {
        let f = try F()
        try book(f, "One", ["Humour", "Fantasy"])
        try f.service.renameGenre("Humour", to: "Comedy Shows")
        try f.service.mergeGenre("Fantasy", into: "Horror")
        let before = try whole(f)
        try f.service.resetBuiltInGenreNames()
        #expect(try whole(f) != before)
        #expect(try f.service.undoLast() == "Reset genre names")
        #expect(try whole(f) == before)
    }

    @Test func G27_undoLeavesWhatWasChangedSinceThatIsNoPartOfIt() throws {
        let f = try F()
        let id = try book(f, "One", ["Pub Quiz"])
        try f.service.renameGenre("Pub Quiz", to: "Quizzes")
        try f.service.setReadStatus(.finished, for: [id])
        try f.service.undoLast()
        let after = try #require(try f.store.book(id: id))
        #expect(after.genres == ["Pub Quiz"])
        #expect(after.readStatus == .finished)
    }

    @Test func G27_undoPassesOverABookRemovedSince() throws {
        let f = try F()
        let gone = try book(f, "Gone", ["Pub Quiz"])
        let kept = try book(f, "Kept", ["Pub Quiz"])
        try f.service.renameGenre("Pub Quiz", to: "Quizzes")
        try f.service.removeBook(id: gone, moveFilesToTrash: false)
        try f.service.undoLast()
        #expect(try genres(f, kept) == ["Pub Quiz"])
        #expect(try f.store.book(id: gone) == nil)
    }

    @Test func G27_GP9_aListChangeIsRecordedAsVersionFive() throws {
        let f = try F()
        try book(f, "One", ["Pub Quiz"])
        try f.service.renameGenre("Pub Quiz", to: "Quizzes")
        let snapshot = try f.snapshot()
        #expect(snapshot.version == 5)
        #expect(OperationSnapshot.currentVersion == 5)
        #expect(snapshot.books.isEmpty)
        #expect(snapshot.genreList?.books.map(\.genres) == [["Pub Quiz"]])
        #expect(snapshot.genreList?.rowsBefore.map(\.name) == ["Pub Quiz"])

        // An edit of a book still says four: it holds no rows of the list.
        var edit = BookEdit(book: try #require(try f.store.books().first))
        edit.rating = 3
        _ = try f.service.save([edit])
        #expect(try f.snapshot().version == 4)
    }

    @Test func G27_aChangeThatCannotBeCommittedChangesNothing() throws {
        let f = try F()
        try book(f, "One", ["Pub Quiz"])
        let before = try whole(f)
        f.service.beforeCommit = { throw Boom() }
        #expect(throws: Boom.self) { try f.service.renameGenre("Pub Quiz", to: "Quizzes") }
        #expect(try whole(f) == before)
    }

    // MARK: GP10 Names from the mapping and from lookups, in a list that was changed

    @Test func GP10_aRenamedBuiltInGenreIsGivenByItsNewName() throws {
        let f = try F()
        try f.service.renameGenre("Science Fiction", to: "SF & Space")
        #expect(f.service.genres(fromTag: "Sci-Fi") == ["SF & Space"])
        #expect(f.service.genres(fromTag: "Science Fiction; Horror") == ["SF & Space", "Horror"])
        #expect(f.service.genres(fromTag: "SF & Space") == ["SF & Space"])
        #expect(f.service.listedGenres(["Science Fiction", "Horror"]) == ["SF & Space", "Horror"])
        // A file tagged as another app would is imported under the new name.
        let id = try importM4B(f, title: "Tagged", tag: "Science Fiction & Fantasy, Hard Science Fiction")
        #expect(try genres(f, id) == ["SF & Space"])
        #expect(try entry(f, "Science Fiction") == nil)
    }

    @Test func GP10_aBuiltInGenreMergedAwayIsGivenAsTheGenreItWentInto() throws {
        let f = try F()
        try f.service.addGenre("Speculative", group: .fiction)
        try f.service.mergeGenre("Fantasy", into: "Speculative")
        try f.service.mergeGenre("Science Fiction", into: "Speculative")
        #expect(f.service.genres(fromTag: "Fantasy") == ["Speculative"])
        #expect(f.service.genres(fromTag: "Sci-Fi/Fantasy") == ["Speculative"])
        #expect(f.service.listedGenres(["Science Fiction", "Horror", "Fantasy"]) == ["Speculative", "Horror"])

        // A lookup's genres, saved to a book, are stored translated.
        let id = try book(f, "One", [])
        var edit = BookEdit(book: try #require(try f.store.book(id: id)))
        edit.metadata.genres = ["Fantasy", "Horror"]
        _ = try f.service.save([edit])
        #expect(try genres(f, id) == ["Speculative", "Horror"])
    }

    @Test func GP10_aChainOfMergesIsFollowedToItsEnd() throws {
        let f = try F()
        try f.service.mergeGenre("Fantasy", into: "Science Fiction")
        try f.service.mergeGenre("Science Fiction", into: "Horror")
        try f.service.renameGenre("Horror", to: "Dark")
        #expect(f.service.genres(fromTag: "Fantasy") == ["Dark"])
        #expect(f.service.genres(fromTag: "Fantasy; Sci-Fi; Horror") == ["Dark"])
    }

    @Test func GP10_anOwnGenreMergedAwayHandsOnWhatWasMergedIntoIt() throws {
        let f = try F()
        try f.service.addGenre("Swords", group: .fiction)
        try f.service.mergeGenre("Fantasy", into: "Swords")
        try f.service.mergeGenre("Swords", into: "Horror")
        #expect(try entry(f, "Fantasy")?.mergedInto == "Horror")
        #expect(f.service.genres(fromTag: "Fantasy") == ["Horror"])
    }

    @Test func GP10_aLoopInWhatTheListRecordsEndsAndGivesAName() throws {
        let f = try F()
        // Written behind the service's back: it never records a loop.
        try f.store.dbQueue.write { db in
            let fantasy = try Int64.fetchOne(db, sql: "SELECT id FROM genre WHERE name = 'Fantasy'")
            let horror = try Int64.fetchOne(db, sql: "SELECT id FROM genre WHERE name = 'Horror'")
            try db.execute(sql: "UPDATE genre SET isHidden = 1, mergedInto = ? WHERE id = ?", arguments: [horror, fantasy])
            try db.execute(sql: "UPDATE genre SET isHidden = 1, mergedInto = ? WHERE id = ?", arguments: [fantasy, horror])
        }
        #expect(f.service.genres(fromTag: "Fantasy") == ["Fantasy"])
        #expect(f.service.genres(fromTag: "Horror") == ["Horror"])
    }

    @Test func GP10_theListingTranslatesByCurrentNameFirstThenByShippedName() {
        func row(_ id: Int64, _ name: String, builtIn: String? = nil, hidden: Bool = false, into: Int64? = nil) -> GenreRow {
            GenreRow(id: id, name: name, genreGroup: "fiction", builtInName: builtIn, isHidden: hidden, mergedInto: into)
        }
        let listing = GenreListing(rows: [
            row(1, "Magic", builtIn: "Fantasy"),
            row(2, "Horror", builtIn: "Horror", hidden: true, into: 1),
            row(3, "Pub Quiz"),
        ])
        #expect(listing.listed("fantasy") == "Magic")
        #expect(listing.listed("MAGIC") == "Magic")
        #expect(listing.listed("Horror") == "Magic")
        #expect(listing.listed("pub quiz") == "Pub Quiz")
        #expect(listing.listed("Unlisted") == nil)
        #expect(listing.names(["Unlisted", "horror", "Fantasy", "Pub Quiz", "unlisted"]) == ["Unlisted", "Magic", "Pub Quiz"])
    }
}

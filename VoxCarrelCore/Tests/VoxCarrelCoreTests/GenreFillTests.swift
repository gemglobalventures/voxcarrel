import Foundation
import GRDB
import Testing
@testable import VoxCarrelCore
import VoxCarrelFixtures

/// Fill in Genres: which books it covers, what it asks the catalogues, what it
/// proposes, and what Apply does with the proposals that are chosen.
@Suite struct GenreFillTests {
    typealias F = LibraryFixture

    static let thrillers = "Thrillers & Spies"
    static let espionage = ["Mystery, Thriller & Suspense", "Thriller & Suspense", "Spies & Politics", "Espionage"]
    static let hardSF = ["Science Fiction & Fantasy", "Science Fiction", "Hard Science Fiction"]

    // MARK: A catalogue to ask

    /// What the catalogues hold, answered without a network.
    struct Catalogue: Sendable {
        /// Audible products by ASIN, as JSON.
        var byID: [String: Data] = [:]
        /// Audible search results by the title asked for, as JSON.
        var audible: [String: Data] = [:]
        /// Open Library search results by the title asked for, as JSON.
        var openLibrary: [String: Data] = [:]
        /// The status Audible answers every request with.
        var audibleStatus = 200

        static func product(asin: String, title: String, author: String, paths: [[String]]) -> [String: Any] {
            [
                "asin": asin, "title": title, "authors": [["name": author]],
                "category_ladders": paths.map { path in
                    ["root": "Genres", "ladder": path.map { ["id": "0", "name": $0] }] as [String: Any]
                },
            ]
        }

        mutating func addByID(_ asin: String, title: String, author: String, paths: [[String]]) throws {
            byID[asin] = try JSONSerialization.data(
                withJSONObject: ["product": Self.product(asin: asin, title: title, author: author, paths: paths)])
        }

        /// What Audible finds when `asked` is searched for.
        mutating func addAudible(
            asked: String, found: [(title: String, author: String, paths: [[String]])]
        ) throws {
            let products = found.enumerated().map { index, book in
                Self.product(asin: "B00000000\(index)", title: book.title, author: book.author, paths: book.paths)
            }
            audible[asked] = try JSONSerialization.data(withJSONObject: ["products": products])
        }

        /// What Open Library finds when `asked` is searched for.
        mutating func addOpenLibrary(asked: String, title: String, author: String, subjects: [String]) throws {
            let doc: [String: Any] = [
                "key": "/works/OL1W", "title": title, "author_name": [author], "subject": subjects,
            ]
            openLibrary[asked] = try JSONSerialization.data(withJSONObject: ["docs": [doc]])
        }

        func http() -> FakeHTTP {
            FakeHTTP { url in
                let asked = queryItems(url)["title"] ?? ""
                if url.host == "openlibrary.org" {
                    return (openLibrary[asked] ?? Data(#"{"docs":[]}"#.utf8), 200)
                }
                guard audibleStatus == 200 else { return (Data(), audibleStatus) }
                if url.path.hasPrefix("/1.0/catalog/products/") {
                    let asin = url.lastPathComponent
                    return (byID[asin] ?? Data(#"{"product":{"asin":"\#(asin)"}}"#.utf8), 200)
                }
                return (audible[asked] ?? Data(#"{"products":[]}"#.utf8), 200)
            }
        }
    }

    func service(_ http: FakeHTTP, sources: Set<LookupSource> = [.audible, .openLibrary]) -> LookupService {
        LookupService.standard(LookupConfiguration(sources: sources, audibleStores: [.us]), http: http)
    }

    func fill(_ f: F, _ http: FakeHTTP) throws -> GenreFill {
        GenreFill(lookup: service(http), listing: try f.service.genreListing())
    }

    func all(_ stream: AsyncThrowingStream<GenreProposal, any Error>) async throws -> [GenreProposal] {
        var found: [GenreProposal] = []
        for try await proposal in stream { found.append(proposal) }
        return found
    }

    // MARK: Books

    /// A book with no files, holding these genres.
    @discardableResult
    func book(_ f: F, _ title: String, author: String? = "An Author", asin: String? = nil, _ genres: [String] = []) throws -> Int64 {
        var details = BookMetadata(title: title, authors: author.map { [$0] } ?? [])
        details.genres = genres
        details.asin = asin
        var book = Book(metadata: details)
        book.externalCopies = [ExternalCopy(kind: .audible, form: .audio)]
        return try #require(try f.store.insert(book, files: []).id)
    }

    func candidate(_ f: F, _ id: Int64, general: Bool = false) throws -> GenreFillBook {
        try #require(try f.service.genreFillCandidates(includingGeneral: general).first { $0.id == id })
    }

    /// The titles the catalogues were asked about, in order, and the ASINs.
    func asked(_ http: FakeHTTP) -> [String] {
        http.urls.map { url in
            url.path.hasPrefix("/1.0/catalog/products/") ? url.lastPathComponent : (queryItems(url)["title"] ?? "?")
        }
    }

    // MARK: G29 Which books

    @Test func G29_theBooksWithNoGenreAreCoveredByTitle() throws {
        let f = try F()
        let second = try book(f, "Zebra")
        let first = try book(f, "Aardvark", asin: "B08G9PRS1K")
        try book(f, "Has One", ["Horror"])
        try book(f, "General", ["Literary & General"])
        let books = try f.service.genreFillCandidates(includingGeneral: false)
        #expect(books.map(\.id) == [first, second])
        #expect(books.map(\.title) == ["Aardvark", "Zebra"])
        #expect(books.map(\.author) == ["An Author", "An Author"])
        #expect(books.map(\.audibleID) == ["B08G9PRS1K", nil])
    }

    @Test func G29_theSwitchAddsBooksWhoseOnlyGenresAreGeneralOrInOther() throws {
        let f = try F()
        let none = try book(f, "A None")
        let literary = try book(f, "B Literary", ["Literary & General"])
        let reference = try book(f, "C Reference", ["Reference & Learning"])
        let other = try book(f, "D Other", ["Pub Quiz"])
        let both = try book(f, "E Both", ["Pub Quiz", "Literary & General"])
        try book(f, "F Specific", ["Horror"])
        try book(f, "G Mixed", ["Literary & General", "Horror"])
        try book(f, "H Mixed", ["Horror", "Pub Quiz"])
        #expect(try f.service.genreFillCandidates(includingGeneral: false).map(\.id) == [none])
        #expect(try f.service.genreFillCandidates(includingGeneral: true).map(\.id)
            == [none, literary, reference, other, both])
    }

    @Test func G29_generalAndOtherAreJudgedByTheListAsItNowIs() throws {
        let f = try F()
        let renamed = try book(f, "A Renamed", ["Literary & General"])
        let movedIn = try book(f, "B Moved In", ["Horror"])
        let movedOut = try book(f, "C Moved Out", ["Pub Quiz"])
        try f.service.renameGenre("Literary & General", to: "General Fiction")
        try f.service.moveGenre("Horror", to: .other)
        try f.service.moveGenre("Pub Quiz", to: .nonFiction)
        #expect(try f.service.genreFillCandidates(includingGeneral: true).map(\.id) == [renamed, movedIn])
        _ = movedOut
    }

    @Test func G29_aNameTheListLacksCountsAsOneInOther() throws {
        let f = try F()
        let stray = try book(f, "A Stray")
        let mixed = try book(f, "B Mixed")
        // Stored behind the service's back: a name it stores always joins the list.
        try f.store.dbQueue.write { db in
            try db.execute(sql: #"UPDATE book SET genres = '["Unlisted"]' WHERE id = ?"#, arguments: [stray])
            try db.execute(sql: #"UPDATE book SET genres = '["Horror","Unlisted"]' WHERE id = ?"#, arguments: [mixed])
        }
        #expect(try f.service.genreList().contains { $0.name == "Unlisted" } == false)
        #expect(try f.service.genreFillCandidates(includingGeneral: false).isEmpty)
        #expect(try f.service.genreFillCandidates(includingGeneral: true).map(\.id) == [stray])
    }

    // MARK: G30 What is asked

    @Test func G30_aBookWithAnAudibleIDIsLookedUpByThatID() async throws {
        let f = try F()
        let id = try book(f, "Slow Horses", author: "Mick Herron", asin: " b08g9prs1k ")
        var catalogue = Catalogue()
        try catalogue.addByID("B08G9PRS1K", title: "Slow Horses: Slough House, Book 1", author: "M. Herron", paths: [Self.espionage])
        let http = catalogue.http()
        let found = try await all(try fill(f, http).proposals(for: [try candidate(f, id)]))
        #expect(found == [
            GenreProposal(
                id: id, title: "Slow Horses", author: "Mick Herron", genres: [Self.thrillers],
                genreSource: Self.espionage.joined(separator: " > "),
                foundTitle: "Slow Horses: Slough House, Book 1", foundAuthor: "M. Herron", source: .audible,
                isSure: true),
        ])
        // One request, by the ID, and nothing of the title or author in it.
        #expect(http.urls.count == 1)
        #expect(http.urls.first?.host == "api.audible.com")
        #expect(http.urls.first?.path == "/1.0/catalog/products/B08G9PRS1K")
        #expect(queryItems(try #require(http.urls.first))["title"] == nil)
        #expect(queryItems(try #require(http.urls.first))["author"] == nil)
    }

    @Test func G30_anAudibleCopysIDCountsAsTheBooksID() async throws {
        let f = try F()
        var record = Book(metadata: BookMetadata(title: "Owned", authors: ["An Author"]))
        record.externalCopies = [ExternalCopy(kind: .audible, form: .audio, itemId: "B00AAAAAAA")]
        let id = try #require(try f.store.insert(record, files: []).id)
        #expect(try candidate(f, id).audibleID == "B00AAAAAAA")
    }

    @Test func G30_otherBooksAreLookedUpByTitleAndFirstAuthorOnAudibleFirst() async throws {
        let f = try F()
        var details = BookMetadata(title: "Bad Actors", authors: ["Mick Herron", "Someone Else"])
        details.isbn = "9780593135204"
        details.narrators = ["Gerard Doyle"]
        let id = try #require(try f.store.insert(Book(metadata: details), files: []).id)
        var catalogue = Catalogue()
        try catalogue.addAudible(asked: "Bad Actors", found: [("Bad Actors", "Mick Herron", [Self.espionage])])
        try catalogue.addOpenLibrary(asked: "Bad Actors", title: "Bad Actors", author: "Mick Herron", subjects: ["Horror"])
        let http = catalogue.http()
        let found = try await all(try fill(f, http).proposals(for: [try candidate(f, id)]))
        #expect(found.map(\.genres) == [[Self.thrillers]])
        #expect(found.first?.source == .audible)
        // Audible had it: Open Library is not asked. Only the title and first author go.
        #expect(http.urls.map(\.host) == ["api.audible.com"])
        let items = queryItems(try #require(http.urls.first))
        #expect(items["title"] == "Bad Actors")
        #expect(items["author"] == "Mick Herron")
        #expect(items["narrator"] == nil)
        #expect(http.urls.allSatisfy { !$0.absoluteString.contains("9780593135204") && !$0.absoluteString.contains("Doyle") })
    }

    @Test func G30_openLibraryIsAskedOnlyWhenAudibleFindsNothing() async throws {
        let f = try F()
        let id = try book(f, "The Wealth of Nations", author: "Adam Smith")
        var catalogue = Catalogue()
        try catalogue.addOpenLibrary(
            asked: "The Wealth of Nations", title: "The Wealth of Nations", author: "Adam Smith",
            subjects: ["Economics", "Large type books", "Finance"])
        let http = catalogue.http()
        let found = try await all(try fill(f, http).proposals(for: [try candidate(f, id)]))
        #expect(found.count == 1)
        #expect(found.first?.source == .openLibrary)
        #expect(found.first?.genres == GenreMapping.map(.subjects(["Economics", "Large type books", "Finance"])).names)
        #expect(found.first?.genres.isEmpty == false)
        #expect(found.first?.genreSource == "Economics; Large type books; Finance")
        #expect(found.first?.isSure == true)
        #expect(http.urls.map(\.host) == ["api.audible.com", "openlibrary.org"])
    }

    @Test func G30_aResultFiledUnderNoGenreCountsAsNothing() async throws {
        let f = try F()
        let id = try book(f, "Unfiled", author: "An Author")
        var catalogue = Catalogue()
        try catalogue.addAudible(asked: "Unfiled", found: [("Unfiled", "An Author", [])])
        try catalogue.addOpenLibrary(asked: "Unfiled", title: "Unfiled", author: "An Author", subjects: ["Horror tales"])
        let http = catalogue.http()
        let found = try await all(try fill(f, http).proposals(for: [try candidate(f, id)]))
        #expect(found.first?.source == .openLibrary)
        #expect(found.first?.genres == ["Horror"])
    }

    @Test func G30_anIDTheCatalogueDoesNotKnowIsFollowedByTheTitleAndAuthor() async throws {
        let f = try F()
        let id = try book(f, "Clown Town", author: "Mick Herron", asin: "B0UNKNOWN1")
        var catalogue = Catalogue()
        try catalogue.addAudible(asked: "Clown Town", found: [("Clown Town", "Mick Herron", [Self.espionage])])
        let http = catalogue.http()
        let found = try await all(try fill(f, http).proposals(for: [try candidate(f, id)]))
        #expect(asked(http) == ["B0UNKNOWN1", "Clown Town"])
        #expect(found.first?.genres == [Self.thrillers])
        #expect(found.first?.isSure == true)
    }

    @Test func G30_noRequestIsSentForABookThatHasGenresUnlessTheSwitchIsOn() async throws {
        let f = try F()
        let none = try book(f, "Untagged One")
        try book(f, "Specific One", asin: "B0SPECIFIC", ["Horror"])
        let general = try book(f, "General One", asin: "B0GENERAL1", ["Literary & General"])
        let catalogue = Catalogue()

        let off = catalogue.http()
        let covered = try f.service.genreFillCandidates(includingGeneral: false)
        #expect(covered.map(\.id) == [none])
        _ = try await all(try fill(f, off).proposals(for: covered))
        #expect(Set(asked(off)) == ["Untagged One"])

        let on = catalogue.http()
        let more = try f.service.genreFillCandidates(includingGeneral: true)
        #expect(more.map(\.id) == [general, none])
        _ = try await all(try fill(f, on).proposals(for: more))
        #expect(Set(asked(on)) == ["B0GENERAL1", "General One", "Untagged One"])
        #expect(on.urls.allSatisfy { !$0.absoluteString.contains("SPECIFIC") && !$0.absoluteString.contains("Specific") })
    }

    @Test func G30_booksAreLookedUpOneAtATimeInTheOrderGiven() async throws {
        let f = try F()
        for title in ["A", "B", "C"] { try book(f, title) }
        let http = Catalogue().http()
        let books = try f.service.genreFillCandidates(includingGeneral: false)
        let found = try await all(try fill(f, http).proposals(for: books))
        #expect(found.map(\.title) == ["A", "B", "C"])
        // Each book's requests are all made before the next book's first.
        #expect(asked(http) == ["A", "A", "B", "B", "C", "C"])
    }

    @Test func G30_aSourceThatIsOffIsNotAsked() async throws {
        let f = try F()
        let id = try book(f, "Quiet", asin: "B08G9PRS1K")
        let http = Catalogue().http()
        let lookup = service(http, sources: [.openLibrary])
        let fill = GenreFill(lookup: lookup, listing: try f.service.genreListing())
        _ = try await all(fill.proposals(for: [try candidate(f, id)]))
        #expect(http.urls.map(\.host) == ["openlibrary.org"])
    }

    // MARK: G32 What is proposed

    @Test func G32_aTitleAndAuthorMatchIsSureOnlyWhenTheExistingMatchCountsItSo() async throws {
        let f = try F()
        let same = try book(f, "The Sum of All Fears", author: "Tom Clancy")
        let subtitle = try book(f, "Dune", author: "Frank Herbert")
        let otherAuthor = try book(f, "Without Remorse", author: "Tom Clancy")
        let noAuthor = try book(f, "Anonymous Work", author: nil)
        var catalogue = Catalogue()
        // Edition words and capitals aside, the same title by the same author.
        try catalogue.addAudible(asked: "The Sum of All Fears", found: [
            ("the sum of all fears (Unabridged)", "Tom Clancy", [Self.espionage]),
        ])
        try catalogue.addAudible(asked: "Dune", found: [("Dune: Messiah", "Frank Herbert", [Self.hardSF])])
        try catalogue.addAudible(asked: "Without Remorse", found: [("Without Remorse", "Someone Else", [Self.espionage])])
        try catalogue.addAudible(asked: "Anonymous Work", found: [("Anonymous Work", "A Writer", [Self.hardSF])])
        let http = catalogue.http()
        let books = try [same, subtitle, otherAuthor, noAuthor].map { try candidate(f, $0) }
        let found = try await all(try fill(f, http).proposals(for: books))
        #expect(found.map(\.isSure) == [true, false, false, false])
        // An unsure one still proposes, with what was found to check it by.
        #expect(found.map(\.genres) == [[Self.thrillers], ["Science Fiction"], [Self.thrillers], ["Science Fiction"]])
        #expect(found.map(\.foundTitle) == [
            "the sum of all fears (Unabridged)", "Dune: Messiah", "Without Remorse", "Anonymous Work",
        ])
        #expect(found.map(\.foundAuthor) == ["Tom Clancy", "Frank Herbert", "Someone Else", "A Writer"])
        #expect(found.allSatisfy { $0.source == .audible })
        // The rule is the one a book that arrives is matched to the library by.
        for (book, proposal) in zip(books, found) {
            var details = BookMetadata(title: proposal.foundTitle ?? "", authors: [proposal.foundAuthor ?? ""])
            details.asin = nil
            #expect(LibraryService.isSurelyTheSameBook(book, details) == proposal.isSure)
        }
    }

    @Test func G32_theRuleForSureIsTheLibrarysOwnForABookThatArrives() throws {
        let f = try F()
        let id = try f.importNew(
            [try f.makeM4B("Dune.m4b", tags: F.meta("Dune", "Frank Herbert"))], F.meta("Dune", "Frank Herbert"))
        let book = GenreFillBook(id: id, title: "Dune", author: "Frank Herbert", audibleID: nil)
        for (title, author) in [
            ("Dune", "Frank Herbert"), ("DUNE (Unabridged)", "frank herbert"), ("Dune: Messiah", "Frank Herbert"),
            ("Dune", "Brian Herbert"), ("Children of Dune", "Frank Herbert"),
        ] {
            let details = BookMetadata(title: title, authors: [author])
            let strength = try f.service.existingMatches(for: details)?.strength
            #expect(LibraryService.isSurelyTheSameBook(book, details) == (strength == .sure), "\(title), \(author)")
        }
    }

    @Test func G32_ofSeveralResultsTheOneThatIsSurelyTheBookIsTaken() async throws {
        let f = try F()
        let id = try book(f, "Dune", author: "Frank Herbert")
        var catalogue = Catalogue()
        try catalogue.addAudible(asked: "Dune", found: [
            ("Dune: The Graphic Novel", "Frank Herbert", [["Comics & Graphic Novels"]]),
            ("Dune", "Frank Herbert", [Self.hardSF]),
        ])
        let found = try await all(try fill(f, catalogue.http()).proposals(for: [try candidate(f, id)]))
        #expect(found.first?.foundTitle == "Dune")
        #expect(found.first?.isSure == true)
        #expect(found.first?.genres == ["Science Fiction"])
    }

    @Test func G32_ofSeveralResultsALaterOneThatIsSurelyTheBookIsTakenBeforeTheBestMatch() async throws {
        let f = try F()
        let id = try book(f, "Dune", author: "Frank Herbert")
        // The first matches the title and one of its authors as well as the second
        // does, but its first author is another: only the second is surely the book.
        var shared = Catalogue.product(asin: "B000000001", title: "Dune", author: "Brian Herbert", paths: [Self.espionage])
        shared["authors"] = [["name": "Brian Herbert"], ["name": "Frank Herbert"]]
        let own = Catalogue.product(asin: "B000000002", title: "Dune", author: "Frank Herbert", paths: [Self.hardSF])
        var catalogue = Catalogue()
        catalogue.audible["Dune"] = try JSONSerialization.data(withJSONObject: ["products": [shared, own]])

        let lookedUp = await service(catalogue.http()).search(
            LookupQuery(title: "Dune", author: "Frank Herbert"), preferAudio: true, language: nil, sources: [.audible])
        #expect(lookedUp.candidates.map(\.metadata.authors.first) == ["Brian Herbert", "Frank Herbert"])

        let found = try await all(try fill(f, catalogue.http()).proposals(for: [try candidate(f, id)]))
        #expect(found.first?.foundAuthor == "Frank Herbert")
        #expect(found.first?.isSure == true)
        #expect(found.first?.genres == ["Science Fiction"])
    }

    @Test func G32_withNoAuthorOnEitherSideNothingIsSure() async throws {
        let f = try F()
        let id = try book(f, "Anonymous Work", author: nil)
        let asked = try candidate(f, id)
        #expect(asked.author == nil)
        #expect(!LibraryService.isSurelyTheSameBook(asked, BookMetadata(title: "Anonymous Work", authors: [])))
        #expect(!LibraryService.isSurelyTheSameBook(asked, BookMetadata(title: "Anonymous Work", authors: [" "])))

        var product = Catalogue.product(asin: "B000000001", title: "Anonymous Work", author: "", paths: [Self.hardSF])
        product["authors"] = [[String: String]]()
        var catalogue = Catalogue()
        catalogue.audible["Anonymous Work"] = try JSONSerialization.data(withJSONObject: ["products": [product]])
        let found = try await all(try fill(f, catalogue.http()).proposals(for: [asked]))
        #expect(found.map(\.genres) == [["Science Fiction"]])
        #expect(found.map(\.foundTitle) == ["Anonymous Work"])
        #expect(found.map(\.foundAuthor) == [nil])
        #expect(found.map(\.isSure) == [false])
    }

    @Test func G32_aBookWithNoResultIsListedWithNothingFound() async throws {
        let f = try F()
        let id = try book(f, "Obscure", author: "Nobody")
        let found = try await all(try fill(f, Catalogue().http()).proposals(for: [try candidate(f, id)]))
        #expect(found == [GenreProposal(id: id, title: "Obscure", author: "Nobody")])
        #expect(found.first?.foundNothing == true)
        #expect(found.first?.isSure == false)
        #expect(found.first?.source == nil)
    }

    @Test func G32_GP10_whatIsProposedIsNamedAsTheLibraryNamesIt() async throws {
        let f = try F()
        let id = try book(f, "Slow Horses", author: "Mick Herron", asin: "B08G9PRS1K")
        try f.service.renameGenre(Self.thrillers, to: "Spies")
        try f.service.mergeGenre("Science Fiction", into: "Fantasy")
        var catalogue = Catalogue()
        try catalogue.addByID(
            "B08G9PRS1K", title: "Slow Horses", author: "Mick Herron", paths: [Self.espionage, Self.hardSF, ["Pub Quiz Books"]])
        let found = try await all(try fill(f, catalogue.http()).proposals(for: [try candidate(f, id)]))
        #expect(found.first?.genres == ["Spies", "Fantasy", "Pub Quiz Books"])
    }

    @Test func G32_aSourceThatAnswersWithAnErrorIsNotedAndTheOthersAreStillAsked() async throws {
        let f = try F()
        let found = try book(f, "A Found", author: "An Author")
        let missing = try book(f, "B Missing", author: "An Author")
        var catalogue = Catalogue()
        catalogue.audibleStatus = 503
        try catalogue.addOpenLibrary(asked: "A Found", title: "A Found", author: "An Author", subjects: ["Horror tales"])
        let books = try [found, missing].map { try candidate(f, $0) }
        let proposals = try await all(try fill(f, catalogue.http()).proposals(for: books))
        #expect(proposals.map(\.genres) == [["Horror"], []])
        #expect(proposals.map(\.failure) == [nil, .refused(status: 503)])
    }

    // MARK: G33 Stopping, and no network

    @Test func G33_stoppedPartWayWhatWasFoundIsKeptAndNothingMoreIsAsked() async throws {
        let f = try F()
        for title in ["A", "B", "C", "D", "E"] { try book(f, title) }
        var catalogue = Catalogue()
        try catalogue.addAudible(asked: "A", found: [("A", "An Author", [Self.espionage])])
        let http = catalogue.http()
        let books = try f.service.genreFillCandidates(includingGeneral: false)
        let stream = try fill(f, http).proposals(for: books)
        let before = try f.store.books()

        let task = Task { () -> [GenreProposal] in
            var found: [GenreProposal] = []
            for try await proposal in stream {
                found.append(proposal)
                // Stop is pressed once the first has arrived.
                withUnsafeCurrentTask { $0?.cancel() }
            }
            return found
        }
        let found = try await task.value
        #expect(found.map(\.title) == ["A"])
        #expect(found.first?.genres == [Self.thrillers])
        #expect(asked(http) == ["A"])
        #expect(try f.store.books() == before)
    }

    /// Holds the task that reads the proposals, so that a request can stop it.
    final class Reader: @unchecked Sendable {
        private let lock = NSLock()
        private var task: Task<[GenreProposal], any Error>?

        func set(_ task: Task<[GenreProposal], any Error>) { lock.withLock { self.task = task } }
        var isSet: Bool { lock.withLock { task != nil } }
        func stop() { lock.withLock { task }?.cancel() }
    }

    @Test func G33_stoppedInTheMiddleOfABookItEndsThereWithoutAnError() async throws {
        let f = try F()
        for title in ["A", "B", "C"] { try book(f, title) }
        var catalogue = Catalogue()
        try catalogue.addAudible(asked: "A", found: [("A", "An Author", [Self.espionage])])
        let answers = catalogue.http()
        let reader = Reader()
        // Stop is pressed while the second book is being asked about.
        let http = FakeHTTP { url in
            if queryItems(url)["title"] == "B" { reader.stop() }
            return try answers.answerForTest(url)
        }
        let stream = try fill(f, http).proposals(for: try f.service.genreFillCandidates(includingGeneral: false))
        let task = Task { () -> [GenreProposal] in
            while !reader.isSet { await Task.yield() }
            var found: [GenreProposal] = []
            for try await proposal in stream { found.append(proposal) }
            return found
        }
        reader.set(task)
        let found = try await task.value
        #expect(found.map(\.title) == ["A"])
        #expect(asked(http) == ["A", "B"])
    }

    @Test func G33_whatIsFoundForTheBookBeingAskedAboutWhenStopIsPressedIsNotHandedOver() async throws {
        let f = try F()
        for title in ["A", "B", "C"] { try book(f, title) }
        var catalogue = Catalogue()
        try catalogue.addAudible(asked: "A", found: [("A", "An Author", [Self.espionage])])
        try catalogue.addAudible(asked: "B", found: [("B", "An Author", [Self.hardSF])])
        try catalogue.addAudible(asked: "C", found: [("C", "An Author", [Self.hardSF])])
        let answers = catalogue.http()
        let reader = Reader()
        // Stop is pressed while the second book is being asked about, and it is answered.
        let http = FakeHTTP { url in
            if queryItems(url)["title"] == "B" { reader.stop() }
            return try answers.answerForTest(url)
        }
        let stream = try fill(f, http).proposals(for: try f.service.genreFillCandidates(includingGeneral: false))
        let task = Task { () -> [GenreProposal] in
            while !reader.isSet { await Task.yield() }
            var found: [GenreProposal] = []
            for try await proposal in stream { found.append(proposal) }
            return found
        }
        reader.set(task)
        let found = try await task.value
        #expect(found.map(\.title) == ["A"])
        #expect(asked(http) == ["A", "B"])
    }

    @Test func G30_whatComesBackUnderAnotherIDIsNotTakenAsTheBook() async throws {
        let f = try F()
        let id = try book(f, "Mine", author: "An Author", asin: "B08G9PRS1K")
        var catalogue = Catalogue()
        catalogue.byID["B08G9PRS1K"] = try JSONSerialization.data(withJSONObject: [
            "product": Catalogue.product(asin: "B000000009", title: "Another", author: "Someone", paths: [Self.hardSF]),
        ])
        let found = try await all(try fill(f, catalogue.http()).proposals(for: [try candidate(f, id)]))
        #expect(found == [GenreProposal(id: id, title: "Mine", author: "An Author")])
    }

    @Test func G33_withoutTheNetworkTheLookupEndsWithAnErrorTheAppCanWordAndNothingChanges() async throws {
        let f = try F()
        for title in ["A", "B", "C"] { try book(f, title, asin: "B08G9PRS1K") }
        let before = try f.store.books()
        let list = try f.store.genreRows()
        let http = FakeHTTP(throwing: LookupError.notReachable)
        let books = try f.service.genreFillCandidates(includingGeneral: false)
        var found: [GenreProposal] = []
        var failure: LookupError?
        do {
            for try await proposal in try fill(f, http).proposals(for: books) { found.append(proposal) }
        } catch let error as LookupError {
            failure = error
        }
        #expect(failure == .notReachable)
        #expect(found.isEmpty)
        // It stops at the first book: the others are not tried.
        #expect(http.urls.count == 1)
        #expect(try f.store.books() == before)
        #expect(try f.store.genreRows() == list)
        #expect(try f.service.undoLabel() == nil)
    }

    // MARK: G31, G33 Apply

    /// A book of one M4B with every field and a cover, and no genre.
    func importFull(_ f: F, _ title: String) throws -> Int64 {
        var details = F.fullMeta(title, "An Author")
        details.genres = []
        details.genreSource = nil
        let url = try f.makeM4B("\(title).m4b", tags: details, cover: F.jpeg)
        return try f.importNew([url], details, cover: .set(F.jpeg))
    }

    func place(_ f: F, _ id: Int64) throws -> URL {
        f.store.url(for: try #require(try f.store.files(bookId: id).first))
    }

    @Test func G31_onlyTheGenresAreTakenEveryOtherFieldAndTheCoverStay() async throws {
        let f = try F()
        let id = try importFull(f, "Full")
        let url = try place(f, id)
        let recordBefore = try #require(try f.store.book(id: id))
        let fileBefore = try f.io.read(url)
        let coverBefore = try f.service.covers.image(for: id)
        var catalogue = Catalogue()
        // What is found differs from the book in everything it can.
        var product = Catalogue.product(asin: "B08G9PRS1K", title: "Full: Another Title", author: "Another Author", paths: [Self.espionage])
        product["subtitle"] = "Another Subtitle"
        product["publisher_name"] = "Another Publisher"
        product["release_date"] = "1999-01-01"
        product["narrators"] = [["name": "Another Narrator"]]
        product["publisher_summary"] = "Another summary."
        product["product_images"] = ["500": "https://m.media-amazon.com/images/I/another.jpg"]
        catalogue.byID["B08G9PRS1K"] = try JSONSerialization.data(withJSONObject: ["product": product])
        let http = catalogue.http()

        let proposals = try await all(try fill(f, http).proposals(for: [try candidate(f, id)]))
        #expect(proposals.first?.isSure == true)
        // No cover was fetched.
        #expect(http.urls.count == 1)
        let outcomes = try f.service.applyGenres(proposals.map(GenreChoice.init))
        guard case .saved(_, _, _, let problems) = try #require(outcomes.first) else {
            Issue.record("expected .saved, got \(outcomes)")
            return
        }
        #expect(problems.isEmpty)

        var expected = recordBefore
        expected.genres = [Self.thrillers]
        expected.genreSource = Self.espionage.joined(separator: " > ")
        expected.genreTag = Self.thrillers
        #expect(try f.store.book(id: id) == expected)
        let fileAfter = try f.io.read(url)
        var details = fileBefore.metadata
        details.genres = [Self.thrillers]
        details.genreSource = Self.thrillers
        #expect(fileAfter.metadata == details)
        #expect(fileAfter.cover == fileBefore.cover)
        #expect(try f.service.covers.image(for: id) == coverBefore)
        #expect(try place(f, id) == url)
    }

    @Test func G31_whatTheOwnerNotedOfABookStaysWhenItsGenresAreFilledIn() throws {
        let f = try F()
        let id = try importFull(f, "Noted")
        var edit = BookEdit(book: try #require(try f.store.book(id: id)))
        edit.rating = 4
        edit.tags = ["favourite", "re-read"]
        edit.editionKind = EditionKindNote(kind: .abridged, basis: .setByHand)
        _ = try f.service.save([edit])
        try f.service.setReadStatus(.finished, for: [id])
        let before = try #require(try f.store.book(id: id))
        #expect(before.rating == 4)
        #expect(before.tags == ["favourite", "re-read"])
        #expect(before.editionKind?.kind == .abridged)
        #expect(before.readStatus == .finished)

        _ = try f.service.applyGenres([GenreChoice(bookId: id, genres: ["Horror"], genreSource: "Horror tales")])
        var expected = before
        expected.genres = ["Horror"]
        expected.genreSource = "Horror tales"
        expected.genreTag = "Horror"
        #expect(try f.store.book(id: id) == expected)
    }

    @Test func G33_applySetsTheChosenBooksGenresAsOneOperationAndWritesTheirFiles() throws {
        let f = try F()
        let first = try importFull(f, "First")
        let second = try importFull(f, "Second")
        let notChosen = try importFull(f, "Not Chosen")
        try f.service.renameGenre("Fantasy", to: "Magic")
        let outcomes = try f.service.applyGenres([
            GenreChoice(bookId: first, genres: [Self.thrillers, "crime & mystery"], genreSource: "A > B"),
            GenreChoice(bookId: second, genres: ["Fantasy", "Pub Quiz Books"], genreSource: "C"),
        ])
        #expect(outcomes.count == 2)
        #expect(try f.store.book(id: first)?.genres == [Self.thrillers, "Crime & Mystery"])
        #expect(try f.store.book(id: first)?.genreSource == "A > B")
        // GP10: stored as the library names them; a new name joins the list in Other.
        #expect(try f.store.book(id: second)?.genres == ["Magic", "Pub Quiz Books"])
        #expect(try f.service.genreList().first { $0.name == "Pub Quiz Books" }?.group == .other)
        #expect(try f.io.read(try place(f, first)).metadata.genreSource == "Thrillers & Spies; Crime & Mystery")
        #expect(try f.io.read(try place(f, second)).metadata.genreSource == "Magic; Pub Quiz Books")
        #expect(try f.store.book(id: notChosen)?.genres == [])
        #expect(try f.io.read(try place(f, notChosen)).metadata.genreSource == nil)
        #expect(try f.service.undoLabel() == "Fill in genres for 2 books")
        #expect(try f.service.genreFileDifferences().isEmpty)
        #expect(try f.service.genreFillCandidates(includingGeneral: false).map(\.id) == [notChosen])
    }

    @Test func G33_undoOfApplyRestoresTheSameRecordsTheSameListAndTheSameTags() throws {
        let f = try F()
        let first = try importFull(f, "First")
        let second = try importFull(f, "Second")
        let booksBefore = try f.store.books()
        let rowsBefore = try f.store.allFiles().map(\.path)
        let listBefore = try f.store.genreRows()
        let places = try [first, second].map { try place(f, $0) }
        let detailsBefore = try places.map { try f.io.read($0).metadata }
        let tracksBefore = try places.map { try f.trackTags($0) }

        _ = try f.service.applyGenres([
            GenreChoice(bookId: first, genres: [Self.thrillers], genreSource: "A > B"),
            GenreChoice(bookId: second, genres: ["Horror"], genreSource: "C"),
        ])
        #expect(try f.store.books() != booksBefore)
        #expect(try places.map { try f.io.read($0).metadata.genreSource } == [Self.thrillers, "Horror"])

        #expect(try f.service.undoLast() == "Fill in genres for 2 books")
        #expect(try f.store.books() == booksBefore)
        #expect(try f.store.allFiles().map(\.path) == rowsBefore)
        #expect(try f.store.genreRows() == listBefore)
        #expect(try places.map { try f.io.read($0).metadata } == detailsBefore)
        #expect(try places.map { try f.trackTags($0) } == tracksBefore)
    }

    @Test func G33_aChoiceWithNoGenresOrForNoBookIsRefusedAndTheRestAreApplied() throws {
        let f = try F()
        let kept = try book(f, "Kept", ["Horror"])
        let filled = try book(f, "Filled")
        let outcomes = try f.service.applyGenres([
            GenreChoice(bookId: kept, genres: [" "]),
            GenreChoice(bookId: 9_999, genres: ["Horror"]),
            GenreChoice(bookId: filled, genres: ["Romance"]),
        ])
        guard case .failed(let first, _) = outcomes[0], case .failed(let second, _) = outcomes[1],
              case .saved(let third, _, _, _) = outcomes[2]
        else {
            Issue.record("unexpected outcomes \(outcomes)")
            return
        }
        #expect([first, second, third] == [kept, 9_999, filled])
        #expect(try f.store.book(id: kept)?.genres == ["Horror"])
        #expect(try f.store.book(id: filled)?.genres == ["Romance"])
        #expect(try f.service.undoLabel() == "Fill in genres")
    }

    @Test func G33_nothingChangesUntilApply() async throws {
        let f = try F()
        let id = try importFull(f, "Waiting")
        let url = try place(f, id)
        let bytes = try Data(contentsOf: url)
        let before = try f.store.books()
        let label = try f.service.undoLabel()
        var catalogue = Catalogue()
        try catalogue.addByID("B08G9PRS1K", title: "Waiting", author: "An Author", paths: [Self.espionage])
        let found = try await all(try fill(f, catalogue.http()).proposals(for: [try candidate(f, id)]))
        #expect(found.first?.genres == [Self.thrillers])
        #expect(try f.store.books() == before)
        #expect(try Data(contentsOf: url) == bytes)
        #expect(try f.service.undoLabel() == label)
        #expect(try f.service.genreList().allSatisfy { $0.bookCount == 0 })
    }
}

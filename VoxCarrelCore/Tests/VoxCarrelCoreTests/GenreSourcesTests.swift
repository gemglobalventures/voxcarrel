import Foundation
import Testing
@testable import VoxCarrelCore
import VoxCarrelFixtures

/// Where a book's genres come from: the tags of files being brought in, and lookups.
/// Everything a source says goes to the mapping whole.
@Suite struct GenreSourcesTests {
    typealias F = LibraryFixture

    static let thrillers = "Thrillers & Spies"
    static let crime = "Crime & Mystery"

    /// An M4B in the fixture's inbox whose genre tag is `tag`.
    func tagged(_ f: F, _ name: String, _ tag: String?) throws -> URL {
        var tags = F.meta(name, "An Author")
        tags.genres = tag.map { [$0] } ?? []
        return try f.makeM4B("\(name).m4b", tags: tags)
    }

    // MARK: G19 At import

    @Test func G19_aScannedFilesGenreTagGoesThroughTheMapping() throws {
        let f = try F()
        let cases: [(tag: String?, genres: [String])] = [
            ("International Mystery & Crime, Espionage, Traditional Detectives", [Self.thrillers, Self.crime]),
            ("Mystery, Thriller & Suspense", [Self.thrillers]),
            ("Audiobook", []),
            ("Sci-Fi", ["Science Fiction"]),
            (nil, []),
        ]
        for (index, entry) in cases.enumerated() {
            let url = try tagged(f, "Book \(index)", entry.tag)
            let candidate = try #require(f.service.scan([url]).candidates.first)
            #expect(candidate.metadata.genres == entry.genres, "\(entry.tag ?? "no tag")")
            // The tag as it stands is kept beside them, to become the book's wording.
            #expect(candidate.metadata.genreSource == entry.tag, "\(entry.tag ?? "no tag")")
        }
    }

    @Test func G19_theImportedBookHasTheMappedGenresTheWordingAndTheTagWritten() throws {
        let f = try F()
        let url = try tagged(f, "Bad Actors", "International Mystery & Crime, Espionage")
        let candidate = try #require(f.service.scan([url]).candidates.first)
        let result = try f.service.importItems([ImportItem(candidate: candidate)])
        let id = try f.importedId(try #require(result.outcomes.first))

        let book = try #require(try f.store.book(id: id))
        #expect(book.genres == [Self.thrillers, Self.crime])
        #expect(book.genreSource == "International Mystery & Crime, Espionage")
        let filed = f.store.url(for: try #require(try f.store.files(bookId: id).first))
        #expect(try FileMetadataIO().read(filed).metadata.genreSource == "Thrillers & Spies; Crime & Mystery")
    }

    @Test func G19_genresChangedInTheReviewAreTheOnesImported() throws {
        let f = try F()
        let url = try tagged(f, "Reviewed", "Mystery, Thriller & Suspense")
        var candidate = try #require(f.service.scan([url]).candidates.first)
        candidate.metadata.genres = ["Horror", Self.thrillers]
        let id = try f.importedId(
            try #require(try f.service.importItems([ImportItem(candidate: candidate)]).outcomes.first))
        let book = try #require(try f.store.book(id: id))
        #expect(book.genres == ["Horror", Self.thrillers])
        // The wording is still what the file said.
        #expect(book.genreSource == "Mystery, Thriller & Suspense")
    }

    @Test func G18_G19_aFileTaggedWithTheLibrarysOwnGenreIsScannedAsWritten() throws {
        let f = try F()
        // The library has a genre of the owner's own.
        var own = F.meta("First", "An Author")
        own.genres = ["Pub Quiz"]
        _ = try f.importNew([try f.makeM4B("first.m4b", tags: F.meta("First", "An Author"))], own)

        // A file that comes back in with a tag this library wrote.
        let url = try tagged(f, "Second", "Pub Quiz; Fantasy")
        let candidate = try #require(f.service.scan([url]).candidates.first)
        #expect(candidate.metadata.genres == ["Pub Quiz", "Fantasy"])

        // A library without that genre lets the mapping decide: the name it knows first.
        let elsewhere = try F()
        let other = try #require(elsewhere.service.scan([url]).candidates.first)
        #expect(other.metadata.genres == ["Fantasy", "Pub Quiz"])
    }

    @Test func G19_aScannedBookOfSeveralFilesHasTheFirstFilesGenres() throws {
        let f = try F()
        var one = F.meta("Long Book", "Ann Author")
        one.genres = ["History"]
        var two = one
        two.genres = ["Horror"]
        let parts = [
            try f.makeMP3("long/part1.mp3", tags: one), try f.makeMP3("long/part2.mp3", tags: two),
        ]
        let candidate = try #require(f.service.scan([parts[0].deletingLastPathComponent()]).candidates.first)
        #expect(candidate.files.count == 2)
        #expect(candidate.metadata.genres == ["History"])
        #expect(candidate.metadata.genreSource == "History")
    }

    @Test func G19_anArrivalInTheInboxHasItsTagMappedAsAScanDoes() throws {
        let f = try F()
        var now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        _ = try f.service.addWatchFolder(f.inbox, now: now)
        _ = try tagged(f, "Arrived", "Mystery, Thriller & Suspense, Mystery")
        var report = InboxReport(arrivals: [], folders: [], hasUnsettled: true)
        for _ in 0..<2 {
            now += 11
            report = try f.service.checkInbox(now: now)
        }
        let arrival = try #require(report.arrivals.first)
        #expect(arrival.candidate.metadata.genres == [Self.crime])
        #expect(arrival.candidate.metadata.genreSource == "Mystery, Thriller & Suspense, Mystery")
    }

    // MARK: G20 Audible

    /// An Audible answer holding one product filed under `paths`, each a ladder under
    /// the root "Genres", with one more ladder under another root.
    static func audibleAnswer(paths: [[String]]) throws -> Data {
        var ladders: [[String: Any]] = [
            ["root": "EditorsPicks", "ladder": [["id": "1", "name": "Romance"]]],
        ]
        for path in paths {
            ladders.append(["root": "Genres", "ladder": path.map { ["id": "0", "name": $0] }])
        }
        let product: [String: Any] = ["asin": "B000000001", "title": "A Book", "category_ladders": ladders]
        return try JSONSerialization.data(withJSONObject: ["products": [product]])
    }

    func audible(_ paths: [[String]]) async throws -> BookMetadata {
        let http = FakeHTTP(data: try Self.audibleAnswer(paths: paths))
        let found = try await AudibleProvider(http: http, store: .us).search(LookupQuery(title: "A Book"))
        return try #require(found.first).metadata
    }

    /// Paths as Audible gave them for books of the owner's.
    static let badActors = [
        ["Mystery, Thriller & Suspense", "Mystery", "International Mystery & Crime"],
        ["Mystery, Thriller & Suspense", "Mystery", "Traditional Detectives"],
        ["Mystery, Thriller & Suspense", "Thriller & Suspense", "Spies & Politics", "Espionage"],
    ]
    static let withoutRemorse = [
        ["Literature & Fiction", "Action & Adventure", "Mystery, Thriller & Suspense", "Thriller & Suspense"],
        ["Literature & Fiction", "Action & Adventure", "War & Military"],
        ["Literature & Fiction", "Genre Fiction", "War & Military"],
        ["Mystery, Thriller & Suspense", "Thriller & Suspense", "Spies & Politics", "Espionage"],
        ["Mystery, Thriller & Suspense", "Thriller & Suspense", "Suspense"],
    ]
    static let projectMaven = [
        ["Computers & Technology", "Computer Science"],
        ["History", "Military", "Military Science"],
        ["Politics & Social Sciences", "Politics & Government", "Freedom & Security",
         "National & International Security"],
        ["Politics & Social Sciences", "Politics & Government", "International Relations", "Arms Control"],
    ]

    @Test func G20_GP5_audibleKeepsEveryPathFiledUnderGenresAndTheMappingReadsThemTogether() async throws {
        let bad = try await audible(Self.badActors)
        #expect(bad.genres == [Self.thrillers, Self.crime])
        // Every path, whole, is the wording; the ladder under another root is not.
        #expect(bad.genreSource == """
            Mystery, Thriller & Suspense > Mystery > International Mystery & Crime; \
            Mystery, Thriller & Suspense > Mystery > Traditional Detectives; \
            Mystery, Thriller & Suspense > Thriller & Suspense > Spies & Politics > Espionage
            """)
        #expect(bad.genreSource == GenreMapping.wording(of: .paths(Self.badActors)))

        let remorse = try await audible(Self.withoutRemorse)
        #expect(remorse.genres == [Self.thrillers])

        let maven = try await audible(Self.projectMaven)
        #expect(maven.genres.first == "Politics & Society")
        #expect(Set(maven.genres) == ["Politics & Society", "Technology", "History"])
    }

    @Test func G20_theResultIsWhatTheMappingGivesForThePathsHandedOverWhole() async throws {
        for paths in [Self.badActors, Self.withoutRemorse, Self.projectMaven] {
            let found = try await audible(paths)
            #expect(found.genres == GenreMapping.map(.paths(paths)).names)
        }
        // A name Audible files a book under that the mapping does not know is kept.
        let odd = try await audible([["Pub Quiz Books", "Trivia Nights"]])
        #expect(odd.genres == GenreMapping.map(.paths([["Pub Quiz Books", "Trivia Nights"]])).names)
        #expect(odd.genreSource == "Pub Quiz Books > Trivia Nights")
    }

    @Test func G20_aBookFiledUnderNoGenreHasNoneAndNoWording() async throws {
        let none = try await audible([])
        #expect(none.genres.isEmpty)
        #expect(none.genreSource == nil)
    }

    // MARK: G20 Open Library

    func openLibrary(subjects: [Any]) async throws -> BookMetadata {
        let doc: [String: Any] = [
            "key": "/works/OL1W", "title": "A Book", "author_name": ["An Author"], "subject": subjects,
        ]
        let http = FakeHTTP(data: try JSONSerialization.data(withJSONObject: ["docs": [doc]]))
        let found = try await OpenLibraryProvider(http: http).search(LookupQuery(title: "A Book"))
        return try #require(found.first).metadata
    }

    @Test func G20_openLibraryHandsOverItsSubjectsAndUnknownOnesAreDropped() async throws {
        let found = try await openLibrary(subjects: [
            "Large type books", "Spy stories", "New York Times reviewed", "Fiction, espionage", 7,
            "nyt:hardcover-fiction=2021-05-23", "Finance",
        ])
        #expect(found.genres == GenreMapping.map(.subjects([
            "Large type books", "Spy stories", "New York Times reviewed", "Fiction, espionage",
            "nyt:hardcover-fiction=2021-05-23", "Finance",
        ])).names)
        #expect(found.genres.contains(Self.thrillers))
        #expect(found.genres.contains("Money & Investing"))
        // Nothing the mapping does not know becomes a genre.
        #expect(found.genres.allSatisfy { BuiltInGenre.named($0) != nil })
        #expect(found.genreSource == """
            Large type books; Spy stories; New York Times reviewed; Fiction, espionage; \
            nyt:hardcover-fiction=2021-05-23; Finance
            """)
    }

    @Test func G20_openLibrarySubjectsThatSayNothingGiveNoGenre() async throws {
        let noise = try await openLibrary(subjects: ["Large type books", "New York Times reviewed"])
        #expect(noise.genres.isEmpty)
        #expect(noise.genreSource == "Large type books; New York Times reviewed")

        let none = try await openLibrary(subjects: [])
        #expect(none.genres.isEmpty)
        #expect(none.genreSource == nil)
    }

    @Test func G20_openLibraryTakesNoMoreSubjectsThanItsLimit() async throws {
        let many = (1...200).map { "Subject \($0)" } + ["Horror"]
        let found = try await openLibrary(subjects: many)
        #expect(OpenLibraryProvider.subjects(many).count == OpenLibraryProvider.subjectLimit)
        // What lies beyond the limit is not read.
        #expect(found.genres.isEmpty)
    }
}

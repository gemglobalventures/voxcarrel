import Foundation
import Testing
@testable import VoxCarrelCore

@Suite struct AudibleNarratorTests {
    private let query = LookupQuery(title: "Dead Lions", author: "Mick Herron", narrator: " Gerard Doyle ")

    // MARK: N1

    @Test func N1_theNarratorIsSentWithATitleSearch() async throws {
        let http = FakeHTTP(data: fixture("au-narrator-found"))
        let found = try await AudibleProvider(http: http, store: .us).search(query)
        #expect(http.urls.count == 1)
        let url = try #require(http.urls.first)
        #expect(url.host == "api.audible.com")
        #expect(url.path == "/1.0/catalog/products")
        #expect(queryItems(url) == [
            "title": "Dead Lions", "author": "Mick Herron", "narrator": "Gerard Doyle", "num_results": "8",
            "products_sort_by": "Relevance", "response_groups": AudibleProviderTests.groups, "image_sizes": "500,1024",
        ])
        #expect(found.map(\.id) == ["audible:us:B09XN7T3FP"])
        #expect(found.first?.metadata.narrators == ["Gerard Doyle"])
    }

    @Test func N1_noNarratorNoParameter() async throws {
        for narrator in [nil, "", "  "] as [String?] {
            let http = FakeHTTP(data: fixture("au-narrator-found"))
            _ = try await AudibleProvider(http: http, store: .us)
                .search(LookupQuery(title: "Dead Lions", author: "Mick Herron", narrator: narrator))
            #expect(http.urls.count == 1)
            let url = try #require(http.urls.first)
            #expect(queryItems(url)["narrator"] == nil)
        }
    }

    @Test func N1_nothingReadByTheNarratorIsSearchedAgainWithout() async throws {
        let http = FakeHTTP { url in
            (fixture(queryItems(url)["narrator"] == nil ? "au-stores-us" : "au-narrator-none"), 200)
        }
        let found = try await AudibleProvider(http: http, store: .us)
            .search(LookupQuery(title: "A Perfect Spy", author: "John le Carré", narrator: "Frank Muller"))
        #expect(http.urls.count == 2)
        let first = try #require(http.urls.first), second = try #require(http.urls.last)
        #expect(queryItems(first)["narrator"] == "Frank Muller")
        // The same search, less the narrator.
        var expected = queryItems(first)
        expected["narrator"] = nil
        #expect(queryItems(second) == expected)
        #expect(second.host == first.host)
        #expect(second.path == first.path)
        #expect(found.map(\.id) == ["audible:us:B004WPQ4BI", "audible:us:B0D3MX4TFN", "audible:us:B074JD5VBZ"])
    }

    @Test func N1_theSearchIsRepeatedOnlyOnce() async throws {
        let http = FakeHTTP(data: fixture("au-narrator-none"))
        let found = try await AudibleProvider(http: http, store: .uk)
            .search(LookupQuery(title: "A Perfect Spy", narrator: "Frank Muller"))
        #expect(found.isEmpty)
        #expect(http.urls.count == 2)
        // Without a narrator there is nothing to repeat.
        let plain = FakeHTTP(data: fixture("au-narrator-none"))
        #expect(try await AudibleProvider(http: plain, store: .uk).search(LookupQuery(title: "A Perfect Spy")).isEmpty)
        #expect(plain.urls.count == 1)
    }

    @Test func N1_aFailedNarratorSearchIsNotRepeated() async throws {
        let http = FakeHTTP(data: Data(), status: 503)
        await #expect(throws: LookupError.refused(status: 503)) {
            _ = try await AudibleProvider(http: http, store: .us).search(query)
        }
        #expect(http.urls.count == 1)
    }

    @Test func N1_anASINLookupNeverSendsTheNarrator() async throws {
        let http = FakeHTTP(data: fixture("au-asin"))
        var asked = query
        asked.asin = "B08G9PRS1K"
        let found = try await AudibleProvider(http: http, store: .us).search(asked)
        #expect(found.count == 1)
        #expect(http.urls.count == 1)
        let url = try #require(http.urls.first)
        #expect(url.path == "/1.0/catalog/products/B08G9PRS1K")
        #expect(queryItems(url) == ["response_groups": AudibleProviderTests.groups, "image_sizes": "500,1024"])
        #expect(!url.absoluteString.contains("Gerard"))
    }

    @Test func N1_anUnknownASINFallsBackToTheTitleSearchWithTheNarrator() async throws {
        let http = FakeHTTP { url in
            (fixture(url.path.hasSuffix("/products") ? "au-narrator-found" : "au-badasin"), 200)
        }
        var asked = query
        asked.asin = "B000000000"
        let found = try await AudibleProvider(http: http, store: .us).search(asked)
        #expect(found.map(\.id) == ["audible:us:B09XN7T3FP"])
        #expect(http.urls.count == 2)
        #expect(queryItems(http.urls[0])["narrator"] == nil)
        #expect(queryItems(http.urls[1])["narrator"] == "Gerard Doyle")
    }

    // MARK: N2

    /// What the repeated search finds is exactly what a search without a narrator finds.
    @Test func N2_aResultOfTheRepeatedSearchIsNotMarked() async throws {
        let http = FakeHTTP { url in
            (fixture(queryItems(url)["narrator"] == nil ? "au-stores-us" : "au-narrator-none"), 200)
        }
        let repeated = try await AudibleProvider(http: http, store: .us)
            .search(LookupQuery(title: "A Perfect Spy", author: "John le Carré", narrator: "Frank Muller"))
        let plain = try await AudibleProvider(http: FakeHTTP(data: fixture("au-stores-us")), store: .us)
            .search(LookupQuery(title: "A Perfect Spy", author: "John le Carré"))
        #expect(repeated == plain)
        #expect(!repeated.isEmpty)
    }

    // MARK: N5, N7

    @Test func N5_editionFactsOfAnAudibleResult() async throws {
        let found = try await AudibleProvider(http: FakeHTTP(data: fixture("au-stores-uk")), store: .uk)
            .search(LookupQuery(title: "A Perfect Spy"))
        #expect(found.map(\.id) == ["audible:uk:B0DM2NJ5SK", "audible:uk:B074JGKNXT", "audible:uk:B004WPPYP0", "audible:uk:B0FYQJC8PR"])
        #expect(found.allSatisfy { $0.source == .audible })
        #expect(found.map(\.edition) == [
            EditionFacts(format: .digital, abridged: false, publisher: "Penguin", year: 2025, stores: ["uk"]),
            EditionFacts(format: .digital, abridged: true, publisher: "BBC Digital Audio", year: 2017, stores: ["uk"]),
            EditionFacts(format: .digital, abridged: false, publisher: "BBC Digital Audio", year: 2011, stores: ["uk"]),
            EditionFacts(format: .digital, abridged: true, publisher: "Penguin", year: 2025, stores: ["uk"]),
        ])
        #expect(found.first?.metadata.narrators == ["Rory Kinnear"])
        #expect(found.first?.metadata.durationSeconds == 71_940)
    }

    @Test(arguments: [
        ("unabridged", false), ("Unabridged", false), ("abridged", true), ("ABRIDGED", true),
        ("original_recording", nil), ("", nil), ("highlights", nil),
    ] as [(String, Bool?)])
    func N5_abridgedFromTheFormatType(format: String, abridged: Bool?) async throws {
        let body = #"{"products": [{"asin": "B08G9PRS1K", "title": "T", "format_type": "\#(format)"}]}"#
        let found = try await AudibleProvider(http: FakeHTTP(data: Data(body.utf8)), store: .de).search(LookupQuery(title: "T"))
        #expect(found.count == 1)
        #expect(found.first?.edition == EditionFacts(format: .digital, abridged: abridged, stores: ["de"]))
    }

    @Test func N5_noFormatTypeIsUnknown() async throws {
        let body = #"{"products": [{"asin": "B08G9PRS1K", "title": "T", "format_type": 7}]}"#
        let found = try await AudibleProvider(http: FakeHTTP(data: Data(body.utf8)), store: .us).search(LookupQuery(title: "T"))
        #expect(found.first?.edition.abridged == nil)
    }
}

@Suite struct AudibleStoresProviderTests {
    private let query = LookupQuery(title: "A Perfect Spy", author: "John le Carré")

    /// Each store's own answer from the trial.
    private static func stores(failing: Set<String> = []) -> FakeHTTP {
        FakeHTTP { url in
            let host = url.host ?? ""
            if failing.contains(host) { throw LookupError.notReachable }
            switch host {
            case "api.audible.com": return (fixture("au-stores-us"), 200)
            case "api.audible.co.uk": return (fixture("au-stores-uk"), 200)
            case "api.audible.com.au": return (fixture("au-stores-au"), 200)
            default: return (fixture("au-none"), 200)
            }
        }
    }

    // MARK: N3

    @Test func N3_everyStoreIsAskedTheSameThing() async throws {
        let http = Self.stores()
        let provider = AudibleStoresProvider(http: http, stores: [.uk, .us, .au])
        #expect(provider.source == .audible)
        var asked = query
        asked.isbn = "9780340393130"
        _ = try await provider.search(asked)
        #expect(http.urls.count == 3)
        #expect(Set(http.urls.compactMap(\.host)) == ["api.audible.co.uk", "api.audible.com", "api.audible.com.au"])
        for url in http.urls {
            #expect(url.scheme == "https")
            #expect(url.path == "/1.0/catalog/products")
            #expect(queryItems(url) == [
                "title": "A Perfect Spy", "author": "John le Carré", "num_results": "12", "products_sort_by": "Relevance",
                "response_groups": AudibleProviderTests.groups, "image_sizes": "500,1024",
            ])
        }
        for request in http.requests {
            #expect(request.headers == ["User-Agent": "VoxCarrel/0.1 (https://voxcarrel.com)", "Accept": "application/json"])
        }
    }

    @Test func N3_theLimitAndTheNarratorReachEveryStore() async throws {
        let http = Self.stores()
        var asked = query
        asked.narrator = "Rory Kinnear"
        _ = try await AudibleStoresProvider(http: http, stores: [.us, .uk], limit: 5).search(asked)
        // The United States store has nothing read by anyone here: its fixture answers
        // whatever is asked, so each store is asked once.
        #expect(http.urls.count == 2)
        for url in http.urls {
            #expect(queryItems(url)["num_results"] == "5")
            #expect(queryItems(url)["narrator"] == "Rory Kinnear")
        }
    }

    @Test func N3_aStoreNamedTwiceIsAskedOnce() async throws {
        let http = Self.stores()
        let found = try await AudibleStoresProvider(http: http, stores: [.us, .us, .uk, .us]).search(query)
        #expect(http.urls.count == 2)
        #expect(found.first?.edition.stores == ["us", "uk"])
    }

    @Test func N3_noStoresNoRequests() async throws {
        let http = Self.stores()
        #expect(try await AudibleStoresProvider(http: http, stores: []).search(query).isEmpty)
        #expect(http.urls.isEmpty)
    }

    @Test func N3_oneStoreFailingDoesNotFailTheOthers() async throws {
        let http = Self.stores(failing: ["api.audible.co.uk"])
        let found = try await AudibleStoresProvider(http: http, stores: [.uk, .us, .au]).search(query)
        #expect(http.urls.count == 3)
        // The United States store's order leads now; nothing is from the store that failed.
        #expect(found.map(\.id) == [
            "audible:us:B004WPQ4BI", "audible:us:B0D3MX4TFN", "audible:us:B074JD5VBZ",
            "audible:au:B0DM2L6NHL", "audible:au:B0FYQH7KNC",
        ])
        #expect(found.allSatisfy { !$0.edition.stores.contains("uk") })
    }

    @Test func N3_everyStoreFailingThrowsTheFirstStoresError() async throws {
        let http = FakeHTTP { url in
            switch url.host {
            case "api.audible.co.uk": return (Data(), 503)
            case "api.audible.com": throw LookupError.notReachable
            default: return (Data("[]".utf8), 200)
            }
        }
        // In asking order, whichever answered first.
        await #expect(throws: LookupError.refused(status: 503)) {
            _ = try await AudibleStoresProvider(http: http, stores: [.uk, .us, .au]).search(query)
        }
        await #expect(throws: LookupError.notReachable) {
            _ = try await AudibleStoresProvider(http: http, stores: [.us, .au, .uk]).search(query)
        }
        await #expect(throws: LookupError.unreadable) {
            _ = try await AudibleStoresProvider(http: http, stores: [.au, .us, .uk]).search(query)
        }
    }

    @Test func N3_aStoreThatFindsNothingIsNotAFailure() async throws {
        let http = FakeHTTP { url in
            if url.host == "api.audible.com" { return (fixture("au-none"), 200) }
            throw LookupError.notReachable
        }
        #expect(try await AudibleStoresProvider(http: http, stores: [.uk, .us]).search(query).isEmpty)
    }

    // MARK: N4, N6, N7: the trial's case

    /// The United States lacks the 2025 edition the United Kingdom and Australia have;
    /// all three have both BBC dramatisations.
    @Test func N4_N6_N7_theSameEditionInSeveralStoresIsOneResult() async throws {
        let found = try await AudibleStoresProvider(http: Self.stores(), stores: [.us, .uk, .au]).search(query)
        #expect(found.map(\.id) == [
            // N6: the user's own store's order…
            "audible:us:B004WPQ4BI", "audible:us:B0D3MX4TFN", "audible:us:B074JD5VBZ",
            // …then what only other stores have, in store order.
            "audible:uk:B0DM2NJ5SK", "audible:uk:B0FYQJC8PR",
        ])
        #expect(found.map(\.edition.stores) == [["us", "uk", "au"], ["us"], ["us", "uk", "au"], ["uk", "au"], ["uk", "au"]])
        #expect(found.allSatisfy { $0.source == .audible })
        // N7: the id and the ASIN are those of the store that is kept.
        #expect(found.map(\.metadata.asin) == ["B004WPQ4BI", "B0D3MX4TFN", "B074JD5VBZ", "B0DM2NJ5SK", "B0FYQJC8PR"])
        #expect(found.map(\.metadata.narrators.first) == ["Full Cast", "Shaun Evans", "Full Cast", "Rory Kinnear", "John le Carré"])
        let lengths: [Double?] = [14_220, 71_760, 10_200, 71_940, 61_020]
        #expect(found.map(\.metadata.durationSeconds) == lengths)
        #expect(found[3].edition == EditionFacts(format: .digital, abridged: false, publisher: "Penguin", year: 2025, stores: ["uk", "au"]))
    }

    @Test func N4_N6_N7_theUsersOwnStoreLeadsAndItsASINIsKept() async throws {
        let found = try await AudibleStoresProvider(http: Self.stores(), stores: [.uk, .us, .au]).search(query)
        #expect(found.map(\.id) == [
            "audible:uk:B0DM2NJ5SK", "audible:uk:B074JGKNXT", "audible:uk:B004WPPYP0", "audible:uk:B0FYQJC8PR",
            "audible:us:B0D3MX4TFN",
        ])
        #expect(found.map(\.edition.stores) == [["uk", "au"], ["uk", "us", "au"], ["uk", "us", "au"], ["uk", "au"], ["us"]])
        #expect(found.map(\.metadata.asin) == ["B0DM2NJ5SK", "B074JGKNXT", "B004WPPYP0", "B0FYQJC8PR", "B0D3MX4TFN"])

        // Australia first: its order, its ASINs.
        let australian = try await AudibleStoresProvider(http: Self.stores(), stores: [.au, .uk, .us]).search(query)
        #expect(australian.map(\.id) == [
            "audible:au:B0DM2L6NHL", "audible:au:B0FYQH7KNC", "audible:au:B00FG9D0FM", "audible:au:B074JC69ZD",
            "audible:us:B0D3MX4TFN",
        ])
        #expect(australian.map(\.edition.stores) == [["au", "uk"], ["au", "uk"], ["au", "uk", "us"], ["au", "uk", "us"], ["us"]])
    }

    @Test func N4_theMergedResultKeepsTheFirstStoresDetails() async throws {
        let first = try await AudibleProvider(http: Self.stores(), store: .uk, limit: 12).search(query)
        let merged = try await AudibleStoresProvider(http: Self.stores(), stores: [.uk, .us, .au]).search(query)
        for candidate in merged.prefix(4) {
            var alone = try #require(first.first { $0.id == candidate.id })
            alone.edition.stores = candidate.edition.stores
            #expect(alone == candidate)
        }
    }

    @Test func N4_theAnswerIsTheSameEveryTime() async throws {
        let provider = AudibleStoresProvider(http: Self.stores(), stores: [.us, .uk, .au])
        let first = try await provider.search(query)
        for _ in 0..<20 {
            #expect(try await provider.search(query) == first)
        }
    }

    // MARK: N4: what makes two results one edition

    private static func product(
        asin: String, title: String = "The Book", author: String? = "Ann Author", narrators: [String] = ["Rae Reader"],
        minutes: Int? = 600
    ) -> String {
        var fields = [#""asin": "\#(asin)""#, #""title": "\#(title)""#]
        if let author { fields.append(#""authors": [{"name": "\#(author)"}]"#) }
        fields.append(#""narrators": [\#(narrators.map { #"{"name": "\#($0)"}"# }.joined(separator: ","))]"#)
        if let minutes { fields.append(#""runtime_length_min": \#(minutes)"#) }
        return "{" + fields.joined(separator: ",") + "}"
    }

    /// The first store answers with `own`, the second with `other`.
    private func merged(_ own: [String], _ other: [String]) async throws -> [LookupCandidate] {
        let http = FakeHTTP { url in
            let products = url.host == "api.audible.co.uk" ? own : other
            return (Data(#"{"products": [\#(products.joined(separator: ","))]}"#.utf8), 200)
        }
        return try await AudibleStoresProvider(http: http, stores: [.uk, .us]).search(LookupQuery(title: "The Book"))
    }

    @Test func N4_sameTitleAuthorNarratorsAndLengthMerge() async throws {
        let found = try await merged(
            [Self.product(asin: "B00000000A", narrators: ["Rae Reader", "J. R. Voice"])],
            // Another ASIN, another spelling and order of the same people, a minute's difference.
            [Self.product(asin: "B00000000B", title: "the book", author: "ann author", narrators: ["JR Voice", "Reader, Rae"], minutes: 601)])
        #expect(found.map(\.id) == ["audible:uk:B00000000A"])
        #expect(found.first?.edition.stores == ["uk", "us"])
        #expect(found.first?.metadata.narrators == ["Rae Reader", "J. R. Voice"])
        #expect(found.first?.metadata.durationSeconds == 36_000)
    }

    @Test func N4_whatDiffersIsAnotherEdition() async throws {
        let own = Self.product(asin: "B00000000A")
        let others = [
            Self.product(asin: "B00000000B", title: "The Book Two"),
            Self.product(asin: "B00000000C", author: "Ben Writer"),
            Self.product(asin: "B00000000D", author: nil),
            Self.product(asin: "B00000000E", narrators: ["Sam Speaker"]),
            Self.product(asin: "B00000000F", narrators: ["Rae Reader", "Sam Speaker"]),
            Self.product(asin: "B00000000G", narrators: []),
            // More than a minute longer or shorter, or of no known length.
            Self.product(asin: "B00000000H", minutes: 602),
            Self.product(asin: "B00000000J", minutes: 598),
            Self.product(asin: "B00000000K", minutes: nil),
        ]
        let found = try await merged([own], others)
        #expect(found.count == 10)
        #expect(found.first?.edition.stores == ["uk"])
        #expect(found.dropFirst().allSatisfy { $0.edition.stores == ["us"] })
    }

    @Test func N4_nothingKnownOnEitherSideStillMatches() async throws {
        let found = try await merged(
            [Self.product(asin: "B00000000A", author: nil, narrators: [], minutes: nil)],
            [Self.product(asin: "B00000000B", author: nil, narrators: [], minutes: nil)])
        #expect(found.map(\.id) == ["audible:uk:B00000000A"])
        #expect(found.first?.edition.stores == ["uk", "us"])
    }

    /// Two look-alikes in one store stay two; another store's copy joins the first only.
    @Test func N4_oneStoresOwnResultsAreNeverMerged() async throws {
        let found = try await merged(
            [Self.product(asin: "B00000000A"), Self.product(asin: "B00000000B")],
            [Self.product(asin: "B00000000C"), Self.product(asin: "B00000000D"), Self.product(asin: "B00000000E")])
        #expect(found.map(\.id) == ["audible:uk:B00000000A", "audible:uk:B00000000B", "audible:us:B00000000E"])
        #expect(found.map(\.edition.stores) == [["uk", "us"], ["uk", "us"], ["us"]])
    }

    // MARK: N7

    @Test func N7_anASINLookupAsksEveryStoreForIt() async throws {
        let http = FakeHTTP { url in
            (fixture(url.host == "api.audible.co.uk" ? "au-asin" : "au-badasin"), 200)
        }
        let found = try await AudibleStoresProvider(http: http, stores: [.us, .uk]).search(LookupQuery(asin: "B08G9PRS1K"))
        #expect(found.count == 1)
        let candidate = try #require(found.first)
        #expect(candidate.id == "audible:uk:\(candidate.metadata.asin ?? "")")
        #expect(candidate.edition.stores == ["uk"])
        #expect(http.urls.allSatisfy { $0.path == "/1.0/catalog/products/B08G9PRS1K" })
    }
}

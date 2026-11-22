import Foundation
import Testing
@testable import VoxCarrelCore

/// The recorded answers are the US store's, trimmed to the fields that are read:
/// "Without Remorse" (B004FG2QGQ) and a search for it, the series "John Clark"
/// (B0764TX3PG) and "A Jack Ryan Novel (publication order)" (B06ZYRYZKG) with their
/// members' details in the batches they were asked in, and numbers 19 to 21 of
/// "A Jack Ryan Novel (chronological order)" (B005NASPF4), whose members' details are
/// gathered into one answer from the recorded ones that hold them.
@Suite struct AudibleSeriesProviderTests {
    static let clark = AudibleSeriesRef(id: "B0764TX3PG", title: "John Clark", number: nil, store: .us)
    static let ryan = AudibleSeriesRef(
        id: "B06ZYRYZKG", title: "A Jack Ryan Novel (publication order)", number: nil, store: .us)
    static let chrono = AudibleSeriesRef(
        id: "B005NASPF4", title: "A Jack Ryan Novel (chronological order)", number: nil, store: .us)

    static let clarkMembers = "B00IO1KSDG,B004FG2QGQ,B004I6ZR78,B00J54P7XM"
    static let ryanFirstBatch =
        "B004EBZ2GI,1405939931,B0DZDQG6BD,B0CN222WBQ,1405948965,B004FJA3TA,0593106792,B00I2WUYL8,B00I0G84HC,B00IT1831K,"
        + "B07DK2KCJD,B00IO1JD2S,B002V0KDY0,B00GM3L0DU,B0FXHDX89K,B00A9W1U58,B0FPZQ14QH,1405939958,B074HGCJZ8,B004ESTSSO,"
        + "B0D2JLJ4KV,1405943971,B004KAPD4Y,B004JOAIDM,B0D92PWVHV,B0BP877MF8,B011PVT3A0,B017JCMF2C,B004EBW0K4,B004AY444A,"
        + "B00I2WVC2S,B0DZL5B5ZX,B07D2HN6PP,B01N95XIVW,B0CGS1GWMT,B006FX933G,0593287371,B00PKJ2SVA,B00IEIB2UC,0593453255"
    static let ryanSecondBatch =
        "B09VMYFH24,B004XN6PVS,B0BH9D9C4G,B078XLLJBN,1405948957,B0BXK4QWDS,B00IPRK6YU,B00GWT4UAY,B01JKG9FMS"
    static let chronoMembers = "1405939958,0593106792,B07DK2KCJD,0593287371,1405948957,B07RC4LDGB"

    static let notFound = Data(#"{"error_code":"404","message":"Not Found"}"#.utf8)

    /// The US store as recorded: each address answered with what it was answered with,
    /// and 404 for anything that was never asked.
    static func recorded() -> FakeHTTP {
        FakeHTTP { url in
            let query = queryItems(url)
            switch url.path {
            case "/1.0/catalog/products/B004FG2QGQ": return (fixture("au-series-of-book"), 200)
            case "/1.0/catalog/products/B0764TX3PG": return (fixture("au-series-clark"), 200)
            case "/1.0/catalog/products/B06ZYRYZKG": return (fixture("au-series-ryan"), 200)
            case "/1.0/catalog/products/B005NASPF4": return (fixture("au-series-chrono"), 200)
            case "/1.0/catalog/products":
                switch query["asins"] {
                case clarkMembers: return (fixture("au-series-clark-members"), 200)
                case ryanFirstBatch: return (fixture("au-series-ryan-members-1"), 200)
                case ryanSecondBatch: return (fixture("au-series-ryan-members-2"), 200)
                case chronoMembers: return (fixture("au-series-chrono-members"), 200)
                case nil where query["title"] == "Without Remorse": return (fixture("au-series-search"), 200)
                default: return (notFound, 404)
                }
            default: return (notFound, 404)
            }
        }
    }

    static func json(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    static func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    /// A made-up series of `count` members numbered from 1, in reverse order, and a
    /// catalogue that knows every member asked for.
    static func madeUp(count: Int, series: String = "B0SERIES01") -> FakeHTTP {
        @Sendable func asin(_ index: Int) -> String { "B" + String(format: "%09d", index) }
        return FakeHTTP { url in
            if url.path == "/1.0/catalog/products/\(series)" {
                let members = (1...count).reversed().map {
                    ["asin": asin($0), "relationship_type": "series", "relationship_to_product": "child",
                     "sequence": String($0), "sort": String($0)]
                }
                return (json(["product": ["asin": series, "title": "Long", "relationships": members]]), 200)
            }
            let asked = (queryItems(url)["asins"] ?? "").split(separator: ",").map(String.init)
            return (json(["products": asked.map { ["asin": $0, "title": "Book \($0)"] }]), 200)
        }
    }

    // MARK: SC1

    @Test func SC1_theSeriesOfABookByItsASIN() async throws {
        let http = Self.recorded()
        let provider = AudibleSeriesProvider(http: http, store: .us)
        // Tidied as the lookup tidies an ASIN; the title and author are not sent.
        let found = try await provider.series(ofBookWithASIN: " b004fg2qgq ", title: "Without Remorse", author: "Tom Clancy")
        #expect(found == [AudibleSeriesRef(id: "B0764TX3PG", title: "John Clark", number: "1", store: .us)])
        #expect(http.urls.map(\.absoluteString) == [
            "https://api.audible.com/1.0/catalog/products/B004FG2QGQ?response_groups=series,product_desc",
        ])
        #expect(http.requests.first?.headers == LookupRequest.headers)
    }

    // Constructed: a book in several series, with entries that cannot be used.
    @Test func SC1_everySeriesIsGivenAndOneWithNoIDOrTitleIsDropped() async throws {
        let http = FakeHTTP(data: Self.json(["product": [
            "asin": "B000000001", "title": "A Book",
            "series": [
                ["asin": "B0SERIES01", "title": "The Universe"],
                ["asin": "b0series02", "title": "  The\tTrilogy ", "sequence": " 2.5 "],
                ["title": "No ID", "sequence": "1"],
                ["asin": "B0SERIES03", "sequence": "1"],
                ["asin": "B0SERIES04", "title": "   ", "sequence": "1"],
                ["asin": "../../x", "title": "Bad ID", "sequence": "1"],
                ["asin": "B0SERIES02", "title": "The Trilogy again", "sequence": "3"],
                "not an entry",
            ],
        ]]))
        let found = try await AudibleSeriesProvider(http: http, store: .uk)
            .series(ofBookWithASIN: "B000000001", title: "", author: nil)
        #expect(found == [
            AudibleSeriesRef(id: "B0SERIES01", title: "The Universe", number: nil, store: .uk),
            AudibleSeriesRef(id: "B0SERIES02", title: "The Trilogy", number: "2.5", store: .uk),
        ])
        #expect(http.urls.map(\.absoluteString) == [
            "https://api.audible.co.uk/1.0/catalog/products/B000000001?response_groups=series,product_desc",
        ])
    }

    // A book the store knows that is in no series, and one it does not know.
    @Test func SC1_aBookInNoSeries() async throws {
        for body in [
            Self.json(["product": ["asin": "B000000001", "title": "Alone"]]),
            Self.json(["product": ["asin": "B000000001", "title": "Alone", "series": []]]),
            fixture("au-badasin"),
        ] {
            let http = FakeHTTP(data: body)
            let found = try await AudibleSeriesProvider(http: http, store: .us)
                .series(ofBookWithASIN: "B000000001", title: "Alone", author: "Someone")
            #expect(found.isEmpty)
            // With an ASIN, the title is never searched for.
            #expect(http.urls.count == 1)
        }
    }

    // MARK: SC2

    @Test func SC2_withoutAnASINTheTitleAndAuthorAreSearchedFor() async throws {
        let http = Self.recorded()
        let provider = AudibleSeriesProvider(http: http, store: .us)
        let found = try await provider.series(ofBookWithASIN: nil, title: "Without Remorse", author: "Tom Clancy")
        // The first result with that title: not the abridged edition's series as well.
        #expect(found == [AudibleSeriesRef(id: "B0764TX3PG", title: "John Clark", number: "1", store: .us)])
        #expect(http.urls.count == 1)
        let url = try #require(http.urls.first)
        #expect(url.scheme == "https")
        #expect(url.host == "api.audible.com")
        #expect(url.path == "/1.0/catalog/products")
        #expect(queryItems(url) == [
            "title": "Without Remorse", "author": "Tom Clancy", "num_results": "10", "products_sort_by": "Relevance",
            "response_groups": "series,product_desc,contributors",
        ])
    }

    @Test func SC2_theTitleIsComparedAsTheLookupComparesTitles() async throws {
        let answer = Self.json(["products": [
            ["asin": "B000000001", "title": "Without Remorse: The Film", "series": [["asin": "B0SERIES01", "title": "Wrong"]]],
            ["asin": "B000000002", "title": "The WITHOUT  Remorse!", "series": [["asin": "B0SERIES02", "title": "Right", "sequence": "1"]]],
            ["asin": "B000000003", "title": "Without Remorse", "series": [["asin": "B0SERIES03", "title": "Later"]]],
        ]])
        let http = FakeHTTP(data: answer)
        let found = try await AudibleSeriesProvider(http: http, store: .us)
            .series(ofBookWithASIN: "", title: "  without remorse ", author: " ")
        #expect(found == [AudibleSeriesRef(id: "B0SERIES02", title: "Right", number: "1", store: .us)])
        // A blank author is not sent.
        #expect(queryItems(try #require(http.urls.first))["author"] == nil)
        #expect(queryItems(try #require(http.urls.first))["title"] == "without remorse")
    }

    @Test func SC2_noEqualTitleIsNothingAndNeverAGuess() async throws {
        let http = Self.recorded()
        let provider = AudibleSeriesProvider(http: http, store: .us)
        // The recorded search holds two books called "Without Remorse" and nothing else.
        let near = FakeHTTP(data: fixture("au-series-search"))
        for title in ["Without Remorse: A Novel", "Remorse", "Without"] {
            #expect(try await AudibleSeriesProvider(http: near, store: .us)
                .series(ofBookWithASIN: nil, title: title, author: "Tom Clancy").isEmpty)
        }
        #expect(near.urls.count == 3)
        // A result past the tenth is not looked at.
        var many: [[String: Any]] = (1...10).map { ["asin": "B00000000\($0 % 10)", "title": "Other \($0)"] }
        many.append(["asin": "B000000011", "title": "Wanted", "series": [["asin": "B0SERIES01", "title": "Eleventh"]]])
        #expect(try await AudibleSeriesProvider(http: FakeHTTP(data: Self.json(["products": many])), store: .us)
            .series(ofBookWithASIN: nil, title: "Wanted", author: nil).isEmpty)
        // No title, or none with a letter or digit in it: nothing is asked.
        for title in ["", "   ", "?!"] {
            #expect(try await provider.series(ofBookWithASIN: nil, title: title, author: "Tom Clancy").isEmpty)
        }
        #expect(http.urls.isEmpty)
    }

    // MARK: SC3

    @Test func SC3_theBooksOfASeries() async throws {
        let http = Self.recorded()
        var asked = Self.clark
        asked.number = "1"
        let list = try await AudibleSeriesProvider(http: http, store: .us).list(asked)
        #expect(http.urls.map(\.absoluteString) == [
            "https://api.audible.com/1.0/catalog/products/B0764TX3PG?response_groups=relationships,product_desc",
            "https://api.audible.com/1.0/catalog/products?asins=\(Self.clarkMembers)"
                + "&response_groups=product_desc,product_attrs,contributors,media",
        ])
        #expect(http.requests.allSatisfy { $0.headers == LookupRequest.headers })
        #expect(list.ref == Self.clark)
        // By Audible's ordering value, then number, then ASIN. The abridged series the
        // answer also names (B07651NXNZ, not a "series" relationship) is no member.
        #expect(list.editions == [
            AudibleSeriesEdition(
                asin: "B004FG2QGQ", title: "Without Remorse", number: "1", sort: 1, authors: ["Tom Clancy"],
                narrators: ["Michael Prichard"], minutes: 1627, isAbridged: false, releaseDate: Self.day(2011, 1, 20)),
            AudibleSeriesEdition(
                asin: "B00IO1KSDG", title: "Without Remorse", number: "1", sort: 1, authors: ["Tom Clancy"],
                narrators: ["Michael Prichard"], minutes: 1628, isAbridged: false, releaseDate: Self.day(2014, 3, 4)),
            AudibleSeriesEdition(
                asin: "B004I6ZR78", title: "Rainbow Six", number: "2", sort: 2, authors: ["Tom Clancy"],
                narrators: ["Michael Prichard"], minutes: 2155, isAbridged: false, releaseDate: Self.day(2011, 1, 7)),
            AudibleSeriesEdition(
                asin: "B00J54P7XM", title: "Rainbow Six", number: "2", sort: 2, authors: ["Tom Clancy"],
                narrators: ["Michael Prichard"], minutes: 2155, isAbridged: false, releaseDate: Self.day(2014, 3, 24)),
        ])
    }

    @Test func SC3_membersAreAskedForInBatchesOfForty() async throws {
        let http = Self.recorded()
        let list = try await AudibleSeriesProvider(http: http, store: .us).list(Self.ryan)
        #expect(http.urls.count == 3)
        #expect(http.urls.dropFirst().map { queryItems($0)["asins"] } == [Self.ryanFirstBatch, Self.ryanSecondBatch])
        #expect(http.urls.dropFirst().allSatisfy {
            queryItems($0)["response_groups"] == "product_desc,product_attrs,contributors,media"
        })
        #expect(list.ref == Self.ryan)
        #expect(list.editions.count == 49)
        #expect(Set(list.editions.map(\.asin)).count == 49)
        // Numbers 1 to 27, in order, each once or twice.
        var numbers: [String] = []
        for edition in list.editions where numbers.last != edition.number { numbers.append(edition.number ?? "?") }
        #expect(numbers == (1...27).map(String.init))
        #expect(list.editions.map(\.sort) == list.editions.map { Double($0.number ?? "") ?? -1 })
        // Within a number, by ASIN.
        #expect(list.editions.prefix(4).map(\.asin) == ["B078XLLJBN", "B07D2HN6PP", "B004KAPD4Y", "B00I0G84HC"])
        // Two editions of one number, read by different people.
        let first = list.editions.filter { $0.number == "1" }
        #expect(first.map(\.title) == ["The Hunt for Red October", "The Hunt for Red October"])
        #expect(first.map(\.narrators) == [["Lance C. Fuller"], ["Scott Brick"]])
        #expect(first.map(\.minutes) == [1039, 1122])
        // Two editions of one number under different titles.
        #expect(list.editions.filter { $0.number == "15" }.map(\.title) == [
            "Tom Clancy Commander-in-Chief", "Tom Clancy Commander in Chief: Jack Ryan, Book 11",
        ])
        #expect(list.editions.allSatisfy { $0.isAbridged == false && $0.releaseDate != nil && $0.minutes != nil })
    }

    // Constructed.
    @Test func SC3_onlyChildrenOfTheSeriesAreMembersAndTheirOrder() async throws {
        func relation(_ asin: Any, type: String = "series", to: String = "child", sequence: Any? = nil, sort: Any? = nil)
            -> [String: Any]
        {
            var relation: [String: Any] = ["asin": asin, "relationship_type": type, "relationship_to_product": to]
            relation["sequence"] = sequence
            relation["sort"] = sort
            return relation
        }
        let series = Self.json(["product": ["asin": "B0SERIES01", "title": " The  Real Name ", "relationships": [
            relation("B00000000C", sequence: "10", sort: "3"),
            relation("B00000000B", sequence: "2", sort: "3"),
            relation("B00000000A", sequence: "2", sort: 3),
            relation("B00000000D", sequence: "1-3", sort: "3"),
            relation("B00000000E", sort: "3"),
            relation("B00000000F", sequence: "9", sort: "1.5"),
            relation("B00000000G", sequence: "", sort: "0.5"),
            // No ordering value: placed by its number.
            relation("B00000000H", sequence: "2"),
            // Neither: last.
            relation("B00000000I"),
            relation("B00000000P", to: "parent", sequence: "1", sort: "1"),
            relation("B00000000Q", type: "season", sequence: "1", sort: "1"),
            relation("B00000000R", type: "merchant_title_authority", sort: "1"),
            relation("b00000000a", sequence: "7", sort: "7"),
            relation("../etc/passwd", sequence: "1", sort: "1"),
            relation(12, sequence: "1", sort: "1"),
            "not a relationship",
        ]]])
        let http = FakeHTTP { url in
            if url.path.hasSuffix("/B0SERIES01") { return (series, 200) }
            let asked = (queryItems(url)["asins"] ?? "").split(separator: ",").map(String.init)
            return (Self.json(["products": asked.reversed().map { ["asin": $0, "title": "Book \($0.suffix(1))"] }]), 200)
        }
        let list = try await AudibleSeriesProvider(http: http, store: .de)
            .list(AudibleSeriesRef(id: "b0series01", title: "Asked Name", number: "4", store: .us))
        // The catalogue's own name for the series, the store that was asked, no number.
        #expect(list.ref == AudibleSeriesRef(id: "B0SERIES01", title: "The Real Name", number: nil, store: .de))
        #expect(http.urls.count == 2)
        #expect(http.urls.allSatisfy { $0.host == "api.audible.de" })
        // Each member once, as first named, in the order the series names them.
        #expect(queryItems(http.urls[1])["asins"]
            == "B00000000C,B00000000B,B00000000A,B00000000D,B00000000E,B00000000F,B00000000G,B00000000H,B00000000I")
        #expect(list.editions.map(\.asin) == [
            "B00000000G", "B00000000F", "B00000000H", "B00000000A", "B00000000B", "B00000000C", "B00000000D",
            "B00000000E", "B00000000I",
        ])
        #expect(list.editions.map(\.number) == [nil, "9", "2", "2", "2", "10", "1-3", nil, nil])
        #expect(list.editions.map(\.sort).prefix(8) == [0.5, 1.5, 2, 3, 3, 3, 3, 3])
        #expect(list.editions.map(\.title).first == "Book G")
    }

    // MARK: SC4

    @Test func SC4_aMemberWithoutDetailsIsLeftOut() async throws {
        // The recorded answer, less one member, and with a book nobody asked for.
        var answer = try #require(try JSONSerialization.jsonObject(with: fixture("au-series-clark-members")) as? [String: Any])
        var products = try #require(answer["products"] as? [[String: Any]])
        products.removeAll { $0["asin"] as? String == "B004I6ZR78" }
        products.append(["asin": "B0UNASKED1", "title": "Not Asked For"])
        products.append(["asin": "B00J54P7XM", "title": "Named Twice"])
        // Details with no title are no details.
        products[0]["title"] = nil
        answer["products"] = products
        let members = Self.json(answer)
        let http = FakeHTTP { url in
            url.path.hasSuffix("/B0764TX3PG") ? (fixture("au-series-clark"), 200) : (members, 200)
        }
        let list = try await AudibleSeriesProvider(http: http, store: .us).list(Self.clark)
        #expect(list.editions.map(\.asin) == ["B004FG2QGQ", "B00J54P7XM"])
        #expect(list.editions.map(\.title) == ["Without Remorse", "Rainbow Six"])
    }

    // Constructed.
    @Test func SC4_aSeriesIsCutAtFourHundredMembers() async throws {
        let http = Self.madeUp(count: 450)
        let list = try await AudibleSeriesProvider(http: http, store: .us)
            .list(AudibleSeriesRef(id: "B0SERIES01", title: "Long", number: nil, store: .us))
        // The first four hundred of the series, not the first four hundred named.
        #expect(list.editions.count == 400)
        #expect(list.editions.map(\.number) == (1...400).map(String.init))
        #expect(http.urls.count == 11)
        let batches = http.urls.dropFirst().map { (queryItems($0)["asins"] ?? "").split(separator: ",").count }
        #expect(batches == Array(repeating: 40, count: 10))
    }

    @Test func SC4_aSeriesWithNoMembersAsksForNoDetails() async throws {
        let http = FakeHTTP(data: Self.json(["product": ["asin": "B0SERIES01", "title": "Empty", "relationships": []]]))
        let ref = AudibleSeriesRef(id: "B0SERIES01", title: "Empty", number: nil, store: .us)
        #expect(try await AudibleSeriesProvider(http: http, store: .us).list(ref) == AudibleSeriesList(ref: ref, editions: []))
        #expect(http.urls.count == 1)
    }

    // MARK: SC5

    // The entry Audible holds a place with: dated 2200, no length, nobody reading.
    @Test func SC5_aPlaceholderEdition() async throws {
        let list = try await AudibleSeriesProvider(http: Self.recorded(), store: .us).list(Self.chrono)
        #expect(list.editions.map(\.asin) == [
            "1405939958", "B07DK2KCJD", "0593106792", "B07RC4LDGB", "0593287371", "1405948957",
        ])
        #expect(list.editions.map(\.number) == ["19", "19", "20", "20", "21", "21"])
        #expect(list.editions[3] == AudibleSeriesEdition(
            asin: "B07RC4LDGB", title: "Tom Clancy Code of Honor", number: "20", sort: 20, authors: ["Marc Cameron"],
            narrators: [], minutes: nil, isAbridged: false, releaseDate: Self.day(2200, 1, 1)))
        #expect(list.editions[2] == AudibleSeriesEdition(
            asin: "0593106792", title: "Tom Clancy Code of Honor", number: "20", sort: 20, authors: ["Marc Cameron"],
            narrators: ["Scott Brick"], minutes: 819, isAbridged: false, releaseDate: Self.day(2019, 11, 19)))
    }

    // Constructed.
    @Test func SC5_whatTheCatalogueSendsIsCleanedAndLimited() async throws {
        let long = String(repeating: "x", count: 2000)
        let details: [[String: Any]] = [
            ["asin": "B000000001", "title": " A\u{202E}\tTitle\u{0007}\n here ", "format_type": "abridged",
             "runtime_length_min": 0, "release_date": "2019-11-19",
             "authors": [["name": " Ann\u{200F} Author "], ["name": "  "], ["nom": "x"], "x", ["name": long]],
             "narrators": [["name": "Ned\nNarrator"]]],
            ["asin": "B000000002", "title": long, "format_type": "Unabridged", "runtime_length_min": 1_000_001,
             "release_date": "soon", "issue_date": "2001-02-03"],
            ["asin": "B000000003", "title": "Three", "format_type": "original_recording", "runtime_length_min": "600",
             "release_date": "2019-13-45"],
            ["asin": "B000000004", "title": "Four", "runtime_length_min": 1_000_000, "release_date": "2019-02-30"],
            ["asin": "B000000005", "title": "Five", "runtime_length_min": 1, "release_date": "20191119"],
            ["asin": "B000000006", "title": "Six", "runtime_length_min": -5, "release_date": 2019],
            ["asin": "B000000007", "title": "Seven", "runtime_length_min": 61.5, "release_date": "2019-11-19T10:00:00Z"],
            ["asin": "B000000008", "title": "Eight", "release_date": "0000-01-01"],
        ]
        let relations: [[String: Any]] = (1...8).map {
            ["asin": "B00000000\($0)", "relationship_type": "series", "relationship_to_product": "child",
             "sequence": $0 == 1 ? " 1\u{202E}\t.5 " : $0 == 2 ? long : "\($0)", "sort": "\($0)"]
        }
        let http = FakeHTTP { url in
            url.path.hasSuffix("/B0SERIES01")
                ? (Self.json(["product": ["asin": "B0SERIES01", "title": long, "relationships": relations]]), 200)
                : (Self.json(["products": details]), 200)
        }
        let list = try await AudibleSeriesProvider(http: http, store: .us)
            .list(AudibleSeriesRef(id: "B0SERIES01", title: "Asked", number: nil, store: .us))
        #expect(list.ref.title == String(repeating: "x", count: LookupText.nameLimit))
        let editions = list.editions
        #expect(editions.count == 8)
        #expect(editions[0] == AudibleSeriesEdition(
            asin: "B000000001", title: "A Title here", number: "1 .5", sort: 1,
            authors: ["Ann Author", String(repeating: "x", count: LookupText.nameLimit)], narrators: ["Ned Narrator"],
            minutes: nil, isAbridged: true, releaseDate: Self.day(2019, 11, 19)))
        #expect(editions[1].title == String(repeating: "x", count: LookupText.nameLimit))
        #expect(editions[1].number == String(repeating: "x", count: LookupText.lineLimit))
        #expect(editions[1].authors.isEmpty)
        #expect(editions.map(\.minutes) == [nil, nil, nil, 1_000_000, 1, nil, nil, nil])
        #expect(editions.map(\.isAbridged) == [true, false, nil, nil, nil, nil, nil, nil])
        // A release date that cannot be read falls back on the issue date, as the lookup's year does.
        #expect(editions.map(\.releaseDate) == [
            Self.day(2019, 11, 19), Self.day(2001, 2, 3), nil, nil, nil, nil, nil, nil,
        ])
    }

    // MARK: SC6

    @Test func SC6_requestsAreMadeAsEveryLookupRequestIs() async throws {
        let http = Self.recorded()
        let provider = AudibleSeriesProvider(http: http, store: .us)
        _ = try await provider.series(ofBookWithASIN: "B004FG2QGQ", title: "", author: nil)
        _ = try await provider.series(ofBookWithASIN: nil, title: "Without Remorse", author: "Tom Clancy")
        _ = try await provider.list(Self.ryan)
        #expect(http.urls.count == 5)
        #expect(http.urls.allSatisfy { $0.scheme == "https" && $0.host == "api.audible.com" })
        #expect(http.requests.allSatisfy { $0.headers == LookupRequest.headers })
        #expect(http.limits.allSatisfy {
            $0 == FakeHTTP.Limits(maxBytes: LookupRequest.jsonByteLimit, redirectHosts: ["api.audible.com"], insecure: [])
        })
    }

    @Test func SC6_anIDThatIsNotAnASINReachesNoRequest() async throws {
        let http = FakeHTTP(data: fixture("au-series-search"))
        let provider = AudibleSeriesProvider(http: http, store: .us)
        let bad = ["B08G9PRS1", "B08G9PRS1K1", "B08G9/RS1K", "../../etc/x", "B08G9PRS1é", "B08G9 RS1K", "", "   "]
        // A series: refused, and nothing is asked.
        for id in bad {
            await #expect(throws: LookupError.unreadable) {
                _ = try await provider.list(AudibleSeriesRef(id: id, title: "Series", number: nil, store: .us))
            }
        }
        #expect(http.urls.isEmpty)
        // A book: the ID is not sent; the book is one without an ASIN, searched for by title.
        for id in bad {
            let found = try await provider.series(ofBookWithASIN: id, title: "Without Remorse", author: "Tom Clancy")
            #expect(found.map(\.id) == ["B0764TX3PG"])
        }
        #expect(http.urls.count == bad.count)
        #expect(http.urls.allSatisfy { $0.path == "/1.0/catalog/products" && queryItems($0)["asins"] == nil })
        // And with no title either, nothing is asked.
        #expect(try await provider.series(ofBookWithASIN: "../../etc/x", title: "", author: "Tom Clancy").isEmpty)
        #expect(http.urls.count == bad.count)
    }

    // MARK: SC7

    @Test func SC7_notFoundIsNothingFoundAndNotAnError() async throws {
        let http = FakeHTTP(data: Self.notFound, status: 404)
        let provider = AudibleSeriesProvider(http: http, store: .us)
        #expect(try await provider.series(ofBookWithASIN: "B004FG2QGQ", title: "Without Remorse", author: nil).isEmpty)
        #expect(try await provider.series(ofBookWithASIN: nil, title: "Without Remorse", author: nil).isEmpty)
        #expect(try await provider.list(Self.clark) == AudibleSeriesList(ref: Self.clark, editions: []))
        #expect(http.urls.count == 3)
        // A product that is not a series, or one the store answers for without knowing it.
        for body in [fixture("au-badasin"), fixture("au-series-of-book")] {
            let other = FakeHTTP(data: body)
            #expect(try await AudibleSeriesProvider(http: other, store: .us).list(Self.clark)
                == AudibleSeriesList(ref: Self.clark, editions: []))
            #expect(other.urls.count == 1)
        }
    }

    @Test func SC7_errorsAreTheLookupsOwn() async throws {
        func all(_ http: FakeHTTP, throw expected: LookupError) async {
            let provider = AudibleSeriesProvider(http: http, store: .us)
            await #expect(throws: expected) {
                _ = try await provider.series(ofBookWithASIN: "B004FG2QGQ", title: "", author: nil)
            }
            await #expect(throws: expected) {
                _ = try await provider.series(ofBookWithASIN: nil, title: "Without Remorse", author: nil)
            }
            await #expect(throws: expected) { _ = try await provider.list(Self.clark) }
        }
        await all(FakeHTTP(data: Data("{}".utf8), status: 500), throw: .refused(status: 500))
        await all(FakeHTTP(data: Data("{}".utf8), status: 429), throw: .refused(status: 429))
        await all(FakeHTTP(data: Data("<html>".utf8)), throw: .unreadable)
        await all(FakeHTTP(data: Data("[]".utf8)), throw: .unreadable)
        await all(FakeHTTP(data: Data("{}".utf8)), throw: .unreadable)
        await all(FakeHTTP(throwing: LookupError.notReachable), throw: .notReachable)

        // The members' details failing fails the list: half a series is not a series.
        for (status, expected) in [(404, LookupError.refused(status: 404)), (503, .refused(status: 503))] {
            let http = FakeHTTP { url in
                url.path.hasSuffix("/B0764TX3PG") ? (fixture("au-series-clark"), 200) : (Self.notFound, status)
            }
            await #expect(throws: expected) { _ = try await AudibleSeriesProvider(http: http, store: .us).list(Self.clark) }
        }
        let unreadable = FakeHTTP { url in
            url.path.hasSuffix("/B0764TX3PG") ? (fixture("au-series-clark"), 200) : (Data(#"{"products":7}"#.utf8), 200)
        }
        await #expect(throws: LookupError.unreadable) {
            _ = try await AudibleSeriesProvider(http: unreadable, store: .us).list(Self.clark)
        }
    }

    // MARK: SC8

    static func service(_ sources: Set<LookupSource>, _ stores: [AudibleStore], http: FakeHTTP) -> LookupService {
        LookupService.standard(LookupConfiguration(sources: sources, audibleStores: stores), http: http)
    }

    @Test func SC8_nothingIsSentWhenAudibleIsOff() async throws {
        let http = Self.recorded()
        for service in [
            Self.service([.openLibrary, .libraryOfCongress], [.us, .uk], http: http),
            Self.service([], [.us], http: http),
            // Audible with no store to ask is off.
            Self.service([.audible], [], http: http),
            // A service put together by hand is told its stores, or has none.
            LookupService(providers: [], http: http),
        ] {
            #expect(try await service.audibleSeries(ofBookWithASIN: "B004FG2QGQ", title: "Without Remorse", author: "Tom Clancy").isEmpty)
            #expect(try await service.audibleSeriesList(Self.clark) == AudibleSeriesList(ref: Self.clark, editions: []))
        }
        #expect(http.urls.isEmpty)
    }

    @Test func SC8_storesAreAskedInOrderUntilOneKnowsASeries() async throws {
        // The UK store does not know the book; the US store is as recorded.
        let recorded = Self.recorded()
        let http = FakeHTTP { url in
            url.host == "api.audible.com" ? try recorded.answerForTest(url) : (fixture("au-badasin"), 200)
        }
        let found = try await Self.service([.audible], [.uk, .us, .au, .us], http: http)
            .audibleSeries(ofBookWithASIN: "B004FG2QGQ", title: "Without Remorse", author: "Tom Clancy")
        #expect(found == [AudibleSeriesRef(id: "B0764TX3PG", title: "John Clark", number: "1", store: .us)])
        // The Australian store is not asked: the US store answered.
        #expect(http.urls.map(\.host) == ["api.audible.co.uk", "api.audible.com"])

        // The owner's own store first, and no further when it answers.
        let first = Self.recorded()
        _ = try await Self.service([.audible, .openLibrary], [.us, .uk], http: first)
            .audibleSeries(ofBookWithASIN: nil, title: "Without Remorse", author: "Tom Clancy")
        #expect(first.urls.map(\.host) == ["api.audible.com"])

        // No store knows one: every store is asked, and the answer is empty.
        let none = FakeHTTP(data: fixture("au-badasin"))
        #expect(try await Self.service([.audible], [.uk, .us, .au], http: none)
            .audibleSeries(ofBookWithASIN: "B004FG2QGQ", title: "", author: nil).isEmpty)
        #expect(none.urls.map(\.host) == ["api.audible.co.uk", "api.audible.com", "api.audible.com.au"])
    }

    @Test func SC8_aStoreThatFailsIsSkippedUnlessAllFail() async throws {
        let recorded = Self.recorded()
        func http(_ answers: [String: Int]) -> FakeHTTP {
            FakeHTTP { url in
                switch answers[url.host ?? ""] {
                case 200: return try recorded.answerForTest(url)
                case 0: throw LookupError.notReachable
                case 204: return (fixture("au-badasin"), 200)
                case let status?: return (Data("{}".utf8), status)
                case nil: throw LookupError.unreadable
                }
            }
        }
        func ask(_ http: FakeHTTP) async throws -> [AudibleSeriesRef] {
            try await Self.service([.audible], [.uk, .us, .au], http: http)
                .audibleSeries(ofBookWithASIN: "B004FG2QGQ", title: "Without Remorse", author: "Tom Clancy")
        }
        // The first fails, the second answers.
        let skipped = http(["api.audible.co.uk": 503, "api.audible.com": 200, "api.audible.com.au": 500])
        #expect(try await ask(skipped).map(\.id) == ["B0764TX3PG"])
        #expect(skipped.urls.count == 2)
        // Some fail and the rest know nothing: nothing found, not an error.
        let partly = http(["api.audible.co.uk": 503, "api.audible.com": 204, "api.audible.com.au": 0])
        #expect(try await ask(partly).isEmpty)
        #expect(partly.urls.count == 3)
        // All fail: the last error.
        let all = http(["api.audible.co.uk": 503, "api.audible.com": 0, "api.audible.com.au": 500])
        await #expect(throws: LookupError.refused(status: 500)) { _ = try await ask(all) }
        #expect(all.urls.count == 3)
        let unreachable = http(["api.audible.co.uk": 503, "api.audible.com": 500, "api.audible.com.au": 0])
        await #expect(throws: LookupError.notReachable) { _ = try await ask(unreachable) }
    }

    @Test func SC8_aSeriesListIsAskedOfItsOwnStore() async throws {
        let recorded = Self.recorded()
        let http = FakeHTTP { try recorded.answerForTest($0) }
        let service = Self.service([.audible], [.uk, .us], http: http)
        let list = try await service.audibleSeriesList(Self.clark)
        #expect(list.ref == Self.clark)
        #expect(list.editions.map(\.asin) == ["B004FG2QGQ", "B00IO1KSDG", "B004I6ZR78", "B00J54P7XM"])
        #expect(http.urls.count == 2)
        #expect(http.urls.allSatisfy { $0.host == "api.audible.com" })
        // Its failure is thrown as it is.
        let failing = FakeHTTP(data: Data("{}".utf8), status: 503)
        await #expect(throws: LookupError.refused(status: 503)) {
            _ = try await Self.service([.audible], [.us], http: failing).audibleSeriesList(Self.clark)
        }
        // A store that is not switched on is not asked.
        var german = Self.clark
        german.store = .de
        #expect(try await service.audibleSeriesList(german) == AudibleSeriesList(ref: german, editions: []))
        #expect(http.urls.count == 2)
    }
}

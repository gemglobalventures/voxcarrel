import Foundation

/// One book of a series, as Wikidata has it.
public struct WikidataSeriesBook: Equatable, Sendable {
    /// Wikidata's own id for the book, as in "Q6535598".
    public var id: String
    public var title: String
    /// Its place in the series as Wikidata writes it: "1", "4.5"; nil when it gives none.
    public var number: String?
    public var authors: [String]

    public init(id: String, title: String, number: String?, authors: [String]) {
        self.id = id
        self.title = title
        self.number = number
        self.authors = authors
    }
}

/// A series as Wikidata has it, with its books in order.
public struct WikidataSeries: Equatable, Sendable {
    /// Wikidata's own id for the series.
    public var id: String
    public var title: String
    /// What Wikidata says the series is, in a few words; nil when it says nothing.
    public var about: String?
    /// In the order of their numbers; those with none come last, by title.
    public var books: [WikidataSeriesBook]

    public init(id: String, title: String, about: String?, books: [WikidataSeriesBook]) {
        self.id = id
        self.title = title
        self.about = about
        self.books = books
    }

    /// The series' page at Wikidata.
    public var page: URL? { URL(string: "https://www.wikidata.org/wiki/" + id) }
}

/// Asks Wikidata what books a series holds, and in what order. Wikidata is open data,
/// asked without an account: first for the things that go by a name, then, in one
/// question, for the books each of them holds.
///
/// A book is in a series when it says so (`part of the series`) or the series says so
/// (`has part`): both are asked, since Wikidata's records are kept either way. Only
/// what has a written author is taken for a book, which leaves out the television
/// series and games that share a name with one.
public struct WikidataSeriesProvider: Sendable {
    static let searchHost = "www.wikidata.org"
    static let queryHost = "query.wikidata.org"
    /// The most things by one name that are looked into.
    static let mostCandidates = 12
    /// The most rows one answer is asked for.
    static let mostRows = 1_500

    private let http: any HTTPFetching

    public init(http: any HTTPFetching) {
        self.http = http
    }

    /// The series that go by `name`, with their books. Those with a book by `author`
    /// come first, then those with the most books. Empty when Wikidata has none.
    public func series(named name: String, author: String? = nil) async throws -> [WikidataSeries] {
        let found = try await things(named: name)
        return Self.ranked(try await series(amongThings: found), author: author)
    }

    /// The series the book called `title` is part of, with their books.
    public func series(ofBookTitled title: String, author: String? = nil) async throws -> [WikidataSeries] {
        let books = try await things(named: title)
        guard !books.isEmpty else { return [] }
        let values = books.map { "wd:\($0.id)" }.joined(separator: " ")
        let rows = try await ask("""
            SELECT DISTINCT ?s ?sLabel ?sDescription WHERE {
              VALUES ?book { \(values) }
              { ?book wdt:P179 ?s } UNION { ?s wdt:P527 ?book . ?book wdt:P50 ?anyAuthor }
              SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
            } LIMIT 40
            """)
        var seen = Set<String>()
        let found = rows.compactMap { row -> Thing? in
            guard let id = Self.id(row["s"]), seen.insert(id).inserted else { return nil }
            return Thing(id: id, label: row["sLabel"] ?? id, about: row["sDescription"])
        }
        return Self.ranked(try await series(amongThings: found), author: author)
    }

    // MARK: Asking

    struct Thing: Equatable {
        var id: String
        var label: String
        var about: String?
    }

    /// The things Wikidata knows by a name: books, series, and much else.
    func things(named name: String) async throws -> [Thing] {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return [] }
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = Self.searchHost
        parts.path = "/w/api.php"
        parts.queryItems = [
            URLQueryItem(name: "action", value: "wbsearchentities"), URLQueryItem(name: "search", value: name),
            URLQueryItem(name: "language", value: "en"), URLQueryItem(name: "uselang", value: "en"),
            URLQueryItem(name: "type", value: "item"), URLQueryItem(name: "limit", value: String(Self.mostCandidates)),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let url = parts.url else { throw LookupError.unreadable }
        let answer = try await http.get(url, headers: LookupRequest.headers, maxBytes: 1_000_000, redirectHosts: [])
        guard answer.status == 200 else { throw LookupError.refused(status: answer.status) }
        guard let object = try? JSONSerialization.jsonObject(with: answer.data) as? [String: Any],
              let list = object["search"] as? [[String: Any]]
        else { throw LookupError.unreadable }
        return list.compactMap { item in
            guard let id = item["id"] as? String, Self.isId(id) else { return nil }
            return Thing(id: id, label: (item["label"] as? String) ?? id, about: item["description"] as? String)
        }
    }

    /// Of these things, those that are series of books, each with its books.
    func series(amongThings things: [Thing]) async throws -> [WikidataSeries] {
        guard !things.isEmpty else { return [] }
        let values = things.map { "wd:\($0.id)" }.joined(separator: " ")
        let rows = try await ask("""
            SELECT ?s ?book ?bookLabel ?ordinal ?authorLabel WHERE {
              VALUES ?s { \(values) }
              { ?book p:P179 ?st . ?st ps:P179 ?s . OPTIONAL { ?st pq:P1545 ?ordinal } }
              UNION
              { ?s p:P527 ?st2 . ?st2 ps:P527 ?book . OPTIONAL { ?st2 pq:P1545 ?ordinal } }
              OPTIONAL { ?book wdt:P50 ?author }
              SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
            } LIMIT \(Self.mostRows)
            """)
        return Self.series(from: rows, things: things)
    }

    /// One question put to Wikidata's query service; its answer as rows of name and value.
    func ask(_ query: String) async throws -> [[String: String]] {
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = Self.queryHost
        parts.path = "/sparql"
        parts.queryItems = [URLQueryItem(name: "query", value: query), URLQueryItem(name: "format", value: "json")]
        guard let url = parts.url else { throw LookupError.unreadable }
        let answer = try await http.get(
            url, headers: ["User-Agent": LookupRequest.userAgent, "Accept": "application/sparql-results+json"], maxBytes: 4_000_000, redirectHosts: [])
        guard answer.status == 200 else { throw LookupError.refused(status: answer.status) }
        guard let object = try? JSONSerialization.jsonObject(with: answer.data) as? [String: Any],
              let results = object["results"] as? [String: Any], let bindings = results["bindings"] as? [[String: Any]]
        else { throw LookupError.unreadable }
        return bindings.map { binding in
            binding.compactMapValues { ($0 as? [String: Any])?["value"] as? String }
        }
    }

    // MARK: Reading the answer

    /// "Q42" from "http://www.wikidata.org/entity/Q42"; nil for anything else.
    static func id(_ address: String?) -> String? {
        guard let last = address?.split(separator: "/").last.map(String.init), isId(last) else { return nil }
        return last
    }

    public static func isId(_ text: String) -> Bool {
        text.count > 1 && text.count < 14 && text.first == "Q" && text.dropFirst().allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// The rows of the books question as series, in the order the things were given.
    static func series(from rows: [[String: String]], things: [Thing]) -> [WikidataSeries] {
        struct Found {
            var title: String
            var number: String?
            var authors: [String] = []
        }
        var books: [String: [String: Found]] = [:]
        var order: [String: [String]] = [:]
        for row in rows {
            guard let series = id(row["s"]), let book = id(row["book"]) else { continue }
            let label = row["bookLabel"] ?? book
            // A book with no name in English comes back named by its id: it is left out.
            guard !isId(label) else { continue }
            if books[series]?[book] == nil {
                books[series, default: [:]][book] = Found(title: label)
                order[series, default: []].append(book)
            }
            if let number = row["ordinal"]?.trimmingCharacters(in: .whitespaces), !number.isEmpty,
               books[series]![book]!.number == nil {
                books[series]![book]!.number = number
            }
            if let author = row["authorLabel"], !isId(author), !books[series]![book]!.authors.contains(author) {
                books[series]![book]!.authors.append(author)
            }
        }
        return things.compactMap { thing in
            guard let found = books[thing.id], let ids = order[thing.id] else { return nil }
            // Something written has an author: a season of television has none.
            guard found.values.contains(where: { !$0.authors.isEmpty }), found.count >= 2 else { return nil }
            let list = ids.map { WikidataSeriesBook(id: $0, title: found[$0]!.title, number: found[$0]!.number, authors: found[$0]!.authors) }
            return WikidataSeries(id: thing.id, title: thing.label, about: thing.about, books: inOrder(list))
        }
    }

    static func inOrder(_ books: [WikidataSeriesBook]) -> [WikidataSeriesBook] {
        func place(_ book: WikidataSeriesBook) -> Double { book.number.flatMap(Double.init) ?? .greatestFiniteMagnitude }
        return books.sorted { (place($0), $0.title) < (place($1), $1.title) }
    }

    /// Those with a book by `author` first, then those with the most books.
    static func ranked(_ series: [WikidataSeries], author: String?) -> [WikidataSeries] {
        let wanted = author.map(key) ?? ""
        func isBy(_ one: WikidataSeries) -> Bool {
            !wanted.isEmpty && one.books.contains { $0.authors.contains { key($0) == wanted } }
        }
        return series.enumerated().sorted { a, b in
            let (first, second) = (isBy(a.element), isBy(b.element))
            if first != second { return first }
            if a.element.books.count != b.element.books.count { return a.element.books.count > b.element.books.count }
            return a.offset < b.offset
        }.map(\.element)
    }

    public static func key(_ name: String) -> String {
        name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }
}

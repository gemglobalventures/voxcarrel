import Foundation
import VoxCarrelCore

@testable import VoxCarrelAppCore

/// Stands in for the Audible stores' catalogues when a series is asked about: it answers
/// the requests the real series provider makes, from the series a test gives it, and
/// remembers every request. No test reaches the network.
final class FakeCatalogue: @unchecked Sendable {
    /// Where every catalogue request goes.
    static let path = "/1.0/catalog/"

    struct Member {
        var asin: String
        var title: String
        var number: String?
        var authors: [String] = ["Ines Calloway"]
        var narrators: [String] = ["Marcus Lindqvist"]
        var minutes: Int? = 600
        var abridged = false
        var released = "2020-01-01"
    }

    struct Series {
        var id: String
        var title: String
        var members: [Member]
    }

    private let lock = NSLock()
    private var stores: [AudibleStore: [Series]] = [:]
    private var failure: LookupError?
    private var recorded: [URL] = []
    private var gate: Gate?

    /// Every request made, in order.
    var requests: [URL] { lock.withLock { recorded } }

    /// The requests that asked which series a book is in: by its ID, or by a search.
    var bookRequests: [URL] { requests.filter { !$0.isAboutSeries } }

    /// The requests that asked for a series' books, or for the details of some.
    var listRequests: [URL] { requests.filter(\.isAboutSeries) }

    /// The store lists these series, and no others.
    func set(_ series: [Series], in store: AudibleStore = .us) {
        lock.withLock { stores[store] = series }
    }

    private var wikidata: (search: String, books: String)?

    /// What Wikidata answers: to a search by name, and to the question of which books
    /// the things found hold. Nil for a Wikidata that knows nothing by any name.
    func setWikidata(search: String, books: String) {
        lock.withLock { wikidata = (search, books) }
    }

    /// The requests made of Wikidata.
    var wikidataRequests: [URL] { requests.filter { $0.host?.hasSuffix("wikidata.org") == true } }

    /// Every request fails this way; nil for none to.
    func fail(_ error: LookupError?) {
        lock.withLock { failure = error }
    }

    /// No request is answered until `gate` is released.
    func hold(at gate: Gate) {
        lock.withLock { self.gate = gate }
    }

    func answer(_ url: URL) async throws -> (data: Data, status: Int) {
        let (gate, failure) = lock.withLock {
            recorded.append(url)
            return (self.gate, self.failure)
        }
        await gate?.wait()
        if let failure { throw failure }
        if url.host?.hasSuffix("wikidata.org") == true {
            let known = lock.withLock { wikidata }
            guard let known else { return (Data("{\"search\":[]}".utf8), 200) }
            return (Data((url.host == "www.wikidata.org" ? known.search : known.books).utf8), 200)
        }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value }
        let series = lock.withLock { stores.first { $0.key.host == url.host }?.value ?? [] }
        let object = Self.object(path: url.path, query: query, series: series)
        guard let object else { return (Data("{}".utf8), 404) }
        return (try JSONSerialization.data(withJSONObject: object), 200)
    }

    private static func object(path: String, query: [String: String], series: [Series]) -> [String: Any]? {
        let groups = query["response_groups"] ?? ""
        let last = path.split(separator: "/").last.map(String.init) ?? ""
        if last != "products" {
            if groups.contains("relationships") {
                guard let wanted = series.first(where: { $0.id == last }) else { return nil }
                let relations: [[String: Any]] = wanted.members.enumerated().map { index, member in
                    var relation: [String: Any] = [
                        "relationship_type": "series", "relationship_to_product": "child", "asin": member.asin,
                        "sort": String(index + 1),
                    ]
                    relation["sequence"] = member.number
                    return relation
                }
                return ["product": ["asin": wanted.id, "title": wanted.title, "relationships": relations]]
            }
            return book(asin: last, in: series).map { ["product": $0] }
        }
        if let asins = query["asins"] {
            let members = series.flatMap(\.members)
            let products: [[String: Any]] = asins.split(separator: ",").compactMap { asin in
                guard let member = members.first(where: { $0.asin == asin }) else { return nil }
                var product: [String: Any] = [
                    "asin": member.asin, "title": member.title,
                    "authors": member.authors.map { ["name": $0] }, "narrators": member.narrators.map { ["name": $0] },
                    "format_type": member.abridged ? "abridged" : "unabridged", "release_date": member.released,
                ]
                product["runtime_length_min"] = member.minutes
                return product
            }
            return ["products": products]
        }
        let title = (query["title"] ?? "").lowercased()
        let found = series.flatMap(\.members).first { $0.title.lowercased() == title }
        return ["products": found.flatMap { book(asin: $0.asin, in: series) }.map { [$0] } ?? []]
    }

    /// The book as the catalogue describes it, with every series it is in.
    private static func book(asin: String, in series: [Series]) -> [String: Any]? {
        var title: String?
        var memberships: [[String: Any]] = []
        for one in series {
            guard let member = one.members.first(where: { $0.asin == asin }) else { continue }
            title = title ?? member.title
            var membership: [String: Any] = ["asin": one.id, "title": one.title]
            membership["sequence"] = member.number
            memberships.append(membership)
        }
        guard let title else { return nil }
        return ["asin": asin, "title": title, "series": memberships]
    }
}

extension URL {
    /// Whether a catalogue request asks for a series' books or their details, not for
    /// the series of a book.
    fileprivate var isAboutSeries: Bool {
        let text = absoluteString
        return text.contains("relationships") || text.contains("asins=")
    }
}

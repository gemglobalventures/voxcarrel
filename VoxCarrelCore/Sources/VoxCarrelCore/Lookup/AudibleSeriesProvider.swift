import Foundation

/// A series in one Audible store's catalogue. A series is a catalogue entry of its own.
public struct AudibleSeriesRef: Hashable, Sendable {
    /// The series' own Audible ID.
    public var id: String
    public var title: String
    /// The number in it of the book that was asked about; nil when no book was.
    public var number: String?
    public var store: AudibleStore

    public init(id: String, title: String, number: String?, store: AudibleStore) {
        self.id = id
        self.title = title
        self.number = number
        self.store = store
    }
}

/// One edition of one book of a series. A number often has several.
public struct AudibleSeriesEdition: Equatable, Sendable {
    public var asin: String
    public var title: String
    /// As Audible gives it: "1", "2.5", "1-3"; nil for a member with no number.
    public var number: String?
    /// Audible's own ordering value.
    public var sort: Double
    public var authors: [String]
    public var narrators: [String]
    public var minutes: Int?
    /// Nil when Audible does not say.
    public var isAbridged: Bool?
    /// The start of the day, in UTC.
    public var releaseDate: Date?

    public init(
        asin: String, title: String, number: String?, sort: Double, authors: [String] = [], narrators: [String] = [],
        minutes: Int? = nil, isAbridged: Bool? = nil, releaseDate: Date? = nil
    ) {
        self.asin = asin
        self.title = title
        self.number = number
        self.sort = sort
        self.authors = authors
        self.narrators = narrators
        self.minutes = minutes
        self.isAbridged = isAbridged
        self.releaseDate = releaseDate
    }
}

/// Every edition of every book of a series, as one store lists it.
public struct AudibleSeriesList: Equatable, Sendable {
    /// The series; its `number` is nil.
    public var ref: AudibleSeriesRef
    /// In Audible's order.
    public var editions: [AudibleSeriesEdition]

    public init(ref: AudibleSeriesRef, editions: [AudibleSeriesEdition]) {
        self.ref = ref
        self.editions = editions
    }
}

/// A series number as text: "1", "01", "2.5", "1-3".
enum SeriesNumber {
    /// The number a plain number stands for: "01" and "1.0" are 1. Nil for anything
    /// else: a range, a word, nothing.
    static func value(_ text: String?) -> Double? {
        guard let text = text?.lookupTrimmed, !text.isEmpty, text.count <= 20 else { return nil }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let value = Double(text), value.isFinite
        else { return nil }
        return value
    }

    /// Whether `first` comes before `second`; nil when neither comes before the other.
    /// Plain numbers by their value and before everything else; other numbers as text;
    /// no number last.
    static func precedes(_ first: String?, _ second: String?) -> Bool? {
        switch (value(first), value(second)) {
        case (let a?, let b?): return a == b ? nil : a < b
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil): break
        }
        switch (first?.lookupTrimmed.nonBlank, second?.lookupTrimmed.nonBlank) {
        case (let a?, let b?): return a == b ? nil : a < b
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil): return nil
        }
    }
}

/// Asks one Audible store's public catalogue which series a book is in, and for every
/// book of a series. No account, no cookies.
public struct AudibleSeriesProvider: Sendable {
    private let http: any HTTPFetching
    private let store: AudibleStore

    static let bookGroups = "series,product_desc"
    static let searchGroups = "series,product_desc,contributors"
    static let seriesGroups = "relationships,product_desc"
    static let memberGroups = "product_desc,product_attrs,contributors,media"
    /// The most results a search for a book is asked for, and looked at.
    static let searchLimit = 10
    /// The most series of one book that are read.
    static let seriesLimit = 50
    /// The most members whose details are asked for in one request.
    static let batchSize = 40
    /// The most members of a series that are kept.
    static let memberLimit = 400

    public init(http: any HTTPFetching, store: AudibleStore) {
        self.http = http
        self.store = store
    }

    // MARK: A book's series

    /// The series a book is in. Asks by Audible ID when `asin` is given, otherwise
    /// searches by title and author and takes the series of the first result with that
    /// title; when no result has it, nothing (never a guess).
    ///
    /// An `asin` that is not a well-formed ASIN is not sent: the book is searched for as
    /// one that has none. A book the store does not know is in no series.
    public func series(ofBookWithASIN asin: String?, title: String, author: String?) async throws -> [AudibleSeriesRef] {
        if let asin = asin.flatMap(AudibleProvider.asin) {
            guard let product = try await product(asin, groups: Self.bookGroups) else { return [] }
            return refs(product["series"])
        }

        let wanted = LookupText.comparable(title)
        guard let title = title.nonBlank, !wanted.isEmpty else { return [] }
        var items: [(name: String, value: String)] = [("title", title)]
        if let author = author?.nonBlank { items.append(("author", author)) }
        items.append(("num_results", String(Self.searchLimit)))
        items.append(("products_sort_by", "Relevance"))
        items.append(("response_groups", Self.searchGroups))
        guard let url = LookupRequest.url(host: store.host, path: "/1.0/catalog/products", query: items),
              let answer = try await object(at: url)
        else { return [] }
        guard let products = answer["products"] as? [Any] else { throw LookupError.unreadable }
        for case let product as [String: Any] in products.prefix(Self.searchLimit) {
            guard let found = LookupText.cleaned(product["title"] as? String, limit: LookupText.nameLimit),
                  LookupText.comparable(found) == wanted
            else { continue }
            return refs(product["series"])
        }
        return []
    }

    /// Each series once, in the order given. One with no well-formed ID or no title is dropped.
    private func refs(_ list: Any?) -> [AudibleSeriesRef] {
        var seen: Set<String> = []
        var refs: [AudibleSeriesRef] = []
        for case let entry as [String: Any] in (list as? [Any] ?? []).prefix(Self.seriesLimit) {
            guard let id = (entry["asin"] as? String).flatMap(AudibleProvider.asin),
                  let title = LookupText.cleaned(entry["title"] as? String, limit: LookupText.nameLimit),
                  seen.insert(id).inserted
            else { continue }
            let number = LookupText.cleaned(entry["sequence"] as? String, limit: LookupText.lineLimit)
            refs.append(AudibleSeriesRef(id: id, title: title, number: number, store: store))
        }
        return refs
    }

    // MARK: A series' books

    /// What a series says of one of its members.
    private struct Member {
        var asin: String
        var number: String?
        var sort: Double
    }

    /// Every edition of every book of the series, ordered by Audible's ordering value,
    /// then number, then ASIN. A series the store does not know has none.
    ///
    /// Throws `LookupError.unreadable`, and asks nothing, when the series' ID is not a
    /// well-formed ASIN. The answer's `ref` names this provider's store and, when the
    /// series has members, carries the catalogue's own title for it.
    public func list(_ series: AudibleSeriesRef) async throws -> AudibleSeriesList {
        guard let id = AudibleProvider.asin(series.id) else { throw LookupError.unreadable }
        var ref = AudibleSeriesRef(id: id, title: series.title, number: nil, store: store)
        guard let product = try await product(id, groups: Self.seriesGroups) else {
            return AudibleSeriesList(ref: ref, editions: [])
        }

        var seen: Set<String> = []
        var members: [Member] = []
        for case let relation as [String: Any] in product["relationships"] as? [Any] ?? [] {
            guard relation["relationship_type"] as? String == "series",
                  relation["relationship_to_product"] as? String == "child",
                  let asin = (relation["asin"] as? String).flatMap(AudibleProvider.asin),
                  seen.insert(asin).inserted
            else { continue }
            let number = LookupText.cleaned(relation["sequence"] as? String, limit: LookupText.lineLimit)
            members.append(Member(asin: asin, number: number, sort: Self.sort(relation["sort"], number: number)))
        }
        // An entry with no members is not known to be a series: its title is not taken.
        if !members.isEmpty,
           let title = LookupText.cleaned(product["title"] as? String, limit: LookupText.nameLimit) {
            ref.title = title
        }
        // Too long a series loses its end, not whichever members were named last.
        if members.count > Self.memberLimit {
            let kept = Set(members.sorted(by: Self.inOrder).prefix(Self.memberLimit).map(\.asin))
            members.removeAll { !kept.contains($0.asin) }
        }

        var editions: [AudibleSeriesEdition] = []
        var start = 0
        while start < members.count {
            try Task.checkCancellation()
            let batch = members[start..<min(start + Self.batchSize, members.count)]
            start += Self.batchSize
            editions += try await details(of: Array(batch))
        }
        editions.sort {
            Self.inOrder(Member(asin: $0.asin, number: $0.number, sort: $0.sort),
                         Member(asin: $1.asin, number: $1.number, sort: $1.sort))
        }
        return AudibleSeriesList(ref: ref, editions: editions)
    }

    /// The members the catalogue gave details of. One it left out, or gave no title
    /// for, is left out; a product that was not asked for is not read.
    private func details(of members: [Member]) async throws -> [AudibleSeriesEdition] {
        let query: [(name: String, value: String)] = [
            ("asins", members.map(\.asin).joined(separator: ",")), ("response_groups", Self.memberGroups),
        ]
        guard let url = LookupRequest.url(host: store.host, path: "/1.0/catalog/products", query: query) else { return [] }
        let answer = try await LookupRequest.object(at: url, http: http)
        guard let products = answer["products"] as? [Any] else { throw LookupError.unreadable }

        var asked: [String: Member] = [:]
        for member in members { asked[member.asin] = member }
        var editions: [AudibleSeriesEdition] = []
        for case let product as [String: Any] in products.prefix(members.count * 2) {
            guard let asin = (product["asin"] as? String).flatMap(AudibleProvider.asin),
                  let title = LookupText.cleaned(product["title"] as? String, limit: LookupText.nameLimit),
                  let member = asked.removeValue(forKey: asin)
            else { continue }
            let format = LookupText.cleaned(product["format_type"] as? String, limit: LookupText.lineLimit)
            editions.append(AudibleSeriesEdition(
                asin: asin, title: title, number: member.number, sort: member.sort,
                authors: AudibleProvider.names(product["authors"]),
                narrators: AudibleProvider.names(product["narrators"]),
                minutes: (product["runtime_length_min"] as? Int).flatMap { (1...1_000_000).contains($0) ? $0 : nil },
                isAbridged: AudibleProvider.abridged(format),
                releaseDate: Self.day(product["release_date"]) ?? Self.day(product["issue_date"])))
        }
        return editions
    }

    /// By Audible's ordering value, then number, then ASIN.
    private static func inOrder(_ a: Member, _ b: Member) -> Bool {
        if a.sort != b.sort { return a.sort < b.sort }
        if let precedes = SeriesNumber.precedes(a.number, b.number) { return precedes }
        return a.asin < b.asin
    }

    /// Audible's ordering value, sent as text or as a number. Without one a member is
    /// placed by its number, and without that either, last.
    private static func sort(_ raw: Any?, number: String?) -> Double {
        let given = (raw as? String).flatMap { Double($0.lookupTrimmed) } ?? (raw as? Double)
        if let given, given.isFinite { return given }
        return SeriesNumber.value(number) ?? .greatestFiniteMagnitude
    }

    /// The day a "YYYY-MM-DD" date names, at its start in UTC; nil for anything else.
    static func day(_ raw: Any?) -> Date? {
        guard let text = (raw as? String)?.lookupTrimmed else { return nil }
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let year = LookupText.year(Int(parts[0])), let month = Int(parts[1]), let day = Int(parts[2])
        else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        let wanted = DateComponents(year: year, month: month, day: day)
        // A day there is no such day as (the 30th of February) is not moved to another.
        guard let date = calendar.date(from: wanted),
              calendar.dateComponents([.year, .month, .day], from: date) == wanted
        else { return nil }
        return date
    }

    // MARK: Requests

    /// The catalogue's entry for one ID; nil when the store has none (a 404).
    private func product(_ asin: String, groups: String) async throws -> [String: Any]? {
        guard let url = LookupRequest.url(
            host: store.host, path: "/1.0/catalog/products/\(asin)", query: [("response_groups", groups)]),
            let answer = try await object(at: url)
        else { return nil }
        guard let product = answer["product"] as? [String: Any] else { throw LookupError.unreadable }
        return product
    }

    /// The JSON object at `url`; nil when the store answers that there is nothing there.
    private func object(at url: URL) async throws -> [String: Any]? {
        do {
            return try await LookupRequest.object(at: url, http: http)
        } catch LookupError.refused(status: 404) {
            return nil
        }
    }
}

import Foundation

/// An Audible country. Each has its own catalogue and its own ASINs.
public enum AudibleStore: String, Codable, Sendable, CaseIterable {
    case us, uk, au, ca, de, fr, it, es, jp, `in`, br

    public var title: String {
        switch self {
        case .us: "United States"
        case .uk: "United Kingdom"
        case .au: "Australia"
        case .ca: "Canada"
        case .de: "Germany"
        case .fr: "France"
        case .it: "Italy"
        case .es: "Spain"
        case .jp: "Japan"
        case .in: "India"
        case .br: "Brazil"
        }
    }

    public var host: String {
        switch self {
        case .us: "api.audible.com"
        case .uk: "api.audible.co.uk"
        case .au: "api.audible.com.au"
        case .ca: "api.audible.ca"
        case .de: "api.audible.de"
        case .fr: "api.audible.fr"
        case .it: "api.audible.it"
        case .es: "api.audible.es"
        case .jp: "api.audible.co.jp"
        case .in: "api.audible.in"
        case .br: "api.audible.com.br"
        }
    }

    /// The store's website, as against `host`, which answers catalogue requests.
    public var webHost: String {
        switch self {
        case .us: "www.audible.com"
        case .uk: "www.audible.co.uk"
        case .au: "www.audible.com.au"
        case .ca: "www.audible.ca"
        case .de: "www.audible.de"
        case .fr: "www.audible.fr"
        case .it: "www.audible.it"
        case .es: "www.audible.es"
        case .jp: "www.audible.co.jp"
        case .in: "www.audible.in"
        case .br: "www.audible.com.br"
        }
    }

    /// The book's page on this store's website, or a search there for its title and
    /// author when there is no usable ASIN. Always `https`, always this store's own host:
    /// only a well-formed ASIN reaches the path, and the search words are percent-encoded
    /// by the lookup's encoder, so nothing in them can change the address's shape.
    /// With nothing to search for, the store's front page.
    public func webAddress(asin: String?, title: String, author: String) -> URL {
        let home = URL(string: "https://\(webHost)/")!
        if let asin = asin.flatMap(AudibleProvider.asin) {
            return LookupRequest.url(host: webHost, path: "/pd/\(asin)", query: []) ?? home
        }
        let words = [title, author]
            .compactMap { LookupText.cleaned($0, limit: LookupText.nameLimit) }
            .joined(separator: " ")
        guard !words.isEmpty else { return home }
        return LookupRequest.url(host: webHost, path: "/search", query: [("keywords", words)]) ?? home
    }

    /// The store for a region code such as "GB" or "AU"; `.us` when there is none.
    public static func forRegion(_ code: String?) -> AudibleStore {
        switch code?.lookupTrimmed.uppercased() {
        case "GB", "UK", "IE": .uk
        case "AU", "NZ": .au
        case "CA": .ca
        case "DE", "AT", "CH": .de
        case "FR": .fr
        case "IT": .it
        case "ES": .es
        case "JP": .jp
        case "IN": .in
        case "BR": .br
        default: .us
        }
    }
}

/// Looks audiobooks up in one Audible store's public catalogue. No account, no cookies.
public struct AudibleProvider: LookupProvider {
    public let source = LookupSource.audible
    private let http: any HTTPFetching
    private let store: AudibleStore
    private let limit: Int

    static let responseGroups = "contributors,product_desc,product_extended_attrs,product_attrs,media,series,category_ladders"
    static let imageSizes = "500,1024"

    public init(http: any HTTPFetching, store: AudibleStore, limit: Int = 8) {
        self.http = http
        self.store = store
        self.limit = limit
    }

    public func search(_ query: LookupQuery) async throws -> [LookupCandidate] {
        try await answer(to: query).candidates
    }

    /// The results, and the narrator's name when nothing read by them was found and
    /// what is given is the same search without it.
    public func answer(to query: LookupQuery) async throws -> LookupAnswer {
        let shared: [(name: String, value: String)] = [("response_groups", Self.responseGroups), ("image_sizes", Self.imageSizes)]

        if let asin = query.asin.flatMap(Self.asin) {
            guard let url = LookupRequest.url(host: store.host, path: "/1.0/catalog/products/\(asin)", query: shared) else {
                return LookupAnswer()
            }
            let answer = try await LookupRequest.object(at: url, http: http)
            guard let product = answer["product"] as? [String: Any] else { throw LookupError.unreadable }
            // An unknown ASIN (one from another country's store, say) is answered with a
            // product that has no title: the title and author are searched for instead.
            // A request that failed has thrown by now, and is not searched around.
            if let found = candidate(from: product) { return LookupAnswer(candidates: [found]) }
        }

        var items: [(name: String, value: String)] = []
        if let title = query.title.nonBlank { items.append(("title", title)) }
        if let author = query.author.nonBlank { items.append(("author", author)) }
        // An ISBN alone cannot be searched here.
        guard !items.isEmpty else { return LookupAnswer() }
        items.append(("num_results", String(limit)))
        items.append(("products_sort_by", "Relevance"))

        if let narrator = query.narrator?.nonBlank {
            let found = try await products(matching: items + [("narrator", narrator)] + shared)
            // Nothing read by that narrator: the same search once more, without the name.
            // A request that failed has thrown by now, and is not searched around.
            if !found.isEmpty { return LookupAnswer(candidates: found) }
            return LookupAnswer(candidates: try await products(matching: items + shared), narratorNotFound: narrator)
        }
        return LookupAnswer(candidates: try await products(matching: items + shared))
    }

    private func products(matching items: [(name: String, value: String)]) async throws -> [LookupCandidate] {
        guard let url = LookupRequest.url(host: store.host, path: "/1.0/catalog/products", query: items) else { return [] }
        let answer = try await LookupRequest.object(at: url, http: http)
        guard let products = answer["products"] as? [Any] else { throw LookupError.unreadable }
        // Audible's order is kept and nothing is dropped for its language: ranking is the service's.
        return products.compactMap(candidate)
    }

    /// Ten letters or digits, upper-cased; nil for anything else, which must not reach a URL path.
    public static func asin(_ raw: String) -> String? {
        let tidy = raw.lookupTrimmed.uppercased()
        guard tidy.count == 10, tidy.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return tidy
    }

    /// Nil for a product without an ASIN and a title.
    private func candidate(from product: Any) -> LookupCandidate? {
        guard let product = product as? [String: Any] else { return nil }
        func line(_ key: String, limit: Int = LookupText.lineLimit) -> String? {
            LookupText.cleaned(product[key] as? String, limit: limit)
        }
        guard let asin = line("asin"),
              let title = line("title", limit: LookupText.nameLimit)
        else { return nil }

        var metadata = BookMetadata(title: title)
        metadata.asin = asin
        metadata.subtitle = line("subtitle", limit: LookupText.nameLimit)
        // Names exactly as listed: Audible puts translators and "foreword" credits here too.
        metadata.authors = Self.names(product["authors"])
        metadata.narrators = Self.names(product["narrators"])
        metadata.publisher = line("publisher_name")
        metadata.year = Self.year(product["release_date"]) ?? Self.year(product["issue_date"])
        let language = line("language")
        metadata.language = language.flatMap(LookupText.languageCode)
        let minutes = (product["runtime_length_min"] as? Int).flatMap { (1...1_000_000).contains($0) ? $0 : nil }
        metadata.durationSeconds = minutes.map { Double($0) * 60 }
        metadata.summary = LookupText.cleaned(
            (product["publisher_summary"] as? String).map(LookupText.plainText(fromHTML:)),
            limit: LookupText.summaryLimit, multiline: true)
        metadata.genre = Self.genre(product["category_ladders"])
        (metadata.series, metadata.seriesNumber) = Self.series(product["series"], main: line("publication_name", limit: LookupText.nameLimit))

        var note = [source.title]
        let format = line("format_type")
        if let format { note.append(Self.readable(format)) }
        if let minutes { note.append(LookupText.lengthLabel(minutes: minutes)) }
        if let language { note.append(Self.readable(language)) }

        let images = product["product_images"] as? [String: Any]
        func image(_ size: String) -> URL? {
            LookupText.cleaned(images?[size] as? String, limit: 2000).flatMap(URL.init(string:))
        }
        let small = image("500")

        return LookupCandidate(
            id: "\(source.rawValue):\(store.rawValue):\(asin)",
            source: source,
            metadata: metadata,
            coverURL: image("1024") ?? small,
            thumbnailURL: small,
            note: note.joined(separator: " · "),
            hasMoreDetails: false,
            edition: EditionFacts(
                format: .digital, abridged: Self.abridged(format), publisher: metadata.publisher, year: metadata.year,
                stores: [store.rawValue])
        )
    }

    /// "unabridged" -> false, "abridged" -> true; nil for any other kind, which does not say.
    private static func abridged(_ format: String?) -> Bool? {
        switch format?.lowercased() {
        case "unabridged": false
        case "abridged": true
        default: nil
        }
    }

    private static func names(_ list: Any?) -> [String] {
        LookupText.cleanedNames((list as? [Any] ?? []).compactMap { ($0 as? [String: Any])?["name"] as? String })
    }

    /// The year of a "YYYY-MM-DD" date.
    private static func year(_ date: Any?) -> Int? {
        guard let text = date as? String else { return nil }
        let tidy = text.lookupTrimmed
        let digits = tidy.prefix(4)
        // Four digits and then the rest of a date, not the start of a longer number.
        guard digits.count == 4, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              tidy.dropFirst(4).first.map({ !$0.isNumber }) ?? true
        else { return nil }
        return LookupText.year(Int(digits))
    }

    /// The top name that most of the ladders filed under "Genres" share: a book is often
    /// filed under a second genre as well as its own. Among equals, the first listed.
    private static func genre(_ ladders: Any?) -> String? {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for ladder in (ladders as? [Any] ?? []).prefix(100) {
            guard let ladder = ladder as? [String: Any], ladder["root"] as? String == "Genres",
                  let top = (ladder["ladder"] as? [Any])?.first as? [String: Any],
                  let name = LookupText.cleaned(top["name"] as? String, limit: LookupText.lineLimit)
            else { continue }
            if counts[name] == nil { order.append(name) }
            counts[name, default: 0] += 1
        }
        let most = counts.values.max()
        return order.first { counts[$0] == most }
    }

    /// A book can sit in several series (a universe and a series within it). The one with a
    /// number is wanted, preferring the one Audible names as the main series; series without
    /// a number are used only when none has one.
    private static func series(_ list: Any?, main: String?) -> (title: String?, number: String?) {
        let entries: [(title: String, number: String?)] = (list as? [Any] ?? []).compactMap { entry in
            guard let entry = entry as? [String: Any],
                  let title = LookupText.cleaned(entry["title"] as? String, limit: LookupText.nameLimit)
            else { return nil }
            return (title, LookupText.cleaned(entry["sequence"] as? String, limit: LookupText.lineLimit))
        }
        let numbered = entries.filter { $0.number != nil }
        let pool = numbered.isEmpty ? entries : numbered
        guard let chosen = pool.first(where: { $0.title == main }) ?? pool.first else { return (nil, nil) }
        return chosen
    }

    /// "original_recording" -> "Original recording".
    private static func readable(_ word: String) -> String {
        let spaced = word.replacingOccurrences(of: "_", with: " ")
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }
}

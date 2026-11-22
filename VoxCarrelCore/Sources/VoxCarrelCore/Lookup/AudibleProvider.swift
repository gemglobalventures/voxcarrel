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
        let shared: [(name: String, value: String)] = [("response_groups", Self.responseGroups), ("image_sizes", Self.imageSizes)]

        if let asin = query.asin.flatMap(Self.asin) {
            guard let url = LookupRequest.url(host: store.host, path: "/1.0/catalog/products/\(asin)", query: shared) else { return [] }
            let answer = try await LookupRequest.object(at: url, http: http)
            guard let product = answer["product"] as? [String: Any] else { throw LookupError.unreadable }
            // An unknown ASIN (one from another country's store, say) is answered with a
            // product that has no title: the title and author are searched for instead.
            // A request that failed has thrown by now, and is not searched around.
            if let found = candidate(from: product) { return [found] }
        }

        var items: [(name: String, value: String)] = []
        if let title = query.title.nonBlank { items.append(("title", title)) }
        if let author = query.author.nonBlank { items.append(("author", author)) }
        // An ISBN alone cannot be searched here.
        guard !items.isEmpty else { return [] }
        items.append(("num_results", String(limit)))
        items.append(("products_sort_by", "Relevance"))
        guard let url = LookupRequest.url(host: store.host, path: "/1.0/catalog/products", query: items + shared) else { return [] }

        let answer = try await LookupRequest.object(at: url, http: http)
        guard let products = answer["products"] as? [Any] else { throw LookupError.unreadable }
        // Audible's order is kept and nothing is dropped for its language: ranking is the service's.
        return products.compactMap(candidate)
    }

    /// Ten letters or digits, upper-cased; nil for anything else, which must not reach a URL path.
    static func asin(_ raw: String) -> String? {
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
        if let format = line("format_type") { note.append(Self.readable(format)) }
        if let minutes { note.append(minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m") }
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
            hasMoreDetails: false
        )
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

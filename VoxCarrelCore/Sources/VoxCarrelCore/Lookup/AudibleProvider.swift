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
        guard let product = product as? [String: Any],
              let asin = (product["asin"] as? String)?.nonBlank,
              let title = (product["title"] as? String)?.nonBlank
        else { return nil }

        var metadata = BookMetadata(title: title)
        metadata.asin = asin
        metadata.subtitle = (product["subtitle"] as? String)?.nonBlank
        // Names exactly as listed: Audible puts translators and "foreword" credits here too.
        metadata.authors = Self.names(product["authors"])
        metadata.narrators = Self.names(product["narrators"])
        metadata.publisher = (product["publisher_name"] as? String)?.nonBlank
        metadata.year = Self.year(product["release_date"]) ?? Self.year(product["issue_date"])
        let language = (product["language"] as? String)?.nonBlank
        metadata.language = language.flatMap(LookupText.languageCode)
        let minutes = (product["runtime_length_min"] as? Int).flatMap { $0 > 0 ? $0 : nil }
        metadata.durationSeconds = minutes.map { Double($0) * 60 }
        metadata.summary = (product["publisher_summary"] as? String).map(LookupText.plainText(fromHTML:)).flatMap(\.nonBlank)
        metadata.genre = Self.genre(product["category_ladders"])
        (metadata.series, metadata.seriesNumber) = Self.series(product["series"], main: product["publication_name"] as? String)

        var note = [source.title]
        if let format = (product["format_type"] as? String)?.nonBlank { note.append(Self.readable(format)) }
        if let minutes { note.append(minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m") }
        if let language { note.append(Self.readable(language)) }

        let images = product["product_images"] as? [String: Any]
        let cover = ["1024", "500"].lazy.compactMap { (images?[$0] as? String)?.nonBlank }.first

        return LookupCandidate(
            id: "\(source.rawValue):\(store.rawValue):\(asin)",
            source: source,
            metadata: metadata,
            coverURL: cover.flatMap(URL.init(string:)),
            note: note.joined(separator: " · "),
            hasMoreDetails: false
        )
    }

    private static func names(_ list: Any?) -> [String] {
        (list as? [Any] ?? []).compactMap { (($0 as? [String: Any])?["name"] as? String)?.nonBlank }
    }

    /// The year of a "YYYY-MM-DD" date.
    private static func year(_ date: Any?) -> Int? {
        guard let text = date as? String else { return nil }
        let digits = text.lookupTrimmed.prefix(4)
        guard digits.count == 4, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(digits)
    }

    /// The top of the first ladder filed under "Genres".
    private static func genre(_ ladders: Any?) -> String? {
        for ladder in ladders as? [Any] ?? [] {
            guard let ladder = ladder as? [String: Any], ladder["root"] as? String == "Genres" else { continue }
            let top = (ladder["ladder"] as? [Any])?.first as? [String: Any]
            return (top?["name"] as? String)?.nonBlank
        }
        return nil
    }

    /// A book can sit in several series (a universe and a series within it). The one with a
    /// number is wanted, preferring the one Audible names as the main series; series without
    /// a number are used only when none has one.
    private static func series(_ list: Any?, main: String?) -> (title: String?, number: String?) {
        let entries: [(title: String, number: String?)] = (list as? [Any] ?? []).compactMap { entry in
            guard let entry = entry as? [String: Any], let title = (entry["title"] as? String)?.nonBlank else { return nil }
            return (title, (entry["sequence"] as? String)?.nonBlank)
        }
        let numbered = entries.filter { $0.number != nil }
        let pool = numbered.isEmpty ? entries : numbered
        let main = main?.nonBlank
        guard let chosen = pool.first(where: { $0.title == main }) ?? pool.first else { return (nil, nil) }
        return chosen
    }

    /// "original_recording" -> "Original recording".
    private static func readable(_ word: String) -> String {
        let spaced = word.replacingOccurrences(of: "_", with: " ")
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }
}

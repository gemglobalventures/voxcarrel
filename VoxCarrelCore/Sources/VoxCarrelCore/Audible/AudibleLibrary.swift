import Foundation

/// A book as an Audible account's library lists it.
public struct AudibleOwnedBook: Equatable, Sendable, Identifiable {
    public var asin: String
    public var title: String
    public var subtitle: String?
    public var authors: [String]
    public var narrators: [String]
    /// The series Audible numbers the book in, when it is in one.
    public var series: String?
    public var seriesNumber: String?
    public var minutes: Int?
    public var isFinished: Bool
    /// How far along the owner is, 0 to 100; nil when Audible does not say.
    public var percentComplete: Double?
    public var purchased: Date?
    public var year: Int?
    public var publisher: String?
    public var language: String?
    /// The paths Audible files the book under, each from its top name down.
    public var genrePaths: [[String]]
    public var coverURL: URL?

    public var id: String { asin }

    public init(asin: String, title: String) {
        self.asin = asin
        self.title = title
        authors = []
        narrators = []
        isFinished = false
        genrePaths = []
    }

    /// The reading status this stands for: finished, begun (some of it heard), or neither.
    public var status: ReadStatus {
        if isFinished { return .finished }
        return (percentComplete ?? 0) >= 1 ? .inProgress : .unread
    }
}

/// Reads an account's library from Audible. Nothing is changed there.
public enum AudibleLibraryReader {
    static let pageSize = 50
    /// More pages than any library has: a stop for an answer that never ends.
    static let mostPages = 400
    static let groups =
        "product_desc,contributors,series,media,product_attrs,is_finished,percent_complete,category_ladders"

    /// Every book of the library, in the order Audible gives them. Podcasts and
    /// anything else that is not a book are left out.
    public static func books(of account: AudibleAccount, transport: any AudibleTransport) async throws -> [AudibleOwnedBook] {
        var found: [AudibleOwnedBook] = []
        var seen = Set<String>()
        for page in 1...mostPages {
            let path = "/1.0/library?num_results=\(pageSize)&page=\(page)&response_groups=\(groups)"
            guard let url = URL(string: "https://\(account.store.host)\(path)") else { throw AudibleAccountError.unreadable }
            var request = URLRequest(url: url)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            for (name, value) in try AudibleSigner.headers(method: "GET", path: path, account: account) {
                request.setValue(value, forHTTPHeaderField: name)
            }
            let (data, status) = try await transport.send(request)
            guard status == 200 else {
                throw status == 401 || status == 403 ? AudibleAccountError.refused(status) : AudibleAccountError.unreadable
            }
            guard let answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let items = answer["items"] as? [Any]
            else { throw AudibleAccountError.unreadable }
            for item in items {
                guard let book = book(from: item), seen.insert(book.asin).inserted else { continue }
                found.append(book)
            }
            if items.count < pageSize { break }
        }
        return found
    }

    /// One item of the library as a book; nil for a podcast, and for an item with no
    /// ID or no title.
    static func book(from item: Any) -> AudibleOwnedBook? {
        guard let item = item as? [String: Any],
              let asin = LookupText.cleaned(item["asin"] as? String, limit: 20),
              let title = LookupText.cleaned(item["title"] as? String, limit: LookupText.lineLimit)
        else { return nil }
        let kind = (item["content_delivery_type"] as? String ?? "").lowercased()
        guard !kind.contains("podcast"), !kind.contains("periodical") else { return nil }

        var book = AudibleOwnedBook(asin: asin, title: title)
        book.subtitle = LookupText.cleaned(item["subtitle"] as? String, limit: LookupText.lineLimit)
        func names(_ key: String) -> [String] {
            (item[key] as? [Any] ?? []).prefix(20).compactMap {
                LookupText.cleaned(($0 as? [String: Any])?["name"] as? String, limit: LookupText.lineLimit)
            }
        }
        book.authors = names("authors")
        book.narrators = names("narrators")
        // The series Audible numbers the book in, failing that the first it names.
        let series = (item["series"] as? [Any] ?? []).prefix(20).compactMap { $0 as? [String: Any] }
        let chosen = series.first { !(($0["sequence"] as? String) ?? "").isEmpty } ?? series.first
        book.series = LookupText.cleaned(chosen?["title"] as? String, limit: LookupText.lineLimit)
        if book.series != nil {
            book.seriesNumber = LookupText.cleaned(chosen?["sequence"] as? String, limit: 20)
        }
        if let minutes = item["runtime_length_min"] as? Int, minutes > 0, minutes < 100_000 { book.minutes = minutes }
        book.isFinished = item["is_finished"] as? Bool ?? false
        if let percent = (item["percent_complete"] as? NSNumber)?.doubleValue, percent.isFinite {
            book.percentComplete = min(100, max(0, percent))
        }
        book.purchased = (item["purchase_date"] as? String).flatMap(date)
        book.year = ((item["release_date"] as? String) ?? (item["issue_date"] as? String))
            .flatMap { Int($0.prefix(4)) }.flatMap { (1000...9999).contains($0) ? $0 : nil }
        book.publisher = LookupText.cleaned(item["publisher_name"] as? String, limit: LookupText.lineLimit)
        book.language = LookupText.cleaned(item["language"] as? String, limit: 40)
        book.genrePaths = AudibleProvider.genrePaths(item["category_ladders"])
        if let images = item["product_images"] as? [String: Any],
           let address = (images["500"] ?? images.values.first) as? String,
           let url = URL(string: address), url.scheme == "https" {
            book.coverURL = url
        }
        return book
    }

    static func date(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

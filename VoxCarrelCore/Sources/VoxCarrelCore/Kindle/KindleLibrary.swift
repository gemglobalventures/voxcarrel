import Foundation

/// A book as an Amazon account's Kindle library lists it.
public struct KindleOwnedBook: Equatable, Sendable, Identifiable {
    public var asin: String
    public var title: String
    public var authors: [String]
    /// The series the title itself names, as in "(The Expanse Book 2)", when it does.
    public var series: String?
    public var seriesNumber: String?
    public var coverURL: URL?

    public var id: String { asin }

    public init(asin: String, title: String) {
        self.asin = asin
        self.title = title
        authors = []
    }
}

/// Reads an account's Kindle library from Amazon, as its web reader lists it. Nothing
/// is changed there.
///
/// The web reader wants a signed-in web session, not a device's keys. Amazon gives a
/// registered device such a session in exchange for its refresh key; that session is
/// asked for afresh at each reading, sent only to the web reader of the account's own
/// store, and kept nowhere.
public enum KindleLibraryReader {
    static let pageSize = 50
    /// More pages than any library has: a stop for an answer that never ends.
    static let mostPages = 400

    /// Every book of the Kindle library, in the order Amazon gives them. Samples and
    /// anything else that is not a book the account owns are left out.
    public static func books(of account: AudibleAccount, transport: any AudibleTransport) async throws -> [KindleOwnedBook] {
        let cookies = try await webSession(of: account, transport: transport)
        let host = "read.amazon.\(account.store.amazonDomain)"
        var found: [KindleOwnedBook] = []
        var seen = Set<String>()
        var token: String?
        for _ in 1...mostPages {
            var address = "https://\(host)/kindle-library/search?query=&libraryType=BOOKS&sortType=recency&querySize=\(pageSize)"
            if let token {
                guard let escaped = token.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else {
                    throw AudibleAccountError.unreadable
                }
                address += "&paginationToken=\(escaped)"
            }
            guard let url = URL(string: address), url.host == host else { throw AudibleAccountError.unreadable }
            var request = URLRequest(url: url)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(cookies, forHTTPHeaderField: "Cookie")
            let (data, status) = try await transport.send(request)
            let answer = try Self.page(in: data, status: status)
            let items = answer.items
            for item in items {
                guard let book = book(from: item), seen.insert(book.asin).inserted else { continue }
                found.append(book)
            }
            guard !items.isEmpty, let next = answer.next, !next.isEmpty, next != token else { break }
            token = next
        }
        return found
    }

    /// One page of the library as the web reader answered: its items and the token of
    /// the page after it; or why there is none to be had.
    static func page(in data: Data, status: Int) throws -> (items: [Any], next: String?) {
        guard status == 200 else {
            // Sent to its sign-in page: the session was not taken.
            if (300..<400).contains(status) || status == 401 || status == 403 { throw AudibleAccountError.refused(status) }
            throw AudibleAccountError.saysNotNow(status) ? AudibleAccountError.busy(status) : AudibleAccountError.unreadable
        }
        guard let answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let items = answer["itemsList"] as? [Any]
        else { throw AudibleAccountError.unreadable }
        return (items, answer["paginationToken"] as? String)
    }

    /// Asks Amazon for a session and one book of the Kindle library, to see whether
    /// the link still works. Nothing is kept of the answers, and nothing is changed.
    /// - Throws: As `books(of:transport:)`: why the library cannot be read now.
    public static func check(_ account: AudibleAccount, transport: any AudibleTransport) async throws {
        let cookies = try await webSession(of: account, transport: transport)
        let host = "read.amazon.\(account.store.amazonDomain)"
        guard let url = URL(string: "https://\(host)/kindle-library/search?query=&libraryType=BOOKS&sortType=recency&querySize=1"),
              url.host == host
        else { throw AudibleAccountError.unreadable }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(cookies, forHTTPHeaderField: "Cookie")
        let (data, status) = try await transport.send(request)
        _ = try page(in: data, status: status)
    }

    /// A web session for the account, as the value of a Cookie header.
    static func webSession(of account: AudibleAccount, transport: any AudibleTransport) async throws -> String {
        let domain = account.store.amazonDomain
        guard let url = URL(string: "https://www.amazon.\(domain)/ap/exchangetoken/cookies") else {
            throw AudibleAccountError.unreadable
        }
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "app_name", value: "Audible"),
            URLQueryItem(name: "app_version", value: AudibleLink.appVersion),
            URLQueryItem(name: "source_token", value: account.refreshToken),
            URLQueryItem(name: "requested_token_type", value: "auth_cookies"),
            URLQueryItem(name: "source_token_type", value: "refresh_token"),
            URLQueryItem(name: "domain", value: ".amazon.\(domain)"),
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("api.amazon.\(domain)", forHTTPHeaderField: "x-amzn-identity-auth-domain")
        // A plus sign in a form stands for a space: it is written out.
        request.httpBody = Data((form.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        let (data, status) = try await transport.send(request)
        guard status == 200 else {
            if AudibleAccountError.saysNotNow(status) { throw AudibleAccountError.busy(status) }
            throw (400..<500).contains(status) ? AudibleAccountError.refused(status) : AudibleAccountError.unreadable
        }
        guard let answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tokens = (answer["response"] as? [String: Any])?["tokens"] as? [String: Any],
              let groups = tokens["cookies"] as? [String: Any]
        else { throw AudibleAccountError.unreadable }
        var pairs: [String] = []
        for case let group as [Any] in groups.values {
            for case let cookie as [String: Any] in group {
                guard let name = cookie["Name"] as? String, let value = cookie["Value"] as? String,
                      isPlain(name), isPlain(value), !name.isEmpty
                else { continue }
                pairs.append("\(name)=\(value)")
            }
        }
        guard !pairs.isEmpty else { throw AudibleAccountError.refused(status) }
        return pairs.sorted().joined(separator: "; ")
    }

    /// True for text that can stand in a Cookie header without ending it or starting another.
    static func isPlain(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { $0.isASCII && $0.value > 0x20 && $0.value < 0x7F && $0 != ";" && $0 != "," }
    }

    /// One item of the library as a book; nil for a sample, and for an item with no ID
    /// or no title.
    static func book(from item: Any) -> KindleOwnedBook? {
        guard let item = item as? [String: Any],
              let asin = LookupText.cleaned(item["asin"] as? String, limit: 20),
              let title = LookupText.cleaned(item["title"] as? String, limit: LookupText.lineLimit),
              (item["resourceType"] as? String ?? "EBOOK").uppercased() == "EBOOK"
        else { return nil }
        var book = KindleOwnedBook(asin: asin, title: title)
        (book.title, book.series, book.seriesNumber) = seriesNamed(in: title)
        book.authors = (item["authors"] as? [Any] ?? []).prefix(5).flatMap { authors(($0 as? String) ?? "") }
        if let address = item["productUrl"] as? String, let url = URL(string: address), url.scheme == "https" {
            book.coverURL = url
        }
        return book
    }

    /// "Corey, James S. A.:Abraham, Daniel:" as ["James S. A. Corey", "Daniel Abraham"].
    static func authors(_ text: String) -> [String] {
        text.split(separator: ":").prefix(20).compactMap { part in
            let names = part.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            let turned = names.count == 2 && !names[1].isEmpty ? "\(names[1]) \(names[0])" : String(part)
            return LookupText.cleaned(turned, limit: LookupText.lineLimit)
        }
    }

    /// "Caliban's War (The Expanse Book 2)" as the title, "The Expanse" and "2". A title
    /// that ends any other way is left as it is.
    static func seriesNamed(in title: String) -> (title: String, series: String?, number: String?) {
        let pattern = #/^(?<title>.+?)\s*\((?<series>[^()]+?),?\s+(?:Book|Volume|Vol\.|Band|Livre|Libro)\s+(?<number>\d{1,3}(?:\.\d)?)\)$/#
        guard let match = try? pattern.ignoresCase().wholeMatch(in: title) else { return (title, nil, nil) }
        let series = match.series.trimmingCharacters(in: .whitespaces)
        let bare = match.title.trimmingCharacters(in: .whitespaces)
        guard !series.isEmpty, !bare.isEmpty else { return (title, nil, nil) }
        return (bare, series, String(match.number))
    }
}

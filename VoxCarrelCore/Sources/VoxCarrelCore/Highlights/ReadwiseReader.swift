import Foundation

public enum ReadwiseError: Error, Equatable {
    /// Readwise did not accept the token.
    case refused
    case notReachable
    case unreadable
    /// Readwise asked to be left alone for longer than the app will wait.
    case busy
}

/// Reads an account's highlights from Readwise with the owner's own token. Nothing is
/// changed there.
public enum ReadwiseReader {
    static let host = "readwise.io"
    /// More pages than any account has: a stop for an answer that never ends.
    static let mostPages = 500
    /// The longest the app waits when Readwise asks it to slow down.
    static let longestWait: TimeInterval = 90

    /// Every book that has highlights, with them. Articles, tweets, podcasts and the
    /// like are left out: only what Readwise files under books.
    ///
    /// - Parameters:
    ///   - updatedAfter: Only what changed since then, for looking again later.
    ///   - wait: For tests; the task sleeps otherwise.
    public static func books(
        token: String, updatedAfter: Date? = nil, transport: any AudibleTransport,
        wait: (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    ) async throws -> [HighlightedBook] {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, token.allSatisfy({ $0.isASCII && !$0.isWhitespace }) else { throw ReadwiseError.refused }
        var found: [HighlightedBook] = []
        var cursor: String?
        var waited: TimeInterval = 0
        var page = 0
        while page < mostPages {
            var parts = URLComponents()
            parts.scheme = "https"
            parts.host = host
            parts.path = "/api/v2/export/"
            var query: [URLQueryItem] = []
            if let cursor { query.append(URLQueryItem(name: "pageCursor", value: cursor)) }
            if let updatedAfter {
                query.append(URLQueryItem(name: "updatedAfter", value: ISO8601DateFormatter().string(from: updatedAfter)))
            }
            parts.queryItems = query.isEmpty ? nil : query
            guard let url = parts.url else { throw ReadwiseError.unreadable }
            var request = URLRequest(url: url)
            request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, status): (Data, Int)
            do {
                (data, status) = try await transport.send(request)
            } catch {
                throw ReadwiseError.notReachable
            }
            if status == 429 {
                // Readwise says how long; the app waits, within reason, and asks again.
                let pause: TimeInterval = 20
                waited += pause
                guard waited <= longestWait else { throw ReadwiseError.busy }
                await wait(pause)
                continue
            }
            guard status != 401, status != 403 else { throw ReadwiseError.refused }
            guard status == 200, let answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let results = answer["results"] as? [Any]
            else { throw ReadwiseError.unreadable }
            found += results.compactMap(book)
            page += 1
            if let next = answer["nextPageCursor"] as? String, !next.isEmpty {
                cursor = next
            } else if let next = answer["nextPageCursor"] as? NSNumber {
                cursor = next.stringValue
            } else {
                break
            }
        }
        return found
    }

    /// One of Readwise's sources as a book with its highlights; nil for anything it
    /// does not file under books, for one with no title, and for one marked deleted.
    static func book(from item: Any) -> HighlightedBook? {
        guard let item = item as? [String: Any], (item["category"] as? String) == "books",
              (item["is_deleted"] as? Bool) != true,
              let title = LookupText.cleaned(item["title"] as? String, limit: LookupText.lineLimit)
        else { return nil }
        var book = HighlightedBook(
            title: title, authors: authors(item["author"] as? String), source: .readwise,
            highlights: (item["highlights"] as? [Any] ?? []).compactMap(highlight))
        if let asin = LookupText.cleaned(item["asin"] as? String, limit: 20) { book.itemId = asin }
        // What came from a Kindle is owned as a Kindle book.
        if (item["source"] as? String)?.lowercased() == "kindle" { book.ownedOn = .kindle }
        if let address = item["cover_image_url"] as? String, let url = URL(string: address), url.scheme == "https" {
            book.coverURL = url
        }
        return book
    }

    /// The people in one line of names: "A, B, and C", "A and B", "A; B".
    static func authors(_ line: String?) -> [String] {
        guard let line = LookupText.cleaned(line, limit: LookupText.lineLimit) else { return [] }
        let parted = line.replacingOccurrences(of: ", and ", with: ";").replacingOccurrences(of: " and ", with: ";")
            .replacingOccurrences(of: " & ", with: ";").replacingOccurrences(of: ",", with: ";")
        return parted.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func highlight(from item: Any) -> IncomingHighlight? {
        guard let item = item as? [String: Any], let id = (item["id"] as? NSNumber)?.stringValue ?? (item["id"] as? String)
        else { return nil }
        var highlight = IncomingHighlight(
            sourceId: id, text: (item["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        highlight.isDeleted = (item["is_deleted"] as? Bool) == true || (item["is_discard"] as? Bool) == true
        let note = (item["note"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        highlight.note = note.isEmpty ? nil : note
        highlight.location = (item["location"] as? NSNumber)?.doubleValue
        highlight.endLocation = (item["end_location"] as? NSNumber)?.doubleValue
        switch (item["location_type"] as? String)?.lowercased() {
        case "page": highlight.locationKind = .page
        case "location": highlight.locationKind = .location
        case "time_offset": highlight.locationKind = .time
        default: highlight.locationKind = highlight.location == nil ? nil : .order
        }
        highlight.madeAt = ((item["highlighted_at"] as? String) ?? (item["created_at"] as? String))
            .flatMap(AudibleLibraryReader.date)
        highlight.colour = LookupText.cleaned(item["color"] as? String, limit: 30)
        if let address = (item["readwise_url"] as? String) ?? (item["url"] as? String), URL(string: address)?.scheme == "https" {
            highlight.link = address
        }
        highlight.isFavourite = (item["is_favorite"] as? Bool) == true
        highlight.tags = (item["tags"] as? [Any] ?? []).prefix(30).compactMap {
            LookupText.cleaned(($0 as? [String: Any])?["name"] as? String, limit: 80)
        }
        // A highlight with no words and no note says nothing.
        guard highlight.isDeleted || !highlight.text.isEmpty || highlight.note != nil else { return nil }
        return highlight
    }
}

/// Reads the marks made in a book while listening, from the Audible account.
public enum AudibleMarksReader {
    static let host = "cde-ta-g7g.amazon.com"

    /// The bookmarks, clips and notes of one book, as highlights placed by time. A
    /// book Audible has no marks for gives none.
    public static func marks(
        asin: String, account: AudibleAccount, transport: any AudibleTransport
    ) async throws -> [IncomingHighlight] {
        guard asin.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }), !asin.isEmpty else { return [] }
        let path = "/FionaCDEServiceEngine/sidecar?type=AUDI&key=\(asin)"
        guard let url = URL(string: "https://\(host)\(path)") else { return [] }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in try AudibleSigner.headers(method: "GET", path: path, account: account) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let (data, status) = try await transport.send(request)
        if status == 401 || status == 403 { throw AudibleAccountError.refused(status) }
        guard status == 200, let answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let records = (answer["payload"] as? [String: Any])?["records"] as? [Any]
        else { return [] }
        return marks(from: records)
    }

    /// The records of one book as highlights. A clip and a note made on it are one
    /// highlight; the place last heard is no mark.
    static func marks(from records: [Any]) -> [IncomingHighlight] {
        var found: [IncomingHighlight] = []
        var notes: [String: String] = [:]
        let records = records.compactMap { $0 as? [String: Any] }
        for record in records where (record["type"] as? String) == "audible.note" {
            if let start = record["startPosition"] as? String, let text = record["text"] as? String { notes[start] = text }
        }
        for record in records {
            guard let kind = record["type"] as? String, kind == "audible.clip" || kind == "audible.bookmark",
                  let id = record["annotationId"] as? String,
                  let start = (record["startPosition"] as? String).flatMap(Double.init), start >= 0
            else { continue }
            var highlight = IncomingHighlight(sourceId: id, text: "")
            highlight.location = start / 1000
            if kind == "audible.clip", let end = (record["endPosition"] as? String).flatMap(Double.init), end > start {
                highlight.endLocation = end / 1000
            }
            highlight.locationKind = .time
            let meta = record["metadata"] as? [String: Any]
            let note = ((meta?["note"] as? String) ?? notes[record["startPosition"] as? String ?? ""] ?? (meta?["title"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            highlight.note = note.isEmpty ? nil : note
            highlight.madeAt = (record["creationTime"] as? String).flatMap(time)
            found.append(highlight)
        }
        return found.sorted { ($0.location ?? 0) < ($1.location ?? 0) }
    }

    /// "2026-09-18 10:21:35.0", in UTC.
    static func time(_ text: String) -> Date? {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(identifier: "UTC")
        format.dateFormat = "yyyy-MM-dd HH:mm:ss.S"
        return format.date(from: text)
    }
}

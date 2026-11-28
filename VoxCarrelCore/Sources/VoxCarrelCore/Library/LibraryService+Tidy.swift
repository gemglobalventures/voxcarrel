import Foundation
import ImageIO

/// One thing that can be untidy about a library, looked for across all of it.
public enum TidyCheck: String, CaseIterable, Sendable {
    case noAuthor, noYear, noDescription, noCover, smallCover
    case seriesNoNumber, seriesSameNumber, seriesGap
    case nameSpellings, titleExtras
    case sameBookTwice, formsApart, editionsNotLinked
    case oldFormat
    /// Not untidy, but worth a list of its own: books kept where their files are.
    case outsideLibrary
    /// Not untidy either: audiobooks kept as several audio files. Listed only where
    /// something can make one file of them (`isShownOnlyWhereActedOn`).
    case manyAudioFiles

    /// True for a check that names no fault, only a state of things that some would
    /// rather change: it is listed only where something offers to change it, and
    /// looked for only when asked for by name (`tidyReport(including:)`). Nobody is
    /// shown a list they can do nothing about.
    public var isShownOnlyWhereActedOn: Bool {
        self == .manyAudioFiles
    }

    /// What the check is called where it is listed.
    public var title: String {
        switch self {
        case .noAuthor: "No Author"
        case .noYear: "No Year"
        case .noDescription: "No Description"
        case .noCover: "No Cover"
        case .smallCover: "Small Cover"
        case .seriesNoNumber: "In a Series, No Number"
        case .seriesSameNumber: "One Number, Two Books"
        case .seriesGap: "Gaps in a Series"
        case .nameSpellings: "A Name Spelled Two Ways"
        case .titleExtras: "Extra Words in the Title"
        case .sameBookTwice: "The Same Book Twice"
        case .formsApart: "Audiobook and Ebook Apart"
        case .editionsNotLinked: "Editions Not Linked"
        case .oldFormat: "Older Ebook Formats"
        case .outsideLibrary: "Outside the Library Folder"
        case .manyAudioFiles: "Audio in Parts"
        }
    }

    /// What it means and what can be done, in a sentence or two.
    public var explanation: String {
        switch self {
        case .noAuthor: "These books have no author. Look one up, or edit it in the inspector."
        case .noYear: "These books have no year. A lookup usually supplies one."
        case .noDescription: "These books have no description. A lookup usually supplies one."
        case .noCover: "These books have no cover of their own, and are shown with one made for them. Look a book up, or drop a picture on it."
        case .smallCover: "These covers are under \(LibraryService.smallCoverSide) pixels on their longer side, and look soft at full size. Look the book up for a larger one, or drop a picture on it."
        case .seriesNoNumber: "These books are in a series and have no number in it, so they sort last. Show the series and check it against a list, or number them in the inspector."
        case .seriesSameNumber: "In each of these series two books have the same number. One of them is probably wrong, unless they are editions of one book: then link them."
        case .seriesGap: "The numbers of these series skip one or more. A book may be missing, or numbered wrongly: show the series and check it against a list to see which."
        case .nameSpellings: "The same author or narrator is written more than one way across these books, so they are listed as different people. Select the books and give them one spelling."
        case .titleExtras: "These titles carry words that belong elsewhere: \"(Unabridged)\", \"A Novel\", or the series and its number."
        case .sameBookTwice: "Each of these has the same title and author as another entry, and nothing tells the two apart. If they are one book, select both and choose Merge Books."
        case .formsApart: "Each of these is an audiobook or an ebook whose other form is filed as a separate entry. Select both and choose Merge Books to make them one book."
        case .editionsNotLinked: "Each of these has the same title and author as another entry but is another edition: another language, narrator or kind. Select both and choose Link as Editions of One Book."
        case .outsideLibrary: "These books were added where their files are, and are kept there: nothing of theirs has been moved or changed, and their details are kept in the catalogue alone. Select them and choose Book > Bring into the Library to copy or move them in."
        case .manyAudioFiles: "Each of these audiobooks is kept as several audio files. They can be left as they are; one file with a chapter for each part is easier to move, send and resume."
        case .oldFormat: "These books have an ebook in an older format (MOBI, AZW3 and the like) and no EPUB. Convert to EPUB adds one beside it."
        }
    }
}

extension LibraryService {
    /// What is untidy about the library: for each check, the books it finds, lowest id
    /// first. Checks that find nothing are left out, and so is every book the owner has
    /// let off a check. Asks nothing of the network and opens no book's file; a cover's
    /// size is read from its picture once, and again only when the picture changes.
    /// Inside `BookScope.visible`, hidden books are not looked at.
    public func tidyFindings(including asked: Set<TidyCheck> = []) throws -> [TidyCheck: [Int64]] {
        try tidyReport(including: asked).found
    }

    /// The same, and with it the books each check would list had the owner not let them
    /// off it: the ones that can be put back.
    ///
    /// - Parameter asked: The checks shown only where acted on that are wanted too. The
    ///   others of that kind are not looked for, and are in neither list.
    public func tidyReport(including asked: Set<TidyCheck> = []) throws
        -> (found: [TidyCheck: [Int64]], letOff: [TidyCheck: [Int64]])
    {
        let books = try store.books()
        let ignored = try store.tidyIgnored()
        var roles: [Int64: Set<FileRole>] = [:]
        var formats: [Int64: Set<FileFormat>] = [:]
        var audioFiles: [Int64: Int] = [:]
        for file in try store.allFiles() {
            guard let id = file.bookId else { continue }
            roles[id, default: []].insert(file.role)
            if file.role == .ebook { formats[id, default: []].insert(file.format) }
            if file.role == .audio { audioFiles[id, default: 0] += 1 }
        }
        let allCovers = covers.all()
        let withCover = Set(allCovers.keys)
        var found: [TidyCheck: Set<Int64>] = [:]
        func blank(_ text: String?) -> Bool { (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        // Details.
        for book in books {
            guard let id = book.id else { continue }
            if book.authors.allSatisfy({ blank($0) }) { found[.noAuthor, default: []].insert(id) }
            if book.year == nil { found[.noYear, default: []].insert(id) }
            if blank(book.summary) { found[.noDescription, default: []].insert(id) }
            // A book with no files here is shown with whatever its source gave.
            if !withCover.contains(id), roles[id] != nil { found[.noCover, default: []].insert(id) }
            if let cover = allCovers[id], let side = coverLongSide(of: cover.url, modified: cover.modified),
               side < Self.smallCoverSide {
                found[.smallCover, default: []].insert(id)
            }
            if Self.titleHasExtras(book) { found[.titleExtras, default: []].insert(id) }
            if book.keptOutside { found[.outsideLibrary, default: []].insert(id) }
            if asked.contains(.manyAudioFiles), (audioFiles[id] ?? 0) > 1 { found[.manyAudioFiles, default: []].insert(id) }
            let own = formats[id] ?? []
            if !own.isEmpty, !own.contains(.epub), !own.contains(.pdf) { found[.oldFormat, default: []].insert(id) }
        }

        // Series.
        var series: [String: [Book]] = [:]
        for book in books where !blank(book.series) {
            series[book.series!.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), default: []].append(book)
        }
        for members in series.values {
            var byNumber: [Double: [Book]] = [:]
            for book in members {
                guard let id = book.id else { continue }
                guard let number = SeriesNumber.value(book.seriesNumber) else {
                    if blank(book.seriesNumber) { found[.seriesNoNumber, default: []].insert(id) }
                    continue
                }
                byNumber[number, default: []].append(book)
            }
            for sharing in byNumber.values where sharing.count > 1 {
                // Editions of one work rightly share a number.
                let works = Set(sharing.map { $0.workKey ?? "alone \($0.id ?? 0)" })
                if works.count > 1 { for book in sharing { if let id = book.id { found[.seriesSameNumber, default: []].insert(id) } } }
            }
            let whole = byNumber.keys.filter { $0 == $0.rounded() && $0 >= 1 }.map { Int($0) }
            if let first = whole.min(), let last = whole.max(), last - first + 1 > Set(whole).count, last - first < 200 {
                for book in members { if let id = book.id { found[.seriesGap, default: []].insert(id) } }
            }
        }

        // Names: one person written more than one way.
        var spellings: [String: Set<String>] = [:]
        for book in books {
            for name in book.authors + book.narrators where !blank(name) {
                let key = KnownNames.authorKey(name)
                if !key.isEmpty { spellings[key, default: []].insert(name.trimmingCharacters(in: .whitespacesAndNewlines)) }
            }
        }
        let varied = Set(spellings.filter { $0.value.count > 1 }.keys)
        if !varied.isEmpty {
            for book in books {
                guard let id = book.id else { continue }
                if (book.authors + book.narrators).contains(where: { varied.contains(KnownNames.authorKey($0)) }) {
                    found[.nameSpellings, default: []].insert(id)
                }
            }
        }

        // The same title by the same author, more than once.
        var alike: [String: [Book]] = [:]
        for book in books {
            let title = LookupText.comparable(book.title).joined(separator: " ")
            let author = KnownNames.authorKey(book.authors.first ?? "")
            guard !title.isEmpty, !author.isEmpty else { continue }
            alike[title + "|" + author, default: []].append(book)
        }
        for group in alike.values where group.count > 1 {
            for (index, book) in group.enumerated() {
                for other in group[(index + 1)...] {
                    guard let a = book.id, let b = other.id else { continue }
                    // Tied already as editions: nothing to say.
                    if let key = book.workKey, key == other.workKey { continue }
                    let check: TidyCheck
                    if Self.differAsEditions(book, other) != nil {
                        check = .editionsNotLinked
                    } else if let first = roles[a], let second = roles[b], first.isDisjoint(with: second),
                              first.union(second).isSuperset(of: [.audio, .ebook]) {
                        check = .formsApart
                    } else {
                        check = .sameBookTwice
                    }
                    found[check, default: []].formUnion([a, b])
                }
            }
        }

        var result: [TidyCheck: [Int64]] = [:]
        var letOff: [TidyCheck: [Int64]] = [:]
        for (check, ids) in found {
            let off = ignored[check.rawValue] ?? []
            let left = ids.subtracting(off)
            if !left.isEmpty { result[check] = left.sorted() }
            let spared = ids.intersection(off)
            if !spared.isEmpty { letOff[check] = spared.sorted() }
        }
        return (result, letOff)
    }

    /// For a check that finds books by what they share (the same book twice, its forms
    /// filed apart, editions not linked): the books it lists, in the groups that share a
    /// title and an author, each of two or more, lowest id first. Empty for any other check.
    public func tidyGroups(for check: TidyCheck) throws -> [[Int64]] {
        guard [.sameBookTwice, .formsApart, .editionsNotLinked].contains(check) else { return [] }
        let listed = Set(try tidyFindings()[check] ?? [])
        var groups: [String: [Int64]] = [:]
        for book in try store.books() {
            guard let id = book.id, listed.contains(id) else { continue }
            let title = LookupText.comparable(book.title).joined(separator: " ")
            groups[title + "|" + KnownNames.authorKey(book.authors.first ?? ""), default: []].append(id)
        }
        return groups.values.filter { $0.count >= 2 }.map { $0.sorted() }.sorted { $0[0] < $1[0] }
    }

    /// A cover shorter than this on its longer side is a small one.
    public static let smallCoverSide = 600

    /// The longer side of a cover in pixels; nil when the picture cannot be read. Only
    /// the picture's header is read, and what is learned is kept until it changes.
    func coverLongSide(of url: URL, modified: Date) -> Int? {
        if let known = coverSides[url.path], known.modified == modified { return known.side }
        var side: Int?
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int,
           let height = properties[kCGImagePropertyPixelHeight] as? Int {
            side = max(width, height)
        }
        coverSides[url.path] = (modified, side)
        return side
    }

    /// Whether a title carries words that belong elsewhere: what kind of edition it
    /// is, that it is a novel, or its own series and number.
    static func titleHasExtras(_ book: Book) -> Bool {
        let title = book.title.lowercased()
        for extra in ["(unabridged)", "[unabridged]", "(abridged)", "[abridged]", ": a novel", "(a novel)", " - a novel", "(audiobook)", "[audiobook]"]
        where title.contains(extra) { return true }
        if title.hasSuffix(" a novel") { return true }
        // "…, Book 3" or "… (Book 3)", and the series' own name in brackets.
        if title.range(of: #"[\(\[,:-]\s*book\s+\d+"#, options: .regularExpression) != nil { return true }
        if let series = book.series?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), series.count > 3,
           title.contains("(" + series) || title.contains("[" + series) {
            return true
        }
        return false
    }

    /// Lets books off a check of the library's tidiness, or puts them back under it.
    public func setTidyIgnored(_ ignored: Bool, check: TidyCheck, bookIds: [Int64]) throws {
        try store.setTidyIgnored(ignored, check: check.rawValue, bookIds: bookIds)
    }
}

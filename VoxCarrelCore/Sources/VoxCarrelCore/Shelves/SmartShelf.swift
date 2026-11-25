import Foundation

/// Which forms of a book a shelf asks for.
public enum ShelfFormat: String, Codable, Sendable, CaseIterable {
    case audiobook, ebook, both
}

/// One thing a smart shelf asks of a book.
public enum ShelfCondition: Codable, Equatable, Hashable, Sendable {
    case format(ShelfFormat)
    case status(ReadStatus)
    case genre(String)
    case genreGroup(GenreGroup)
    case author(String)
    case narrator(String)
    case series(String)
    case tag(String)
    /// Rated this many stars or more.
    case ratingAtLeast(Int)
    case unrated
    case shorterThan(hours: Double)
    case longerThan(hours: Double)
    /// Published in this year or later.
    case yearFrom(Int)
    /// Published in this year or earlier.
    case yearTo(Int)
    case addedWithin(days: Int)
    case onAudible(Bool)
    /// Whether the book is in a series at all.
    case inASeries(Bool)
}

/// A saved set of conditions. The books on it are worked out when it is looked at.
public struct SmartShelf: Codable, Equatable, Identifiable, Sendable {
    public var id: Int64?
    public var name: String
    /// True when a book must meet every condition; false when any one will do.
    public var matchesAll: Bool
    public var conditions: [ShelfCondition]

    public init(id: Int64? = nil, name: String, matchesAll: Bool = true, conditions: [ShelfCondition]) {
        self.id = id
        self.name = name
        self.matchesAll = matchesAll
        self.conditions = conditions
    }

    /// The shelves a library begins with. They can be changed and deleted like any other.
    public static let starters: [SmartShelf] = [
        SmartShelf(name: "Short Listens", conditions: [.format(.audiobook), .status(.unread), .shorterThan(hours: 6)]),
        SmartShelf(name: "Recently Added", conditions: [.addedWithin(days: 30)]),
        SmartShelf(name: "Finished, Not Rated", conditions: [.status(.finished), .unrated]),
    ]
}

/// A book as a shelf's conditions see it.
public struct ShelfBook: Sendable {
    public var book: Book
    /// The book has an audio file, or is owned elsewhere as an audiobook.
    public var hasAudio: Bool
    /// The book has an ebook file, or is owned elsewhere as an ebook.
    public var hasEbook: Bool
    /// The groups its genres belong to.
    public var genreGroups: Set<GenreGroup>

    public init(book: Book, hasAudio: Bool, hasEbook: Bool, genreGroups: Set<GenreGroup>) {
        self.book = book
        self.hasAudio = hasAudio
        self.hasEbook = hasEbook
        self.genreGroups = genreGroups
    }
}

extension ShelfCondition {
    /// Whether a book meets this condition. Names are compared without regard to
    /// case or to spaces at the ends. A book with no stated length is neither shorter
    /// nor longer than anything, and one with no year is in no span of years.
    public func isMet(by item: ShelfBook, now: Date) -> Bool {
        let book = item.book
        func has(_ names: [String], _ wanted: String) -> Bool {
            let key = wanted.trimmingCharacters(in: .whitespaces).lowercased()
            return !key.isEmpty && names.contains { $0.trimmingCharacters(in: .whitespaces).lowercased() == key }
        }
        switch self {
        case .format(.audiobook): return item.hasAudio
        case .format(.ebook): return item.hasEbook
        case .format(.both): return item.hasAudio && item.hasEbook
        case .status(let status): return book.readStatus == status
        case .genre(let name): return has(book.genres, name)
        case .genreGroup(let group): return item.genreGroups.contains(group)
        case .author(let name): return has(book.authors, name)
        case .narrator(let name): return has(book.narrators, name)
        case .series(let name): return has([book.series ?? ""], name)
        case .tag(let name): return has(book.tags, name)
        case .ratingAtLeast(let stars): return book.rating >= max(1, stars)
        case .unrated: return book.rating <= 0
        case .shorterThan(let hours):
            guard let seconds = book.durationSeconds, seconds > 0 else { return false }
            return seconds < hours * 3600
        case .longerThan(let hours):
            guard let seconds = book.durationSeconds, seconds > 0 else { return false }
            return seconds > hours * 3600
        case .yearFrom(let year): return book.year.map { $0 >= year } ?? false
        case .yearTo(let year): return book.year.map { $0 <= year } ?? false
        case .addedWithin(let days):
            return book.dateAdded >= now.addingTimeInterval(-Double(max(0, days)) * 86_400)
        case .onAudible(let wanted): return book.externalCopies.contains { $0.kind == .audible } == wanted
        case .inASeries(let wanted):
            return !(book.series ?? "").trimmingCharacters(in: .whitespaces).isEmpty == wanted
        }
    }
}

extension SmartShelf {
    /// Whether a book belongs on the shelf. A shelf with no conditions holds nothing:
    /// it has not said what it wants.
    public func holds(_ item: ShelfBook, now: Date) -> Bool {
        guard !conditions.isEmpty else { return false }
        return matchesAll
            ? conditions.allSatisfy { $0.isMet(by: item, now: now) }
            : conditions.contains { $0.isMet(by: item, now: now) }
    }
}

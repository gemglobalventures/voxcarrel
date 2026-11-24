import Foundation

/// The groups genres are listed under. They are fixed.
public enum GenreGroup: String, Codable, Sendable, CaseIterable {
    case fiction, nonFiction, children, other
}

/// A genre of the list the app ships with.
public struct BuiltInGenre: Equatable, Sendable {
    public let name: String
    public let group: GenreGroup
    /// A genre that says little, and gives way when a source names another as well.
    public let isGeneral: Bool

    /// The built-in list, in the order it is shown.
    public static let all: [BuiltInGenre] = [
        BuiltInGenre(name: Name.literary, group: .fiction, isGeneral: true),
        BuiltInGenre(name: Name.classics, group: .fiction, isGeneral: false),
        BuiltInGenre(name: Name.crime, group: .fiction, isGeneral: false),
        BuiltInGenre(name: Name.thrillers, group: .fiction, isGeneral: false),
        BuiltInGenre(name: Name.scienceFiction, group: .fiction, isGeneral: false),
        BuiltInGenre(name: Name.fantasy, group: .fiction, isGeneral: false),
        BuiltInGenre(name: Name.historical, group: .fiction, isGeneral: false),
        BuiltInGenre(name: Name.romance, group: .fiction, isGeneral: false),
        BuiltInGenre(name: Name.horror, group: .fiction, isGeneral: false),
        BuiltInGenre(name: Name.humour, group: .fiction, isGeneral: false),
        BuiltInGenre(name: Name.biography, group: .nonFiction, isGeneral: false),
        BuiltInGenre(name: Name.history, group: .nonFiction, isGeneral: false),
        BuiltInGenre(name: Name.politics, group: .nonFiction, isGeneral: false),
        BuiltInGenre(name: Name.business, group: .nonFiction, isGeneral: false),
        BuiltInGenre(name: Name.money, group: .nonFiction, isGeneral: false),
        BuiltInGenre(name: Name.science, group: .nonFiction, isGeneral: false),
        BuiltInGenre(name: Name.technology, group: .nonFiction, isGeneral: false),
        BuiltInGenre(name: Name.health, group: .nonFiction, isGeneral: false),
        BuiltInGenre(name: Name.selfDevelopment, group: .nonFiction, isGeneral: false),
        BuiltInGenre(name: Name.philosophy, group: .nonFiction, isGeneral: false),
        BuiltInGenre(name: Name.arts, group: .nonFiction, isGeneral: false),
        BuiltInGenre(name: Name.travel, group: .nonFiction, isGeneral: false),
        BuiltInGenre(name: Name.sports, group: .nonFiction, isGeneral: false),
        BuiltInGenre(name: Name.trueCrime, group: .nonFiction, isGeneral: false),
        BuiltInGenre(name: Name.reference, group: .nonFiction, isGeneral: true),
        BuiltInGenre(name: Name.children, group: .children, isGeneral: false),
        BuiltInGenre(name: Name.youngAdult, group: .children, isGeneral: false),
    ]

    /// The built-in genre of this name, compared as `GenreName.same` does once the
    /// name is tidied; nil when there is none.
    public static func named(_ name: String) -> BuiltInGenre? {
        guard let tidy = GenreName.valid(name) else { return nil }
        return all.first { GenreName.same($0.name, tidy) }
    }

    /// The built-in names, written once.
    enum Name {
        static let literary = "Literary & General"
        static let classics = "Classics"
        static let crime = "Crime & Mystery"
        static let thrillers = "Thrillers & Spies"
        static let scienceFiction = "Science Fiction"
        static let fantasy = "Fantasy"
        static let historical = "Historical Fiction"
        static let romance = "Romance"
        static let horror = "Horror"
        static let humour = "Humour"
        static let biography = "Biography & Memoir"
        static let history = "History"
        static let politics = "Politics & Society"
        static let business = "Business & Careers"
        static let money = "Money & Investing"
        static let science = "Science & Nature"
        static let technology = "Technology"
        static let health = "Health & Mind"
        static let selfDevelopment = "Self-Development"
        static let philosophy = "Philosophy & Religion"
        static let arts = "Arts & Culture"
        static let travel = "Travel & Places"
        static let sports = "Sports & Outdoors"
        static let trueCrime = "True Crime"
        static let reference = "Reference & Learning"
        static let children = "Children"
        static let youngAdult = "Young Adult"
    }
}

/// The rules every genre name keeps, built in or the owner's own.
public enum GenreName {
    /// The marks that part one genre from the next in a file's tag. No name may hold one.
    static let separators: Set<Character> = [",", ";", "/"]

    /// Trimmed, runs of spaces made one; nil when empty or holding "," ";" or "/".
    public static func valid(_ text: String) -> String? {
        let tidy = tidied(text)
        guard !tidy.isEmpty, !tidy.contains(where: separators.contains) else { return nil }
        return tidy
    }

    /// Whether two names are the same genre: compared without regard to case.
    public static func same(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: .caseInsensitive) == .orderedSame
    }

    /// Trimmed, runs of spaces made one.
    static func tidied(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

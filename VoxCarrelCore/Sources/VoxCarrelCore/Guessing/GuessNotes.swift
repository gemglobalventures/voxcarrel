import Foundation

/// What was guessed about a candidate book, for the review to say and to ask about.
public struct GuessNotes: OptionSet, Equatable, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// The title or the author came from a file's or folder's name, not from tags.
    public static let fromFileName = GuessNotes(rawValue: 1 << 0)
    /// A name "A - B" could not be told apart, and was read as "Author - Title".
    public static let orderUnsure = GuessNotes(rawValue: 1 << 1)
    /// A name "A - B" was read as "Title - Author".
    public static let orderSwapped = GuessNotes(rawValue: 1 << 2)
    /// The Audible ID came from a file's or folder's name.
    public static let audibleIDFromName = GuessNotes(rawValue: 1 << 3)
    /// The title read from a name is shaped like a person's name, and no author that is
    /// shaped like one came with it.
    public static let titleLooksLikePerson = GuessNotes(rawValue: 1 << 4)
}

/// The authors and titles a library already has, as evidence for reading a name
/// "A - B": each normalised with `authorKey` or `titleKey`.
public struct KnownNames: Equatable, Sendable {
    public var authors: Set<String>
    public var titles: Set<String>

    /// - Parameters:
    ///   - authors: Each one as `authorKey` gives it.
    ///   - titles: Each one as `titleKey` gives it.
    public init(authors: Set<String>, titles: Set<String>) {
        self.authors = authors
        self.titles = titles
    }

    /// Nothing known.
    public static let none = KnownNames(authors: [], titles: [])

    /// A person's name for comparing: lower-case words without accents or punctuation,
    /// in the order written. "J.R.R. Tolkien" and "j. r. r. tolkien" are the same.
    public static func authorKey(_ name: String) -> String {
        LookupText.comparable(name, droppingArticle: false).joined(separator: " ")
    }

    /// A title for comparing: `TitleMatch.core`.
    public static func titleKey(_ title: String) -> String {
        TitleMatch.core(title)
    }

    /// True when the text is one of the authors. Text with nothing to compare never is.
    func hasAuthor(_ text: String) -> Bool {
        let key = Self.authorKey(text)
        return !key.isEmpty && authors.contains(key)
    }

    /// True when the text is one of the titles. Text with nothing to compare never is.
    func hasTitle(_ text: String) -> Bool {
        let key = Self.titleKey(text)
        return !key.isEmpty && titles.contains(key)
    }
}

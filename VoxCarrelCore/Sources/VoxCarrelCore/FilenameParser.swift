import Foundation

/// What a file's or folder's name says about the book.
public struct FilenameGuess: Equatable, Sendable {
    public var title: String
    public var author: String?
    /// An Audible ID written in the name, or in the name of the book's own folder.
    public var asin: String?
    /// How the name was read. Always has `.fromFileName`.
    public var notes: GuessNotes

    public init(title: String, author: String? = nil, asin: String? = nil, notes: GuessNotes = [.fromFileName]) {
        self.title = title
        self.author = author
        self.asin = asin
        self.notes = notes
    }
}

/// Guesses a title and author from file and folder names.
public enum FilenameParser {
    /// Folder names (lowercased) that are places, not authors or books.
    static let genericFolders: Set<String> = [
        "downloads", "desktop", "documents", "audiobooks", "ebooks", "books",
    ]

    /// Reads the name, and the folders it is in.
    ///
    /// A name "A - B" (split at its first " - ") is an author and a title, in whichever
    /// order the evidence says: the side that is an author in `known` when only one is;
    /// failing that, the other side from the one that is a title in `known` when only
    /// one is; failing that, the side shaped like a person's name when only one is
    /// (but shape alone does not make an author of the second side when the first is
    /// one capitalised word, which may be a person named alone or by surname, or
    /// begins with an article, as the name of a group or a publisher may). An order
    /// that shape alone decided is noted `.orderGuessedByShape`, whichever it is. A name
    /// written all in lower case is never decided by shape.
    /// With nothing to go on it is read as "Author - Title" and noted `.orderUnsure`;
    /// read the other way it is noted `.orderSwapped`. A number before the dash is a
    /// part or series number, and the rest is the title.
    ///
    /// Any other name is the title, and the author is the folder it is in, unless that
    /// is a place such as Downloads. A title shaped like a person's name with no author
    /// beside it, or beside an author that is neither shaped like one nor known, is
    /// noted `.titleLooksLikePerson`.
    ///
    /// An Audible ID in the name is taken out of it and given as `asin`; failing that,
    /// one in the name of the folder that is this book's own. Underscores in what is
    /// read are tidied (`TitleMatch.tidyFromFileName`).
    ///
    /// - Parameters:
    ///   - url: A book file, or the folder that is the book.
    ///   - isFolder: True when `url` is a folder (its name keeps any dots).
    ///   - parentIsBookFolder: True when `url` is a file whose folder holds just
    ///     this one book, so the author is the folder above that one. A file in a
    ///     folder with its own name is treated this way without being told.
    ///   - known: The authors and titles already known, as evidence for "A - B".
    public static func guess(
        from url: URL, isFolder: Bool, parentIsBookFolder: Bool = false, known: KnownNames = .none
    ) -> FilenameGuess {
        let written = isFolder ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        var guess = FilenameGuess(title: "")

        // The Audible ID is no part of the title or the author. A name that is nothing
        // else is kept whole.
        var name = written
        if let found = AudibleIDInName.find(in: written) {
            guess.asin = found.id
            if !found.cleaned.isEmpty { name = found.cleaned }
        }

        var authorFolder = url.deletingLastPathComponent()
        if !isFolder,
           parentIsBookFolder || authorFolder.lastPathComponent.lowercased() == written.lowercased() {
            // The folder is this book's own: an ID in its name is the book's.
            if guess.asin == nil { guess.asin = AudibleIDInName.find(in: authorFolder.lastPathComponent)?.id }
            authorFolder = authorFolder.deletingLastPathComponent()
        }
        if guess.asin != nil { guess.notes.insert(.audibleIDFromName) }

        guess.title = tidy(name)
        if let range = name.range(of: " - ") {
            let before = tidy(String(name[..<range.lowerBound]))
            let after = tidy(String(name[range.upperBound...]))
            if !before.isEmpty, !after.isEmpty {
                // "01 - Chapter One" is a part or series number, not an author.
                guard before.allSatisfy(\.isWholeNumber) else {
                    read(before, after, known: known, into: &guess)
                    return guess
                }
                guess.title = after
            }
        }

        let parent = authorFolder.lastPathComponent
        if !parent.isEmpty, parent != "/", !genericFolders.contains(parent.lowercased()) {
            guess.author = tidy(parent)
        }
        if guess.author == nil, NameShape.looksLikePerson(guess.title) {
            guess.notes.insert(.titleLooksLikePerson)
        }
        return guess
    }

    private static func tidy(_ text: String) -> String {
        TitleMatch.tidyFromFileName(text).trimmingCharacters(in: .whitespaces)
    }

    /// Decides which side of "A - B" is the author.
    private static func read(_ a: String, _ b: String, known: KnownNames, into guess: inout FilenameGuess) {
        let shapes = (NameShape.looksLikePerson(a), NameShape.looksLikePerson(b))
        let authors = (known.hasAuthor(a), known.hasAuthor(b))
        let titles = (known.hasTitle(a), known.hasTitle(b))

        var authorIsFirst = true
        if authors.0 != authors.1 {
            authorIsFirst = authors.0
        } else if titles.0 != titles.1 {
            authorIsFirst = titles.1
        } else if shapes.0 != shapes.1, !(a + b).allSatisfy({ !$0.isUppercase }),
                  shapes.0 || !(NameShape.couldBeALoneName(a) || NameShape.beginsWithArticle(a)) {
            // Shape alone never turns round a first side that may be a lone name
            // ("Aristotle - Nicomachean Ethics", "Herbert - Dune Messiah"), nor one
            // that begins with an article and may be a group's or a publisher's name
            // ("The Great Courses - Ancient Greece", "The Beatles - Abbey Road").
            // And a name with no capital anywhere gives shape nothing to go by.
            authorIsFirst = shapes.0
            // A guess all the same, whichever way round it came out.
            guess.notes.insert(.orderGuessedByShape)
        } else {
            guess.notes.insert(.orderUnsure)
        }

        guess.author = authorIsFirst ? a : b
        guess.title = authorIsFirst ? b : a
        if !authorIsFirst { guess.notes.insert(.orderSwapped) }
        let titleIsShaped = authorIsFirst ? shapes.1 : shapes.0
        let authorIsShaped = authorIsFirst ? shapes.0 : shapes.1
        // An author the library knows is no cause for doubt, however the name is written.
        let authorIsKnown = authors.0 != authors.1
        if titleIsShaped, !authorIsShaped, !authorIsKnown { guess.notes.insert(.titleLooksLikePerson) }
    }
}

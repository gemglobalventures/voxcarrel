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
    /// part or series number, and the rest is the title, unless the rest is an author
    /// in `known` or the number a title in `known`: then it is read as any other name.
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
        if let read = downloadSiteName(name) {
            guess.title = read.title
            guess.author = read.author
            return guess
        }
        if let range = name.range(of: " - ") {
            let before = tidy(String(name[..<range.lowerBound]))
            let after = tidy(String(name[range.upperBound...]))
            if !before.isEmpty, !after.isEmpty {
                // "01 - Chapter One" is a part or series number, not an author; but
                // "1984 - George Orwell" is a title and an author when what is known
                // says so: the other side is a known author, or the number a known title.
                guard before.allSatisfy(\.isWholeNumber), !known.hasAuthor(after), !known.hasTitle(before) else {
                    read(before, after, known: known, into: &guess)
                    return guess
                }
                guess.title = after
            }
        }

        let parent = authorFolder.lastPathComponent
        if !parent.isEmpty, parent != "/", !genericFolders.contains(parent.lowercased()),
           folderIsAnAuthor(tidy(parent), known: known) {
            guess.author = tidy(parent)
        }
        if guess.author == nil, NameShape.looksLikePerson(guess.title) {
            guess.notes.insert(.titleLooksLikePerson)
        }
        return guess
    }

    /// Words that make a folder's name a subject or a heap, not a person.
    static let subjectWords: Set<String> = [
        "papers", "exchange", "trading", "investing", "investment", "books", "ebooks", "audiobooks", "collection",
        "stocks", "markets", "market", "finance", "financial", "business", "general", "misc", "various", "other",
        "new", "items", "library", "fiction", "history", "science", "analysis", "systems", "options", "futures",
        "bonds", "commodities", "psychology", "interviews", "courses", "course", "unsorted", "sorted", "read",
        "unread", "suggested", "reading", "kindle", "calibre", "torrents", "complete", "series", "volume",
        "inbox", "drop", "incoming", "import", "imports", "temp", "tmp", "staging", "queue", "todo", "shared",
        "public", "backup", "backups", "archive", "archives", "old", "stuff", "files", "media", "music", "home",
    ]

    /// True when the folder a book lies in can be taken for its author: a name the
    /// library has as an author, or one shaped like a person's (or one capitalised
    /// word, as a person named alone is written) with no word of a subject in it and
    /// no digit. "White
    /// Papers", "Foreign Exchange", "14 items" and "suggested stocktrader.com" are
    /// where books were put, not who wrote them.
    static func folderIsAnAuthor(_ name: String, known: KnownNames) -> Bool {
        if known.hasAuthor(name) { return true }
        guard NameShape.looksLikePerson(name) || NameShape.couldBeALoneName(name),
              !name.contains(where: \.isNumber) else { return false }
        let words = name.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        return !words.contains(where: subjectWords.contains)
    }

    /// A name as download sites write it: "Author-Title-Publisher (2014)", with an
    /// optional number and an optional series in brackets before it, and no spaces
    /// round the hyphens. The author is what stands before the first such hyphen
    /// (several, with commas, give the first), the title what stands between it and
    /// the publisher. Nil for any other name.
    static func downloadSiteName(_ name: String) -> (title: String, author: String)? {
        var text = name.trimmingCharacters(in: .whitespaces)
        // The year, in brackets at the end, is what marks the form.
        guard let open = text.lastIndex(of: "("), text.hasSuffix(")") else { return nil }
        let year = text[text.index(after: open)..<text.index(before: text.endIndex)]
        guard year.count == 4, year.allSatisfy(\.isNumber) else { return nil }
        text = String(text[..<open]).trimmingCharacters(in: .whitespaces)
        // A number, then a series in brackets, may come first.
        if let space = text.firstIndex(of: " "), text[..<space].allSatisfy(\.isNumber) {
            text = String(text[text.index(after: space)...]).trimmingCharacters(in: .whitespaces)
        }
        if text.hasPrefix("("), let close = text.firstIndex(of: ")") {
            text = String(text[text.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        }
        // Hyphens with a letter on both sides and no space divide the three parts.
        let characters = Array(text)
        var cuts: [Int] = []
        for i in characters.indices.dropFirst().dropLast()
        where characters[i] == "-" && characters[i - 1] != " " && characters[i + 1] != " "
            && (characters[i + 1].isUppercase || characters[i + 1].isNumber || characters[i + 1] == "[") {
            cuts.append(i)
        }
        guard cuts.count >= 2, let first = cuts.first, let last = cuts.last else { return nil }
        let authors = String(characters[..<first])
        let title = tidy(String(characters[(first + 1)..<last]))
        let author = tidy(authors.split(separator: ",").first.map(String.init) ?? authors)
        guard !title.isEmpty, NameShape.looksLikePerson(author) else { return nil }
        return (title, author)
    }

    private static func tidy(_ text: String) -> String {
        TitleMatch.tidyFromFileName(text).trimmingCharacters(in: .whitespaces)
    }

    /// Decides which side of "A - B" is the author.
    private static func read(_ first: String, _ second: String, known: KnownNames, into guess: inout FilenameGuess) {
        // "(Unabridged)" says which edition it is: no part of a person's name, and
        // nothing to judge a side by. It is set aside and goes with the title.
        let (a, tailA) = TitleMatch.settingAsideEditionWords(first)
        let (b, tailB) = TitleMatch.settingAsideEditionWords(second)
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
        guess.title = ([authorIsFirst ? b : a, tailA, tailB].filter { !$0.isEmpty }).joined(separator: " ")
        if !authorIsFirst { guess.notes.insert(.orderSwapped) }
        let titleIsShaped = authorIsFirst ? shapes.1 : shapes.0
        let authorIsShaped = authorIsFirst ? shapes.0 : shapes.1
        // An author the library knows is no cause for doubt, however the name is written.
        let authorIsKnown = authors.0 != authors.1
        if titleIsShaped, !authorIsShaped, !authorIsKnown { guess.notes.insert(.titleLooksLikePerson) }
    }
}

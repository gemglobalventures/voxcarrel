import Foundation

extension LibraryService {
    /// The library's list of genres, hidden ones included, each with the number of
    /// books that have it: by group, the built-in ones in their own order and then the
    /// owner's own by name.
    public func genreList() throws -> [GenreEntry] {
        try store.genreList()
    }

    /// The ids of the books that have this genre, whatever its place in their lists,
    /// sorted by title. Capitalisation does not count.
    public func books(inGenre name: String) throws -> [Int64] {
        try store.bookIds(inGenre: name)
    }

    /// The ids of the books with a genre of this group, each once, sorted by title.
    public func books(inGroup group: GenreGroup) throws -> [Int64] {
        try store.bookIds(inGroup: group)
    }

    /// The ids of the books with no genre, sorted by title.
    public func booksWithNoGenre() throws -> [Int64] {
        try store.bookIdsWithNoGenre()
    }

    /// The genres a file's tag gives in this library. A tag made only of names of the
    /// library's list, parted by semicolons, is taken as it is written, so a tag the
    /// app wrote reads back as the same genres in the same order, the owner's own among
    /// them; any other tag goes to the mapping, whole. Either way each name is then the
    /// one the library keeps for it (`listedGenres`). Every reading of a file's genre
    /// tag for this library comes through here.
    ///
    /// - Parameter asSubjects: True for an ebook's subjects (`GenreTag.genres`).
    public func genres(fromTag tag: String?, asSubjects: Bool = false) -> [String] {
        let listing = (try? store.genreListing()) ?? GenreListing(rows: [])
        return listing.names(GenreTag.genres(from: tag, listed: listing.rows.map(\.name), asSubjects: asSubjects))
    }

    /// Genres as this library keeps them on a book: no name twice, and each as the list
    /// has it. A name is spelled as the list spells it; a built-in genre that has been
    /// renamed is given by its new name, and one that has been merged away by the genre
    /// it was merged into. Names from the mapping and from lookups are built-in names,
    /// and come through here before they are stored or shown.
    public func listedGenres(_ names: [String]) -> [String] {
        ((try? store.genreListing()) ?? GenreListing(rows: [])).names(names)
    }

    /// The genre of the list that typed text is, without asking: the genre of that
    /// name, or the built-in genre the mapping knows the text as a name for ("Sci-Fi"),
    /// as the library now names it. Nil when the text is neither: it is then a new name.
    public func listedGenre(forTyped text: String) -> String? {
        let listing = (try? store.genreListing()) ?? GenreListing(rows: [])
        return Self.listedGenre(forTyped: text, in: listing)
    }

    static func listedGenre(forTyped text: String, in listing: GenreListing) -> String? {
        if let listed = listing.listed(text) { return listed }
        let mapped = GenreMapping.map(.text(text))
        guard mapped.unknown.isEmpty, mapped.builtIn.count == 1 else { return nil }
        return listing.listed(mapped.builtIn[0])
    }

    /// A file's details as this library reads them: its genres are what its tag gives
    /// here (`genres(fromTag:)`), and the tag itself is kept as the wording.
    func inLibrary(_ read: BookMetadata, from url: URL) -> BookMetadata {
        var details = read
        details.genres = genres(fromTag: read.genreSource, asSubjects: FileFormat(url: url) == .epub)
        return details
    }
}

/// Gives the scanner its tags by way of the library, which says what a genre tag comes
/// to here. Used within one scan, on the thread that makes it.
final class LibraryTagReader: MetadataReader, @unchecked Sendable {
    private let read: (URL) throws -> BookMetadata

    init(_ read: @escaping (URL) throws -> BookMetadata) {
        self.read = read
    }

    func readMetadata(at url: URL) throws -> BookMetadata {
        try read(url)
    }
}

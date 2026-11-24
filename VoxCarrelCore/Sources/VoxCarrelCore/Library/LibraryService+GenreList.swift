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
    /// them; any other tag goes to the mapping, whole. Every reading of a file's genre
    /// tag for this library comes through here.
    public func genres(fromTag tag: String?) -> [String] {
        GenreTag.genres(from: tag, listed: (try? store.genreNames()) ?? [])
    }

    /// Genres as this library keeps them on a book: no name twice, and each spelled as
    /// the list spells it where the list has it.
    func listedGenres(_ names: [String]) -> [String] {
        GenreName.spelled(names, as: (try? store.genreNames()) ?? [])
    }

    /// A file's details as this library reads them: its genres are what its tag gives
    /// here (`genres(fromTag:)`), and the tag itself is kept as the wording.
    func inLibrary(_ read: BookMetadata) -> BookMetadata {
        var details = read
        details.genres = genres(fromTag: read.genreSource)
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

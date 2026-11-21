import Foundation
import Testing
import VoxCarrelCore

/// A book with every editable field filled in, for the draft tests.
func fullBook(id: Int64 = 7, title: String = "Good Omens") -> Book {
    var metadata = BookMetadata(title: title, authors: ["Terry Pratchett", "Neil Gaiman"])
    metadata.subtitle = "The Nice and Accurate Prophecies"
    metadata.narrators = ["Martin Jarvis"]
    metadata.series = "Standalones"
    metadata.seriesNumber = "1.5"
    metadata.genre = "Fantasy"
    metadata.year = 1990
    metadata.publisher = "Gollancz"
    metadata.summary = "The world will end on Saturday."
    metadata.language = "en"
    metadata.isbn = "9780575048003"
    metadata.asin = "B0012345"
    metadata.durationSeconds = 45_000
    metadata.pageCount = 412
    var book = Book(metadata: metadata, dateAdded: Date(timeIntervalSinceReferenceDate: 0))
    book.id = id
    book.tags = ["funny", "apocalypse"]
    book.rating = 4
    return book
}

/// A book with nothing but a title.
func bareBook(id: Int64 = 8, title: String = "Bare") -> Book {
    var book = Book(metadata: BookMetadata(title: title), dateAdded: Date(timeIntervalSinceReferenceDate: 0))
    book.id = id
    return book
}

/// `BookEdit` is not Equatable: compares every field.
func expectSame(_ a: BookEdit?, _ b: BookEdit, sourceLocation: SourceLocation = #_sourceLocation) {
    guard let a else {
        Issue.record("no edit was made", sourceLocation: sourceLocation)
        return
    }
    #expect(a.bookId == b.bookId, sourceLocation: sourceLocation)
    #expect(a.metadata == b.metadata, sourceLocation: sourceLocation)
    #expect(a.tags == b.tags, sourceLocation: sourceLocation)
    #expect(a.rating == b.rating, sourceLocation: sourceLocation)
    #expect(a.cover == b.cover, sourceLocation: sourceLocation)
}

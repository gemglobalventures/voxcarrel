import Foundation

extension LibraryService {
    /// Counts the words of books whose EPUB has not been counted yet, a few at a time,
    /// so that it can be done behind other work.
    ///
    /// A book is counted from the first EPUB it has that is on disk. The count is kept
    /// with the book, and gives it a page count (`WordCount.pages`) when it has none
    /// from a PDF. A book whose EPUB cannot be read is recorded as tried (0 words) and
    /// not tried again; one whose EPUB is missing is left for another time.
    /// - Parameter limit: The most books to count in this call.
    /// - Returns: How many books were counted or recorded as tried. 0 when there is
    ///   nothing more to do for now.
    @discardableResult
    public func countWords(limit: Int = 20) throws -> Int {
        var done = 0
        for id in try store.bookIdsAwaitingWordCount(notAmong: wordCountPassedOver, limit: limit) {
            let epubs = try store.files(bookId: id).filter { $0.format == .epub }.map { store.url(for: $0) }
            guard let url = epubs.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
                wordCountPassedOver.insert(id)
                continue
            }
            let words = (try? EpubIO.wordCount(of: url)) ?? 0
            _ = try? store.modifyBook(id: id) { book, _ in
                book.wordCount = words
                if book.pageCount == nil { book.pageCount = WordCount.pages(forWords: words) }
            }
            done += 1
        }
        return done
    }

    /// The words in one EPUB file. For a caller that wants the figure without a library.
    public static func wordCount(ofEPUB url: URL) throws -> Int {
        try EpubIO.wordCount(of: url)
    }
}

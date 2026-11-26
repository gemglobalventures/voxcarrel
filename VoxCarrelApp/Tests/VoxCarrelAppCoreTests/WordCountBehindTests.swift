import Foundation
import Testing
import VoxCarrelCore
@testable import VoxCarrelAppCore

/// WB1: the words of a library's ebooks are counted behind its list, once it has been checked.
@MainActor @Suite struct WordCountBehindTests {
    @Test func WB1_ebooksAreCountedOnceTheLibraryIsOpen() async throws {
        let h = try await Harness.demo()
        #expect(h.model.libraryWasChecked)
        // The pass ends by itself when nothing is left to count.
        for _ in 0..<2_000 where h.model.isCountingWords {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(!h.model.isCountingWords)
        let worker = try #require(h.model.worker)
        let counted: [Int?] = try await worker.withService { service in
            try service.store.books().filter { book in
                guard let id = book.id else { return false }
                return try service.store.files(bookId: id).contains { $0.format == .epub }
            }.map(\.wordCount)
        }
        #expect(!counted.isEmpty && counted.allSatisfy { $0 != nil })
        // And nothing more is asked for.
        #expect(try await worker.countWords() == 0)
    }
}

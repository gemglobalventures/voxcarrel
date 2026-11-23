import Foundation
@testable import VoxCarrelCore

// The tests written when every library filed by one fixed rule ask where a book goes
// without naming a pattern or saying whether the book has audio. They are kept as they
// were written: here each such question is asked of the standard pattern, which files
// exactly as the fixed rule did and does not use `{Kind}`.

extension PathBuilder {
    /// The book's folder under the standard pattern.
    static func bookFolder(metadata: BookMetadata) -> String? {
        bookFolder(values: FolderPatternValues(metadata: metadata, hasAudio: false), pattern: .standard)
    }
}

extension Organiser {
    /// Destinations under the standard pattern.
    static func plan(files: [CandidateFile], metadata: BookMetadata, libraryRoot: URL) -> [PlannedMove]? {
        plan(files: files, metadata: metadata, pattern: .standard, libraryRoot: libraryRoot)
    }
}

extension LibraryService {
    /// The planned folder in a library whose pattern does not use `{Kind}`.
    func plannedFolder(for metadata: BookMetadata) -> String? {
        plannedFolder(for: metadata, hasAudio: false)
    }
}

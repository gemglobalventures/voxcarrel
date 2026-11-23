import Foundation
import VoxCarrelAppCore
import VoxCarrelCore

// The tests written when every library filed by one fixed rule ask where a book would
// be filed without saying whether it has audio. They are kept as they were written:
// here the question is asked for a library whose folder pattern does not use `{Kind}`,
// as the standard pattern does not.

extension LibraryService {
    func plannedFolder(for metadata: BookMetadata) -> String? {
        plannedFolder(for: metadata, hasAudio: false)
    }
}

extension LibraryWorker {
    func plannedFolder(for metadata: BookMetadata) -> String? {
        plannedFolder(for: metadata, hasAudio: false)
    }
}

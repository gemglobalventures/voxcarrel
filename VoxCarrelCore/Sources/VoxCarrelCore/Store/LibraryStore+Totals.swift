import Foundation
import GRDB

extension LibraryStore {
    /// The length of all the audio the library has, in seconds: the sum of what each
    /// book states. Books with no stated length count for nothing.
    public func totalAudioSeconds() throws -> Double {
        try dbQueue.read { db in
            try Double.fetchOne(db, sql: "SELECT COALESCE(SUM(durationSeconds), 0) FROM book") ?? 0
        }
    }
}

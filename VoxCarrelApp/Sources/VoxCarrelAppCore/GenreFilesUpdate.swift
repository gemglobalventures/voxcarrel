import Foundation
import Observation
import VoxCarrelCore

/// One book of the preview of "Update files…".
public struct GenreFilesRow: Identifiable, Equatable, Sendable {
    public var id: Int64
    public var title: String
    /// How many of its files will be written.
    public var fileCount: Int
    /// The genre tag its files hold, as the library last recorded it; "No tag" for none.
    public var tagNow: String
    /// The tag that will be written; "No tag" when it will be taken away.
    public var tagAfter: String

    /// "1 file", "4 files".
    public var filesText: String {
        fileCount == 1 ? "1 file" : "\(fileCount) files"
    }
}

/// G14: the state of the preview of "Update files…": the books whose files hold another
/// genre tag than the library would write, with the tag as it is and as it will be.
/// Nothing is written until `update()`.
@MainActor @Observable
public final class GenreFilesUpdate {
    @ObservationIgnored private unowned let model: AppModel

    /// The books whose files will be written, by title.
    public let rows: [GenreFilesRow]

    init(model: AppModel, differences: [LibraryService.GenreFileDifference]) {
        self.model = model
        rows = differences.map { difference in
            GenreFilesRow(
                id: difference.id, title: difference.title, fileCount: difference.fileCount,
                tagNow: difference.tagNow ?? Self.noTag, tagAfter: difference.tagAfter ?? Self.noTag)
        }
    }

    static let noTag = "No tag"

    /// "Update genre tags in 5 files of 3 books"
    public var title: String {
        guard !rows.isEmpty else { return "Update genre tags" }
        let files = rows.map(\.fileCount).reduce(0, +)
        return "Update genre tags in \(files == 1 ? "1 file" : "\(files) files") of "
            + (rows.count == 1 ? "1 book" : "\(rows.count) books")
    }

    /// The headings of the list. The tag as it is, is what the library last recorded
    /// of the files: they are not read again for the preview.
    public let columns = ["Book", "Tag recorded", "Tag after"]

    /// Each file is written whole, so anything else in it that differs is brought in line too.
    public let note = "Other details that differ from the library are written too."

    public let updateTitle = "Update"

    /// Said in place of the list when there is nothing to update.
    public var emptyText: String? {
        rows.isEmpty ? "Every file's genre tag matches the library." : nil
    }

    public var canUpdate: Bool {
        !rows.isEmpty && model.busyLabel == nil && model.filesCanChange
    }

    /// G14: writes the genres into the files, as one operation that Undo reverses, and
    /// closes the sheet. A file that could not be written is reported as other saves
    /// report it, and its book stays among those to update.
    public func update() async {
        guard canUpdate else { return }
        let ids = rows.map(\.id)
        let titles = Dictionary(rows.map { ($0.id, $0.title) }) { first, _ in first }
        let model = model
        model.genreFilesUpdate = nil
        await model.perform("Updating genre tags…") { worker in
            let summary = UserMessage.summary(of: try await worker.updateGenreFiles(ids), titles: titles)
            if !summary.isClean { model.result = summary }
        }
    }

    /// Closes the sheet. Nothing was written.
    public func cancel() {
        model.genreFilesUpdate = nil
    }
}

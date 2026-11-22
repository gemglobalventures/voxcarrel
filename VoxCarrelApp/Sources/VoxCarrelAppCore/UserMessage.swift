import Foundation
import VoxCarrelCore

/// What an operation did, worded for the person using the app.
public struct ResultSummary: Equatable, Sendable {
    /// For example "11 books imported, 1 needs attention".
    public var headline: String
    /// One per failed book or file.
    public var problems: [Line]
    /// Nothing the user needs to read.
    public var isClean: Bool

    public struct Line: Equatable, Sendable {
        public var title: String
        public var detail: String

        public init(title: String, detail: String) {
            self.title = title
            self.detail = detail
        }
    }

    public init(headline: String, problems: [Line], isClean: Bool) {
        self.headline = headline
        self.problems = problems
        self.isClean = isClean
    }
}

/// Every sentence the app shows about something that went wrong, or about how an
/// operation went. Written for someone who is not technical: no type names, no codes.
public enum UserMessage {
    // MARK: Errors

    public static func text(for error: Error) -> String {
        switch error {
        case let error as LibraryError: text(for: error)
        case let error as CollectionError: text(for: error)
        case let error as MetadataIOError: text(for: error)
        case let error as OrganiserError: text(for: error)
        case let error as LookupError: text(for: error, source: nil)
        case let error as WatchFolderError: text(for: error)
        case let error as SeriesListError: text(for: error)
        default:
            // The database's own errors are written for programmers.
            LibraryStore.isDatabaseError(error)
                ? "The library's database could not be read. It may be damaged, or not a VoxCarrel library."
                : error.localizedDescription
        }
    }

    /// Why Audible's list of a series could not be stored or changed.
    private static func text(for error: SeriesListError) -> String {
        switch error {
        case .emptyList: "Audible has no books listed for that series, so nothing was changed."
        case .noBooks: "No book in your library is in that series any more."
        case .entryNotFound: "That book is no longer on the list. Check the series again."
        }
    }

    private static func text(for error: WatchFolderError) -> String {
        switch error {
        case .notFound: "That watch folder is no longer in the list."
        }
    }

    private static func text(for error: LibraryError) -> String {
        switch error {
        case .bookNotFound:
            "That book is no longer in the library."
        case .fileNotFound:
            "That file is no longer in the library."
        case .invalidRole:
            "That kind of file cannot be used that way. An audio file is always part of the audiobook; "
                + "other files can be the ebook or an extra."
        case .nothingToUndo:
            "There is nothing to undo."
        case .undoBlocked(let reason):
            joined([
                "Undo could not put the files back, so nothing was changed.", sentence(reason),
                "Once that is sorted out, you can try Undo again.",
            ])
        case .rollbackIncomplete(let cause, let stranded):
            listed(
                [
                    "The change could not be made, and some files could not be put back where they came from.",
                    sentence(cause),
                    stranded.isEmpty ? "" : "These files are still in the library folder, but no book uses them:",
                ], stranded)
        case .cannotLocate(let reason):
            joined([
                "That file could not be used in place of the missing one, so nothing was changed.", sentence(reason),
            ])
        case .wouldLeaveNothing:
            "That book has no files, so it must stay marked as owned somewhere. Remove it instead."
        case .invalidDetails(let reason):
            sentence(reason)
        }
    }

    private static func text(for error: CollectionError) -> String {
        switch error {
        case .blankName: "A collection needs a name."
        case .notFound: "That collection no longer exists."
        }
    }

    private static func text(for error: MetadataIOError) -> String {
        switch error {
        case .unsupportedFormat(let type):
            "Files of type \"\(type)\" are not supported."
        case .unreadable(let file):
            "\(name(file)) could not be read. It may be damaged, or not the kind of file its name says."
        case .locked(let file):
            "\(name(file)) is locked, read-only or protected, so it could not be changed."
        case .notARegularFile(let file):
            "\(name(file)) is not an ordinary file, so it was left alone."
        case .verificationFailed(let reason):
            joined(["The changed file did not pass its checks, so the original was kept.", sentence(reason)])
        case .cleanupFailed(let path):
            "The file was left unchanged, but a working copy could not be removed. You can delete it yourself: \(path)"
        }
    }

    private static func text(for error: OrganiserError) -> String {
        switch error {
        case .destinationExists(let path):
            "There is already a file named \(name(path)) in that place, so nothing was replaced: \(path)"
        case .sourceMissing(let path):
            "The file \(name(path)) could not be found. It was expected here: \(path)"
        case .notARegularFile(let path):
            "\(name(path)) is not an ordinary file, so it was left alone."
        case .cannotBeChanged(let path):
            "\(name(path)) is locked, or its folder cannot be changed: \(path)"
        case .rollbackIncomplete(let cause, let outstanding):
            listed(
                [
                    "The files could not be moved, and some could not be put back where they came from.",
                    sentence(cause),
                    outstanding.isEmpty ? "" : "These files are not where they were:",
                ], outstanding.map { "\(name($0.from)) is now at \($0.to)" })
        }
    }

    /// Why a lookup source gave no answer: "Audible could not be reached."
    public static func text(for error: LookupError, source: LookupSource) -> String {
        text(for: error, source: Optional(source))
    }

    /// The same in a few words, to follow a source's name: "could not be reached".
    public static func shortText(for error: LookupError) -> String {
        switch error {
        case .notReachable: "could not be reached"
        case .refused: "answered with an error"
        case .unreadable: "sent an answer VoxCarrel could not read"
        }
    }

    private static func text(for error: LookupError, source: LookupSource?) -> String {
        let name = source?.title ?? "The lookup service"
        switch error {
        case .notReachable:
            return source == nil
                ? "\(name) could not be reached. Check your internet connection." : "\(name) could not be reached."
        case .refused: return "\(name) answered with an error."
        case .unreadable: return "\(name) sent an answer VoxCarrel could not read."
        }
    }

    // MARK: Summaries

    /// `titles` is parallel to the result's outcomes: one title per import item, in order.
    public static func summary(of result: ImportResult, titles: [String]) -> ResultSummary {
        var imported = 0
        var needAttention = 0
        var failed = 0
        var problems: [ResultSummary.Line] = []
        for (index, outcome) in result.outcomes.enumerated() {
            let title = shownTitle(index < titles.count ? titles[index] : nil)
            switch outcome {
            case .imported(_, let fileProblems):
                imported += 1
                problems += fileProblems.map { line(title, $0) }
            case .needsAttention:
                needAttention += 1
            case .failed(let reason):
                failed += 1
                problems.append(.init(title: title, detail: sentence(reason)))
            }
        }
        let headline = headline(
            [
                (imported, "imported", "imported"),
                (needAttention, "needs attention", "need attention"),
                (failed, "could not be imported", "could not be imported"),
            ], nothing: "Nothing was imported")
        // A book that needs attention has no line, but the user should still be told.
        return ResultSummary(headline: headline, problems: problems, isClean: problems.isEmpty && needAttention == 0)
    }

    /// `titles`: each book's title by its id.
    public static func summary(of outcomes: [SaveOutcome], titles: [Int64: String]) -> ResultSummary {
        var saved = 0
        var failed = 0
        var problems: [ResultSummary.Line] = []
        var files = 0
        for outcome in outcomes {
            switch outcome {
            // App-only fields are marked in the inspector; they are not a problem.
            case .saved(let bookId, _, _, let fileProblems):
                saved += 1
                files += fileProblems.count
                problems += fileProblems.map { line(shownTitle(titles[bookId]), $0) }
            case .failed(let bookId, let reason):
                failed += 1
                problems.append(.init(title: shownTitle(titles[bookId]), detail: sentence(reason)))
            }
        }
        var headline = headline(
            [(saved, "saved", "saved"), (failed, "could not be saved", "could not be saved")],
            nothing: "Nothing was saved")
        if files > 0 {
            headline += ", \(files) \(files == 1 ? "file" : "files") could not be updated"
        }
        return ResultSummary(headline: headline, problems: problems, isClean: problems.isEmpty)
    }

    /// What repairing length headers left undone. `titles`: each book's title by its id.
    public static func repairSummary(of outcomes: [SaveOutcome], titles: [Int64: String]) -> ResultSummary {
        var problems: [ResultSummary.Line] = []
        var files = 0
        var books = 0
        for outcome in outcomes {
            switch outcome {
            case .saved(let bookId, _, _, let fileProblems):
                files += fileProblems.count
                problems += fileProblems.map { line(shownTitle(titles[bookId]), $0) }
            case .failed(let bookId, let reason):
                books += 1
                problems.append(.init(title: shownTitle(titles[bookId]), detail: sentence(reason)))
            }
        }
        var parts: [String] = []
        if files > 0 { parts.append("\(files) \(files == 1 ? "file" : "files") could not be repaired") }
        if books > 0 { parts.append("\(books) \(books == 1 ? "book" : "books") could not be repaired") }
        return ResultSummary(
            headline: parts.isEmpty ? "Length headers repaired" : parts.joined(separator: ", "),
            problems: problems, isClean: problems.isEmpty)
    }

    // MARK: Field names

    public static func fieldName(_ field: MetadataField) -> String {
        switch field {
        case .title: "Title"
        case .subtitle: "Subtitle"
        case .authors: "Author"
        case .narrators: "Narrator"
        case .series: "Series"
        case .seriesNumber: "Series number"
        case .genre: "Genre"
        case .year: "Year"
        case .publisher: "Publisher"
        case .summary: "Summary"
        case .language: "Language"
        case .isbn: "ISBN"
        case .asin: "ASIN"
        case .cover: "Cover"
        }
    }

    // MARK: Wording

    /// "11 books imported, 1 needs attention": each count that is not zero, the first one
    /// saying what is being counted.
    private static func headline(_ counts: [(count: Int, one: String, many: String)], nothing: String) -> String {
        let parts = counts.filter { $0.count > 0 }
        guard !parts.isEmpty else { return nothing }
        return parts.enumerated().map { index, part in
            let noun = index == 0 ? (part.count == 1 ? " book" : " books") : ""
            return "\(part.count)\(noun) \(part.count == 1 ? part.one : part.many)"
        }.joined(separator: ", ")
    }

    private static func line(_ title: String, _ problem: FileProblem) -> ResultSummary.Line {
        .init(title: title, detail: "\(problem.file): \(sentence(problem.reason))")
    }

    private static func shownTitle(_ title: String?) -> String {
        title?.trimmedOrNil ?? "Untitled book"
    }

    /// The file's name in quotation marks, whether given a name or a whole path.
    private static func name(_ path: String) -> String {
        "\"\((path as NSString).lastPathComponent)\""
    }

    /// The engine's reasons are fragments ("the disk is full"): gives one a capital
    /// letter and a full stop.
    private static func sentence(_ text: String) -> String {
        let text = text.trimmed
        guard let first = text.first else { return "" }
        let capitalised = first.uppercased() + text.dropFirst()
        return ".!?".contains(text.last ?? ".") ? capitalised : capitalised + "."
    }

    private static func joined(_ sentences: [String]) -> String {
        sentences.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The sentences, then each item on a line of its own.
    private static func listed(_ sentences: [String], _ items: [String]) -> String {
        ([joined(sentences)] + items).joined(separator: "\n")
    }
}
